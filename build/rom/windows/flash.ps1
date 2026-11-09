#Requires -Version 5.1
<#
  flash.ps1 - install the TB710FU Arch ROM from Windows.

    .\flash.ps1 dual      keep ZUXOS; shrink userdata, create an arch partition
    .\flash.ps1 single    erase Android data; rename userdata to arch

  The script only writes boot_a with fastboot.  The rootfs is served over
  USB-NBD from this PC; the installer inside the boot image partitions the
  UFS, copies the rootfs, writes the final boot_a and reboots to the
  bootloader.  The script then finishes with "fastboot reboot".

  Requires: Windows 10/11 x64, an unlocked bootloader, a data-capable USB-C
  cable and (for dual) a backup of the Android data you care about.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('dual', 'single')]
    [string]$Mode,

    # Skip the interactive YES prompt (for scripted reinstalls).
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Fail([string]$Text) { Write-Host "`n!! $Text" -ForegroundColor Red; exit 1 }

# Native commands (fastboot/zstd) write progress and getvar replies to stderr.
# PowerShell 5.1 turns redirected native stderr into a terminating error when
# $ErrorActionPreference is Stop, so every call goes through these helpers.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = & $Exe @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Output = $text; Code = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-Fastboot {
    param([string[]]$Arguments)
    return (Invoke-Native -Exe $script:Fastboot -Arguments $Arguments)
}

# --- locate the package -----------------------------------------------------
$WindowsDir = $PSScriptRoot
if ($WindowsDir.StartsWith('\\\\')) {
    Write-Host '!! The package is on a network share. Copy it to a local disk first.' -ForegroundColor Red
    exit 1
}
$Root = Split-Path -Parent $WindowsDir
$Tools = Join-Path $WindowsDir 'tools'
$Work = Join-Path $Root 'work'

if (-not $Mode) {
    Write-Host 'usage: flash.cmd dual|single'
    exit 2
}

# The firewall rule and the static fallback address need elevation.
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host 'Requesting administrator rights (needed for the USB network / firewall)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Mode', $Mode)
    if ($Yes) { $argList += '-Yes' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList ($argList -join ' ')
    } catch {
        Fail 'Could not elevate. Right-click flash.cmd and choose "Run as administrator".'
    }
    exit
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null

$BootImage = Join-Path $Root "boot\boot_install_$Mode.img"
$RootfsZst = Join-Path $Root 'rootfs\arch-nbd.img.zst'
$Image = Join-Path $Work 'arch-nbd.img'
$NbdLog = Join-Path $Work 'nbd.log'
$NbdErr = Join-Path $Work 'nbd.err'
$Sums = Join-Path $Root 'SHA256SUMS'

foreach ($f in @($BootImage, $RootfsZst, $Sums)) {
    if (-not (Test-Path -LiteralPath $f)) { Fail "missing $f" }
}

# --- fastboot ---------------------------------------------------------------
$Fastboot = Join-Path $Tools 'fastboot.exe'
if (-not (Test-Path -LiteralPath $Fastboot)) {
    $cmd = Get-Command fastboot.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $Fastboot = $cmd.Source
    } else {
        Say 'fastboot.exe not found; downloading Android platform-tools'
        $zip = Join-Path $Work 'platform-tools.zip'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri `
                'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
                -OutFile $zip
            Expand-Archive -LiteralPath $zip -DestinationPath $Work -Force
        } catch {
            Fail "could not download platform-tools: $($_.Exception.Message)"
        }
        $Fastboot = Join-Path $Work 'platform-tools\fastboot.exe'
        if (-not (Test-Path -LiteralPath $Fastboot)) { Fail 'platform-tools did not provide fastboot.exe' }
    }
}
$Zstd = Join-Path $Tools 'zstd.exe'
$NbdServer = Join-Path $Tools 'nbdserver.exe'
foreach ($f in @($Zstd, $NbdServer)) {
    if (-not (Test-Path -LiteralPath $f)) { Fail "missing $f" }
}

# --- hashes -----------------------------------------------------------------
Say 'verify package hashes'
$bad = @()
foreach ($line in Get-Content -LiteralPath $Sums) {
    if ($line -notmatch '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') { continue }
    $want = $Matches[1].ToLowerInvariant()
    $rel = $Matches[2] -replace '/', '\'
    $path = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $path)) { $bad += "$rel (missing)"; continue }
    $got = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $want) { $bad += "$rel ($got != $want)" }
}
if ($bad.Count -gt 0) { Fail ("SHA256SUMS mismatch:`n  " + ($bad -join "`n  ")) }
Write-Host 'all hashes match'

# --- device checks ----------------------------------------------------------
Say 'check the device'
$devices = (Invoke-Fastboot @('devices')).Output
if ($devices -notmatch '\S+\s+fastboot') {
    Fail @'
No fastboot device found.
  1. Power off, then hold Power + Volume Down until the bootloader screen appears.
  2. Install the Google USB driver if Windows does not recognise it:
     https://developer.android.com/studio/run/win-usb
  3. Run "tools\fastboot.exe devices" and check that the serial is listed.
'@
}
$productOut = (Invoke-Fastboot @('getvar', 'product')).Output
$unlockedOut = (Invoke-Fastboot @('getvar', 'unlocked')).Output
$slotOut = (Invoke-Fastboot @('getvar', 'current-slot')).Output
$product = if ($productOut -match 'product:\s*(\S+)') { $Matches[1] } else { '' }
$unlocked = if ($unlockedOut -match 'unlocked:\s*(\S+)') { $Matches[1] } else { '' }
$slot = if ($slotOut -match 'current-slot:\s*(\S+)') { $Matches[1] } else { '' }
Write-Host "product=$product unlocked=$unlocked slot=$slot"
if ($product -notmatch 'TB710FU|tb710fu|sm8650|SM8650|topaz_') {
    Fail "this does not look like a TB710FU (product=$product); refusing"
}
if ($unlocked -ne 'yes') { Fail 'the bootloader is not unlocked; unlock it first' }
if ($slot -ne 'a') {
    Fail "current slot is '$slot'; run `"$Fastboot set_active a`" first (metadata only), then rerun"
}

Say "mode: $Mode"
if ($Mode -eq 'dual') {
    Write-Host @'
This will:
  * shrink the Android userdata partition and create an arch partition in the free tail
    (ZUXOS keeps at least 40 GiB; Arch gets the rest, so 8+128, 8+256, 12+256 and
    12+512 boards each use their own capacity; Arch must be at least 32 GiB)
  * factory-reset ZUXOS's userdata/metadata (Android data will be lost)
  * install Arch in the new partition
  * keep persist/modemst/fsg/fsc/devinfo/frp/keystore/ssd/secdata/uefivarstore/
    super/vbmeta*/dtbo/init_boot/vendor_boot untouched

Back up anything you need from Android before continuing.
'@
} else {
    Write-Host @'
This will:
  * erase ALL Android user data (the userdata partition is reformatted as Arch)
  * rename userdata to arch and install Arch there
  * keep persist/modemst/fsg/fsc/devinfo/frp/keystore/ssd/secdata/uefivarstore/
    super/vbmeta*/dtbo/init_boot/vendor_boot untouched

There is no Android left to boot after this.
'@
}
if (-not $Yes) {
    $answer = Read-Host "`nType YES to continue"
    if ($answer -ne 'YES') { Fail 'aborted' }
}

$archSize = (Invoke-Fastboot @('getvar', 'partition-size:arch')).Output
if ($archSize -notmatch 'not found|unknown|FAILED' -and $archSize -match '\S') {
    Write-Host "!! note: this device already has an arch partition ($($archSize.Trim()))." -ForegroundColor Yellow
    Write-Host '   The installer boot image tries the on-disk arch partition first, so a'
    Write-Host '   reinstall will boot the old system instead of the NBD installer.'
    if (-not $Yes) {
        $again = Read-Host '   Type YES to continue anyway'
        if ($again -ne 'YES') { Fail 'aborted' }
    }
}

# --- unpack the rootfs ------------------------------------------------------
Say 'unpack the rootfs (one-time; needs about 32 GiB free under work\)'
$need = 32GB
try {
    $driveRoot = [System.IO.Path]::GetPathRoot($Work)
    $free = (Get-PSDrive -Name $driveRoot.TrimEnd(':\')).Free
    if ($free -and $free -lt $need) {
        Fail ("only {0:N1} GiB free on {1}; the unpacked image needs about 32 GiB" -f ($free / 1GB), $driveRoot)
    }
} catch { }
if ((-not (Test-Path -LiteralPath $Image)) -or
    ((Get-Item -LiteralPath $RootfsZst).LastWriteTime -gt (Get-Item -LiteralPath $Image).LastWriteTime)) {
    $tmp = "$Image.tmp"
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "zstd: $RootfsZst -> $tmp"
    & $Zstd -d -q -f --no-progress $RootfsZst -o $tmp
    if ($LASTEXITCODE -ne 0) { Fail "zstd failed with exit code $LASTEXITCODE" }
    Move-Item -LiteralPath $tmp -Destination $Image -Force
}
Write-Host ("image: {0} ({1:N1} GiB)" -f $Image, ((Get-Item -LiteralPath $Image).Length / 1GB))

# --- firewall ---------------------------------------------------------------
$ruleName = 'TB710FU NBD 10809'
try {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort 10809 -RemoteAddress 172.16.42.0/24 -Profile Any | Out-Null
        Write-Host 'firewall: allowed TCP 10809 from 172.16.42.0/24'
    }
} catch {
    Write-Host "warning: could not add the firewall rule: $($_.Exception.Message)"
}

# --- NBD server -------------------------------------------------------------
Say 'start the NBD server (port 10809)'
Get-Process nbdserver -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $NbdLog, $NbdErr -Force -ErrorAction SilentlyContinue
$nbd = Start-Process -FilePath $NbdServer `
    -ArgumentList "--image `"$Image`" --port 10809" `
    -RedirectStandardOutput $NbdLog -RedirectStandardError $NbdErr `
    -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
if ($nbd.HasExited) {
    Get-Content -LiteralPath $NbdErr -ErrorAction SilentlyContinue | Write-Host
    Fail 'the NBD server exited immediately (see work\nbd.err)'
}
Write-Host "NBD server pid $($nbd.Id); log: $NbdLog"

try {
    Say "write boot_install_$Mode.img to boot_a"
    $flash = Invoke-Native -Exe $Fastboot -Arguments @('flash', 'boot_a', $BootImage)
    Write-Host $flash.Output
    if ($flash.Code -ne 0) { Fail "fastboot flash failed with exit code $($flash.Code)" }
    Invoke-Fastboot @('reboot') | Out-Null

    Say 'wait for the USB-NBD link (172.16.42.x on this PC)'
    function Get-UsbAddress {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like '172.16.42.*' }
    }
    $addr = $null
    for ($i = 0; $i -lt 60; $i++) {
        $addr = Get-UsbAddress
        if ($addr) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $addr) {
        Write-Host 'no DHCP address yet; trying the USB network adapters directly'
        $candidates = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -eq 'Up' -and
                $_.InterfaceDescription -match 'RNDIS|NCM|USB Ethernet|Remote NDIS|CDC'
            }
        foreach ($adapter in $candidates) {
            try {
                Enable-NetAdapter -InputObject $adapter -Confirm:$false -ErrorAction SilentlyContinue
                New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress 172.16.42.2 `
                    -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null
            } catch { }
        }
        for ($i = 0; $i -lt 15; $i++) {
            $addr = Get-UsbAddress
            if ($addr) { break }
            Start-Sleep -Seconds 2
        }
    }
    if ($addr) {
        $addr | ForEach-Object { Write-Host ("USB link: {0}/{1} on {2}" -f $_.IPAddress, $_.PrefixLength, $_.InterfaceAlias) }
    } else {
        Write-Host 'warning: this PC still has no 172.16.42.x address.' -ForegroundColor Yellow
        Write-Host 'If the installer does not connect, open Network Connections, find the new'
        Write-Host 'USB/RNDIS adapter and set 172.16.42.2/24 on it manually.'
    }

    Say 'waiting for the installer (the tablet returns to fastboot when done)'
    Start-Sleep -Seconds 20
    $deadline = (Get-Date).AddMinutes(45)
    $done = $false
    while ((Get-Date) -lt $deadline) {
        $out = (Invoke-Fastboot @('devices')).Output
        if ($out -match '\S+\s+fastboot') { $done = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $done) {
        Fail "timed out waiting for the installer. Check the tablet screen and $NbdLog"
    }

    Say 'installer finished; rebooting into the installed system'
    Invoke-Fastboot @('reboot') | Out-Null
    Say 'done'
    Write-Host 'First boot can take a few minutes (GNOME + droidloom initialise the fresh cell).'
    Write-Host 'Default password for alarm and root: tb710fu  (change it after first login).'
} finally {
    if ($nbd -and -not $nbd.HasExited) {
        Stop-Process -Id $nbd.Id -Force -ErrorAction SilentlyContinue
    }
}
