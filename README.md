# PowerShell Scripts Management

Repository for managing reusable PowerShell functions, standalone applications,
installation scripts, and related modules.

## Root Structure
- `Applications/` - Standalone PowerShell applications (for example 3CX tooling and web admin utilities).
- `Data/` - Shared data and settings files.
- `Functions/` - Reusable function scripts (Verb-Noun naming).
- `Installations/` - Installation and configuration scripts.
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
