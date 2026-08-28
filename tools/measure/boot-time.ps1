<#
.SYNOPSIS
    Measure how long the board takes to become a usable camera after a reboot.

.DESCRIPTION
    Answers the question the roadmap's G3 goal is about: from the board
    restarting, how long until a host application can select the camera?

    dmesg alone cannot answer this. Kernel timestamps start when the kernel
    starts, so they miss the bootloader entirely, and "the gadget bound" is not
    the same event as "Windows finished enumerating and the device is
    selectable". This script measures the host-visible answer and then lines it
    up against the board's own milestones.

    It reboots over ADB rather than asking for a physical replug, so the power
    rails never actually drop. That makes the number a slight under-estimate of
    a true cold plug-in, which is called out in the output.

.PARAMETER Runs
    How many reboot cycles to average over.

.PARAMETER DeviceName
    Friendly name of the camera as Windows sees it.
#>
param(
    [int]$Runs = 3,
    [string]$DeviceName = 'UVC Camera',
    [string]$Adb = 'adb',
    [string]$Csv = "$PSScriptRoot\boot-time.csv"
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ae-common.ps1"
$Adb = Resolve-AdbPath -Adb $Adb

function Test-CameraPresent {
    # Win32_PnPEntity is the cheapest reliable probe; a camera that is present
    # but still installing shows up with a non-OK status, which is not yet
    # "selectable", so require Status = OK.
    $d = Get-CimInstance Win32_PnPEntity -Filter "Name='$DeviceName'" -ErrorAction SilentlyContinue
    return ($null -ne $d -and $d.Status -eq 'OK')
}

function Wait-Until {
    <#
    .SYNOPSIS
        Block until Condition is true, returning seconds elapsed since Since.

    .DESCRIPTION
        Every measurement has to share one origin: the moment the reboot was
        issued. Timing each wait from whenever the previous one happened to
        finish would report, for example, "adb back: 3s" meaning three seconds
        after the camera appeared, while reading as three seconds after reboot.
    #>
    param(
        [scriptblock]$Condition,
        [datetime]$Since,
        [int]$TimeoutSec = 90
    )
    while (((Get-Date) - $Since).TotalSeconds -lt $TimeoutSec) {
        if (& $Condition) { return [math]::Round(((Get-Date) - $Since).TotalSeconds, 2) }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

$results = @()

for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "--- run $i of $Runs ---"

    if (-not (Test-CameraPresent)) { Write-Host "  camera not present before reboot (already down?)" }

    & $Adb shell "sync" 2>&1 | Out-Null
    & $Adb reboot 2>&1 | Out-Null
    $t0 = Get-Date

    # The device must first disappear, or we would immediately match the
    # pre-reboot state and report a nonsense zero.
    $gone = Wait-Until -Since $t0 -TimeoutSec 30 -Condition { -not (Test-CameraPresent) }
    if ($null -eq $gone) { Write-Host "  camera never disappeared - skipping run"; continue }

    # Both measured from t0, the moment the reboot was issued.
    $camSec = Wait-Until -Since $t0 -TimeoutSec 90 -Condition { Test-CameraPresent }
    $adbSec = Wait-Until -Since $t0 -TimeoutSec 90 -Condition {
        $out = & $Adb devices 2>&1 | Out-String
        $out -match '\sdevice\s*$' -or $out -match "`n\S+\tdevice"
    }

    # The bootloader is invisible from both ends: dmesg's clock only starts when
    # the kernel starts, and the host sees nothing at all until USB enumerates.
    # Reading /proc/uptime the moment adb returns closes that gap - subtracting
    # the board's own uptime from host-elapsed time leaves everything that
    # happened before the kernel began counting, which is shutdown plus
    # bootloader. The read is a round trip over USB, so the reading is treated as
    # referring to the midpoint of that round trip rather than either end.
    $preKernel = $null
    $uptimeAt  = $null
    if ($null -ne $adbSec) {
        $before = Get-Date
        $up = (& $Adb shell "cat /proc/uptime" 2>&1 | Out-String).Trim()
        $after = Get-Date
        if ($up -match '([0-9]+\.[0-9]+)') {
            $uptimeAt = [double]::Parse($matches[1], [Globalization.CultureInfo]::InvariantCulture)
            $mid = $before.AddTicks([long]((($after - $before).Ticks) / 2))
            $preKernel = [math]::Round(($mid - $t0).TotalSeconds - $uptimeAt, 2)
        }
    }

    $total = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
    Write-Host ("  camera selectable: {0}s   adb back: {1}s   (disappeared after {2}s)" -f $camSec, $adbSec, $gone)

    $results += [PSCustomObject]@{
        run          = $i
        gone_after_s = $gone
        camera_s     = $camSec
        adb_s        = $adbSec
        uptime_at_adb_s = $uptimeAt
        pre_kernel_s = $preKernel
        total_s      = $total
    }
}

if ($results.Count -eq 0) { throw "no successful runs" }

$results | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8

$camAvg = [math]::Round((($results | Where-Object { $_.camera_s } | Measure-Object camera_s -Average).Average), 2)
$adbAvg = [math]::Round((($results | Where-Object { $_.adb_s } | Measure-Object adb_s -Average).Average), 2)

Write-Host ''
Write-Host '=== host-visible timing (from `adb reboot`) ==='
$results | Format-Table -AutoSize
Write-Host ("camera selectable, mean: {0}s over {1} runs" -f $camAvg, $results.Count)
Write-Host ("adb back, mean:          {0}s" -f $adbAvg)
Write-Host ''
Write-Host 'Note: measured from a soft reboot, so the power-on rail settling and'
Write-Host 'the initial ROM stage are not included. A cold plug-in is slightly slower.'

# Line the host number up against the board's own view of the same boot.
Write-Host ''
Write-Host '=== board milestones for the last boot (kernel time) ==='
$dmesg = & $Adb shell "dmesg" 2>&1
$patterns = [ordered]@{
    'init starts'          = 'Run /sbin/init'
    'ISP probe'            = 'rkisp_hw .*: is_thunderboot'
    'sensor detected'      = 'sc3336 .*Detected'
    'encoder module'       = 'mpp_vcodec: init'
    'UVC function bound'   = 'uvc_function_bind'
    'USB configured'       = 'USB_STATE=CONFIGURED'
    'ISP first params'     = 'first params buf queue'
}
# The kernel ring buffer is small and wraps. After the board has been streaming
# for a while the early boot lines are gone, and every milestone below reports
# "not seen" for a reason that has nothing to do with the boot itself.
$sawBootStart = $dmesg | Select-String -Pattern 'Booting Linux|Linux version' | Select-Object -First 1
if (-not $sawBootStart) {
    Write-Host '(ring buffer no longer holds the start of boot - milestones may have been'
    Write-Host ' overwritten; this table is only complete straight after a reboot)'
}

$milestone = @{}
foreach ($k in $patterns.Keys) {
    $line = $dmesg | Select-String -Pattern $patterns[$k] | Select-Object -First 1
    if ($line -and $line.Line -match '^\[\s*([0-9.]+)\]') {
        $milestone[$k] = [double]::Parse($matches[1], [Globalization.CultureInfo]::InvariantCulture)
        '{0,-20} {1,8} s' -f $k, $matches[1]
    } else {
        '{0,-20} {1,8}' -f $k, 'not seen'
    }
}

$log = & $Adb shell "cat /tmp/uvc.log" 2>&1
$act = $log | Select-String 'gadget activated' | Select-Object -First 1
if ($act -and $act.Line -match '^\[\s*([0-9.]+)\]') {
    '{0,-20} {1,8} s' -f 'daemon ready', $matches[1]
}

# The deliverable WP0 actually asks for: a phase table that includes the
# bootloader. Each phase is the gap between two clocks that do not otherwise
# meet - the host's, which starts at the reboot command, and the kernel's, which
# starts several seconds later.
$preVals = @($results | Where-Object { $null -ne $_.pre_kernel_s } | ForEach-Object { $_.pre_kernel_s })
if ($preVals.Count -gt 0 -and $milestone.ContainsKey('USB configured')) {
    $preAvg = [math]::Round((($preVals | Measure-Object -Average).Average), 2)
    $usbCfg = $milestone['USB configured']
    $hostEnum = [math]::Round($camAvg - $preAvg - $usbCfg, 2)
    Write-Host ''
    Write-Host '=== where the time goes (phase -> seconds) ==='
    '{0,-34} {1,6} s' -f 'shutdown + bootloader', $preAvg
    '{0,-34} {1,6} s' -f 'kernel start -> USB configured', ([math]::Round($usbCfg, 2))
    '{0,-34} {1,6} s' -f 'host enumeration -> selectable', $hostEnum
    '{0,-34} {1,6} s' -f 'TOTAL (camera selectable)', $camAvg
    Write-Host ''
    Write-Host 'The last row is measured; the three above it are a decomposition of it,'
    Write-Host 'so they are only as good as the assumption that the last boot resembled'
    Write-Host 'the others. Compare pre_kernel_s across runs in the table above.'
} elseif ($preVals.Count -gt 0) {
    Write-Host ''
    Write-Host ('shutdown + bootloader, mean: {0}s (kernel milestones unavailable, so no full phase table)' -f
        [math]::Round((($preVals | Measure-Object -Average).Average), 2))
}

Write-Host ''
Write-Host "wrote $Csv"
