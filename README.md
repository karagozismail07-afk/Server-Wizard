# Server Wizard

A read-only Windows Server inventory and monitoring tool with a WinForms GUI, written in a single PowerShell script.

Scan every Windows Server in your Active Directory domain over WinRM and browse the results from one screen: roles, resources, disks, IIS sites, SSL certificates, SQL instances, installed software and more. No agents, no credentials stored, no changes made to any server.

## Features

- **AD-based discovery**: pulls only real, enabled Windows Server objects (cluster virtual objects filtered out), with optional parallel ping check
- **Role grouping (multi-role)**: every installed Windows Server role and role service is read during the scan and servers are classified automatically (Domain Controllers, SQL / Database, IIS / Web, DNS, DHCP, Certificate Services, ADFS, RDS, Hyper-V, File Services / DFS, Print, WSUS, WDS, NPS / Remote Access, Failover Cluster, Exchange, 3rd Party). A server with several roles appears in **every** matching list; checking it in one list checks all its copies. Right-click pins a server to a single group (persisted)
- **Per-server tabs**: click a server to open its full inventory in its own closable tab
- **Categorised search**: type an IP, website, DNS name, port, software or user name and instantly see which server it lives on. Results open with a summary of how many matches were found per category (SSL bindings, IIS websites, DNS names, installed software, services, ports…), then list them grouped by category and server, with matches highlighted. Narrow a search to a single category from the dropdown, or click a category in the summary to filter to it
- **Collected data**: OS + version, install/last restart dates, IPs, CPU/RAM, disks with free-space warnings, roles & features, automatic services, last RDP logons, IIS sites + DNS names + modules + SSL bindings (with certificate dates), listening ports, SQL instance details (edition/version), database services, Microsoft and 3rd-party software with versions, running 3rd-party services
- **Role-based reporting** (`Export Report` opens one dialog):
  - choose the **roles** (e.g. only IIS, only SQL, or IIS + SQL) and the **servers** (checked in the list or all scanned) that go into the report
  - **Interactive HTML report** (single offline file, no external resources): role chips (click = only that role, Ctrl/Shift+click = combine), "Problems only" filter (EOL / extended support / expired or expiring certificates), free-text search with highlighting, sortable columns, per-section "Download view (CSV)", KPIs that follow the filter, and a bookmarkable view in the address bar (`report.html#roles=IIS%20%2F%20Web&problems=1`)
  - **CSV per role / section** (semicolon-delimited, UTF-8 BOM, formula-injection safe) into a folder
  - **Active tab only (CSV)**: the v1.4 per-server / search-result export
  - **Open in-app view**: a `Reports` tab with a section selector, a sortable, colour-coded grid (double-click a row to open the server) and export / refresh buttons
- **Role classification evidence**: every placement shows why (Windows role, database engine with its instance, or service), in the server tab and in the report's *Role Classification* section. Database packages without a service (client tools, drivers) are listed but do not make a server a database server
- **Role details in reports and server tabs**:
  - *Operating system*: version, build, install date, Microsoft Lifecycle policy, mainstream end, extended end (EOL), paid ESU end, days to EOL, status
  - *Databases*: product (Microsoft SQL Server, MariaDB, MySQL, PostgreSQL, Firebird, MongoDB, Oracle, Redis), version, edition / instance, service pack, install date, service state, vendor support end / EOL
  - *IIS*: version (InetStp), approximate install date, sites, lifecycle (IIS follows the Windows lifecycle)
  - *SSL certificates*: every certificate in `LocalMachine\My` and `WebHosting`, expiry date, days left, status (expired / 30 / 60 / 90 days), issuer, SANs and the IIS bindings that use it
  - *Windows Server roles & features*: every installed role, role service and feature with display names
- **Official lifecycle sources only**: support / EOL dates are fetched at every scan, report and app start from the vendors' own pages: [Microsoft Lifecycle](https://learn.microsoft.com/lifecycle/products/) (Windows Server, SQL Server, IIS), [MariaDB Foundation REST API](https://downloads.mariadb.org/rest-api/mariadb/), [PostgreSQL versioning policy](https://www.postgresql.org/support/versioning/), [MySQL EOL notices](https://www.mysql.com/support/eol-notice.html) and Firebird's [discontinued versions](https://www.firebirdsql.org/en/discontinued-versions/) / [roadmap](https://www.firebirdsql.org/en/roadmap/). If a site is unreachable the last official copy is used and marked as an offline copy with its retrieval date
- **Caching**: results are cached per user (ACL-restricted to the owner) so the app opens instantly with the last inventory; last scan time shown in the status bar
- **Logging**: every step and every error is written to a per-user log file (`Open Log` button in the app)

## Security model

- **Read-only by design**: the remote scan block contains zero write operations; sessions are opened with `-NoMachineProfile` so not even a user profile is created on targets
- **No credentials asked or stored**: connections use the Kerberos identity of whoever runs the app — everyone sees exactly what their own Windows account is allowed to see
- **Internet access limited to official lifecycle pages**: inventory traffic stays inside your network (AD + WinRM). Only the machine running the app makes HTTPS GET requests, to an allow-list of vendor hosts (`learn.microsoft.com`, `downloads.mariadb.org`, `www.postgresql.org`, `www.mysql.com`, `www.firebirdsql.org`), redirects to other hosts are refused, and no inventory data is sent. The system proxy is used with the current Windows credentials
- **Private caches**: each user's scan results and logs are ACL-restricted to that user

## Requirements

- Windows with PowerShell 5.1
- RSAT ActiveDirectory module on the machine running the app (for AD discovery)
- WinRM enabled on target servers (`Enable-PSRemoting -Force`)
- Local admin rights on targets recommended (event log / IIS / registry details)
- HTTPS access from the machine running the app to the official lifecycle hosts above (optional; without it support / EOL dates show as not resolved)
- Results cached by v1.4 still open; rescan once with v1.5 to collect role, database, certificate and lifecycle details

## Getting started

Run directly:

```powershell
powershell.exe -ExecutionPolicy Bypass -STA -File .\ServerWizard.ps1
```

Or install (builds a standalone exe via ps2exe, generates the icon, creates shortcuts):

```powershell
# current user only
powershell.exe -ExecutionPolicy Bypass -File .\Install-ServerWizard.ps1

# shortcuts for every account on the machine (elevated prompt required)
powershell.exe -ExecutionPolicy Bypass -File .\Install-ServerWizard.ps1 -AllUsers

# uninstall
powershell.exe -ExecutionPolicy Bypass -File .\Install-ServerWizard.ps1 -Uninstall
```

Inside the app: **Load from AD** → select servers → **Start Scan** → click any server to inspect it, or use the search bar.

Data locations: if a `D:` drive exists, cache/logs go to `D:\Server Wizard\Cache\<username>\`; otherwise `%LOCALAPPDATA%\ServerWizard`.

## License

MIT
