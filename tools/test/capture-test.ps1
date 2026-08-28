# Capture a still from the camera through Media Foundation (WinRT MediaCapture).
#
# This is the Media Foundation leg of testing. dshow-test.ps1 is the DirectShow
# leg, and both matter: the two stacks negotiate differently, and a fault that
# only DirectShow sees is exactly the shape of the black-picture bug fixed in
# 2717e3d. Run both before believing a mode works.
#
# The mode must be forced. Left to itself the host picks a raw mode this camera
# does not offer and the capture returns zero bytes.
#
#   .\capture-test.ps1                          # 1920x1080
#   .\capture-test.ps1 -Width 640 -Height 360
#   .\capture-test.ps1 -Width 2304 -Height 1296
param(
    [int]$Width = 1920,
    [int]$Height = 1080,
    [string]$OutFile
)

if (-not $OutFile) { $OutFile = "$PSScriptRoot\uvc-$Width" + "x$Height.jpg" }

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
$asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
})[0]

function Await-Op($op, [Type]$resultType) {
    $task = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
    $task.Wait(20000) | Out-Null
    $task.Result
}
function Await-Action($op) {
    $task = $asTaskAction.Invoke($null, @($op))
    $task.Wait(20000) | Out-Null
}

# Enumerate video capture devices
$null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
$devs = Await-Op ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
Write-Output "Video capture devices: $($devs.Count)"
foreach ($d in $devs) { Write-Output " - $($d.Name) [$($d.Id)]" }
if ($devs.Count -eq 0) { Write-Output "NO CAMERA FOUND"; exit 1 }
$target = $devs | Where-Object { $_.Name -like '*UVC Camera*' } | Select-Object -First 1
if (-not $target) { Write-Output "UVC Camera not found among devices"; exit 1 }
Write-Output "Using: $($target.Name)"

$mc = New-Object Windows.Media.Capture.MediaCapture
$settings = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
$settings.VideoDeviceId = $target.Id
$settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
Await-Action ($mc.InitializeAsync($settings))
Write-Output "MediaCapture initialized"

# Select MJPG at the requested size. Frame rate is deliberately not part of the
# match: the descriptors advertise one interval, and pinning a number here meant
# every one of these scripts stopped matching the day that interval changed.
$props = $mc.VideoDeviceController.GetAvailableMediaStreamProperties([Windows.Media.Capture.MediaStreamType]::VideoRecord)
$want = $props | Where-Object {
    $_.Subtype -eq 'MJPG' -and $_.Width -eq $Width -and $_.Height -eq $Height
} | Select-Object -First 1
if (-not $want) {
    Write-Output ("MJPG {0}x{1} is not offered. Modes advertised:" -f $Width, $Height)
    $props | Where-Object { $_.Subtype -eq 'MJPG' } | ForEach-Object {
        Write-Output ("  {0}x{1} @{2}" -f $_.Width, $_.Height, $_.FrameRate.Numerator)
    }
    exit 1
}
Write-Output ("Selecting: {0} {1}x{2} @{3}" -f $want.Subtype, $want.Width, $want.Height, $want.FrameRate.Numerator)
Await-Action ($mc.VideoDeviceController.SetMediaStreamPropertiesAsync([Windows.Media.Capture.MediaStreamType]::VideoRecord, $want))
Write-Output "Stream properties set"

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
$folder = Await-Op ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync((Split-Path $OutFile))) ([Windows.Storage.StorageFolder])
$file = Await-Op ($folder.CreateFileAsync((Split-Path $OutFile -Leaf), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
$fmt = [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg()
# Capture 3 times with pauses so auto-exposure can converge; keep the last.
for ($i = 1; $i -le 3; $i++) {
    Await-Action ($mc.CapturePhotoToStorageFileAsync($fmt, $file))
    Write-Output ("capture {0}: {1} bytes" -f $i, (Get-Item $OutFile).Length)
    if ($i -lt 3) { Start-Sleep -Seconds 4 }
}
$mc.Dispose()
$len = (Get-Item $OutFile).Length
if ($len -eq 0) { Write-Output "CAPTURED 0 BYTES - the stream produced nothing"; exit 1 }
Write-Output "CAPTURED: $OutFile ($len bytes)"
