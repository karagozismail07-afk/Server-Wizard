# Server Wizard

A read-only Windows Server inventory and monitoring tool with a WinForms GUI, written in a single PowerShell script.

Scan every Windows Server in your Active Directory domain over WinRM and browse the results from one screen: roles, resources, disks, IIS sites, SSL certificates, SQL instances, installed software and more. No agents, no credentials stored, no changes made to any server.

## Features

- **AD-based discovery**: pulls only real, enabled Windows Server objects (cluster virtual objects filtered out), with optional parallel ping check
- **Role grouping**: servers are automatically grouped as Domain Controllers > SQL / Database > IIS / Web > Other Microsoft Roles > 3rd Party, with manual override via right-click (persisted)
- **Per-server tabs**: click a server to open its full inventory in its own closable tab
- **Categorised search**: type an IP, website, DNS name, port, software or user name and instantly see which server it lives on. Results open with a summary of how many matches were found per category (SSL bindings, IIS websites, DNS names, installed software, services, ports…), then list them grouped by category and server, with matches highlighted. Narrow a search to a single category from the dropdown, or click a category in the summary to filter to it
- **Collected data**: OS + version, install/last restart dates, IPs, CPU/RAM, disks with free-space warnings, roles & features, automatic services, last RDP logons, IIS sites + DNS names + modules + SSL bindings (with certificate dates), listening ports, SQL instance details (edition/version), database services, Microsoft and 3rd-party software with versions, running 3rd-party services
- **Reporting**: export the active server's inventory, or the current search results grouped by category, as a clean long-format CSV (semicolon-delimited, Excel-friendly)
- **Caching**: results are cached per user (ACL-restricted to the owner) so the app opens instantly with the last inventory; last scan time shown in the status bar
- **Logging**: every step and every error is written to a per-user log file (`Open Log` button in the app)

## Security model

- **Read-only by design**: the remote scan block contains zero write operations; sessions are opened with `-NoMachineProfile` so not even a user profile is created on targets
- **No credentials asked or stored**: connections use the Kerberos identity of whoever runs the app — everyone sees exactly what their own Windows account is allowed to see
- **No internet access**: all traffic stays inside your network (AD + WinRM)
- **Private caches**: each user's scan results and logs are ACL-restricted to that user

## Requirements

- Windows with PowerShell 5.1
- RSAT ActiveDirectory module on the machine running the app (for AD discovery)
- WinRM enabled on target servers (`Enable-PSRemoting -Force`)
- Local admin rights on targets recommended (event log / IIS / registry details)

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
