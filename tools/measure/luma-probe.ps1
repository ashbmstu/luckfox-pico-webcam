<#
.SYNOPSIS
    Measure the brightness of the picture the camera actually produces, next to
    what the sensor was told to do.

.DESCRIPTION
    Every other script in tools/measure reads the control loop's decisions and
    never looks at the picture. That is deliberate - it makes them work in an
    unlit room - but it leaves one question unanswerable: has the image got
    darker while the sensor registers sat still?

    That question matters. A fault anywhere downstream of the sensor - the ISP's
    colour space matrix flipping from full to limited range, output gamma
    changing, black level drifting - darkens the picture with every sensor
    register unchanged. ae-probe.ps1 would report a perfectly healthy camera
    throughout.

    This script captures stills from a single MediaCapture session, measures the
    luminance of each one, and reads the sensor's exposure and gain at the same
    moment. One CSV row per shot, so the two can be compared directly:

        luma steady,   gain steady    -> nothing is happening
        luma falls,    gain rises     -> the scene got darker; AE is compensating
        luma falls,    gain steady    -> the fault is downstream of the sensor
        luma steady,   gain rises     -> the scene got darker; AE is keeping up

    The third line is the one worth catching, and it is the one no other script
    in this directory can see.

.PARAMETER Shots
    Number of stills to capture. Default 30.

.PARAMETER GapSec
    Seconds between shots. Default 10. Shots x GapSec is the run length.

.PARAMETER OutDir
    Where images and the CSV go. Defaults to a timestamped directory under the
    current one.

.PARAMETER Csv
    CSV path. Defaults to luma.csv inside OutDir.

.PARAMETER DiscardImages
    Delete each JPEG once it has been measured. An overnight run at a ten second
    gap is around 3000 images; keep them only if you intend to look at them.

.PARAMETER Analyse
    Measure existing JPEG or PNG files instead of capturing. No camera is
    touched, so this is safe to run while something else is streaming. Sensor
    columns are left empty because there is no moment to attach them to.

.EXAMPLE
    .\luma-probe.ps1 -Shots 60 -GapSec 60 -DiscardImages
    An hour-long run, one shot a minute, keeping only the numbers.

.EXAMPLE
    .\luma-probe.ps1 -Analyse .\run\*.jpg -Csv .\redo.csv
    Re-measure a previous run's images without a camera.

.NOTES
    The camera is an exclusive resource. Capture mode will fail if another
    application holds the stream - including this project's own soak tests.

    Each CapturePhotoToStorageFileAsync call starts and stops the sensor stream
    even within one session, so auto-exposure re-converges for every shot. That
    is a property of the measurement, not a fault, but it means shot-to-shot
    spread of well over a factor of two is normal on this hardware and only a
    trend across many shots means anything.
#>
[CmdletBinding(DefaultParameterSetName = 'Capture')]
param(
    [Parameter(ParameterSetName = 'Capture')]
    [int]$Shots = 30,

    [Parameter(ParameterSetName = 'Capture')]
    [int]$GapSec = 10,

    [Parameter(ParameterSetName = 'Capture')]
    [int]$Width = 1920,

    [Parameter(ParameterSetName = 'Capture')]
    [int]$Height = 1080,

    [Parameter(ParameterSetName = 'Capture')]
    [switch]$DiscardImages,

    [Parameter(ParameterSetName = 'Capture')]
    [string]$Adb = 'adb',

    [Parameter(ParameterSetName = 'Analyse', Mandatory = $true, Position = 0)]
    [string[]]$Analyse,

    [string]$OutDir,
    [string]$Csv
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- luminance --
#
# A 1920x1080 frame is two million pixels. Reading them one at a time through
# System.Drawing's GetPixel takes minutes in PowerShell, and downsampling first
# would blur the percentiles this is measuring. So the pixel loop is compiled:
# it returns a 256-bin histogram, and every statistic below is derived from that
# exactly rather than approximated.
#
# Luma is Rec.601 - 0.299R + 0.587G + 0.114B - in integer form, matching the
# coefficients the video pipeline itself uses.
if (-not ('LumaProbe.Histogram' -as [type])) {
    $cs = @'
namespace LumaProbe {
    using System;
    using System.IO;
    using System.Drawing;
    using System.Drawing.Imaging;
    using System.Runtime.InteropServices;

    public static class Histogram {
        // Returns 514 longs: bins 0-255 for the whole frame, 256-511 for the
        // centre half (roughly what auto-exposure meters), then width and
        // height. Dimensions come back from this same decode so the caller does
        // not open and decode the file a second time just to read its size.
        public static long[] Compute(string path) {
            long[] bins = new long[514];
            // Read the whole file first and decode from memory. Decoding
            // straight from the path keeps the file locked for the lifetime of
            // the Bitmap, which blocks -DiscardImages from deleting it.
            byte[] raw = File.ReadAllBytes(path);
            using (MemoryStream ms = new MemoryStream(raw))
            using (Bitmap bmp = new Bitmap(ms)) {
                int w = bmp.Width, h = bmp.Height;
                bins[512] = w; bins[513] = h;
                int cx0 = w / 4, cx1 = w * 3 / 4, cy0 = h / 4, cy1 = h * 3 / 4;
                Rectangle rect = new Rectangle(0, 0, w, h);
                BitmapData data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                try {
                    int stride = data.Stride;
                    byte[] row = new byte[stride];
                    IntPtr scan = data.Scan0;
                    for (int y = 0; y < h; y++) {
                        Marshal.Copy(new IntPtr(scan.ToInt64() + (long)y * stride), row, 0, stride);
                        bool centreRow = (y >= cy0 && y < cy1);
                        for (int x = 0; x < w; x++) {
                            int i = x * 3;
                            // Format24bppRgb is laid out blue, green, red. The
                            // +128 rounds to nearest; without it the shift
                            // truncates and every frame reads about half a
                            // level dark, which is a bias rather than noise.
                            int luma = (29 * row[i] + 150 * row[i + 1] + 77 * row[i + 2] + 128) >> 8;
                            if (luma > 255) luma = 255;
                            bins[luma]++;
                            if (centreRow && x >= cx0 && x < cx1) bins[256 + luma]++;
                        }
                    }
                } finally {
                    bmp.UnlockBits(data);
                }
            }
            return bins;
        }
    }
}
'@
    Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Drawing'
}

function Get-Percentile {
    param([long[]]$Bins, [double]$Total, [double]$P)
    $want = $Total * $P / 100.0
    $run = 0.0
    for ($v = 0; $v -lt 256; $v++) {
        $run += $Bins[$v]
        if ($run -ge $want) { return $v }
    }
    return 255
}

function Measure-Luma {
    <#
    .SYNOPSIS
        Luminance statistics for one image file.

    .DESCRIPTION
        The percentiles earn their place: a fault that crushes the shadows moves
        p05 while barely touching the mean, and one that clips the highlights
        moves p95 and the clipped-pixel count. A mean on its own would miss both.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $inv = [Globalization.CultureInfo]::InvariantCulture
    $size = (Get-Item -LiteralPath $Path).Length

    # A zero-byte file is a real failure mode of the capture stack, not a
    # corrupt disk. Record it rather than throwing away the whole run.
    if ($size -eq 0) {
        return [PSCustomObject]@{
            bytes = 0; w = ''; h = ''; mean = ''; stddev = ''
            p05 = ''; p50 = ''; p95 = ''; centre_mean = ''
            black_pct = ''; clipped_pct = ''; note = 'empty file'
        }
    }

    $full = (Resolve-Path -LiteralPath $Path).Path

    # Windows can still hold the file briefly after a capture completes. Retry
    # rather than losing the shot; an earlier tool in this project spun on this
    # and produced hundreds of exceptions instead of a measurement.
    $bins = $null
    for ($try = 1; $try -le 5; $try++) {
        try { $bins = [LumaProbe.Histogram]::Compute($full); break }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds (100 * $try) }
    }
    if ($null -eq $bins) {
        return [PSCustomObject]@{
            bytes = $size; w = ''; h = ''; mean = ''; stddev = ''
            p05 = ''; p50 = ''; p95 = ''; centre_mean = ''
            black_pct = ''; clipped_pct = ''; note = 'file locked'
        }
    }
    $w = $bins[512]; $h = $bins[513]

    $total = 0.0; $sum = 0.0
    for ($v = 0; $v -lt 256; $v++) { $total += $bins[$v]; $sum += $bins[$v] * $v }
    if ($total -le 0) { return $null }
    $mean = $sum / $total

    $var = 0.0
    for ($v = 0; $v -lt 256; $v++) { $d = $v - $mean; $var += $bins[$v] * $d * $d }
    $stddev = [math]::Sqrt($var / $total)

    $ctotal = 0.0; $csum = 0.0
    for ($v = 0; $v -lt 256; $v++) { $ctotal += $bins[256 + $v]; $csum += $bins[256 + $v] * $v }
    $centre = ''
    if ($ctotal -gt 0) { $centre = ([math]::Round($csum / $ctotal, 3)).ToString($inv) }

    [PSCustomObject]@{
        bytes       = $size
        w           = $w
        h           = $h
        mean        = ([math]::Round($mean, 3)).ToString($inv)
        stddev      = ([math]::Round($stddev, 3)).ToString($inv)
        p05         = Get-Percentile -Bins $bins -Total $total -P 5
        p50         = Get-Percentile -Bins $bins -Total $total -P 50
        p95         = Get-Percentile -Bins $bins -Total $total -P 95
        centre_mean = $centre
        # Wholly black and wholly clipped pixels. A black level fault shows here
        # long before it is obvious by eye.
        black_pct   = ([math]::Round(100.0 * $bins[0] / $total, 3)).ToString($inv)
        clipped_pct = ([math]::Round(100.0 * $bins[255] / $total, 3)).ToString($inv)
        note        = ''
    }
}

# ------------------------------------------------------------------- output --
$columns = @(
    'time', 'shot', 'file', 'w', 'h',
    'mean', 'centre_mean', 'stddev', 'p05', 'p50', 'p95',
    'black_pct', 'clipped_pct', 'bytes',
    'exp_lines', 'again', 'gain_x',
    # The ISP columns are what turn "the fault is downstream of the sensor" into
    # a named block. Sort the finished CSV by mean and look for a column that
    # splits the same way brightness does.
    'isp_gain', 'isp_drc', 'isp_cproc', 'isp_csm', 'isp_gamma', 'isp_lsc',
    'isp_bls', 'isp_ob', 'isp_dhaz', 'isp_ccm', 'awb_gain1b', 'isp_blocks',
    'isp_frame',
    'note'
)

# Every ISP field is empty for a row where no host was streaming, and empty
# columns invite the reader to think the probe failed. Fill them explicitly.
$ispBlank = [PSCustomObject]@{
    isp_gain = ''; isp_drc = ''; isp_cproc = ''; isp_csm = ''; isp_gamma = ''
    isp_lsc = ''; isp_bls = ''; isp_ob = ''; isp_dhaz = ''; isp_ccm = ''
    awb_gain1b = ''; isp_blocks = ''; isp_frame = ''
}

function Write-Row {
    param($Row, [string]$Path)
    $ordered = [ordered]@{}
    foreach ($c in $columns) { $ordered[$c] = $Row.$c }
    [PSCustomObject]$ordered | Export-Csv -Path $Path -NoTypeInformation -Append -Encoding UTF8
}

# ------------------------------------------------------------ analyse mode ---
if ($PSCmdlet.ParameterSetName -eq 'Analyse') {
    if (-not $Csv) { $Csv = 'luma.csv' }
    if (Test-Path -LiteralPath $Csv) { Remove-Item -LiteralPath $Csv }

    $files = @()
    foreach ($pattern in $Analyse) {
        $files += @(Get-Item -Path $pattern -ErrorAction SilentlyContinue)
    }
    if ($files.Count -eq 0) { throw "No files matched: $($Analyse -join ', ')" }

    $n = 0
    foreach ($f in ($files | Sort-Object Name)) {
        $n++
        $m = Measure-Luma -Path $f.FullName
        if ($null -eq $m) { continue }
        $row = [PSCustomObject]@{
            time = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); shot = $n
            file = $f.Name; w = $m.w; h = $m.h
            mean = $m.mean; centre_mean = $m.centre_mean; stddev = $m.stddev
            p05 = $m.p05; p50 = $m.p50; p95 = $m.p95
            black_pct = $m.black_pct; clipped_pct = $m.clipped_pct; bytes = $m.bytes
            exp_lines = ''; again = ''; gain_x = ''; note = $m.note
        }
        foreach ($c in $ispBlank.PSObject.Properties.Name) {
            Add-Member -InputObject $row -NotePropertyName $c -NotePropertyValue ''
        }
        Write-Row -Row $row -Path $Csv
        Write-Host ('{0,-20} mean {1,8}  centre {2,8}  p05 {3,3}  p95 {4,3}  {5}' -f
            $f.Name, $m.mean, $m.centre_mean, $m.p05, $m.p95, $m.note)
    }
    Write-Host ''
    Write-Host "Wrote $Csv"
    return
}

# ------------------------------------------------------------ capture mode ---
if (-not $OutDir) { $OutDir = Join-Path (Get-Location) ('luma-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
if (-not $Csv) { $Csv = Join-Path $OutDir 'luma.csv' }
if (Test-Path -LiteralPath $Csv) { Remove-Item -LiteralPath $Csv }

# Sensor sampling is shared with ae-probe.ps1 so the gain maths lives in exactly
# one place. Without adb the run still works; the sensor columns stay empty.
$aeCommon  = Join-Path $PSScriptRoot 'ae-common.ps1'
$ispCommon = Join-Path $PSScriptRoot 'isp-common.ps1'
$haveAdb = $false
$adbPath = $null
if (Test-Path -LiteralPath $aeCommon) {
    . $aeCommon
    if (Test-Path -LiteralPath $ispCommon) { . $ispCommon }
    # Unlike the other probes, a missing adb is not fatal here: the luminance
    # measurement still stands on its own, it just loses the columns that say
    # what the camera was doing at the time.
    try {
        $adbPath = Resolve-AdbPath -Adb $Adb
        $haveAdb = $null -ne (Get-AeSample -Adb $adbPath)
        if (-not $haveAdb) { Write-Warning 'adb found but the sensor did not answer; sensor and ISP columns will be empty.' }
    } catch {
        Write-Warning "$($_.Exception.Message) Sensor and ISP columns will be empty."
    }
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.MediaProperties.ImageEncodingProperties, Windows.Media.MediaProperties, ContentType = WindowsRuntime]
$null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]

# WinRT async methods are not awaitable from PowerShell directly; these two
# reflected AsTask overloads bridge IAsyncOperation<T> and IAsyncAction.
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
$asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
})[0]

function Wait-Op {
    param($Op, [Type]$ResultType)
    $task = $asTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Op))
    if (-not $task.Wait(20000)) { throw 'WinRT operation timed out' }
    $task.Result
}
function Wait-Action {
    param($Op)
    $task = $asTaskAction.Invoke($null, @($Op))
    if (-not $task.Wait(20000)) { throw 'WinRT action timed out' }
}

$devs = Wait-Op ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
    [Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
$target = $devs | Where-Object { $_.Name -like '*UVC Camera*' } | Select-Object -First 1
if (-not $target) {
    Write-Host 'Video capture devices found:'
    foreach ($d in $devs) { Write-Host " - $($d.Name)" }
    throw 'No device named "UVC Camera". Is the board plugged in and streaming?'
}
Write-Host "Camera: $($target.Name)"

$mc = New-Object Windows.Media.Capture.MediaCapture
try {
    $settings = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
    $settings.VideoDeviceId = $target.Id
    $settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
    Wait-Action ($mc.InitializeAsync($settings))

    $props = $mc.VideoDeviceController.GetAvailableMediaStreamProperties(
        [Windows.Media.Capture.MediaStreamType]::VideoRecord)
    $want = $props | Where-Object {
        $_.Subtype -eq 'MJPG' -and $_.Width -eq $Width -and $_.Height -eq $Height
    } | Select-Object -First 1
    if (-not $want) { throw "The camera does not offer MJPG ${Width}x${Height}." }
    Wait-Action ($mc.VideoDeviceController.SetMediaStreamPropertiesAsync(
        [Windows.Media.Capture.MediaStreamType]::VideoRecord, $want))
    Write-Host ("Mode: MJPG {0}x{1}" -f $want.Width, $want.Height)
    Write-Host ("Run: {0} shots, {1} s apart, about {2} minutes" -f
        $Shots, $GapSec, [math]::Round($Shots * $GapSec / 60.0, 1))
    Write-Host ''

    $folder = Wait-Op ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($OutDir)) ([Windows.Storage.StorageFolder])
    $fmt = [Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg()

    for ($i = 1; $i -le $Shots; $i++) {
        $name = 'shot{0:d4}.jpg' -f $i
        $file = Wait-Op ($folder.CreateFileAsync($name,
            [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])

        $note = ''
        try {
            Wait-Action ($mc.CapturePhotoToStorageFileAsync($fmt, $file))
        } catch {
            $note = 'capture failed'
        }

        # Read the sensor immediately after the shutter, while the stream this
        # capture opened is still up. Reading it before would report the state
        # left over from the previous shot.
        # Read the ISP in the same breath as the sensor. /proc/rkisp-vir0 only
        # reports while a host is streaming, and the stream this capture opened
        # is still up at this instant - a moment later it is not.
        $ae = $null
        $isp = $null
        if ($haveAdb) {
            $ae = Get-AeSample -Adb $adbPath
            if (Get-Command Get-IspSample -ErrorAction SilentlyContinue) {
                $isp = Get-IspSample -Adb $adbPath
            }
        }

        $path = Join-Path $OutDir $name
        $m = Measure-Luma -Path $path
        if ($null -eq $m) {
            $m = [PSCustomObject]@{
                bytes = 0; w = ''; h = ''; mean = ''; stddev = ''; p05 = ''; p50 = ''
                p95 = ''; centre_mean = ''; black_pct = ''; clipped_pct = ''; note = 'unreadable'
            }
        }
        if ($note -and -not $m.note) { $m.note = $note }

        $expText = ''; $againText = ''; $gainText = ''
        if ($ae) { $expText = $ae.exp_lines; $againText = $ae.again; $gainText = $ae.gain_x }

        $row = [PSCustomObject]@{
            time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); shot = $i
            file = $name; w = $m.w; h = $m.h
            mean = $m.mean; centre_mean = $m.centre_mean; stddev = $m.stddev
            p05 = $m.p05; p50 = $m.p50; p95 = $m.p95
            black_pct = $m.black_pct; clipped_pct = $m.clipped_pct; bytes = $m.bytes
            exp_lines = $expText; again = $againText; gain_x = $gainText
            note = $m.note
        }
        foreach ($c in $ispBlank.PSObject.Properties.Name) {
            $v = ''
            if ($isp) { $v = $isp.$c }
            Add-Member -InputObject $row -NotePropertyName $c -NotePropertyValue $v
        }
        Write-Row -Row $row -Path $Csv

        Write-Host ('{0,4}  {1}  mean {2,8}  centre {3,8}  p05 {4,3}  p95 {5,3}  gain {6,7}  exp {7,6}  {8}' -f
            $i, $row.time.Substring(11), $row.mean, $row.centre_mean, $row.p05, $row.p95,
            $row.gain_x, $row.exp_lines, $row.note)

        if ($DiscardImages) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
        if ($i -lt $Shots) { Start-Sleep -Seconds $GapSec }
    }
} finally {
    $mc.Dispose()
}

Write-Host ''
Write-Host "Wrote $Csv"
