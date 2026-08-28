<#
.SYNOPSIS
    Log SC3336 auto-exposure state over time, independent of scene brightness.

.DESCRIPTION
    The 3A server (rkaiq_3A_server) drives auto-exposure by writing exposure and
    gain registers on the sensor over I2C. Reading those registers back tells us
    what AE has decided, without needing to look at the picture at all - which
    matters when the room is dark, or when the drift we are chasing is in the
    control loop rather than in the scene.

    The register map, the gain ladder and the reasoning behind reading the
    sensor rather than the picture all live in ae-common.ps1, which this
    script dot-sources.

.PARAMETER Seconds
    Total run time. 0 means run until interrupted.

.PARAMETER Interval
    Seconds between samples.

.PARAMETER Csv
    Where to append samples. A header is written when the file is created.
#>
param(
    [int]$Seconds  = 0,
    [int]$Interval = 30,
    [string]$Csv   = "$PSScriptRoot\ae-log.csv",
    [string]$Adb   = 'adb'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ae-common.ps1"

$Adb = Resolve-AdbPath -Adb $Adb

if (-not (Test-Path $Csv)) {
    'time,uptime_s,exp_lines,dgain,again,gain_x,raw' | Set-Content -Path $Csv -Encoding UTF8
}

Write-Host ("logging AE state every {0}s -> {1}" -f $Interval, $Csv)
Write-Host ('{0,-19} {1,9} {2,10} {3,8} {4,8}' -f 'time', 'uptime', 'exp_lines', 'again', 'gain_x')

$deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
while ((Get-Date) -lt $deadline) {
    $s = Get-AeSample -Adb $Adb
    if ($null -ne $s) {
        '{0},{1},{2},{3},{4},{5},"{6}"' -f $s.time, $s.uptime_s, $s.exp_lines, $s.dgain, $s.again, $s.gain_x, $s.raw |
            Add-Content -Path $Csv -Encoding UTF8
        Write-Host ('{0,-19} {1,9} {2,10} {3,8} {4,8}' -f $s.time, $s.uptime_s, $s.exp_lines, $s.again, $s.gain_x)
    } else {
        Write-Host ('{0,-19} {1}' -f (Get-Date).ToString('HH:mm:ss'), 'sample failed (board offline?)')
    }
    Start-Sleep -Seconds $Interval
}
