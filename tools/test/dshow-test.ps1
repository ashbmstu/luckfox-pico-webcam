# Minimal DirectShow preview graph for "UVC Camera": capture -> auto decoder -> renderer.
# Screenshots the screen after 5 s so we can see what the DirectShow path renders.
param([string]$OutPng = "$PSScriptRoot\dshow-preview.png", [int]$Width = 0, [int]$Height = 0,
      [int]$Seconds = 5, [switch]$NoScreenshot)

$cs = @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IBaseFilter { } // opaque - only passed around

[ComImport, Guid("56a868a9-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IGraphBuilder
{
    // IFilterGraph
    int AddFilter(IBaseFilter pFilter, [MarshalAs(UnmanagedType.LPWStr)] string pName);
    int RemoveFilter(IBaseFilter pFilter);
    int EnumFilters(out IntPtr ppEnum);
    int FindFilterByName([MarshalAs(UnmanagedType.LPWStr)] string pName, out IBaseFilter ppFilter);
    int ConnectDirect(IntPtr ppinOut, IntPtr ppinIn, IntPtr pmt);
    int Reconnect(IntPtr ppin);
    int Disconnect(IntPtr ppin);
    int SetDefaultSyncSource();
    // IGraphBuilder
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

public static class DShow
{
    public static readonly Guid CLSID_FilterGraph = new Guid("e436ebb3-524f-11ce-9f53-0020af0ba770");
    public static readonly Guid CLSID_CaptureGraphBuilder2 = new Guid("BF87B6E1-8C27-11d0-B3F0-00AA003761C5");
    public static readonly Guid CLSID_SystemDeviceEnum = new Guid("62BE5D10-60EB-11d0-BD3B-00A0C911CE86");
    public static Guid CLSID_VideoInputDeviceCategory = new Guid("860BB310-5D01-11d0-BD3B-00A0C911CE86");
    public static Guid PIN_CATEGORY_PREVIEW = new Guid("fb6c4282-0353-11d1-905f-0000c0cc16ba");
    public static Guid PIN_CATEGORY_CAPTURE = new Guid("fb6c4281-0353-11d1-905f-0000c0cc16ba");
    public static Guid MEDIATYPE_Video = new Guid("73646976-0000-0010-8000-00AA00389B71");
    public static Guid IID_IBaseFilter = new Guid("56a86895-0ad4-11ce-b03a-0020af0ba770");

    static IGraphBuilder g_graph;
    static IMediaControl g_mc;

    public static Guid IID_IAMStreamConfig = new Guid("C6E13340-30AC-11d0-A18C-00A0C9118956");

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
        string got = "";
        for (int i = 0; i < count; i++)
        {
            IntPtr mtPtr;
            if (sc.GetStreamCaps(i, out mtPtr, caps) != 0) continue;
            AMMediaType mt = (AMMediaType)Marshal.PtrToStructure(mtPtr, typeof(AMMediaType));
            if (mt.formatPtr != IntPtr.Zero && mt.formatSize >= 88)
            {
                // VIDEOINFOHEADER: bmiHeader at offset 48; biWidth at +4, biHeight at +8
                int w = Marshal.ReadInt32(mt.formatPtr, 48 + 4);
                int h = Marshal.ReadInt32(mt.formatPtr, 48 + 8);
                got += w + "x" + h + " ";
                if (w == width && h == height)
                {
                    int hr2 = sc.SetFormat(mtPtr);
                    Marshal.FreeCoTaskMem(caps);
                    return string.Format("SetFormat {0}x{1} hr=0x{2:X8}", w, h, hr2);
                }
            }
        }
        Marshal.FreeCoTaskMem(caps);
        return "no matching cap; saw: " + got;
    }

    public static string StartPreview(string name) { return StartPreview(name, 0, 0); }

    public static string StartPreview(string name, int width, int height)
    {
        IBaseFilter cam = FindCamera(name);
        if (cam == null) return "camera not found";
        g_graph = (IGraphBuilder)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_FilterGraph));
        ICaptureGraphBuilder2 builder = (ICaptureGraphBuilder2)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_CaptureGraphBuilder2));
        builder.SetFiltergraph(g_graph);
        g_graph.AddFilter(cam, "cam");
        if (width > 0)
            Console.Error.WriteLine("format: " + SetCaptureFormat(builder, cam, width, height));
        int hr = builder.RenderStream(ref PIN_CATEGORY_PREVIEW, ref MEDIATYPE_Video, cam, null, null);
        if (hr < 0)
        {
            int hr2 = builder.RenderStream(ref PIN_CATEGORY_CAPTURE, ref MEDIATYPE_Video, cam, null, null);
            if (hr2 < 0) return string.Format("RenderStream failed preview=0x{0:X8} capture=0x{1:X8}", hr, hr2);
        }
        g_mc = (IMediaControl)g_graph;
        g_mc.Run();
        return "running";
    }

    public static string ListFilters()
    {
        IntPtr enumPtr;
        g_graph.EnumFilters(out enumPtr);
        IEnumFilters ef = (IEnumFilters)Marshal.GetObjectForIUnknown(enumPtr);
        string names = "";
        IBaseFilter2[] f = new IBaseFilter2[1];
        int fetched;
        while (ef.Next(1, f, out fetched) == 0 && fetched == 1)
        {
            FilterInfo fi;
            f[0].QueryFilterInfo(out fi);
            names += fi.achName + " | ";
        }
        return names;
    }

    public static void StopPreview()
    {
        if (g_mc != null) g_mc.Stop();
    }

    public static IBaseFilter FindCamera(string name)
    {
        var devEnum = (ICreateDevEnum)Activator.CreateInstance(Type.GetTypeFromCLSID(CLSID_SystemDeviceEnum));
        IEnumMoniker en;
        devEnum.CreateClassEnumerator(ref CLSID_VideoInputDeviceCategory, out en, 0);
        if (en == null) return null;
        var mon = new IMoniker[1];
        IntPtr fetched = IntPtr.Zero;
        while (en.Next(1, mon, fetched) == 0)
        {
            object bagObj;
            Guid bagId = typeof(IPropertyBag).GUID;
            mon[0].BindToStorage(null, null, ref bagId, out bagObj);
            var bag = (IPropertyBag)bagObj;
            object val;
            bag.Read("FriendlyName", out val, IntPtr.Zero);
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
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct FilterInfo
{
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string achName;
    public IntPtr pGraph;
}

[ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IBaseFilter2
{
    // IPersist
    int GetClassID(out Guid pClassID);
    // IMediaFilter
    int Stop();
    int Pause();
    int Run(long tStart);
    int GetState(int dwMilliSecsTimeout, out int filtState);
    int SetSyncSource(IntPtr pClock);
    int GetSyncSource(out IntPtr pClock);
    // IBaseFilter
    int EnumPins(out IntPtr ppEnum);
    int FindPin([MarshalAs(UnmanagedType.LPWStr)] string Id, out IntPtr ppPin);
    int QueryFilterInfo(out FilterInfo pInfo);
    int JoinFilterGraph(IntPtr pGraph, [MarshalAs(UnmanagedType.LPWStr)] string pName);
    int QueryVendorInfo([MarshalAs(UnmanagedType.LPWStr)] out string pVendorInfo);
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

[ComImport, Guid("56a86893-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IEnumFilters
{
    [PreserveSig]
    int Next(int cFilters, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] IBaseFilter2[] ppFilter, out int pcFetched);
    int Skip(int cFilters);
    int Reset();
    int Clone(out IEnumFilters ppEnum);
}

[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyBag
{
    int Read([MarshalAs(UnmanagedType.LPWStr)] string name, out object pVar, IntPtr pErrorLog);
    int Write([MarshalAs(UnmanagedType.LPWStr)] string name, ref object pVar);
}
"@
Add-Type -TypeDefinition $cs
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$res = [DShow]::StartPreview("UVC Camera", $Width, $Height)
Write-Output "StartPreview: $res"
if ($res -ne "running") { exit 1 }
Write-Output ("filters: " + [DShow]::ListFilters())
Write-Output "running ${Seconds}s..."
Start-Sleep -Seconds $Seconds

if (-not $NoScreenshot) {
    $b = New-Object System.Drawing.Bitmap([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.CopyFromScreen(0, 0, 0, 0, $b.Size)
    $b.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $b.Dispose()
    Write-Output "SCREENSHOT: $OutPng"
}
[DShow]::StopPreview()
Write-Output "stopped"
