<#
.SYNOPSIS
    Measure image brightness frame by frame from a stream that keeps running,
    with the option to restart the stream between samples.

.DESCRIPTION
    luma-probe.ps1 answers "how bright is a still?", but it takes every still
    with CapturePhotoToStorageFileAsync, and that call starts and stops the
    sensor stream each time. Every one of its shots therefore samples a fresh
    stream, which makes two very different faults look identical:

      per frame        brightness wanders while a call is in progress
      per stream open  brightness is decided when the stream starts, then held

    Those need different fixes and the distinction is not academic - it is the
    difference between "your picture drifts during a meeting" and "your picture
    is wrong for the whole meeting until you reconnect".

    This tool separates them. It builds one DirectShow graph, taps it with a
    SampleGrabber, and reads raw RGB24 frames out of it while the graph stays in
    Run state. Nothing restarts between samples, so any variation seen here is
    genuinely frame to frame. Pass -Restart to tear the graph down and rebuild it
    for every sample, which reintroduces exactly one variable - the stream
    restart - and nothing else.

    The grabber path never touches the Windows photo pipeline, so comparing this
    tool against luma-probe.ps1 also tells you whether an effect comes from the
    board or from the host's still-capture path.

    Luma is the same integer Rec.601 approximation luma-probe.ps1 uses, including
    the round-to-nearest term, so mean and percentile columns are comparable
    between the two tools. Absolute levels are not comparable to a JPEG opened in
    another application, because no display or colour transform is applied here.

.PARAMETER Csv
    Where to write samples. Created with a header; appended to if it exists.

.PARAMETER Samples
    How many frames to record.

.PARAMETER GapSec
    Seconds between samples.

.PARAMETER Restart
    Rebuild the capture graph before every sample instead of holding one open.

.PARAMETER SettleSec
    With -Restart, seconds to let the stream run before grabbing. Auto-exposure
    needs a moment after a restart; too short and you measure the ramp instead of
    the result. Ignored without -Restart.

.PARAMETER Adb
    Path to adb, used only to record ISP state beside each frame. The camera and
    ADB are independent, so this is safe while streaming.

.EXAMPLE
    .\stream-probe.ps1 -Samples 60 -GapSec 3
    Sixty frames from one uninterrupted stream.

.EXAMPLE
    .\stream-probe.ps1 -Samples 20 -Restart -SettleSec 5 -GapSec 8
    Twenty frames, each from its own freshly opened stream.

.NOTES
    The camera is exclusive - nothing else may hold it while this runs.

    Keep restart cycles slow. Opening and closing the stream every few seconds
    wedges the board's MPP channel ("mpp_chan: ctx is no found in chan server" in
    dmesg, and "rkisp-vir0: waiting on params stream off event timeout"), after
    which frames stop arriving until the rate drops. The fault is rate dependent
    and clears on its own; a total cycle of about 15 s has been stable.
#>
param(
    [string]$Csv = "$PSScriptRoot\stream-log.csv",
    [int]$Samples = 60,
    [double]$GapSec = 3,
    [switch]$Restart,
    [double]$SettleSec = 5,
    [int]$Width = 1920,
    [int]$Height = 1080,
    [string]$Camera = 'UVC Camera',
    [string]$Adb = 'adb'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ae-common.ps1"
. "$PSScriptRoot\isp-common.ps1"

$Adb = Resolve-AdbPath -Adb $Adb

# DirectShow interop. Only the members actually called are declared; the rest of
# each interface is padded with correctly typed placeholders so the vtable layout
# stays right, which is why some methods below are never referenced.
$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IBaseFilter { }

[ComImport, Guid("56a868a9-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IGraphBuilder
{
    int AddFilter(IBaseFilter pFilter, [MarshalAs(UnmanagedType.LPWStr)] string pName);
    int RemoveFilter(IBaseFilter pFilter);
    int EnumFilters(out IntPtr ppEnum);
    int FindFilterByName([MarshalAs(UnmanagedType.LPWStr)] string pName, out IBaseFilter ppFilter);
    int ConnectDirect(IntPtr ppinOut, IntPtr ppinIn, IntPtr pmt);
    int Reconnect(IntPtr ppin);
    int Disconnect(IntPtr ppin);
    int SetDefaultSyncSource();
    int Connect(IntPtr ppinOut, IntPtr ppinIn);
    int Render(IntPtr ppinOut);
    int RenderFile([MarshalAs(UnmanagedType.LPWStr)] string f, [MarshalAs(UnmanagedType.LPWStr)] string p);
    int AddSourceFilter([MarshalAs(UnmanagedType.LPWStr)] string f, [MarshalAs(UnmanagedType.LPWStr)] string n, out IBaseFilter ppFilter);
    int SetLogFile(IntPtr hFile);
    int Abort();
    int ShouldOperationContinue();
}

[ComImport, Guid("93E5A4E0-2D50-11d2-ABFA-00A0C9C6E38D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICaptureGraphBuilder2
{
    int SetFiltergraph(IGraphBuilder pfg);
    int GetFiltergraph(out IGraphBuilder ppfg);
    int SetOutputFileName(ref Guid pType, [MarshalAs(UnmanagedType.LPWStr)] string f, out IBaseFilter ppf, out IntPtr ppSink);
    int FindInterface(ref Guid pCategory, ref Guid pType, IBaseFilter pf, ref Guid riid, out IntPtr ppint);
    int RenderStream(ref Guid pCategory, ref Guid pType, [MarshalAs(UnmanagedType.IUnknown)] object pSource, IBaseFilter pfCompressor, IBaseFilter pfRenderer);
    int ControlStream(ref Guid pCategory, ref Guid pType, IBaseFilter pFilter, IntPtr pstart, IntPtr pstop, short wStartCookie, short wStopCookie);
    int AllocCapFile([MarshalAs(UnmanagedType.LPWStr)] string f, long dwlSize);
    int CopyCaptureFile([MarshalAs(UnmanagedType.LPWStr)] string old, [MarshalAs(UnmanagedType.LPWStr)] string nw, int fAllowEscAbort, IntPtr pCallback);
    int FindPin([MarshalAs(UnmanagedType.IUnknown)] object pSource, int pindir, ref Guid pCategory, ref Guid pType, [MarshalAs(UnmanagedType.Bool)] bool fUnconnected, int num, out IntPtr ppPin);
}

[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICreateDevEnum
{
    int CreateClassEnumerator(ref Guid clsidDeviceClass, out IEnumMoniker ppEnumMoniker, int dwFlags);
}

[ComImport, Guid("56a868b1-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
public interface IMediaControl
{
    int Run();
    int Pause();
    int Stop();
    int GetState(int msTimeout, out int pfs);
    int RenderFile(string strFilename);
    int AddSourceFilter(string strFilename, out object ppUnk);
    int get_FilterCollection(out object ppUnk);
    int get_RegFilterCollection(out object ppUnk);
    int StopWhenReady();
}

[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyBag
{
    int Read([MarshalAs(UnmanagedType.LPWStr)] string name, out object pVar, IntPtr pErrorLog);
    int Write([MarshalAs(UnmanagedType.LPWStr)] string name, ref object pVar);
}

[StructLayout(LayoutKind.Sequential)]
public struct AMMediaType
{
    public Guid majorType;
    public Guid subType;
    [MarshalAs(UnmanagedType.Bool)] public bool fixedSizeSamples;
    [MarshalAs(UnmanagedType.Bool)] public bool temporalCompression;
    public int sampleSize;
    public Guid formatType;
    public IntPtr unkPtr;
    public int formatSize;
    public IntPtr formatPtr;
}

[ComImport, Guid("C6E13340-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAMStreamConfig
{
    [PreserveSig] int SetFormat(IntPtr pmt);
    [PreserveSig] int GetFormat(out IntPtr ppmt);
    [PreserveSig] int GetNumberOfCapabilities(out int piCount, out int piSize);
    [PreserveSig] int GetStreamCaps(int iIndex, out IntPtr ppmt, IntPtr pSCC);
}

[ComImport, Guid("6B652FFF-11FE-4FCE-92AD-0266B5D7C78F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ISampleGrabber
{
    [PreserveSig] int SetOneShot([MarshalAs(UnmanagedType.Bool)] bool oneShot);
    [PreserveSig] int SetMediaType([In] ref AMMediaType pmt);
    [PreserveSig] int GetConnectedMediaType(IntPtr pmt);
    [PreserveSig] int SetBufferSamples([MarshalAs(UnmanagedType.Bool)] bool bufferThem);
    [PreserveSig] int GetCurrentBuffer(ref int pBufferSize, IntPtr pBuffer);
    [PreserveSig] int GetCurrentSample(IntPtr ppSample);
    [PreserveSig] int SetCallback(IntPtr cb, int whichMethodToCallback);
}

public static class StreamGrab
{
    static readonly Guid CLSID_FilterGraph = new Guid("e436ebb3-524f-11ce-9f53-0020af0ba770");
    static readonly Guid CLSID_CaptureGraphBuilder2 = new Guid("BF87B6E1-8C27-11d0-B3F0-00AA003761C5");
    static readonly Guid CLSID_SystemDeviceEnum = new Guid("62BE5D10-60EB-11d0-BD3B-00A0C911CE86");
    static readonly Guid CLSID_SampleGrabber = new Guid("C1F400A0-3F08-11D3-9F0B-006008039E37");
    static readonly Guid CLSID_NullRenderer = new Guid("C1F400A4-3F08-11D3-9F0B-006008039E37");
    static Guid CLSID_VideoInputDeviceCategory = new Guid("860BB310-5D01-11d0-BD3B-00A0C911CE86");
    static Guid PIN_CATEGORY_PREVIEW = new Guid("fb6c4282-0353-11d1-905f-0000c0cc16ba");
    static Guid PIN_CATEGORY_CAPTURE = new Guid("fb6c4281-0353-11d1-905f-0000c0cc16ba");
    static Guid MEDIATYPE_Video = new Guid("73646976-0000-0010-8000-00AA00389B71");
    static Guid MEDIASUBTYPE_RGB24 = new Guid("e436eb7d-524f-11ce-9f53-0020af0ba770");
    static Guid FORMAT_VideoInfo = new Guid("05589f80-c356-11ce-bf01-00aa0055595a");
    static Guid IID_IBaseFilter = new Guid("56a86895-0ad4-11ce-b03a-0020af0ba770");
    static Guid IID_IAMStreamConfig = new Guid("C6E13340-30AC-11d0-A18C-00A0C9118956");

    static IGraphBuilder g_graph;
    static IMediaControl g_control;
    static ISampleGrabber g_grabber;
    static int g_w, g_h;

    static IBaseFilter FindCamera(string name)
    {
        var devEnum = (ICreateDevEnum)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_SystemDeviceEnum));
        IEnumMoniker en;
        devEnum.CreateClassEnumerator(ref CLSID_VideoInputDeviceCategory, out en, 0);
        if (en == null) return null;
        var mon = new IMoniker[1];
        while (en.Next(1, mon, IntPtr.Zero) == 0)
        {
            object bagObj;
            Guid bagId = typeof(IPropertyBag).GUID;
            mon[0].BindToStorage(null, null, ref bagId, out bagObj);
            object val;
            ((IPropertyBag)bagObj).Read("FriendlyName", out val, IntPtr.Zero);
            if (val != null && val.ToString().Contains(name))
            {
                object filterObj;
                Guid fid = IID_IBaseFilter;
                mon[0].BindToObject(null, null, ref fid, out filterObj);
                return (IBaseFilter)filterObj;
            }
        }
        return null;
    }

    // Pin the capture pin to one resolution. Without this the graph negotiates
    // the first descriptor the device offers, which on this camera is 640x360.
    static string SetCaptureFormat(ICaptureGraphBuilder2 builder, IBaseFilter cam, int width, int height)
    {
        IntPtr scPtr;
        Guid iid = IID_IAMStreamConfig;
        int hr = builder.FindInterface(ref PIN_CATEGORY_CAPTURE, ref MEDIATYPE_Video, cam, ref iid, out scPtr);
        if (hr < 0) return string.Format("FindInterface(IAMStreamConfig) 0x{0:X8}", hr);
        IAMStreamConfig sc = (IAMStreamConfig)Marshal.GetObjectForIUnknown(scPtr);
        int count, size;
        sc.GetNumberOfCapabilities(out count, out size);
        IntPtr caps = Marshal.AllocCoTaskMem(size);
        try
        {
            for (int i = 0; i < count; i++)
            {
                IntPtr mtPtr;
                if (sc.GetStreamCaps(i, out mtPtr, caps) != 0) continue;
                AMMediaType mt = (AMMediaType)Marshal.PtrToStructure(mtPtr, typeof(AMMediaType));
                if (mt.formatPtr == IntPtr.Zero || mt.formatSize < 88) continue;
                // VIDEOINFOHEADER: BITMAPINFOHEADER at offset 48, biWidth at +4, biHeight at +8
                int w = Marshal.ReadInt32(mt.formatPtr, 48 + 4);
                int h = Marshal.ReadInt32(mt.formatPtr, 48 + 8);
                if (w == width && h == height)
                    return string.Format("{0}x{1} hr=0x{2:X8}", w, h, sc.SetFormat(mtPtr));
            }
        }
        finally { Marshal.FreeCoTaskMem(caps); }
        return "no matching capability";
    }

    public static string Start(string name, int width, int height)
    {
        IBaseFilter cam = FindCamera(name);
        if (cam == null) return "camera not found: " + name;

        g_graph = (IGraphBuilder)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_FilterGraph));
        var builder = (ICaptureGraphBuilder2)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_CaptureGraphBuilder2));
        builder.SetFiltergraph(g_graph);
        g_graph.AddFilter(cam, "cam");
        if (width > 0)
        {
            string f = SetCaptureFormat(builder, cam, width, height);
            if (f.StartsWith("no ") || f.StartsWith("FindInterface")) return "format: " + f;
        }

        var grabFilter = (IBaseFilter)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_SampleGrabber));
        g_grabber = (ISampleGrabber)grabFilter;

        // Asking for RGB24 makes the graph insert the MJPEG decompressor and
        // hand over packed pixels, so no decoding happens in this script.
        AMMediaType want = new AMMediaType();
        want.majorType = MEDIATYPE_Video;
        want.subType = MEDIASUBTYPE_RGB24;
        want.formatType = FORMAT_VideoInfo;
        int hrmt = g_grabber.SetMediaType(ref want);
        if (hrmt < 0) return string.Format("SetMediaType 0x{0:X8}", hrmt);
        g_grabber.SetOneShot(false);
        g_grabber.SetBufferSamples(true);
        g_graph.AddFilter(grabFilter, "grab");

        // A null renderer terminates the graph without creating a window, so this
        // works with no desktop session and cannot be disturbed by one.
        var nullRend = (IBaseFilter)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_NullRenderer));
        g_graph.AddFilter(nullRend, "null");

        int hr = builder.RenderStream(ref PIN_CATEGORY_PREVIEW, ref MEDIATYPE_Video, cam, grabFilter, nullRend);
        if (hr < 0)
            hr = builder.RenderStream(ref PIN_CATEGORY_CAPTURE, ref MEDIATYPE_Video, cam, grabFilter, nullRend);
        if (hr < 0) return string.Format("RenderStream 0x{0:X8}", hr);

        IntPtr p = Marshal.AllocCoTaskMem(Marshal.SizeOf(typeof(AMMediaType)));
        try
        {
            if (g_grabber.GetConnectedMediaType(p) >= 0)
            {
                AMMediaType got = (AMMediaType)Marshal.PtrToStructure(p, typeof(AMMediaType));
                if (got.formatPtr != IntPtr.Zero && got.formatSize >= 88)
                {
                    g_w = Marshal.ReadInt32(got.formatPtr, 48 + 4);
                    g_h = Marshal.ReadInt32(got.formatPtr, 48 + 8);
                }
            }
        }
        finally { Marshal.FreeCoTaskMem(p); }

        g_control = (IMediaControl)g_graph;
        g_control.Run();
        return string.Format("running {0}x{1}", g_w, g_h);
    }

    // 258 longs: a 256-bin luma histogram of the whole frame, then width and
    // height. Element 256 is set to -1 and 257 to the HRESULT if no sample is
    // buffered yet, which happens for the first moment after Run.
    //
    // The luma is the same integer Rec.601 form luma-probe.ps1 uses. The +128
    // makes the shift round to nearest instead of truncating; without it every
    // frame reads about half a level dark, which is a bias rather than noise and
    // does not average away.
    public static long[] Frame()
    {
        long[] bins = new long[258];
        int size = 0;
        int hr = g_grabber.GetCurrentBuffer(ref size, IntPtr.Zero);
        if (hr < 0 || size <= 0) { bins[256] = -1; bins[257] = hr; return bins; }

        IntPtr buf = Marshal.AllocCoTaskMem(size);
        try
        {
            hr = g_grabber.GetCurrentBuffer(ref size, buf);
            if (hr < 0) { bins[256] = -1; bins[257] = hr; return bins; }
            byte[] px = new byte[size];
            Marshal.Copy(buf, px, 0, size);

            // Bottom-up DIB, rows padded to a four byte boundary. Byte order is
            // BGR, so the blue coefficient comes first.
            int h = Math.Abs(g_h);
            int stride = ((g_w * 3 + 3) / 4) * 4;
            if (stride * h > size) h = size / stride;
            for (int y = 0; y < h; y++)
            {
                int o = y * stride;
                for (int x = 0; x < g_w; x++)
                {
                    int i = o + x * 3;
                    int luma = (29 * px[i] + 150 * px[i + 1] + 77 * px[i + 2] + 128) >> 8;
                    if (luma > 255) luma = 255;
                    bins[luma]++;
                }
            }
            bins[256] = g_w;
            bins[257] = h;
            return bins;
        }
        finally { Marshal.FreeCoTaskMem(buf); }
    }

    public static void Stop()
    {
        if (g_control != null) { g_control.Stop(); g_control = null; }
        g_grabber = null;
        g_graph = null;
    }
}
'@

Add-Type -TypeDefinition $cs

function Get-BinPercentile {
    <#
    .SYNOPSIS
        The level at which the cumulative histogram first reaches a quantile.
    #>
    param(
        [long[]]$Bins,
        [long]$Total,
        [double]$Quantile
    )
    $target = [long][Math]::Ceiling($Total * $Quantile)
    if ($target -lt 1) { $target = 1 }
    $acc = 0L
    for ($i = 0; $i -lt 256; $i++) {
        $acc += $Bins[$i]
        if ($acc -ge $target) { return $i }
    }
    return 255
}

function Measure-Frame {
    <#
    .SYNOPSIS
        Turn one histogram into the row that gets logged.
    #>
    param(
        [long[]]$Bins,
        [PSCustomObject]$Isp,
        [int]$Index
    )
    $total = 0L
    $sum = 0.0
    for ($k = 0; $k -lt 256; $k++) {
        $total += $Bins[$k]
        $sum += ($k * $Bins[$k])
    }
    $mean = $sum / $total
    $var = 0.0
    for ($k = 0; $k -lt 256; $k++) {
        $d = $k - $mean
        $var += $Bins[$k] * $d * $d
    }

    [PSCustomObject]@{
        time       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        sample     = $Index
        w          = $Bins[256]
        h          = $Bins[257]
        mean       = [Math]::Round($mean, 3).ToString([Globalization.CultureInfo]::InvariantCulture)
        stddev     = [Math]::Round([Math]::Sqrt($var / $total), 3).ToString([Globalization.CultureInfo]::InvariantCulture)
        p01        = (Get-BinPercentile -Bins $Bins -Total $total -Quantile 0.01)
        p05        = (Get-BinPercentile -Bins $Bins -Total $total -Quantile 0.05)
        p50        = (Get-BinPercentile -Bins $Bins -Total $total -Quantile 0.50)
        p95        = (Get-BinPercentile -Bins $Bins -Total $total -Quantile 0.95)
        isp_gain   = $Isp.isp_gain
        isp_drc    = $Isp.isp_drc
        isp_cproc  = $Isp.isp_cproc
        isp_csm    = $Isp.isp_csm
        isp_gamma  = $Isp.isp_gamma
        isp_lsc    = $Isp.isp_lsc
        isp_bls    = $Isp.isp_bls
        isp_ob     = $Isp.isp_ob
        isp_blocks = $Isp.isp_blocks
        isp_frame  = $Isp.isp_frame
    }
}

$columns = @(
    'time', 'sample', 'w', 'h', 'mean', 'stddev', 'p01', 'p05', 'p50', 'p95',
    'isp_gain', 'isp_drc', 'isp_cproc', 'isp_csm', 'isp_gamma', 'isp_lsc',
    'isp_bls', 'isp_ob', 'isp_blocks', 'isp_frame'
)
if (-not (Test-Path -LiteralPath $Csv)) {
    ($columns -join ',') | Set-Content -Path $Csv -Encoding UTF8
}

$mode = if ($Restart) { 'restarting the stream for each sample' } else { 'one continuous stream' }
Write-Host ("stream-probe: {0} samples, {1} s apart, {2}" -f $Samples, $GapSec, $mode)

if (-not $Restart) {
    $res = [StreamGrab]::Start($Camera, $Width, $Height)
    Write-Host ("graph: {0}" -f $res)
    if ($res -notlike 'running*') { throw $res }
    # The graph needs a moment before a sample is buffered to be read.
    Start-Sleep -Seconds 3
}

Write-Host ('{0,6} {1,-10} {2,9} {3,5} {4,5} {5,5} {6,10}' -f 'sample', 'time', 'mean', 'p01', 'p05', 'p95', 'isp_frame')

try {
    for ($i = 1; $i -le $Samples; $i++) {
        if ($Restart) {
            $res = [StreamGrab]::Start($Camera, $Width, $Height)
            if ($res -notlike 'running*') {
                Write-Host ('{0,6} start failed: {1}' -f $i, $res)
                Start-Sleep -Seconds $GapSec
                continue
            }
            Start-Sleep -Seconds $SettleSec
        }

        $bins = [StreamGrab]::Frame()
        $isp = Get-IspSample -Adb $Adb
        if ($Restart) { [StreamGrab]::Stop() }

        if ($bins[256] -lt 0) {
            Write-Host ('{0,6} no frame buffered (hr=0x{1:X8})' -f $i, $bins[257])
            Start-Sleep -Seconds $GapSec
            continue
        }

        $row = Measure-Frame -Bins $bins -Isp $isp -Index $i
        # Quote every field. Several ISP values contain a comma of their own -
        # CSM is reported as "FULL(0x6197)," - which silently shifts every later
        # column into the wrong one if the fields are simply joined.
        (($columns | ForEach-Object { '"{0}"' -f ([string]$row.$_ -replace '"', '""') }) -join ',') |
            Add-Content -Path $Csv -Encoding UTF8
        Write-Host ('{0,6} {1,-10} {2,9} {3,5} {4,5} {5,5} {6,10}' -f `
                $i, $row.time.Substring(11), $row.mean, $row.p01, $row.p05, $row.p95, $row.isp_frame)

        if ($i -lt $Samples) { Start-Sleep -Seconds $GapSec }
    }
}
finally {
    [StreamGrab]::Stop()
}

Write-Host ("wrote {0}" -f $Csv)
