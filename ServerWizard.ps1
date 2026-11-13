<#
 Server Wizard - read-only Windows Server inventory tool (WinForms GUI)
 See README.md for usage, requirements and the security model.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data
[System.Windows.Forms.Application]::EnableVisualStyles()

# Win32 helper for flicker-free rendering and scroll-to-top
Add-Type -Namespace SW -Name Native -MemberDefinition '
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);'

function Set-Redraw($ctrl, [bool]$on) {
    [void][SW.Native]::SendMessage($ctrl.Handle, 0x0B, [IntPtr]([int]$on), [IntPtr]::Zero)
    if ($on) { $ctrl.Invalidate() }
}
function Scroll-ToTop($box) {
    $box.SelectionStart = 0
    $box.SelectionLength = 0
    [void][SW.Native]::SendMessage($box.Handle, 0x115, [IntPtr]6, [IntPtr]::Zero)   # WM_VSCROLL, SB_TOP
}

# Enables the protected DoubleBuffered property to avoid repaint ghosting
function Set-DoubleBuffered($ctrl) {
    try {
        $prop = [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
        $prop.SetValue($ctrl, $true, $null)
    } catch {}
}

# --- Version ---------------------------------------------------------------
$script:AppVersion = '1.7.1'

# --- UI font: Open Sans if installed on this server, else Segoe UI ---------
$script:FontName = 'Segoe UI'
try {
    $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
    if ($installed -contains 'Open Sans') { $script:FontName = 'Open Sans' }
} catch {}

# --- Theme (dark) ------------------------------------------------------------
function New-Rgb([int]$r, [int]$g, [int]$b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }
$script:ThBg      = New-Rgb 30 31 34      # window / content
$script:ThPanel   = New-Rgb 39 41 45      # side panel, headers
$script:ThSurface = New-Rgb 52 55 60      # inputs, buttons
$script:ThAlt     = New-Rgb 35 36 40      # alternating grid rows
$script:ThLine    = New-Rgb 64 67 73
$script:ThSelect  = New-Rgb 45 70 120
$script:ThText    = New-Rgb 222 224 228
$script:ThMuted   = New-Rgb 150 156 166
$script:ThAccent  = New-Rgb 96 146 245
$script:ThOk      = New-Rgb 76 194 128
$script:ThWarn    = New-Rgb 242 170 60
$script:ThBad     = New-Rgb 240 90 90
# Names used throughout the UI code (kept for compatibility)
$script:MerlinBlue   = $script:ThAccent
$script:MerlinBlueLt = $script:ThPanel
$script:MerlinYellow = $script:ThSurface
$script:WarnOrange   = $script:ThWarn
$script:OkGreen      = $script:ThOk

# Native helpers: dark title bar / scrollbars (Windows 10 1809+) and a tab
# control that paints its whole strip (the stock one leaves it light grey).
# If compiling fails the app falls back to the stock controls.
$script:DarkNative = $false
try {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public static class SwDark {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string id);
    public static void TitleBar(IntPtr h) { int on = 1; if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4); }
    public static void Scrollbars(IntPtr h) { SetWindowTheme(h, "DarkMode_Explorer", null); }
}
public class SwTabControl : TabControl {
    public Color StripBack = Color.FromArgb(30, 31, 34), TabBack = Color.FromArgb(39, 41, 45), TabSel = Color.FromArgb(52, 55, 60);
    public Color Fore = Color.FromArgb(150, 156, 166), ForeSel = Color.FromArgb(222, 224, 228), Accent = Color.FromArgb(96, 146, 245);
    public Color CloseColor = Color.FromArgb(200, 110, 110), Line = Color.FromArgb(64, 67, 73);
    public string Pinned = "Home";
    public SwTabControl() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    public bool IsClosable(int i) { return i >= 0 && i < TabCount && TabPages[i].Text != Pinned; }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(StripBack);
        if (SelectedTab != null) {
            Rectangle d = DisplayRectangle; d.Inflate(1, 1);
            using (Pen p = new Pen(Line)) g.DrawRectangle(p, d);
        }
        for (int i = 0; i < TabCount; i++) {
            Rectangle r = GetTabRect(i);
            bool sel = (i == SelectedIndex);
            using (SolidBrush b = new SolidBrush(sel ? TabSel : TabBack)) g.FillRectangle(b, r);
            if (sel) using (SolidBrush a = new SolidBrush(Accent)) g.FillRectangle(a, r.Left, r.Bottom - 2, r.Width, 2);
            int w = IsClosable(i) ? r.Width - 22 : r.Width - 8;
            TextRenderer.DrawText(g, TabPages[i].Text, Font, new Rectangle(r.X + 6, r.Y, w, r.Height), sel ? ForeSel : Fore,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            if (IsClosable(i))
                TextRenderer.DrawText(g, "x", Font, new Rectangle(r.Right - 18, r.Y, 14, r.Height), CloseColor,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }
}
'@
    $script:DarkNative = $true
} catch { $script:DarkNativeError = $_.Exception.Message }


# --- Cache / override files (PER USER, so every account can use the app) ---
if (Test-Path 'D:\') { $script:CacheDir = "D:\Server Wizard\Cache\$env:USERNAME" }
else                 { $script:CacheDir = Join-Path $env:LOCALAPPDATA 'ServerWizard' }
$script:CacheFile    = Join-Path $script:CacheDir 'ScanCache.xml'
$script:OverrideFile = Join-Path $script:CacheDir 'GroupOverrides.xml'
$script:LogFile      = Join-Path $script:CacheDir 'ServerWizard.log'

# Restricts the cache folder to the current user only (DACL-only access,
# so it works without SeSecurityPrivilege, unlike Get-Acl/Set-Acl).
function Protect-CacheDir {
    try {
        $di  = New-Object System.IO.DirectoryInfo ($script:CacheDir)
        $acl = $di.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $acl.SetAccessRuleProtection($true, $false)   # drop inherited rules
        $me  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User   # SID of current user
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        $di.SetAccessControl($acl)
    } catch {
        try { Write-Log "Cache ACL protection failed: $($_.Exception.Message)" } catch {}
    }
}

# --- Logging ---------------------------------------------------------------
try {
    if (-not (Test-Path $script:CacheDir)) {
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
    }
    Protect-CacheDir   # enforced on EVERY start (also repairs unprotected dirs)
} catch {}

function Write-Log([string]$msg) {
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

Write-Log "=== Server Wizard v$($script:AppVersion) started (user: $env:USERNAME, host: $env:COMPUTERNAME, PS: $($PSVersionTable.PSVersion)) ==="

# Catch ALL unhandled UI exceptions -> log them instead of dying silently
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
        [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        Write-Log "UNHANDLED UI EXCEPTION: $($e.Exception.Message)`n$($e.Exception.StackTrace)"
    })
} catch { Write-Log "Could not attach global exception handler: $_" }

# --- Remote inventory (runs on each target) --------------------------------
$InventoryScriptBlock = {
    $result = [ordered]@{}
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem

    $result.ComputerName    = $env:COMPUTERNAME
    $result.OperatingSystem = "$($os.Caption) ($($os.Version), build $($os.BuildNumber))"
    $result.Domain          = $cs.Domain
    $result.InstallDate     = if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd HH:mm') } else { "N/A" }
    $result.LastRestartDate = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')

    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -ne '127.0.0.1' }
        $result.IPAddresses = ($ips.IPAddress -join '; ')
    } catch { $result.IPAddresses = "N/A" }

    try {
        $cpu = Get-CimInstance Win32_Processor
        $result.CPU          = ($cpu.Name | Select-Object -First 1)
        $result.LogicalCores = ($cpu.NumberOfLogicalProcessors | Measure-Object -Sum).Sum
        $result.TotalRAM_GB  = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
    } catch { $result.CPU = "N/A"; $result.LogicalCores = "N/A"; $result.TotalRAM_GB = "N/A" }

    try {
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
        $minPct = 100
        $diskInfo = foreach ($d in $disks) {
            $sizeGB  = [math]::Round($d.Size / 1GB, 2)
            $freeGB  = [math]::Round($d.FreeSpace / 1GB, 2)
            $pctFree = if ($d.Size -gt 0) { [math]::Round(($d.FreeSpace / $d.Size) * 100, 1) } else { 0 }
            if ($pctFree -lt $minPct) { $minPct = $pctFree }
            "$($d.DeviceID) ${sizeGB}GB total / ${freeGB}GB free (%$pctFree)"
        }
        $result.Disks       = ($diskInfo -join ' | ')
        $result.MinDiskFree = $minPct
    } catch { $result.Disks = "N/A"; $result.MinDiskFree = 100 }

    # Installed Windows Server roles / role services / features (queried ONCE,
    # reused by the legacy 'Roles' string and the structured v1.5 inventory)
    $installedFeatures = @()
    try {
        $installedFeatures = @(Get-WindowsFeature -ErrorAction Stop | Where-Object Installed)
        $result.Roles = ($installedFeatures.Name -join '; ')
    } catch { $result.Roles = "N/A" }

    # ONE service query, reused by Automatic / Database / 3rd party sections
    $allSvc = @()
    try { $allSvc = @(Get-CimInstance Win32_Service -ErrorAction Stop) } catch {}

    if ($allSvc.Count -gt 0) {
        $auto = $allSvc | Where-Object { $_.StartMode -eq 'Auto' }
        $result.AutomaticServices = (($auto | ForEach-Object { "$($_.DisplayName) [$($_.State)]" }) -join '; ')
    } else { $result.AutomaticServices = "N/A" }

    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624 } -MaxEvents 200 -ErrorAction Stop |
            Where-Object { $_.Properties[8].Value -eq 10 } | Select-Object -First 5
        $rdp = foreach ($e in $events) {
            "$($e.TimeCreated.ToString('yyyy-MM-dd HH:mm')) - $($e.Properties[5].Value) ($($e.Properties[18].Value))"
        }
        $result.LastRDPLogons = if ($rdp) { $rdp -join ' | ' } else { "No records" }
    } catch { $result.LastRDPLogons = "N/A" }

    # IIS: sites, DNS names, modules, SSL bindings
    $bindMap = @{}   # certificate thumbprint -> IIS bindings using it (v1.5 cert report)
    $sites   = @()
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $sites    = Get-Website
        $dnsNames = @()
        $siteInfo = foreach ($s in $sites) {
            $bindings = foreach ($b in $s.bindings.Collection) {
                $parts = "$($b.bindingInformation)" -split ':'
                if ($parts.Count -ge 3 -and $parts[2]) { $dnsNames += $parts[2] }
                "$($b.protocol)/$($b.bindingInformation)"
            }
            "$($s.Name) [$($s.State)] Bindings: $($bindings -join ', ') Path: $($s.PhysicalPath)"
        }
        $result.Websites     = if ($siteInfo) { $siteInfo -join ' || ' } else { "No sites" }
        $result.SiteDNSNames = if ($dnsNames) { ($dnsNames | Sort-Object -Unique) -join '; ' } else { "None" }

        try { $result.IISModules = ((Get-WebGlobalModule).Name -join '; ') } catch { $result.IISModules = "N/A" }

        $ssl = @()
        foreach ($b in (Get-WebBinding -Protocol https -ErrorAction SilentlyContinue)) {
            $thumb = "$($b.certificateHash)".Trim()
            $store = if ($b.certificateStoreName) { $b.certificateStoreName } else { 'My' }
            $cert  = if ($thumb) { Get-Item "cert:\LocalMachine\$store\$thumb" -ErrorAction SilentlyContinue }
            if ($thumb) {
                $siteName = if ("$($b.ItemXPath)" -match "@name='([^']+)'") { $matches[1] } else { '?' }
                $tk = $thumb.ToUpper()
                if (-not $bindMap.ContainsKey($tk)) { $bindMap[$tk] = @() }
                $bindMap[$tk] += "IIS: $siteName ($($b.bindingInformation))"
            }
            $ssl += [PSCustomObject]@{
                Info      = $b.bindingInformation
                Subject   = if ($cert) { $cert.Subject } else { '(certificate not found)' }
                NotBefore = if ($cert) { $cert.NotBefore } else { [datetime]::MinValue }
                NotAfter  = if ($cert) { $cert.NotAfter }  else { [datetime]::MinValue }
            }
        }
        $result.SSLBindings = if ($ssl) {
            ($ssl | Sort-Object NotBefore -Descending | ForEach-Object {
                $issued  = if ($_.NotBefore -ne [datetime]::MinValue) { $_.NotBefore.ToString('yyyy-MM-dd') } else { '?' }
                $expires = if ($_.NotAfter  -ne [datetime]::MinValue) { $_.NotAfter.ToString('yyyy-MM-dd') }  else { '?' }
                "$($_.Info) -> $($_.Subject) (issued: $issued, expires: $expires)"
            }) -join ' ;; '
        } else { "None" }
    }
    catch {
        $result.Websites = "N/A (IIS not installed)"; $result.SiteDNSNames = "N/A"
        $result.IISModules = "N/A"; $result.SSLBindings = "N/A"
    }

    try {
        $ports = Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Select-Object -ExpandProperty LocalPort -Unique | Sort-Object
        $result.ListeningPorts = ($ports -join ', ')
    } catch { $result.ListeningPorts = "N/A" }

    # SQL instances with edition/version details
    try {
        $instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction Stop).InstalledInstances
        if ($instances) {
            $map = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
            $details = foreach ($i in $instances) {
                $id    = if ($map) { $map.$i } else { $null }
                $setup = if ($id) { Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\Setup" -ErrorAction SilentlyContinue }
                if ($setup) { "$i -> Edition: $($setup.Edition), Version: $($setup.Version), Path: $($setup.SQLPath)" }
                else        { "$i -> (details not readable)" }
            }
            $result.SQLInstanceDetails = $details -join ' | '
        } else { $result.SQLInstanceDetails = "None" }
    } catch { $result.SQLInstanceDetails = "None" }

    $dbPattern = 'SQL|MySQL|Postgre|Mongo|Oracle|Redis|MariaDB'
    if ($allSvc.Count -gt 0) {
        $dbSvc = $allSvc | Where-Object { $_.DisplayName -match $dbPattern }
        $result.DatabaseServices = if ($dbSvc) {
            ($dbSvc | ForEach-Object { "$($_.DisplayName) [$($_.State)]" }) -join '; '
        } else { "None" }
    } else { $result.DatabaseServices = "N/A" }

    # Installed software: Microsoft vs 3rd party
    $msProducts = @(); $tpProducts = @(); $apps = @()
    try {
        $apps = Get-ItemProperty @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and ($_.SystemComponent -ne 1) } |
            Sort-Object DisplayName -Unique
        foreach ($a in $apps) {
            $entry = if ($a.DisplayVersion) { "$($a.DisplayName) [$($a.DisplayVersion)]" } else { $a.DisplayName }
            if ($a.Publisher -match 'Microsoft') { $msProducts += $entry }
            else { $tpProducts += "$entry ($(if ($a.Publisher) { $a.Publisher } else { 'Unknown' }))" }
        }
    } catch {}
    try {
        $netfx = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        $msProducts += ".NET Framework [$($netfx.Version)]"
    } catch {}
    try {
        $rt = & dotnet --list-runtimes 2>$null
        if ($rt) { $msProducts += ($rt | ForEach-Object { ($_ -split ' \[')[0] } | Sort-Object -Unique) }
    } catch {}
    try { $v = & java -version 2>&1 | Select-Object -First 1; if ($v -and $v -notmatch 'not recognized') { $tpProducts += "Java runtime: $v" } } catch {}
    try { $v = & python --version 2>&1; if ($v -and $v -notmatch 'not recognized') { $tpProducts += "$v" } } catch {}
    try { $v = & node --version 2>&1; if ($v -and $v -notmatch 'not recognized') { $tpProducts += "Node.js: $v" } } catch {}

    $result.MicrosoftProducts  = if ($msProducts) { ($msProducts | Sort-Object -Unique) -join '; ' } else { "None detected" }
    $result.ThirdPartyProducts = if ($tpProducts) { ($tpProducts | Sort-Object -Unique) -join '; ' } else { "None detected" }

    if ($allSvc.Count -gt 0) {
        $svcs = $allSvc | Where-Object {
            $_.PathName -and $_.PathName -notmatch '\\Windows\\' -and $_.State -eq 'Running'
        }
        $result.ThirdPartyServices = if ($svcs) {
            (($svcs | ForEach-Object { "$($_.DisplayName) [$($_.StartName)]" }) -join '; ')
        } else { "None" }
    } else { $result.ThirdPartyServices = "N/A" }

    # ======================================================================
    # v1.5 structured inventory: OS, roles/features, IIS, database products,
    # certificates. Serialised to ONE JSON string so it survives remoting and
    # the plain-string cache unchanged. Still strictly read-only.
    # ======================================================================
    $inv = [ordered]@{ SchemaVersion = 2; CollectedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm') }

    function ConvertTo-IsoDay($d) {
        if ($d -is [datetime] -and $d -gt [datetime]'1980-01-01') { return $d.ToString('yyyy-MM-dd') }
        return $null
    }
    function ConvertFrom-UninstallDate([string]$s) {
        # Uninstall\InstallDate is a yyyyMMdd string (sometimes with junk)
        if ("$s" -match '^\s*(\d{4})(\d{2})(\d{2})') {
            try { return (New-Object DateTime -ArgumentList ([int]$matches[1]), ([int]$matches[2]), ([int]$matches[3])).ToString('yyyy-MM-dd') } catch {}
        }
        return $null
    }
    function Get-ServiceExePath([string]$pathName) {
        if (-not $pathName) { return $null }
        if ($pathName -match '^\s*"([^"]+)"') { return $matches[1] }
        if ($pathName -match '^\s*(.+?\.exe)(\s|$)') { return $matches[1] }
        return $null
    }
    function Get-VersionNumber([string]$s) {
        if ("$s" -match '(\d+(\.\d+)+)') { return $matches[1] }
        return $null
    }

    # --- OS --------------------------------------------------------------
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $inv.OS = [ordered]@{
            Caption          = "$($os.Caption)".Trim()
            Version          = "$($os.Version)"
            Build            = [int]$os.BuildNumber
            UBR              = if ($cv) { "$($cv.UBR)" } else { $null }
            DisplayVersion   = if ($cv) { "$($cv.DisplayVersion)" } else { $null }
            EditionID        = if ($cv) { "$($cv.EditionID)" } else { $null }
            InstallationType = if ($cv) { "$($cv.InstallationType)" } else { $null }
            InstallDate      = ConvertTo-IsoDay $os.InstallDate
            LastBoot         = ConvertTo-IsoDay $os.LastBootUpTime
        }
    } catch { $inv.OS = [ordered]@{ Caption = "$($os.Caption)"; Build = 0; Error = "$($_.Exception.Message)" } }

    # --- Windows Server roles, role services and features ------------------
    $inv.Features = @(foreach ($f in $installedFeatures) {
        [ordered]@{
            Name        = "$($f.Name)"
            DisplayName = "$($f.DisplayName)"
            Type        = "$($f.FeatureType)"     # Role | Role Service | Feature
            Parent      = "$($f.Parent)"
            Depth       = [int]$f.Depth
        }
    })

    # --- IIS version (registry InetStp is the authoritative source) --------
    $inv.IIS = $null
    try {
        $stp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp' -ErrorAction Stop
        $iisInstall = $null
        try {
            $wwwRoot = [Environment]::ExpandEnvironmentVariables("$($stp.PathWWWRoot)")
            if ($wwwRoot) {
                $inetpub = Split-Path $wwwRoot -Parent
                if ($inetpub -and (Test-Path -LiteralPath $inetpub)) { $iisInstall = ConvertTo-IsoDay (Get-Item -LiteralPath $inetpub).CreationTime }
            }
        } catch {}
        $inv.IIS = [ordered]@{
            Version           = "$($stp.MajorVersion).$($stp.MinorVersion)"
            SetupString       = "$($stp.SetupString)"
            VersionString     = "$($stp.VersionString)"
            InstallDate       = $iisInstall
            InstallDateSource = 'inetpub folder creation time (approx.)'
            SiteCount         = @($sites).Count
            Sites             = @(foreach ($s in @($sites)) { "$($s.Name) [$($s.State)]" })
        }
    } catch {}

    # --- Database products (MSSQL + 3rd party engines) ---------------------
    $uninstall = @($apps)
    $products  = New-Object System.Collections.ArrayList

    try {
        $sqlRoot   = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
        $instances = (Get-ItemProperty $sqlRoot -ErrorAction Stop).InstalledInstances
        $map       = Get-ItemProperty "$sqlRoot\Instance Names\SQL" -ErrorAction SilentlyContinue
        foreach ($i in @($instances)) {
            $id    = if ($map) { $map.$i } else { $null }
            $setup = if ($id) { Get-ItemProperty "$sqlRoot\$id\Setup" -ErrorAction SilentlyContinue } else { $null }
            $svcName = if ($i -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$i" }
            $svc     = $allSvc | Where-Object { $_.Name -eq $svcName } | Select-Object -First 1
            $instDate = $null
            try {
                $binRoot = if ($setup -and $setup.SQLBinRoot) { "$($setup.SQLBinRoot)" } elseif ($setup) { "$($setup.SQLPath)" } else { $null }
                if ($binRoot -and (Test-Path -LiteralPath $binRoot)) { $instDate = ConvertTo-IsoDay (Get-Item -LiteralPath $binRoot).CreationTime }
            } catch {}
            [void]$products.Add([ordered]@{
                Product           = 'Microsoft SQL Server'
                Instance          = "$i"
                Edition           = if ($setup) { "$($setup.Edition)" } else { $null }
                Version           = if ($setup -and $setup.PatchLevel) { "$($setup.PatchLevel)" } elseif ($setup) { "$($setup.Version)" } else { $null }
                ServicePack       = if ($setup -and $null -ne $setup.SP) { [int]$setup.SP } else { $null }
                InstallDate       = $instDate
                InstallDateSource = 'instance Binn folder creation time'
                ServiceState      = if ($svc) { "$($svc.State)" } else { 'No service' }
                Path              = if ($setup) { "$($setup.SQLPath)" } else { $null }
            })
        }
    } catch {}

    $dbRules = @(
        @{ Product = 'MariaDB';         Uninstall = '^MariaDB\s+\d';                Exe = '^mariadbd\.exe$' },
        @{ Product = 'MySQL';           Uninstall = '^MySQL Server\s+\d';           Exe = '^mysqld(-nt)?\.exe$' },
        @{ Product = 'PostgreSQL';      Uninstall = '^PostgreSQL\s+\d';             Exe = '^(postgres|pg_ctl)\.exe$' },
        @{ Product = 'Firebird';        Uninstall = '^Firebird\s+\d';               Exe = '^(firebird|fbserver|fb_inet_server|fb_smp_server)\.exe$' },
        @{ Product = 'MongoDB';         Uninstall = '^MongoDB(\s+\d|\s+Server)';    Exe = '^mongod\.exe$' },
        @{ Product = 'Oracle Database'; Uninstall = '^Oracle Database';            Exe = '^oracle\.exe$' },
        @{ Product = 'Redis';           Uninstall = '^Redis(\s|$)';                 Exe = '^redis-server\.exe$' }
    )
    $usedUninstall = @{}

    # 1) Running/installed database SERVICES -> real binary version
    foreach ($svc in $allSvc) {
        $exe = Get-ServiceExePath "$($svc.PathName)"
        if (-not $exe) { continue }
        $leaf = [IO.Path]::GetFileName($exe)
        $rule = $dbRules | Where-Object { $leaf -match $_.Exe } | Select-Object -First 1
        if (-not $rule) { continue }

        $fileVer = $null; $created = $null; $prodName = ''
        try {
            $fi = Get-Item -LiteralPath $exe -ErrorAction Stop
            $fileVer  = Get-VersionNumber "$($fi.VersionInfo.ProductVersion)"
            if (-not $fileVer) { $fileVer = Get-VersionNumber "$($fi.VersionInfo.FileVersion)" }
            $prodName = "$($fi.VersionInfo.ProductName)"
            $created  = ConvertTo-IsoDay $fi.CreationTime
        } catch {}

        $product = $rule.Product
        # MariaDB < 10.5 ships mysqld.exe: tell it apart from Oracle MySQL
        if ($product -eq 'MySQL' -and ($exe -match 'MariaDB' -or $prodName -match 'MariaDB')) {
            $product = 'MariaDB'
            $rule    = $dbRules | Where-Object { $_.Product -eq 'MariaDB' } | Select-Object -First 1
        }

        # Matching uninstall entry (install date / display version)
        $u = $uninstall | Where-Object {
            $_.DisplayName -match $rule.Uninstall -and
            ((-not $_.InstallLocation) -or $exe.StartsWith("$($_.InstallLocation)".TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase))
        } | Select-Object -First 1
        if ($u) { $usedUninstall["$($u.PSChildName)"] = $true }

        $udate = if ($u) { ConvertFrom-UninstallDate "$($u.InstallDate)" } else { $null }
        [void]$products.Add([ordered]@{
            Product           = $product
            Instance          = "$($svc.Name)"
            Edition           = if ($u) { "$($u.DisplayName)" } else { $prodName }
            Version           = if ($fileVer) { $fileVer } elseif ($u) { Get-VersionNumber "$($u.DisplayVersion)" } else { $null }
            ServicePack       = $null
            InstallDate       = if ($udate) { $udate } else { $created }
            InstallDateSource = if ($udate) { 'Windows uninstall registry' } else { 'binary creation time (approx.)' }
            ServiceState      = "$($svc.State) / $($svc.StartMode)"
            Path              = $exe
        })
    }

    # 2) Installed packages without a service (stopped/removed services, clients)
    foreach ($u in $uninstall) {
        if ($usedUninstall.ContainsKey("$($u.PSChildName)")) { continue }
        $rule = $dbRules | Where-Object { "$($u.DisplayName)" -match $_.Uninstall } | Select-Object -First 1
        if (-not $rule) { continue }
        [void]$products.Add([ordered]@{
            Product           = $rule.Product
            Instance          = '(no service)'
            Edition           = "$($u.DisplayName)"
            Version           = Get-VersionNumber "$($u.DisplayVersion)"
            ServicePack       = $null
            InstallDate       = ConvertFrom-UninstallDate "$($u.InstallDate)"
            InstallDateSource = 'Windows uninstall registry'
            ServiceState      = 'No service'
            Path              = "$($u.InstallLocation)"
        })
    }
    $inv.Databases = @($products)

    # --- Certificates (LocalMachine\My + WebHosting) -----------------------
    $certs = New-Object System.Collections.ArrayList
    foreach ($storeName in 'My', 'WebHosting') {
        try {
            foreach ($c in @(Get-ChildItem "Cert:\LocalMachine\$storeName" -ErrorAction Stop | Where-Object { -not $_.PSIsContainer })) {
                $dns = @()
                try { $dns = @($c.DnsNameList | ForEach-Object { "$($_.Unicode)" } | Where-Object { $_ }) } catch {}
                $tk = "$($c.Thumbprint)".ToUpper()
                [void]$certs.Add([ordered]@{
                    Store         = $storeName
                    Subject       = "$($c.Subject)"
                    FriendlyName  = "$($c.FriendlyName)"
                    Issuer        = "$($c.Issuer)"
                    Thumbprint    = $tk
                    NotBefore     = $c.NotBefore.ToString('yyyy-MM-dd HH:mm')
                    NotAfter      = $c.NotAfter.ToString('yyyy-MM-dd HH:mm')
                    DnsNames      = @($dns)
                    HasPrivateKey = [bool]$c.HasPrivateKey
                    SelfSigned    = ("$($c.Subject)" -eq "$($c.Issuer)")
                    BoundTo       = @(if ($bindMap.ContainsKey($tk)) { $bindMap[$tk] })
                })
            }
        } catch {}
    }
    $inv.Certificates = @($certs)

    try   { $result.Inventory = ($inv | ConvertTo-Json -Depth 6 -Compress) }
    catch { $result.Inventory = '' }

    [PSCustomObject]$result
}

# --- Field definitions (drive detail tabs + CSV export + search) -----------
# Derived = $true: computed locally from the structured inventory and the
# official lifecycle sources (not collected on the target).
$script:FieldDefs = @(
    @{ Name='OperatingSystem';    Section='General';             Label='Operating System';            Sep=$null  },
    @{ Name='Domain';             Section='General';             Label='Domain';                      Sep=$null  },
    @{ Name='InstallDate';        Section='General';             Label='OS Install Date';             Sep=$null  },
    @{ Name='LastRestartDate';    Section='General';             Label='Last Restart Date';           Sep=$null  },
    @{ Name='OSLifecycle';        Section='General';             Label='OS Support / EOL (official)'; Sep=' ;; '; Derived=$true },
    @{ Name='IPAddresses';        Section='Network';             Label='IP Addresses';                Sep='; '   },
    @{ Name='ListeningPorts';     Section='Network';             Label='Listening TCP Ports';         Sep=', '   },
    @{ Name='CPU';                Section='Hardware';            Label='CPU';                         Sep=$null  },
    @{ Name='LogicalCores';       Section='Hardware';            Label='Logical Cores';               Sep=$null  },
    @{ Name='TotalRAM_GB';        Section='Hardware';            Label='Total RAM (GB)';              Sep=$null  },
    @{ Name='Disks';              Section='Disks';               Label='Disks';                       Sep=' | '  },
    @{ Name='RoleGroupsText';     Section='Roles & Features';    Label='Detected Role Groups (with evidence)'; Sep='; '; Derived=$true },
    @{ Name='RolesDetail';        Section='Roles & Features';    Label='Windows Server Roles & Role Services'; Sep=' ;; '; Derived=$true },
    @{ Name='FeaturesDetail';     Section='Roles & Features';    Label='Windows Server Features';     Sep=' ;; '; Derived=$true },
    @{ Name='Roles';              Section='Roles & Features';    Label='Installed Roles';             Sep='; '   },
    @{ Name='AutomaticServices';  Section='Windows Services';    Label='Automatic Services';          Sep='; '   },
    @{ Name='LastRDPLogons';      Section='RDP Logons';          Label='Last RDP Logons';             Sep=' | '  },
    @{ Name='IISVersionInfo';     Section='IIS / Web';           Label='IIS Version & Lifecycle (official)'; Sep=' ;; '; Derived=$true },
    @{ Name='Websites';           Section='IIS / Web';           Label='IIS Websites';                Sep=' || ' },
    @{ Name='SiteDNSNames';       Section='IIS / Web';           Label='Site DNS Names';              Sep='; '   },
    @{ Name='IISModules';         Section='IIS / Web';           Label='IIS Modules (extensions)';    Sep='; '   },
    @{ Name='SSLBindings';        Section='IIS / Web';           Label='SSL Bindings (newest first)'; Sep=' ;; ' },
    @{ Name='CertificateSummary'; Section='SSL Certificates';    Label='Certificates (soonest expiry first)'; Sep=' ;; '; Derived=$true },
    @{ Name='DatabaseProducts';   Section='Database';            Label='Database Products (version / install / support)'; Sep=' ;; '; Derived=$true },
    @{ Name='SQLInstanceDetails'; Section='Database';            Label='SQL Instances (detailed)';    Sep=' | '  },
    @{ Name='DatabaseServices';   Section='Database';            Label='Database Services';           Sep='; '   },
    @{ Name='MicrosoftProducts';  Section='Microsoft Products';  Label='Microsoft Products & Versions'; Sep='; ' },
    @{ Name='ThirdPartyProducts'; Section='3rd Party Products';  Label='3rd Party Software & Versions'; Sep='; ' },
    @{ Name='ThirdPartyServices'; Section='3rd Party Services';  Label='Running 3rd Party Services';    Sep='; ' }
)

# --- Role groups -------------------------------------------------------------
# A server is placed in EVERY group whose rule matches (multi-role servers
# appear in several lists). Features = Get-WindowsFeature names (role or role
# service); Services = regex on running 3rd party service names.
$script:RoleDefs = @(
    @{ Group = 'Domain Controllers';       Features = @('AD-Domain-Services') },
    @{ Group = 'SQL / Database';           Features = @() },   # detected from database products
    @{ Group = 'IIS / Web';                Features = @('Web-Server') },
    @{ Group = 'DNS Server';               Features = @('DNS') },
    @{ Group = 'DHCP Server';              Features = @('DHCP') },
    @{ Group = 'Certificate Services';     Features = @('AD-Certificate', 'ADCS-Cert-Authority') },
    @{ Group = 'Federation Services';      Features = @('ADFS-Federation') },
    @{ Group = 'Remote Desktop Services';  Features = @('Remote-Desktop-Services', 'RDS-RD-Server', 'RDS-Connection-Broker', 'RDS-Gateway', 'RDS-Web-Access', 'RDS-Licensing') },
    @{ Group = 'Hyper-V';                  Features = @('Hyper-V') },
    @{ Group = 'File Services / DFS';      Features = @('FS-DFS-Namespace', 'FS-DFS-Replication', 'FS-Resource-Manager') },
    @{ Group = 'Print Services';           Features = @('Print-Services', 'Print-Server') },
    @{ Group = 'WSUS';                     Features = @('UpdateServices') },
    @{ Group = 'Deployment Services';      Features = @('WDS') },
    @{ Group = 'Network Policy / Remote Access'; Features = @('NPAS', 'RemoteAccess') },
    @{ Group = 'Failover Cluster';         Features = @('Failover-Clustering') },
    @{ Group = 'Exchange';                 Features = @(); Services = 'MSExchange|Microsoft Exchange' }
)
$script:RoleGroups = @($script:RoleDefs | ForEach-Object { $_.Group }) + @('3rd Party', 'Other')
$script:GroupOrder = $script:RoleGroups + @('Not Scanned / Unreachable')

# Parses (once) and returns the structured v1.5 inventory of a result, or $null
# for results cached by v1.4 (those fall back to the legacy string fields).
function Get-Inv($r) {
    if (-not $r) { return $null }
    $p = $r.PSObject.Properties['__Inv']
    if ($p) { return $p.Value }
    $inv = $null
    $raw = $r.PSObject.Properties['Inventory']
    if ($raw -and "$($raw.Value)".TrimStart().StartsWith('{')) {
        try { $inv = "$($raw.Value)" | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Log "Inventory JSON parse failed for $($r.ComputerName): $($_.Exception.Message)" }
    }
    try { $r | Add-Member -NotePropertyName '__Inv' -NotePropertyValue $inv -Force } catch {}
    return $inv
}

# Classification with evidence: returns one @{ Group; Reason } per matched
# group, so every placement can be verified in the server tab and reports.
function Get-RoleGroupDetails($r) {
    $out      = New-Object System.Collections.Generic.List[object]
    $inv      = Get-Inv $r
    $featObjs = @()
    if ($inv -and $inv.Features) { $featObjs = @($inv.Features | Where-Object { $_ }) }
    $features = if ($featObjs) { @($featObjs | ForEach-Object { "$($_.Name)" }) }
                else { @("$($r.Roles)" -split ';\s*' | Where-Object { $_ -and $_ -ne 'N/A' }) }
    $tpSvc = "$($r.ThirdPartyServices)"

    foreach ($def in $script:RoleDefs) {
        $reason = $null
        $hitF = @($def.Features | Where-Object { $features -contains $_ })
        if ($hitF) {
            $names = foreach ($f in $hitF) {
                $o = $featObjs | Where-Object { $_.Name -eq $f } | Select-Object -First 1
                if ($o) { "$($o.DisplayName) [$f]" } else { $f }
            }
            $reason = "Windows role: $($names -join ', ')"
        }
        if (-not $reason -and $def.Services -and $tpSvc -match $def.Services) { $reason = "Service matches '$($def.Services)'" }
        if (-not $reason -and $def.Group -eq 'SQL / Database') {
            if ($inv) {
                # Only real database SERVERS: an engine with a service/instance.
                # Client tools / drivers without a service do not classify.
                $engines = @($inv.Databases | Where-Object { $_ -and "$($_.Instance)" -ne '(no service)' })
                if ($engines) {
                    $reason = 'Database engine: ' + (($engines | ForEach-Object { "$($_.Product) $($_.Version) [$($_.Instance)]" }) -join ', ')
                }
            }
            else {
                $sql = "$($r.SQLInstanceDetails)"
                if (($sql -and $sql -notin 'None', 'N/A') -or "$($r.DatabaseServices)" -match 'SQL Server \(') { $reason = "SQL instance (v1.4 data): $sql" }
            }
        }
        if (-not $reason -and $def.Group -eq 'IIS / Web' -and "$($r.Websites)" -and "$($r.Websites)" -notmatch '^(N/A|No sites)') { $reason = 'IIS websites present' }
        if ($reason) { $out.Add([PSCustomObject]@{ Group = $def.Group; Reason = $reason }) }
    }
    if ($out.Count -eq 0) {
        if ($tpSvc -and $tpSvc -notin 'None', 'N/A') { $out.Add([PSCustomObject]@{ Group = '3rd Party'; Reason = 'No Microsoft server role; running 3rd party services' }) }
        else { $out.Add([PSCustomObject]@{ Group = 'Other'; Reason = 'No server role or 3rd party service detected' }) }
    }
    return $out.ToArray()
}

function Get-RoleGroups($r) {
    return @(Get-RoleGroupDetails $r | ForEach-Object { $_.Group })    # enumerated: callers wrap with @()
}

# Backward compatible single "primary" group (first match in display order)
function Get-RoleGroup($r) { return @(Get-RoleGroups $r)[0] }

# --- Global state ----------------------------------------------------------
$script:ScanJob      = $null
$script:Results      = @{}    # UPPERCASE name -> result
$script:Overrides    = @{}    # UPPERCASE name -> manually chosen group
$script:TreeUpdating = $false
$script:CtxTarget    = $null
$script:AllCategories   = 'All categories'
$script:SearchScope     = $script:AllCategories
$script:LastSearchQuery = ''
$script:LastSearchRows  = @()

# All groups a server belongs to. A manual override pins it to ONE group.
function Get-EffectiveGroups([string]$key, $r) {
    if ($script:Overrides.ContainsKey($key)) { return [string]$script:Overrides[$key] }
    if ($r) { return @(Get-RoleGroups $r) }
    return 'Not Scanned / Unreachable'
}

# Display / export text of the groups ("IIS / Web, SQL / Database")
function Get-EffectiveGroup([string]$key, $r) {
    return (@(Get-EffectiveGroups $key $r) -join ', ')
}

# Stores results as plain strings (no PS remoting metadata) and writes
# atomically (temp file + move) so a crash never corrupts the cache.
function Save-Cache {
    try {
        if (-not (Test-Path $script:CacheDir)) {
            New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
            Protect-CacheDir
        }
        $slim = foreach ($key in $script:Results.Keys) {
            $r = $script:Results[$key]
            $h = @{ __Key = $key; ComputerName = "$($r.ComputerName)"; MinDiskFree = "$($r.MinDiskFree)" }
            $ip = $r.PSObject.Properties['Inventory']
            if ($ip) { $h['Inventory'] = "$($ip.Value)" }
            foreach ($def in $script:FieldDefs) {
                $p = $r.PSObject.Properties[$def.Name]
                if ($p) { $h[$def.Name] = "$($p.Value)" }
            }
            $h
        }
        # Clear attributes before deleting/replacing so a locked or
        # read-only destination doesn't fail the atomic move.
        $tmp = "$($script:CacheFile).tmp"
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
        @($slim) | Export-Clixml -Path $tmp
        if (Test-Path $script:CacheFile) {
            Set-ItemProperty -Path $script:CacheFile -Name Attributes -Value 'Normal' -ErrorAction SilentlyContinue
            Remove-Item -Path $script:CacheFile -Force -ErrorAction Stop
        }
        Move-Item -Path $tmp -Destination $script:CacheFile -Force
        $script:Overrides | Export-Clixml -Path $script:OverrideFile -Force
        return $true
    } catch { Write-Log "CACHE SAVE FAILED: $($_.Exception.Message)"; return $false }
}

function Load-Cache {
    if (Test-Path $script:OverrideFile) {
        try {
            $o = Import-Clixml -Path $script:OverrideFile
            if ($o -is [hashtable]) { $script:Overrides = $o }
        } catch {}
    }
    if (-not (Test-Path $script:CacheFile)) { return $false }
    try {
        foreach ($h in @(Import-Clixml -Path $script:CacheFile)) {
            if (-not $h) { continue }
            $key = "$(if ($h.__Key) { $h.__Key } else { $h.ComputerName })".ToUpper()
            if ($key) { $script:Results[$key] = [PSCustomObject]$h }
        }
        return ($script:Results.Keys.Count -gt 0)
    } catch { return $false }
}

# ============================================================================
# Lifecycle module: support / EOL dates from OFFICIAL vendor sources only.
# - HTTPS GET to an allow-list of vendor hosts, nothing is ever sent except
#   the public product page URL (no inventory data leaves the network).
# - Pages are fetched fresh on every scan / report (session cache only); the
#   last good copy is kept on disk and used ONLY when the site is unreachable,
#   and is then clearly marked as an offline copy with its retrieval date.
# ============================================================================
$script:OfficialHosts = @('learn.microsoft.com', 'downloads.mariadb.org', 'www.postgresql.org',
                          'www.mysql.com', 'www.firebirdsql.org', 'firebirdsql.org')
$script:OfficialPageCache = @{}    # url -> page entry (this refresh only)
$script:OfficialDiskCache = @{}    # url -> @{ Content; Retrieved } (offline fallback)
$script:OfficialDiskDirty = $false
$script:OfficialCacheFile = Join-Path $script:CacheDir 'OfficialSources.xml'
$script:Lifecycle         = @{}    # lookup key -> lifecycle object
$script:LifecycleRefreshed = $null

$script:MsLifecycleBase = 'https://learn.microsoft.com/en-us/lifecycle/products/'
$script:WinServerBuilds = @{
    26100 = @{ Slug = 'windows-server-2025';    Name = 'Windows Server 2025' }
    20348 = @{ Slug = 'windows-server-2022';    Name = 'Windows Server 2022' }
    17763 = @{ Slug = 'windows-server-2019';    Name = 'Windows Server 2019' }
    14393 = @{ Slug = 'windows-server-2016';    Name = 'Windows Server 2016' }
    9600  = @{ Slug = 'windows-server-2012-r2'; Name = 'Windows Server 2012 R2' }
    9200  = @{ Slug = 'windows-server-2012';    Name = 'Windows Server 2012' }
    7601  = @{ Slug = 'windows-server-2008-r2'; Name = 'Windows Server 2008 R2' }
    7600  = @{ Slug = 'windows-server-2008-r2'; Name = 'Windows Server 2008 R2' }
    6003  = @{ Slug = 'windows-server-2008';    Name = 'Windows Server 2008' }
    6002  = @{ Slug = 'windows-server-2008';    Name = 'Windows Server 2008' }
}
$script:SqlMajors = @{
    '17'    = @{ Slug = 'sql-server-2025';               Name = 'SQL Server 2025' }
    '16'    = @{ Slug = 'sql-server-2022';               Name = 'SQL Server 2022' }
    '15'    = @{ Slug = 'sql-server-2019';               Name = 'SQL Server 2019' }
    '14'    = @{ Slug = 'sql-server-2017';               Name = 'SQL Server 2017' }
    '13'    = @{ Slug = 'sql-server-2016';               Name = 'SQL Server 2016' }
    '12'    = @{ Slug = 'sql-server-2014';               Name = 'SQL Server 2014' }
    '11'    = @{ Slug = 'microsoft-sql-server-2012';     Name = 'SQL Server 2012' }
    '10.50' = @{ Slug = 'microsoft-sql-server-2008-r2';  Name = 'SQL Server 2008 R2' }
    '10.0'  = @{ Slug = 'microsoft-sql-server-2008';     Name = 'SQL Server 2008' }
}

function Load-OfficialDiskCache {
    try {
        if (Test-Path $script:OfficialCacheFile) {
            $o = Import-Clixml -Path $script:OfficialCacheFile
            if ($o -is [hashtable]) { $script:OfficialDiskCache = $o }
        }
    } catch { Write-Log "Official source cache unreadable: $($_.Exception.Message)" }
}

function Save-OfficialDiskCache {
    if (-not $script:OfficialDiskDirty) { return }
    try {
        $tmp = "$($script:OfficialCacheFile).tmp"
        $script:OfficialDiskCache | Export-Clixml -Path $tmp -Force
        Move-Item -Path $tmp -Destination $script:OfficialCacheFile -Force
        $script:OfficialDiskDirty = $false
    } catch { Write-Log "Official source cache save failed: $($_.Exception.Message)" }
}

# Fetches one official page (HTTPS, allow-listed host, also after redirects).
# Returns @{ Url; Content; Retrieved; Offline } or $null.
function Invoke-OfficialSourceGet([string]$url) {
    if ($script:OfficialPageCache.ContainsKey($url)) { return $script:OfficialPageCache[$url] }
    $entry = $null
    try {
        $uri = [Uri]$url
        if ($uri.Scheme -ne 'https' -or $script:OfficialHosts -notcontains $uri.Host) {
            throw "Blocked: '$($uri.Host)' is not an allow-listed official source."
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create($uri)
        $req.Method                 = 'GET'
        $req.Timeout                = 20000
        $req.ReadWriteTimeout       = 20000
        $req.UserAgent              = "ServerWizard/$($script:AppVersion) (lifecycle lookup)"
        $req.Accept                 = 'text/html,application/json'
        $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        $req.MaximumAutomaticRedirections = 5
        $proxy = [Net.WebRequest]::GetSystemWebProxy()
        $proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
        $req.Proxy = $proxy

        $resp = $req.GetResponse()
        try {
            if ($script:OfficialHosts -notcontains $resp.ResponseUri.Host) {
                throw "Blocked: redirected to non-official host '$($resp.ResponseUri.Host)'."
            }
            $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $resp.Close() }

        $now   = Get-Date
        $entry = @{ Url = $url; Content = $content; Retrieved = $now; Offline = $false }
        $script:OfficialDiskCache[$url] = @{ Content = $content; Retrieved = $now }
        $script:OfficialDiskDirty = $true
        Write-Log "Official source OK: $url ($($content.Length) chars)"
    }
    catch {
        Write-Log "Official source FAILED: $url -> $($_.Exception.Message)"
        if ($script:OfficialDiskCache.ContainsKey($url)) {
            $d = $script:OfficialDiskCache[$url]
            $entry = @{ Url = $url; Content = $d.Content; Retrieved = $d.Retrieved; Offline = $true }
        }
    }
    $script:OfficialPageCache[$url] = $entry   # failures are cached too (no retry storm)
    return $entry
}

function ConvertFrom-HtmlText([string]$html) {
    $t = [regex]::Replace("$html", '(?s)<[^>]+>', ' ')
    $t = [Net.WebUtility]::HtmlDecode($t)
    return ([regex]::Replace($t, '\s+', ' ')).Trim()
}

# Parses vendor date strings ("1/10/2024 6:59:59 AM", "November 9, 2028",
# "24 Jun 2019", ISO 8601). Returns the calendar date or $null.
function ConvertTo-LcDate([string]$s) {
    $s = "$s".Trim()
    if (-not $s) { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $fmts = [string[]]@('M/d/yyyy h:mm:ss tt', 'M/d/yyyy', 'MMMM d, yyyy', 'MMM d, yyyy', 'd MMM yyyy', 'dd MMM yyyy', 'yyyy-MM-dd')
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, $fmts, $inv, [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$d)) { return $d.Date }
    if ($s -match '^\d{4}-\d{2}-\d{2}T') {
        if ([datetime]::TryParse($s, $inv, [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) { return $d.Date }
        return $null
    }
    # Last resort for other English vendor formats ("Jun 24, 2019", "24 June 2019")
    if ($s -match '\d{4}' -and [datetime]::TryParse($s, $inv, [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$d)) { return $d.Date }
    return $null
}

# Returns every <table> as a list of rows; each row is a string[] of cell
# texts. A cell with no text but a datetime="..." attribute (e.g. a client
# side <local-time> element) yields that attribute value instead.
function Get-HtmlTables([string]$html) {
    $tables = New-Object System.Collections.Generic.List[object]
    foreach ($tm in [regex]::Matches("$html", '(?is)<table\b.*?</table>')) {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($rm in [regex]::Matches($tm.Value, '(?is)<tr\b.*?</tr>')) {
            $cells = New-Object System.Collections.Generic.List[string]
            foreach ($cm in [regex]::Matches($rm.Value, '(?is)<t([hd])\b[^>]*>(.*?)</t\1>')) {
                $inner = $cm.Groups[2].Value
                $txt   = ConvertFrom-HtmlText $inner
                $attr  = [regex]::Match($inner, '(?i)datetime="([^"]+)"')
                if ($attr.Success -and -not (ConvertTo-LcDate $txt)) { $txt = $attr.Groups[1].Value }
                $cells.Add($txt)
            }
            if ($cells.Count -gt 0) { $rows.Add($cells.ToArray()) }
        }
        $tables.Add($rows.ToArray())
    }
    return ,$tables.ToArray()
}

# Status from the official dates (today = local date)
function Get-LcStatus($supportEnd, $eol, $esuEnd) {
    $today = (Get-Date).Date
    if (-not $supportEnd -and -not $eol) { return 'Unknown' }
    if ($eol -and $today -ge $eol) {
        if ($esuEnd -and $today -lt $esuEnd) { return 'EOL (paid ESU only)' }
        return 'EOL'
    }
    if ($supportEnd -and $today -ge $supportEnd) { return 'Extended support (security fixes only)' }
    return 'Supported'
}

function New-LcResult {
    param([string]$Product, [string]$Release, $ReleaseDate, $SupportEnd, $Eol, $EsuEnd,
          [string]$Policy, [string]$Note, [string]$Status, $Page, [string]$Source)
    if (-not $Status) { $Status = Get-LcStatus $SupportEnd $Eol $EsuEnd }
    $src = if ($Page) { $Page.Url } else { $Source }
    $srcNote = if (-not $Page) { 'official source unreachable' }
               elseif ($Page.Offline) { "offline copy of official page, retrieved $($Page.Retrieved.ToString('yyyy-MM-dd'))" }
               else { "official, retrieved $($Page.Retrieved.ToString('yyyy-MM-dd HH:mm'))" }
    $days = $null
    if ($Eol) { $days = [int]([datetime]$Eol - (Get-Date).Date).TotalDays }
    [PSCustomObject]@{
        Product     = $Product
        Release     = $Release
        Policy      = $Policy
        ReleaseDate = $ReleaseDate
        SupportEnd  = $SupportEnd
        EOL         = $Eol
        ESUEnd      = $EsuEnd
        DaysToEOL   = $days
        Status      = $Status
        Note        = $Note
        Source      = $src
        SourceNote  = $srcNote
    }
}

function Get-MsLifecycle([string]$slug) {
    $page = Invoke-OfficialSourceGet ($script:MsLifecycleBase + $slug)
    if (-not $page) { return $null }
    $info = @{ Page = $page; Policy = $null; Start = $null; MainstreamEnd = $null; ExtendedEnd = $null; EndDate = $null; Releases = @() }
    $pm = [regex]::Match($page.Content, '(?is)follows the\s*(?:<[^>]+>\s*)*([A-Za-z\- ]{3,30}?)\s*(?:<[^>]+>\s*)*Lifecycle Policy')
    if ($pm.Success) { $info.Policy = $pm.Groups[1].Value.Trim() }
    foreach ($t in (Get-HtmlTables $page.Content)) {
        if (@($t).Count -lt 2) { continue }
        $hdr = @($t[0])
        if ($hdr[0] -eq 'Listing') {
            $row = @($t[1])
            for ($c = 1; $c -lt $hdr.Count -and $c -lt $row.Count; $c++) {
                $d = ConvertTo-LcDate $row[$c]
                switch -Regex ($hdr[$c]) {
                    '^Start'      { $info.Start = $d }
                    '^Mainstream' { $info.MainstreamEnd = $d }
                    '^Extended'   { $info.ExtendedEnd = $d }
                    '^(End|Retirement)' { $info.EndDate = $d }
                }
            }
        }
        elseif ($hdr[0] -eq 'Version') {
            $info.Releases = @(for ($i = 1; $i -lt $t.Count; $i++) {
                $row = @($t[$i])
                [PSCustomObject]@{ Name = $row[0]; Start = (ConvertTo-LcDate $row[1]); End = $(if ($row.Count -gt 2) { ConvertTo-LcDate $row[2] }) }
            })
        }
    }
    return $info
}

function Get-EsuEnd($releases) {
    $esu = @($releases | Where-Object { $_.Name -match 'Extended Security Update' -and $_.End } | Sort-Object End -Descending)
    if ($esu.Count) { return $esu[0].End }
    return $null
}

function Resolve-OsLifecycle([int]$build) {
    $m = $script:WinServerBuilds[$build]
    if (-not $m) {
        return New-LcResult -Product "Windows build $build" -Status 'Unknown' -Note 'Build not mapped to a Windows Server LTSC release (SAC/Insider?)' -Source ($script:MsLifecycleBase)
    }
    $ms = Get-MsLifecycle $m.Slug
    if (-not $ms) { return New-LcResult -Product $m.Name -Status 'Unknown' -Source ($script:MsLifecycleBase + $m.Slug) }
    $esu = Get-EsuEnd $ms.Releases
    $eol = if ($ms.ExtendedEnd) { $ms.ExtendedEnd } else { $ms.EndDate }
    New-LcResult -Product $m.Name -Release $m.Name -ReleaseDate $ms.Start -SupportEnd $ms.MainstreamEnd -Eol $eol `
        -EsuEnd $esu -Policy $ms.Policy -Page $ms.Page
}

function Resolve-SqlLifecycle([string]$version, $sp) {
    $parts = "$version" -split '\.'
    $key   = $parts[0]
    if ($key -eq '10') { $key = if ($parts.Count -gt 1 -and $parts[1] -eq '50') { '10.50' } else { '10.0' } }
    $m = $script:SqlMajors[$key]
    if (-not $m) { return New-LcResult -Product "SQL Server $version" -Status 'Unknown' -Note 'Version not mapped' -Source $script:MsLifecycleBase }
    $ms = Get-MsLifecycle $m.Slug
    if (-not $ms) { return New-LcResult -Product $m.Name -Status 'Unknown' -Source ($script:MsLifecycleBase + $m.Slug) }
    $note = $null
    $spLabel = $null
    if ($null -ne $sp -and "$sp" -ne '') {
        $spLabel = if ([int]$sp -gt 0) { "Service Pack $sp" } else { 'Original Release' }
        $spRow = $ms.Releases | Where-Object { $_.Name -eq $spLabel } | Select-Object -First 1
        if ($spRow -and $spRow.End -and (Get-Date).Date -ge $spRow.End) {
            $note = "$spLabel support ended $($spRow.End.ToString('yyyy-MM-dd')) - install the latest service pack"
        }
    }
    $esu = Get-EsuEnd $ms.Releases
    $rel = if ($spLabel -and $spLabel -ne 'Original Release') { "$($m.Name) $spLabel" } else { $m.Name }
    New-LcResult -Product $m.Name -Release $rel -ReleaseDate $ms.Start -SupportEnd $ms.MainstreamEnd -Eol $ms.ExtendedEnd `
        -EsuEnd $esu -Policy $ms.Policy -Note $note -Page $ms.Page
}

# IIS is an OS component: official IIS page row "IIS x on <OS>", else the OS lifecycle.
function Resolve-IisLifecycle([string]$iisVersion, [int]$osBuild) {
    $osMap = $script:WinServerBuilds[$osBuild]
    $ms    = Get-MsLifecycle 'internet-information-services-iis'
    $short = ("$iisVersion" -replace '\.0$', '')
    if ($ms -and $osMap) {
        $row = $ms.Releases | Where-Object { $_.Name -eq "IIS $short on $($osMap.Name)" } | Select-Object -First 1
        if ($row) {
            return New-LcResult -Product "IIS $short" -Release $row.Name -ReleaseDate $row.Start -SupportEnd $row.End -Eol $row.End `
                -Policy 'Component (follows Windows)' -Page $ms.Page
        }
    }
    $os = Resolve-OsLifecycle $osBuild
    $os.Product = "IIS $short"
    $os.Release = if ($osMap) { "IIS $short on $($osMap.Name)" } else { "IIS $short" }
    $os.Policy  = 'Component (follows Windows)'
    $os.Note    = 'Microsoft: IIS is a Windows component and follows the OS lifecycle'
    return $os
}

function Resolve-MariaDbLifecycle([string]$version) {
    $series = if ("$version" -match '^(\d+\.\d+)') { $matches[1] } else { "$version" }
    $page = Invoke-OfficialSourceGet 'https://downloads.mariadb.org/rest-api/mariadb/'
    if (-not $page) { return New-LcResult -Product 'MariaDB' -Release $series -Status 'Unknown' -Source 'https://downloads.mariadb.org/rest-api/mariadb/' }
    try {
        $json = $page.Content | ConvertFrom-Json -ErrorAction Stop
        $rel  = @($json.major_releases) | Where-Object { "$($_.release_id)" -eq $series } | Select-Object -First 1
        if (-not $rel) { return New-LcResult -Product 'MariaDB' -Release $series -Status 'Unknown' -Note 'Series not listed by MariaDB Foundation' -Page $page }
        $eol = ConvertTo-LcDate "$($rel.release_eol_date)"
        New-LcResult -Product 'MariaDB' -Release "MariaDB $series" -SupportEnd $eol -Eol $eol `
            -Policy "$($rel.release_support_type)" -Note "Vendor status: $($rel.release_status)" -Page $page
    }
    catch { New-LcResult -Product 'MariaDB' -Release $series -Status 'Unknown' -Note "Parse error: $($_.Exception.Message)" -Page $page }
}

function Resolve-PostgresLifecycle([string]$version) {
    $v = "$version" -split '\.'
    $major = if ([int]$v[0] -ge 10) { $v[0] } else { "$($v[0]).$($v[1])" }
    $page = Invoke-OfficialSourceGet 'https://www.postgresql.org/support/versioning/'
    if (-not $page) { return New-LcResult -Product 'PostgreSQL' -Release $major -Status 'Unknown' -Source 'https://www.postgresql.org/support/versioning/' }
    foreach ($t in (Get-HtmlTables $page.Content)) {
        if (@($t).Count -lt 2 -or @($t[0])[0] -ne 'Version') { continue }
        foreach ($row in @($t | Select-Object -Skip 1)) {
            if ($row[0] -ne $major) { continue }
            $eol  = ConvertTo-LcDate $row[4]
            $note = "Latest minor: $($row[1])"
            if ($row[1] -and "$version" -notlike "$($row[1])*") { $note += " (installed $version - update available)" }
            $status = $null
            if ($row[2] -eq 'No') { $status = 'EOL' }
            return New-LcResult -Product 'PostgreSQL' -Release "PostgreSQL $major" -ReleaseDate (ConvertTo-LcDate $row[3]) `
                -SupportEnd $eol -Eol $eol -Status $status -Policy 'Community (5 years)' -Note $note -Page $page
        }
    }
    New-LcResult -Product 'PostgreSQL' -Release $major -Status 'Unknown' -Note 'Major version not listed' -Page $page
}

# MySQL: Oracle's EOL notice page lists the date each series moved to
# Sustaining Support; a series not listed there has no announced EOL.
function Resolve-MySqlLifecycle([string]$version) {
    $series = if ("$version" -match '^(\d+\.\d+)') { $matches[1] } else { "$version" }
    $url  = 'https://www.mysql.com/support/eol-notice.html'
    $page = Invoke-OfficialSourceGet $url
    if (-not $page) { return New-LcResult -Product 'MySQL' -Release $series -Status 'Unknown' -Source $url }
    $months = 'January|February|March|April|May|June|July|August|September|October|November|December'
    foreach ($h in [regex]::Matches($page.Content, '(?is)<h[23][^>]*>(.*?)</h[23]>')) {
        $title = ConvertFrom-HtmlText $h.Groups[1].Value
        if ($title -notmatch "MySQL\s+$([regex]::Escape($series))\b" -or $title -notmatch 'Sustaining Support') { continue }
        $before = $page.Content.Substring([Math]::Max(0, $h.Index - 1500), [Math]::Min(1500, $h.Index))
        $dm = [regex]::Matches((ConvertFrom-HtmlText $before), "($months)\s+\d{1,2},\s+\d{4}")
        $eol = if ($dm.Count) { ConvertTo-LcDate $dm[$dm.Count - 1].Value } else { $null }
        return New-LcResult -Product 'MySQL' -Release "MySQL $series" -SupportEnd $eol -Eol $eol -Status 'EOL' `
            -Policy 'Oracle Lifetime Support' -Note $title -Page $page
    }
    New-LcResult -Product 'MySQL' -Release "MySQL $series" -Status 'Supported (no EOL announced)' -Policy 'Oracle Lifetime Support' `
        -Note 'Series not listed on the official MySQL EOL notice page' -Page $page
}

# Firebird: discontinued series (with date) on the official page; active
# series are those on the official roadmap "Stable releases" table.
function Resolve-FirebirdLifecycle([string]$version) {
    $series = if ("$version" -match '^(\d+\.\d+)') { $matches[1] } else { "$version" }
    $disc = Invoke-OfficialSourceGet 'https://www.firebirdsql.org/en/discontinued-versions/'
    if ($disc) {
        foreach ($t in (Get-HtmlTables $disc.Content)) {
            foreach ($row in @($t)) {
                if (@($row).Count -ge 3 -and $row[0] -match "^v?$([regex]::Escape($series))$") {
                    $eol = ConvertTo-LcDate $row[2]
                    return New-LcResult -Product 'Firebird' -Release "Firebird $series" -SupportEnd $eol -Eol $eol -Status 'EOL' `
                        -Policy 'Firebird release policy' -Note "Discontinued; last release $($row[1])" -Page $disc
                }
            }
        }
    }
    $road = Invoke-OfficialSourceGet 'https://www.firebirdsql.org/en/roadmap/'
    if ($road) {
        foreach ($t in (Get-HtmlTables $road.Content)) {
            foreach ($row in @($t)) {
                if (@($row).Count -ge 3 -and $row[0] -match "^v?$([regex]::Escape($series))\b") {
                    return New-LcResult -Product 'Firebird' -Release "Firebird $series" -Status 'Supported (no EOL announced)' `
                        -Policy 'Firebird release policy' -Note "Active series; next version $($row[1]) planned $($row[2]). Policy: series older than 5 years get discontinued." -Page $road
                }
            }
        }
    }
    $pg = if ($disc) { $disc } else { $road }
    New-LcResult -Product 'Firebird' -Release "Firebird $series" -Status 'Unknown' -Note 'Series not listed on official pages' -Page $pg `
        -Source 'https://www.firebirdsql.org/en/discontinued-versions/'
}

# Lifecycle for one database product entry from the inventory
function Get-DbLifecycleKey($db) {
    $v = "$($db.Version)"
    switch ($db.Product) {
        'Microsoft SQL Server' { return "MSSQL|$(($v -split '\.')[0..1] -join '.')|$($db.ServicePack)" }
        'MariaDB'    { return "MariaDB|$v" }
        'MySQL'      { return "MySQL|$v" }
        'PostgreSQL' { return "PostgreSQL|$v" }
        'Firebird'   { return "Firebird|$v" }
        default      { return $null }
    }
}

function Resolve-LifecycleKey([string]$key) {
    $p = $key -split '\|'
    switch ($p[0]) {
        'OS'         { return Resolve-OsLifecycle ([int]$p[1]) }
        'IIS'        { return Resolve-IisLifecycle $p[1] ([int]$p[2]) }
        'MSSQL'      { return Resolve-SqlLifecycle $p[1] $(if ($p.Count -gt 2 -and $p[2] -ne '') { [int]$p[2] } else { $null }) }
        'MariaDB'    { return Resolve-MariaDbLifecycle $p[1] }
        'MySQL'      { return Resolve-MySqlLifecycle $p[1] }
        'PostgreSQL' { return Resolve-PostgresLifecycle $p[1] }
        'Firebird'   { return Resolve-FirebirdLifecycle $p[1] }
    }
    return $null
}

function Get-OsLifecycleKey($r) {
    $inv = Get-Inv $r
    $build = 0
    if ($inv -and $inv.OS -and $inv.OS.Build) { $build = [int]$inv.OS.Build }
    elseif ("$($r.OperatingSystem)" -match 'build (\d+)') { $build = [int]$matches[1] }
    if ($build -gt 0) { return "OS|$build" }
    return $null
}

function Get-IisLifecycleKey($r) {
    $inv = Get-Inv $r
    if (-not $inv -or -not $inv.IIS -or -not $inv.IIS.Version) { return $null }
    $os = Get-OsLifecycleKey $r
    $build = if ($os) { ($os -split '\|')[1] } else { 0 }
    return "IIS|$($inv.IIS.Version)|$build"
}

function Get-Lc([string]$key) {
    if ($key -and $script:Lifecycle.ContainsKey($key)) { return $script:Lifecycle[$key] }
    return $null
}

# Resolves lifecycle data for every scanned server (fresh fetch each run).
function Update-AllLifecycle {
    $keys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($k in $script:Results.Keys) {
        $r = $script:Results[$k]
        foreach ($lk in @((Get-OsLifecycleKey $r), (Get-IisLifecycleKey $r))) { if ($lk) { [void]$keys.Add($lk) } }
        $inv = Get-Inv $r
        if ($inv) { foreach ($db in @($inv.Databases | Where-Object { $_ })) { $lk = Get-DbLifecycleKey $db; if ($lk) { [void]$keys.Add($lk) } } }
    }
    if ($keys.Count -eq 0) { return }

    $script:OfficialPageCache = @{}
    $i = 0
    foreach ($lk in $keys) {
        $i++
        Set-Status "Checking official lifecycle sources ($i / $($keys.Count)): $lk" $script:MerlinBlue
        [System.Windows.Forms.Application]::DoEvents()
        try   { $script:Lifecycle[$lk] = Resolve-LifecycleKey $lk }
        catch { Write-Log "Lifecycle resolve failed for ${lk}: $($_.Exception.Message)" }
    }
    Save-OfficialDiskCache
    $script:LifecycleRefreshed = Get-Date
    foreach ($k in $script:Results.Keys) { Update-DerivedFields $script:Results[$k] }
    $offline = @($script:OfficialPageCache.Values | Where-Object { -not $_ -or $_.Offline }).Count
    Write-Log "Lifecycle refresh: $($keys.Count) lookups, $($script:OfficialPageCache.Count) official pages, $offline offline/failed."
}

function Format-LcDate($d) { if ($d) { return ([datetime]$d).ToString('yyyy-MM-dd') } return '-' }

function Format-LcLine($lc) {
    if (-not $lc) { return 'Support / EOL: not resolved yet (runs after scan / report)' }
    $s = "Support end: $(Format-LcDate $lc.SupportEnd) | EOL: $(Format-LcDate $lc.EOL)"
    if ($lc.ESUEnd) { $s += " | ESU until: $(Format-LcDate $lc.ESUEnd)" }
    $s += " | Status: $($lc.Status)"
    if ($lc.Note) { $s += " | $($lc.Note)" }
    return $s
}

function Get-DaysLeft([string]$isoDate) {
    $d = ConvertTo-LcDate (("$isoDate" -split ' ')[0])
    if (-not $d) { return $null }
    return [int]($d - (Get-Date).Date).TotalDays
}

function Get-CertStatus($days) {
    if ($null -eq $days) { return 'Unknown' }
    if ($days -lt 0)  { return 'EXPIRED' }
    if ($days -le 30) { return 'Expires <= 30 days' }
    if ($days -le 60) { return 'Expires <= 60 days' }
    if ($days -le 90) { return 'Expires <= 90 days' }
    return 'Valid'
}

# Builds the human readable (derived) fields shown in tabs / search / CSV
function Update-DerivedFields($r) {
    if (-not $r) { return }
    try {
        $key  = "$($r.ComputerName)".ToUpper()
        $inv  = Get-Inv $r
        $vals = @{}
        $vals.RoleGroupsText = (@(Get-RoleGroupDetails $r) | ForEach-Object { "$($_.Group) <- $($_.Reason)" }) -join '; '

        $osLc = Get-Lc (Get-OsLifecycleKey $r)
        $vals.OSLifecycle = if ($osLc) {
            "$($osLc.Product) ($($osLc.Policy) policy) ;; Mainstream support end: $(Format-LcDate $osLc.SupportEnd) ;; " +
            "Extended support end (EOL): $(Format-LcDate $osLc.EOL)" +
            $(if ($osLc.ESUEnd) { " ;; Paid ESU until: $(Format-LcDate $osLc.ESUEnd)" } else { '' }) +
            " ;; Status: $($osLc.Status)$(if ($null -ne $osLc.DaysToEOL) { if ($osLc.DaysToEOL -ge 0) { " ($($osLc.DaysToEOL) days to EOL)" } else { " (past EOL by $(-$osLc.DaysToEOL) days)" } }) ;; Source: $($osLc.Source) ($($osLc.SourceNote))"
        } else { 'Not resolved yet (checked against official sources after a scan)' }

        if ($inv) {
            $roles = @($inv.Features | Where-Object { $_ } | Where-Object { $_.Type -ne 'Feature' } | Sort-Object Depth)
            $vals.RolesDetail = if ($roles) {
                ($roles | Where-Object { $_.Type -eq 'Role' } | ForEach-Object {
                    $role = $_
                    $svc  = @($roles | Where-Object { $_.Type -eq 'Role Service' -and $_.Parent -eq $role.Name } | ForEach-Object { $_.DisplayName })
                    "$($role.DisplayName) [$($role.Name)]" + $(if ($svc) { " -> $($svc -join ', ')" } else { '' })
                }) -join ' ;; '
            } else { 'None' }
            $feat = @($inv.Features | Where-Object { $_ } | Where-Object { $_.Type -eq 'Feature' -and $_.Depth -le 1 })
            $vals.FeaturesDetail = if ($feat) { ($feat | ForEach-Object { "$($_.DisplayName) [$($_.Name)]" }) -join ' ;; ' } else { 'None' }

            if ($inv.IIS) {
                $iisLc = Get-Lc (Get-IisLifecycleKey $r)
                $vals.IISVersionInfo = "IIS $($inv.IIS.Version) ($($inv.IIS.VersionString)) ;; Install date: $(if ($inv.IIS.InstallDate) { $inv.IIS.InstallDate } else { '?' }) ($($inv.IIS.InstallDateSource)) ;; " +
                                       "Sites: $($inv.IIS.SiteCount) ;; $(Format-LcLine $iisLc)$(if ($iisLc) { " ;; Source: $($iisLc.Source)" })"
            } else { $vals.IISVersionInfo = 'IIS not installed' }

            $dbs = @($inv.Databases | Where-Object { $_ })
            $vals.DatabaseProducts = if ($dbs) {
                ($dbs | ForEach-Object {
                    $lc = Get-Lc (Get-DbLifecycleKey $_)
                    "$($_.Product) $($_.Version) [$($_.Instance)] $(if ($_.Edition) { "- $($_.Edition) " })| Installed: $(if ($_.InstallDate) { $_.InstallDate } else { '?' }) | State: $($_.ServiceState) | $(Format-LcLine $lc)"
                }) -join ' ;; '
            } else { 'None detected' }

            $certs = @($inv.Certificates | Where-Object { $_ } | Sort-Object { $_.NotAfter })
            $vals.CertificateSummary = if ($certs) {
                ($certs | ForEach-Object {
                    $days = Get-DaysLeft $_.NotAfter
                    $name = if ($_.DnsNames) { @($_.DnsNames)[0] } elseif ($_.FriendlyName) { $_.FriendlyName } else { $_.Subject }
                    "$(Get-CertStatus $days): $name | Expires: $($_.NotAfter) ($days days) | Issuer: $($_.Issuer) | Store: $($_.Store)" +
                        $(if (@($_.BoundTo).Count) { " | Used by: $(@($_.BoundTo) -join ', ')" } else { '' })
                }) -join ' ;; '
            } else { 'None' }
        }
        else {
            foreach ($n in 'RolesDetail', 'FeaturesDetail', 'IISVersionInfo', 'DatabaseProducts', 'CertificateSummary') {
                $vals[$n] = 'Rescan with v1.5 to collect this detail'
            }
        }
        foreach ($n in $vals.Keys) { $r | Add-Member -NotePropertyName $n -NotePropertyValue $vals[$n] -Force }
    }
    catch { Write-Log "Derived fields failed for $($r.ComputerName): $($_.Exception.Message)" }
}

# --- Search index: built once, searched instantly --------------------------
$script:SearchIndex = @{}   # key -> List of @{Property; Value; Lower}

function Build-SearchIndex {
    $script:SearchIndex = @{}
    foreach ($key in $script:Results.Keys) {
        $r    = $script:Results[$key]
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($def in $script:FieldDefs) {
            $p   = $r.PSObject.Properties[$def.Name]
            $val = if ($p) { "$($p.Value)" } else { "" }
            if (-not $val) { continue }
            $items = if ($def.Sep) { $val -split [regex]::Escape($def.Sep) } else { @($val) }
            foreach ($item in $items) {
                $item = "$item".Trim()
                if ($item) {
                    $list.Add([PSCustomObject]@{ Property = $def.Label; Value = $item; Lower = $item.ToLower() })
                }
            }
        }
        $script:SearchIndex[$key] = $list
    }
}

# --- Wizard logo (drawn in code) -------------------------------------------
function New-WizardBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.ScaleTransform(($size / 64.0), ($size / 64.0))

    $blue   = New-Object System.Drawing.SolidBrush ($script:MerlinBlue)
    $yellow = New-Object System.Drawing.SolidBrush ((New-Rgb 250 204 21))
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

    $blue.Dispose(); $yellow.Dispose(); $skin.Dispose(); $beard.Dispose(); $nose.Dispose(); $black.Dispose()
    $g.Dispose()
    return $bmp
}

# --- Main form -------------------------------------------------------------
$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Server Wizard v$($script:AppVersion)"
$form.Size          = New-Object System.Drawing.Size(1280, 820)
$form.StartPosition = "CenterScreen"
$form.MinimumSize   = New-Object System.Drawing.Size(1050, 660)
$form.BackColor     = $script:ThBg

try {
    $form.Icon = [System.Drawing.Icon]::FromHandle((New-WizardBitmap 32).GetHicon())
} catch {}

# Default font for ALL controls (inherited by children)
$form.Font = New-Object System.Drawing.Font($script:FontName, 9)

# Header (sized before controls are added, so right-anchored buttons don't
# get measured against the default 200px panel width)
$pnlHeader           = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock      = "Top"
$pnlHeader.Size      = New-Object System.Drawing.Size(1264, 54)
$pnlHeader.BackColor = $script:MerlinBlueLt

$picLogo          = New-Object System.Windows.Forms.PictureBox
$picLogo.Location = New-Object System.Drawing.Point(10, 7)
$picLogo.Size     = New-Object System.Drawing.Size(40, 40)
$picLogo.SizeMode = "Zoom"
$picLogo.Image    = New-WizardBitmap 64

$lblTitle           = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "Server Wizard"
$lblTitle.Font      = New-Object System.Drawing.Font("Comic Sans MS", 15, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $script:MerlinBlue
$lblTitle.Location  = New-Object System.Drawing.Point(56, 5)
$lblTitle.AutoSize  = $true

$lblSubtitle           = New-Object System.Windows.Forms.Label
$lblSubtitle.Text      = "Windows Server Inventory  -  v$($script:AppVersion)"
$lblSubtitle.Font      = New-Object System.Drawing.Font($script:FontName, 9)
$lblSubtitle.ForeColor = $script:ThMuted
$lblSubtitle.Location  = New-Object System.Drawing.Point(232, 18)
$lblSubtitle.AutoSize  = $true

$btnClearCache           = New-Object System.Windows.Forms.Button
$btnClearCache.Text      = "Clear Cache"
$btnClearCache.Size      = New-Object System.Drawing.Size(100, 28)
$btnClearCache.FlatStyle = "Flat"
$btnClearCache.ForeColor = $script:MerlinBlue

$btnOpenLog           = New-Object System.Windows.Forms.Button
$btnOpenLog.Text      = "Open Log"
$btnOpenLog.Size      = New-Object System.Drawing.Size(90, 28)
$btnOpenLog.FlatStyle = "Flat"
$btnOpenLog.ForeColor = $script:MerlinBlue

$pnlHeader.Controls.AddRange(@($picLogo, $lblTitle, $lblSubtitle, $btnOpenLog, $btnClearCache))

# Position header buttons relative to the actual panel width
$pnlHeader.Add_Resize({
    $btnClearCache.Top  = 13
    $btnOpenLog.Top     = 13
    $btnClearCache.Left = $pnlHeader.Width - $btnClearCache.Width - 14
    $btnOpenLog.Left    = $btnClearCache.Left - $btnOpenLog.Width - 8
})

# Left panel: server tree
$grpSource           = New-Object System.Windows.Forms.GroupBox
$grpSource.Text      = "Servers"
$grpSource.ForeColor = $script:MerlinBlue
$grpSource.Location  = New-Object System.Drawing.Point(8, 60)
$grpSource.Size      = New-Object System.Drawing.Size(320, 686)
$grpSource.Anchor    = "Top,Bottom,Left"

$lblOU           = New-Object System.Windows.Forms.Label
$lblOU.Text      = "OU / SearchBase (optional):"
$lblOU.ForeColor = $script:ThText
$lblOU.Location  = New-Object System.Drawing.Point(10, 22)
$lblOU.AutoSize  = $true

$txtOU          = New-Object System.Windows.Forms.TextBox
$txtOU.Location = New-Object System.Drawing.Point(10, 42)
$txtOU.Size     = New-Object System.Drawing.Size(320, 23)
$txtOU.Anchor   = "Top,Left,Right"

$chkPing           = New-Object System.Windows.Forms.CheckBox
$chkPing.Text      = "Ping check (add only reachable servers)"
$chkPing.ForeColor = $script:ThText
$chkPing.Location  = New-Object System.Drawing.Point(10, 68)
$chkPing.AutoSize  = $true
$chkPing.Checked   = $true

$btnLoadAD           = New-Object System.Windows.Forms.Button
$btnLoadAD.Text      = "Load from AD"
$btnLoadAD.Location  = New-Object System.Drawing.Point(10, 92)
$btnLoadAD.Size      = New-Object System.Drawing.Size(150, 32)
$btnLoadAD.BackColor = $script:MerlinBlue
$btnLoadAD.ForeColor = [System.Drawing.Color]::White
$btnLoadAD.FlatStyle = "Flat"

$chkAll           = New-Object System.Windows.Forms.CheckBox
$chkAll.Text      = "Select / deselect all"
$chkAll.ForeColor = $script:ThText
$chkAll.Location  = New-Object System.Drawing.Point(180, 98)
$chkAll.AutoSize  = $true
$chkAll.Checked   = $true

$tree               = New-Object System.Windows.Forms.TreeView
$tree.Location      = New-Object System.Drawing.Point(10, 132)
$tree.Size          = New-Object System.Drawing.Size(320, 480)
$tree.Anchor        = "Top,Bottom,Left,Right"
$tree.CheckBoxes    = $true
$tree.HideSelection = $false
$tree.Font          = New-Object System.Drawing.Font($script:FontName, 9)

$lblCount           = New-Object System.Windows.Forms.Label
$lblCount.Text      = "0 servers  |  Right-click a server to change its group"
$lblCount.ForeColor = $script:ThText
$lblCount.Location  = New-Object System.Drawing.Point(10, 620)
$lblCount.AutoSize  = $true
$lblCount.Anchor    = "Bottom,Left"

$grpSource.Controls.AddRange(@($lblOU, $txtOU, $chkPing, $btnLoadAD, $chkAll, $tree, $lblCount))

# Stacks the "Servers" controls by their REAL rendered heights. Fixed pixel
# positions broke at 125%+ DPI / with Open Sans: the taller OU label covered
# the top border and corners of the OU text box.
function Update-SourceLayout {
    try {
        $grpSource.SuspendLayout()
        $gap = 4
        $lblOU.Top      = [Math]::Max(18, $grpSource.DisplayRectangle.Top + 2)
        $txtOU.Top      = $lblOU.Top + $lblOU.PreferredHeight + $gap
        $chkPing.Top    = $txtOU.Bottom + $gap + 2
        $btnLoadAD.Top  = $chkPing.Top + $chkPing.PreferredSize.Height + $gap + 2
        $chkAll.Top     = $btnLoadAD.Top + [int](($btnLoadAD.Height - $chkAll.PreferredSize.Height) / 2)
        $tree.Top       = $btnLoadAD.Bottom + 8
        $lblCount.Top   = $grpSource.ClientSize.Height - $lblCount.PreferredHeight - 10
        $tree.Height    = [Math]::Max(80, $lblCount.Top - 6 - $tree.Top)
    }
    catch { Write-Log "Servers panel layout failed: $($_.Exception.Message)" }
    finally { $grpSource.ResumeLayout($true) }
}

# Right side: buttons row
$btnScan           = New-Object System.Windows.Forms.Button
$btnScan.Text      = "Start Scan"
$btnScan.Location  = New-Object System.Drawing.Point(336, 64)
$btnScan.Size      = New-Object System.Drawing.Size(110, 28)
$btnScan.BackColor = $script:MerlinBlue
$btnScan.ForeColor = [System.Drawing.Color]::White
$btnScan.FlatStyle = "Flat"

$btnStop           = New-Object System.Windows.Forms.Button
$btnStop.Text      = "Stop"
$btnStop.Location  = New-Object System.Drawing.Point(452, 64)
$btnStop.Size      = New-Object System.Drawing.Size(64, 28)
$btnStop.Enabled   = $false
$btnStop.FlatStyle = "Flat"

$btnExport           = New-Object System.Windows.Forms.Button
$btnExport.Text      = "Report Builder"
$btnExport.Location  = New-Object System.Drawing.Point(522, 64)
$btnExport.Size      = New-Object System.Drawing.Size(120, 28)
$btnExport.Enabled   = $false
$btnExport.BackColor = $script:ThSurface
$btnExport.ForeColor = $script:ThText
$btnExport.FlatStyle = "Flat"

$lblThrottle          = New-Object System.Windows.Forms.Label
$lblThrottle.Text     = "Parallel:"
$lblThrottle.Location = New-Object System.Drawing.Point(652, 70)
$lblThrottle.AutoSize = $true

$numThrottle          = New-Object System.Windows.Forms.NumericUpDown
$numThrottle.Location = New-Object System.Drawing.Point(706, 67)
$numThrottle.Size     = New-Object System.Drawing.Size(52, 23)
$numThrottle.Minimum  = 1
$numThrottle.Maximum  = 100
$numThrottle.Value    = 20

# Search bar (IP / website / DNS -> which server?) with a category scope
$lblSearch          = New-Object System.Windows.Forms.Label
$lblSearch.Text     = "Search:"
$lblSearch.Location = New-Object System.Drawing.Point(772, 70)
$lblSearch.AutoSize = $true

$txtSearch          = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(822, 67)
$txtSearch.Size     = New-Object System.Drawing.Size(280, 23)

$btnSearch           = New-Object System.Windows.Forms.Button
$btnSearch.Text      = "Find"
$btnSearch.Location  = New-Object System.Drawing.Point(1108, 65)
$btnSearch.Size      = New-Object System.Drawing.Size(60, 27)
$btnSearch.BackColor = $script:MerlinBlue
$btnSearch.ForeColor = [System.Drawing.Color]::White
$btnSearch.FlatStyle = "Flat"

# Tabs: each clicked server opens in its own tab (owner-drawn for the x button)
$tabs          = if ($script:DarkNative) { New-Object SwTabControl } else { New-Object System.Windows.Forms.TabControl }
$tabs.Location = New-Object System.Drawing.Point(336, 100)
$tabs.Size     = New-Object System.Drawing.Size(920, 646)
$tabs.Anchor   = "Top,Bottom,Left,Right"
$tabs.DrawMode = "OwnerDrawFixed"
$tabs.Padding  = New-Object System.Drawing.Point(18, 4)
$tabs.SizeMode = "Normal"

# Status bar: message + progress + last scan date (right-aligned)
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text   = "Ready."
$statusLabel.Spring = $true
$statusLabel.TextAlign = "MiddleLeft"
$statusProgress = New-Object System.Windows.Forms.ToolStripProgressBar
$statusProgress.Visible = $false
$statusProgress.Size    = New-Object System.Drawing.Size(220, 16)
$statusScanDate = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusScanDate.Text      = "Last scan: -"
$statusScanDate.ForeColor = $script:ThMuted
[void]$statusStrip.Items.Add($statusLabel)
[void]$statusStrip.Items.Add($statusProgress)
[void]$statusStrip.Items.Add($statusScanDate)

function Update-LastScanLabel {
    if (Test-Path $script:CacheFile) {
        $statusScanDate.Text = "Last scan: $((Get-Item $script:CacheFile).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
    }
    else { $statusScanDate.Text = "Last scan: -" }
}

$form.Controls.AddRange(@($pnlHeader, $grpSource, $btnScan, $btnStop, $btnExport,
    $lblThrottle, $numThrottle, $lblSearch, $txtSearch,
    $btnSearch, $tabs, $statusStrip))
$form.Add_Load({
    Set-DarkTheme $form
    $btnScan.BackColor = $script:ThAccent; $btnScan.ForeColor = [System.Drawing.Color]::White
})
$btnScan.BackColor = $script:ThAccent; $btnScan.ForeColor = [System.Drawing.Color]::White
$btnSearch.BackColor = $script:ThAccent; $btnSearch.ForeColor = [System.Drawing.Color]::White
$btnLoadAD.BackColor = $script:ThAccent; $btnLoadAD.ForeColor = [System.Drawing.Color]::White
foreach ($b in @($btnScan, $btnSearch, $btnLoadAD)) { $b.FlatAppearance.BorderColor = $script:ThAccent }
if (-not $script:DarkNative) { Write-Log "Dark title bar / tab control not available: $script:DarkNativeError" }

# Repaint hygiene: double-buffer the containers and keep the header on top,
# otherwise the initial layout pass can leave border ghosts in the header.
Set-DoubleBuffered $form
Set-DoubleBuffered $pnlHeader
Set-DoubleBuffered $tree
Set-DoubleBuffered $tabs
$pnlHeader.BringToFront()
$form.Add_Load({ Update-SourceLayout })
$form.Add_Shown({ Update-SourceLayout; $pnlHeader.Invalidate(); $form.Refresh() })
try { $form.Add_DpiChanged({ Update-SourceLayout }) } catch {}   # .NET 4.7+ only
$form.Add_Resize({ $pnlHeader.Invalidate() })

$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 1500

# Context menu: manual role-group override
$ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip
foreach ($gName in $script:RoleGroups) {
    $item = $ctxMenu.Items.Add("Move to: $gName")
    $item.Tag = $gName
    $item.Add_Click({
        param($s, $e)
        if ($script:CtxTarget) {
            $script:Overrides[$script:CtxTarget] = $s.Tag
            Save-Cache | Out-Null
            Group-AndRebuild
            Set-Status "$script:CtxTarget moved to '$($s.Tag)' (manual override saved)."
        }
    })
}
[void]$ctxMenu.Items.Add("-")
$itemAuto = $ctxMenu.Items.Add("Auto (clear manual override)")
$itemAuto.Add_Click({
    if ($script:CtxTarget -and $script:Overrides.ContainsKey($script:CtxTarget)) {
        $script:Overrides.Remove($script:CtxTarget)
        Save-Cache | Out-Null
        Group-AndRebuild
        Set-Status "$script:CtxTarget group override cleared (auto-detected group restored)."
    }
})

# --- Helper functions ------------------------------------------------------
function Set-Status([string]$msg, [System.Drawing.Color]$color = $script:ThText) {
    $statusLabel.Text      = $msg
    $statusLabel.ForeColor = $color
}

function Get-AllLeafNodes {
    $leaves = @()
    foreach ($g in $tree.Nodes) { foreach ($n in $g.Nodes) { $leaves += $n } }
    return $leaves
}

# A multi-role server has one leaf per group: count unique names
function Update-ServerCount {
    $leaves  = Get-AllLeafNodes
    $all     = @($leaves | ForEach-Object { Get-LeafName $_ } | Sort-Object -Unique)
    $checked = @($leaves | Where-Object { $_.Checked } | ForEach-Object { Get-LeafName $_ } | Sort-Object -Unique)
    $lblCount.Text = "$($all.Count) servers ($($checked.Count) selected)  |  Right-click = change group"
}

function Get-LeafName([System.Windows.Forms.TreeNode]$node) {
    return ("$($node.Text)" -replace ' \*$', '').ToUpper()
}

function Rebuild-Tree([hashtable]$groups) {
    $script:TreeUpdating = $true
    $tree.BeginUpdate()
    $tree.Nodes.Clear()

    # Known groups in display order, then any other (e.g. legacy override) names
    $order = @($script:GroupOrder) + @($groups.Keys | Where-Object { $script:GroupOrder -notcontains $_ } | Sort-Object)
    foreach ($gName in $order) {
        if (-not $groups.ContainsKey($gName) -or $groups[$gName].Count -eq 0) { continue }

        # Trailing spaces work around the WinForms bold-NodeFont clipping bug
        $gNode           = New-Object System.Windows.Forms.TreeNode ("$gName ($($groups[$gName].Count))     ")
        $gNode.NodeFont  = New-Object System.Drawing.Font($script:FontName, 9, [System.Drawing.FontStyle]::Bold)
        $gNode.ForeColor = $script:MerlinBlue
        $gNode.Checked   = $true
        [void]$tree.Nodes.Add($gNode)

        foreach ($entry in ($groups[$gName] | Sort-Object { $_.Name })) {
            $text = $entry.Name
            if ($script:Overrides.ContainsKey($entry.Name)) { $text += ' *' }   # * = manual override
            $n         = New-Object System.Windows.Forms.TreeNode ($text)
            $n.Checked = $entry.CheckedState

            # Risks are shown on the Home dashboard; only not-yet-scanned servers are dimmed
            if (-not $script:Results[$entry.Name]) { $n.ForeColor = $script:ThMuted }
            [void]$gNode.Nodes.Add($n)
        }
    }

    $tree.ExpandAll()
    $tree.EndUpdate()
    $script:TreeUpdating = $false
    Update-ServerCount
}

function Get-ItemTone([string]$text) {
    if ($text -match 'Status: EOL\b|EXPIRED|Past end of support|Expires <= 30 days') { return $script:ThBad }
    if ($text -match 'Extended support|paid ESU|Expires <= (60|90) days') { return $script:ThWarn }
    return $script:ThText
}

# Compact server view: one line per field ("Label <tab> value"), lists
# continue in the value column; short lists are joined on one line.
function Render-Detail($r, [System.Windows.Forms.RichTextBox]$box) {
    try {
        Set-Redraw $box $false   # suspend painting: renders in one smooth pass
        $box.Clear()
        $box.BackColor = $script:ThBg; $box.ForeColor = $script:ThText
        $labelW      = 230
        $box.SelectionTabs = [int[]]@($labelW)
        $box.SelectionHangingIndent = $labelW
        $headerFont  = New-Object System.Drawing.Font($script:FontName, 12, [System.Drawing.FontStyle]::Bold)
        $sectionFont = New-Object System.Drawing.Font($script:FontName, 9.5, [System.Drawing.FontStyle]::Bold)
        $labelFont   = New-Object System.Drawing.Font($script:FontName, 9)
        $itemFont    = New-Object System.Drawing.Font($script:FontName, 9)

        $key = "$($r.ComputerName)".ToUpper()
        $box.SelectionFont  = $headerFont
        $box.SelectionColor = $script:ThAccent
        $box.AppendText("$($r.ComputerName)")
        $box.SelectionFont  = $itemFont
        $box.SelectionColor = $script:ThMuted
        $grpTxt = Get-EffectiveGroup $key $r
        if ($script:Overrides.ContainsKey($key)) { $grpTxt += " (manual override)" }
        $box.AppendText("    $grpTxt`n")

        $currentSection = ""
        foreach ($def in $script:FieldDefs) {
            $prop = $r.PSObject.Properties[$def.Name]
            $val  = if ($prop) { "$($prop.Value)" } else { "" }
            if (-not $val) { continue }

            if ($def.Section -ne $currentSection) {
                $currentSection     = $def.Section
                $box.SelectionFont  = $sectionFont
                $box.SelectionColor = $script:ThAccent
                $box.AppendText("`n$currentSection`n")
            }

            $items = @(if ($def.Sep) { $val -split [regex]::Escape($def.Sep) } else { $val }) |
                     ForEach-Object { "$_".Trim() } | Where-Object { $_ }
            $items = @($items)
            if ($items.Count -eq 0) { continue }
            # Short lists (ports, IPs, roles...) fit on one line
            $joined = $items -join ', '
            if ($items.Count -gt 1 -and $joined.Length -le 110 -and -not ($items | Where-Object { $_ -match ': ' })) { $items = @($joined) }

            $box.SelectionFont  = $labelFont
            $box.SelectionColor = $script:ThMuted
            $box.AppendText("$($def.Label)")
            $first = $true
            foreach ($item in $items) {
                $box.SelectionFont  = $itemFont
                $box.SelectionColor = Get-ItemTone $item
                $box.AppendText("`t$item`n")
                $first = $false
            }
        }
        # Same tab stop / hanging indent for every paragraph
        $box.SelectAll()
        $box.SelectionTabs = [int[]]@($labelW)
        $box.SelectionHangingIndent = $labelW
        $box.Select(0, 0)
        Set-Redraw $box $true
        Scroll-ToTop $box   # always start reading from the TOP
    }
    catch {
        Set-Redraw $box $true
        $box.Text = "Error rendering details: $_"
    }
}

function Open-ServerTab([string]$key) {
    foreach ($tp in $tabs.TabPages) {
        if ($tp.Text -eq $key) { $tabs.SelectedTab = $tp; return }
    }
    $res = $script:Results[$key]
    if (-not $res) { Set-Status "$key has not been scanned yet. Run a scan to collect its details." $script:WarnOrange; return }

    $tp  = New-Object System.Windows.Forms.TabPage ($key)
    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Dock      = "Fill"
    $box.ReadOnly  = $true
    $box.BackColor = $script:ThBg; $box.ForeColor = $script:ThText; $box.BorderStyle = 'None'
    $box.Font      = New-Object System.Drawing.Font($script:FontName, 9)
    $tp.UseVisualStyleBackColor = $false; $tp.BackColor = $script:ThBg; $tp.Padding = New-Object System.Windows.Forms.Padding(6)
    Set-DarkWindow $box
    $tp.Controls.Add($box)
    [void]$tabs.TabPages.Add($tp)
    $tabs.SelectedTab = $tp
    Render-Detail $res $box
}

# Get (or create) a utility tab like "Search Results" / "Scan Progress"
function Get-TabBox([string]$name, [bool]$select = $true) {
    foreach ($t in $tabs.TabPages) {
        if ($t.Text -eq $name) {
            if ($select) { $tabs.SelectedTab = $t }
            return $t.Controls[0]
        }
    }
    $tp  = New-Object System.Windows.Forms.TabPage ($name)
    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Dock = "Fill"; $box.ReadOnly = $true; $box.BackColor = $script:ThBg; $box.ForeColor = $script:ThText; $box.BorderStyle = 'None'
    $box.Font = New-Object System.Drawing.Font($script:FontName, 9)
    $tp.UseVisualStyleBackColor = $false; $tp.BackColor = $script:ThBg; $tp.Padding = New-Object System.Windows.Forms.Padding(6)
    Set-DarkWindow $box
    $tp.Controls.Add($box)
    [void]$tabs.TabPages.Add($tp)
    if ($select) { $tabs.SelectedTab = $tp }
    return $box
}

function Group-AndRebuild {
    $known = @{}
    foreach ($leaf in Get-AllLeafNodes) { $known[(Get-LeafName $leaf)] = $leaf.Checked }
    foreach ($key in $script:Results.Keys) {
        if (-not $known.ContainsKey($key)) { $known[$key] = $true }
    }

    $groups = @{}
    foreach ($key in $known.Keys) {
        foreach ($gName in @(Get-EffectiveGroups $key $script:Results[$key])) {
            if (-not $groups.ContainsKey($gName)) { $groups[$gName] = @() }
            $groups[$gName] += @{ Name = $key; CheckedState = $known[$key] }
        }
    }
    Rebuild-Tree $groups
}

function Finish-Scan {
    $timer.Stop()
    try {
    if ($script:ScanJob) {
        $data   = Receive-Job -Job $script:ScanJob -ErrorAction SilentlyContinue
        $failed = $script:ScanJob.ChildJobs | Where-Object { $_.State -eq 'Failed' } | ForEach-Object { $_.Location }
        Remove-Job -Job $script:ScanJob -Force -ErrorAction SilentlyContinue
        $script:ScanJob = $null

        foreach ($r in @($data | Where-Object { $_ })) {
            $key = "$(if ($r.PSComputerName) { $r.PSComputerName } else { $r.ComputerName })".ToUpper()
            if ($key) { $script:Results[$key] = $r }
        }

        foreach ($k in $script:Results.Keys) { Update-DerivedFields $script:Results[$k] }
        # Support / EOL dates: always re-checked against the official sources
        try { Update-AllLifecycle } catch { Write-Log "Lifecycle refresh failed: $($_.Exception.Message)" }

        $script:LastUnreachable = @($failed | Where-Object { $_ })
        $cached = Save-Cache
        Build-SearchIndex
        Group-AndRebuild
        Show-Overview

        # Refresh any open server tabs with fresh data
        foreach ($tp in $tabs.TabPages) {
            $res = $script:Results["$($tp.Text)".ToUpper()]
            if ($res -and $tp.Controls.Count -gt 0) { Render-Detail $res $tp.Controls[0] }
        }

        $msg = "$($script:Results.Keys.Count) servers in inventory."
        if ($cached) { $msg += " Cache updated." } else { $msg += " (cache could not be written)" }
        if ($failed) { Set-Status "$msg UNREACHABLE: $($failed -join ', ')" $script:WarnOrange }
        else         { Set-Status $msg $script:OkGreen }
        Write-Log "Scan finished: $($script:Results.Keys.Count) in inventory, cache saved: $cached, unreachable: $($failed -join ', ')"
    }
    }
    catch {
        Write-Log "FINISH-SCAN ERROR: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        Set-Status "Error while finishing scan: $_ (see log)" $script:ThBad
    }
    Update-LastScanLabel
    $statusProgress.Visible = $false
    $btnScan.Enabled   = $true
    $btnStop.Enabled   = $false
    $btnExport.Enabled = ($script:Results.Keys.Count -gt 0)
}

function Invoke-Search([switch]$KeepScope) {
    if (-not $KeepScope) { $script:SearchScope = $script:AllCategories }
    $q = $txtSearch.Text.Trim()
    if (-not $q) { return }
    if ($script:Results.Keys.Count -eq 0) { Set-Status "Nothing to search - run a scan first." $script:WarnOrange; return }
    if ($script:SearchIndex.Keys.Count -eq 0) { Build-SearchIndex }

    $scope = "$script:SearchScope"
    if (-not $scope) { $scope = $script:AllCategories }
    $allScopes = ($scope -eq $script:AllCategories)

    # Fast indexed search (case-insensitive substring, no regex)
    $qLower = $q.ToLower()
    $found  = @()
    foreach ($key in ($script:SearchIndex.Keys | Sort-Object)) {
        if (($allScopes -or $scope -eq 'Server Name') -and $key.ToLower().Contains($qLower)) {
            $found += [PSCustomObject]@{ Server = $key; Category = 'Server Name'; Value = $key }
        }
        if ($scope -eq 'Server Name') { continue }
        foreach ($entry in $script:SearchIndex[$key]) {
            if (-not $allScopes -and $entry.Property -ne $scope) { continue }
            if ($entry.Lower.Contains($qLower)) {
                $found += [PSCustomObject]@{ Server = $key; Category = $entry.Property; Value = $entry.Value }
            }
        }
    }

    $script:LastSearchQuery = $q
    $script:LastSearchRows  = $found

    $box = Get-TabBox "Search Results"

    # Wire the click handler once: server names open a tab, category lines filter
    if (-not $script:SearchClickWired) {
        $script:SearchClickWired = $true
        $box.Add_MouseDown({
            param($s, $e)
            $map = $s.Tag
            if (-not $map) { return }
            $idx = $s.GetCharIndexFromPosition($e.Location)
            $ln  = $s.GetLineFromCharIndex($idx)
            if (-not $map.ContainsKey($ln)) { return }
            $target = $map[$ln]
            if ($target.Type -eq 'Server') { Open-ServerTab $target.Value }
            else {
                $script:SearchScope = $target.Value
                Invoke-Search -KeepScope
            }
        })
        $box.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    Set-Redraw $box $false
    $box.Clear()
    $lineMap = @{}   # line index -> @{ Type = 'Server'|'Category'; Value = ... }

    $titleFont   = New-Object System.Drawing.Font($script:FontName, 12, [System.Drawing.FontStyle]::Bold)
    $catFont     = New-Object System.Drawing.Font($script:FontName, 11, [System.Drawing.FontStyle]::Bold)
    $linkFont    = New-Object System.Drawing.Font($script:FontName, 10, ([System.Drawing.FontStyle]::Bold -bor [System.Drawing.FontStyle]::Underline))
    $itemFont    = New-Object System.Drawing.Font($script:FontName, 9.5)
    $summaryFont = New-Object System.Drawing.Font($script:FontName, 9.5, [System.Drawing.FontStyle]::Underline)

    $box.SelectionFont  = $titleFont
    $box.SelectionColor = $script:MerlinBlue
    $box.AppendText("Search: `"$q`"")
    $box.SelectionFont  = $itemFont
    $box.SelectionColor = $script:ThMuted
    if (-not $allScopes) { $box.AppendText("   (scope: $scope)") }
    $box.AppendText("`n")

    if ($found.Count -eq 0) {
        $box.SelectionColor = $script:WarnOrange
        $box.AppendText("`nNo matches found in the scanned inventory.")
        $box.Tag = $lineMap
        Set-Redraw $box $true
        Set-Status "No matches for `"$q`"." $script:WarnOrange
        return
    }

    $servers = @($found | Select-Object -ExpandProperty Server -Unique)
    $box.SelectionFont  = $itemFont
    $box.SelectionColor = $script:ThMuted
    $box.AppendText("$($found.Count) match(es) across $($servers.Count) server(s). Click a category to filter, a server name to open it.`n`n")

    # Keep categories in the same order as the inventory fields
    $catOrder = @('Server Name') + ($script:FieldDefs | ForEach-Object { $_.Label })
    $cats = @($found | Select-Object -ExpandProperty Category -Unique |
        Sort-Object { $catOrder.IndexOf($_) })

    # --- Summary block: what kind of matches were found -------------------
    $box.SelectionFont  = $catFont
    $box.SelectionColor = $script:MerlinBlue
    $box.AppendText("Matches by category`n")
    foreach ($cat in $cats) {
        $rows    = @($found | Where-Object { $_.Category -eq $cat })
        $srvCnt  = @($rows | Select-Object -ExpandProperty Server -Unique).Count
        $lineMap[$box.GetLineFromCharIndex($box.TextLength)] = @{ Type = 'Category'; Value = $cat }
        $box.SelectionFont  = $summaryFont
        $box.SelectionColor = $script:MerlinBlue
        $box.AppendText(("   {0,-38}" -f $cat))
        $box.SelectionFont  = $itemFont
        $box.SelectionColor = $script:ThText
        $box.AppendText("  $($rows.Count) match(es) / $srvCnt server(s)`n")
    }
    if (-not $allScopes) {
        $lineMap[$box.GetLineFromCharIndex($box.TextLength)] = @{ Type = 'Category'; Value = $script:AllCategories }
        $box.SelectionFont  = $summaryFont
        $box.SelectionColor = $script:MerlinBlue
        $box.AppendText("   $($script:AllCategories)`n")
    }
    $box.AppendText("`n")

    # --- Results grouped by category, then by server ----------------------
    foreach ($cat in $cats) {
        $rows = @($found | Where-Object { $_.Category -eq $cat })
        $box.SelectionFont  = $catFont
        $box.SelectionColor = $script:MerlinBlue
        $box.AppendText("$cat  ($($rows.Count))`n")

        foreach ($srv in @($rows | Select-Object -ExpandProperty Server -Unique)) {
            $lineMap[$box.GetLineFromCharIndex($box.TextLength)] = @{ Type = 'Server'; Value = $srv }
            $box.SelectionFont  = $linkFont
            $box.SelectionColor = $script:MerlinBlue
            $box.AppendText("   >> $srv`n")
            foreach ($m in ($rows | Where-Object { $_.Server -eq $srv })) {
                $box.SelectionFont  = $itemFont
                $box.SelectionColor = $script:ThText
                $box.AppendText("        $($m.Value)`n")
            }
        }
        $box.AppendText("`n")
    }
    $box.Tag = $lineMap

    # Highlight every occurrence of the query in yellow
    $hl  = (New-Rgb 105 90 20)
    $pos = 0
    while (($pos = $box.Find($q, $pos, [System.Windows.Forms.RichTextBoxFinds]::None)) -ge 0) {
        $box.SelectionBackColor = $hl
        $pos += $q.Length
        if ($pos -ge $box.TextLength) { break }
    }

    Set-Redraw $box $true
    Scroll-ToTop $box

    # Select the first matching server in the tree as well
    foreach ($g in $tree.Nodes) {
        foreach ($n in $g.Nodes) {
            if ((Get-LeafName $n) -eq $servers[0]) { $tree.SelectedNode = $n; break }
        }
    }
    Set-Status "Found $($found.Count) match(es) for `"$q`" in $($cats.Count) categor(ies) on $($servers.Count) server(s)." $script:OkGreen
}

# ============================================================================
# Shared facts (v1.7): one normalised view of a scanned server, used by the
# Overview (risks + profiles) and by the Report Builder.
# ============================================================================
function HE($v) { return [Net.WebUtility]::HtmlEncode("$v") }

# Re-checks the official sources unless that already happened very recently
function Update-LifecycleIfStale([int]$maxAgeMinutes = 15) {
    if ($script:LifecycleRefreshed -and ((Get-Date) - $script:LifecycleRefreshed).TotalMinutes -lt $maxAgeMinutes) { return }
    Update-AllLifecycle
}

function Format-Day($d) { if ($d) { return ([datetime]$d).ToString('yyyy-MM-dd') } return '' }

# "C: 80GB total / 12GB free (%15)" -> objects (scan format since v1.0)
function Get-DiskList($r) {
    $out = @()
    foreach ($part in ("$($r.Disks)" -split ' \| ')) {
        if ($part -match '^\s*(\S+)\s+([\d\.,]+)GB total / ([\d\.,]+)GB free \(%([\d\.,]+)\)') {
            $out += [PSCustomObject]@{
                Drive   = $matches[1]
                TotalGB = [double]($matches[2] -replace ',', '.')
                FreeGB  = [double]($matches[3] -replace ',', '.')
                FreePct = [double]($matches[4] -replace ',', '.')
            }
        }
    }
    return $out
}

function Get-ShortLcStatus($lc) {
    if (-not $lc) { return 'No official date' }
    switch -Wildcard ("$($lc.Status)") {
        'EOL (paid ESU only)' { return 'Past end of support (ESU)' }
        'EOL'                 { return 'Past end of support' }
        'Extended*'           { return 'Extended support' }
        'Supported (no EOL*'  { return 'Supported (no end date)' }
        'Supported'           { return 'Supported' }
        default               { return 'No official date' }
    }
}

function Get-ServerFacts([string]$key) {
    $r   = $script:Results[$key]
    if (-not $r) { return $null }
    $inv = Get-Inv $r
    $osLc = Get-Lc (Get-OsLifecycleKey $r)
    $osName = if ($inv -and $inv.OS -and $inv.OS.Caption) { "$($inv.OS.Caption)" -replace '^Microsoft\s+', '' } else { ("$($r.OperatingSystem)" -replace '^Microsoft\s+', '' -replace '\s*\(.*$', '') }
    $build  = if ($inv -and $inv.OS -and $inv.OS.Build) { "$($inv.OS.Build)$(if ($inv.OS.UBR) { ".$($inv.OS.UBR)" })" } elseif ("$($r.OperatingSystem)" -match 'build (\d+)') { $matches[1] } else { '' }

    $dbs = @()
    if ($inv) {
        foreach ($db in @($inv.Databases | Where-Object { $_ })) {
            $lc = Get-Lc (Get-DbLifecycleKey $db)
            $dbs += [PSCustomObject]@{
                Product = "$($db.Product)"; Version = "$($db.Version)"; Edition = "$($db.Edition)"; Instance = "$($db.Instance)"
                IsEngine = ("$($db.Instance)" -ne '(no service)'); Installed = "$($db.InstallDate)"; Lc = $lc
                Name = $(if ($lc -and $lc.Release) { "$($lc.Release)" } else { "$($db.Product) $($db.Version)" })
            }
        }
    }
    $certs = @()
    if ($inv) {
        foreach ($c in @($inv.Certificates | Where-Object { $_ })) {
            $name = if (@($c.DnsNames | Where-Object { $_ }).Count) { "$(@($c.DnsNames)[0])" } elseif ($c.FriendlyName) { "$($c.FriendlyName)" } else { ("$($c.Subject)" -replace '^CN=', '' -replace ',.*$', '') }
            $certs += [PSCustomObject]@{
                Name = $name; Expires = ("$($c.NotAfter)" -split ' ')[0]; Days = (Get-DaysLeft $c.NotAfter)
                InUse = (@($c.BoundTo | Where-Object { $_ }).Count -gt 0); BoundTo = @($c.BoundTo | Where-Object { $_ })
                Issuer = ("$($c.Issuer)" -replace '^CN=', '' -replace ',.*$', '')
            }
        }
    }
    $iis = $null
    if ($inv -and $inv.IIS -and $inv.IIS.Version) {
        $iis = [PSCustomObject]@{ Version = "$($inv.IIS.Version)"; SiteCount = $inv.IIS.SiteCount; Sites = @($inv.IIS.Sites | Where-Object { $_ }); Lc = (Get-Lc (Get-IisLifecycleKey $r)) }
    }
    $disks = @(Get-DiskList $r)
    $minDisk = $null
    if ($disks.Count) { $minDisk = ($disks | Sort-Object FreePct | Select-Object -First 1) }
    $uptime = $null
    $boot = ConvertTo-LcDate (("$($r.LastRestartDate)" -split ' ')[0])
    if ($boot) { $uptime = [int]((Get-Date).Date - $boot).TotalDays }

    return [PSCustomObject]@{
        Key = $key; R = $r; Inv = $inv; Groups = @(Get-EffectiveGroups $key $r)
        OsName = $osName; Build = $build; OsLc = $osLc; OsStatus = (Get-ShortLcStatus $osLc)
        Databases = $dbs; Certs = $certs; Iis = $iis; Disks = $disks; MinDisk = $minDisk; UptimeDays = $uptime
    }
}

# ============================================================================
# Risks for the Overview (Critical first). The Overview highlights; the
# Report Builder output itself only shows what the user ticked.
#   Critical: OS / DB past end of support (no paid ESU), certificate in use
#             expired or expiring <= 14 days, a disk below 10 % free,
#             unreachable at the last scan
#   Warning : OS / DB in paid ESU or end of support <= 12 months, certificate
#             in use expiring <= 60 days, a disk below 20 % free
# ============================================================================
$script:LastUnreachable = @()

function Get-RiskItems {
    $items = New-Object System.Collections.Generic.List[object]
    $add = {
        param($level, $key, $area, $item, $detail, $date)
        $items.Add([PSCustomObject]@{ Level = $level; Server = $key; Area = $area; Item = $item; Detail = $detail; Date = $date })
    }
    foreach ($key in @($script:Results.Keys | Sort-Object)) {
        $f = Get-ServerFacts $key
        if (-not $f) { continue }
        # Operating system
        $lc = $f.OsLc
        if ($lc) {
            if ($lc.Status -eq 'EOL') { & $add 'Critical' $key 'OS' $f.OsName 'Past end of support' (Format-Day $lc.EOL) }
            elseif ($lc.Status -eq 'EOL (paid ESU only)') { & $add 'Warning' $key 'OS' $f.OsName "Past end of support, paid ESU until $(Format-Day $lc.ESUEnd)" (Format-Day $lc.EOL) }
            elseif ($null -ne $lc.DaysToEOL -and $lc.DaysToEOL -le 365) { & $add 'Warning' $key 'OS' $f.OsName "End of support in $($lc.DaysToEOL) days" (Format-Day $lc.EOL) }
        }
        # Database engines (packages without a service are not engines)
        foreach ($db in @($f.Databases | Where-Object { $_.IsEngine })) {
            $l = $db.Lc
            if (-not $l) { continue }
            if ($l.Status -eq 'EOL') { & $add 'Critical' $key 'Database' $db.Name 'Past end of support' (Format-Day $l.EOL) }
            elseif ($l.Status -eq 'EOL (paid ESU only)') { & $add 'Warning' $key 'Database' $db.Name "Past end of support, paid ESU until $(Format-Day $l.ESUEnd)" (Format-Day $l.EOL) }
            elseif ($null -ne $l.DaysToEOL -and $l.DaysToEOL -le 365) { & $add 'Warning' $key 'Database' $db.Name "End of support in $($l.DaysToEOL) days" (Format-Day $l.EOL) }
        }
        # Certificates bound to IIS
        foreach ($c in @($f.Certs | Where-Object { $_.InUse -and $null -ne $_.Days })) {
            $where = (@($c.BoundTo) -join ', ')
            if ($c.Days -lt 0) { & $add 'Critical' $key 'Certificate' $c.Name "Expired $(-$c.Days) days ago - in use: $where" $c.Expires }
            elseif ($c.Days -le 14) { & $add 'Critical' $key 'Certificate' $c.Name "Expires in $($c.Days) days - in use: $where" $c.Expires }
            elseif ($c.Days -le 60) { & $add 'Warning' $key 'Certificate' $c.Name "Expires in $($c.Days) days - in use: $where" $c.Expires }
        }
        # Disks
        foreach ($d in $f.Disks) {
            $txt = "$($d.FreeGB) GB free of $($d.TotalGB) GB ($($d.FreePct)%)"
            if ($d.FreePct -lt 10) { & $add 'Critical' $key 'Disk' $d.Drive $txt '' }
            elseif ($d.FreePct -lt 20) { & $add 'Warning' $key 'Disk' $d.Drive $txt '' }
        }
    }
    foreach ($u in @($script:LastUnreachable)) { & $add 'Critical' "$u".ToUpper() 'Scan' 'Unreachable' 'Not reachable at the last scan (WinRM)' '' }
    $rank = @{ Critical = 0; Warning = 1 }
    return @($items | Sort-Object { $rank[$_.Level] }, Area, Server)
}

# ============================================================================
# Dark theme
# ============================================================================
function Set-DarkWindow($ctrl) {
    if (-not $script:DarkNative) { return }
    try {
        if ($ctrl -is [System.Windows.Forms.Form]) { [SwDark]::TitleBar($ctrl.Handle) }
        else { [SwDark]::Scrollbars($ctrl.Handle) }
    } catch {}
}

function Set-GridDark([System.Windows.Forms.DataGridView]$grid) {
    $grid.BackgroundColor = $script:ThBg
    $grid.GridColor = $script:ThLine
    $grid.BorderStyle = 'None'
    $grid.EnableHeadersVisualStyles = $false
    $grid.RowHeadersVisible = $false
    $grid.CellBorderStyle = 'SingleHorizontal'
    $grid.ColumnHeadersBorderStyle = 'None'
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $script:ThPanel
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:ThMuted
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:ThPanel
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font($script:FontName, 8.5, [System.Drawing.FontStyle]::Bold)
    $grid.ColumnHeadersHeight = 26
    $grid.DefaultCellStyle.BackColor = $script:ThBg
    $grid.DefaultCellStyle.ForeColor = $script:ThText
    $grid.DefaultCellStyle.SelectionBackColor = $script:ThSelect
    $grid.DefaultCellStyle.SelectionForeColor = $script:ThText
    $grid.DefaultCellStyle.Font = New-Object System.Drawing.Font($script:FontName, 8.75)
    $grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $script:ThAlt
    $grid.RowTemplate.Height = 22
    Set-DarkWindow $grid
}

# Walks a control tree and applies the palette. Controls that set their own
# accent colours (blue buttons, coloured labels) keep them.
function Set-DarkTheme($ctrl) {
    try {
        $t = $ctrl.GetType().Name
        switch ($t) {
            'Form'      { $ctrl.BackColor = $script:ThBg; $ctrl.ForeColor = $script:ThText; Set-DarkWindow $ctrl }
            'TabPage'   { $ctrl.UseVisualStyleBackColor = $false; $ctrl.BackColor = $script:ThBg; $ctrl.ForeColor = $script:ThText }
            'GroupBox'  { $ctrl.BackColor = $script:ThBg }
            'Panel'     { if ($ctrl.BackColor -eq [System.Drawing.SystemColors]::Control -or $ctrl.BackColor -eq [System.Drawing.Color]::White) { $ctrl.BackColor = $script:ThBg }; $ctrl.ForeColor = $script:ThText }
            'SplitContainer' { $ctrl.BackColor = $script:ThLine }
            'TextBox'   { $ctrl.BackColor = $script:ThSurface; $ctrl.ForeColor = $script:ThText; $ctrl.BorderStyle = 'FixedSingle' }
            'ComboBox'  { $ctrl.BackColor = $script:ThSurface; $ctrl.ForeColor = $script:ThText; $ctrl.FlatStyle = 'Flat' }
            'NumericUpDown' { $ctrl.BackColor = $script:ThSurface; $ctrl.ForeColor = $script:ThText; $ctrl.BorderStyle = 'FixedSingle' }
            'RichTextBox' { $ctrl.BackColor = $script:ThBg; $ctrl.ForeColor = $script:ThText; $ctrl.BorderStyle = 'None'; Set-DarkWindow $ctrl }
            'TreeView'  { $ctrl.BackColor = $script:ThPanel; $ctrl.ForeColor = $script:ThText; $ctrl.BorderStyle = 'None'; $ctrl.LineColor = $script:ThMuted; Set-DarkWindow $ctrl }
            'CheckedListBox' { $ctrl.BackColor = $script:ThPanel; $ctrl.ForeColor = $script:ThText; $ctrl.BorderStyle = 'None'; Set-DarkWindow $ctrl }
            'ListBox'   { $ctrl.BackColor = $script:ThPanel; $ctrl.ForeColor = $script:ThText; $ctrl.BorderStyle = 'None' }
            'DataGridView' { Set-GridDark $ctrl }
            'Button' {
                $ctrl.FlatStyle = 'Flat'
                $ctrl.FlatAppearance.BorderColor = $script:ThLine
                if ($ctrl.BackColor -ne $script:ThAccent) { $ctrl.BackColor = $script:ThSurface; $ctrl.ForeColor = $script:ThText }
                else { $ctrl.FlatAppearance.BorderColor = $script:ThAccent; $ctrl.ForeColor = [System.Drawing.Color]::White }
            }
            'LinkLabel' { $ctrl.LinkColor = $script:ThAccent; $ctrl.ActiveLinkColor = $script:ThText; $ctrl.BackColor = [System.Drawing.Color]::Transparent }
            'StatusStrip' { $ctrl.BackColor = $script:ThPanel; $ctrl.ForeColor = $script:ThText; $ctrl.SizingGrip = $false; $ctrl.RenderMode = 'System' }
            default { }
        }
        if ($t -in 'Label', 'CheckBox', 'RadioButton') {
            if ($ctrl.ForeColor -eq [System.Drawing.SystemColors]::ControlText -or $ctrl.ForeColor -eq $script:ThText) { $ctrl.ForeColor = $script:ThText }
        }
        foreach ($c in $ctrl.Controls) { Set-DarkTheme $c }
    }
    catch { Write-Log "Theme: $($ctrl.GetType().Name): $($_.Exception.Message)" }
}

# ============================================================================
# Home: a permanent risk dashboard (first tab, cannot be closed, shown
# whenever no other tab is open). Risk cards by type -> affected servers.
# ============================================================================
function New-InfoLabel([string]$text, [single]$size = 9, [bool]$bold = $false) {
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true; $l.Text = $text; $l.ForeColor = $script:ThText
    $l.Font = New-Object System.Drawing.Font($script:FontName, $size, $(if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    return $l
}

function New-DarkGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'; $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.AllowUserToResizeRows = $false
    $g.SelectionMode = 'FullRowSelect'; $g.MultiSelect = $false
    $g.AutoSizeColumnsMode = 'None'
    Set-DoubleBuffered $g
    Set-GridDark $g
    $g.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        try { $v = "$($s.Rows[$e.RowIndex].Cells['Server'].Value)"; if ($v -and $script:Results.ContainsKey($v)) { Open-ServerTab $v } } catch {}
    })
    return $g
}

function Set-GridRows([System.Windows.Forms.DataGridView]$grid, [string[]]$cols, $rows, [hashtable]$widths) {
    $grid.SuspendLayout()
    $grid.Rows.Clear()
    $grid.Columns.Clear()
    foreach ($c in $cols) {
        $i = $grid.Columns.Add($c, $c)
        $col = $grid.Columns[$i]
        $col.SortMode = 'Automatic'
        if ($widths.ContainsKey($c)) {
            if ($widths[$c] -eq 0) { $col.AutoSizeMode = 'Fill' } else { $col.Width = $widths[$c] }
        }
        else { $col.Width = 110 }
    }
    foreach ($r in @($rows)) {
        $vals = @(foreach ($c in $cols) { "$($r.$c)" })
        [void]$grid.Rows.Add([object[]]$vals)
    }
    $grid.ResumeLayout()
}

# Card definitions: Level + Area of Get-RiskItems
$script:HomeCards = @(
    @{ Id = 'C-OS';   Level = 'Critical'; Area = 'OS';          Title = 'OS past end of support' },
    @{ Id = 'C-DB';   Level = 'Critical'; Area = 'Database';    Title = 'Database past end of support' },
    @{ Id = 'C-CERT'; Level = 'Critical'; Area = 'Certificate'; Title = 'IIS certificate expired / <= 14 days' },
    @{ Id = 'C-DISK'; Level = 'Critical'; Area = 'Disk';        Title = 'Disk below 10% free' },
    @{ Id = 'C-SCAN'; Level = 'Critical'; Area = 'Scan';        Title = 'Unreachable at last scan' },
    @{ Id = 'W-OS';   Level = 'Warning';  Area = 'OS';          Title = 'OS in ESU / ends within 12 months' },
    @{ Id = 'W-DB';   Level = 'Warning';  Area = 'Database';    Title = 'Database ends within 12 months' },
    @{ Id = 'W-CERT'; Level = 'Warning';  Area = 'Certificate'; Title = 'IIS certificate <= 60 days' },
    @{ Id = 'W-DISK'; Level = 'Warning';  Area = 'Disk';        Title = 'Disk below 20% free' }
)
$script:HomeFilter = 'ALL-C'
$script:HomeRisks  = @()

function New-HomeCard($def) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size(212, 70)
    $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
    $p.BackColor = $script:ThPanel
    $p.Cursor = [System.Windows.Forms.Cursors]::Hand
    $p.Tag = $def.Id
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Left'; $bar.Width = 4; $bar.Tag = $def.Id
    $num = New-InfoLabel '0' 18 $true
    $num.Location = New-Object System.Drawing.Point(12, 4); $num.Tag = $def.Id
    $sub = New-InfoLabel '' 8
    $sub.ForeColor = $script:ThMuted; $sub.Tag = $def.Id
    $sub.Location = New-Object System.Drawing.Point(64, 16)
    $cap = New-InfoLabel $def.Title 8.5
    $cap.Location = New-Object System.Drawing.Point(12, 44); $cap.Tag = $def.Id
    $cap.MaximumSize = New-Object System.Drawing.Size(196, 0)
    $p.Controls.AddRange(@($num, $sub, $cap, $bar))
    $click = { param($s, $e) $script:HomeFilter = "$($s.Tag)"; Update-HomeList }
    foreach ($c in @($p, $bar, $num, $sub, $cap)) { $c.Add_Click($click) }
    return @{ Panel = $p; Bar = $bar; Num = $num; Sub = $sub; Def = $def }
}

function Update-HomeList {
    $ui = $script:HomeUi
    if (-not $ui) { return }
    $f = $script:HomeFilter
    $rows = @($script:HomeRisks)
    $title = 'All risks'
    if ($f -eq 'ALL-C') { $rows = @($rows | Where-Object { $_.Level -eq 'Critical' }); $title = 'All critical risks' }
    elseif ($f -ne 'ALL') {
        $def = $script:HomeCards | Where-Object { $_.Id -eq $f } | Select-Object -First 1
        if ($def) { $rows = @($rows | Where-Object { $_.Level -eq $def.Level -and $_.Area -eq $def.Area }); $title = "$($def.Level): $($def.Title)" }
    }
    $nSrv = @($rows | ForEach-Object { $_.Server } | Sort-Object -Unique).Count
    $ui.ListTitle.Text = "$title  -  $($rows.Count) item(s) on $nSrv server(s).  Double-click a row to open the server."
    Set-GridRows $ui.Grid @('Level', 'Server', 'Item', 'Detail', 'Date', 'Roles') $rows @{ Level = 70; Server = 160; Item = 230; Detail = 0; Date = 90; Roles = 200 }
    foreach ($card in $ui.Cards) {
        $sel = ($card.Def.Id -eq $f)
        $card.Panel.BackColor = $(if ($sel) { $script:ThSelect } else { $script:ThPanel })
    }
    $ui.LnkCrit.LinkVisited = ($f -eq 'ALL-C'); $ui.LnkAll.LinkVisited = ($f -eq 'ALL')
}

function Update-Overview {
    $ui = $script:HomeUi
    if (-not $ui) { return }
    try {
        $keys = @($script:Results.Keys)
        if ($keys.Count -eq 0) {
            $script:HomeRisks = @()
            $ui.Kpi.Text = 'No inventory yet. Load the servers from AD (left), then run a scan.'
        }
        else {
            $risks = @(Get-RiskItems)
            foreach ($x in $risks) {
                $roles = if ($script:Results.ContainsKey($x.Server)) { @(Get-EffectiveGroups $x.Server $script:Results[$x.Server]) -join ', ' } else { '' }
                $x | Add-Member -NotePropertyName Roles -NotePropertyValue $roles -Force
            }
            $script:HomeRisks = $risks
            $crit = @($risks | Where-Object { $_.Level -eq 'Critical' })
            $warn = @($risks | Where-Object { $_.Level -eq 'Warning' })
            $srvC = @($crit | ForEach-Object { $_.Server } | Sort-Object -Unique).Count
            $srvW = @($warn | ForEach-Object { $_.Server } | Sort-Object -Unique).Count
            $ui.Kpi.Text = "$($keys.Count) servers in inventory   |   $srvC with critical risks   |   $srvW with warnings"
        }
        foreach ($card in $ui.Cards) {
            $d = $card.Def
            $items = @($script:HomeRisks | Where-Object { $_.Level -eq $d.Level -and $_.Area -eq $d.Area })
            $nS = @($items | ForEach-Object { $_.Server } | Sort-Object -Unique).Count
            $card.Num.Text = "$nS"
            $card.Sub.Text = if ($nS -eq 1) { 'server' } else { 'servers' }
            $card.Sub.Left = $card.Num.Right + 2
            $tone = if ($nS -eq 0) { $script:ThLine } elseif ($d.Level -eq 'Critical') { $script:ThBad } else { $script:ThWarn }
            $card.Bar.BackColor = $tone
            $card.Num.ForeColor = $(if ($nS -eq 0) { $script:ThMuted } else { $tone })
        }
        $when = if ($script:LifecycleRefreshed) { $script:LifecycleRefreshed.ToString('yyyy-MM-dd HH:mm') } else { 'not yet checked' }
        $ui.Foot.Text = "Support dates: official vendor pages, checked $when.   Click a card to list its servers."
        Update-HomeList
    }
    catch {
        Write-Log "HOME FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        $ui.Kpi.Text = "Home could not be built: $($_.Exception.Message) (see log)"
    }
}

function Show-Overview([bool]$select = $true) {
    try {
        if (-not $script:HomeUi) {
            $tp = New-Object System.Windows.Forms.TabPage ('Home')
            $tp.UseVisualStyleBackColor = $false; $tp.BackColor = $script:ThBg
            $root = New-Object System.Windows.Forms.TableLayoutPanel
            $root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 8; $root.BackColor = $script:ThBg
            $root.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 6)
            foreach ($i in 1..6) { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
            [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
            [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

            $kpi = New-InfoLabel '' 10 $true
            $kpi.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
            $mkHead = { param($t, $c) $l = New-InfoLabel $t 9 $true; $l.ForeColor = $c; $l.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 4); $l }
            $hCrit = & $mkHead 'CRITICAL' $script:ThBad
            $hWarn = & $mkHead 'WARNING' $script:ThWarn
            $mkFlow = {
                $fl = New-Object System.Windows.Forms.FlowLayoutPanel
                $fl.AutoSize = $true; $fl.AutoSizeMode = 'GrowAndShrink'; $fl.WrapContents = $true
                $fl.Dock = 'Fill'; $fl.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4); $fl.BackColor = $script:ThBg
                $fl
            }
            $flC = & $mkFlow; $flW = & $mkFlow
            $cards = @()
            foreach ($d in $script:HomeCards) {
                $c = New-HomeCard $d
                if ($d.Level -eq 'Critical') { $flC.Controls.Add($c.Panel) } else { $flW.Controls.Add($c.Panel) }
                $cards += $c
            }
            # List header: title + quick links
            $pHead = New-Object System.Windows.Forms.FlowLayoutPanel
            $pHead.AutoSize = $true; $pHead.WrapContents = $false; $pHead.Dock = 'Fill'; $pHead.BackColor = $script:ThBg
            $pHead.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 4)
            $listTitle = New-InfoLabel '' 9 $true
            $listTitle.ForeColor = $script:ThAccent
            $lnkCrit = New-Object System.Windows.Forms.LinkLabel
            $lnkCrit.Text = 'All critical'; $lnkCrit.AutoSize = $true; $lnkCrit.Margin = New-Object System.Windows.Forms.Padding(18, 1, 0, 0)
            $lnkAll = New-Object System.Windows.Forms.LinkLabel
            $lnkAll.Text = 'All risks'; $lnkAll.AutoSize = $true; $lnkAll.Margin = New-Object System.Windows.Forms.Padding(10, 1, 0, 0)
            foreach ($l in @($lnkCrit, $lnkAll)) { $l.LinkColor = $script:ThAccent; $l.VisitedLinkColor = $script:ThText; $l.ActiveLinkColor = $script:ThText }
            $lnkCrit.Add_LinkClicked({ $script:HomeFilter = 'ALL-C'; Update-HomeList })
            $lnkAll.Add_LinkClicked({ $script:HomeFilter = 'ALL'; Update-HomeList })
            $pHead.Controls.AddRange(@($listTitle, $lnkCrit, $lnkAll))

            $grid = New-DarkGrid
            $grid.Add_CellFormatting({
                param($s, $e)
                try {
                    if ($s.Columns[$e.ColumnIndex].Name -eq 'Level') {
                        $e.CellStyle.ForeColor = $(if ("$($e.Value)" -eq 'Critical') { $script:ThBad } else { $script:ThWarn })
                    }
                } catch {}
            })
            $foot = New-InfoLabel '' 8
            $foot.ForeColor = $script:ThMuted
            $foot.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)

            $root.Controls.Add($kpi, 0, 0)
            $root.Controls.Add($hCrit, 0, 1)
            $root.Controls.Add($flC, 0, 2)
            $root.Controls.Add($hWarn, 0, 3)
            $root.Controls.Add($flW, 0, 4)
            $root.Controls.Add($pHead, 0, 5)
            $root.Controls.Add($grid, 0, 6)
            $root.Controls.Add($foot, 0, 7)
            $tp.Controls.Add($root)
            $tabs.TabPages.Insert(0, $tp)
            $script:HomeUi = @{ Tab = $tp; Kpi = $kpi; Cards = $cards; Grid = $grid; ListTitle = $listTitle; LnkCrit = $lnkCrit; LnkAll = $lnkAll; Foot = $foot }
        }
        elseif (-not $tabs.TabPages.Contains($script:HomeUi.Tab)) { $tabs.TabPages.Insert(0, $script:HomeUi.Tab) }
        Update-Overview
        if ($select) { $tabs.SelectedTab = $script:HomeUi.Tab }
    }
    catch { Write-Log "HOME TAB FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
}

# ============================================================================
# Report Builder: the user ticks groups, columns and (optional) conditions.
# Nothing is pre-selected and a group never implies a filter or a column.
# ============================================================================
function Join-Items($list) { return ((@($list) | Where-Object { "$_" -ne '' }) -join "`n") }
function Get-FieldItems($r, [string]$name, [string]$sep) {
    $p = $r.PSObject.Properties[$name]
    if (-not $p -or -not "$($p.Value)") { return '' }
    $v = "$($p.Value)"
    if ($v -match '^(N/A|None)\b') { return $v }
    if ($sep) { return (Join-Items ($v -split [regex]::Escape($sep) | ForEach-Object { "$_".Trim() })) }
    return $v
}

function Get-DbEolText($db) {
    $t = 'no official date'
    if ($db.Lc -and $db.Lc.EOL) { $t = Format-Day $db.Lc.EOL }
    elseif ($db.Lc -and ([string]$db.Lc.Status) -like 'Supported (no EOL*') { $t = 'no end date announced' }
    return "$($db.Name): $t"
}

# Each column: Id, Category, Label, Get = { param($f) ... } -> text
$script:ReportColumns = @(
    @{ Id='roles';     Cat='General';      Label='Role groups';                 Get={ param($f) (@($f.Groups) -join ', ') } },
    @{ Id='os';        Cat='General';      Label='Operating system';            Get={ param($f) $f.OsName } },
    @{ Id='build';     Cat='General';      Label='OS build';                    Get={ param($f) $f.Build } },
    @{ Id='osinst';    Cat='General';      Label='OS install date';             Get={ param($f) ("$($f.R.InstallDate)" -split ' ')[0] } },
    @{ Id='restart';   Cat='General';      Label='Last restart';                Get={ param($f) "$($f.R.LastRestartDate)" } },
    @{ Id='uptime';    Cat='General';      Label='Uptime (days)';               Get={ param($f) "$($f.UptimeDays)" } },
    @{ Id='domain';    Cat='General';      Label='Domain';                      Get={ param($f) "$($f.R.Domain)" } },
    @{ Id='ip';        Cat='General';      Label='IP addresses';                Get={ param($f) Get-FieldItems $f.R 'IPAddresses' '; ' } },
    @{ Id='ossup';     Cat='OS lifecycle'; Label='OS support status';           Get={ param($f) $f.OsStatus } },
    @{ Id='osmain';    Cat='OS lifecycle'; Label='OS mainstream support end';   Get={ param($f) if ($f.OsLc) { Format-Day $f.OsLc.SupportEnd } } },
    @{ Id='oseol';     Cat='OS lifecycle'; Label='OS end of support (EOL)';     Get={ param($f) if ($f.OsLc) { Format-Day $f.OsLc.EOL } } },
    @{ Id='osesu';     Cat='OS lifecycle'; Label='OS paid ESU end';             Get={ param($f) if ($f.OsLc) { Format-Day $f.OsLc.ESUEnd } } },
    @{ Id='osdays';    Cat='OS lifecycle'; Label='OS days to EOL';              Get={ param($f) if ($f.OsLc) { "$($f.OsLc.DaysToEOL)" } } },
    @{ Id='ossrc';     Cat='OS lifecycle'; Label='OS lifecycle source';         Get={ param($f) if ($f.OsLc) { "$($f.OsLc.Source)" } } },
    @{ Id='cpu';       Cat='Hardware';     Label='CPU';                         Get={ param($f) "$($f.R.CPU)" } },
    @{ Id='cores';     Cat='Hardware';     Label='Logical cores';               Get={ param($f) "$($f.R.LogicalCores)" } },
    @{ Id='ram';       Cat='Hardware';     Label='RAM (GB)';                    Get={ param($f) "$($f.R.TotalRAM_GB)" } },
    @{ Id='disks';     Cat='Disks';        Label='Disks (free / total)';        Get={ param($f) Join-Items (@($f.Disks) | ForEach-Object { "$($_.Drive) $($_.FreeGB) / $($_.TotalGB) GB ($($_.FreePct)% free)" }) } },
    @{ Id='diskmin';   Cat='Disks';        Label='Lowest free space (%)';       Get={ param($f) if ($f.MinDisk) { "$($f.MinDisk.Drive) $($f.MinDisk.FreePct)%" } } },
    @{ Id='diskfree';  Cat='Disks';        Label='Free space (GB, all drives)'; Get={ param($f) if (@($f.Disks).Count) { "$([math]::Round((@($f.Disks) | Measure-Object FreeGB -Sum).Sum, 1))" } } },
    @{ Id='iisver';    Cat='IIS';          Label='IIS version';                 Get={ param($f) if ($f.Iis) { "IIS $($f.Iis.Version)" } } },
    @{ Id='iissites';  Cat='IIS';          Label='IIS sites';                   Get={ param($f) if ($f.Iis) { Join-Items $f.Iis.Sites } } },
    @{ Id='iisdns';    Cat='IIS';          Label='Site DNS names';              Get={ param($f) Get-FieldItems $f.R 'SiteDNSNames' '; ' } },
    @{ Id='iisssl';    Cat='IIS';          Label='SSL bindings';                Get={ param($f) Get-FieldItems $f.R 'SSLBindings' ' ;; ' } },
    @{ Id='iiseol';    Cat='IIS';          Label='IIS end of support';          Get={ param($f) if ($f.Iis -and $f.Iis.Lc) { Format-Day $f.Iis.Lc.EOL } } },
    @{ Id='dbprod';    Cat='Database';     Label='Database engines and versions'; Get={ param($f) Join-Items (@($f.Databases | Where-Object { $_.IsEngine }) | ForEach-Object { "$($_.Product) $($_.Version)$(if ($_.Edition) { " - $($_.Edition)" })" }) } },
    @{ Id='dbinst';    Cat='Database';     Label='Database install date';       Get={ param($f) Join-Items (@($f.Databases | Where-Object { $_.IsEngine }) | ForEach-Object { "$($_.Product): $($_.Installed)" }) } },
    @{ Id='dbsup';     Cat='Database';     Label='Database support status';     Get={ param($f) Join-Items (@($f.Databases | Where-Object { $_.IsEngine }) | ForEach-Object { "$($_.Name): $(Get-ShortLcStatus $_.Lc)" }) } },
    @{ Id='dbeol';     Cat='Database';     Label='Database end of support (EOL)'; Get={ param($f) Join-Items (@($f.Databases | Where-Object { $_.IsEngine }) | ForEach-Object { Get-DbEolText $_ }) } },
    @{ Id='dbclient';  Cat='Database';     Label='Database client packages';    Get={ param($f) Join-Items (@($f.Databases | Where-Object { -not $_.IsEngine }) | ForEach-Object { "$($_.Product) $($_.Version)" }) } },
    @{ Id='sqlinst';   Cat='Database';     Label='SQL instances (detailed)';    Get={ param($f) Get-FieldItems $f.R 'SQLInstanceDetails' ' | ' } },
    @{ Id='certuse';   Cat='Certificates'; Label='Certificates in use (expiry)'; Get={ param($f) Join-Items (@($f.Certs | Where-Object { $_.InUse } | Sort-Object Days) | ForEach-Object { "$($_.Name) - $($_.Expires) ($($_.Days) d)" }) } },
    @{ Id='certall';   Cat='Certificates'; Label='All certificates (expiry)';   Get={ param($f) Join-Items (@($f.Certs | Sort-Object Days) | ForEach-Object { "$($_.Name) - $($_.Expires) ($($_.Days) d)$(if ($_.InUse) { ' in use' })" }) } },
    @{ Id='certnext';  Cat='Certificates'; Label='Next in-use expiry';          Get={ param($f) $c = @($f.Certs | Where-Object { $_.InUse -and $null -ne $_.Days } | Sort-Object Days); if ($c.Count) { "$($c[0].Expires) ($($c[0].Days) d)" } } },
    @{ Id='winroles';  Cat='Roles and software'; Label='Windows roles and role services'; Get={ param($f) Get-FieldItems $f.R 'RolesDetail' ' ;; ' } },
    @{ Id='winfeat';   Cat='Roles and software'; Label='Windows features';      Get={ param($f) Get-FieldItems $f.R 'FeaturesDetail' ' ;; ' } },
    @{ Id='3psvc';     Cat='Roles and software'; Label='3rd party services (running)'; Get={ param($f) Get-FieldItems $f.R 'ThirdPartyServices' '; ' } },
    @{ Id='3psw';      Cat='Roles and software'; Label='3rd party software';    Get={ param($f) Get-FieldItems $f.R 'ThirdPartyProducts' '; ' } },
    @{ Id='mssw';      Cat='Roles and software'; Label='Microsoft products';    Get={ param($f) Get-FieldItems $f.R 'MicrosoftProducts' '; ' } },
    @{ Id='autosvc';   Cat='Roles and software'; Label='Automatic services';    Get={ param($f) Get-FieldItems $f.R 'AutomaticServices' '; ' } },
    @{ Id='ports';     Cat='Roles and software'; Label='Listening TCP ports';   Get={ param($f) "$($f.R.ListeningPorts)" } },
    @{ Id='rdp';       Cat='Roles and software'; Label='Last RDP logons';       Get={ param($f) Get-FieldItems $f.R 'LastRDPLogons' ' | ' } }
)

# Optional conditions; a server is listed when it matches ALL (or ANY) ticked ones
$script:ReportFilters = @(
    @{ Id='disk20';  Label='A disk below 20% free';                   Test={ param($f) @($f.Disks | Where-Object { $_.FreePct -lt 20 }).Count -gt 0 } },
    @{ Id='disk10';  Label='A disk below 10% free';                   Test={ param($f) @($f.Disks | Where-Object { $_.FreePct -lt 10 }).Count -gt 0 } },
    @{ Id='oseol';   Label='OS past end of support';                  Test={ param($f) $f.OsLc -and "$($f.OsLc.Status)" -like 'EOL*' } },
    @{ Id='oseol12'; Label='OS end of support within 12 months';      Test={ param($f) $f.OsLc -and $null -ne $f.OsLc.DaysToEOL -and $f.OsLc.DaysToEOL -ge 0 -and $f.OsLc.DaysToEOL -le 365 } },
    @{ Id='dbeol';   Label='Database past end of support';            Test={ param($f) @($f.Databases | Where-Object { $_.IsEngine -and $_.Lc -and "$($_.Lc.Status)" -like 'EOL*' }).Count -gt 0 } },
    @{ Id='hasdb';   Label='Has a database engine';                   Test={ param($f) @($f.Databases | Where-Object { $_.IsEngine }).Count -gt 0 } },
    @{ Id='hasiis';  Label='Has IIS';                                 Test={ param($f) $null -ne $f.Iis } },
    @{ Id='cert30';  Label='Certificate in use expires within 30 days (or expired)'; Test={ param($f) @($f.Certs | Where-Object { $_.InUse -and $null -ne $_.Days -and $_.Days -le 30 }).Count -gt 0 } },
    @{ Id='cert90';  Label='Certificate in use expires within 90 days (or expired)'; Test={ param($f) @($f.Certs | Where-Object { $_.InUse -and $null -ne $_.Days -and $_.Days -le 90 }).Count -gt 0 } },
    @{ Id='uptime30'; Label='Not restarted for 30+ days';             Test={ param($f) $null -ne $f.UptimeDays -and $f.UptimeDays -ge 30 } }
)

# Builds the report data: one section per ticked group (or one table)
function Get-BuilderData {
    param([string[]]$Groups, [string[]]$Columns, [string[]]$Filters = @(), [bool]$MatchAll = $true,
          [bool]$OneTable = $false, [string[]]$Servers = @())
    $cols = @($script:ReportColumns | Where-Object { $Columns -contains $_.Id })
    $flts = @($script:ReportFilters | Where-Object { $Filters -contains $_.Id })
    $pool = if (@($Servers).Count) { @($Servers | Where-Object { $script:Results.ContainsKey($_) }) } else { @($script:Results.Keys) }
    $sections = [ordered]@{}
    if ($OneTable) { $sections['All selected groups'] = New-Object System.Collections.Generic.List[object] }
    else { foreach ($g in $Groups) { $sections[$g] = New-Object System.Collections.Generic.List[object] } }
    $seen = @{}
    foreach ($key in @($pool | Sort-Object)) {
        $f = Get-ServerFacts $key
        if (-not $f) { continue }
        $hit = @($f.Groups | Where-Object { $Groups -contains $_ })
        if ($hit.Count -eq 0) { continue }
        if ($flts.Count) {
            $res = @(foreach ($x in $flts) { [bool](& $x.Test $f) })
            $ok = if ($MatchAll) { -not ($res -contains $false) } else { $res -contains $true }
            if (-not $ok) { continue }
        }
        $row = [ordered]@{ Server = $key }
        if ($OneTable) { $row['Groups'] = ($hit -join ', ') }
        foreach ($c in $cols) {
            $v = ''
            try { $v = "$(& $c.Get $f)" } catch { $v = '' }
            $row[$c.Label] = $v
        }
        if ($OneTable) { if (-not $seen.ContainsKey($key)) { $sections['All selected groups'].Add([PSCustomObject]$row); $seen[$key] = $true } }
        else { foreach ($g in $hit) { $sections[$g].Add([PSCustomObject]$row) } }
    }
    # Plain arrays (a generic List inside @() fails on some PowerShell builds)
    foreach ($k in @($sections.Keys)) { $sections[$k] = [object[]]$sections[$k].ToArray() }
    return @{ Sections = $sections; Columns = @($cols | ForEach-Object { $_.Label }); Filters = @($flts | ForEach-Object { $_.Label }); OneTable = $OneTable }
}

$script:BuilderCss = @'
*{box-sizing:border-box}html{-webkit-print-color-adjust:exact;print-color-adjust:exact}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:12px;color:#1d2433;margin:0;background:#fff}
header{padding:14px 22px 10px;border-bottom:2px solid #1f3a93}
h1{font-size:18px;margin:0 0 4px;color:#1f3a93}
.meta{color:#5f6b7a;font-size:11px;line-height:1.5}.meta b{color:#1d2433;font-weight:600}
main{padding:4px 22px 18px}
h2{font-size:14px;color:#1f3a93;margin:16px 0 6px}h2 span{color:#5f6b7a;font-weight:400;font-size:12px}
table{border-collapse:collapse;width:100%;font-size:11px}
th{background:#eef2fc;color:#1d2433;text-align:left;vertical-align:bottom;padding:5px 7px;border-bottom:1px solid #c8d1e6;cursor:pointer;min-width:60px}
td{padding:4px 7px;border-bottom:1px solid #e3e7ee;vertical-align:top;white-space:pre-line;overflow-wrap:anywhere}
table.wide{font-size:9.5px}table.wide td,table.wide th{padding:3px 4px}
td:first-child{font-weight:600;white-space:nowrap}
tr:nth-child(even) td{background:#fafbfd}
.empty{color:#5f6b7a;font-style:italic;padding:4px 0}
footer{color:#5f6b7a;font-size:10px;padding:6px 22px 16px;border-top:1px solid #e3e7ee}
@page{size:A4 landscape;margin:10mm}
@media print{body{font-size:10px}table{font-size:9.5px}table.wide{font-size:7.5px}th{cursor:default}thead{display:table-header-group}tr{break-inside:avoid}h2{break-after:avoid}}
'@

$script:BuilderJs = @'
(function(){var ths=document.querySelectorAll("th");Array.prototype.forEach.call(ths,function(th){th.addEventListener("click",function(){
var tb=th.closest("table").tBodies[0],i=Array.prototype.indexOf.call(th.parentNode.children,th),d=th.getAttribute("data-d")==="1"?-1:1;
Array.prototype.forEach.call(th.parentNode.children,function(x){x.removeAttribute("data-d");});th.setAttribute("data-d",d===1?"1":"0");
var rows=Array.prototype.slice.call(tb.rows);rows.sort(function(a,b){var x=a.cells[i].textContent,y=b.cells[i].textContent,nx=parseFloat(x),ny=parseFloat(y);
if(!isNaN(nx)&&!isNaN(ny)&&/^-?[\d.]/.test(x)&&/^-?[\d.]/.test(y))return(nx-ny)*d;return x.localeCompare(y)*d;});rows.forEach(function(r){tb.appendChild(r);});});});})();
'@

function ConvertTo-BuilderHtml($data, [string[]]$Groups, [string]$serverScope) {
    $sb = New-Object System.Text.StringBuilder
    $now = Get-Date
    [void]$sb.Append('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Server Report</title>')
    [void]$sb.Append("<style>$($script:BuilderCss)</style></head><body><header><h1>Server Report</h1><div class=""meta"">")
    [void]$sb.Append("<b>Generated:</b> $(HE $now.ToString('yyyy-MM-dd HH:mm')) by $(HE "$env:USERDOMAIN\$env:USERNAME") on $(HE $env:COMPUTERNAME) &middot; Server Wizard v$(HE $script:AppVersion)<br>")
    [void]$sb.Append("<b>Groups:</b> $(HE ($Groups -join ', ')) &middot; <b>Servers:</b> $(HE $serverScope)<br>")
    [void]$sb.Append("<b>Columns:</b> $(HE ((@('Server') + $data.Columns) -join ', '))")
    if (@($data.Filters).Count) { [void]$sb.Append("<br><b>Conditions:</b> $(HE ($data.Filters -join $(if ($data.MatchAll) { ' AND ' } else { ' OR ' })))") }
    [void]$sb.Append('</div></header><main>')
    $total = 0
    foreach ($name in $data.Sections.Keys) {
        $rows = @($data.Sections[$name])
        $total += $rows.Count
        [void]$sb.Append("<h2>$(HE $name) <span>&middot; $($rows.Count) server(s)</span></h2>")
        if ($rows.Count -eq 0) { [void]$sb.Append('<div class="empty">No server matches.</div>'); continue }
        $heads = @($rows[0].PSObject.Properties.Name)
        [void]$sb.Append($(if ($heads.Count -gt 12) { '<table class="wide"><thead><tr>' } else { '<table><thead><tr>' }))
        foreach ($h in $heads) { [void]$sb.Append("<th>$(HE $h)</th>") }
        [void]$sb.Append('</tr></thead><tbody>')
        foreach ($r in $rows) {
            [void]$sb.Append('<tr>')
            foreach ($h in $heads) { [void]$sb.Append("<td>$(HE $r.$h)</td>") }
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</tbody></table>')
    }
    [void]$sb.Append("</main><footer>Read-only inventory: nothing was changed on any server. Support and end-of-support dates are read from the vendors' official lifecycle pages.</footer>")
    [void]$sb.Append("<script>$($script:BuilderJs)</script></body></html>")
    return $sb.ToString()
}

# --- PDF via the local Edge / Chrome (headless print) ------------------------
function Find-HeadlessBrowser {
    $cands = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($app in 'msedge.exe', 'chrome.exe') {
        try {
            $p = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$app" -ErrorAction Stop).'(default)'
            if ($p) { $cands += $p.Trim('"') }
        } catch {}
    }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

function Convert-HtmlToPdf([string]$htmlPath, [string]$pdfPath) {
    $browser = Find-HeadlessBrowser
    if (-not $browser) { throw "Microsoft Edge or Google Chrome was not found on this machine; the HTML report can be printed to PDF from any browser." }
    $profileDir = Join-Path $env:TEMP ("ServerWizard_pdf_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    try {
        if (Test-Path -LiteralPath $pdfPath) { Remove-Item -LiteralPath $pdfPath -Force -ErrorAction Stop }
        $uri  = ([Uri]$htmlPath).AbsoluteUri
        $argLine = "--headless=new --disable-gpu --no-first-run --no-default-browser-check --disable-extensions " +
                   "--user-data-dir=""$profileDir"" --no-pdf-header-footer --print-to-pdf-no-header " +
                   "--print-to-pdf=""$pdfPath"" ""$uri"""
        Write-Log "PDF: $browser $argLine"
        $p = Start-Process -FilePath $browser -ArgumentList $argLine -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch {}; throw "PDF conversion timed out after 120 s." }
        $deadline = (Get-Date).AddSeconds(10)
        while (-not (Test-Path -LiteralPath $pdfPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        if (-not (Test-Path -LiteralPath $pdfPath) -or (Get-Item -LiteralPath $pdfPath).Length -eq 0) {
            throw "The browser did not produce a PDF (exit code $($p.ExitCode))."
        }
    }
    finally {
        if ($profileDir -like (Join-Path $env:TEMP 'ServerWizard_pdf_*')) { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Saved choices (per user), so a regular report is two clicks away
$script:BuilderFile = Join-Path $script:CacheDir 'ReportBuilder.json'
function Get-BuilderChoice {
    try { if (Test-Path -LiteralPath $script:BuilderFile) { return (Get-Content -LiteralPath $script:BuilderFile -Raw -ErrorAction Stop | ConvertFrom-Json) } }
    catch { Write-Log "Report Builder settings unreadable: $($_.Exception.Message)" }
    return $null
}
function Save-BuilderChoice($c) {
    try {
        if (-not (Test-Path -LiteralPath $script:CacheDir)) { New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null }
        ($c | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:BuilderFile -Encoding UTF8 -ErrorAction Stop
    } catch { Write-Log "Report Builder settings not saved: $($_.Exception.Message)" }
}

function New-CheckList([int]$x, [int]$y, [int]$w, [int]$h) {
    $l = New-Object System.Windows.Forms.CheckedListBox
    $l.CheckOnClick = $true; $l.IntegralHeight = $false
    $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, $h)
    return $l
}

function Show-ReportBuilder {
    if ($script:Results.Keys.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No inventory yet - run a scan first.", "Report Builder", "OK", "Information") | Out-Null
        return $null
    }
    $allKeys = @($script:Results.Keys)
    $checked = @(Get-AllLeafNodes | Where-Object { $_.Checked } | ForEach-Object { Get-LeafName $_ } |
                 Where-Object { $script:Results.ContainsKey($_) } | Sort-Object -Unique)
    $counts = [ordered]@{}
    foreach ($g in $script:GroupOrder) { $counts[$g] = 0 }
    foreach ($k in $allKeys) { foreach ($g in @(Get-EffectiveGroups $k $script:Results[$k])) { if (-not $counts.Contains($g)) { $counts[$g] = 0 }; $counts[$g]++ } }
    $prev = Get-BuilderChoice

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Report Builder'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'; $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(900, 560)
    $dlg.Font = $form.Font

    $mkTitle = { param($t, $x) $l = New-InfoLabel $t 9.5 $true; $l.ForeColor = $script:ThAccent; $l.Location = New-Object System.Drawing.Point($x, 12); $l }
    $t1 = & $mkTitle '1. Groups' 14
    $t2 = & $mkTitle '2. Columns' 252
    $t3 = & $mkTitle '3. Conditions (optional)' 590

    $clbGroups = New-CheckList 14 38 224 300
    $groupOf = @{}
    foreach ($g in $counts.Keys) {
        if ($counts[$g] -eq 0) { continue }
        $text = "$g  ($($counts[$g]))"; $groupOf[$text] = $g
        [void]$clbGroups.Items.Add($text, ($prev -and @($prev.Groups) -contains $g))
    }

    # Columns: a checkable tree, one node per category
    $tvCols = New-Object System.Windows.Forms.TreeView
    $tvCols.CheckBoxes = $true; $tvCols.ShowLines = $false; $tvCols.FullRowSelect = $true
    $tvCols.Location = New-Object System.Drawing.Point(252, 38); $tvCols.Size = New-Object System.Drawing.Size(324, 448)
    $script:BuilderTreeSync = $false
    foreach ($cat in @($script:ReportColumns | ForEach-Object { $_.Cat } | Select-Object -Unique)) {
        $cn = New-Object System.Windows.Forms.TreeNode ($cat)
        $cn.NodeFont = New-Object System.Drawing.Font($script:FontName, 9, [System.Drawing.FontStyle]::Bold)
        foreach ($c in @($script:ReportColumns | Where-Object { $_.Cat -eq $cat })) {
            $n = New-Object System.Windows.Forms.TreeNode ($c.Label); $n.Tag = $c.Id
            $n.Checked = ($prev -and @($prev.Columns) -contains $c.Id)
            [void]$cn.Nodes.Add($n)
        }
        [void]$tvCols.Nodes.Add($cn)
    }
    $tvCols.ExpandAll()
    $tvCols.Add_AfterCheck({
        param($s, $e)
        if ($script:BuilderTreeSync -or $e.Action -eq [System.Windows.Forms.TreeViewAction]::Unknown) { return }
        $script:BuilderTreeSync = $true
        try { if ($e.Node.Nodes.Count) { foreach ($ch in $e.Node.Nodes) { $ch.Checked = $e.Node.Checked } } }
        finally { $script:BuilderTreeSync = $false }
    })

    $clbFilters = New-CheckList 590 38 296 250
    foreach ($fl in $script:ReportFilters) { [void]$clbFilters.Items.Add($fl.Label, ($prev -and @($prev.Filters) -contains $fl.Id)) }
    $rbAll = New-Object System.Windows.Forms.RadioButton
    $rbAll.Text = 'Server must match all ticked conditions'; $rbAll.AutoSize = $true; $rbAll.Location = New-Object System.Drawing.Point(592, 294)
    $rbAny = New-Object System.Windows.Forms.RadioButton
    $rbAny.Text = 'Server must match any ticked condition'; $rbAny.AutoSize = $true; $rbAny.Location = New-Object System.Drawing.Point(592, 316)
    if ($prev -and $prev.MatchAll -eq $false) { $rbAny.Checked = $true } else { $rbAll.Checked = $true }
    $lblHint = New-InfoLabel 'No condition ticked = every server of the ticked groups.' 8
    $lblHint.ForeColor = $script:ThMuted; $lblHint.Location = New-Object System.Drawing.Point(592, 342)

    $lblSrv = New-InfoLabel 'Servers' 9 $true; $lblSrv.ForeColor = $script:ThAccent; $lblSrv.Location = New-Object System.Drawing.Point(14, 350)
    $rbChecked = New-Object System.Windows.Forms.RadioButton
    $rbChecked.Text = "Checked in the list ($($checked.Count))"; $rbChecked.AutoSize = $true; $rbChecked.Location = New-Object System.Drawing.Point(16, 372)
    $rbEvery = New-Object System.Windows.Forms.RadioButton
    $rbEvery.Text = "All scanned ($($allKeys.Count))"; $rbEvery.AutoSize = $true; $rbEvery.Location = New-Object System.Drawing.Point(16, 394)
    if ($checked.Count -gt 0) { $rbChecked.Checked = $true } else { $rbChecked.Enabled = $false; $rbEvery.Checked = $true }
    $pSrv = New-Object System.Windows.Forms.Panel
    $pSrv.Location = New-Object System.Drawing.Point(0, 368); $pSrv.Size = New-Object System.Drawing.Size(240, 50)
    $rbChecked.Location = New-Object System.Drawing.Point(16, 2); $rbEvery.Location = New-Object System.Drawing.Point(16, 24)
    $pSrv.Controls.AddRange(@($rbChecked, $rbEvery))

    $lblLay = New-InfoLabel 'Layout' 9 $true; $lblLay.ForeColor = $script:ThAccent; $lblLay.Location = New-Object System.Drawing.Point(14, 424)
    $pLay = New-Object System.Windows.Forms.Panel
    $pLay.Location = New-Object System.Drawing.Point(0, 442); $pLay.Size = New-Object System.Drawing.Size(240, 50)
    $rbPerGroup = New-Object System.Windows.Forms.RadioButton
    $rbPerGroup.Text = 'One table per group'; $rbPerGroup.AutoSize = $true; $rbPerGroup.Location = New-Object System.Drawing.Point(16, 2)
    $rbOne = New-Object System.Windows.Forms.RadioButton
    $rbOne.Text = 'One table (groups as a column)'; $rbOne.AutoSize = $true; $rbOne.Location = New-Object System.Drawing.Point(16, 24)
    if ($prev -and $prev.OneTable) { $rbOne.Checked = $true } else { $rbPerGroup.Checked = $true }
    $pLay.Controls.AddRange(@($rbPerGroup, $rbOne))

    $lblFmt = New-InfoLabel 'Format' 9 $true; $lblFmt.ForeColor = $script:ThAccent; $lblFmt.Location = New-Object System.Drawing.Point(590, 374)
    $pFmt = New-Object System.Windows.Forms.Panel
    $pFmt.Location = New-Object System.Drawing.Point(576, 392); $pFmt.Size = New-Object System.Drawing.Size(310, 72)
    $rbHtml = New-Object System.Windows.Forms.RadioButton; $rbHtml.Text = 'HTML'; $rbHtml.AutoSize = $true; $rbHtml.Location = New-Object System.Drawing.Point(16, 2)
    $rbPdf  = New-Object System.Windows.Forms.RadioButton; $rbPdf.Text = 'PDF (A4 landscape, via Edge / Chrome)'; $rbPdf.AutoSize = $true; $rbPdf.Location = New-Object System.Drawing.Point(16, 24)
    $rbBoth = New-Object System.Windows.Forms.RadioButton; $rbBoth.Text = 'HTML + PDF'; $rbBoth.AutoSize = $true; $rbBoth.Location = New-Object System.Drawing.Point(16, 46)
    switch ("$($prev.Format)") { 'Pdf' { $rbPdf.Checked = $true } 'Both' { $rbBoth.Checked = $true } default { $rbHtml.Checked = $true } }
    $pFmt.Controls.AddRange(@($rbHtml, $rbPdf, $rbBoth))

    $lnkTab = New-Object System.Windows.Forms.LinkLabel
    $lnkTab.Text = 'Export the active tab as CSV instead'; $lnkTab.AutoSize = $true; $lnkTab.Location = New-Object System.Drawing.Point(14, 526)
    $lblSum = New-InfoLabel '' 8.5; $lblSum.ForeColor = $script:ThMuted; $lblSum.Location = New-Object System.Drawing.Point(252, 500)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Location = New-Object System.Drawing.Point(690, 518); $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Create report'; $btnOk.Location = New-Object System.Drawing.Point(788, 518); $btnOk.Size = New-Object System.Drawing.Size(98, 30)
    $btnOk.BackColor = $script:ThAccent; $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.Font = New-Object System.Drawing.Font($script:FontName, 9, [System.Drawing.FontStyle]::Bold)
    $dlg.CancelButton = $btnCancel

    $getCols = { @(foreach ($cn in $tvCols.Nodes) { foreach ($n in $cn.Nodes) { if ($n.Checked) { "$($n.Tag)" } } }) }
    $updSum = {
        $nG = $clbGroups.CheckedItems.Count; $nC = @(& $getCols).Count; $nF = $clbFilters.CheckedItems.Count
        $lblSum.Text = "$nG group(s), $nC column(s), $nF condition(s) selected"
        $btnOk.Enabled = ($nG -gt 0 -and $nC -gt 0)
    }
    $clbGroups.Add_ItemCheck({ $dlg.BeginInvoke([Action]{ & $updSum }) | Out-Null })
    $clbFilters.Add_ItemCheck({ $dlg.BeginInvoke([Action]{ & $updSum }) | Out-Null })
    $tvCols.Add_AfterCheck({ & $updSum })

    $result = $null
    $lnkTab.Add_LinkClicked({ $script:BuilderTabCsv = $true; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Retry; $dlg.Close() })
    $btnOk.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })

    $dlg.Controls.AddRange(@($t1, $t2, $t3, $clbGroups, $tvCols, $clbFilters, $rbAll, $rbAny, $lblHint, $lblSrv, $pSrv,
        $lblLay, $pLay, $lblFmt, $pFmt, $lnkTab, $lblSum, $btnCancel, $btnOk))
    Set-DarkTheme $dlg
    $btnOk.BackColor = $script:ThAccent; $btnOk.ForeColor = [System.Drawing.Color]::White
    & $updSum

    try {
        $res = $dlg.ShowDialog($form)
        if ($res -eq [System.Windows.Forms.DialogResult]::Retry) { return @{ Action = 'Tab' } }
        if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $choice = [ordered]@{
            Action   = 'Report'
            Groups   = [string[]]@(foreach ($i in $clbGroups.CheckedItems) { $groupOf["$i"] })
            Columns  = [string[]]@(& $getCols)
            Filters  = [string[]]@(foreach ($i in $clbFilters.CheckedIndices) { $script:ReportFilters[$i].Id })
            MatchAll = [bool]$rbAll.Checked
            OneTable = [bool]$rbOne.Checked
            AllServers = [bool]$rbEvery.Checked
            Format   = $(if ($rbPdf.Checked) { 'Pdf' } elseif ($rbBoth.Checked) { 'Both' } else { 'Html' })
        }
        Save-BuilderChoice $choice
        return $choice
    }
    finally { $dlg.Dispose() }
}

function Invoke-ReportBuilder($c) {
    $servers = @()
    if (-not $c.AllServers) {
        $servers = @(Get-AllLeafNodes | Where-Object { $_.Checked } | ForEach-Object { Get-LeafName $_ } |
                     Where-Object { $script:Results.ContainsKey($_) } | Sort-Object -Unique)
    }
    $scopeText = if ($c.AllServers -or $servers.Count -eq 0) { "all scanned ($($script:Results.Keys.Count))" } else { "checked in the list ($($servers.Count))" }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmm'
    $tag = if (@($c.Groups).Count -le 3) { '_' + ((@($c.Groups) | ForEach-Object { $_ -replace '[^A-Za-z0-9]+', '' }) -join '+') } else { '' }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    if ($c.Format -eq 'Html') { $dlg.Filter = "HTML report (*.html)|*.html"; $ext = 'html' } else { $dlg.Filter = "PDF report (*.pdf)|*.pdf"; $ext = 'pdf' }
    $dlg.FileName = "ServerWizard_Report${tag}_$stamp.$ext"
    try { if ($dlg.ShowDialog($form) -ne "OK") { return }; $target = $dlg.FileName } finally { $dlg.Dispose() }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $tmpHtml = $null
    try {
        Write-Log "Report Builder: groups=$($c.Groups -join ', ') columns=$($c.Columns -join ',') filters=$($c.Filters -join ',') format=$($c.Format) -> $target"
        Set-Status "Building report..." $script:ThAccent
        if (@($c.Columns) | Where-Object { $_ -match 'eol|sup|main|esu|days|src' }) { Update-LifecycleIfStale }
        $data = Get-BuilderData -Groups $c.Groups -Columns $c.Columns -Filters $c.Filters -MatchAll $c.MatchAll -OneTable $c.OneTable -Servers $servers
        $data.MatchAll = $c.MatchAll
        $html = ConvertTo-BuilderHtml $data $c.Groups $scopeText
        $utf8 = New-Object Text.UTF8Encoding($true)
        switch ($c.Format) {
            'Html' { [IO.File]::WriteAllText($target, $html, $utf8) }
            'Both' {
                [IO.File]::WriteAllText([IO.Path]::ChangeExtension($target, '.html'), $html, $utf8)
                Set-Status "Printing PDF with the local browser..." $script:ThAccent
                Convert-HtmlToPdf ([IO.Path]::ChangeExtension($target, '.html')) $target
            }
            'Pdf' {
                $tmpHtml = Join-Path $env:TEMP ("ServerWizard_report_" + [guid]::NewGuid().ToString('N') + '.html')
                [IO.File]::WriteAllText($tmpHtml, $html, $utf8)
                Set-Status "Printing PDF with the local browser..." $script:ThAccent
                Convert-HtmlToPdf $tmpHtml $target
            }
        }
        $n = 0; foreach ($k in $data.Sections.Keys) { $n += @($data.Sections[$k]).Count }
        Set-Status "Report saved ($n row(s)): $target" $script:OkGreen
        try { Start-Process -FilePath $target } catch { Write-Log "Could not open report: $($_.Exception.Message)" }
    }
    catch {
        Write-Log "REPORT FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        $msg = "Report failed: $($_.Exception.Message)"
        if ($c.Format -ne 'Html') { $msg += "`n`nTip: choose HTML and print to PDF from the browser." }
        [System.Windows.Forms.MessageBox]::Show("$msg`n`nSee log: $script:LogFile", "Report Builder", "OK", "Error") | Out-Null
        Set-Status "Report failed (see log)." $script:ThBad
    }
    finally {
        if ($tmpHtml -and (Test-Path -LiteralPath $tmpHtml)) { Remove-Item -LiteralPath $tmpHtml -Force -ErrorAction SilentlyContinue }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

# --- Event handlers --------------------------------------------------------
$btnLoadAD.Add_Click({
    Set-Status "Querying Active Directory..."
    Write-Log "Load from AD clicked (OU: '$($txtOU.Text.Trim())', ping check: $($chkPing.Checked))"
    $form.Refresh()
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Log "ActiveDirectory module imported."

        # STRING filter: scriptblock filters can fail inside compiled (.exe) hosts
        $adParams = @{
            Filter     = 'OperatingSystem -like "Windows Server*" -and Enabled -eq $true'
            Properties = @('OperatingSystem', 'servicePrincipalName', 'PrimaryGroupID')
        }
        if ($txtOU.Text.Trim()) { $adParams.SearchBase = $txtOU.Text.Trim() }

        $all = @(Get-ADComputer @adParams)
        Write-Log "AD returned $($all.Count) enabled Windows Server objects."

        $computers = @($all | Where-Object {
            -not ($_.servicePrincipalName -match 'MSClusterVirtualServer|MSServerClusterMgmtAPI')
        })
        Write-Log "$($computers.Count) remain after cluster-object filtering."

        if ($chkPing.Checked -and $computers) {
            Set-Status "Ping check: testing $($computers.Count) servers in parallel..."
            $form.Refresh()

            # Clear the sync context so async ping completions run on the
            # thread pool instead of deadlocking the UI thread; hard timeout
            # below guarantees this never blocks indefinitely.
            $prevCtx = [System.Threading.SynchronizationContext]::Current
            [System.Threading.SynchronizationContext]::SetSynchronizationContext($null)
            try {
                $tasks = foreach ($c in $computers) {
                    try { @{ C = $c; T = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($c.Name, 1500) } }
                    catch { Write-Log "Ping task creation failed for $($c.Name): $_" }
                }
                $taskList = @($tasks | Where-Object { $_ } | ForEach-Object { $_.T })
                try { [void][System.Threading.Tasks.Task]::WaitAll($taskList, 10000) } catch {}

                $alive = @()
                foreach ($t in $tasks) {
                    if (-not $t) { continue }
                    try {
                        if ($t.T.IsCompleted -and -not $t.T.IsFaulted -and $t.T.Result.Status -eq 'Success') {
                            $alive += $t.C
                        }
                    } catch {}
                }
                $computers = $alive
            }
            finally {
                [System.Threading.SynchronizationContext]::SetSynchronizationContext($prevCtx)
            }
            Write-Log "$(@($computers).Count) servers responded to ping."
        }

        $groups = @{}
        foreach ($c in $computers) {
            $key   = "$($c.Name)".ToUpper()
            $res   = $script:Results[$key]
            $gNames =
                if ($script:Overrides.ContainsKey($key) -or $res) { @(Get-EffectiveGroups $key $res) }
                elseif ($c.PrimaryGroupID -eq 516) { @('Domain Controllers') }
                else { @('Not Scanned / Unreachable') }
            foreach ($gName in @($gNames)) {
                if (-not $groups.ContainsKey($gName)) { $groups[$gName] = @() }
                $groups[$gName] += @{ Name = $key; CheckedState = $true }
            }
        }
        Rebuild-Tree $groups
        Set-Status "$(@($computers).Count) servers loaded from AD." $script:OkGreen
        Write-Log "AD load finished: $(@($computers).Count) servers in tree."
    }
    catch {
        Write-Log "AD LOAD FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        [System.Windows.Forms.MessageBox]::Show(
            "AD query failed: $_`n`nDetails were written to the log:`n$script:LogFile",
            "Error", "OK", "Error") | Out-Null
        Set-Status "AD query failed (see log)." $script:ThBad
    }
})

$btnOpenLog.Add_Click({
    if (Test-Path $script:LogFile) { Start-Process notepad.exe -ArgumentList "`"$script:LogFile`"" }
    else { Set-Status "No log file yet." }
})

$btnClearCache.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete the scan cache and manual group overrides?`n($script:CacheDir)",
        "Clear Cache", "YesNo", "Question")
    if ($answer -eq "Yes") {
        Remove-Item -Path $script:CacheFile, $script:OverrideFile -Force -ErrorAction SilentlyContinue
        $script:Results     = @{}
        $script:Overrides   = @{}
        $script:SearchIndex = @{}
        $tree.Nodes.Clear()
        $tabs.TabPages.Clear()
        $btnExport.Enabled = $false
        Update-ServerCount
        Set-Status "Cache cleared."
    }
})

$chkAll.Add_CheckedChanged({
    $script:TreeUpdating = $true
    foreach ($g in $tree.Nodes) {
        $g.Checked = $chkAll.Checked
        foreach ($n in $g.Nodes) { $n.Checked = $chkAll.Checked }
    }
    $script:TreeUpdating = $false
    Update-ServerCount
})

$tree.Add_AfterCheck({
    param($s, $e)
    if ($script:TreeUpdating) { return }
    $script:TreeUpdating = $true
    if ($e.Node.Nodes.Count -gt 0) {
        foreach ($n in $e.Node.Nodes) { $n.Checked = $e.Node.Checked }
    }
    # Keep every copy of a multi-role server in sync (leaf or group change)
    $changed = @{}
    if ($e.Node.Nodes.Count -gt 0) { foreach ($n in $e.Node.Nodes) { $changed[(Get-LeafName $n)] = $e.Node.Checked } }
    else { $changed[(Get-LeafName $e.Node)] = $e.Node.Checked }
    foreach ($leaf in Get-AllLeafNodes) {
        $ln = Get-LeafName $leaf
        if ($changed.ContainsKey($ln) -and $leaf.Checked -ne $changed[$ln]) { $leaf.Checked = $changed[$ln] }
    }
    $script:TreeUpdating = $false
    Update-ServerCount
})

$tree.Add_NodeMouseClick({
    param($s, $e)
    if ($e.Node.Nodes.Count -gt 0) { return }   # group node
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $script:CtxTarget = Get-LeafName $e.Node
        $ctxMenu.Show($tree, $e.Location)
    }
    else {
        Open-ServerTab (Get-LeafName $e.Node)
    }
})

# Owner-drawn tabs: title + "x" close button on each tab
$tabs.Add_DrawItem({
    param($s, $e)
    $g    = $e.Graphics
    $rect = $e.Bounds
    $isSel = ($e.Index -eq $tabs.SelectedIndex)

    $back = if ($isSel) { $script:ThSurface } else { $script:ThPanel }
    $backBrush = New-Object System.Drawing.SolidBrush ($back)
    $g.FillRectangle($backBrush, $rect)
    $backBrush.Dispose()

    $textBrush = New-Object System.Drawing.SolidBrush ($(if ($isSel) { $script:MerlinBlue } else { $script:ThText }))
    $font = New-Object System.Drawing.Font($script:FontName, 9, $(if ($isSel) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    $g.DrawString($tabs.TabPages[$e.Index].Text, $font, $textBrush,
        ([single]($rect.X + 4)), ([single]($rect.Y + 4)))
    $textBrush.Dispose(); $font.Dispose()

    # x button (Overview stays)
    if ($tabs.TabPages[$e.Index].Text -eq 'Home') { return }
    $xBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 60, 60))
    $xFont  = New-Object System.Drawing.Font($script:FontName, 8, [System.Drawing.FontStyle]::Bold)
    $g.DrawString("x", $xFont, $xBrush, ([single]($rect.Right - 16)), ([single]($rect.Y + 4)))
    $xBrush.Dispose(); $xFont.Dispose()
})

$tabs.Add_MouseDown({
    param($s, $e)
    for ($i = 0; $i -lt $tabs.TabPages.Count; $i++) {
        $r = $tabs.GetTabRect($i)
        $xRect = New-Object System.Drawing.Rectangle (($r.Right - 18), ($r.Top + 2), 16, 16)
        if ($xRect.Contains($e.Location) -and $tabs.TabPages[$i].Text -ne 'Home') {
            $tabs.TabPages.RemoveAt($i)
            # Nothing else open -> the Home dashboard
            if ($tabs.TabPages.Count -le 1) { Show-Overview }
            break
        }
    }
})

$btnScan.Add_Click({
    $targets = @(Get-AllLeafNodes | Where-Object { $_.Checked } | ForEach-Object { Get-LeafName $_ } | Sort-Object -Unique)
    if ($targets.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Select at least one server first.", "Warning", "OK", "Warning") | Out-Null
        return
    }
    $btnScan.Enabled   = $false
    $btnStop.Enabled   = $true
    Set-Status "Scan started: $($targets.Count) servers..." $script:MerlinBlue
    Write-Log "Scan started for $($targets.Count) servers (parallel: $([int]$numThrottle.Value))."

    # Show live progress: progress bar in the status strip + a progress tab
    $statusProgress.Minimum = 0
    $statusProgress.Maximum = $targets.Count
    $statusProgress.Value   = 0
    $statusProgress.Visible = $true
    $box = Get-TabBox "Scan Progress"
    $box.Text = "Scan started for $($targets.Count) servers...`n"

    # NoMachineProfile: no user profile is created on target servers
    # (faster AND guarantees the scan changes nothing on the targets)
    $sessOpt = New-PSSessionOption -NoMachineProfile -OpenTimeout 15000
    $script:ScanJob = Invoke-Command -ComputerName $targets -ScriptBlock $InventoryScriptBlock `
        -ThrottleLimit ([int]$numThrottle.Value) -SessionOption $sessOpt -AsJob -ErrorAction SilentlyContinue
    $timer.Start()
})

$btnStop.Add_Click({
    if ($script:ScanJob) { Stop-Job -Job $script:ScanJob -ErrorAction SilentlyContinue }
    Set-Status "Scan stopped by user." $script:WarnOrange
    Finish-Scan
})

$timer.Add_Tick({
    try {
    if (-not $script:ScanJob) { $timer.Stop(); return }
    $done  = ($script:ScanJob.ChildJobs | Where-Object { $_.State -in 'Completed','Failed','Stopped' }).Count
    $total = $script:ScanJob.ChildJobs.Count
    Set-Status "Scanning... $done / $total servers completed." $script:MerlinBlue
    if ($statusProgress.Maximum -ge $done) { $statusProgress.Value = $done }

    # Live per-server state in the Scan Progress tab
    $box = Get-TabBox "Scan Progress" $false
    $lines = foreach ($cj in $script:ScanJob.ChildJobs) {
        $mark = switch ($cj.State) {
            'Completed' { '[OK]     ' }
            'Failed'    { '[FAILED] ' }
            'Stopped'   { '[STOPPED]' }
            default     { '[...]    ' }
        }
        "$mark $($cj.Location)"
    }
    $box.Text = "Progress: $done / $total`n`n" + ($lines -join "`n")

    if ($script:ScanJob.State -in 'Completed', 'Failed', 'Stopped') { Finish-Scan }
    }
    catch { Set-Status "Scan monitor error: $_" $script:ThBad }
})

$btnSearch.Add_Click({ Invoke-Search })
$txtSearch.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.SuppressKeyPress = $true
        Invoke-Search
    }
})

# Exports ONLY the server (or search) open in the active tab.
# Semicolon delimiter + UTF8 BOM so Turkish-locale Excel opens it in
# proper columns (comma-delimited CSV shows as one column there).
function Export-ActiveTabCsv {
    $tp = $tabs.SelectedTab

    # Search Results tab -> export the search itself, grouped by category
    if ($tp -and $tp.Text -eq 'Search Results') {
        if (-not $script:LastSearchRows -or $script:LastSearchRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Run a search first.", "Export Report", "OK", "Information") | Out-Null
            return
        }
        $safeQ = ($script:LastSearchQuery -replace '[\\/:*?"<>|]', '_')
        $dlg          = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter   = "CSV file (*.csv)|*.csv"
        $dlg.FileName = "ServerWizard_Search_${safeQ}_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
        if ($dlg.ShowDialog($form) -ne "OK") { return }

        $catOrder = @('Server Name') + ($script:FieldDefs | ForEach-Object { $_.Label })
        $rows = $script:LastSearchRows |
            Sort-Object @{ Expression = { $catOrder.IndexOf($_.Category) } }, Server, Value |
            ForEach-Object {
                [PSCustomObject]@{
                    SearchTerm = $script:LastSearchQuery
                    Category   = $_.Category
                    Server     = $_.Server
                    RoleGroup  = (Get-EffectiveGroup $_.Server $script:Results[$_.Server])
                    Value      = $_.Value
                }
            }
        $rows | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Set-Status "Search report saved ($($rows.Count) rows): $($dlg.FileName)" $script:OkGreen
        return
    }

    if (-not $tp -or $tp.Text -eq 'Scan Progress') {
        [System.Windows.Forms.MessageBox]::Show(
            "Open a server tab (or the Search Results tab) first - the report is generated for the active tab.",
            "Export Report", "OK", "Information") | Out-Null
        return
    }
    $key = "$($tp.Text)".ToUpper()
    $r   = $script:Results[$key]
    if (-not $r) { Set-Status "No data for $key." $script:WarnOrange; return }

    $dlg          = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = "CSV file (*.csv)|*.csv"
    $dlg.FileName = "ServerWizard_${key}_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    if ($dlg.ShowDialog($form) -ne "OK") { return }

    $rGroup = Get-EffectiveGroup $key $r
    $rows = @(
        [PSCustomObject]@{ Section = 'Server'; Property = 'Server Name'; Value = $key }
        [PSCustomObject]@{ Section = 'Server'; Property = 'Role Group';  Value = $rGroup }
    )
    $rows += foreach ($def in $script:FieldDefs) {
        $prop = $r.PSObject.Properties[$def.Name]
        $val  = if ($prop) { "$($prop.Value)" } else { "" }
        if (-not $val) { continue }
        $items = if ($def.Sep) { $val -split [regex]::Escape($def.Sep) } else { @($val) }
        foreach ($item in $items) {
            $item = "$item".Trim()
            if (-not $item) { continue }
            [PSCustomObject]@{ Section = $def.Section; Property = $def.Label; Value = $item }
        }
    }
    $rows | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Set-Status "Report saved for ${key}: $($dlg.FileName)" $script:OkGreen
}

# Export Report: one dialog to choose WHAT goes into the report (roles,
# servers) and HOW (interactive HTML, CSV per role, active tab CSV), or to
# open the in-app Reports view.
$btnExport.Add_Click({
    try {
        Write-Log "Report Builder opened"
        $choice = Show-ReportBuilder
        if (-not $choice) { return }
        if ($choice.Action -eq 'Tab') { Export-ActiveTabCsv; return }
        Invoke-ReportBuilder $choice
    }
    catch {
        Write-Log "REPORT BUILDER FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        Set-Status "Report Builder failed: $($_.Exception.Message) (see log)" $script:ThBad
    }
})

$form.Add_FormClosing({
    $timer.Stop()
    if ($script:ScanJob) {
        Stop-Job -Job $script:ScanJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:ScanJob -Force -ErrorAction SilentlyContinue
    }
})

# --- Startup: load cache, build groups from it -----------------------------
Load-OfficialDiskCache
if (Load-Cache) {
    foreach ($k in $script:Results.Keys) { Update-DerivedFields $script:Results[$k] }
    Build-SearchIndex
    Group-AndRebuild
    Show-Overview
    $btnExport.Enabled = $true
    $cacheDate = (Get-Item $script:CacheFile).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    Set-Status "Loaded $($script:Results.Keys.Count) servers from cache ($cacheDate). Click a server to open it in a tab." $script:OkGreen
}
else {
    Show-Overview
    Set-Status "Ready. Load the server list from AD, then run a scan."
}
Update-LastScanLabel

# Cached inventory: re-check support / EOL dates against the official sources
# once the window is visible (offline -> last official copy, clearly marked)
$form.Add_Shown({
    if ($script:Results.Keys.Count -eq 0) { return }
    $prev = $statusLabel.Text
    try {
        Update-AllLifecycle
        Build-SearchIndex
        Update-Overview
        foreach ($tp in $tabs.TabPages) {
            $res = $script:Results["$($tp.Text)".ToUpper()]
            if ($res -and $tp.Controls.Count -gt 0) { Render-Detail $res $tp.Controls[0] }
        }
        Set-Status "$prev  Support/EOL dates checked against official sources." $script:OkGreen
    }
    catch {
        Write-Log "Startup lifecycle refresh failed: $($_.Exception.Message)"
        Set-Status "$prev  (official lifecycle sources could not be checked - see log)" $script:WarnOrange
    }
})

[void]$form.ShowDialog()
