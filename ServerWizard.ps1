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
$script:AppVersion = '1.6'

# --- UI font: Open Sans if installed on this server, else Segoe UI ---------
$script:FontName = 'Segoe UI'
try {
    $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
    if ($installed -contains 'Open Sans') { $script:FontName = 'Open Sans' }
} catch {}

# --- Theme -----------------------------------------------------------------
$script:MerlinBlue   = [System.Drawing.Color]::FromArgb(31, 58, 147)
$script:MerlinBlueLt = [System.Drawing.Color]::FromArgb(232, 238, 252)
$script:MerlinYellow = [System.Drawing.Color]::FromArgb(250, 204, 21)
$script:WarnOrange   = [System.Drawing.Color]::FromArgb(200, 100, 0)
$script:OkGreen      = [System.Drawing.Color]::FromArgb(0, 120, 60)

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
    $yellow = New-Object System.Drawing.SolidBrush ($script:MerlinYellow)
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
$form.BackColor     = [System.Drawing.Color]::White

try {
    $form.Icon = [System.Drawing.Icon]::FromHandle((New-WizardBitmap 32).GetHicon())
} catch {}

# Default font for ALL controls (inherited by children)
$form.Font = New-Object System.Drawing.Font($script:FontName, 9)

# Header (sized before controls are added, so right-anchored buttons don't
# get measured against the default 200px panel width)
$pnlHeader           = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock      = "Top"
$pnlHeader.Size      = New-Object System.Drawing.Size(1264, 84)
$pnlHeader.BackColor = $script:MerlinBlueLt

$picLogo          = New-Object System.Windows.Forms.PictureBox
$picLogo.Location = New-Object System.Drawing.Point(12, 10)
$picLogo.Size     = New-Object System.Drawing.Size(64, 64)
$picLogo.SizeMode = "Zoom"
$picLogo.Image    = New-WizardBitmap 64

$lblTitle           = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "Server Wizard"
$lblTitle.Font      = New-Object System.Drawing.Font("Comic Sans MS", 22, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $script:MerlinBlue
$lblTitle.Location  = New-Object System.Drawing.Point(84, 8)
$lblTitle.AutoSize  = $true

$lblSubtitle           = New-Object System.Windows.Forms.Label
$lblSubtitle.Text      = "Windows Server Inventory  -  v$($script:AppVersion)"
$lblSubtitle.Font      = New-Object System.Drawing.Font($script:FontName, 9)
$lblSubtitle.ForeColor = [System.Drawing.Color]::DimGray
$lblSubtitle.Location  = New-Object System.Drawing.Point(90, 56)
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
    $btnClearCache.Top  = 28
    $btnOpenLog.Top     = 28
    $btnClearCache.Left = $pnlHeader.Width - $btnClearCache.Width - 14
    $btnOpenLog.Left    = $btnClearCache.Left - $btnOpenLog.Width - 8
})

# Left panel: server tree
$grpSource           = New-Object System.Windows.Forms.GroupBox
$grpSource.Text      = "Servers"
$grpSource.ForeColor = $script:MerlinBlue
$grpSource.Location  = New-Object System.Drawing.Point(10, 94)
$grpSource.Size      = New-Object System.Drawing.Size(340, 650)
$grpSource.Anchor    = "Top,Bottom,Left"

$lblOU           = New-Object System.Windows.Forms.Label
$lblOU.Text      = "OU / SearchBase (optional):"
$lblOU.ForeColor = [System.Drawing.Color]::Black
$lblOU.Location  = New-Object System.Drawing.Point(10, 22)
$lblOU.AutoSize  = $true

$txtOU          = New-Object System.Windows.Forms.TextBox
$txtOU.Location = New-Object System.Drawing.Point(10, 42)
$txtOU.Size     = New-Object System.Drawing.Size(320, 23)
$txtOU.Anchor   = "Top,Left,Right"

$chkPing           = New-Object System.Windows.Forms.CheckBox
$chkPing.Text      = "Ping check (add only reachable servers)"
$chkPing.ForeColor = [System.Drawing.Color]::Black
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
$chkAll.ForeColor = [System.Drawing.Color]::Black
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
$lblCount.ForeColor = [System.Drawing.Color]::Black
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
$btnScan.Location  = New-Object System.Drawing.Point(360, 100)
$btnScan.Size      = New-Object System.Drawing.Size(120, 33)
$btnScan.BackColor = $script:MerlinBlue
$btnScan.ForeColor = [System.Drawing.Color]::White
$btnScan.FlatStyle = "Flat"

$btnStop           = New-Object System.Windows.Forms.Button
$btnStop.Text      = "Stop"
$btnStop.Location  = New-Object System.Drawing.Point(486, 100)
$btnStop.Size      = New-Object System.Drawing.Size(70, 33)
$btnStop.Enabled   = $false
$btnStop.FlatStyle = "Flat"

$btnExport           = New-Object System.Windows.Forms.Button
$btnExport.Text      = "Export Report"
$btnExport.Location  = New-Object System.Drawing.Point(562, 100)
$btnExport.Size      = New-Object System.Drawing.Size(110, 33)
$btnExport.Enabled   = $false
$btnExport.BackColor = $script:MerlinYellow
$btnExport.ForeColor = $script:MerlinBlue
$btnExport.FlatStyle = "Flat"

$lblThrottle          = New-Object System.Windows.Forms.Label
$lblThrottle.Text     = "Parallel:"
$lblThrottle.Location = New-Object System.Drawing.Point(682, 108)
$lblThrottle.AutoSize = $true

$numThrottle          = New-Object System.Windows.Forms.NumericUpDown
$numThrottle.Location = New-Object System.Drawing.Point(738, 105)
$numThrottle.Size     = New-Object System.Drawing.Size(52, 23)
$numThrottle.Minimum  = 1
$numThrottle.Maximum  = 100
$numThrottle.Value    = 20

# Search bar (IP / website / DNS -> which server?) with a category scope
$lblSearch          = New-Object System.Windows.Forms.Label
$lblSearch.Text     = "Search:"
$lblSearch.Location = New-Object System.Drawing.Point(360, 142)
$lblSearch.AutoSize = $true

$txtSearch          = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(415, 139)
$txtSearch.Size     = New-Object System.Drawing.Size(300, 23)

$lblScope          = New-Object System.Windows.Forms.Label
$lblScope.Text     = "in:"
$lblScope.Location = New-Object System.Drawing.Point(725, 142)
$lblScope.AutoSize = $true

$cmbScope               = New-Object System.Windows.Forms.ComboBox
$cmbScope.Location      = New-Object System.Drawing.Point(748, 139)
$cmbScope.Size          = New-Object System.Drawing.Size(250, 23)
$cmbScope.DropDownStyle = "DropDownList"
[void]$cmbScope.Items.Add($script:AllCategories)
[void]$cmbScope.Items.Add('Server Name')
foreach ($def in $script:FieldDefs) { [void]$cmbScope.Items.Add($def.Label) }
$cmbScope.SelectedIndex = 0

$btnSearch           = New-Object System.Windows.Forms.Button
$btnSearch.Text      = "Find"
$btnSearch.Location  = New-Object System.Drawing.Point(1006, 137)
$btnSearch.Size      = New-Object System.Drawing.Size(70, 27)
$btnSearch.BackColor = $script:MerlinBlue
$btnSearch.ForeColor = [System.Drawing.Color]::White
$btnSearch.FlatStyle = "Flat"

$lblTabHint           = New-Object System.Windows.Forms.Label
$lblTabHint.Text      = "Click the x on a tab to close it"
$lblTabHint.ForeColor = [System.Drawing.Color]::Gray
$lblTabHint.Location  = New-Object System.Drawing.Point(1086, 142)
$lblTabHint.AutoSize  = $true

# Tabs: each clicked server opens in its own tab (owner-drawn for the x button)
$tabs          = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(360, 170)
$tabs.Size     = New-Object System.Drawing.Size(895, 574)
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
$statusScanDate.ForeColor = [System.Drawing.Color]::DimGray
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
    $lblThrottle, $numThrottle, $lblSearch, $txtSearch, $lblScope, $cmbScope,
    $btnSearch, $lblTabHint, $tabs, $statusStrip))

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
function Set-Status([string]$msg, [System.Drawing.Color]$color = [System.Drawing.Color]::Black) {
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

            $res = $script:Results[$entry.Name]
            if ($res) {
                $minFree = 100
                if ("$($res.MinDiskFree)" -match '^[\d\.]+$') { $minFree = [double]$res.MinDiskFree }
                if     ($minFree -lt 10) { $n.ForeColor = [System.Drawing.Color]::Red }
                elseif ($minFree -lt 20) { $n.ForeColor = $script:WarnOrange }
            }
            else { $n.ForeColor = [System.Drawing.Color]::Gray }
            [void]$gNode.Nodes.Add($n)
        }
    }

    $tree.ExpandAll()
    $tree.EndUpdate()
    $script:TreeUpdating = $false
    Update-ServerCount
}

function Render-Detail($r, [System.Windows.Forms.RichTextBox]$box) {
    try {
        Set-Redraw $box $false   # suspend painting: renders in one smooth pass
        $box.Clear()
        $headerFont  = New-Object System.Drawing.Font($script:FontName, 13, [System.Drawing.FontStyle]::Bold)
        $sectionFont = New-Object System.Drawing.Font($script:FontName, 11, [System.Drawing.FontStyle]::Bold)
        $labelFont   = New-Object System.Drawing.Font($script:FontName, 9.5, [System.Drawing.FontStyle]::Bold)
        $itemFont    = New-Object System.Drawing.Font($script:FontName, 9.5)

        $key = "$($r.ComputerName)".ToUpper()
        $box.SelectionFont  = $headerFont
        $box.SelectionColor = $script:MerlinBlue
        $box.AppendText("$($r.ComputerName)`n")
        $box.SelectionFont  = $itemFont
        $box.SelectionColor = [System.Drawing.Color]::DimGray
        $grpTxt = Get-EffectiveGroup $key $r
        if ($script:Overrides.ContainsKey($key)) { $grpTxt += " (manual override)" }
        $box.AppendText("Role groups: $grpTxt`n`n")

        $currentSection = ""
        foreach ($def in $script:FieldDefs) {
            $prop = $r.PSObject.Properties[$def.Name]
            $val  = if ($prop) { "$($prop.Value)" } else { "" }
            if (-not $val) { continue }

            if ($def.Section -ne $currentSection) {
                $currentSection     = $def.Section
                $box.SelectionFont  = $sectionFont
                $box.SelectionColor = $script:MerlinBlue
                $box.AppendText("$currentSection`n")
            }

            $box.SelectionFont  = $labelFont
            $box.SelectionColor = [System.Drawing.Color]::Black
            $box.AppendText("  $($def.Label):`n")

            $items = if ($def.Sep) { $val -split [regex]::Escape($def.Sep) } else { @($val) }
            foreach ($item in $items) {
                $item = "$item".Trim()
                if (-not $item) { continue }
                $box.SelectionFont  = $itemFont
                $box.SelectionColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
                $box.AppendText("      - $item`n")
            }
            $box.AppendText("`n")
        }
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
    $box.BackColor = [System.Drawing.Color]::White
    $box.Font      = New-Object System.Drawing.Font($script:FontName, 10)
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
    $box.Dock = "Fill"; $box.ReadOnly = $true; $box.BackColor = [System.Drawing.Color]::White
    $box.Font = New-Object System.Drawing.Font($script:FontName, 10)
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

        $cached = Save-Cache
        Build-SearchIndex
        Group-AndRebuild

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
        Set-Status "Error while finishing scan: $_ (see log)" ([System.Drawing.Color]::Red)
    }
    Update-LastScanLabel
    $statusProgress.Visible = $false
    $btnScan.Enabled   = $true
    $btnStop.Enabled   = $false
    $btnExport.Enabled = ($script:Results.Keys.Count -gt 0)
}

function Invoke-Search {
    $q = $txtSearch.Text.Trim()
    if (-not $q) { return }
    if ($script:Results.Keys.Count -eq 0) { Set-Status "Nothing to search - run a scan first." $script:WarnOrange; return }
    if ($script:SearchIndex.Keys.Count -eq 0) { Build-SearchIndex }

    $scope = "$($cmbScope.SelectedItem)"
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
                $cmbScope.SelectedItem = $target.Value
                Invoke-Search
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
    $box.SelectionColor = [System.Drawing.Color]::DimGray
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
    $box.SelectionColor = [System.Drawing.Color]::DimGray
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
        $box.SelectionColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
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
                $box.SelectionColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
                $box.AppendText("        $($m.Value)`n")
            }
        }
        $box.AppendText("`n")
    }
    $box.Tag = $lineMap

    # Highlight every occurrence of the query in yellow
    $hl  = [System.Drawing.Color]::FromArgb(255, 244, 141)
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
# Reporting module: role-based reports (HTML + CSV per role)
# ============================================================================

# Servers in scope: checked in the tree and scanned; all scanned if none checked
# Servers in scope: checked in the tree and scanned (all scanned if none are
# checked, or when -AllServers); optionally only those in the given roles.
function Get-ReportServerKeys([string[]]$Roles = @(), [switch]$AllServers) {
    $base = @()
    if (-not $AllServers) {
        $base = @(Get-AllLeafNodes | Where-Object { $_.Checked } | ForEach-Object { Get-LeafName $_ } |
            Where-Object { $script:Results.ContainsKey($_) } | Sort-Object -Unique)
    }
    if ($base.Count -eq 0) { $base = @($script:Results.Keys | Sort-Object) }
    if (@($Roles).Count -gt 0) {
        $base = @($base | Where-Object {
            $gs = @(Get-EffectiveGroups $_ $script:Results[$_])
            @($gs | Where-Object { $Roles -contains $_ }).Count -gt 0
        })
    }
    return ,[string[]]$base
}

function Get-FeatureRows($inv, $def) {
    if (-not $inv -or -not $def -or -not $def.Features) { return @() }
    $names = @($def.Features)
    return @($inv.Features | Where-Object { $_ } | Where-Object { $names -contains $_.Name -or $names -contains $_.Parent })
}

# Builds every report section as rows of objects. Both the HTML and the CSV
# writers render from this, so they always contain the same data.
function Get-ReportSections([string[]]$keys, [string[]]$Roles = @()) {
    $sections = [ordered]@{}
    $members  = [ordered]@{}
    foreach ($g in $script:GroupOrder) { $members[$g] = New-Object System.Collections.Generic.List[string] }
    foreach ($k in $keys) {
        foreach ($g in @(Get-EffectiveGroups $k $script:Results[$k])) {
            if (@($Roles).Count -gt 0 -and $Roles -notcontains $g) { continue }   # role-scoped report
            if (-not $members.Contains($g)) { $members[$g] = New-Object System.Collections.Generic.List[string] }
            $members[$g].Add($k)
        }
    }

    # --- Summary ---------------------------------------------------------
    $sections['Summary by Role'] = @{
        Description = 'Servers per role group. A server with several roles is listed in every matching group.'
        Rows = @(foreach ($g in $members.Keys) {
            if ($members[$g].Count -eq 0) { continue }
            [PSCustomObject]@{ 'Role Group' = $g; 'Servers' = $members[$g].Count; 'Server Names' = ($members[$g] -join ', ') }
        })
    }

    # --- Classification evidence (why a server is in a group) ---------------
    $sections['Role Classification'] = @{
        Description = 'Why each server is in each role group (detected Windows role, database engine or service). Use it to verify the grouping.'
        Rows = @(foreach ($k in $keys) {
            $r = $script:Results[$k]
            if ($script:Overrides.ContainsKey($k)) {
                [PSCustomObject]@{ 'Server' = $k; 'Role Group' = $script:Overrides[$k]; 'Evidence' = 'Manual override (right-click)' }
                continue
            }
            foreach ($d in @(Get-RoleGroupDetails $r)) { [PSCustomObject]@{ 'Server' = $k; 'Role Group' = $d.Group; 'Evidence' = $d.Reason } }
        })
    }

    # --- Operating systems ---------------------------------------------------
    $sections['Operating Systems'] = @{
        Description = 'OS version, install date and Microsoft Lifecycle dates (learn.microsoft.com).'
        Rows = @(foreach ($k in $keys) {
            $r = $script:Results[$k]; $inv = Get-Inv $r
            $lc = Get-Lc (Get-OsLifecycleKey $r)
            [PSCustomObject]@{
                'Server'            = $k
                'Role Groups'       = Get-EffectiveGroup $k $r
                'Operating System'  = if ($inv -and $inv.OS) { $inv.OS.Caption } else { "$($r.OperatingSystem)" }
                'Build'             = if ($inv -and $inv.OS) { "$($inv.OS.Build)$(if ($inv.OS.UBR) { ".$($inv.OS.UBR)" })" } else { '' }
                'OS Install Date'   = "$($r.InstallDate)"
                'Last Restart'      = "$($r.LastRestartDate)"
                'Lifecycle Policy'  = if ($lc) { $lc.Policy } else { '' }
                'Mainstream End'    = if ($lc) { Format-LcDate $lc.SupportEnd } else { '' }
                'Extended End (EOL)'= if ($lc) { Format-LcDate $lc.EOL } else { '' }
                'ESU End'           = if ($lc -and $lc.ESUEnd) { Format-LcDate $lc.ESUEnd } else { '' }
                'Days to EOL'       = if ($lc) { $lc.DaysToEOL } else { $null }
                'Status'            = if ($lc) { $lc.Status } else { 'Not resolved' }
                'Official Source'   = if ($lc) { $lc.Source } else { '' }
                'Source Note'       = if ($lc) { $lc.SourceNote } else { '' }
            }
        })
    }

    # --- Role specific sections ---------------------------------------------
    foreach ($g in $members.Keys) {
        $list = $members[$g]
        if ($list.Count -eq 0) { continue }
        $def = $script:RoleDefs | Where-Object { $_.Group -eq $g } | Select-Object -First 1

        if ($g -eq 'SQL / Database') {
            $sections[$g] = @{
                Description = 'Database engines (MSSQL, MariaDB, MySQL, PostgreSQL, Firebird, ...): version, install date and vendor lifecycle.'
                Rows = @(foreach ($k in $list) {
                    $r = $script:Results[$k]; $inv = Get-Inv $r
                    if (-not $inv) {
                        [PSCustomObject]@{ 'Server' = $k; 'Product' = 'Rescan with v1.5'; 'Version' = "$($r.SQLInstanceDetails)" }
                        continue
                    }
                    foreach ($db in @($inv.Databases | Where-Object { $_ })) {
                        $lc = Get-Lc (Get-DbLifecycleKey $db)
                        [PSCustomObject]@{
                            'Server'          = $k
                            'Product'         = $db.Product
                            'Version'         = $db.Version
                            'Edition/Package' = $db.Edition
                            'Instance'        = $db.Instance
                            'Service Pack'    = $db.ServicePack
                            'Install Date'    = $db.InstallDate
                            'Install Date Source' = $db.InstallDateSource
                            'Service State'   = $db.ServiceState
                            'Release'         = if ($lc) { $lc.Release } else { '' }
                            'Support End'     = if ($lc) { Format-LcDate $lc.SupportEnd } else { '' }
                            'EOL'             = if ($lc) { Format-LcDate $lc.EOL } else { '' }
                            'ESU End'         = if ($lc -and $lc.ESUEnd) { Format-LcDate $lc.ESUEnd } else { '' }
                            'Days to EOL'     = if ($lc) { $lc.DaysToEOL } else { $null }
                            'Status'          = if ($lc) { $lc.Status } else { 'No official source for this product' }
                            'Note'            = if ($lc) { $lc.Note } else { '' }
                            'Official Source' = if ($lc) { $lc.Source } else { '' }
                        }
                    }
                })
            }
        }
        elseif ($g -eq 'IIS / Web') {
            $sections[$g] = @{
                Description = 'IIS version (registry InetStp), approximate install date, sites and lifecycle (IIS follows the Windows lifecycle).'
                Rows = @(foreach ($k in $list) {
                    $r = $script:Results[$k]; $inv = Get-Inv $r
                    $lc = Get-Lc (Get-IisLifecycleKey $r)
                    [PSCustomObject]@{
                        'Server'          = $k
                        'IIS Version'     = if ($inv -and $inv.IIS) { $inv.IIS.Version } else { '' }
                        'Version String'  = if ($inv -and $inv.IIS) { $inv.IIS.VersionString } else { '' }
                        'Install Date (approx.)' = if ($inv -and $inv.IIS) { $inv.IIS.InstallDate } else { '' }
                        'Sites'           = if ($inv -and $inv.IIS) { $inv.IIS.SiteCount } else { $null }
                        'Site List'       = if ($inv -and $inv.IIS) { @($inv.IIS.Sites) -join ', ' } else { "$($r.Websites)" }
                        'Release'         = if ($lc) { $lc.Release } else { '' }
                        'Support End / EOL' = if ($lc) { Format-LcDate $lc.EOL } else { '' }
                        'Days to EOL'     = if ($lc) { $lc.DaysToEOL } else { $null }
                        'Status'          = if ($lc) { $lc.Status } else { 'Not resolved' }
                        'Official Source' = if ($lc) { $lc.Source } else { '' }
                    }
                })
            }
        }
        elseif ($g -in '3rd Party', 'Other', 'Not Scanned / Unreachable' -or -not $def) {
            $sections[$g] = @{
                Description = 'Servers without a detected Microsoft server role.'
                Rows = @(foreach ($k in $list) {
                    $r = $script:Results[$k]
                    [PSCustomObject]@{ 'Server' = $k; 'Operating System' = "$($r.OperatingSystem)"; 'Running 3rd Party Services' = "$($r.ThirdPartyServices)" }
                })
            }
        }
        else {
            $sections[$g] = @{
                Description = "Installed role / role services for '$g' and the host OS lifecycle."
                Rows = @(foreach ($k in $list) {
                    $r = $script:Results[$k]; $inv = Get-Inv $r
                    $lc = Get-Lc (Get-OsLifecycleKey $r)
                    $fr = Get-FeatureRows $inv $def
                    [PSCustomObject]@{
                        'Server'          = $k
                        'Operating System'= if ($inv -and $inv.OS) { $inv.OS.Caption } else { "$($r.OperatingSystem)" }
                        'Role / Role Services' = if ($fr) { ($fr | ForEach-Object { $_.DisplayName }) -join ', ' } else { ($def.Features -join ', ') }
                        'OS EOL'          = if ($lc) { Format-LcDate $lc.EOL } else { '' }
                        'Status'          = if ($lc) { $lc.Status } else { 'Not resolved' }
                    }
                })
            }
        }
    }

    # --- Windows Server roles & features (all servers) ------------------------
    $sections['Windows Server Roles & Features'] = @{
        Description = 'Every installed role, role service and feature (Get-WindowsFeature).'
        Rows = @(foreach ($k in $keys) {
            $inv = Get-Inv $script:Results[$k]
            if (-not $inv) { [PSCustomObject]@{ 'Server' = $k; 'Type' = ''; 'Name' = "$($script:Results[$k].Roles)"; 'Display Name' = 'Rescan with v1.5 for details'; 'Parent' = '' }; continue }
            foreach ($f in @($inv.Features | Where-Object { $_ } | Sort-Object @{ Expression = { switch ($_.Type) { 'Role' { 0 } 'Role Service' { 1 } default { 2 } } } }, Name)) {
                [PSCustomObject]@{ 'Server' = $k; 'Type' = $f.Type; 'Name' = $f.Name; 'Display Name' = $f.DisplayName; 'Parent' = $f.Parent }
            }
        })
    }

    # --- Certificates ---------------------------------------------------------
    $certRows = @(foreach ($k in $keys) {
        $inv = Get-Inv $script:Results[$k]
        if (-not $inv) { continue }
        foreach ($c in @($inv.Certificates | Where-Object { $_ })) {
            $days = Get-DaysLeft $c.NotAfter
            [PSCustomObject]@{
                'Server'      = $k
                'Status'      = Get-CertStatus $days
                'Days Left'   = $days
                'Expires'     = $c.NotAfter
                'Issued'      = $c.NotBefore
                'Subject'     = $c.Subject
                'DNS Names'   = @($c.DnsNames) -join ', '
                'Issuer'      = $c.Issuer
                'Self-signed' = $c.SelfSigned
                'Private Key' = $c.HasPrivateKey
                'Used By'     = @($c.BoundTo) -join ', '
                'Store'       = $c.Store
                'Thumbprint'  = $c.Thumbprint
            }
        }
    })
    $sections['SSL Certificates'] = @{
        Description = 'All certificates in LocalMachine\My and WebHosting, soonest expiry first, with the IIS bindings that use them.'
        Rows = @($certRows | Sort-Object @{ Expression = { if ($null -eq $_.'Days Left') { [int]::MaxValue } else { $_.'Days Left' } } })
    }
    return $sections
}

function Get-StatusClass([string]$v) {
    if ($v -match '^(EOL|EXPIRED)') { return 'bad' }
    if ($v -match '^(Extended support|Expires <= (30|60))') { return 'warn' }
    if ($v -match '^Expires <= 90') { return 'soon' }
    if ($v -match '^(Supported|Valid)') { return 'ok' }
    return ''
}

# Interactive single-file HTML report. All data is embedded as JSON and
# rendered client-side with textContent (no HTML injection), no external
# resources, works offline. Filters: role chips (multi-select), problem
# filter, free-text search, sortable columns, per-section CSV of the view.
# Deep link: report.html#roles=IIS%20%2F%20Web,SQL%20%2F%20Database&problems=1
function ConvertTo-HtmlReport($sections, [string[]]$keys) {
    $enc = { param($v) [Net.WebUtility]::HtmlEncode("$v") }

    $serverGroups = @{}
    foreach ($k in $keys) { $serverGroups[$k] = [string[]]@(Get-EffectiveGroups $k $script:Results[$k]) }
    $groupNames = New-Object System.Collections.Generic.List[string]
    foreach ($g in (@($script:GroupOrder) + @($serverGroups.Values | ForEach-Object { $_ }))) {
        if (-not $groupNames.Contains($g) -and @($serverGroups.Values | Where-Object { $_ -contains $g }).Count) { $groupNames.Add($g) }
    }

    $secList = New-Object System.Collections.Generic.List[object]
    foreach ($name in $sections.Keys) {
        $sec  = $sections[$name]
        $rows = @($sec.Rows)
        $cols = New-Object System.Collections.Generic.List[string]
        foreach ($row in $rows) { foreach ($p in $row.PSObject.Properties.Name) { if (-not $cols.Contains($p)) { $cols.Add($p) } } }
        $data = New-Object System.Collections.Generic.List[object]
        foreach ($row in $rows) {
            $cells = [string[]]@(foreach ($c in $cols) {
                $p = $row.PSObject.Properties[$c]
                if ($p -and $null -ne $p.Value) { "$($p.Value)" } else { '' }
            })
            $data.Add($cells)
        }
        $secList.Add(@{
            name = $name
            desc = "$($sec.Description)"
            role = if ($groupNames.Contains($name)) { $name } else { $null }
            cols = $cols.ToArray()
            rows = $data.ToArray()
        })
    }

    $payload = @{
        meta = @{
            generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            by        = "$env:USERDOMAIN\$env:USERNAME"
            host      = "$env:COMPUTERNAME"
            version   = "$($script:AppVersion)"
            hosts     = [string[]]$script:OfficialHosts
        }
        groups   = $groupNames.ToArray()
        servers  = $serverGroups
        sections = $secList.ToArray()
    }
    # "</" can never close the <script> block; < > & are escaped as well
    $json = ($payload | ConvertTo-Json -Depth 8 -Compress) -replace '</', '<\/' -replace '<!--', '<\!--'

    $css = @'
:root{--blue:#1f3a93;--blue-lt:#e8eefc;--ink:#1d2433;--muted:#5f6b7a;--line:#d9dee8;--bg:#fff;--row:#fafbfd;
--bad:#b42318;--bad-bg:#fde8e7;--warn:#9a5b00;--warn-bg:#fff1d6;--soon:#7a6a00;--soon-bg:#fffbd6;--ok:#00783c;--ok-bg:#e3f5ea}
*{box-sizing:border-box}
body{font-family:'Segoe UI',Arial,sans-serif;color:var(--ink);margin:0;background:var(--bg)}
header{background:var(--blue-lt);padding:18px 28px 14px;border-bottom:3px solid var(--blue)}
header h1{margin:0;color:var(--blue);font-size:24px}
header p{margin:4px 0 0;color:var(--muted);font-size:13px}
.bar{position:sticky;top:0;z-index:5;background:#fff;border-bottom:1px solid var(--line);padding:10px 28px;box-shadow:0 2px 6px rgba(31,58,147,.06)}
.row{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
.row+.row{margin-top:8px}
.lbl{font-size:12px;color:var(--muted);margin-right:4px;min-width:42px}
.chip{border:1px solid var(--line);background:#fff;color:var(--ink);border-radius:999px;padding:4px 11px;font:inherit;font-size:12.5px;cursor:pointer;line-height:1.4}
.chip:hover{border-color:var(--blue)}
.chip[aria-pressed=true]{background:var(--blue);border-color:var(--blue);color:#fff}
.chip .n{opacity:.7;margin-left:4px;font-size:11px}
.chip.prob[aria-pressed=true]{background:var(--bad);border-color:var(--bad)}
input[type=search]{border:1px solid var(--line);border-radius:6px;padding:6px 10px;font:inherit;font-size:13px;width:280px;max-width:100%}
.btn{border:1px solid var(--blue);background:#fff;color:var(--blue);border-radius:6px;padding:5px 10px;font:inherit;font-size:12px;cursor:pointer}
.btn:hover{background:var(--blue-lt)}
main{padding:8px 28px 40px}
.kpis{display:flex;flex-wrap:wrap;gap:12px;margin:14px 0}
.kpi{border:1px solid var(--line);border-radius:8px;padding:10px 16px;min-width:150px;background:#fff;text-align:left;font:inherit;cursor:default}
.kpi b{display:block;font-size:24px} .kpi span{font-size:12px;color:var(--muted)}
.kpi.bad b{color:var(--bad)} .kpi.warn b{color:var(--warn)}
nav{font-size:13px;margin:4px 0 6px;line-height:1.9} nav a{color:var(--blue);margin-right:14px;text-decoration:none;white-space:nowrap}
nav a:hover{text-decoration:underline}
section{margin-top:26px}
.sh{display:flex;align-items:baseline;gap:12px;border-bottom:1px solid var(--line);padding-bottom:4px}
h2{color:var(--blue);font-size:18px;margin:0}
.cnt{font-size:12px;color:var(--muted)} .sh .btn{margin-left:auto}
.desc{color:var(--muted);font-size:12px;margin:6px 0 8px}
.wrap{overflow-x:auto;border:1px solid var(--line);border-radius:6px}
table{border-collapse:collapse;font-size:12px;width:100%}
th{background:var(--blue);color:#fff;text-align:left;padding:7px 8px;white-space:nowrap;cursor:pointer;user-select:none;position:sticky;top:0}
th:hover{background:#2a4bb5} th .ar{opacity:.85;margin-left:4px;font-size:10px}
td{border-top:1px solid var(--line);padding:5px 8px;vertical-align:top}
tr:nth-child(even) td{background:var(--row)}
td.bad{background:var(--bad-bg)!important;color:var(--bad);font-weight:600}
td.warn{background:var(--warn-bg)!important;color:var(--warn);font-weight:600}
td.soon{background:var(--soon-bg)!important;color:var(--soon);font-weight:600}
td.ok{background:var(--ok-bg)!important;color:var(--ok);font-weight:600}
td a{color:var(--blue)} mark{background:#fff3a3;padding:0}
.empty{color:var(--muted);font-style:italic;font-size:12px;padding:8px 0}
.hidden{display:none!important}
footer{color:var(--muted);font-size:11px;padding:0 28px 24px}
@media print{.bar,.sh .btn{display:none}th{position:static}section{break-inside:avoid-page}}
'@

    $js = @'
(function(){
"use strict";
var D=JSON.parse(document.getElementById("sw-data").textContent);
var S={roles:[],problems:false,q:""};
var sortState={};
function el(t,c,txt){var e=document.createElement(t);if(c)e.className=c;if(txt!=null)e.textContent=txt;return e;}
function cls(v){v=String(v||"");
 if(/^(EOL|EXPIRED)/.test(v))return"bad";
 if(/^(Extended support|Expires <= (30|60))/.test(v))return"warn";
 if(/^Expires <= 90/.test(v))return"soon";
 if(/^(Supported|Valid)/.test(v))return"ok";return"";}
function isProblem(sec,row){var i=sec.cols.indexOf("Status");if(i<0)return false;var c=cls(row[i]);return c==="bad"||c==="warn"||c==="soon";}
function serverIn(srv){if(!S.roles.length)return true;var g=D.servers[srv]||[];for(var i=0;i<g.length;i++)if(S.roles.indexOf(g[i])>=0)return true;return false;}
function sectionVisible(sec){if(S.problems&&sec.cols.indexOf("Status")<0)return false;return !sec.role||!S.roles.length||S.roles.indexOf(sec.role)>=0;}
function rowVisible(sec,row){
 var gi=sec.cols.indexOf("Role Group"),si=sec.cols.indexOf("Server");
 if(S.roles.length){
  if(gi>=0&&S.roles.indexOf(row[gi])<0)return false;
  if(gi<0&&si>=0&&!serverIn(row[si]))return false;}
 if(S.problems&&sec.cols.indexOf("Status")>=0&&!isProblem(sec,row))return false;
 if(S.q){var q=S.q.toLowerCase(),hit=false;for(var k=0;k<row.length;k++)if(String(row[k]).toLowerCase().indexOf(q)>=0){hit=true;break;}if(!hit)return false;}
 return true;}
function cmp(a,b){var na=parseFloat(a),nb=parseFloat(b);
 if(/^-?\d+(\.\d+)?$/.test(a)&&/^-?\d+(\.\d+)?$/.test(b))return na-nb;
 if(a===""&&b!=="")return 1;if(b===""&&a!=="")return -1;
 return String(a).localeCompare(String(b),undefined,{numeric:true,sensitivity:"base"});}
function hostOk(u){var m=/^https:\/\/([^\/]+)\//.exec(u);return m&&D.meta.hosts.indexOf(m[1])>=0?m[1]:null;}
function fillCell(td,val){var h=hostOk(val);
 if(h){var a=el("a",null,h);a.href=val;a.target="_blank";a.rel="noopener";td.appendChild(a);return;}
 if(S.q){var s=String(val),lo=s.toLowerCase(),q=S.q.toLowerCase(),p=0,i;
  while((i=lo.indexOf(q,p))>=0){td.appendChild(document.createTextNode(s.slice(p,i)));td.appendChild(el("mark",null,s.slice(i,i+q.length)));p=i+q.length;}
  td.appendChild(document.createTextNode(s.slice(p)));return;}
 td.textContent=val;}
function visibleRows(sec,idx){var rows=sec.rows.filter(function(r){return rowVisible(sec,r);});
 var st=sortState[idx];if(st){rows=rows.slice().sort(function(a,b){return st.dir*cmp(a[st.col],b[st.col]);});}
 return rows;}
function csv(sec,rows){var esc=function(v){v=String(v==null?"":v);if(/^[=+\-@\t\r]/.test(v)&&!/^-?\d+(\.\d+)?$/.test(v))v="'"+v;return /[;"\n\r]/.test(v)?'"'+v.replace(/"/g,'""')+'"':v;};
 var out=[sec.cols.map(esc).join(";")];rows.forEach(function(r){out.push(r.map(esc).join(";"));});
 var blob=new Blob(["\ufeff"+out.join("\r\n")],{type:"text/csv;charset=utf-8"});
 var a=el("a");a.href=URL.createObjectURL(blob);
 a.download="ServerWizard_"+sec.name.replace(/[^A-Za-z0-9]+/g,"_").replace(/^_|_$/g,"")+(S.roles.length?"_"+S.roles.join("+").replace(/[^A-Za-z0-9+]+/g,""):"")+".csv";
 document.body.appendChild(a);a.click();setTimeout(function(){URL.revokeObjectURL(a.href);a.remove();},0);}
function renderSection(sec,idx,host){
 host.textContent="";
 var rows=visibleRows(sec,idx);
 var head=el("div","sh");head.appendChild(el("h2",null,sec.name));
 head.appendChild(el("span","cnt",rows.length+" of "+sec.rows.length+" row(s)"));
 var b=el("button","btn","Download view (CSV)");b.type="button";b.onclick=function(){csv(sec,rows);};head.appendChild(b);
 host.appendChild(head);host.appendChild(el("p","desc",sec.desc));
 if(!rows.length){host.appendChild(el("p","empty","No rows match the current filter."));return rows.length;}
 var wrap=el("div","wrap"),t=el("table"),thead=el("thead"),tr=el("tr");
 sec.cols.forEach(function(c,ci){var th=el("th",null,c);var st=sortState[idx];
  if(st&&st.col===ci)th.appendChild(el("span","ar",st.dir>0?"\u25B2":"\u25BC"));
  th.title="Sort by "+c;th.onclick=function(){var s=sortState[idx];sortState[idx]={col:ci,dir:(s&&s.col===ci)?-s.dir:1};renderSection(sec,idx,host);};
  tr.appendChild(th);});
 thead.appendChild(tr);t.appendChild(thead);
 var tb=el("tbody"),si=sec.cols.indexOf("Status");
 rows.forEach(function(r){var row=el("tr");r.forEach(function(v,ci){var td=el("td");if(ci===si){var c=cls(v);if(c)td.className=c;}fillCell(td,v);row.appendChild(td);});tb.appendChild(row);});
 t.appendChild(tb);wrap.appendChild(t);host.appendChild(wrap);return rows.length;}
function sec(name){for(var i=0;i<D.sections.length;i++)if(D.sections[i].name===name)return D.sections[i];return null;}
function countRows(name,test){var s=sec(name);if(!s)return 0;var i=s.cols.indexOf("Status");
 return s.rows.filter(function(r){return rowVisible(s,r)&&test(String(r[i]||""));}).length;}
function renderKpis(){var k=document.getElementById("kpis");k.textContent="";
 var n=Object.keys(D.servers).filter(serverIn).length;
 var items=[["Servers in view",n,""],
  ["OS past EOL",countRows("Operating Systems",function(v){return /^EOL/.test(v);}),"bad"],
  ["DB engines past EOL",countRows("SQL / Database",function(v){return /^EOL/.test(v);}),"bad"],
  ["Certificates expired",countRows("SSL Certificates",function(v){return v==="EXPIRED";}),"bad"],
  ["Certificates <= 30 days",countRows("SSL Certificates",function(v){return v==="Expires <= 30 days";}),"warn"]];
 items.forEach(function(x){var d=el("div","kpi "+x[2]);d.appendChild(el("b",null,String(x[1])));d.appendChild(el("span",null,x[0]));k.appendChild(d);});}
function render(){
 var nav=document.getElementById("nav");nav.textContent="";
 D.sections.forEach(function(s,i){var host=document.getElementById("sec"+i);
  if(!sectionVisible(s)){host.classList.add("hidden");return;}
  host.classList.remove("hidden");var c=renderSection(s,i,host);
  var a=el("a",null,s.name+" ("+c+")");a.href="#sec"+i;a.onclick=function(e){e.preventDefault();host.scrollIntoView({behavior:"smooth"});};nav.appendChild(a);});
 renderKpis();
 document.querySelectorAll("#roles .chip").forEach(function(b){var r=b.getAttribute("data-role");
  b.setAttribute("aria-pressed",String(r===""?S.roles.length===0:S.roles.indexOf(r)>=0));});
 document.getElementById("prob").setAttribute("aria-pressed",String(S.problems));
 var h="roles="+S.roles.map(encodeURIComponent).join(",")+(S.problems?"&problems=1":"");
 if(S.roles.length||S.problems){history.replaceState(null,"","#"+h);}else{history.replaceState(null,"",location.pathname+location.search);}}
function readHash(){S.roles=[];S.problems=false;var h=location.hash.replace(/^#/,"");if(!h||h.indexOf("sec")===0)return;h.split("&").forEach(function(p){var kv=p.split("=");
 if(kv[0]==="roles"&&kv[1])S.roles=kv[1].split(",").map(decodeURIComponent).filter(function(r){return D.groups.indexOf(r)>=0;});
 if(kv[0]==="problems")S.problems=kv[1]==="1";});}
function build(){
 var m=D.meta;document.getElementById("meta").textContent="Generated "+m.generated+" by "+m.by+" on "+m.host+" \u00B7 Server Wizard v"+m.version+" \u00B7 "+Object.keys(D.servers).length+" server(s)";
 var roles=document.getElementById("roles");
 var all=el("button","chip","All roles");all.type="button";all.setAttribute("data-role","");all.onclick=function(){S.roles=[];render();};roles.appendChild(all);
 D.groups.forEach(function(g){var n=Object.keys(D.servers).filter(function(s){return D.servers[s].indexOf(g)>=0;}).length;
  var b=el("button","chip",g);b.type="button";b.setAttribute("data-role",g);b.appendChild(el("span","n",String(n)));
  b.title="Click: show only "+g+" | Ctrl/Shift+click: add to selection";
  b.onclick=function(e){var i=S.roles.indexOf(g);
   if(e.ctrlKey||e.metaKey||e.shiftKey){if(i>=0)S.roles.splice(i,1);else S.roles.push(g);}
   else{S.roles=(S.roles.length===1&&i===0)?[]:[g];}
   render();};
  roles.appendChild(b);});
 var p=document.getElementById("prob");p.onclick=function(){S.problems=!S.problems;render();};
 var q=document.getElementById("q"),t;q.oninput=function(){clearTimeout(t);t=setTimeout(function(){S.q=q.value.trim();render();},180);};
 document.getElementById("reset").onclick=function(){S={roles:[],problems:false,q:""};q.value="";sortState={};render();};
 var main=document.getElementById("sections");D.sections.forEach(function(s,i){var x=el("section");x.id="sec"+i;main.appendChild(x);});
 readHash();render();
 window.addEventListener("hashchange",function(){if(location.hash.indexOf("#sec")===0)return;readHash();render();});}
build();
})();
'@

    $title = 'Server Wizard - Role Report'
    $srcs  = ($script:OfficialHosts | ForEach-Object { & $enc $_ }) -join ', '
    return @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>$css</style></head><body>
<header><h1>Server Wizard &ndash; Role-Based Report</h1><p id="meta"></p></header>
<div class="bar">
 <div class="row" id="roles"><span class="lbl">Roles</span></div>
 <div class="row"><span class="lbl">Filter</span>
  <button type="button" class="chip prob" id="prob" aria-pressed="false">Problems only (EOL / expiring)</button>
  <input type="search" id="q" placeholder="Search server, product, version, certificate..." aria-label="Search">
  <button type="button" class="btn" id="reset">Reset</button>
 </div>
</div>
<main><div class="kpis" id="kpis"></div><nav id="nav"></nav><div id="sections"></div></main>
<footer>Click a role to show only that role (Ctrl/Shift+click to combine), click a column header to sort. The address bar keeps the selected view, so the link can be bookmarked. Support and EOL dates come from official vendor sources only ($srcs). Install dates marked approx. are folder/binary creation times. Read-only inventory; no changes were made to any server.</footer>
<script type="application/json" id="sw-data">$json</script>
<script>$js</script>
</body></html>
"@
}

# CSV/Excel formula-injection guard for text cells
function ConvertTo-SafeCsvRow($row) {
    $o = [ordered]@{}
    foreach ($p in $row.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [string] -and $v -match '^[=+\-@\t\r]' -and $v -notmatch '^-?\d+(\.\d+)?$') { $v = "'" + $v }
        $o[$p.Name] = $v
    }
    return [PSCustomObject]$o
}

# Default report language (remembered for the session; set by the Export dialog)
$script:ReportLangDefault = 'tr'

function Get-ReportScopeText([string[]]$Roles, [int]$serverCount, [bool]$AllServers) {
    $r = if (@($Roles).Count -gt 0) { (@($Roles) -join ', ') } else { (T 'scope_all_roles') }
    $s = if ($AllServers) { "all scanned servers" } else { "selected servers" }
    if ($script:RptLang -eq 'tr') { $s = if ($AllServers) { 'taranan t&#252;m sunucular' } else { 'se&#231;ili sunucular' } }
    # Plain text: the renderer HTML-encodes it
    return [Net.WebUtility]::HtmlDecode("$r | $s")
}

# Builds the readable report (HTML and / or PDF) for the chosen roles / servers.
function Invoke-RoleReport {
    param(
        [ValidateSet('Html', 'Pdf', 'Both')][string]$Format = 'Html',
        [string[]]$Roles = @(),
        [switch]$AllServers,
        [ValidateSet('tr', 'en')][string]$Language = 'tr'
    )
    if ($script:Results.Keys.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Run a scan first.", "Export Report", "OK", "Information") | Out-Null
        return
    }
    $keys = @(Get-ReportServerKeys -Roles $Roles -AllServers:$AllServers)
    if ($keys.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No scanned server matches the selected roles.", "Export Report", "OK", "Information") | Out-Null
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmm'
    $tag   = ''
    if (@($Roles).Count -gt 0 -and @($Roles).Count -le 3) { $tag = '_' + ((@($Roles) | ForEach-Object { $_ -replace '[^A-Za-z0-9]+', '' }) -join '+') }

    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    if ($Format -eq 'Html') { $dlg.Filter = "HTML report (*.html)|*.html"; $ext = 'html' }
    else { $dlg.Filter = "PDF report (*.pdf)|*.pdf"; $ext = 'pdf' }
    $dlg.FileName = "ServerWizard_Report${tag}_$stamp.$ext"
    $dlg.Title = if ($Format -eq 'Both') { 'Save report (the HTML copy is saved next to the PDF)' } else { 'Save report' }
    try { if ($dlg.ShowDialog($form) -ne "OK") { return }; $target = $dlg.FileName } finally { $dlg.Dispose() }

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $tmpHtml = $null
    try {
        Write-Log "Report ($Format, $Language) started for $($keys.Count) servers -> $target"
        Set-Status "Building report for $($keys.Count) server(s)..."
        # Lifecycle dates are re-checked against the official sources
        # (skipped only if that already happened in the last 15 minutes)
        Update-LifecycleIfStale
        $script:RptLang = $Language
        $model = Get-ReportModel $keys $Roles
        $html  = ConvertTo-ReadableReport $model $Language (Get-ReportScopeText $Roles $keys.Count ([bool]$AllServers))
        $utf8  = New-Object Text.UTF8Encoding($true)

        switch ($Format) {
            'Html' {
                [IO.File]::WriteAllText($target, $html, $utf8)
                $open = $target
            }
            'Both' {
                $htmlPath = [IO.Path]::ChangeExtension($target, '.html')
                [IO.File]::WriteAllText($htmlPath, $html, $utf8)
                Set-Status "Printing PDF with the local browser..."
                Convert-HtmlToPdf $htmlPath $target
                $open = $target
            }
            'Pdf' {
                $tmpHtml = Join-Path $env:TEMP ("ServerWizard_report_" + [guid]::NewGuid().ToString('N') + '.html')
                [IO.File]::WriteAllText($tmpHtml, $html, $utf8)
                Set-Status "Printing PDF with the local browser..."
                Convert-HtmlToPdf $tmpHtml $target
                $open = $target
            }
        }
        Set-Status "Report saved ($($keys.Count) servers): $target" $script:OkGreen
        Write-Log "Report ($Format) finished: $target"
        try { Start-Process -FilePath $open } catch { Write-Log "Could not open report: $($_.Exception.Message)" }
    }
    catch {
        Write-Log "REPORT FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        $msg = "Report failed: $($_.Exception.Message)"
        if ($Format -ne 'Html') { $msg += "`n`nTip: choose the HTML format and use 'Print / PDF' in the browser." }
        [System.Windows.Forms.MessageBox]::Show("$msg`n`nSee log: $script:LogFile", "Export Report", "OK", "Error") | Out-Null
        Set-Status "Report failed (see log)." ([System.Drawing.Color]::Red)
    }
    finally {
        if ($tmpHtml -and (Test-Path -LiteralPath $tmpHtml)) { Remove-Item -LiteralPath $tmpHtml -Force -ErrorAction SilentlyContinue }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

# ============================================================================
# Reports module (in-app): a "Reports" tab with a role selector, a sortable
# grid of the selected report section and export / refresh buttons.
# ============================================================================
$script:ReportSections = $null
$script:ReportKeys     = @()

# Re-checks the official sources unless that already happened very recently
function Update-LifecycleIfStale([int]$maxAgeMinutes = 15) {
    if ($script:LifecycleRefreshed -and ((Get-Date) - $script:LifecycleRefreshed).TotalMinutes -lt $maxAgeMinutes) { return }
    Update-AllLifecycle
}

function ConvertTo-ReportTable($rows) {
    $dt = New-Object System.Data.DataTable
    $rows = @($rows)
    $cols = @()
    foreach ($row in $rows) { foreach ($p in $row.PSObject.Properties.Name) { if ($cols -notcontains $p) { $cols += $p } } }
    foreach ($c in $cols) { [void]$dt.Columns.Add($c, [string]) }
    foreach ($row in $rows) {
        $dr = $dt.NewRow()
        foreach ($c in $cols) {
            $p = $row.PSObject.Properties[$c]
            $dr[$c] = if ($p -and $null -ne $p.Value) { "$($p.Value)" } else { '' }
        }
        [void]$dt.Rows.Add($dr)
    }
    return ,$dt
}

function Show-ReportSection {
    $ui = $script:ReportsUi
    if (-not $ui -or -not $script:ReportSections) { return }
    $name = "$($ui.Combo.SelectedItem)" -replace '\s+\(\d+\)$', ''
    if (-not $script:ReportSections.Contains($name)) { return }
    $sec = $script:ReportSections[$name]
    $ui.Grid.DataSource = $null
    $ui.Grid.DataSource = (ConvertTo-ReportTable $sec.Rows)
    $ui.Info.Text = "$($sec.Description)   |   $(@($sec.Rows).Count) row(s), $($script:ReportKeys.Count) server(s). Double-click a row to open the server."
}

function Update-ReportsTab([bool]$refreshLifecycle = $false) {
    $ui = $script:ReportsUi
    if (-not $ui) { return }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        if ($refreshLifecycle) { $script:LifecycleRefreshed = $null }
        Update-LifecycleIfStale
        $script:ReportKeys     = Get-ReportServerKeys
        $script:ReportSections = Get-ReportSections $script:ReportKeys
        $prev = "$($ui.Combo.SelectedItem)" -replace '\s+\(\d+\)$', ''
        $ui.Combo.BeginUpdate()
        $ui.Combo.Items.Clear()
        foreach ($n in $script:ReportSections.Keys) { [void]$ui.Combo.Items.Add("$n ($(@($script:ReportSections[$n].Rows).Count))") }
        $ui.Combo.EndUpdate()
        $idx = 0
        for ($i = 0; $i -lt $ui.Combo.Items.Count; $i++) { if (("$($ui.Combo.Items[$i])" -replace '\s+\(\d+\)$', '') -eq $prev) { $idx = $i } }
        if ($ui.Combo.Items.Count -gt 0) { $ui.Combo.SelectedIndex = $idx }   # triggers Show-ReportSection
        $when = if ($script:LifecycleRefreshed) { $script:LifecycleRefreshed.ToString('yyyy-MM-dd HH:mm') } else { '-' }
        Set-Status "Reports ready for $($script:ReportKeys.Count) server(s). Official lifecycle data checked: $when" $script:OkGreen
    }
    catch {
        Write-Log "REPORTS TAB FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        Set-Status "Reports failed: $($_.Exception.Message) (see log)" ([System.Drawing.Color]::Red)
    }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Open-ReportsTab {
    if ($script:Results.Keys.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No inventory yet - run a scan first.", "Reports", "OK", "Information") | Out-Null
        return
    }
    foreach ($t in $tabs.TabPages) {
        if ($t.Text -eq 'Reports') { $tabs.SelectedTab = $t; Update-ReportsTab; return }
    }
    try {
        $tp = New-Object System.Windows.Forms.TabPage ('Reports')
        $tp.BackColor = [System.Drawing.Color]::White

        $bar = New-Object System.Windows.Forms.Panel
        $bar.Dock = 'Top'; $bar.Height = 64; $bar.BackColor = $script:MerlinBlueLt

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = 'Report:'; $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(10, 12)

        $cmb = New-Object System.Windows.Forms.ComboBox
        $cmb.DropDownStyle = 'DropDownList'
        $cmb.Location = New-Object System.Drawing.Point(64, 8); $cmb.Size = New-Object System.Drawing.Size(300, 23)

        $mk = {
            param($text, $x, $w, $primary)
            $b = New-Object System.Windows.Forms.Button
            $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, 6); $b.Size = New-Object System.Drawing.Size($w, 28)
            $b.FlatStyle = 'Flat'
            if ($primary) { $b.BackColor = $script:MerlinBlue; $b.ForeColor = [System.Drawing.Color]::White }
            else { $b.BackColor = $script:MerlinYellow; $b.ForeColor = $script:MerlinBlue }
            return $b
        }
        $btnRefresh = & $mk 'Refresh (official sources)' 374 180 $true
        $btnHtml    = & $mk 'Export HTML...' 562 120 $false
        $btnCsv     = & $mk 'Export PDF...' 690 120 $false

        $info = New-Object System.Windows.Forms.Label
        $info.AutoSize = $false; $info.Location = New-Object System.Drawing.Point(10, 40)
        $info.Size = New-Object System.Drawing.Size(1200, 20); $info.ForeColor = [System.Drawing.Color]::DimGray
        $info.Anchor = 'Top,Left,Right'

        $bar.Controls.AddRange(@($lbl, $cmb, $btnRefresh, $btnHtml, $btnCsv, $info))

        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = 'Fill'
        $grid.ReadOnly = $true
        $grid.AllowUserToAddRows = $false
        $grid.AllowUserToDeleteRows = $false
        $grid.RowHeadersVisible = $false
        $grid.SelectionMode = 'FullRowSelect'
        $grid.AutoSizeColumnsMode = 'DisplayedCells'
        $grid.BackgroundColor = [System.Drawing.Color]::White
        $grid.BorderStyle = 'None'
        $grid.EnableHeadersVisualStyles = $false
        $grid.ColumnHeadersDefaultCellStyle.BackColor = $script:MerlinBlue
        $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
        $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font($script:FontName, 9, [System.Drawing.FontStyle]::Bold)
        $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 253)
        Set-DoubleBuffered $grid

        # Status colouring (same rules as the HTML report)
        $grid.Add_CellFormatting({
            param($s, $e)
            try {
                if ($e.RowIndex -lt 0 -or $s.Columns[$e.ColumnIndex].Name -ne 'Status') { return }
                switch (Get-StatusClass "$($e.Value)") {
                    'bad'  { $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 232, 231); $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(180, 35, 24) }
                    'warn' { $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 241, 214); $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(154, 91, 0) }
                    'soon' { $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 251, 214); $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(122, 106, 0) }
                    'ok'   { $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(227, 245, 234); $e.CellStyle.ForeColor = $script:OkGreen }
                }
            } catch {}
        })
        $grid.Add_CellDoubleClick({
            param($s, $e)
            try {
                if ($e.RowIndex -lt 0 -or -not $s.Columns.Contains('Server')) { return }
                $srv = "$($s.Rows[$e.RowIndex].Cells['Server'].Value)"
                if ($srv) { Open-ServerTab $srv.ToUpper() }
            } catch { Write-Log "Report row open failed: $($_.Exception.Message)" }
        })

        $cmb.Add_SelectedIndexChanged({ try { Show-ReportSection } catch { Write-Log "Report section failed: $($_.Exception.Message)" } })
        $btnRefresh.Add_Click({ Update-ReportsTab $true })
        $btnHtml.Add_Click({ Invoke-RoleReport -Format Html -Language $script:ReportLangDefault })
        $btnCsv.Add_Click({ Invoke-RoleReport -Format Pdf -Language $script:ReportLangDefault })

        $tp.Controls.Add($grid)
        $tp.Controls.Add($bar)      # added last = docked first (top)
        [void]$tabs.TabPages.Add($tp)
        $tabs.SelectedTab = $tp
        $script:ReportsUi = @{ Tab = $tp; Combo = $cmb; Grid = $grid; Info = $info }
        $tp.Add_Disposed({ $script:ReportsUi = $null })
        Update-ReportsTab
    }
    catch {
        Write-Log "OPEN REPORTS FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        [System.Windows.Forms.MessageBox]::Show("Reports could not be opened: $($_.Exception.Message)`n`nSee log: $script:LogFile",
            "Reports", "OK", "Error") | Out-Null
    }
}

$script:ReportText = @{
    en = @{
        title = 'Server Inventory Report'
        generated = 'Generated {0} by {1} on {2}'
        scope = 'Scope'
        scope_all_roles = 'All roles'
        servers_n = '{0} server(s)'
        toc = 'Contents'
        s_summary = 'Summary'
        summary_note = 'Figures cover all servers in the report scope.'
        k_servers = 'Servers'
        k_roles = 'Role groups'
        k_os = 'OS versions'
        k_db = 'Database engines'
        k_certs = 'Certificates'
        d_roles = 'Servers per role'
        d_os = 'Operating system versions'
        d_db = 'Database products and versions'
        d_status = 'Support status (operating systems, databases, IIS)'
        d_certs = 'Certificates by expiry'
        s_calendar = 'Lifecycle calendar: next 12 months'
        cal_note = 'Vendor-published support dates and certificate expiry dates, by month.'
        cal_none = 'No dates.'
        ev_support = 'Mainstream support ends'
        ev_eol = 'End of support (EOL)'
        ev_esu = 'Paid extended security updates (ESU) end'
        ev_cert = 'Certificate expires'
        s_os = 'Operating systems'
        s_db = 'Databases'
        s_iis = 'IIS / Web'
        s_roles = 'Role views'
        s_certs = 'Certificates'
        s_cards = 'Server details'
        s_appendix = 'Sources and method'
        s_evidence = 'Role classification'
        c_server = 'Server'
        c_roles = 'Roles'
        c_os = 'Operating system'
        c_build = 'Build'
        c_installed = 'Installed'
        c_restart = 'Last restart'
        c_product = 'Product'
        c_version = 'Version'
        c_edition = 'Edition / instance'
        c_mainstream = 'Mainstream support end'
        c_support = 'Support end'
        c_eol = 'End of support (EOL)'
        c_esu = 'ESU end'
        c_days = 'Time left'
        c_status = 'Status'
        c_source = 'Source'
        c_state = 'Service'
        c_sites = 'Sites'
        c_expires = 'Expires'
        c_issuer = 'Issuer'
        c_inuse = 'In use'
        c_name = 'Name'
        c_count = 'Count'
        c_date = 'Date'
        c_event = 'Event'
        c_group = 'Role group'
        c_evidence = 'Evidence'
        c_retrieved = 'Retrieved'
        c_url = 'Official source'
        c_ip = 'IP addresses'
        c_ports = 'Listening ports'
        c_rolesvc = 'Roles and role services'
        c_features = 'Features'
        c_policy = 'Lifecycle policy'
        c_role_services = 'Role services'
        yes = 'Yes'
        no = 'No'
        not_bound = 'Not bound in IIS'
        st_supported = 'Supported'
        st_extended = 'Extended support (security updates only)'
        st_eol = 'End of support passed'
        st_esu = 'End of support passed (paid ESU available)'
        st_noeol = 'Supported (no end date announced)'
        st_unknown = 'No official date found'
        cs_expired = 'Expired'
        cs_30 = 'Expires within 30 days'
        cs_90 = 'Expires in 31-90 days'
        cs_365 = 'Expires in 91-365 days'
        cs_later = 'Valid for more than a year'
        f_roles = 'Roles'
        f_all = 'All'
        f_dates = 'Only dates passed or within 90 days'
        f_search = 'Search server, product, version, certificate...'
        f_reset = 'Reset'
        f_print = 'Print / PDF'
        f_hint = 'Filters apply to the detail tables and server cards; the summary always covers the full report scope.'
        m_dates = 'Support and end-of-support dates are read only from the vendors'' official pages when the report is created; every date is listed with its source and retrieval time below.'
        m_approx = 'Install dates marked (approx.) are folder or binary creation times.'
        m_certs = 'Certificates come from the LocalMachine\My and WebHosting stores; ''In use'' means the certificate is bound to an IIS site.'
        m_readonly = 'Read-only inventory: no changes were made to any server.'
        m_noeol = '''No end date announced'' means the vendor''s official page lists the version as supported without an end date.'
        offline = 'offline copy of the official page'
        approx = '(approx.)'
        none = 'None detected'
        in_days = 'in {0} days'
        days_ago = '{0} days ago'
        today = 'today'
        rescan = 'Rescan with v1.5 or later for details'
        more = 'and {0} more'
        page_note = 'Server Wizard v{0}'
    }
    tr = @{
        title = 'Sunucu Envanter Raporu'
        generated = '{0} tarihinde {1} taraf&#305;ndan {2} &#252;zerinde olu&#351;turuldu'
        scope = 'Kapsam'
        scope_all_roles = 'T&#252;m roller'
        servers_n = '{0} sunucu'
        toc = '&#304;&#231;indekiler'
        s_summary = '&#214;zet'
        summary_note = 'Rakamlar rapor kapsam&#305;ndaki t&#252;m sunucular&#305; kapsar.'
        k_servers = 'Sunucu'
        k_roles = 'Rol grubu'
        k_os = '&#304;&#351;letim sistemi s&#252;r&#252;m&#252;'
        k_db = 'Veritaban&#305; motoru'
        k_certs = 'Sertifika'
        d_roles = 'Role g&#246;re sunucu say&#305;s&#305;'
        d_os = '&#304;&#351;letim sistemi s&#252;r&#252;mleri'
        d_db = 'Veritaban&#305; &#252;r&#252;n ve s&#252;r&#252;mleri'
        d_status = 'Destek durumu (i&#351;letim sistemi, veritaban&#305;, IIS)'
        d_certs = 'Biti&#351; tarihine g&#246;re sertifikalar'
        s_calendar = 'Ya&#351;am d&#246;ng&#252;s&#252; takvimi: &#246;n&#252;m&#252;zdeki 12 ay'
        cal_note = '&#220;reticilerin yay&#305;mlad&#305;&#287;&#305; destek tarihleri ve sertifika biti&#351; tarihleri, aylara g&#246;re.'
        cal_none = 'Tarih yok.'
        ev_support = 'Ana ak&#305;m destek sona eriyor'
        ev_eol = 'Destek sona eriyor (EOL)'
        ev_esu = '&#220;cretli geni&#351;letilmi&#351; g&#252;venlik g&#252;ncellemeleri (ESU) sona eriyor'
        ev_cert = 'Sertifika s&#252;resi doluyor'
        s_os = '&#304;&#351;letim sistemleri'
        s_db = 'Veritabanlar&#305;'
        s_iis = 'IIS / Web'
        s_roles = 'Rol g&#246;r&#252;n&#252;mleri'
        s_certs = 'Sertifikalar'
        s_cards = 'Sunucu detaylar&#305;'
        s_appendix = 'Kaynaklar ve y&#246;ntem'
        s_evidence = 'Rol s&#305;n&#305;fland&#305;rmas&#305;'
        c_server = 'Sunucu'
        c_roles = 'Roller'
        c_os = '&#304;&#351;letim sistemi'
        c_build = 'Derleme'
        c_installed = 'Kurulum'
        c_restart = 'Son yeniden ba&#351;latma'
        c_product = '&#220;r&#252;n'
        c_version = 'S&#252;r&#252;m'
        c_edition = 'S&#252;r&#252;m t&#252;r&#252; / instance'
        c_mainstream = 'Ana ak&#305;m destek sonu'
        c_support = 'Destek sonu'
        c_eol = 'Destek sonu (EOL)'
        c_esu = 'ESU sonu'
        c_days = 'Kalan s&#252;re'
        c_status = 'Durum'
        c_source = 'Kaynak'
        c_state = 'Servis'
        c_sites = 'Siteler'
        c_expires = 'Biti&#351;'
        c_issuer = 'Yay&#305;mlayan'
        c_inuse = 'Kullan&#305;mda'
        c_name = 'Ad'
        c_count = 'Adet'
        c_date = 'Tarih'
        c_event = 'Olay'
        c_group = 'Rol grubu'
        c_evidence = 'Gerek&#231;e'
        c_retrieved = 'Al&#305;nma zaman&#305;'
        c_url = 'Resmi kaynak'
        c_ip = 'IP adresleri'
        c_ports = 'Dinlenen portlar'
        c_rolesvc = 'Roller ve rol servisleri'
        c_features = '&#214;zellikler'
        c_policy = 'Ya&#351;am d&#246;ng&#252;s&#252; politikas&#305;'
        c_role_services = 'Rol servisleri'
        yes = 'Evet'
        no = 'Hay&#305;r'
        not_bound = 'IIS''te ba&#287;l&#305; de&#287;il'
        st_supported = 'Destekleniyor'
        st_extended = 'Geni&#351;letilmi&#351; destek (yaln&#305;zca g&#252;venlik g&#252;ncellemeleri)'
        st_eol = 'Destek sona erdi'
        st_esu = 'Destek sona erdi (&#252;cretli ESU mevcut)'
        st_noeol = 'Destekleniyor (biti&#351; tarihi ilan edilmedi)'
        st_unknown = 'Resmi tarih bulunamad&#305;'
        cs_expired = 'S&#252;resi doldu'
        cs_30 = '30 g&#252;n i&#231;inde doluyor'
        cs_90 = '31-90 g&#252;n i&#231;inde doluyor'
        cs_365 = '91-365 g&#252;n i&#231;inde doluyor'
        cs_later = 'Bir y&#305;ldan uzun ge&#231;erli'
        f_roles = 'Roller'
        f_all = 'T&#252;m&#252;'
        f_dates = 'Yaln&#305;zca ge&#231;mi&#351; veya 90 g&#252;n i&#231;indeki tarihler'
        f_search = 'Sunucu, &#252;r&#252;n, s&#252;r&#252;m, sertifika ara...'
        f_reset = 'S&#305;f&#305;rla'
        f_print = 'Yazd&#305;r / PDF'
        f_hint = 'Filtreler detay tablolar&#305;na ve sunucu kartlar&#305;na uygulan&#305;r; &#246;zet her zaman rapor kapsam&#305;n&#305;n tamam&#305;n&#305; g&#246;sterir.'
        m_dates = 'Destek ve destek sonu tarihleri, rapor olu&#351;turulurken yaln&#305;zca &#252;reticilerin resmi sayfalar&#305;ndan okunur; her tarihin kayna&#287;&#305; ve al&#305;nma zaman&#305; a&#351;a&#287;&#305;da listelenir.'
        m_approx = '(yakla&#351;&#305;k) olarak i&#351;aretli kurulum tarihleri klas&#246;r veya dosya olu&#351;turulma zamanlar&#305;d&#305;r.'
        m_certs = 'Sertifikalar LocalMachine\My ve WebHosting depolar&#305;ndan okunur; ''Kullan&#305;mda'', sertifikan&#305;n bir IIS sitesine ba&#287;l&#305; oldu&#287;unu g&#246;sterir.'
        m_readonly = 'Salt okunur envanter: hi&#231;bir sunucuda de&#287;i&#351;iklik yap&#305;lmad&#305;.'
        m_noeol = '''Biti&#351; tarihi ilan edilmedi'', &#252;reticinin resmi sayfas&#305;n&#305;n s&#252;r&#252;m&#252; biti&#351; tarihi olmadan desteklenen olarak listeledi&#287;i anlam&#305;na gelir.'
        offline = 'resmi sayfan&#305;n &#231;evrimd&#305;&#351;&#305; kopyas&#305;'
        approx = '(yakla&#351;&#305;k)'
        none = 'Tespit edilmedi'
        in_days = '{0} g&#252;n sonra'
        days_ago = '{0} g&#252;n &#246;nce'
        today = 'bug&#252;n'
        rescan = 'Detaylar i&#231;in v1.5 veya sonras&#305; ile yeniden taray&#305;n'
        more = 've {0} tane daha'
        page_note = 'Server Wizard v{0}'
    }
}

# ============================================================================
# Readable report (v1.6): one model, rendered as a static, print-ready HTML
# page (light JS only filters / sorts what is already on the page) and
# printed to PDF with the local Edge / Chrome in headless mode.
# The report only SHOWS facts: no advice, no scores. Every lifecycle date
# carries its official source and retrieval time.
# ============================================================================
$script:RptLang = 'en'

function T([string]$key) {
    $d = $script:ReportText[$script:RptLang]
    # Strings are stored ASCII-safe (&#NNN;) and returned as plain text;
    # every value is HTML-encoded once where it is written into the page
    $v = if ($d -and $d.ContainsKey($key)) { $d[$key] } else { $script:ReportText['en'][$key] }
    return [Net.WebUtility]::HtmlDecode("$v")
}
function HE($v) { return [Net.WebUtility]::HtmlEncode("$v") }

function Format-RptDate($d) {
    if (-not $d) { return '' }
    $dt = $null
    if ($d -is [datetime]) { $dt = $d } else { $dt = ConvertTo-LcDate ((("$d" -split ' ')[0])) }
    if (-not $dt) { return "$d" }
    if ($script:RptLang -eq 'tr') { return $dt.ToString('dd.MM.yyyy') }
    return $dt.ToString('yyyy-MM-dd')
}
function Get-SortKey($d) {
    if (-not $d) { return '' }
    $dt = if ($d -is [datetime]) { $d } else { ConvertTo-LcDate ((("$d" -split ' ')[0])) }
    if ($dt) { return $dt.ToString('yyyyMMdd') }
    return "$d"
}
function Format-RptDays($days) {
    if ($null -eq $days -or "$days" -eq '') { return '' }
    $n = [int]$days
    if ($n -eq 0) { return (T 'today') }
    if ($n -gt 0) { return ((T 'in_days') -f $n) }
    return ((T 'days_ago') -f (-$n))
}

# Neutral status key for an OS / DB / IIS lifecycle result
function Get-StatusKey($lc) {
    if (-not $lc) { return 'st_unknown' }
    $s = "$($lc.Status)"
    if ($s -like 'EOL (paid ESU*') { return 'st_esu' }
    if ($s -like 'EOL*')           { return 'st_eol' }
    if ($s -like 'Extended*')      { return 'st_extended' }
    if ($s -like 'Supported (no*') { return 'st_noeol' }
    if ($s -like 'Supported*')     { return 'st_supported' }
    return 'st_unknown'
}
function Get-StatusTone([string]$key) {
    switch ($key) {
        'st_supported' { 'ok' }   'st_noeol' { 'ok' }   'cs_later' { 'ok' }   'cs_365' { 'ok' }
        'st_extended'  { 'warn' } 'cs_90'    { 'soon' } 'cs_30'    { 'warn' }
        'st_eol'       { 'bad' }  'st_esu'   { 'bad' }  'cs_expired' { 'bad' }
        default        { 'mute' }
    }
}
function Get-CertKey($days) {
    if ($null -eq $days) { return 'st_unknown' }
    if ($days -lt 0)   { return 'cs_expired' }
    if ($days -le 30)  { return 'cs_30' }
    if ($days -le 90)  { return 'cs_90' }
    if ($days -le 365) { return 'cs_365' }
    return 'cs_later'
}
# A row is "dated soon" when a shown date has passed or falls within 90 days
function Test-Soon($days) { return ($null -ne $days -and "$days" -ne '' -and [int]$days -le 90) }

function Get-OsShortName($r, $lc) {
    if ($lc -and $lc.Product -and $lc.Product -notlike 'Windows build*') { return $lc.Product }
    $inv = Get-Inv $r
    $cap = if ($inv -and $inv.OS) { "$($inv.OS.Caption)" } else { ("$($r.OperatingSystem)" -replace '\s*\(.*$', '') }
    return ($cap -replace '^Microsoft\s+', '' -replace '\s+(Standard|Datacenter|Essentials|Evaluation).*$', '')
}

# Builds everything the report shows, for the given servers and roles
function Get-ReportModel([string[]]$keys, [string[]]$Roles = @()) {
    $m = @{
        Keys = $keys; Roles = @($Roles); Groups = [ordered]@{}; ServerGroups = @{}
        Lifecycle = New-Object System.Collections.Generic.List[object]
        Certs     = New-Object System.Collections.Generic.List[object]
        Sources   = @{}
    }
    foreach ($g in $script:GroupOrder) { $m.Groups[$g] = New-Object System.Collections.Generic.List[string] }
    foreach ($k in $keys) {
        $gs = @(Get-EffectiveGroups $k $script:Results[$k] | Where-Object { @($Roles).Count -eq 0 -or $Roles -contains $_ })
        $m.ServerGroups[$k] = $gs
        foreach ($g in $gs) { if (-not $m.Groups.Contains($g)) { $m.Groups[$g] = New-Object System.Collections.Generic.List[string] }; $m.Groups[$g].Add($k) }
    }
    $addSrc = {
        param($lc)
        if ($lc -and $lc.Source -and -not $m.Sources.ContainsKey($lc.Source)) { $m.Sources[$lc.Source] = $lc.SourceNote }
    }
    foreach ($k in $keys) {
        $r = $script:Results[$k]; $inv = Get-Inv $r
        $osLc = Get-Lc (Get-OsLifecycleKey $r); & $addSrc $osLc
        $m.Lifecycle.Add([PSCustomObject]@{
            Server = $k; Category = 'OS'; Name = (Get-OsShortName $r $osLc); Version = $(if ($inv -and $inv.OS) { "$($inv.OS.Build)$(if ($inv.OS.UBR) { ".$($inv.OS.UBR)" })" } else { '' })
            Edition = $(if ($inv -and $inv.OS) { "$($inv.OS.Caption)" } else { "$($r.OperatingSystem)" })
            Installed = "$($r.InstallDate)"; Approx = $false; State = ''
            Lc = $osLc; StatusKey = (Get-StatusKey $osLc)
        })
        if ($inv -and $inv.IIS) {
            $iisLc = Get-Lc (Get-IisLifecycleKey $r); & $addSrc $iisLc
            $m.Lifecycle.Add([PSCustomObject]@{
                Server = $k; Category = 'IIS'; Name = "IIS $(("$($inv.IIS.Version)") -replace '\.0$', '')"; Version = "$($inv.IIS.VersionString)"
                Edition = "$($inv.IIS.SiteCount) site(s)"; Installed = "$($inv.IIS.InstallDate)"; Approx = $true; State = ''
                Lc = $iisLc; StatusKey = (Get-StatusKey $iisLc); Sites = @($inv.IIS.Sites | Where-Object { $_ })
            })
        }
        if ($inv) {
            foreach ($db in @($inv.Databases | Where-Object { $_ })) {
                $lc = Get-Lc (Get-DbLifecycleKey $db); & $addSrc $lc
                $nm = if ($lc -and $lc.Release) { $lc.Release } else { "$($db.Product)" }
                $m.Lifecycle.Add([PSCustomObject]@{
                    Server = $k; Category = 'DB'; Name = $nm; Product = "$($db.Product)"; Version = "$($db.Version)"
                    Edition = (@("$($db.Edition)", "$($db.Instance)") | Where-Object { $_ }) -join ' / '
                    Installed = "$($db.InstallDate)"; Approx = ("$($db.InstallDateSource)" -match 'approx|creation'); State = "$($db.ServiceState)"
                    Lc = $lc; StatusKey = $(if ($lc) { Get-StatusKey $lc } else { 'st_unknown' })
                })
            }
            foreach ($c in @($inv.Certificates | Where-Object { $_ })) {
                $days = Get-DaysLeft $c.NotAfter
                $name = if (@($c.DnsNames | Where-Object { $_ }).Count) { @($c.DnsNames)[0] } elseif ($c.FriendlyName) { $c.FriendlyName } else { ($c.Subject -replace '^CN=', '' -replace ',.*$', '') }
                $m.Certs.Add([PSCustomObject]@{
                    Server = $k; Name = $name; Subject = $c.Subject; Issuer = ($c.Issuer -replace '^CN=', '' -replace ',.*$', '')
                    Expires = $c.NotAfter; Days = $days; Key = (Get-CertKey $days); InUse = @($c.BoundTo | Where-Object { $_ })
                    Store = $c.Store; SelfSigned = $c.SelfSigned; Sans = @($c.DnsNames | Where-Object { $_ })
                })
            }
        }
    }
    return $m
}

function Get-RolesAttr($m, [string]$server) { return (HE ((@($m.ServerGroups[$server]) -join '|'))) }

# --- small HTML builders ------------------------------------------------------
function New-RptBars($title, $pairs, [string]$toneMap = '') {
    # $pairs: ordered dictionary label -> count (labels are trusted/encoded by caller)
    $max = 0; foreach ($v in $pairs.Values) { if ($v -gt $max) { $max = $v } }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<div class=""panel""><h3>$title</h3>")
    if ($pairs.Count -eq 0) { [void]$sb.Append("<p class=""muted"">$(T 'none')</p></div>"); return $sb.ToString() }
    [void]$sb.Append('<table class="bars">')
    foreach ($k in $pairs.Keys) {
        $v = $pairs[$k]; $w = if ($max -gt 0) { [math]::Max(2, [math]::Round(100 * $v / $max)) } else { 0 }
        $tone = 'blue'
        if ($toneMap -and $k -match '^<span data-tone="(\w+)"') { $tone = $matches[1] }
        [void]$sb.Append("<tr><td class=""bl"">$k</td><td class=""bb""><span class=""bar $tone"" style=""width:$w%""></span></td><td class=""bn"">$v</td></tr>")
    }
    [void]$sb.Append('</table></div>')
    return $sb.ToString()
}

function New-RptTable([string[]]$headers, $rows, [string]$id) {
    # $rows: list of @{ Attrs = '...'; Cells = @( @{ H = html; S = sortkey; C = class } ) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<div class=""tw""><table class=""grid"" id=""$id""><thead><tr>")
    foreach ($h in $headers) { [void]$sb.Append("<th>$h</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in $rows) {
        [void]$sb.Append("<tr $($row.Attrs)>")
        foreach ($c in $row.Cells) {
            $cls = if ($c.C) { " class=""$($c.C)""" } else { '' }
            $srt = if ($null -ne $c.S -and "$($c.S)" -ne '') { " data-sort=""$(HE $c.S)""" } else { '' }
            [void]$sb.Append("<td$cls$srt>$($c.H)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    if (@($rows).Count -eq 0) { return "<p class=""muted"">$(T 'none')</p>" }
    return $sb.ToString()
}
function Cell($html, $sort = $null, $cls = $null) { return @{ H = $html; S = $sort; C = $cls } }
function StatusCell([string]$key) { return (Cell "<span class=""pill $(Get-StatusTone $key)"">$(T $key)</span>" $key) }
function SrcCell($lc) {
    if (-not $lc -or -not $lc.Source) { return (Cell '') }
    $u = "$($lc.Source)"
    if ($u -match '^https://([^/]+)/' -and $script:OfficialHosts -contains $matches[1]) {
        return (Cell "<a href=""$(HE $u)"" target=""_blank"" rel=""noopener"">$(HE $matches[1])</a>")
    }
    return (Cell (HE $u))
}
function DaysCell($days) { return (Cell (HE (Format-RptDays $days)) $(if ($null -ne $days -and "$days" -ne '') { [int]$days + 100000 } else { '' }) 'nw') }
function DateCell($d) { return (Cell (HE (Format-RptDate $d)) (Get-SortKey $d) 'nw') }

function New-LcRow($m, $it, [switch]$WithServer) {
    $lc = $it.Lc
    $days = if ($lc) { $lc.DaysToEOL } else { $null }
    $inst = (Format-RptDate $it.Installed)
    if ($inst -and $it.Approx) { $inst += " $(T 'approx')" }
    $cells = @()
    if ($WithServer) { $cells += (Cell "<b>$(HE $it.Server)</b>" $it.Server) }
    $cells += (Cell (HE $it.Name))
    $cells += (Cell (HE $it.Version) $it.Version 'nw')
    $cells += (Cell (HE $it.Edition))
    $cells += (Cell (HE $inst) (Get-SortKey $it.Installed) 'nw')
    $cells += (DateCell $(if ($lc) { $lc.SupportEnd }))
    $cells += (DateCell $(if ($lc) { $lc.EOL }))
    $cells += (DaysCell $days)
    $cells += (StatusCell $it.StatusKey)
    $cells += (SrcCell $lc)
    $soon = if (Test-Soon $days) { '1' } else { '0' }
    return @{ Attrs = "data-roles=""$(Get-RolesAttr $m $it.Server)"" data-soon=""$soon"""; Cells = $cells }
}

function ConvertTo-ReadableReport($m, [string]$lang = 'en', [string]$scopeText = '') {
    $script:RptLang = if ($lang -eq 'tr') { 'tr' } else { 'en' }
    $now = Get-Date
    $sb  = New-Object System.Text.StringBuilder
    $lcHeaders = @((T 'c_product'), (T 'c_version'), (T 'c_edition'), (T 'c_installed'), (T 'c_support'), (T 'c_eol'), (T 'c_days'), (T 'c_status'), (T 'c_source'))
    $os  = @($m.Lifecycle | Where-Object { $_.Category -eq 'OS' })
    $dbs = @($m.Lifecycle | Where-Object { $_.Category -eq 'DB' })
    $iis = @($m.Lifecycle | Where-Object { $_.Category -eq 'IIS' })
    $groupsUsed = @($m.Groups.Keys | Where-Object { $m.Groups[$_].Count -gt 0 })

    # ---- head + toolbar ---------------------------------------------------
    [void]$sb.Append("<!DOCTYPE html><html lang=""$($script:RptLang)""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width, initial-scale=1"">")
    [void]$sb.Append("<title>$(T 'title')</title><style>$($script:ReportCss)</style></head><body>")
    $by = "$env:USERDOMAIN\$env:USERNAME"
    [void]$sb.Append("<header class=""cover""><div><h1>$(T 'title')</h1>")
    [void]$sb.Append("<p>$((T 'generated') -f (HE $now.ToString($(if ($script:RptLang -eq 'tr') { 'dd.MM.yyyy HH:mm' } else { 'yyyy-MM-dd HH:mm' }))), (HE $by), (HE $env:COMPUTERNAME))</p>")
    [void]$sb.Append("<p><b>$(T 'scope'):</b> $(HE $scopeText) &middot; $((T 'servers_n') -f $m.Keys.Count)</p></div>")
    [void]$sb.Append("<div class=""brand"">$((T 'page_note') -f (HE $script:AppVersion))</div></header>")

    [void]$sb.Append('<div class="fbar noprint"><div class="row"><span class="lbl">' + (T 'f_roles') + '</span>')
    [void]$sb.Append("<button type=""button"" class=""chip"" data-role="""" aria-pressed=""true"">$(T 'f_all')</button>")
    foreach ($g in $groupsUsed) { [void]$sb.Append("<button type=""button"" class=""chip"" data-role=""$(HE $g)"" aria-pressed=""false"">$(HE $g) <span class=""n"">$($m.Groups[$g].Count)</span></button>") }
    [void]$sb.Append('</div><div class="row">')
    [void]$sb.Append("<button type=""button"" class=""chip"" id=""soon"" aria-pressed=""false"">$(T 'f_dates')</button>")
    [void]$sb.Append("<input type=""search"" id=""q"" placeholder=""$(T 'f_search')"">")
    [void]$sb.Append("<button type=""button"" class=""btn"" id=""reset"">$(T 'f_reset')</button><button type=""button"" class=""btn pri"" id=""print"">$(T 'f_print')</button>")
    [void]$sb.Append("<span class=""hint"">$(T 'f_hint')</span></div></div><main>")

    # ---- TOC ----------------------------------------------------------------
    $toc = [ordered]@{ summary = (T 's_summary'); calendar = (T 's_calendar'); os = (T 's_os') }
    if ($dbs.Count) { $toc['db'] = (T 's_db') }
    if ($iis.Count) { $toc['iis'] = (T 's_iis') }
    $toc['roles'] = (T 's_roles'); $toc['certs'] = (T 's_certs'); $toc['cards'] = (T 's_cards'); $toc['appendix'] = (T 's_appendix')
    [void]$sb.Append("<nav class=""toc""><b>$(T 'toc')</b>")
    $n = 0; foreach ($k in $toc.Keys) { $n++; [void]$sb.Append("<a href=""#$k"">$n. $($toc[$k])</a>") }
    [void]$sb.Append('</nav>')

    # ---- 1. Summary -----------------------------------------------------------
    $osNames = [ordered]@{}; foreach ($o in ($os | Sort-Object Name)) { $l = HE $o.Name; if (-not $osNames.Contains($l)) { $osNames[$l] = 0 }; $osNames[$l]++ }
    $dbNames = [ordered]@{}; foreach ($d in ($dbs | Sort-Object Name, Version)) {
        $l = HE $(if ($d.Lc -and $d.Lc.Release) { $d.Lc.Release } else { "$($d.Product) $((("$($d.Version)" -split '\.')[0..1]) -join '.')" })
        if (-not $dbNames.Contains($l)) { $dbNames[$l] = 0 }; $dbNames[$l]++ }
    $kpi = @(
        @((T 'k_servers'), $m.Keys.Count), @((T 'k_roles'), $groupsUsed.Count), @((T 'k_os'), $osNames.Count),
        @((T 'k_db'), $dbs.Count), @((T 'k_certs'), $m.Certs.Count)
    )
    [void]$sb.Append("<section id=""summary""><h2>1. $(T 's_summary')</h2><p class=""muted"">$(T 'summary_note')</p><div class=""kpis"">")
    foreach ($k in $kpi) { [void]$sb.Append("<div class=""kpi""><b>$($k[1])</b><span>$($k[0])</span></div>") }
    [void]$sb.Append('</div><div class="panels">')
    $rolePairs = [ordered]@{}; foreach ($g in $groupsUsed) { $rolePairs[(HE $g)] = $m.Groups[$g].Count }
    [void]$sb.Append((New-RptBars (T 'd_roles') $rolePairs))
    [void]$sb.Append((New-RptBars (T 'd_os') $osNames))
    [void]$sb.Append((New-RptBars (T 'd_db') $dbNames))
    $stPairs = [ordered]@{}
    foreach ($sk in 'st_supported', 'st_noeol', 'st_extended', 'st_esu', 'st_eol', 'st_unknown') {
        $c = @($m.Lifecycle | Where-Object { $_.StatusKey -eq $sk }).Count
        if ($c) { $stPairs["<span data-tone=""$(Get-StatusTone $sk)"">$(T $sk)</span>"] = $c }
    }
    [void]$sb.Append((New-RptBars (T 'd_status') $stPairs 'tone'))
    $cPairs = [ordered]@{}
    foreach ($ck in 'cs_expired', 'cs_30', 'cs_90', 'cs_365', 'cs_later') {
        $c = @($m.Certs | Where-Object { $_.Key -eq $ck }).Count
        if ($c) { $cPairs["<span data-tone=""$(Get-StatusTone $ck)"">$(T $ck)</span>"] = $c }
    }
    [void]$sb.Append((New-RptBars (T 'd_certs') $cPairs 'tone'))
    [void]$sb.Append('</div></section>')

    # ---- 2. Calendar (next 12 months) -------------------------------------------
    $start = New-Object DateTime -ArgumentList $now.Year, $now.Month, 1
    $end   = $start.AddMonths(12)
    $events = New-Object System.Collections.Generic.List[object]
    $addEv = {
        param($date, $evKey, $name, $server)
        if ($date -and $date -ge $start -and $date -lt $end) { $events.Add([PSCustomObject]@{ Date = ([datetime]$date).Date; Ev = $evKey; Name = $name; Server = $server }) }
    }
    foreach ($it in $m.Lifecycle) {
        if (-not $it.Lc) { continue }
        if ($it.Lc.SupportEnd -and $it.Lc.EOL -and ([datetime]$it.Lc.SupportEnd).Date -ne ([datetime]$it.Lc.EOL).Date) { & $addEv $it.Lc.SupportEnd 'ev_support' $it.Name $it.Server }
        & $addEv $it.Lc.EOL 'ev_eol' $it.Name $it.Server
        & $addEv $it.Lc.ESUEnd 'ev_esu' $it.Name $it.Server
    }
    foreach ($c in $m.Certs) { $d = ConvertTo-LcDate ((("$($c.Expires)" -split ' ')[0])); & $addEv $d 'ev_cert' $c.Name $c.Server }
    $culture = if ($script:RptLang -eq 'tr') { [Globalization.CultureInfo]::GetCultureInfo('tr-TR') } else { [Globalization.CultureInfo]::GetCultureInfo('en-US') }
    [void]$sb.Append("<section id=""calendar"" class=""pb""><h2>2. $(T 's_calendar')</h2><p class=""muted"">$(T 'cal_note')</p><div class=""cal"">")
    for ($i = 0; $i -lt 12; $i++) {
        $ms = $start.AddMonths($i); $me = $ms.AddMonths(1)
        $mev = @($events | Where-Object { $_.Date -ge $ms -and $_.Date -lt $me })
        [void]$sb.Append("<div class=""mon""><h4>$(HE $culture.TextInfo.ToTitleCase($ms.ToString('MMMM yyyy', $culture)))</h4>")
        if ($mev.Count -eq 0) { [void]$sb.Append("<p class=""muted"">$(T 'cal_none')</p></div>"); continue }
        [void]$sb.Append('<ul>')
        foreach ($grp in ($mev | Group-Object Date, Ev, Name | Sort-Object { $_.Group[0].Date }, { $_.Group[0].Name })) {
            $e0 = $grp.Group[0]
            $srvs = @($grp.Group | ForEach-Object { $_.Server } | Sort-Object -Unique)
            $roles = HE ((@($srvs | ForEach-Object { $m.ServerGroups[$_] } | ForEach-Object { $_ } | Sort-Object -Unique)) -join '|')
            $list = if ($srvs.Count -le 6) { $srvs -join ', ' } else { (($srvs[0..5]) -join ', ') + ' ' + ((T 'more') -f ($srvs.Count - 6)) }
            $tone = if ($e0.Ev -eq 'ev_cert') { 'cert' } else { 'lc' }
            [void]$sb.Append("<li data-roles=""$roles"" data-soon=""1"" class=""$tone""><span class=""dd"">$(HE (Format-RptDate $e0.Date))</span> <b>$(HE $e0.Name)</b> &middot; $(T $e0.Ev)<br><span class=""muted"">$(HE $list)</span></li>")
        }
        [void]$sb.Append('</ul></div>')
    }
    [void]$sb.Append('</div></section>')

    # ---- 3. Operating systems -------------------------------------------------
    $sec = 3
    [void]$sb.Append("<section id=""os"" class=""pb""><h2>$sec. $(T 's_os')</h2>")
    $rows = foreach ($it in ($os | Sort-Object Name, Server)) {
        $r = $script:Results[$it.Server]
        $lc = $it.Lc
        $days = if ($lc) { $lc.DaysToEOL } else { $null }
        @{ Attrs = "data-roles=""$(Get-RolesAttr $m $it.Server)"" data-soon=""$(if (Test-Soon $days) { '1' } else { '0' })"""
           Cells = @((Cell "<b>$(HE $it.Server)</b>" $it.Server), (Cell (HE (@($m.ServerGroups[$it.Server]) -join ', '))), (Cell (HE $it.Name)),
                     (Cell (HE $it.Version) $it.Version 'nw'), (DateCell $it.Installed), (DateCell "$($r.LastRestartDate)"),
                     (DateCell $(if ($lc) { $lc.SupportEnd })), (DateCell $(if ($lc) { $lc.EOL })), (DateCell $(if ($lc) { $lc.ESUEnd })),
                     (DaysCell $days), (StatusCell $it.StatusKey), (SrcCell $lc)) }
    }
    [void]$sb.Append((New-RptTable @((T 'c_server'), (T 'c_roles'), (T 'c_os'), (T 'c_build'), (T 'c_installed'), (T 'c_restart'), (T 'c_mainstream'), (T 'c_eol'), (T 'c_esu'), (T 'c_days'), (T 'c_status'), (T 'c_source')) @($rows) 't-os'))
    [void]$sb.Append('</section>')

    # ---- 4. Databases ------------------------------------------------------------
    if ($dbs.Count) {
        $sec++
        [void]$sb.Append("<section id=""db"" class=""pb""><h2>$sec. $(T 's_db')</h2>")
        $rows = foreach ($it in ($dbs | Sort-Object Product, Version, Server)) { New-LcRow $m $it -WithServer }
        [void]$sb.Append((New-RptTable (@((T 'c_server')) + $lcHeaders) @($rows) 't-db'))
        [void]$sb.Append('</section>')
    }
    # ---- 5. IIS -------------------------------------------------------------------
    if ($iis.Count) {
        $sec++
        [void]$sb.Append("<section id=""iis"" class=""pb""><h2>$sec. $(T 's_iis')</h2>")
        $rows = foreach ($it in ($iis | Sort-Object Name, Server)) {
            $row = New-LcRow $m $it -WithServer
            $row.Cells[3] = (Cell (HE ((@($it.Sites) -join ', '))))
            $row
        }
        $h = @((T 'c_server')) + $lcHeaders; $h[3] = (T 'c_sites')
        [void]$sb.Append((New-RptTable $h @($rows) 't-iis'))
        [void]$sb.Append('</section>')
    }

    # ---- Role views ----------------------------------------------------------------
    $sec++
    [void]$sb.Append("<section id=""roles"" class=""pb""><h2>$sec. $(T 's_roles')</h2>")
    foreach ($g in $groupsUsed) {
        $def = $script:RoleDefs | Where-Object { $_.Group -eq $g } | Select-Object -First 1
        [void]$sb.Append("<div class=""rolev"" data-roles=""$(HE $g)""><h3>$(HE $g) <span class=""muted"">&middot; $((T 'servers_n') -f $m.Groups[$g].Count)</span></h3>")
        $rows = foreach ($k in ($m.Groups[$g] | Sort-Object)) {
            $r = $script:Results[$k]; $inv = Get-Inv $r
            $osIt = $os | Where-Object { $_.Server -eq $k } | Select-Object -First 1
            $svc = ''
            if ($g -eq 'SQL / Database') {
                $svc = (@($dbs | Where-Object { $_.Server -eq $k } | ForEach-Object { "$($_.Product) $($_.Version)" }) -join ', ')
            } elseif ($g -eq 'IIS / Web') {
                $svc = (@($iis | Where-Object { $_.Server -eq $k } | ForEach-Object { "$($_.Name): $((@($_.Sites) -join ', '))" }) -join ', ')
            } elseif ($inv -and $def -and $def.Features) {
                $svc = (@(Get-FeatureRows $inv $def | ForEach-Object { $_.DisplayName }) -join ', ')
            } else { $svc = "$($r.ThirdPartyServices)" }
            $days = if ($osIt -and $osIt.Lc) { $osIt.Lc.DaysToEOL } else { $null }
            @{ Attrs = "data-roles=""$(HE $g)"" data-soon=""$(if (Test-Soon $days) { '1' } else { '0' })"""
               Cells = @((Cell "<b>$(HE $k)</b>" $k), (Cell (HE $svc)), (Cell (HE $(if ($osIt) { $osIt.Name }))),
                         (DateCell $(if ($osIt -and $osIt.Lc) { $osIt.Lc.EOL })), (StatusCell $(if ($osIt) { $osIt.StatusKey } else { 'st_unknown' }))) }
        }
        [void]$sb.Append((New-RptTable @((T 'c_server'), (T 'c_role_services'), (T 'c_os'), (T 'c_eol'), (T 'c_status')) @($rows) ("t-role-" + ($g -replace '[^A-Za-z0-9]', ''))))
        [void]$sb.Append('</div>')
    }
    [void]$sb.Append('</section>')

    # ---- Certificates ------------------------------------------------------------------
    $sec++
    [void]$sb.Append("<section id=""certs"" class=""pb""><h2>$sec. $(T 's_certs')</h2>")
    $rows = foreach ($c in ($m.Certs | Sort-Object @{ Expression = { if ($null -eq $_.Days) { [int]::MaxValue } else { $_.Days } } }, Server)) {
        $use = if ($c.InUse.Count) { (T 'yes') + ': ' + (HE ($c.InUse -join ', ')) } else { (T 'no') }
        @{ Attrs = "data-roles=""$(Get-RolesAttr $m $c.Server)"" data-soon=""$(if (Test-Soon $c.Days) { '1' } else { '0' })"""
           Cells = @((Cell "<b>$(HE $c.Server)</b>" $c.Server), (Cell ("$(HE $c.Name)" + $(if ($c.Sans.Count -gt 1) { "<br><span class=""muted"">$(HE (($c.Sans | Select-Object -Skip 1) -join ', '))</span>" } else { '' }))),
                     (Cell (HE $c.Issuer)), (DateCell $c.Expires), (DaysCell $c.Days), (Cell $use $(if ($c.InUse.Count) { '1' } else { '0' })), (StatusCell $c.Key), (Cell (HE $c.Store))) }
    }
    [void]$sb.Append((New-RptTable @((T 'c_server'), (T 'c_name'), (T 'c_issuer'), (T 'c_expires'), (T 'c_days'), (T 'c_inuse'), (T 'c_status'), (T 'c_store')) @($rows) 't-certs'))
    [void]$sb.Append('</section>')

    # ---- Server cards ---------------------------------------------------------------------
    $sec++
    [void]$sb.Append("<section id=""cards"" class=""pb""><h2>$sec. $(T 's_cards')</h2>")
    foreach ($k in ($m.Keys | Sort-Object)) {
        $r = $script:Results[$k]; $inv = Get-Inv $r
        $osIt = $os | Where-Object { $_.Server -eq $k } | Select-Object -First 1
        $soon = @($m.Lifecycle | Where-Object { $_.Server -eq $k -and $_.Lc -and (Test-Soon $_.Lc.DaysToEOL) }).Count + @($m.Certs | Where-Object { $_.Server -eq $k -and (Test-Soon $_.Days) }).Count
        [void]$sb.Append("<article class=""card"" id=""srv-$(HE $k)"" data-roles=""$(Get-RolesAttr $m $k)"" data-soon=""$(if ($soon) { '1' } else { '0' })"">")
        [void]$sb.Append("<div class=""ch""><h3>$(HE $k)</h3><div>")
        foreach ($g in @($m.ServerGroups[$k])) { [void]$sb.Append("<span class=""tag"">$(HE $g)</span>") }
        [void]$sb.Append('</div></div><dl class="kv">')
        $kv = [ordered]@{}
        $kv[(T 'c_os')]        = HE ("$(if ($osIt) { $osIt.Edition }) $(if ($osIt -and $osIt.Version) { "($(T 'c_build') $($osIt.Version))" })")
        $kv[(T 'c_installed')] = HE (Format-RptDate "$($r.InstallDate)")
        $kv[(T 'c_restart')]   = HE (Format-RptDate "$($r.LastRestartDate)")
        if ($osIt -and $osIt.Lc) {
            $kv[(T 'c_mainstream')] = HE (Format-RptDate $osIt.Lc.SupportEnd)
            $kv[(T 'c_eol')]        = "$(HE (Format-RptDate $osIt.Lc.EOL)) <span class=""pill $(Get-StatusTone $osIt.StatusKey)"">$(T $osIt.StatusKey)</span>"
        }
        $kv[(T 'c_ip')]    = HE ("$($r.IPAddresses)" -replace ';\s*', ', ')
        $kv[(T 'c_ports')] = HE ("$($r.ListeningPorts)")
        if ($inv) {
            $roleTxt = @($inv.Features | Where-Object { $_ -and $_.Type -eq 'Role' } | ForEach-Object {
                $role = $_
                $svcs = @($inv.Features | Where-Object { $_ -and $_.Type -eq 'Role Service' -and $_.Parent -eq $role.Name } | ForEach-Object { $_.DisplayName })
                "$($role.DisplayName)" + $(if ($svcs) { " ($($svcs -join ', '))" } else { '' })
            })
            $kv[(T 'c_rolesvc')] = if ($roleTxt) { HE ($roleTxt -join '; ') } else { T 'none' }
            $feat = @($inv.Features | Where-Object { $_ -and $_.Type -eq 'Feature' -and $_.Depth -le 1 } | ForEach-Object { $_.DisplayName })
            $kv[(T 'c_features')] = if ($feat) { HE ($feat -join ', ') } else { T 'none' }
        } else { $kv[(T 'c_rolesvc')] = T 'rescan' }
        foreach ($kk in $kv.Keys) { [void]$sb.Append("<dt>$kk</dt><dd>$($kv[$kk])</dd>") }
        [void]$sb.Append('</dl>')
        $prod = @($m.Lifecycle | Where-Object { $_.Server -eq $k -and $_.Category -ne 'OS' })
        if ($prod.Count) {
            $rows = foreach ($it in $prod) { New-LcRow $m $it }
            [void]$sb.Append((New-RptTable $lcHeaders @($rows) "t-card-$(HE $k)-p"))
        }
        $cs = @($m.Certs | Where-Object { $_.Server -eq $k } | Sort-Object Days)
        if ($cs.Count) {
            $rows = foreach ($c in $cs) {
                @{ Attrs = "data-soon=""$(if (Test-Soon $c.Days) { '1' } else { '0' })"""
                   Cells = @((Cell (HE $c.Name)), (DateCell $c.Expires), (DaysCell $c.Days), (Cell $(if ($c.InUse.Count) { (T 'yes') + ': ' + (HE ($c.InUse -join ', ')) } else { T 'no' })), (StatusCell $c.Key)) }
            }
            [void]$sb.Append((New-RptTable @((T 'c_name'), (T 'c_expires'), (T 'c_days'), (T 'c_inuse'), (T 'c_status')) @($rows) "t-card-$(HE $k)-c"))
        }
        [void]$sb.Append('</article>')
    }
    [void]$sb.Append('</section>')

    # ---- Appendix: sources, method, classification ---------------------------------------
    $sec++
    [void]$sb.Append("<section id=""appendix"" class=""pb""><h2>$sec. $(T 's_appendix')</h2><ul class=""method"">")
    foreach ($mk in 'm_dates', 'm_noeol', 'm_approx', 'm_certs', 'm_readonly') { [void]$sb.Append("<li>$(T $mk)</li>") }
    [void]$sb.Append('</ul>')
    $rows = foreach ($u in ($m.Sources.Keys | Sort-Object)) {
        $note = "$($m.Sources[$u])"
        $when = if ($note -match '(\d{4}-\d{2}-\d{2}( \d{2}:\d{2})?)') { $matches[1] } else { $note }
        $txt  = HE $when
        if ($note -match 'offline') { $txt += " &middot; $(T 'offline')" }
        @{ Attrs = ''; Cells = @((Cell "<a href=""$(HE $u)"" target=""_blank"" rel=""noopener"">$(HE $u)</a>"), (Cell $txt $when 'nw')) }
    }
    [void]$sb.Append((New-RptTable @((T 'c_url'), (T 'c_retrieved')) @($rows) 't-src'))
    [void]$sb.Append("<h3>$(T 's_evidence')</h3>")
    $rows = foreach ($k in ($m.Keys | Sort-Object)) {
        if ($script:Overrides.ContainsKey($k)) {
            @{ Attrs = "data-roles=""$(Get-RolesAttr $m $k)"""; Cells = @((Cell (HE $k) $k), (Cell (HE $script:Overrides[$k])), (Cell 'Manual override')) }
            continue
        }
        foreach ($d in @(Get-RoleGroupDetails $script:Results[$k])) {
            if (@($m.Roles).Count -and $m.Roles -notcontains $d.Group) { continue }
            @{ Attrs = "data-roles=""$(HE $d.Group)"""; Cells = @((Cell (HE $k) $k), (Cell (HE $d.Group)), (Cell (HE $d.Reason))) }
        }
    }
    [void]$sb.Append((New-RptTable @((T 'c_server'), (T 'c_group'), (T 'c_evidence')) @($rows) 't-evidence'))
    [void]$sb.Append("</section></main><footer>$((T 'page_note') -f (HE $script:AppVersion)) &middot; $(T 'm_readonly')</footer>")
    [void]$sb.Append("<script>$($script:ReportJs)</script></body></html>")
    return $sb.ToString()
}

$script:ReportCss = @'
:root{--blue:#1f3a93;--blue-lt:#eef2fc;--ink:#1d2433;--muted:#5f6b7a;--line:#dde2ea;--row:#fafbfd;
--ok:#1e7b4b;--ok-bg:#e5f4ec;--warn:#9a5b00;--warn-bg:#fff1d6;--soon:#7a6a00;--soon-bg:#fff9cf;--bad:#a8261b;--bad-bg:#fbe6e4;--mute:#5f6b7a;--mute-bg:#eef0f3}
*{box-sizing:border-box}
html{-webkit-print-color-adjust:exact;print-color-adjust:exact}
body{font-family:'Segoe UI',Arial,sans-serif;color:var(--ink);margin:0;background:#fff;font-size:13px;line-height:1.45}
.cover{display:flex;justify-content:space-between;align-items:flex-end;gap:20px;background:var(--blue-lt);border-bottom:3px solid var(--blue);padding:22px 32px}
.cover h1{margin:0 0 6px;color:var(--blue);font-size:26px}
.cover p{margin:2px 0;color:var(--muted)} .brand{color:var(--blue);font-weight:600;white-space:nowrap}
.fbar{position:sticky;top:0;z-index:5;background:#fff;border-bottom:1px solid var(--line);padding:10px 32px;box-shadow:0 2px 6px rgba(31,58,147,.06)}
.row{display:flex;flex-wrap:wrap;gap:6px;align-items:center} .row+.row{margin-top:8px}
.lbl{font-size:12px;color:var(--muted);min-width:46px}
.chip{border:1px solid var(--line);background:#fff;color:var(--ink);border-radius:999px;padding:4px 12px;font:inherit;font-size:12.5px;cursor:pointer}
.chip:hover{border-color:var(--blue)} .chip[aria-pressed=true]{background:var(--blue);border-color:var(--blue);color:#fff}
.chip .n{opacity:.7;font-size:11px;margin-left:3px}
input[type=search]{border:1px solid var(--line);border-radius:6px;padding:6px 10px;font:inherit;width:300px;max-width:100%}
.btn{border:1px solid var(--blue);background:#fff;color:var(--blue);border-radius:6px;padding:5px 12px;font:inherit;font-size:12.5px;cursor:pointer}
.btn.pri{background:var(--blue);color:#fff} .hint{font-size:11.5px;color:var(--muted);margin-left:6px}
main{padding:6px 32px 32px;max-width:1500px}
.toc{display:flex;flex-wrap:wrap;gap:6px 16px;margin:16px 0 4px;font-size:13px} .toc a{color:var(--blue);text-decoration:none} .toc a:hover{text-decoration:underline}
section{margin-top:28px} h2{color:var(--blue);font-size:19px;margin:0 0 4px;padding-bottom:5px;border-bottom:2px solid var(--blue-lt)}
h3{font-size:14.5px;margin:16px 0 6px;color:var(--ink)} .muted{color:var(--muted)}
.kpis{display:flex;flex-wrap:wrap;gap:12px;margin:12px 0}
.kpi{border:1px solid var(--line);border-radius:8px;padding:10px 18px;min-width:140px} .kpi b{display:block;font-size:26px;color:var(--blue)} .kpi span{font-size:12px;color:var(--muted)}
.panels{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:14px}
.panel{border:1px solid var(--line);border-radius:8px;padding:10px 14px;break-inside:avoid} .panel h3{margin:2px 0 8px;font-size:13.5px}
table.bars{width:100%;border-collapse:collapse} .bars td{padding:3px 4px;font-size:12px;vertical-align:middle}
.bl{width:46%} .bb{width:44%} .bn{width:10%;text-align:right;font-weight:600}
.bar{display:block;height:10px;border-radius:5px;background:var(--blue)} .bar.ok{background:var(--ok)} .bar.warn{background:#d08a1a} .bar.soon{background:#c4b100} .bar.bad{background:var(--bad)} .bar.mute{background:#9aa4b2}
.cal{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px}
.mon{border:1px solid var(--line);border-radius:8px;padding:8px 12px;break-inside:avoid} .mon h4{margin:0 0 6px;color:var(--blue);font-size:13px}
.mon ul{margin:0;padding:0;list-style:none} .mon li{padding:5px 0 5px 8px;border-left:3px solid var(--blue);margin:4px 0;font-size:12px}
.mon li.cert{border-left-color:#d08a1a} .dd{font-weight:600;font-variant-numeric:tabular-nums}
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:6px;margin:6px 0 4px}
table.grid{border-collapse:collapse;width:100%;font-size:12px}
.grid th{background:var(--blue);color:#fff;text-align:left;padding:7px 8px;white-space:nowrap;cursor:pointer;user-select:none}
.grid th .ar{font-size:9px;margin-left:4px} .grid td{border-top:1px solid var(--line);padding:5px 8px;vertical-align:top}
.grid tr:nth-child(even) td{background:var(--row)} .nw{white-space:nowrap}
.grid td a{color:var(--blue)}
.pill{display:inline-block;padding:1px 8px;border-radius:999px;font-size:11.5px;font-weight:600;white-space:nowrap}
.pill.ok{background:var(--ok-bg);color:var(--ok)} .pill.warn{background:var(--warn-bg);color:var(--warn)} .pill.soon{background:var(--soon-bg);color:var(--soon)}
.pill.bad{background:var(--bad-bg);color:var(--bad)} .pill.mute{background:var(--mute-bg);color:var(--mute)}
.card{border:1px solid var(--line);border-radius:8px;padding:12px 16px;margin:12px 0;break-inside:avoid}
.ch{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:8px} .ch h3{margin:0;color:var(--blue);font-size:15px}
.tag{display:inline-block;background:var(--blue-lt);color:var(--blue);border-radius:4px;padding:1px 7px;font-size:11.5px;margin:2px 0 2px 4px}
dl.kv{display:grid;grid-template-columns:200px 1fr;gap:3px 14px;margin:10px 0} dl.kv dt{color:var(--muted)} dl.kv dd{margin:0}
ul.method{padding-left:18px} ul.method li{margin:3px 0}
.hidden{display:none!important} mark{background:#fff3a3;padding:0}
footer{color:var(--muted);font-size:11px;padding:8px 32px 24px;border-top:1px solid var(--line)}
@page{size:A4 landscape;margin:12mm}
@media print{.noprint{display:none!important}body{font-size:11px}.cover{padding:14px 18px}main{padding:0 6px;max-width:none}
section.pb{break-before:page}.tw{overflow:visible;border:none}.grid th{background:var(--blue)!important}thead{display:table-header-group}tr{break-inside:avoid}.card{break-inside:avoid}}
'@

$script:ReportJs = @'
(function(){"use strict";
var S={roles:[],soon:false,q:""};
function $(s,r){return Array.prototype.slice.call((r||document).querySelectorAll(s));}
function rolesOk(el){if(!S.roles.length)return true;var a=el.getAttribute("data-roles");if(a===null)return true;
 var rs=a.split("|");for(var i=0;i<rs.length;i++)if(S.roles.indexOf(rs[i])>=0)return true;return false;}
function soonOk(el){if(!S.soon)return true;var s=el.getAttribute("data-soon");return s===null||s==="1";}
function textOk(el){if(!S.q)return true;return el.textContent.toLowerCase().indexOf(S.q)>=0;}
function apply(){
 $("[data-roles],[data-soon]").forEach(function(el){if(el.closest(".fbar"))return;
  var show=rolesOk(el)&&soonOk(el)&&(el.tagName==="TR"||el.tagName==="LI"||el.tagName==="ARTICLE"?textOk(el):true);
  el.classList.toggle("hidden",!show);});
 $(".mon").forEach(function(m){var any=$("li",m).some(function(li){return !li.classList.contains("hidden");});m.classList.toggle("hidden",(S.roles.length||S.soon||S.q)&&!any);});
 $(".chip[data-role]").forEach(function(b){var r=b.getAttribute("data-role");b.setAttribute("aria-pressed",String(r===""?S.roles.length===0:S.roles.indexOf(r)>=0));});
 document.getElementById("soon").setAttribute("aria-pressed",String(S.soon));
 var h=[];if(S.roles.length)h.push("roles="+S.roles.map(encodeURIComponent).join(","));if(S.soon)h.push("soon=1");
 try{history.replaceState(null,"",h.length?"#"+h.join("&"):location.pathname+location.search);}catch(e){}}
$(".chip[data-role]").forEach(function(b){b.addEventListener("click",function(e){var g=b.getAttribute("data-role");
 if(g===""){S.roles=[];}else{var i=S.roles.indexOf(g);if(e.ctrlKey||e.metaKey||e.shiftKey){if(i>=0)S.roles.splice(i,1);else S.roles.push(g);}else{S.roles=(S.roles.length===1&&i===0)?[]:[g];}}
 apply();});});
document.getElementById("soon").addEventListener("click",function(){S.soon=!S.soon;apply();});
var q=document.getElementById("q"),t;q.addEventListener("input",function(){clearTimeout(t);t=setTimeout(function(){S.q=q.value.trim().toLowerCase();apply();},180);});
document.getElementById("reset").addEventListener("click",function(){S={roles:[],soon:false,q:""};q.value="";apply();});
document.getElementById("print").addEventListener("click",function(){window.print();});
$("table.grid").forEach(function(tb){$("th",tb).forEach(function(th,ci){th.title="Sort";th.addEventListener("click",function(){
 var body=tb.tBodies[0],rows=Array.prototype.slice.call(body.rows),dir=th.getAttribute("data-dir")==="1"?-1:1;
 $("th",tb).forEach(function(x){x.removeAttribute("data-dir");var a=x.querySelector(".ar");if(a)a.remove();});
 th.setAttribute("data-dir",dir===1?"1":"-1");var ar=document.createElement("span");ar.className="ar";ar.textContent=dir===1?"\u25B2":"\u25BC";th.appendChild(ar);
 function key(r){var c=r.cells[ci];if(!c)return"";var s=c.getAttribute("data-sort");return s!==null?s:c.textContent.trim();}
 rows.sort(function(a,b){var x=key(a),y=key(b);if(x===""&&y!=="")return 1;if(y===""&&x!=="")return -1;
  if(/^-?\d+(\.\d+)?$/.test(x)&&/^-?\d+(\.\d+)?$/.test(y))return dir*(parseFloat(x)-parseFloat(y));
  return dir*x.localeCompare(y,undefined,{numeric:true,sensitivity:"base"});});
 rows.forEach(function(r){body.appendChild(r);});});});});
(function(){var h=location.hash.replace(/^#/,"");if(!h)return;h.split("&").forEach(function(p){var kv=p.split("=");
 if(kv[0]==="roles"&&kv[1])S.roles=kv[1].split(",").map(decodeURIComponent);if(kv[0]==="soon")S.soon=kv[1]==="1";});})();
apply();
})();
'@

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
        # Only the temporary browser profile this function created
        if ($profileDir -like (Join-Path $env:TEMP 'ServerWizard_pdf_*')) { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue }
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
        Set-Status "AD query failed (see log)." ([System.Drawing.Color]::Red)
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

    $back = if ($isSel) { $script:MerlinBlueLt } else { [System.Drawing.Color]::White }
    $backBrush = New-Object System.Drawing.SolidBrush ($back)
    $g.FillRectangle($backBrush, $rect)
    $backBrush.Dispose()

    $textBrush = New-Object System.Drawing.SolidBrush ($(if ($isSel) { $script:MerlinBlue } else { [System.Drawing.Color]::Black }))
    $font = New-Object System.Drawing.Font($script:FontName, 9, $(if ($isSel) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    $g.DrawString($tabs.TabPages[$e.Index].Text, $font, $textBrush,
        ([single]($rect.X + 4)), ([single]($rect.Y + 4)))
    $textBrush.Dispose(); $font.Dispose()

    # x button
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
        if ($xRect.Contains($e.Location)) {
            $tabs.TabPages.RemoveAt($i)
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
    catch { Set-Status "Scan monitor error: $_" ([System.Drawing.Color]::Red) }
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
function Show-ExportDialog {
    if ($script:Results.Keys.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No inventory yet - run a scan first.", "Export Report", "OK", "Information") | Out-Null
        return $null
    }
    $allKeys  = @($script:Results.Keys)
    $checked  = @(Get-AllLeafNodes | Where-Object { $_.Checked } | ForEach-Object { Get-LeafName $_ } |
                  Where-Object { $script:Results.ContainsKey($_) } | Sort-Object -Unique)
    $counts = [ordered]@{}
    foreach ($g in $script:GroupOrder) { $counts[$g] = 0 }
    foreach ($k in $allKeys) { foreach ($g in @(Get-EffectiveGroups $k $script:Results[$k])) { if (-not $counts.Contains($g)) { $counts[$g] = 0 }; $counts[$g]++ } }
    $activeTab = $tabs.SelectedTab
    $tabOk = ($activeTab -and $activeTab.Text -notin 'Scan Progress', 'Reports')

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Export Report'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(470, 580)
    $dlg.Font = $form.Font
    $dlg.BackColor = [System.Drawing.Color]::White
    $dlg.ShowInTaskbar = $false

    $lblRoles = New-Object System.Windows.Forms.Label
    $lblRoles.Text = 'Roles to include'; $lblRoles.ForeColor = $script:MerlinBlue
    $lblRoles.Font = New-Object System.Drawing.Font($script:FontName, 10, [System.Drawing.FontStyle]::Bold)
    $lblRoles.Location = New-Object System.Drawing.Point(14, 12); $lblRoles.AutoSize = $true

    $lnkAll = New-Object System.Windows.Forms.LinkLabel
    $lnkAll.Text = 'All'; $lnkAll.AutoSize = $true; $lnkAll.Location = New-Object System.Drawing.Point(370, 15)
    $lnkNone = New-Object System.Windows.Forms.LinkLabel
    $lnkNone.Text = 'None'; $lnkNone.AutoSize = $true; $lnkNone.Location = New-Object System.Drawing.Point(410, 15)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.CheckOnClick = $true
    $clb.Location = New-Object System.Drawing.Point(14, 38); $clb.Size = New-Object System.Drawing.Size(442, 214)
    $roleOf = @{}
    foreach ($g in $counts.Keys) {
        if ($counts[$g] -eq 0) { continue }
        $text = "$g  ($($counts[$g]))"
        $roleOf[$text] = $g
        [void]$clb.Items.Add($text, $true)
    }
    $lnkAll.Add_LinkClicked({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } })
    $lnkNone.Add_LinkClicked({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } })

    $grpSrv = New-Object System.Windows.Forms.GroupBox
    $grpSrv.Text = 'Servers'; $grpSrv.ForeColor = $script:MerlinBlue
    $grpSrv.Location = New-Object System.Drawing.Point(14, 262); $grpSrv.Size = New-Object System.Drawing.Size(442, 76)
    $rbChecked = New-Object System.Windows.Forms.RadioButton
    $rbChecked.Text = "Servers checked in the list ($($checked.Count))"; $rbChecked.ForeColor = [System.Drawing.Color]::Black
    $rbChecked.Location = New-Object System.Drawing.Point(12, 22); $rbChecked.AutoSize = $true
    $rbAll = New-Object System.Windows.Forms.RadioButton
    $rbAll.Text = "All scanned servers ($($allKeys.Count))"; $rbAll.ForeColor = [System.Drawing.Color]::Black
    $rbAll.Location = New-Object System.Drawing.Point(12, 46); $rbAll.AutoSize = $true
    if ($checked.Count -gt 0) { $rbChecked.Checked = $true } else { $rbChecked.Enabled = $false; $rbAll.Checked = $true }
    $grpSrv.Controls.AddRange(@($rbChecked, $rbAll))

    $grpFmt = New-Object System.Windows.Forms.GroupBox
    $grpFmt.Text = 'Format'; $grpFmt.ForeColor = $script:MerlinBlue
    $grpFmt.Location = New-Object System.Drawing.Point(14, 346); $grpFmt.Size = New-Object System.Drawing.Size(442, 124)
    $rbHtml = New-Object System.Windows.Forms.RadioButton
    $rbHtml.Text = 'HTML (opens in the browser; filters, search, Print / PDF button)'; $rbHtml.ForeColor = [System.Drawing.Color]::Black
    $rbHtml.Location = New-Object System.Drawing.Point(12, 22); $rbHtml.AutoSize = $true; $rbHtml.Checked = $true
    $rbPdf = New-Object System.Windows.Forms.RadioButton
    $rbPdf.Text = 'PDF (A4 landscape, printed with Edge / Chrome)'; $rbPdf.ForeColor = [System.Drawing.Color]::Black
    $rbPdf.Location = New-Object System.Drawing.Point(12, 46); $rbPdf.AutoSize = $true
    $rbBoth = New-Object System.Windows.Forms.RadioButton
    $rbBoth.Text = 'HTML + PDF (same name, side by side)'; $rbBoth.ForeColor = [System.Drawing.Color]::Black
    $rbBoth.Location = New-Object System.Drawing.Point(12, 70); $rbBoth.AutoSize = $true
    $rbTab = New-Object System.Windows.Forms.RadioButton
    $rbTab.Text = if ($tabOk) { "Active tab only (CSV): $($activeTab.Text)" } else { 'Active tab only (CSV) - open a server or search tab first' }
    $rbTab.ForeColor = [System.Drawing.Color]::Black
    $rbTab.Location = New-Object System.Drawing.Point(12, 94); $rbTab.AutoSize = $true; $rbTab.Enabled = $tabOk
    $grpFmt.Controls.AddRange(@($rbHtml, $rbPdf, $rbBoth, $rbTab))

    $lblLang = New-Object System.Windows.Forms.Label
    $lblLang.Text = 'Report language'; $lblLang.ForeColor = $script:MerlinBlue; $lblLang.AutoSize = $true
    $lblLang.Location = New-Object System.Drawing.Point(16, 486)
    $cmbLang = New-Object System.Windows.Forms.ComboBox
    $cmbLang.DropDownStyle = 'DropDownList'
    $cmbLang.Location = New-Object System.Drawing.Point(140, 482); $cmbLang.Size = New-Object System.Drawing.Size(160, 24)
    [void]$cmbLang.Items.Add("T$([char]0x00FC)rk$([char]0x00E7)e"); [void]$cmbLang.Items.Add('English')
    $cmbLang.SelectedIndex = if ($script:ReportLangDefault -eq 'en') { 1 } else { 0 }

    $toggle = { $clb.Enabled = -not $rbTab.Checked; $grpSrv.Enabled = -not $rbTab.Checked; $cmbLang.Enabled = -not $rbTab.Checked }
    $rbTab.Add_CheckedChanged($toggle)

    $btnView = New-Object System.Windows.Forms.Button
    $btnView.Text = 'Open in-app view'; $btnView.FlatStyle = 'Flat'; $btnView.ForeColor = $script:MerlinBlue
    $btnView.Location = New-Object System.Drawing.Point(14, 532); $btnView.Size = New-Object System.Drawing.Size(140, 32)
    $btnView.DialogResult = [System.Windows.Forms.DialogResult]::Retry
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.FlatStyle = 'Flat'
    $btnCancel.Location = New-Object System.Drawing.Point(254, 532); $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Export'; $btnOk.FlatStyle = 'Flat'
    $btnOk.BackColor = $script:MerlinYellow; $btnOk.ForeColor = $script:MerlinBlue
    $btnOk.Font = New-Object System.Drawing.Font($script:FontName, 9, [System.Drawing.FontStyle]::Bold)
    $btnOk.Location = New-Object System.Drawing.Point(354, 532); $btnOk.Size = New-Object System.Drawing.Size(102, 32)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnCancel

    $dlg.Controls.AddRange(@($lblRoles, $lnkAll, $lnkNone, $clb, $grpSrv, $grpFmt, $lblLang, $cmbLang, $btnView, $btnCancel, $btnOk))

    try {
        $res = $dlg.ShowDialog($form)
        if ($res -eq [System.Windows.Forms.DialogResult]::Retry) { return @{ Action = 'View' } }
        if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        if ($rbTab.Checked) { return @{ Action = 'Tab' } }
        $roles = @(foreach ($item in $clb.CheckedItems) { $roleOf["$item"] })
        if ($roles.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Select at least one role.", "Export Report", "OK", "Information") | Out-Null
            return $null
        }
        # Every role ticked = no role filter (also keeps servers with no group)
        if ($roles.Count -eq $clb.Items.Count) { $roles = @() }
        $script:ReportLangDefault = if ($cmbLang.SelectedIndex -eq 0) { 'tr' } else { 'en' }
        return @{
            Action     = 'Report'
            Format     = if ($rbPdf.Checked) { 'Pdf' } elseif ($rbBoth.Checked) { 'Both' } else { 'Html' }
            Language   = if ($cmbLang.SelectedIndex -eq 0) { 'tr' } else { 'en' }
            Roles      = [string[]]$roles
            AllServers = [bool]$rbAll.Checked
        }
    }
    finally { $dlg.Dispose() }
}

$btnExport.Add_Click({
    try {
        Write-Log "Export Report clicked"
        $choice = Show-ExportDialog
        if (-not $choice) { return }
        switch ($choice.Action) {
            'View'   { Open-ReportsTab }
            'Tab'    { Export-ActiveTabCsv }
            'Report' {
                Write-Log "Export: $($choice.Format) [$($choice.Language)], roles: $(if ($choice.Roles.Count) { $choice.Roles -join ', ' } else { 'all' }), all servers: $($choice.AllServers)"
                Invoke-RoleReport -Format $choice.Format -Roles $choice.Roles -AllServers:$choice.AllServers -Language $choice.Language
            }
        }
    }
    catch {
        Write-Log "EXPORT FAILED: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        Set-Status "Export Report failed: $($_.Exception.Message) (see log)" ([System.Drawing.Color]::Red)
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
    $btnExport.Enabled = $true
    $cacheDate = (Get-Item $script:CacheFile).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    Set-Status "Loaded $($script:Results.Keys.Count) servers from cache ($cacheDate). Click a server to open it in a tab." $script:OkGreen
}
else {
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
