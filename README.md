# PowerShell Scripts Management

Repository for managing reusable PowerShell functions, standalone applications,
installation scripts, and related modules.

## Root Structure
- `Applications/` - Standalone PowerShell applications (for example 3CX tooling and web admin utilities).
- `Applications/PSM/` - Powershell Scripts Management (PSM) itself: the maintenance applications that keep every device's `C:\SCRIPTS` current, with the DFS share (`DfsRoot`) as the sync point.
  - `FrontendScriptsSync/` - the PSM Frontend, on every device: `Sync-ScriptsFromDfs.ps1` (scheduled task `\PSM\SyncScriptsFromDfs`, SYSTEM, every `SyncIntervalMinutes`) pulls `Functions`, `Data`, `Modules` and the applications the device has inventory records for. Only validly signed scripts are pulled; nothing outside `C:\SCRIPTS` is written. Installed by `Install-FrontendScriptsSync.ps1`.
  - `BackendScriptsSync/` - the PSM Backend, on the inventory server only: `Update-InventoryIndex.ps1` (task `\PSM\UpdateInventoryIndex`) and, later, the log merge. Installed by `Install-BackendScriptsSync.ps1`.
- `Data/` - Shared data and settings files.
- `Docs/` - Documentation pages, for example `Docs/PSM_Process.html` (how scripts move from the development computer through DFS to the servers). Stays on the development computer; not published or copied to servers.
- `Functions/` - Reusable function scripts (Verb-Noun naming).
- `Installs/` - Deploying applications to servers from the admin workstation.
  - `Installs/SetupApplications.ps1` - window to pick applications, check/fix their modules on the servers, copy their files and list the install steps.
  - `Installs/Data/` - one JSON manifest per application: files and folders to copy, servers, required modules (and where their data lives), install steps and run-as account, `DependsOn` (for example `Installs/Data/PoshAcme.json`).
  - `Installs/Data/Base.json` - always copied first with every application: the root folders (`C:\SCRIPTS`, `Applications`, `Applications\PSM`, `Data`, `Functions`, `Logs`), the common functions (`Functions\*.ps1`, except the deployment tools `Copy-FilesToServer`, `Install-ServerModule` and `Set-ScriptSignature`) and, through `DependsOn`, the PSM Frontend (`PSMFrontendScriptsSync`). So no application can be installed without the Frontend, whose install step is listed first; the Frontend can be installed on its own by picking `PSMFrontendScriptsSync`.
  - `Installs/` itself stays on the setup machine. Settings an application needs on the server live in the application's own `Data` folder (for example `Applications/OpenSource/PoshAcme/Data/PoshAcme.json`, with its `Version`), copied with the application; the manifest points to it with `AppData`, and the setup window compares it with each server's copy.
  - Files are compared by SHA256: the workstation copy is the source of truth, so any file that differs on the server is replaced; identical files are left alone. Unsigned scripts are not copied.
  - Install scripts that run on the server stay with their application under `Applications/`.
- `Data/Settings/Scripts.json` - `Transports`: how devices reach the scripts (`Dfs` = `\\generationsgaither.com\all_scripts\scripts`, plus `Sftp` and `Ftp`, each with `Enabled` and `Priority`; read with `Functions/Get-ScriptsTransport.ps1`; credentials are only named there, never stored), the inventory server (`InventoryServer`, the services server), intervals and the `SEC-Scripts.*` group names. Copied to every device by Base; `Scripts.<COMPUTERNAME>.json` overrides values per device (for example DFS disabled for TNC servers); overrides merge at every depth, so a device lists only what differs. Edit both in SetupApplications with **Distribution...** (`Installs/Show-DistributionSettings.ps1`). The PSM Frontend moves files over DFS only for now; SFTP/FTP can be configured but are not used yet.
- Inventory: installers and the setup window call `Functions/Update-ApplicationInventory.ps1`, which writes `update.<DEVICE>.<App>.json` (locally in `C:\SCRIPTS\Applications\Data` and to `<DFS>\Applications\Data`). `Applications/PSM/BackendScriptsSync/Update-InventoryIndex.ps1`, scheduled on the inventory server by `Install-BackendScriptsSync.ps1`, merges them into `<DFS>\Applications\Data\Inventory.json`.
- `Libraries/` - Supporting libraries.
- `Logs/` - Script execution logs.
- `Modules/` - PowerShell modules (for example `MikrotikRouterOSAPI`).
- `manage.ps1` - Interactive management script.

## Workspaces
- `PowershellScriptsManagement.code-workspace` - Main multi-root workspace.
- `MikrotikRouterOSAPI.code-workspace` - Module-focused workspace.

## Key Entry Points
- Management script:

```powershell
.\manage.ps1
```

- Web administration script:

```powershell
.\Applications\OpenSource\PowershellScriptManagementWebAdministration\StartPowershellScriptsWebAdministration.ps1
```

## Requirements
- Windows PowerShell 5.1+ or PowerShell 7+
- Optional modules for web administration:
  - `Pode`
  - `Pode.Web`

## Notes
- `manage.ps1` currently expects a `scripts` subfolder for interactive script discovery.
- Most reusable shared logic is in `Functions/`, with logs written under `Logs/`.
