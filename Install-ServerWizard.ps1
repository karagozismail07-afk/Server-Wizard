<#
 Server Wizard installer: builds ServerWizard.exe (via ps2exe, falling back
 to a .ps1 shortcut if that's unavailable), generates the icon, and creates
 shortcuts. See README.md for full usage and parameters.
#>

[CmdletBinding()]
param(
    [string]$InstallRoot,
    [switch]$AllUsers,     # shortcuts for EVERY account on this server (needs admin)
    [switch]$Uninstall,
    [switch]$RemoveCache
)

$ErrorActionPreference = 'Stop'

# --- Paths -----------------------------------------------------------------
if (-not $InstallRoot) {
    $InstallRoot = if (Test-Path 'D:\') { 'D:\Server Wizard' } else { Join-Path $env:LOCALAPPDATA 'ServerWizard' }
}
$AppDir    = Join-Path $InstallRoot 'App'
$ExePath   = Join-Path $AppDir 'ServerWizard.exe'
$Ps1Path   = Join-Path $AppDir 'ServerWizard.ps1'
$IconPath  = Join-Path $AppDir 'ServerWizard.ico'
$SourcePs1 = Join-Path $PSScriptRoot 'ServerWizard.ps1'

if ($AllUsers) {
    # Public Desktop + All Users Start Menu -> every account sees the shortcuts
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "-AllUsers requires an elevated (Run as administrator) PowerShell."
        return
    }
    $DesktopLnk = 'C:\Users\Public\Desktop\Server Wizard.lnk'
    $StartLnk   = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Server Wizard.lnk'
}
else {
    $DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Server Wizard.lnk'
    $StartLnk   = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\Server Wizard.lnk'
}

# --- Uninstall -------------------------------------------------------------
if ($Uninstall) {
    Write-Host "Uninstalling Server Wizard..." -ForegroundColor Cyan
    Remove-Item -Path $DesktopLnk, $StartLnk -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $AppDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($RemoveCache) {
        Remove-Item -Path (Join-Path $InstallRoot 'ScanCache.xml'),
                          (Join-Path $InstallRoot 'GroupOverrides.xml') -Force -ErrorAction SilentlyContinue
        Write-Host "Cache removed." -ForegroundColor Yellow
    }
    Write-Host "Done. (Cache kept at $InstallRoot unless -RemoveCache was used)" -ForegroundColor Green
    return
}

# --- Preconditions ---------------------------------------------------------
if (-not (Test-Path $SourcePs1)) {
    Write-Error "ServerWizard.ps1 not found next to this installer. Put both files in the same folder."
    return
}

New-Item -ItemType Directory -Path $AppDir -Force | Out-Null

# --- Generate the wizard icon (same drawing as in the app) -----------------
Add-Type -AssemblyName System.Drawing
function New-WizardIcon([string]$path) {
    $size = 64
    $bmp  = New-Object System.Drawing.Bitmap $size, $size
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $blue   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(31, 58, 147))
    $yellow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(250, 204, 21))
    $skin   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(247, 200, 180))
    $beard  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(238, 232, 222))
    $nose   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(240, 150, 140))
    $black  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 40, 40))

    $g.FillPolygon($blue, @(
        [System.Drawing.PointF]::new(32, 1),
        [System.Drawing.PointF]::new(14, 30),
        [System.Drawing.PointF]::new(50, 30)))
    $g.FillEllipse($blue, 9, 26, 46, 9)

    $star = for ($i = 0; $i -lt 10; $i++) {
        $r   = if ($i % 2 -eq 0) { 5.5 } else { 2.2 }
        $ang = ($i * 36 - 90) * [math]::PI / 180
        [System.Drawing.PointF]::new([float](32 + $r * [math]::Cos($ang)), [float](18 + $r * [math]::Sin($ang)))
    }
    $g.FillPolygon($yellow, $star)

    $g.FillEllipse($skin, 20, 32, 24, 17)
    $g.FillEllipse($black, 27, 36, 3, 3)
    $g.FillEllipse($black, 34, 36, 3, 3)
    $g.FillEllipse($nose, 29, 39, 6, 5)
    $g.FillPolygon($beard, @(
        [System.Drawing.PointF]::new(18, 44),
        [System.Drawing.PointF]::new(46, 44),
        [System.Drawing.PointF]::new(32, 63)))

    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $fs   = [System.IO.File]::Create($path)
    $icon.Save($fs)
    $fs.Close()
    $icon.Dispose(); $bmp.Dispose()
}

Write-Host "Generating icon..." -ForegroundColor Cyan
New-WizardIcon $IconPath

# --- Build the EXE (or fall back to ps1) -----------------------------------
$builtExe = $false
try {
    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        Write-Host "Installing ps2exe module (CurrentUser)..." -ForegroundColor Cyan
        Install-Module ps2exe -Scope CurrentUser -Force -ErrorAction Stop
    }
    Write-Host "Building ServerWizard.exe..." -ForegroundColor Cyan
    Invoke-ps2exe -InputFile $SourcePs1 -OutputFile $ExePath `
        -NoConsole -STA -IconFile $IconPath `
        -Title "Server Wizard" -Product "Server Wizard" -Version "1.5.1.0" -ErrorAction Stop
    $builtExe = Test-Path $ExePath
}
catch {
    Write-Warning "EXE build failed ($_). Falling back to .ps1 installation."
}

if (-not $builtExe) {
    Copy-Item -Path $SourcePs1 -Destination $Ps1Path -Force
}

# --- Shortcuts (Desktop + Start Menu) --------------------------------------
Write-Host "Creating shortcuts..." -ForegroundColor Cyan
$shell = New-Object -ComObject WScript.Shell
foreach ($lnkPath in @($DesktopLnk, $StartLnk)) {
    $lnk = $shell.CreateShortcut($lnkPath)
    if ($builtExe) {
        $lnk.TargetPath = $ExePath
        $lnk.Arguments  = ""
    }
    else {
        $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $lnk.Arguments  = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$Ps1Path`""
    }
    $lnk.WorkingDirectory = $AppDir
    $lnk.IconLocation     = $IconPath
    $lnk.Description      = "Server Wizard - Windows Server Inventory"
    $lnk.Save()
}

# --- Summary ---------------------------------------------------------------
Write-Host ""
Write-Host "=== Server Wizard installed ===" -ForegroundColor Green
Write-Host "  Location : $AppDir"
Write-Host "  Launcher : $(if ($builtExe) { 'ServerWizard.exe' } else { 'ServerWizard.ps1 (via PowerShell shortcut)' })"
Write-Host "  Shortcuts: Desktop + Start Menu ('Server Wizard')"
Write-Host "  Cache    : $InstallRoot (ScanCache.xml / GroupOverrides.xml)"
Write-Host ""
Write-Host "Launch it from the Start Menu or the desktop shortcut." -ForegroundColor Cyan
