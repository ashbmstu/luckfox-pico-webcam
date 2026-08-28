<#
.SYNOPSIS
    Deploy uvc_streamer to a Luckfox Pico Mini B.

.DESCRIPTION
    Pushes a built uvc_streamer binary to /oem and reboots the board.

    The sequence is push, chmod, mv, reboot — not stop-and-restart. Stopping
    the daemon while the USB gadget is bound deactivates the UVC function,
    which re-runs /etc/init.d/S50usbdevice, rewrites the UDC, and panics the
    kernel in ffs_func_unbind. configfs wedges, a soft reboot hangs, and the
    board needs a physical power cycle. Renaming a running executable with mv
    is safe on Linux while the process still has the old inode mapped. Anyone
    editing this script needs to know that before they "improve" it with a
    kill-and-restart path.

.PARAMETER Binary
    Path to the built uvc_streamer binary. Defaults to
    src/streamer/uvc_streamer relative to the repository root.

.PARAMETER Adb
    Path to the adb executable. Defaults to adb on PATH, or the value of the
    ADB environment variable if set.

.PARAMETER DryRun
    Print the commands without running them.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Binary,

    [string]$Adb = $(if ($env:ADB) { $env:ADB } else { 'adb' }),

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if (-not $Binary) {
    $Binary = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\streamer\uvc_streamer'
}

function Test-AdbExecutable {
    param([string]$Path)

    if (-not (Get-Command -Name $Path -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $null = & $Path version 2>&1
        return $true
    }
    catch {
        return $false
    }
}

function Get-AdbDeviceLines {
    param([string]$Path)

    $output = & $Path devices 2>&1 | Out-String
    return @($output -split "`r?`n" | Where-Object { $_ -match '\tdevice\s*$' })
}

function Invoke-DeployCommand {
    param(
        [string]$Description,
        [scriptblock]$Command
    )

    if ($DryRun) {
        Write-Output "[dry-run] $Description"
        return
    }

    Write-Output $Description
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit $LASTEXITCODE): $Description"
    }
}

if (-not (Test-Path -LiteralPath $Binary)) {
    throw "Binary not found: $Binary"
}

if (-not (Test-AdbExecutable -Path $Adb)) {
    throw "adb is not runnable: $Adb"
}

if (-not $DryRun) {
    $deviceLines = Get-AdbDeviceLines -Path $Adb
    if ($deviceLines.Count -eq 0) {
        throw 'No ADB devices attached. Plug in the board and run ''adb devices''.'
    }
    if ($deviceLines.Count -gt 1) {
        throw ("Multiple ADB devices attached ({0}). Disconnect extras or set ANDROID_SERIAL." -f $deviceLines.Count)
    }
}

Invoke-DeployCommand -Description "adb push `"$Binary`" /tmp/uvc_streamer" -Command {
    & $Adb push $Binary /tmp/uvc_streamer
}

Invoke-DeployCommand -Description 'adb shell "chmod +x /tmp/uvc_streamer && mv /tmp/uvc_streamer /oem/uvc_streamer"' -Command {
    & $Adb shell 'chmod +x /tmp/uvc_streamer && mv /tmp/uvc_streamer /oem/uvc_streamer'
}

Invoke-DeployCommand -Description 'adb shell reboot' -Command {
    & $Adb reboot
}

if ($DryRun) {
    Write-Output '[dry-run] wait up to 60 s for device, then tail /tmp/uvc.log'
    exit 0
}

# adbd takes a moment to go down after 'adb reboot'. Without waiting for the
# device to disappear first, the poll below matches the still-running
# pre-reboot adbd, returns immediately, and tails a stale log.
Write-Output 'Waiting for board to go down...'
$goneDeadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $goneDeadline) {
    if ((Get-AdbDeviceLines -Path $Adb).Count -eq 0) { break }
    Start-Sleep -Seconds 1
}

Write-Output 'Waiting for board to come back (up to 60 s)...'
$deadline = (Get-Date).AddSeconds(60)
$back = $false
while ((Get-Date) -lt $deadline) {
    if ((Get-AdbDeviceLines -Path $Adb).Count -eq 1) {
        $back = $true
        break
    }
    Start-Sleep -Seconds 1
}

if (-not $back) {
    throw 'Board did not reappear on ADB within 60 seconds.'
}

Write-Output 'Last lines of /tmp/uvc.log:'
$log = & $Adb shell 'tail -n 15 /tmp/uvc.log' 2>&1
$log | ForEach-Object { Write-Output $_ }

if ($log -match 'gadget activated') {
    Write-Output 'Daemon reached gadget activated.'
}
else {
    Write-Output 'gadget activated not seen yet — the daemon may still be starting.'
}
