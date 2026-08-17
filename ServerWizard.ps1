<#
 Server Wizard - read-only Windows Server inventory tool (WinForms GUI)
 See README.md for usage, requirements and the security model.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
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
$script:AppVersion = '1.4'

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

    try {
        $result.Roles = ((Get-WindowsFeature -ErrorAction Stop | Where-Object Installed).Name -join '; ')
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
    $msProducts = @(); $tpProducts = @()
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

    [PSCustomObject]$result
}

# --- Field definitions (drive detail tabs + CSV export + search) -----------
$script:FieldDefs = @(
    @{ Name='OperatingSystem';    Section='General';             Label='Operating System';            Sep=$null  },
    @{ Name='Domain';             Section='General';             Label='Domain';                      Sep=$null  },
    @{ Name='InstallDate';        Section='General';             Label='OS Install Date';             Sep=$null  },
    @{ Name='LastRestartDate';    Section='General';             Label='Last Restart Date';           Sep=$null  },
    @{ Name='IPAddresses';        Section='Network';             Label='IP Addresses';                Sep='; '   },
    @{ Name='ListeningPorts';     Section='Network';             Label='Listening TCP Ports';         Sep=', '   },
    @{ Name='CPU';                Section='Hardware';            Label='CPU';                         Sep=$null  },
    @{ Name='LogicalCores';       Section='Hardware';            Label='Logical Cores';               Sep=$null  },
    @{ Name='TotalRAM_GB';        Section='Hardware';            Label='Total RAM (GB)';              Sep=$null  },
    @{ Name='Disks';              Section='Disks';               Label='Disks';                       Sep=' | '  },
    @{ Name='Roles';              Section='Roles & Features';    Label='Installed Roles';             Sep='; '   },
    @{ Name='AutomaticServices';  Section='Windows Services';    Label='Automatic Services';          Sep='; '   },
    @{ Name='LastRDPLogons';      Section='RDP Logons';          Label='Last RDP Logons';             Sep=' | '  },
    @{ Name='Websites';           Section='IIS / Web';           Label='IIS Websites';                Sep=' || ' },
    @{ Name='SiteDNSNames';       Section='IIS / Web';           Label='Site DNS Names';              Sep='; '   },
    @{ Name='IISModules';         Section='IIS / Web';           Label='IIS Modules (extensions)';    Sep='; '   },
    @{ Name='SSLBindings';        Section='IIS / Web';           Label='SSL Bindings (newest first)'; Sep=' ;; ' },
    @{ Name='SQLInstanceDetails'; Section='Database';            Label='SQL Instances (detailed)';    Sep=' | '  },
    @{ Name='DatabaseServices';   Section='Database';            Label='Database Services';           Sep='; '   },
    @{ Name='MicrosoftProducts';  Section='Microsoft Products';  Label='Microsoft Products & Versions'; Sep='; ' },
    @{ Name='ThirdPartyProducts'; Section='3rd Party Products';  Label='3rd Party Software & Versions'; Sep='; ' },
    @{ Name='ThirdPartyServices'; Section='3rd Party Services';  Label='Running 3rd Party Services';    Sep='; ' }
)

$script:RoleGroups = @('Domain Controllers', 'SQL / Database', 'IIS / Web', 'Other Microsoft Roles', '3rd Party', 'Other')
$script:GroupOrder = $script:RoleGroups + @('Not Scanned / Unreachable')

function Get-RoleGroup($r) {
    $roles = "$($r.Roles)"
    if ($roles -match 'AD-Domain-Services') { return 'Domain Controllers' }
    $sql = "$($r.SQLInstanceDetails)"
    if (($sql -and $sql -notin 'None', 'N/A') -or "$($r.DatabaseServices)" -match 'SQL Server \(') { return 'SQL / Database' }
    if ($roles -match 'Web-Server' -or "$($r.Websites)" -notmatch '^(N/A|No sites)') { return 'IIS / Web' }
    if ("$($r.ThirdPartyServices)" -match 'MSExchange|Microsoft Exchange' -or
        $roles -match 'DHCP|DNS|Hyper-V|Remote-Desktop-Services|RDS-|Print-Services|WDS|UpdateServices|FS-DFS|ADCS|ADFS|NPAS') {
        return 'Other Microsoft Roles'
    }
    if ("$($r.ThirdPartyServices)" -and "$($r.ThirdPartyServices)" -notin 'None', 'N/A') { return '3rd Party' }
    return 'Other'
}

# --- Global state ----------------------------------------------------------
$script:ScanJob      = $null
$script:Results      = @{}    # UPPERCASE name -> result
$script:Overrides    = @{}    # UPPERCASE name -> manually chosen group
$script:TreeUpdating = $false
$script:CtxTarget    = $null
$script:AllCategories   = 'All categories'
$script:LastSearchQuery = ''
$script:LastSearchRows  = @()

function Get-EffectiveGroup([string]$key, $r) {
    if ($script:Overrides.ContainsKey($key)) { return $script:Overrides[$key] }
    if ($r) { return Get-RoleGroup $r }
    return 'Not Scanned / Unreachable'
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
$form.Add_Shown({ $pnlHeader.Invalidate(); $form.Refresh() })
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

function Update-ServerCount {
    $leaves  = Get-AllLeafNodes
    $checked = @($leaves | Where-Object { $_.Checked })
    $lblCount.Text = "$($leaves.Count) servers ($($checked.Count) selected)  |  Right-click = change group"
}

function Get-LeafName([System.Windows.Forms.TreeNode]$node) {
    return ("$($node.Text)" -replace ' \*$', '').ToUpper()
}

function Rebuild-Tree([hashtable]$groups) {
    $script:TreeUpdating = $true
    $tree.BeginUpdate()
    $tree.Nodes.Clear()

    foreach ($gName in $script:GroupOrder) {
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
        $box.AppendText("Role group: $grpTxt`n`n")

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
        $gName = Get-EffectiveGroup $key $script:Results[$key]
        if (-not $groups.ContainsKey($gName)) { $groups[$gName] = @() }
        $groups[$gName] += @{ Name = $key; CheckedState = $known[$key] }
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
            $gName =
                if ($script:Overrides.ContainsKey($key)) { $script:Overrides[$key] }
                elseif ($res) { Get-RoleGroup $res }
                elseif ($c.PrimaryGroupID -eq 516) { 'Domain Controllers' }
                else { 'Not Scanned / Unreachable' }
            if (-not $groups.ContainsKey($gName)) { $groups[$gName] = @() }
            $groups[$gName] += @{ Name = $key; CheckedState = $true }
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
    $targets = @(Get-AllLeafNodes | Where-Object { $_.Checked } | ForEach-Object { Get-LeafName $_ })
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

# Export ONLY the server open in the active tab.
# Semicolon delimiter + UTF8 BOM so Turkish-locale Excel opens it in
# proper columns (comma-delimited CSV shows as one column there).
$btnExport.Add_Click({
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
})

$form.Add_FormClosing({
    $timer.Stop()
    if ($script:ScanJob) {
        Stop-Job -Job $script:ScanJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:ScanJob -Force -ErrorAction SilentlyContinue
    }
})

# --- Startup: load cache, build groups from it -----------------------------
if (Load-Cache) {
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

[void]$form.ShowDialog()
