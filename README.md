# Server Wizard

A read-only Windows Server inventory and monitoring tool with a WinForms GUI, written in a single PowerShell script.

Scan every Windows Server in your Active Directory domain over WinRM and browse the results from one screen: roles, resources, disks, IIS sites, SSL certificates, SQL instances, installed software and more. No agents, no credentials stored, no changes made to any server.

## Features

- **AD-based discovery**: pulls only real, enabled Windows Server objects (cluster virtual objects filtered out), with optional parallel ping check
- **Role grouping (multi-role)**: every installed Windows Server role and role service is read during the scan and servers are classified automatically (Domain Controllers, SQL / Database, IIS / Web, DNS, DHCP, Certificate Services, ADFS, RDS, Hyper-V, File Services / DFS, Print, WSUS, WDS, NPS / Remote Access, Failover Cluster, Exchange, 3rd Party). A server with several roles appears in **every** matching list; checking it in one list checks all its copies. Right-click pins a server to a single group (persisted)
- **Per-server tabs**: click a server to open its full inventory in its own closable tab
- **Search**: type an IP, website, DNS name, port, software or user name and instantly see which server it lives on. Results open with a summary of how many matches were found per category (SSL bindings, IIS websites, DNS names, installed software, services, ports…), then list them grouped by category and server, with matches highlighted. Click a category in the summary to filter to it
- **Collected data**: OS + version, install/last restart dates, IPs, CPU/RAM, disks with free-space warnings, roles & features, automatic services, last RDP logons, IIS sites + DNS names + modules + SSL bindings (with certificate dates), listening ports, SQL instance details (edition/version), database services, Microsoft and 3rd-party software with versions, running 3rd-party services
- **Overview (home tab, v1.7)**: opens with the app. Top line: servers, critical / warning counts, OS past end of support, IIS and database counts. Then a **Risks** list (critical first) and a compact **Server profiles** grid (roles, OS, support status, end of support, IIS, databases, next certificate expiry, lowest free disk, uptime). Double-click a row to open the server
  - *Critical*: OS or database past end of support (no paid ESU), certificate bound to IIS expired or expiring within 14 days, a disk below 10% free, server unreachable at the last scan
  - *Warning*: OS or database in paid ESU or ending within 12 months, IIS certificate expiring within 60 days, a disk below 20% free
- **Report Builder** (v1.7, `Report Builder` button): you choose everything, nothing is pre-selected and a group never adds a filter on its own
  1. *Groups*: one or more role groups (IIS / Web, SQL / Database, ...)
  2. *Columns*: tick exactly the fields you need (e.g. IIS servers + *Lowest free space* + *Disks*), grouped as General, OS lifecycle, Hardware, Disks, IIS, Database, Certificates, Roles and software
  3. *Conditions* (optional): disk below 20% / 10%, OS or database past end of support, OS ending within 12 months, certificate in use expiring within 30 / 90 days, has IIS / database, not restarted for 30+ days; match all or any
  - Servers checked in the list or all scanned; one table per group or one table with a Groups column; HTML, PDF (A4 landscape via the local Edge / Chrome) or both; your last choices are remembered
  - The report shows only the ticked columns plus generation time, user, groups, columns and conditions. *Export the active tab as CSV* is still available from the same dialog
- **Dark theme and compact layout** (v1.7): dark window, title bar, tabs and grids; one line per field in server tabs
- **Role classification evidence**: every placement shows why (Windows role, database engine with its instance, or service), in the server tab and in the report's *Role Classification* section. Database packages without a service (client tools, drivers) are listed but do not make a server a database server
- **Role details in server tabs and the Report Builder**:
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
- PDF export needs Microsoft Edge or Google Chrome on the machine running Server Wizard (HTML export does not)
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
