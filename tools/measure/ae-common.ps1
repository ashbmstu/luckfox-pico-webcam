<#
.SYNOPSIS
    Shared helpers for the measurement scripts: SC3336 auto-exposure sampling
    and locating adb.

.DESCRIPTION
    Reads what the 3A server has decided, straight from the sensor, rather than
    judging the picture. That makes the measurement independent of what the
    camera is pointed at - it works in a pitch-dark room, which matters because
    these runs happen overnight.

    Register map (SC3336 uses 16-bit register addresses, which BusyBox i2cget
    cannot express - it rejects anything above 255 - so i2ctransfer is used):

        0x3e00..0x3e02   exposure, 20-bit, in 1/16-line units
        0x3e06           coarse digital gain   (discrete code)
        0x3e07           fine digital gain     (1/128 units)
        0x3e08           not written by the driver, reads 0x00
        0x3e09           analogue gain         (discrete code)

    -f is required because the kernel driver owns the device. Reads are
    non-destructive.
#>

# Analogue gain, register 0x3e09. From sc3336_set_gain_reg() in the vendor
# driver: each code is the lower bound of a band one octave wide, and the fine
# digital gain interpolates within it. Codes are NOT a linear scale - 0x4F is
# 24.32x, not 79x - which is why this has to be a table.
$script:Sc3336AnalogueGain = @{
    0x00 = 1.0
    0x40 = 1.52
    0x48 = 3.04
    0x49 = 6.08
    0x4B = 12.16
    0x4F = 24.32
    0x5F = 48.64
}

# Coarse digital gain, register 0x3e06. Only engaged once analogue gain is at
# its 48.64x ceiling.
$script:Sc3336CoarseDigitalGain = @{
    0x00 = 1.0
    0x01 = 2.0
    0x03 = 4.0
    0x07 = 8.0
}

function Convert-Sc3336Gain {
    <#
    .SYNOPSIS
        Turn the four raw gain register bytes into a single multiplier.

    .DESCRIPTION
        total = analogue x coarse-digital x (fine-digital / 128)

        The ceiling is 48.64 x 8 x 2 = 778x, which is exactly the driver's
        SC3336_GAIN_MAX (99614 = 48.64*16*128). That agreement is the check
        that this table matches the driver.

    .PARAMETER Bytes
        Registers 0x3e06, 0x3e07, 0x3e08, 0x3e09, in that order.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$Bytes
    )

    if ($Bytes.Count -lt 4) { return $null }

    $coarseDigital = $Bytes[0]
    $fineDigital   = $Bytes[1]
    $analogue      = $Bytes[3]

    # An unknown code means the driver has a rung this table does not. Return
    # null rather than a plausible-looking wrong number.
    if (-not $script:Sc3336AnalogueGain.ContainsKey($analogue)) { return $null }
    if (-not $script:Sc3336CoarseDigitalGain.ContainsKey($coarseDigital)) { return $null }

    $total = $script:Sc3336AnalogueGain[$analogue] *
             $script:Sc3336CoarseDigitalGain[$coarseDigital] *
             ($fineDigital / 128.0)

    return [math]::Round($total, 2)
}

function Get-AeSample {
    <#
    .SYNOPSIS
        One ADB round trip returning the sensor's current exposure and gain.

    .PARAMETER Adb
        Path to the adb executable.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Adb
    )

    $probe = @'
i2ctransfer -f -y 4 w2@0x30 0x3e 0x00 r3
i2ctransfer -f -y 4 w2@0x30 0x3e 0x06 r4
cat /proc/uptime
'@ -replace "`r", ""

    $raw = & $Adb shell $probe 2>&1
    $lines = @($raw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -lt 3) { return $null }

    $exp = @($lines[0].Trim() -split '\s+' | ForEach-Object { [Convert]::ToInt32($_, 16) })
    $gn  = @($lines[1].Trim() -split '\s+' | ForEach-Object { [Convert]::ToInt32($_, 16) })
    if ($exp.Count -lt 3 -or $gn.Count -lt 4) { return $null }

    # Exposure is stored shifted left by 4 (1/16-line resolution).
    $expLines = ((($exp[0] -band 0x0F) -shl 16) -bor ($exp[1] -shl 8) -bor $exp[2]) -shr 4

    $gainX = Convert-Sc3336Gain -Bytes $gn
    $gainText = ''
    if ($null -ne $gainX) {
        $gainText = $gainX.ToString([Globalization.CultureInfo]::InvariantCulture)
    }

    # The board's locale is irrelevant, but this machine's is not: a comma
    # decimal separator silently corrupts the CSV.
    [PSCustomObject]@{
        time      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        uptime_s  = [int][double]::Parse(($lines[2].Trim().Split(' '))[0], [Globalization.CultureInfo]::InvariantCulture)
        exp_lines = $expLines
        dgain     = '0x{0:X2}{1:X2}' -f $gn[0], $gn[1]
        again     = '0x{0:X2}' -f $gn[3]
        gain_x    = $gainText
        raw       = ('{0} | {1}' -f $lines[0].Trim(), $lines[1].Trim())
    }
}

function Resolve-AdbPath {
    <#
    .SYNOPSIS
        Turn the -Adb parameter into a usable executable path.

    .DESCRIPTION
        Accepts either a bare command name to be found on PATH - the normal case,
        and the default - or an explicit path, for a machine where the Android
        platform tools are installed somewhere unusual.

        Earlier versions of these scripts defaulted to a path inside a directory
        that is not published with the repository, so the documented default
        could never have worked for anyone who cloned it.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Adb
    )

    if (Test-Path -LiteralPath $Adb -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Adb).Path
    }

    $cmd = Get-Command $Adb -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    throw ("adb not found. Looked for '{0}' both as a path and on PATH. " +
           "Install the Android platform tools, or pass -Adb with a full path.") -f $Adb
}
