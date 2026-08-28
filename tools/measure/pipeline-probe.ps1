<#
.SYNOPSIS
    Log the whole imaging pipeline's state over time: sensor, ISP, and daemon.

.DESCRIPTION
    ae-probe.ps1 reads what auto-exposure has decided on the sensor. That is
    only half the picture. The ISP applies its own white balance, gain and tone
    mapping downstream, so a fault there would darken the image while the
    sensor's registers sat perfectly still - invisible to a sensor-only probe.

    This samples all three layers at once:

      sensor   exposure and gain registers over I2C (see ae-common.ps1)
      ISP      /proc/rkisp-vir0, which reports each hardware block's state,
               the white balance gains actually in force, and frame loss
      daemon   the statistics line uvc_streamer prints every five seconds

    Everything here is a read. Nothing is written to the board, and nothing
    depends on what the camera is pointed at, so it is valid in a dark room.

    A host must be streaming for the ISP and daemon figures to mean anything;
    with no stream the pipeline is idle and the sensor registers hold whatever
    they were last left at.

.PARAMETER Seconds
    Total run time. 0 means run until interrupted.

.PARAMETER Interval
    Seconds between samples.

.PARAMETER Csv
    Where to append samples. A header is written when the file is created.
#>
param(
    [int]$Seconds  = 0,
    [int]$Interval = 60,
    [string]$Csv   = "$PSScriptRoot\pipeline-log.csv",
    [string]$Adb   = 'adb'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ae-common.ps1"
. "$PSScriptRoot\isp-common.ps1"

$Adb = Resolve-AdbPath -Adb $Adb

# One round trip for everything. Sections are separated by markers so the output
# can be split reliably even when a section comes back empty.
$script:Probe = @'
echo ---SENSOR---
i2ctransfer -f -y 4 w2@0x30 0x3e 0x00 r3
i2ctransfer -f -y 4 w2@0x30 0x3e 0x06 r4
echo ---ISP---
cat /proc/rkisp-vir0 2>/dev/null
echo ---DAEMON---
grep 'fps,' /tmp/uvc.log 2>/dev/null | tail -1
echo ---THERMAL---
cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null
echo ---MEM---
grep -E '^MemFree|^MemAvailable' /proc/meminfo
for n in rkaiq_3A_server uvc_streamer; do
  p=$(pidof $n | cut -d' ' -f1)
  if [ -n "$p" ]; then
    echo "$n $(grep VmRSS /proc/$p/status | tr -s ' ' | cut -d' ' -f2) $(ls /proc/$p/fd 2>/dev/null | wc -l)"
  else
    echo "$n - -"
  fi
done
echo ---UPTIME---
cat /proc/uptime
'@ -replace "`r", ""

function Get-ProbeSection {
    param([string[]]$Lines, [string]$Name)
    $out = @()
    $inSection = $false
    foreach ($l in $Lines) {
        if ($l -match '^---([A-Z]+)---\s*$') {
            $inSection = ($matches[1] -eq $Name)
            continue
        }
        if ($inSection) { $out += $l }
    }
    return $out
}

function Get-PipelineSample {
    param([string]$AdbPath)

    $raw = & $AdbPath shell $script:Probe 2>&1
    # ls-style colour escapes can leak into adb output; strip them before parsing.
    $lines = @($raw -split "`r?`n" | ForEach-Object { $_ -replace "`e\[[0-9;]*m", '' })

    $sensor = @(Get-ProbeSection -Lines $lines -Name 'SENSOR' | Where-Object { $_.Trim() -ne '' })
    $isp    = @(Get-ProbeSection -Lines $lines -Name 'ISP')
    $daemon = @(Get-ProbeSection -Lines $lines -Name 'DAEMON' | Where-Object { $_.Trim() -ne '' })
    $thermal = @(Get-ProbeSection -Lines $lines -Name 'THERMAL' | Where-Object { $_.Trim() -ne '' })
    $uptime = @(Get-ProbeSection -Lines $lines -Name 'UPTIME' | Where-Object { $_.Trim() -ne '' })
    $mem    = @(Get-ProbeSection -Lines $lines -Name 'MEM' | Where-Object { $_.Trim() -ne '' })

    if ($sensor.Count -lt 2 -or $uptime.Count -lt 1) { return $null }

    $exp = @($sensor[0].Trim() -split '\s+' | ForEach-Object { [Convert]::ToInt32($_, 16) })
    $gn  = @($sensor[1].Trim() -split '\s+' | ForEach-Object { [Convert]::ToInt32($_, 16) })
    if ($exp.Count -lt 3 -or $gn.Count -lt 4) { return $null }

    $expLines = ((($exp[0] -band 0x0F) -shl 16) -bor ($exp[1] -shl 8) -bor $exp[2]) -shr 4
    $gainX = Convert-Sc3336Gain -Bytes $gn
    $gainText = ''
    if ($null -ne $gainX) { $gainText = $gainX.ToString([Globalization.CultureInfo]::InvariantCulture) }

    # ISP state, parsed by the shared decoder in isp-common.ps1 so that this
    # script and luma-probe.ps1 cannot drift apart. The lines come from the
    # single round trip above rather than a second one.
    $ispData = ConvertFrom-IspProc -Lines $isp

    # Board temperature is reported in millidegrees, CPU frequency in kHz. Both
    # are worth having on a long run: a fault that only appears once the board is
    # warm looks like a fault that appears "over time".
    $tempC = ''
    $cpuMhz = ''
    if ($thermal.Count -ge 1 -and $thermal[0].Trim() -match '^-?\d+$') {
        $tempC = ([double]$thermal[0].Trim() / 1000.0).ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($thermal.Count -ge 2 -and $thermal[1].Trim() -match '^\d+$') {
        $cpuMhz = [string]([int]([double]$thermal[1].Trim() / 1000.0))
    }

    $uptimeS = [int][double]::Parse(($uptime[0].Trim().Split(' '))[0], [Globalization.CultureInfo]::InvariantCulture)

    # Daemon statistics, e.g.
    #   [ 1544.844] streaming: 25.0 fps, 24252 kbps, 0 timeouts
    #
    # This is the last matching line in a log that is only appended to while a
    # host streams, so once the stream stops the same line is returned forever.
    # Reporting it as a current reading is wrong and actively misleading: in one
    # 6 h soak kbps sat at exactly 10094 for 18 samples after the stream had
    # already ended, which reads as a suspiciously steady bitrate rather than as
    # no data. The daemon stamps each line with seconds since boot, so age it
    # against /proc/uptime and publish nothing rather than something stale.
    $dline = ''
    if ($daemon.Count -gt 0) { $dline = $daemon[-1] }
    $logTs = Get-FirstCapture -Lines @($dline) -Pattern '^\[\s*([0-9.]+)\]'
    $daemonAge = ''
    if ($logTs -ne '') {
        $daemonAge = [string][int]($uptimeS - [double]::Parse($logTs, [Globalization.CultureInfo]::InvariantCulture))
    }
    # The daemon logs every 5 s while streaming, so six missed intervals means
    # the stream is gone rather than the sample merely landing awkwardly.
    if ($daemonAge -ne '' -and [int]$daemonAge -gt 30) { $dline = '' }

    $fps      = Get-FirstCapture -Lines @($dline) -Pattern 'streaming:\s*([0-9.]+)\s*fps'
    $kbps     = Get-FirstCapture -Lines @($dline) -Pattern '([0-9]+)\s*kbps'
    # timeouts counts polls where the encoder had no frame ready inside 100 ms,
    # so it reports the sensor/ISP/encoder side starving, not anything on USB.
    $timeouts = Get-FirstCapture -Lines @($dline) -Pattern '([0-9]+)\s+timeouts'

    # Memory and descriptor counts. This board has about 33 MB usable and only a
    # couple of megabytes free while streaming, so a slow leak in either process
    # is a plausible mechanism for a fault that only appears after hours.
    $memFree = Get-FirstCapture -Lines $mem -Pattern '^MemFree:\s+(\d+)'
    $memAvail = Get-FirstCapture -Lines $mem -Pattern '^MemAvailable:\s+(\d+)'
    $rss3a = Get-FirstCapture -Lines $mem -Pattern '^rkaiq_3A_server\s+(\S+)'
    $fd3a  = Get-FirstCapture -Lines $mem -Pattern '^rkaiq_3A_server\s+\S+\s+(\S+)'
    $rssD  = Get-FirstCapture -Lines $mem -Pattern '^uvc_streamer\s+(\S+)'
    $fdD   = Get-FirstCapture -Lines $mem -Pattern '^uvc_streamer\s+\S+\s+(\S+)'

    [PSCustomObject]@{
        time      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        uptime_s  = $uptimeS
        exp_lines = $expLines
        dgain     = '0x{0:X2}{1:X2}' -f $gn[0], $gn[1]
        again     = '0x{0:X2}' -f $gn[3]
        gain_x    = $gainText
        awb_gain0 = $ispData.awb_gain0
        awb_gain0b = $ispData.awb_gain0b
        awb_gain1 = $ispData.awb_gain1
        awb_gain1b = $ispData.awb_gain1b
        isp_csm   = $ispData.isp_csm
        isp_gamma = $ispData.isp_gamma
        isp_lsc   = $ispData.isp_lsc
        isp_bls   = $ispData.isp_bls
        isp_ob    = $ispData.isp_ob
        isp_dhaz  = $ispData.isp_dhaz
        isp_ccm   = $ispData.isp_ccm
        isp_blocks = $ispData.isp_blocks
        isp_gain  = $ispData.isp_gain
        isp_drc   = $ispData.isp_drc
        isp_cproc = $ispData.isp_cproc
        soc_temp_c = $tempC
        cpu_mhz   = $cpuMhz
        mem_free_kb = $memFree
        mem_avail_kb = $memAvail
        rss_3a_kb = $rss3a
        rss_daemon_kb = $rssD
        fd_3a     = $fd3a
        fd_daemon = $fdD
        isp_frame = $ispData.isp_frame
        isp_err   = $ispData.isp_err
        frameloss = $ispData.frameloss
        fps       = $fps
        kbps      = $kbps
        timeouts  = $timeouts
        daemon_age_s = $daemonAge
        raw_gain  = ('{0} | {1}' -f $sensor[0].Trim(), $sensor[1].Trim())
    }
}

$columns = @(
    'time', 'uptime_s', 'exp_lines', 'dgain', 'again', 'gain_x',
    'awb_gain0', 'awb_gain0b', 'awb_gain1', 'awb_gain1b',
    'isp_gain', 'isp_drc', 'isp_cproc', 'isp_csm', 'isp_gamma', 'isp_lsc',
    'isp_bls', 'isp_ob', 'isp_dhaz', 'isp_ccm', 'isp_blocks',
    'isp_frame', 'isp_err', 'frameloss', 'soc_temp_c', 'cpu_mhz',
    'mem_free_kb', 'mem_avail_kb', 'rss_3a_kb', 'rss_daemon_kb', 'fd_3a', 'fd_daemon',
    'fps', 'kbps', 'timeouts', 'daemon_age_s', 'raw_gain'
)

if (-not (Test-Path $Csv)) {
    ($columns -join ',') | Set-Content -Path $Csv -Encoding UTF8
}

Write-Host ("logging pipeline state every {0}s -> {1}" -f $Interval, $Csv)
Write-Host ('{0,-19} {1,10} {2,9} {3,12} {4,7} {5,8} {6,7}' -f 'time', 'exp_lines', 'gain_x', 'awb_gain0', 'fps', 'kbps', 'degC')

$deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
$failures = 0

while ((Get-Date) -lt $deadline) {
    $s = $null
    try { $s = Get-PipelineSample -AdbPath $Adb } catch { $s = $null }

    if ($null -ne $s) {
        $failures = 0
        # Quote every field: the ISP strings contain parentheses today and a
        # future one could contain a comma.
        (($columns | ForEach-Object { '"{0}"' -f ([string]$s.$_ -replace '"', '""') }) -join ',') |
            Add-Content -Path $Csv -Encoding UTF8
        Write-Host ('{0,-19} {1,10} {2,9} {3,12} {4,7} {5,8} {6,7}' -f $s.time, $s.exp_lines, $s.gain_x, $s.awb_gain0, $s.fps, $s.kbps, $s.soc_temp_c)
    } else {
        $failures++
        Write-Host ('{0,-19} sample failed ({1} in a row)' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $failures)
    }

    Start-Sleep -Seconds $Interval
}
