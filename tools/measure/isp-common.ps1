<#
.SYNOPSIS
    Shared ISP state sampling, read from /proc/rkisp-vir0.

.DESCRIPTION
    The sensor is one layer and the ISP is another. Reading the sensor tells you
    what exposure and gain the 3A server asked for; it says nothing about what
    the ISP then did with the result. A fault in the ISP - a colour space matrix
    flipping from full to limited range, output gamma changing, black level
    drifting - darkens the picture with every sensor register sitting still.

    /proc/rkisp-vir0 reports each hardware block's state, but only while a host
    is streaming. With no stream it returns a stub of about six lines and every
    field below comes back empty. That is expected, not a fault.

    Used by pipeline-probe.ps1 and luma-probe.ps1.
#>

function Get-FirstCapture {
    <#
    .SYNOPSIS
        First regex capture across a set of lines, or '' if nothing matches.
    #>
    param(
        [string[]]$Lines,
        [string]$Pattern
    )
    foreach ($line in $Lines) {
        if ($line -match $Pattern) { return $matches[1] }
    }
    return ''
}

function ConvertFrom-IspProc {
    <#
    .SYNOPSIS
        Parse the lines of /proc/rkisp-vir0 into the fields that affect image
        brightness.

    .DESCRIPTION
        Takes lines rather than fetching them, so a caller that already has the
        file - pipeline-probe.ps1 collects it in the same ADB round trip as
        everything else - does not pay for a second one.

    .OUTPUTS
        A PSCustomObject of isp_* fields. Fields are empty strings when no host
        is streaming, which is the normal idle state rather than an error.
    #>
    param(
        [string[]]$Lines
    )

    $isp = @($Lines)

    # AWBGAIN reports two values per gain pair, e.g.
    #   AWBGAIN ON(0x6197) (gain0:0x01000100 0x01000100 gain1:0x111111 0x15628a)
    # Only the second half of gain1 was observed to move, so capturing the first
    # token alone - which an earlier version of this code did - hides the one
    # field that changes.
    $awb0  = Get-FirstCapture -Lines $isp -Pattern 'gain0:(\S+)'
    $awb0b = Get-FirstCapture -Lines $isp -Pattern 'gain0:\S+\s+(\S+)'
    $awb1  = Get-FirstCapture -Lines $isp -Pattern 'gain1:(\S+)'
    $awb1b = Get-FirstCapture -Lines $isp -Pattern 'gain1:\S+\s+([^\s)]+)'

    # Blocks that would change image brightness or tone if they switched state.
    # CSM is the one to watch: a FULL to LIMITED range change darkens the picture
    # on its own, with every sensor register sitting still.
    $csm      = Get-FirstCapture -Lines $isp -Pattern '^CSM\s+(\S+)'
    $gammaOut = Get-FirstCapture -Lines $isp -Pattern '^GAMMA_OUT\s+(\S+)'
    $lsc      = Get-FirstCapture -Lines $isp -Pattern '^LSC\s+(\S+)'
    $bls      = Get-FirstCapture -Lines $isp -Pattern '^BLS\s+(\S+)'
    $ob       = Get-FirstCapture -Lines $isp -Pattern '^OB\s+(\S+)'
    $dhaz     = Get-FirstCapture -Lines $isp -Pattern '^DHAZ\s+(\S+)'
    $ccm      = Get-FirstCapture -Lines $isp -Pattern '^CCM\s+(\S+)'

    # Naming individual blocks can only catch what was thought of in advance.
    # Digest every block's on/off state as well, so a block with no column of its
    # own still shows up as a changed digest if it switches.
    #
    # Deliberately digest the NAME and STATE only, never the parenthesised value.
    # Several blocks - CCM and HDRDRC among them - toggle bit 30 of that value
    # from frame to frame as a "config updated" flag, so digesting the raw lines
    # produced a digest that changed on nearly every sample and signalled
    # nothing. Verified over five samples before this was changed.
    $stateLines = @(
        $isp |
        ForEach-Object {
            if ($_ -match '^([A-Z][A-Z0-9_]*)\s+(ON|OFF|FULL|LIMITED)\(') { '{0}={1}' -f $matches[1], $matches[2] }
        }
    )
    $blocksDigest = ''
    if ($stateLines.Count -gt 0) {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $bytes = [Text.Encoding]::UTF8.GetBytes(($stateLines -join "`n"))
        $blocksDigest = (($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
        $md5.Dispose()
    }

    [PSCustomObject]@{
        awb_gain0  = $awb0
        awb_gain0b = $awb0b
        awb_gain1  = $awb1
        awb_gain1b = $awb1b
        isp_gain   = Get-FirstCapture -Lines $isp -Pattern '^GAIN\s+(\S+)'
        isp_drc    = Get-FirstCapture -Lines $isp -Pattern '^HDRDRC\s+(\S+)'
        isp_cproc  = Get-FirstCapture -Lines $isp -Pattern '^CPROC\s+(\S+)'
        isp_csm    = $csm
        isp_gamma  = $gammaOut
        isp_lsc    = $lsc
        isp_bls    = $bls
        isp_ob     = $ob
        isp_dhaz   = $dhaz
        isp_ccm    = $ccm
        isp_blocks = $blocksDigest
        isp_frame  = Get-FirstCapture -Lines $isp -Pattern 'Isp online frame:(\d+)'
        isp_err    = Get-FirstCapture -Lines $isp -Pattern 'ErrCnt:(\d+)'
        frameloss  = Get-FirstCapture -Lines $isp -Pattern 'frameloss:(\d+)'
    }
}

function Get-IspSample {
    <#
    .SYNOPSIS
        One ADB round trip returning the parsed ISP state.

    .PARAMETER Adb
        Path to the adb executable.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Adb
    )

    $raw = & $Adb shell 'cat /proc/rkisp-vir0 2>/dev/null' 2>&1
    # ls-style colour escapes can leak into adb output; strip them before parsing.
    $lines = @($raw -split "`r?`n" | ForEach-Object { $_ -replace "`e\[[0-9;]*m", '' })
    return ConvertFrom-IspProc -Lines $lines
}
