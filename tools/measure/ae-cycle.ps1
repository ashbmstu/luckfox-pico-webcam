<#
.SYNOPSIS
    Test whether auto-exposure working point degrades across stream open/close cycles.

.DESCRIPTION
    Each cycle starts a DirectShow capture stream, samples AE registers at early,
    mid, and settled phases, stops the stream, waits idle, then samples again.
    Compares first vs last settled samples to detect drift across cycles.
#>
param(
    [int]$Cycles    = 60,
    [int]$StreamSec = 45,
    [int]$IdleSec   = 20,
    [string]$Csv    = "$PSScriptRoot\ae-cycle.csv",
    [string]$Adb    = 'adb',
    [int]$Width     = 1920,
    [int]$Height    = 1080
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ae-common.ps1"

$Adb = Resolve-AdbPath -Adb $Adb

$dshowScript = (Resolve-Path "$PSScriptRoot\..\..\tools\test\dshow-test.ps1").Path
$logDir = Join-Path $PSScriptRoot 'ae-cycle-logs'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-AeCycleRow {
    param(
        [int]$Cycle,
        [string]$Phase,
        [object]$Sample
    )

    if ($null -ne $Sample) {
        $row = '{0},{1},{2},{3},{4},{5},{6}' -f $Cycle, $Phase, $Sample.time, $Sample.uptime_s, $Sample.exp_lines, $Sample.again, $Sample.gain_x
    } else {
        $failTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $row = '{0},{1},{2},,,,' -f $Cycle, $Phase, $failTime
    }
    Add-Content -Path $Csv -Encoding UTF8 -Value $row
}

function Get-AeSampleSafe {
    param([string]$AdbPath)

    try {
        return Get-AeSample -Adb $AdbPath
    } catch {
        return $null
    }
}

function Wait-AeSampleAt {
    <#
    .SYNOPSIS
        Sleep until AtSec seconds after the stream started.

    .DESCRIPTION
        Timed from the stream start rather than from the previous sample, so a
        slow ADB round trip does not push every later phase out.
    #>
    param(
        [datetime]$StreamStart,
        [double]$AtSec
    )

    $elapsed = ((Get-Date) - $StreamStart).TotalSeconds
    $waitSec = $AtSec - $elapsed
    if ($waitSec -gt 0) {
        Start-Sleep -Seconds $waitSec
    }
}

function Write-AeCycleSummary {
    param(
        [System.Collections.Generic.List[object]]$SettledSamples
    )

    $summaryPath = $Csv + '.summary.txt'
    $lines = New-Object System.Collections.Generic.List[string]

    if ($SettledSamples.Count -lt 2) {
        $msg = 'Not enough settled samples to compare first vs last cycles.'
        Write-Host $msg
        $lines.Add($msg)
        $lines | Set-Content -Path $summaryPath -Encoding UTF8
        return
    }

    $takeCount = [int][math]::Min(5, [math]::Floor($SettledSamples.Count / 2))
    $first = $SettledSamples.GetRange(0, $takeCount)
    $last = $SettledSamples.GetRange($SettledSamples.Count - $takeCount, $takeCount)

    $firstExp = ($first | ForEach-Object { $_.exp_lines } | Measure-Object -Average).Average
    $lastExp = ($last | ForEach-Object { $_.exp_lines } | Measure-Object -Average).Average
    $firstGain = ($first | ForEach-Object { [double]::Parse($_.gain_x, [Globalization.CultureInfo]::InvariantCulture) } | Measure-Object -Average).Average
    $lastGain = ($last | ForEach-Object { [double]::Parse($_.gain_x, [Globalization.CultureInfo]::InvariantCulture) } | Measure-Object -Average).Average

    $expRatio = if ($firstExp -gt 0) { $lastExp / $firstExp } else { 0 }
    $gainRatio = if ($firstGain -gt 0) { $lastGain / $firstGain } else { 0 }

    $expPct = ($expRatio - 1) * 100
    $gainPct = ($gainRatio - 1) * 100

    $lines.Add('AE cycle summary: first {0} vs last {0} settled samples' -f $takeCount)
    $lines.Add('')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $lines.Add([string]::Format($inv, '  exposure:  first mean {0:F1} lines, last mean {1:F1} lines, ratio {2:F3} ({3:+0.0;-0.0}%)', $firstExp, $lastExp, $expRatio, $expPct))
    $lines.Add([string]::Format($inv, '  gain:      first mean {0:F2}x, last mean {1:F2}x, ratio {2:F3} ({3:+0.0;-0.0}%)', $firstGain, $lastGain, $gainRatio, $gainPct))
    $lines.Add('')

    $maxPct = [math]::Max([math]::Abs($expPct), [math]::Abs($gainPct))
    if ($maxPct -lt 3) {
        $verdict = 'Working point looks stable (change under 3%).'
    } elseif ($lastGain -lt $firstGain -or $lastExp -lt $firstExp) {
        $verdict = 'Working point moved darker across cycles (lower exposure or gain).'
    } else {
        $verdict = 'Working point shifted (exposure or gain changed beyond 3%).'
    }
    $lines.Add($verdict)

    foreach ($line in $lines) {
        Write-Host $line
    }
    $lines | Set-Content -Path $summaryPath -Encoding UTF8
}

if (-not (Test-Path $Csv)) {
    'cycle,phase,time,uptime_s,exp_lines,again,gain_x' | Set-Content -Path $Csv -Encoding UTF8
}

Write-Host ("AE cycle test: {0} cycles, stream {1}s, idle {2}s -> {3}" -f $Cycles, $StreamSec, $IdleSec, $Csv)

$settledSamples = New-Object System.Collections.Generic.List[object]

for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $logFile = Join-Path $logDir ('cycle-{0:D3}.log' -f $cycle)
    $psArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $dshowScript + '" -Seconds ' + $StreamSec + ' -NoScreenshot -Width ' + $Width + ' -Height ' + $Height
    # cmd /c merges stdout and stderr into one log file (PS 5.1 cannot redirect both to the same path).
    $cmdArgs = '/c powershell.exe ' + $psArgs + ' > "' + $logFile + '" 2>&1'

    $streamProc = $null
    try {
        $streamProc = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -PassThru -WindowStyle Hidden
    } catch {
        Write-Host ('cycle {0}: stream failed to start: {1}' -f $cycle, $_.Exception.Message)
        continue
    }

    if ($null -eq $streamProc) {
        Write-Host ('cycle {0}: stream process did not start' -f $cycle)
        continue
    }

    $streamStart = Get-Date
    $settledSample = $null

    # Listed in ascending order of At, and deliberately NOT piped through
    # Sort-Object: in PowerShell 5.1 Sort-Object cannot sort hashtables by a key
    # name, and silently reordered these to settled/mid/early. Wait-AeSampleAt
    # then found each target already in the past and fired all three at the same
    # instant, which quietly destroyed the phase distinction.
    $phases = @(
        [PSCustomObject]@{ Name = 'early';   At = 3 }
        [PSCustomObject]@{ Name = 'mid';     At = 10 }
        [PSCustomObject]@{ Name = 'settled'; At = $StreamSec - 5 }
    )

    foreach ($phase in $phases) {
        Wait-AeSampleAt -StreamStart $streamStart -AtSec $phase.At
        $sample = Get-AeSampleSafe -AdbPath $Adb
        Write-AeCycleRow -Cycle $cycle -Phase $phase.Name -Sample $sample
        if ($phase.Name -eq 'settled' -and $null -ne $sample) {
            $settledSample = $sample
            $settledSamples.Add($sample)
        }
    }

    # dshow-test.ps1 exits on its own after -Seconds. If it ever does not, kill
    # it rather than stalling the whole overnight run on one bad cycle.
    $exitDeadline = (Get-Date).AddSeconds($StreamSec + 30)
    while (-not $streamProc.HasExited) {
        if ((Get-Date) -gt $exitDeadline) {
            Write-Host ('cycle {0}: stream did not exit, terminating' -f $cycle)
            try { $streamProc.Kill() } catch { Write-Host ('  kill failed: {0}' -f $_.Exception.Message) }
            break
        }
        Start-Sleep -Milliseconds 500
    }

    Start-Sleep -Seconds $IdleSec

    $idleSample = Get-AeSampleSafe -AdbPath $Adb
    Write-AeCycleRow -Cycle $cycle -Phase 'idle' -Sample $idleSample

    if ($null -ne $settledSample) {
        Write-Host ('cycle {0}: settled exp={1} gain={2}x' -f $cycle, $settledSample.exp_lines, $settledSample.gain_x)
    } else {
        Write-Host ('cycle {0}: settled sample failed' -f $cycle)
    }
}

Write-AeCycleSummary -SettledSamples $settledSamples
