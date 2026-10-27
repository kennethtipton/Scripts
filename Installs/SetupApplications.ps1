<#
.SYNOPSIS
    Window to pick applications from the Installs folder and copy them to their servers/clients.
.DESCRIPTION
    Lists every manifest in C:\SCRIPTS\Installs\Data (*.json) with a check box. Checking an
    application shows, on the right, each server/client its files will be copied to:
      inventory  every server whose PSM inventory record (update.<DEVICE>.<App>.json in the DFS
                 inventory drop folder) shows the application, or an application that includes it
                 (DependsOn; shown as "via ..."). Base and the PSM Frontend: every PSM server.
                 A server without a report for StaleDays (Scripts.json) is marked stale and starts
                 unchecked.
      manifest   the manifest's Servers list (servers to install on that have no record yet)
      added      servers/clients typed in below
    Every target row has its own check box, so single servers can be left out. The inventory is
    read when the window opens and on Reload list.

    Modules: a manifest can list the PowerShell modules its application needs
      "Modules": [ { "Name": "Posh-ACME", "MinimumVersion": "4.0.0" }, { "Name": "Posh-ACME.Deploy" } ]
    or pin one exactly (also a prerelease): { "Name": "Pode.Web", "RequiredVersion": "1.0.0-preview3" }
    The modules of an application include those of every manifest in its DependsOn chain, so
    PoshAcmeExchangeServer needs the modules of PoshAcme. Before copying, each target is checked
    (Install-ServerModule). If modules are missing or too old, you are asked first: install
    them and then copy the files, copy the files only, or stop.

    The "On server" column compares the application's settings file (manifest AppData,
    Applications\...\Data\<App>.json) with the copy on each server: same, a different version,
    or not installed. It is a quick check; the copy itself compares every file.

    Preview checks the modules and runs Copy-FilesToServer -WhatIf (changes nothing). Copy asks
    for confirmation and then copies. Results are listed per server and item at the bottom,
    followed by the install steps to run on each server (manifest Install.Steps, Base and the PSM
    Frontend first, then dependencies) and the account to run them as (RunAs in the application's
    settings file).

    Run from Windows PowerShell 5.1 or PowerShell 7 on the admin workstation, as an account
    that is an administrator on the targets (files go through \\server\C$).

    Publish to DFS (tab): pick Shared files and/or applications, Preview, then Publish to the DFS
    release store (Publish-ScriptsToDfs: signature check, backup, changed files only, retire, Release.json).
    When the tab is shown (and after Reload or a publish) each item's files are compared with DFS
    (Publish-ScriptsToDfs -WhatIf): files to publish or retire, or why it cannot be published (for
    example an unsigned script). Files that differ while the version is the same are flagged
    'version not bumped'.

    Distribution...: edits how devices reach the scripts (Transports in Data\Settings\Scripts.json:
    DFS, SFTP, FTP; enabled, priority, connection), for all devices or as one device's override
    (Show-DistributionSettings.ps1 next to this script).

    Override login: for servers where the current login has no rights (another domain), click
    "Override login..." and enter DOMAIN\user and password. It is kept only in memory while the
    window is open (nothing is saved) and used for the admin shares, the "On server" check, the
    module fix (WinRM) and the copy. "Clear login" or closing the window forgets it and closes
    its connections. Without an override the current login is used. The override applies to every
    checked server, so check only the servers of one domain at a time.
.PARAMETER InstallsFolder
    Folder holding the manifests. Defaults to the Data folder next to this script (C:\SCRIPTS\Installs\Data).
.PARAMETER LogFileName
    Base name of the text log file in the Logs folder.
.EXAMPLE
    PS> C:\SCRIPTS\Installs\SetupApplications.ps1
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-13
    Time: 09:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.12.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: SetupApplications
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param(
    [string]$InstallsFolder = (Join-Path -Path $PSScriptRoot -ChildPath 'Data'),
    [string]$LogFileName = 'SetupApplications'
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'SetupApplications.ps1'

#region Standard locations
$SL = Split-Path -Path $PSScriptRoot -Parent   # C:\SCRIPTS (this script is in C:\SCRIPTS\Installs)
$SF = Join-Path -Path $SL -ChildPath 'Functions'
#endregion

#region Functions and logging
foreach ($F in 'Write-AdvancedLog.ps1', 'Compare-Files.ps1', 'Connect-AdminShare.ps1', 'Copy-FilesToServer.ps1', 'Install-ServerModule.ps1', 'Update-ApplicationInventory.ps1', 'Get-ApplicationSettings.ps1', 'Get-ScriptsTransport.ps1', 'Publish-ScriptsToDfs.ps1') {
    $P = Join-Path -Path $SF -ChildPath $F
    if (-not (Test-Path -Path $P)) { throw "Required function file missing: $P" }
    . $P
}
# Distribution settings window (Installs stays on this machine, so it is not in Functions)
$DistPath = Join-Path -Path $PSScriptRoot -ChildPath 'Show-DistributionSettings.ps1'
if (-not (Test-Path -Path $DistPath)) { throw "Required file missing: $DistPath" }
. $DistPath

function Write-SetupLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$LogType = 'INFO'
    )
    Write-Verbose $Message
    try { Write-AdvancedLog -Message $Message -ScriptName $ScriptName -LogFileName $LogFileName -LogType $LogType }
    catch { Write-Warning "Write-AdvancedLog failed: $($_.Exception.Message)" }
}
#endregion

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'This window needs an STA session. Start it with: powershell.exe -STA -File C:\SCRIPTS\Installs\SetupApplications.ps1'
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

#region Data
$Apps         = New-Object System.Collections.Generic.List[object]   # one entry per manifest
$ExtraServers = New-Object System.Collections.Generic.List[string]   # added in the window
$Unchecked    = @{}                                                   # 'App|Server' rows the user unchecked
$Inventory    = New-Object System.Collections.Generic.List[object]   # PSM inventory records on DFS (Import-Inventory)
$StaleDone    = @{}                                                   # stale 'App|Server' rows already unchecked once
$script:InventoryNote = ''

function Import-Manifests {
    $Apps.Clear()
    if (-not (Test-Path -Path $InstallsFolder)) { return }
    foreach ($File in Get-ChildItem -Path $InstallsFolder -Filter '*.json' -File | Sort-Object Name) {
        try {
            $M = Get-Content -Path $File.FullName -Raw | ConvertFrom-Json
            # The application's own settings file (Applications\...\Data\<App>.json) on this machine:
            # version, run-as account and where module data lives. It is copied with the app.
            $AD = $null
            if ($M.AppData -and (Test-Path -Path "$($M.AppData)" -PathType Leaf)) {
                $AD = Get-Content -Path "$($M.AppData)" -Raw | ConvertFrom-Json
            }
            $Apps.Add([pscustomobject]@{
                Name        = if ($M.Name) { "$($M.Name)" } else { $File.BaseName }
                FileName    = $File.BaseName
                Description = "$($M.Description)"
                Version     = if ($AD -and $AD.Version) { "$($AD.Version)" } else { "$($M.Version)" }
                AppData     = "$($M.AppData)"
                Servers     = @(@($M.Servers | Where-Object { $_ }) + @(
                    if ($M.ServersFrom -and $M.ServersFrom.Settings -and (Test-Path -Path "$($M.ServersFrom.Settings)")) {
                        $FromCfg = Get-Content -Path "$($M.ServersFrom.Settings)" -Raw | ConvertFrom-Json
                        $FromCfg."$($M.ServersFrom.Key)" | Where-Object { $_ }
                    }) | Select-Object -Unique)
                DependsOn   = @($M.DependsOn | Where-Object { $_ })
                Modules     = @($M.Modules | Where-Object { $_.Name } | ForEach-Object {
                    $N = "$($_.Name)"
                    $FromApp = if ($AD) { $AD.Modules | Where-Object { "$($_.Name)" -eq $N } | Select-Object -First 1 } else { $null }
                    [pscustomobject]@{
                        Name           = $N
                        MinimumVersion = "$($_.MinimumVersion)"
                        LatestOnly     = [bool]$_.LatestOnly
                        RequiredVersion = "$($_.RequiredVersion)"
                        DataVariable   = if ($FromApp -and $FromApp.DataVariable) { "$($FromApp.DataVariable)" } else { "$($_.DataVariable)" }
                        DataFolder     = if ($FromApp -and $FromApp.DataFolder) { "$($FromApp.DataFolder)" } else { "$($_.DataFolder)" }
                    }
                })
                Files       = @($M.Files).Count
                RunAs       = if ($AD -and $AD.RunAs) { "$($AD.RunAs)" } elseif ($M.Install -and $M.Install.RunAs) { "$($M.Install.RunAs)" } else { '' }
                Steps       = @(if ($M.Install) { $M.Install.Steps | Where-Object { $_ } | ForEach-Object { "$_" } })
                Error       = ''
            })
        }
        catch {
            $Apps.Add([pscustomobject]@{
                Name = $File.BaseName; FileName = $File.BaseName; Description = ''; Version = ''; AppData = ''
                Servers = @(); DependsOn = @(); Modules = @(); Files = 0; RunAs = ''; Steps = @(); Error = $_.Exception.Message
            })
        }
    }
}

# Where applications are installed, from the PSM inventory records the servers and this window write
# to DFS (update.<DEVICE>.<App>.json in the inventory drop folder). Read on start and on Reload list.
function Import-Inventory {
    $Inventory.Clear()
    $script:InventoryNote = ''
    try {
        $Cfg = Get-ApplicationSettings -Path (Join-Path -Path $SL -ChildPath 'Data\Settings\Scripts.json')
        $Root = "$((Get-ScriptsTransport -Settings $Cfg -Type Dfs | Select-Object -First 1).Root)"
        if (-not $Root) { $script:InventoryNote = 'Inventory: no Dfs transport in Scripts.json.'; return }
        $Drop = Join-Path -Path $Root -ChildPath $(if ($Cfg.InventoryFolder) { "$($Cfg.InventoryFolder)" } else { 'Applications\Data' })
        $StaleDays = if ("$($Cfg.StaleDays)" -match '^\d+$') { [int]$Cfg.StaleDays } else { 7 }
        foreach ($F in @(Get-ChildItem -Path $Drop -Filter 'update.*.json' -File -ErrorAction Stop)) {
            try { $J = Get-Content -Path $F.FullName -Raw | ConvertFrom-Json } catch { continue }
            if (-not $J.Device -or -not $J.Application) { continue }
            $When = $F.LastWriteTime
            if ($J.Updated) { try { $When = [datetime]$J.Updated } catch { } }
            $Inventory.Add([pscustomobject]@{
                App     = "$($J.Application)"
                Server  = $(if ($J.Domain) { "$($J.Device).$($J.Domain)" } else { "$($J.Device)" }).ToLower()
                Version = "$($J.Version)"
                Updated = $When
                Stale   = $When -lt (Get-Date).AddDays(-$StaleDays)
            })
        }
        $script:InventoryNote = "Inventory: $(@($Inventory | ForEach-Object Server | Select-Object -Unique).Count) server(s) from $Drop."
    }
    catch { $script:InventoryNote = "Inventory not read: $($_.Exception.Message)" }
}

# Inventory servers of one application: Base and the PSM Frontend go to every PSM server; any other
# application to the servers that have it or an application that includes it (DependsOn).
function Get-InventoryRows {
    param($App)
    if (-not $Inventory.Count) { return @() }
    $Users = @($Apps | Where-Object { $_.FileName -ne $App.FileName -and -not $_.Error -and (@(Get-AppChain -App $_ -NoBase | ForEach-Object FileName) -contains $App.FileName) })
    $All = $Inventory.ToArray()
    $Names = @($App.Name, $App.FileName) + @($Users | ForEach-Object { $_.Name; $_.FileName })
    $Recs = @($All | Where-Object { $App.FileName -in 'Base', 'PSMFrontendScriptsSync' -or $Names -contains $_.App })
    foreach ($G in @($Recs | Group-Object Server)) {
        $Own = @($G.Group | Where-Object { $_.App -in @($App.Name, $App.FileName) })
        $Newest = ($G.Group | Sort-Object Updated -Descending | Select-Object -First 1)
        [pscustomobject]@{
            Server = $G.Name
            Via    = if ($Own -or $App.FileName -in 'Base', 'PSMFrontendScriptsSync') { '' } else { (@($G.Group.App | Select-Object -Unique) -join ', ') }
            Stale  = -not @($G.Group | Where-Object { -not $_.Stale }).Count
            Days   = [int]((Get-Date) - $Newest.Updated).TotalDays
        }
    }
}

# Every target of an application: manifest, inventory and added servers (one row per server)
function Get-TargetRows {
    param($App)
    $Rows = [ordered]@{}
    foreach ($S in $App.Servers) { $Rows["$S".ToLower()] = [pscustomobject]@{ Server = "$S"; From = 'manifest'; Stale = $false } }
    foreach ($I in @(Get-InventoryRows -App $App)) {
        $Text = 'inventory' + $(if ($I.Via) { " (via $($I.Via))" }) + $(if ($I.Stale) { ", stale $($I.Days)d" })
        if ($Rows.Contains($I.Server)) { $Rows[$I.Server].From = "manifest, $Text"; continue }
        $Rows[$I.Server] = [pscustomobject]@{ Server = $I.Server; From = $Text; Stale = $I.Stale }
    }
    foreach ($S in $ExtraServers) { if (-not $Rows.Contains("$S".ToLower())) { $Rows["$S".ToLower()] = [pscustomobject]@{ Server = $S; From = 'added'; Stale = $false } } }
    @($Rows.Values)
}

# Modules an application needs: its own plus those of every manifest it depends on.
# One entry per module: the highest MinimumVersion and LatestOnly from any manifest win.
# For = the manifest(s) asking for it.
function Get-AppModules {
    param($App, [string[]]$Seen = @())
    if ($Seen -contains $App.FileName) { return }
    $List = @($App.Modules | ForEach-Object { $_ | Select-Object *, @{ n = 'For'; e = { $App.Name } } })
    foreach ($Dep in $App.DependsOn) {
        $D = $Apps | Where-Object { $_.FileName -eq $Dep } | Select-Object -First 1
        if ($D) { $List += @(Get-AppModules -App $D -Seen ($Seen + $App.FileName)) }
    }
    $List | Group-Object Name | ForEach-Object {
        $G = $_.Group
        $Min = $G | Where-Object { $_.MinimumVersion } | Sort-Object { [version]$_.MinimumVersion } -Descending | Select-Object -First 1
        $Data = $G | Where-Object { $_.DataFolder } | Select-Object -First 1
        [pscustomobject]@{
            Name           = $_.Name
            MinimumVersion = if ($Min) { $Min.MinimumVersion } else { '' }
            LatestOnly     = [bool]($G | Where-Object { $_.LatestOnly })
            RequiredVersion = "$(($G | Where-Object { $_.RequiredVersion } | Select-Object -First 1).RequiredVersion)"
            DataVariable   = if ($Data) { $Data.DataVariable } else { '' }
            DataFolder     = if ($Data) { $Data.DataFolder } else { '' }
            For            = (@($G.For) | Select-Object -Unique) -join ', '
        }
    }
}

# The application and everything it depends on, dependencies first (install order).
# Base and its own chain (the PSM Frontend) come first for every application, as they are copied first.
function Get-AppChain {
    param($App, [string[]]$Seen = @(), [switch]$NoBase)
    if ($Seen -contains $App.FileName) { return }
    if (-not $NoBase -and -not $Seen.Count -and $App.FileName -ne 'Base') {
        $B = $Apps | Where-Object { $_.FileName -eq 'Base' } | Select-Object -First 1
        if ($B) { Get-AppChain -App $B -NoBase }
    }
    foreach ($Dep in $App.DependsOn) {
        $D = $Apps | Where-Object { $_.FileName -eq $Dep } | Select-Object -First 1
        if ($D) { Get-AppChain -App $D -Seen ($Seen + $App.FileName) }
    }
    $App
}

function Format-ModuleList {
    param($Modules)
    (@($Modules) | ForEach-Object {
        $T = if ($_.RequiredVersion) { "$($_.Name) $($_.RequiredVersion) (exactly)" } elseif ($_.LatestOnly) { "$($_.Name) (newest only)" } elseif ($_.MinimumVersion) { "$($_.Name) $($_.MinimumVersion)+" } else { $_.Name }
        if ($_.DataFolder) { $T += " - data in $($_.DataFolder)" + $(if ($_.DataVariable) { " ($($_.DataVariable))" } else { '' }) }
        $T
    }) -join '; '
}

function Get-AppDisplay {
    param($App)
    if ($App.Error) { return "$($App.Name)   (manifest error)" }
    $Parts = @("$(@(Get-TargetRows -App $App | Where-Object { $_.From -ne 'added' }).Count) server(s)", "$($App.Files) file(s)")
    if ($App.DependsOn.Count) { $Parts += "includes $($App.DependsOn -join ', ')" }
    $Mods = @(Get-AppModules -App $App)
    if ($Mods.Count) { $Parts += "needs $($Mods.Count) module(s)" }
    '{0}   ({1})' -f $App.Name, ($Parts -join ', ')
}
#endregion

#region Window
$Form = New-Object System.Windows.Forms.Form
$Form.Text = 'Setup Applications'
$Form.Size = New-Object System.Drawing.Size(1100, 760)
$Form.MinimumSize = New-Object System.Drawing.Size(800, 560)
$Form.StartPosition = 'CenterScreen'
$Form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$Layout = New-Object System.Windows.Forms.TableLayoutPanel
$Layout.Dock = 'Fill'
$Layout.Padding = New-Object System.Windows.Forms.Padding(8)
$Layout.ColumnCount = 2
$Layout.RowCount = 6
[void]$Layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 40)))
[void]$Layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 60)))
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))        # 0 headings
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 45)))     # 1 lists
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 70)))    # 2 description / add server
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))        # 3 results heading
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 55)))     # 4 results
[void]$Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))        # 5 buttons

# Two tabs: copy to servers (as before) and publish to the DFS release store
$MainTabs = New-Object System.Windows.Forms.TabControl
$MainTabs.Dock = 'Fill'
$CopyTab = New-Object System.Windows.Forms.TabPage
$CopyTab.Text = 'Copy to servers'
$CopyTab.Controls.Add($Layout)
$PublishTab = New-Object System.Windows.Forms.TabPage
$PublishTab.Text = 'Publish to DFS'
[void]$MainTabs.TabPages.Add($CopyTab)
[void]$MainTabs.TabPages.Add($PublishTab)
$Form.Controls.Add($MainTabs)

function New-Heading {
    param([string]$Text)
    $L = New-Object System.Windows.Forms.Label
    $L.Text = $Text
    $L.AutoSize = $true
    $L.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $L.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
    $L
}

# Row 0: headings
$Layout.Controls.Add((New-Heading "Applications  ($InstallsFolder)"), 0, 0)
$Layout.Controls.Add((New-Heading 'Copy to  (servers / clients; uncheck to leave one out)'), 1, 0)

# Row 1: applications and targets
$AppList = New-Object System.Windows.Forms.CheckedListBox
$AppList.Dock = 'Fill'
$AppList.CheckOnClick = $true
$AppList.IntegralHeight = $false
$Layout.Controls.Add($AppList, 0, 1)

$TargetList = New-Object System.Windows.Forms.ListView
$TargetList.Dock = 'Fill'
$TargetList.View = 'Details'
$TargetList.CheckBoxes = $true
$TargetList.FullRowSelect = $true
[void]$TargetList.Columns.Add('Server / client', 300)
[void]$TargetList.Columns.Add('Application', 200)
[void]$TargetList.Columns.Add('From', 170)
[void]$TargetList.Columns.Add('On server', 240)
$Layout.Controls.Add($TargetList, 1, 1)

# Row 2: description (left), add server (right)
$Description = New-Object System.Windows.Forms.TextBox
$Description.Dock = 'Fill'
$Description.Multiline = $true
$Description.ReadOnly = $true
$Description.ScrollBars = 'Vertical'
$Layout.Controls.Add($Description, 0, 2)

$AddPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$AddPanel.Dock = 'Fill'
$AddPanel.WrapContents = $true
$AddLabel = New-Object System.Windows.Forms.Label
$AddLabel.Text = 'Add server/client (FQDN) for the checked applications:'
$AddLabel.AutoSize = $true
$AddLabel.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
$AddBox = New-Object System.Windows.Forms.TextBox
$AddBox.Width = 260
$AddButton = New-Object System.Windows.Forms.Button
$AddButton.Text = 'Add'
$AddButton.AutoSize = $true
$CheckAllButton = New-Object System.Windows.Forms.Button
$CheckAllButton.Text = 'Check all targets'
$CheckAllButton.AutoSize = $true
$UncheckAllButton = New-Object System.Windows.Forms.Button
$UncheckAllButton.Text = 'Uncheck all targets'
$UncheckAllButton.AutoSize = $true
$AddPanel.Controls.AddRange(@($AddLabel, $AddBox, $AddButton, $CheckAllButton, $UncheckAllButton))
$Layout.Controls.Add($AddPanel, 1, 2)

# Row 3-4: results
$ResultsHeading = New-Heading 'Results'
$Layout.Controls.Add($ResultsHeading, 0, 3)
$Layout.SetColumnSpan($ResultsHeading, 2)

$Results = New-Object System.Windows.Forms.ListView
$Results.Dock = 'Fill'
$Results.View = 'Details'
$Results.FullRowSelect = $true
[void]$Results.Columns.Add('Application', 170)
[void]$Results.Columns.Add('Server / client', 230)
[void]$Results.Columns.Add('Item', 430)
[void]$Results.Columns.Add('Action', 220)
$Layout.Controls.Add($Results, 0, 4)
$Layout.SetColumnSpan($Results, 2)

# Row 5: buttons and status
$ButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$ButtonPanel.Dock = 'Fill'
$ButtonPanel.AutoSize = $true
$RefreshButton = New-Object System.Windows.Forms.Button
$RefreshButton.Text = 'Reload list'
$RefreshButton.AutoSize = $true
$PreviewButton = New-Object System.Windows.Forms.Button
$PreviewButton.Text = 'Preview (no changes)'
$PreviewButton.AutoSize = $true
$CopyButton = New-Object System.Windows.Forms.Button
$CopyButton.Text = 'Copy to servers'
$CopyButton.AutoSize = $true
$CloseButton = New-Object System.Windows.Forms.Button
$CloseButton.Text = 'Close'
$CloseButton.AutoSize = $true
$Status = New-Object System.Windows.Forms.Label
$Status.AutoSize = $true
$Status.Margin = New-Object System.Windows.Forms.Padding(12, 8, 3, 3)
$LoginButton = New-Object System.Windows.Forms.Button
$LoginButton.Text = 'Override login...'
$LoginButton.AutoSize = $true
$ClearLoginButton = New-Object System.Windows.Forms.Button
$ClearLoginButton.Text = 'Clear login'
$ClearLoginButton.AutoSize = $true
$ClearLoginButton.Enabled = $false
$LoginLabel = New-Object System.Windows.Forms.Label
$LoginLabel.AutoSize = $true
$LoginLabel.Margin = New-Object System.Windows.Forms.Padding(6, 8, 3, 3)
$LoginLabel.Text = "Login: $env:USERDOMAIN\$env:USERNAME (current)"
$DistButton = New-Object System.Windows.Forms.Button
$DistButton.Text = 'Distribution...'
$DistButton.AutoSize = $true
$ButtonPanel.Controls.AddRange(@($RefreshButton, $PreviewButton, $CopyButton, $DistButton, $LoginButton, $ClearLoginButton, $LoginLabel, $CloseButton, $Status))
$Layout.Controls.Add($ButtonPanel, 0, 5)
$Layout.SetColumnSpan($ButtonPanel, 2)

# Publish tab: what to publish (left), what it contains and its versions (right), results, buttons
$PubLayout = New-Object System.Windows.Forms.TableLayoutPanel
$PubLayout.Dock = 'Fill'
$PubLayout.Padding = New-Object System.Windows.Forms.Padding(8)
$PubLayout.ColumnCount = 2
$PubLayout.RowCount = 5
[void]$PubLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 40)))
[void]$PubLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 60)))
[void]$PubLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))     # 0 heading
[void]$PubLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 40)))  # 1 list / info
[void]$PubLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))     # 2 results heading
[void]$PubLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 60)))  # 3 results
[void]$PubLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))     # 4 buttons
$PublishTab.Controls.Add($PubLayout)

$PubHeading = New-Heading 'Publish to DFS'
$PubLayout.Controls.Add($PubHeading, 0, 0)
$PubLayout.SetColumnSpan($PubHeading, 2)
$PubList = New-Object System.Windows.Forms.CheckedListBox
$PubList.Dock = 'Fill'; $PubList.CheckOnClick = $true; $PubList.IntegralHeight = $false
$PubLayout.Controls.Add($PubList, 0, 1)
$PubInfo = New-Object System.Windows.Forms.TextBox
$PubInfo.Dock = 'Fill'; $PubInfo.Multiline = $true; $PubInfo.ReadOnly = $true; $PubInfo.ScrollBars = 'Vertical'
$PubLayout.Controls.Add($PubInfo, 1, 1)
$PubResultsHeading = New-Heading 'Results  (unchanged files are hidden)'
$PubLayout.Controls.Add($PubResultsHeading, 0, 2)
$PubLayout.SetColumnSpan($PubResultsHeading, 2)
$PubResults = New-Object System.Windows.Forms.ListView
$PubResults.Dock = 'Fill'; $PubResults.View = 'Details'; $PubResults.FullRowSelect = $true
[void]$PubResults.Columns.Add('Item', 200)
[void]$PubResults.Columns.Add('File', 560)
[void]$PubResults.Columns.Add('Action', 260)
$PubLayout.Controls.Add($PubResults, 0, 3)
$PubLayout.SetColumnSpan($PubResults, 2)
$PubButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$PubButtons.Dock = 'Fill'; $PubButtons.AutoSize = $true
$PubReload = New-Object System.Windows.Forms.Button; $PubReload.Text = 'Reload list'; $PubReload.AutoSize = $true
$PubPreview = New-Object System.Windows.Forms.Button; $PubPreview.Text = 'Preview (no changes)'; $PubPreview.AutoSize = $true
$PubGo = New-Object System.Windows.Forms.Button; $PubGo.Text = 'Publish'; $PubGo.AutoSize = $true
$PubStatus = New-Object System.Windows.Forms.Label; $PubStatus.AutoSize = $true
$PubStatus.Margin = New-Object System.Windows.Forms.Padding(12, 8, 3, 3)
$PubButtons.Controls.AddRange(@($PubReload, $PubPreview, $PubGo, $PubStatus))
$PubLayout.Controls.Add($PubButtons, 0, 4)
$PubLayout.SetColumnSpan($PubButtons, 2)
#endregion

#region Window logic
function Update-AppList {
    $AppList.Items.Clear()
    $ServerState.Clear()
    Import-Manifests
    Import-Inventory
    foreach ($A in $Apps) { [void]$AppList.Items.Add((Get-AppDisplay $A)) }
    $Status.Text = "$($Apps.Count) application(s) in $InstallsFolder. $script:InventoryNote"
    Update-Targets
}

function Get-CheckedApps {
    # CheckedIndices is current except inside ItemCheck; callers use BeginInvoke for that.
    @($AppList.CheckedIndices | ForEach-Object { $Apps[$_] } | Where-Object { -not $_.Error })
}

# What the server has of an application, from its settings file there (cached until Reload or a copy):
# same as this machine, a different version, or not installed.
$ServerState = @{}

# Override login: kept only in memory while this window is open, never saved. When set, the
# admin shares are opened with it (Connect-AdminShare) and it is passed to the copy and module
# tools; when not set, the current login is used as before.
$script:OverrideCred = $null
$script:OpenShares = New-Object System.Collections.Generic.List[string]

function Open-TargetShare {
    # Returns '' when the share can be used, otherwise the reason
    param([string]$Server)
    if (-not $script:OverrideCred) { return '' }
    $C = Connect-AdminShare -ComputerName $Server -Credential $script:OverrideCred
    if ($C.Created -and -not $script:OpenShares.Contains($Server)) { $script:OpenShares.Add($Server) }
    if ($C.Connected) { '' } else { $C.Message }
}

function Close-TargetShares {
    foreach ($S in @($script:OpenShares)) { Connect-AdminShare -ComputerName $S -Disconnect | Out-Null }
    $script:OpenShares.Clear()
}

function Show-LoginDialog {
    # Small username/password box (Get-Credential would prompt in the console under PowerShell 7)
    $D = New-Object System.Windows.Forms.Form
    $D.Text = 'Override login'
    $D.FormBorderStyle = 'FixedDialog'; $D.MaximizeBox = $false; $D.MinimizeBox = $false
    $D.StartPosition = 'CenterParent'; $D.ClientSize = New-Object System.Drawing.Size(380, 170)
    $D.Font = $Form.Font
    $Info = New-Object System.Windows.Forms.Label
    $Info.Text = 'Used instead of your own login for the checked servers, only while this window is open. Nothing is saved.'
    $Info.SetBounds(12, 10, 356, 34)
    $UL = New-Object System.Windows.Forms.Label; $UL.Text = 'User (DOMAIN\user):'; $UL.SetBounds(12, 52, 130, 20)
    $UB = New-Object System.Windows.Forms.TextBox; $UB.SetBounds(146, 50, 222, 22)
    if ($script:OverrideCred) { $UB.Text = $script:OverrideCred.UserName }
    $PL = New-Object System.Windows.Forms.Label; $PL.Text = 'Password:'; $PL.SetBounds(12, 84, 130, 20)
    $PB = New-Object System.Windows.Forms.TextBox; $PB.SetBounds(146, 82, 222, 22); $PB.UseSystemPasswordChar = $true
    $OK = New-Object System.Windows.Forms.Button; $OK.Text = 'OK'; $OK.SetBounds(212, 128, 75, 28); $OK.DialogResult = 'OK'
    $Cancel = New-Object System.Windows.Forms.Button; $Cancel.Text = 'Cancel'; $Cancel.SetBounds(293, 128, 75, 28); $Cancel.DialogResult = 'Cancel'
    $D.AcceptButton = $OK; $D.CancelButton = $Cancel
    $D.Controls.AddRange(@($Info, $UL, $UB, $PL, $PB, $OK, $Cancel))
    $Result = $null
    if ($D.ShowDialog($Form) -eq 'OK' -and $UB.Text.Trim()) {
        $Secure = New-Object System.Security.SecureString
        foreach ($Ch in $PB.Text.ToCharArray()) { $Secure.AppendChar($Ch) }
        $Secure.MakeReadOnly()
        $Result = New-Object System.Management.Automation.PSCredential($UB.Text.Trim(), $Secure)
    }
    $PB.Clear()
    $D.Dispose()
    $Result
}

function Get-ServerAppState {
    param($App, [string]$Server)
    if (-not $App.AppData) { return [pscustomobject]@{ Text = ''; Ok = $true } }
    $Key = "$($App.FileName)|$Server"
    if ($ServerState.ContainsKey($Key)) { return $ServerState[$Key] }
    $State = if ($App.AppData -notmatch '^([A-Za-z]):\\(.*)$') { [pscustomobject]@{ Text = 'AppData is not a local path'; Ok = $false } }
    else {
        $Remote = '\\{0}\{1}$\{2}' -f $Server, $Matches[1].ToUpper(), $Matches[2]
        $Why = Open-TargetShare -Server $Server
        if ($Why) { [pscustomobject]@{ Text = "login failed: $Why"; Ok = $false } }
        elseif (-not (Test-Path -Path ('\\{0}\C$' -f $Server))) { [pscustomobject]@{ Text = 'unreachable'; Ok = $false } }
        elseif (-not (Test-Path -Path $Remote -PathType Leaf)) { [pscustomobject]@{ Text = 'not installed'; Ok = $false } }
        elseif ((Compare-Files -File1Path $Remote -File2Path $App.AppData -WhatIf:$false).AreEqual) { [pscustomobject]@{ Text = "v$($App.Version) (same as this machine)"; Ok = $true } }
        else {
            $RV = try { "v$((Get-Content -Path $Remote -Raw | ConvertFrom-Json).Version)" } catch { 'unreadable' }
            [pscustomobject]@{ Text = "$RV (different; this machine v$($App.Version))"; Ok = $false }
        }
    }
    $ServerState[$Key] = $State
    $State
}

function Update-Targets {
    $TargetList.BeginUpdate()
    $TargetList.Items.Clear()
    foreach ($A in Get-CheckedApps) {
        $Rows = @(Get-TargetRows -App $A)
        if ($Rows.Count -eq 0) {
            $Item = New-Object System.Windows.Forms.ListViewItem('(no servers - add one below)')
            [void]$Item.SubItems.Add($A.Name)
            [void]$Item.SubItems.Add('')
            $Item.ForeColor = [System.Drawing.Color]::Gray
            $Item.Tag = $null
            [void]$TargetList.Items.Add($Item)
            continue
        }
        foreach ($R in $Rows) {
            $Item = New-Object System.Windows.Forms.ListViewItem($R.Server)
            [void]$Item.SubItems.Add($A.Name)
            [void]$Item.SubItems.Add($R.From)
            $St = Get-ServerAppState -App $A -Server $R.Server
            [void]$Item.SubItems.Add($St.Text)
            if (-not $St.Ok) { $Item.ForeColor = [System.Drawing.Color]::DarkOrange }
            $Item.Tag = [pscustomobject]@{ App = $A; Server = $R.Server }
            # A stale server (no inventory report for StaleDays) starts unchecked, once
            $Key = "$($A.FileName)|$($R.Server)"
            if ($R.Stale -and -not $StaleDone.ContainsKey($Key)) { $StaleDone[$Key] = $true; $Unchecked[$Key] = $true }
            if ($R.Stale) { $Item.ForeColor = [System.Drawing.Color]::Gray }
            $Item.Checked = -not $Unchecked.ContainsKey($Key)
            [void]$TargetList.Items.Add($Item)
        }
    }
    $TargetList.EndUpdate()
}

function Show-Description {
    $I = $AppList.SelectedIndex
    if ($I -lt 0) { $Description.Text = ''; return }
    $A = $Apps[$I]
    $Lines = @()
    if ($A.Error) { $Lines += "Manifest error: $($A.Error)" }
    if ($A.Description) { $Lines += $A.Description }
    if ($A.Version) { $Lines += "Version $($A.Version)" }
    if ($A.DependsOn.Count) { $Lines += "Also copies: $($A.DependsOn -join ', ')" }
    if ($A.FileName -ne 'Base' -and ($Apps | Where-Object { $_.FileName -eq 'Base' })) { $Lines += 'Always copied first: Base (C:\SCRIPTS root folders, all common functions and the PSM Frontend, whose install step comes first).' }
    $Mods = @(Get-AppModules -App $A)
    if ($Mods.Count) { $Lines += "Modules needed on the server: $(Format-ModuleList $Mods)" }
    $N = 0
    foreach ($C in @(Get-AppChain -App $A | Select-Object -Unique -Property FileName, Name, RunAs, Steps)) {
        foreach ($S in $C.Steps) { $N++; $Lines += "Install step ${N} ($($C.Name)$(if ($C.RunAs) { ", as $($C.RunAs)" })): $S" }
    }
    $Description.Text = $Lines -join "`r`n"
}

function Add-ResultRow {
    param([string]$Application, [string]$Server, [string]$Item, [string]$Action)
    $Row = New-Object System.Windows.Forms.ListViewItem($Application)
    [void]$Row.SubItems.Add($Server)
    [void]$Row.SubItems.Add($Item)
    [void]$Row.SubItems.Add($Action)
    $Row.ForeColor = switch -Wildcard ($Action) {
        'Failed*'        { $script:Failed++; [System.Drawing.Color]::Firebrick }
        'Skipped*'       { [System.Drawing.Color]::DarkOrange }
        'Would*'         { [System.Drawing.Color]::DarkOrange }
        'Needs fixing*'  { [System.Drawing.Color]::DarkOrange }
        'No data*'       { [System.Drawing.Color]::DarkOrange }
        'Unchanged'      { [System.Drawing.Color]::Gray }
        'OK'             { [System.Drawing.Color]::Gray }
        'Data in*'       { [System.Drawing.Color]::Gray }
        'Run on*'        { [System.Drawing.Color]::RoyalBlue }
        default          { [System.Drawing.Color]::DarkGreen }
    }
    [void]$Results.Items.Add($Row)
}

function Set-Busy {
    param([bool]$On, [string]$Text)
    $Form.UseWaitCursor = $On
    $PreviewButton.Enabled = -not $On; $CopyButton.Enabled = -not $On
    if ($Text) { $Status.Text = $Text }
    [System.Windows.Forms.Application]::DoEvents()
}

# One check per module across all checked targets. Each check: the module settings, the
# servers that need it, and the rows Install-ServerModule returned.
function Get-ModuleChecks {
    param($Groups, [switch]$Fix, [string[]]$OnlyServers)
    $ByModule = [ordered]@{}
    foreach ($G in $Groups) {
        foreach ($M in @(Get-AppModules -App $G.Group[0].App)) {
            if (-not $ByModule.Contains($M.Name)) {
                $ByModule[$M.Name] = [pscustomobject]@{ Module = $M; For = @(); Servers = @(); Rows = @() }
            }
            $C = $ByModule[$M.Name]
            $C.For = @($C.For + $M.For | Select-Object -Unique)
            $C.Servers = @($C.Servers + @($G.Group.Server) | Select-Object -Unique)
        }
    }
    foreach ($C in $ByModule.Values) {
        $Servers = if ($OnlyServers) { @($C.Servers | Where-Object { $OnlyServers -contains "$($C.Module.Name)|$_" }) } else { $C.Servers }
        if (-not $Servers) { continue }
        Set-Busy $true "$(if ($Fix) { 'Fixing' } else { 'Checking' }) module $($C.Module.Name)..."
        $ModArgs = @{ ComputerName = $Servers; Name = $C.Module.Name; WhatIf = (-not $Fix); WarningAction = 'SilentlyContinue' }
        if ($script:OverrideCred) { $ModArgs.Credential = $script:OverrideCred }
        if ($C.Module.RequiredVersion) { $ModArgs.RequiredVersion = $C.Module.RequiredVersion }
        elseif ($C.Module.LatestOnly) { $ModArgs.LatestOnly = $true }
        elseif ($C.Module.MinimumVersion) { $ModArgs.MinimumVersion = $C.Module.MinimumVersion }
        if ($C.Module.DataFolder) { $ModArgs.DataFolder = $C.Module.DataFolder }
        if ($C.Module.DataVariable) { $ModArgs.DataVariable = $C.Module.DataVariable }
        try { $C.Rows = @(Install-ServerModule @ModArgs) }
        catch {
            $Msg = $_.Exception.Message
            $C.Rows = @($Servers | ForEach-Object { [pscustomobject]@{ Server = $_; Module = $C.Module.Name; Installed = ''; Required = ''; Action = "Failed: $Msg"; Data = '' } })
        }
        $C
    }
}

# "Would install 4.35.0 and remove 4.0.0 (other versions: 4.0.0, WhatIf)" -> "install 4.35.0 and remove 4.0.0 (other versions: 4.0.0)"
function Format-Problem {
    param([string]$Action)
    ($Action -replace '^Would ', '') -replace ', WhatIf\)$', ')'
}

function Add-ModuleRows {
    param($Checks, [switch]$Pending)
    foreach ($C in $Checks) {
        $App = "module for $($C.For -join ', ')"
        foreach ($R in $C.Rows) {
            # In a check before copying, "Would ..." means it is wrong and was not fixed.
            $Action = "$($R.Action)"
            if ($Pending -and $Action -like 'Would *') { $Action = 'Needs fixing: ' + (Format-Problem $Action) }
            Add-ResultRow -Application $App -Server "$($R.Server)" -Item "Module $($R.Module) (required: $($R.Required); installed: $($R.Installed))" -Action $Action
            if ($R.Data) {
                $Var = if ($C.Module.DataVariable) { " ($($C.Module.DataVariable))" } else { '' }
                Add-ResultRow -Application $App -Server "$($R.Server)" -Item "Data for $($R.Module)$Var" -Action "$($R.Data)"
            }
        }
    }
}

function Invoke-Setup {
    param([switch]$Preview)

    # Checked target rows, grouped by application
    $Targets = @($TargetList.Items | Where-Object { $_.Checked -and $_.Tag } | ForEach-Object { $_.Tag })
    if ($Targets.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Check at least one application and one server/client.', 'Setup Applications', 'OK', 'Information')
        return
    }
    $Groups = @($Targets | Group-Object { $_.App.FileName })
    $Summary = ($Groups | ForEach-Object { "$($_.Name): $(($_.Group.Server) -join ', ')" }) -join "`r`n"
    $Mode = if ($Preview) { 'Preview' } else { 'Copy' }

    $Results.Items.Clear()
    $script:Failed = 0
    try {
        #region 1. Modules
        $Checks = @(Get-ModuleChecks -Groups $Groups)
        $Wrong = @($Checks | ForEach-Object { $C = $_; $C.Rows | Where-Object { "$($_.Action)" -like 'Would *' } | ForEach-Object { [pscustomobject]@{ Check = $C; Row = $_ } } })
        Set-Busy $false

        if ($Preview) {
            Add-ModuleRows -Checks $Checks
        }
        else {
            if ($Wrong.Count) {
                $List = ($Wrong | ForEach-Object { '  {0}: {1} - {2}' -f $_.Row.Server.Split('.')[0], $_.Row.Module, (Format-Problem $_.Row.Action) }) -join "`r`n"
                $Answer = [System.Windows.Forms.MessageBox]::Show(
                    "These modules are not installed correctly:`r`n`r`n$List`r`n`r`nInstall the modules first?`r`n`r`n" +
                    "Yes - fix the modules, then copy:`r`n$Summary`r`n`r`nNo - copy the files only`r`nCancel - do nothing",
                    'Setup Applications - modules', 'YesNoCancel', 'Warning')
                if ($Answer -eq 'Cancel') { $Status.Text = 'Cancelled.'; return }
            }
            else {
                $Answer = [System.Windows.Forms.MessageBox]::Show("Copy these applications now?`r`n`r`n$Summary", 'Setup Applications', 'YesNo', 'Question')
                if ($Answer -ne 'Yes') { return }
                $Answer = 'NoModules'
            }
            Write-SetupLog "$Mode started$(if ($script:OverrideCred) { " with override login $($script:OverrideCred.UserName)" }): $(($Groups | ForEach-Object { "$($_.Name) -> $(($_.Group.Server) -join ', ')" }) -join '; ')"

            if ($Answer -eq 'Yes') {
                # Fix only the module/server pairs that were wrong, then show the fixed state
                $Keys = @($Wrong | ForEach-Object { "$($_.Row.Module)|$($_.Row.Server)" })
                $Fixed = @(Get-ModuleChecks -Groups $Groups -Fix -OnlyServers $Keys)
                foreach ($C in $Checks) {
                    $F = $Fixed | Where-Object { $_.Module.Name -eq $C.Module.Name } | Select-Object -First 1
                    if ($F) { $C.Rows = @($C.Rows | Where-Object { $Keys -notcontains "$($C.Module.Name)|$($_.Server)" }) + @($F.Rows) }
                }
                Add-ModuleRows -Checks $Checks
            }
            else {
                if ($Wrong.Count) { Write-SetupLog "Copying without fixing $($Wrong.Count) module problem(s)." -LogType WARNING }
                Add-ModuleRows -Checks $Checks -Pending
            }
        }
        #endregion

        #region 2. Files
        foreach ($G in $Groups) {
            Set-Busy $true "$Mode $($G.Name)..."
            try {
                $CopyArgs = @{ Name = $G.Name; InstallsFolder = $InstallsFolder; ComputerName = @($G.Group.Server); WhatIf = [bool]$Preview; WarningAction = 'SilentlyContinue' }
                if ($script:OverrideCred) { $CopyArgs.Credential = $script:OverrideCred }
                $Rows = @(Copy-FilesToServer @CopyArgs)
            }
            catch {
                $Rows = @([pscustomobject]@{ Server = ''; Item = "$($G.Name).json"; Action = "Failed: $($_.Exception.Message)" })
            }
            foreach ($R in $Rows) { Add-ResultRow -Application $G.Name -Server "$($R.Server)" -Item "$($R.Item)" -Action "$($R.Action)" }
            # Record the copy in the inventory (the DFS drop folder) for every server copied to
            if (-not $Preview) {
                $App = $G.Group[0].App
                foreach ($Srv in @($G.Group.Server)) {
                    $SrvRows = @($Rows | Where-Object { "$($_.Server)" -eq $Srv })
                    $Bad = @($SrvRows | Where-Object { "$($_.Action)" -like 'Failed*' }).Count
                    $Inv = Update-ApplicationInventory -Application $App.Name -Action Copied -Version $App.Version -ComputerName $Srv `
                        -Result $(if ($Bad) { 'Failed' } else { 'OK' }) -Details @{ Items = $SrvRows.Count; Failed = $Bad } -WarningAction SilentlyContinue
                    if (-not $Inv.DropWritten) { Add-ResultRow -Application $G.Name -Server $Srv -Item 'Inventory' -Action "Skipped: $($Inv.Message)" }
                }
            }
        }
        #endregion

        #region 3. Install steps to run on each server
        foreach ($G in $Groups) {
            $N = 0
            $Chain = @(Get-AppChain -App $G.Group[0].App)
            # Each manifest once, in chain order (Group-Object would sort them by name)
            $Done = @{}
            foreach ($C in @($Chain | Where-Object { -not $Done.ContainsKey($_.FileName) -and ($Done[$_.FileName] = $true) })) {
                foreach ($S in $C.Steps) {
                    $N++
                    foreach ($Srv in @($G.Group.Server)) {
                        Add-ResultRow -Application $G.Name -Server $Srv -Item "Step ${N}: $S" -Action "Run on the server$(if ($C.RunAs) { " as $($C.RunAs)" })"
                    }
                }
            }
        }
        #endregion
    }
    finally {
        Set-Busy $false
    }

    $Status.Text = '{0} finished: {1} row(s), {2} failed.' -f $Mode, $Results.Items.Count, $script:Failed
    if (-not $Preview) { $ServerState.Clear(); Update-Targets }   # show what the servers have now
    if (-not $Preview) {
        Write-SetupLog $Status.Text -LogType $(if ($script:Failed) { 'WARNING' } else { 'INFO' })
    }
}

# ItemCheck fires before the box changes; rebuild the targets once it has.
$AppList.Add_ItemCheck({ $Form.BeginInvoke([Action]{ Update-Targets }) | Out-Null })
$AppList.Add_SelectedIndexChanged({ Show-Description })

$TargetList.Add_ItemChecked({
    param($Src, $E)
    $T = $E.Item.Tag
    if (-not $T) { return }
    $Key = "$($T.App.FileName)|$($T.Server)"
    if ($E.Item.Checked) { $Unchecked.Remove($Key) } else { $Unchecked[$Key] = $true }
})

$AddAction = {
    $Name = $AddBox.Text.Trim()
    if (-not $Name) { return }
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-]*$') {
        [void][System.Windows.Forms.MessageBox]::Show("'$Name' is not a valid computer name.", 'Setup Applications', 'OK', 'Warning')
        return
    }
    if (-not $ExtraServers.Contains($Name)) { $ExtraServers.Add($Name) }
    $AddBox.Clear()
    Update-Targets
}
$AddButton.Add_Click($AddAction)
$AddBox.Add_KeyDown({ param($Src, $E) if ($E.KeyCode -eq 'Enter') { $E.SuppressKeyPress = $true; & $AddAction } })

$CheckAllButton.Add_Click({ foreach ($I in $TargetList.Items) { if ($I.Tag) { $I.Checked = $true } } })
$UncheckAllButton.Add_Click({ foreach ($I in $TargetList.Items) { if ($I.Tag) { $I.Checked = $false } } })
$RefreshButton.Add_Click({ Update-AppList })
$PreviewButton.Add_Click({ Invoke-Setup -Preview })
$CopyButton.Add_Click({ Invoke-Setup })
$CloseButton.Add_Click({ $Form.Close() })
$DistButton.Add_Click({
    # Offer every server of every manifest plus the ones added in this window
    $Known = @(@($Apps | ForEach-Object { $_.Servers }) + @($Inventory | ForEach-Object Server) + @($ExtraServers) | Where-Object { $_ } | Sort-Object -Unique)
    try {
        if (Show-DistributionSettings -Owner $Form -Devices $Known -LogFileName $LogFileName) {
            $Status.Text = 'Distribution settings saved; they reach the servers with the next copy (Base) or publish.'
        }
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show("Distribution settings: $($_.Exception.Message)", 'Setup Applications', 'OK', 'Error')
    }
})
$LoginButton.Add_Click({
    $C = Show-LoginDialog
    if (-not $C) { return }
    Close-TargetShares
    $script:OverrideCred = $C
    $LoginLabel.Text = "Login: $($C.UserName) (override, this session only)"
    $LoginLabel.ForeColor = [System.Drawing.Color]::DarkOrange
    $ClearLoginButton.Enabled = $true
    $ServerState.Clear(); Update-Targets
})
$ClearLoginButton.Add_Click({
    Close-TargetShares
    $script:OverrideCred = $null
    $LoginLabel.Text = "Login: $env:USERDOMAIN\$env:USERNAME (current)"
    $LoginLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
    $ClearLoginButton.Enabled = $false
    $ServerState.Clear(); Update-Targets
})
# Forget the login and close its connections when the window closes
$Form.Add_FormClosed({ Close-TargetShares; $script:OverrideCred = $null })
#endregion

#region Publish tab logic
$script:PubItems = New-Object System.Collections.Generic.List[object]

# Release store: the Dfs transport's Root in Scripts.json
function Get-PublishRoot {
    try {
        $Cfg = Get-ApplicationSettings -Path (Join-Path -Path $SL -ChildPath 'Data\Settings\Scripts.json')
        "$((Get-ScriptsTransport -Settings $Cfg -Type Dfs -All | Where-Object Root | Select-Object -First 1).Root)"
    } catch { '' }
}

# Version in a settings file here and its copy on DFS (relative path)
function Get-VersionPair {
    param([string]$Rel)
    $L = Join-Path -Path $SL -ChildPath $Rel
    $D = if ($script:PubRoot) { Join-Path -Path $script:PubRoot -ChildPath $Rel } else { '' }
    $Lv = try { "$((Get-Content -Path $L -Raw | ConvertFrom-Json).Version)" } catch { '?' }
    $Dv = if ($D -and (Test-Path -Path $D)) { try { "$((Get-Content -Path $D -Raw | ConvertFrom-Json).Version)" } catch { '?' } } else { 'not published' }
    [pscustomobject]@{ Local = $Lv; Dfs = $Dv }
}

# Files of one item that differ from DFS: Publish-ScriptsToDfs -WhatIf (the same rules and signature
# check as a real publish). Cached per item until Reload or a publish.
$script:PubFileCheck = @{}
function Get-PublishFileCheck {
    param([string]$Name)
    if ($script:PubFileCheck.ContainsKey($Name)) { return $script:PubFileCheck[$Name] }
    $Check = try {
        $Rows = @(Publish-ScriptsToDfs -Name $Name -WhatIf -NoBackup -WarningAction SilentlyContinue)
        $Ch = @($Rows | Where-Object { "$($_.Action)" -like 'Would be added*' -or "$($_.Action)" -like 'Would be updated*' })
        $Rt = @($Rows | Where-Object { "$($_.Action)" -like 'Would be retired*' })
        [pscustomobject]@{ Changed = $Ch.Count; Retire = $Rt.Count; Paths = @($Ch + $Rt | ForEach-Object { "$($_.Action -replace ' \(WhatIf\)', ''): $($_.Path)" }); Error = '' }
    }
    catch { [pscustomobject]@{ Changed = 0; Retire = 0; Paths = @(); Error = $_.Exception.Message } }
    $script:PubFileCheck[$Name] = $Check
    $Check
}

function Update-PublishList {
    param([switch]$Files)   # also compare the files with DFS (Publish tab shown, Reload, after a publish)
    $script:PubRoot = Get-PublishRoot
    $PubHeading.Text = if ($script:PubRoot) { "Publish to DFS  ($script:PubRoot; the Dfs transport in Data\Settings\Scripts.json)" } else { 'Publish to DFS  (no Dfs transport Root in Data\Settings\Scripts.json)' }
    $Checked = @(foreach ($Idx in $PubList.CheckedIndices) { $script:PubItems[$Idx].Name })
    $PubList.Items.Clear(); $script:PubItems.Clear()
    $V = Get-VersionPair 'Data\Settings\Scripts.json'
    $script:PubItems.Add([pscustomobject]@{ Name = 'Shared'; Versions = $V; Text = 'Shared files: Functions, Data, Modules, Installs (SetupApplications and all manifests)' })
    foreach ($A in $Apps | Where-Object { $_.FileName -ne 'Base' -and -not $_.Error }) {
        $Rel = if ($A.AppData -and $A.AppData -like 'C:\SCRIPTS\*') { $A.AppData.Substring(11) } else { '' }
        $V = if ($Rel) { Get-VersionPair $Rel } else { [pscustomobject]@{ Local = '?'; Dfs = '?' } }
        $script:PubItems.Add([pscustomobject]@{ Name = $A.FileName; Versions = $V; Text = $A.Description; DependsOn = $A.DependsOn })
    }
    $Started = Get-Date
    if ($Files -and $script:PubRoot) {
        $Form.UseWaitCursor = $true; $PubStatus.Text = 'Comparing files with DFS...'; [System.Windows.Forms.Application]::DoEvents()
    }
    $Out = 0
    foreach ($I in $script:PubItems) {
        $I | Add-Member -NotePropertyName Files -NotePropertyValue $null -Force
        if (($Files -or $script:PubFileCheck.ContainsKey($I.Name)) -and $script:PubRoot) { $I.Files = Get-PublishFileCheck -Name $I.Name }
        $Label = if ($I.Name -eq 'Shared') { 'Shared files' } else { $I.Name }
        $Newer = $I.Versions.Local -ne $I.Versions.Dfs
        $FileText = if (-not $I.Files) { '' }
                    elseif ($I.Files.Error) { '   check failed' }
                    elseif ($I.Files.Changed -or $I.Files.Retire) { '   ' + (@($(if ($I.Files.Changed) { "$($I.Files.Changed) file(s) to publish" }), $(if ($I.Files.Retire) { "$($I.Files.Retire) to retire" })) -join ', ') }
                    else { '   files in sync' }
        $Mark = if ($I.Files -and $I.Files.Error) { '  <- see details' }
                elseif ($I.Files -and ($I.Files.Changed -or $I.Files.Retire) -and -not $Newer) { '  <- files changed, version not bumped' }
                elseif ($Newer) { '  <- newer here' }
                else { '' }
        if ($Mark) { $Out++ }
        $Idx = $PubList.Items.Add(('{0}   {1} (DFS: {2}){3}{4}' -f $Label, $I.Versions.Local, $I.Versions.Dfs, $FileText, $Mark))
        if ($Checked -contains $I.Name) { $PubList.SetItemChecked($Idx, $true) }
    }
    $Form.UseWaitCursor = $false
    $PubStatus.Text = if (@($script:PubItems | Where-Object Files).Count) {
        '{0} item(s), {1} to publish (files compared with DFS in {2:N0}s). Versions: here (DFS).' -f $script:PubItems.Count, $Out, ((Get-Date) - $Started).TotalSeconds
    } else { "$($script:PubItems.Count) item(s). Versions: here (DFS)." }
}

function Show-PublishInfo {
    $I = if ($PubList.SelectedIndex -ge 0) { $script:PubItems[$PubList.SelectedIndex] } else { $null }
    if (-not $I) { $PubInfo.Text = ''; return }
    $Lines = @($I.Text, '', "Version here: $($I.Versions.Local)    On DFS: $($I.Versions.Dfs)")
    if ($I.Files) {
        if ($I.Files.Error) { $Lines += "File check: $($I.Files.Error)" }
        elseif (-not ($I.Files.Changed -or $I.Files.Retire)) { $Lines += 'Files: the same as on DFS.' }
        else {
            $Lines += "Files that differ from DFS ($($I.Files.Changed) to publish, $($I.Files.Retire) to retire):"
            $Lines += @($I.Files.Paths | Select-Object -First 12 | ForEach-Object { "  $_" })
            if ($I.Files.Paths.Count -gt 12) { $Lines += "  ... and $($I.Files.Paths.Count - 12) more (Preview lists all)" }
            if ($I.Versions.Local -eq $I.Versions.Dfs) { $Lines += 'The version was not bumped: bump Version in the settings file, so servers holding a test copy and the inventory see the change.' }
        }
    }
    if ($I.Name -ne 'Shared') {
        if (@($I.DependsOn).Count) { $Lines += "Also publishes (DependsOn): $($I.DependsOn -join ', ')" }
        $Lines += 'Publishes the files its manifest lists and the manifest itself. Server-local data (rules, certificates, logs) is never published.'
    }
    $Lines += '', 'Publish: signature check (stops if any script is not validly signed), backup of C:\SCRIPTS, copy of changed files, retire of files no longer part of the item (moved to _Retired on DFS), Release.json.'
    $PubInfo.Text = $Lines -join "`r`n"
}

function Invoke-Publish {
    param([switch]$Preview)
    $Names = @(foreach ($Idx in $PubList.CheckedIndices) { $script:PubItems[$Idx].Name })
    if (-not $Names.Count) { $PubStatus.Text = 'Check what to publish first.'; return }
    if (-not $script:PubRoot) { [void][System.Windows.Forms.MessageBox]::Show('No Dfs transport Root in Data\Settings\Scripts.json (Distribution...).', 'Publish'); return }
    if (-not $Preview) {
        $A = [System.Windows.Forms.MessageBox]::Show("Publish to $($script:PubRoot)?`r`n`r`n  $($Names -join "`r`n  ")`r`n`r`nServers with the PSM Frontend pick it up within the hour.", 'Publish to DFS', 'YesNo', 'Question')
        if ($A -ne 'Yes') { return }
    }
    $PubResults.Items.Clear()
    $Form.UseWaitCursor = $true; $PubPreview.Enabled = $false; $PubGo.Enabled = $false
    $PubStatus.Text = "$(if ($Preview) { 'Previewing' } else { 'Publishing' }) $($Names -join ', ')..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $Rows = @(Publish-ScriptsToDfs -Name $Names -WhatIf:([bool]$Preview) -WarningAction SilentlyContinue)
        foreach ($R in @($Rows | Where-Object { $_.Action -ne 'Unchanged' })) {
            $Item = New-Object System.Windows.Forms.ListViewItem("$($R.Item)")
            [void]$Item.SubItems.Add("$($R.Path)")
            [void]$Item.SubItems.Add("$($R.Action)")
            # First match wins ('Would be retired' matches two patterns)
            $Item.ForeColor = switch -Wildcard ("$($R.Action)") {
                'Failed*'  { [System.Drawing.Color]::Firebrick; break }
                'Would*'   { [System.Drawing.Color]::DarkOrange; break }
                '*etired*' { [System.Drawing.Color]::RoyalBlue; break }
                default    { [System.Drawing.Color]::DarkGreen }
            }
            [void]$PubResults.Items.Add($Item)
        }
        $Ch = @($Rows | Where-Object { $_.Action -ne 'Unchanged' }).Count
        $Bad = @($Rows | Where-Object { "$($_.Action)" -like 'Failed*' }).Count
        $PubStatus.Text = '{0}: {1} change(s), {2} unchanged, {3} failed.' -f $(if ($Preview) { 'Preview' } else { 'Published' }), $Ch, (@($Rows).Count - $Ch), $Bad
        if (-not $Preview) {
            Write-SetupLog "Publish $($Names -join ', ') to $($script:PubRoot): $Ch change(s), $Bad failed." -LogType $(if ($Bad) { 'WARNING' } else { 'INFO' })
            $Keep = $PubStatus.Text
            $script:PubFileCheck.Clear(); Update-PublishList -Files
            $PubStatus.Text = "$Keep  Now: $($PubStatus.Text)"
        }
    }
    catch {
        $PubStatus.Text = 'Stopped.'
        [void][System.Windows.Forms.MessageBox]::Show("Not published:`r`n`r`n$($_.Exception.Message)", 'Publish to DFS', 'OK', 'Warning')
    }
    finally { $Form.UseWaitCursor = $false; $PubPreview.Enabled = $true; $PubGo.Enabled = $true }
}

$PubList.Add_SelectedIndexChanged({ Show-PublishInfo })
$PubReload.Add_Click({ Import-Manifests; $script:PubFileCheck.Clear(); Update-PublishList -Files })
$PubPreview.Add_Click({ Invoke-Publish -Preview })
$PubGo.Add_Click({ Invoke-Publish })
# Files are compared when the tab is shown (once; Reload compares again)
$MainTabs.Add_SelectedIndexChanged({ if ($MainTabs.SelectedIndex -eq 1) { Update-PublishList -Files } })
#endregion

Update-AppList
Update-PublishList
[void]$Form.ShowDialog()
$Form.Dispose()

# Example usage:
# PS> C:\SCRIPTS\Installs\SetupApplications.ps1
# PS> powershell.exe -STA -File C:\SCRIPTS\Installs\SetupApplications.ps1


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCARSxtrmUAG2i3z
# lWR4bCgk2bg/74XhQZQ38ibJi0V6WKCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG6DCCBNCgAwIBAgITQAAAAqtBkGO1asEvkAAAAAACqzANBgkqhkiG9w0B
# AQsFADBwMRMwEQYKCZImiZPyLGQBGRYDY29tMSIwIAYKCZImiZPyLGQBGRYSZ2Vu
# ZXJhdGlvbnNnYWl0aGVyMTUwMwYDVQQDEyxnZW5lcmF0aW9uc2dhaXRoZXItU1JW
# MDEwMDEwMDM4MDM1LUlzc3VpbmdDQTAeFw0yNjA4MjAxNzMzNTRaFw0yNzAxMzEx
# NzI3MjVaMDgxFDASBgNVBAoTC0dlbmVyYXRpb25zMSAwHgYDVQQDExdQb3dlcnNo
# ZWxsIENvZGUgU2lnbmluZzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
# AMgHhkqXmzDlBuov3PJaCmpZddU3S+1mt4Yaahz121grfW1H+nHXf2cUuzH12wzG
# ErW+kF0lqkBll/26aHzETnBepOxaP+KCoKZ7db4mYctch5wdDTANplQu35hPEO6I
# yNhrEk5UQqAjM9ONKCdWkzBo+/vaTbQDpYwc7h2s1s8dZdjU4tqy72+ThXEx8Vp3
# OePAXZ1moCIPXuhjSEoCMasqIuWDwavRRLXONBrhhue84FPyFa7qpTOz7Hg98DfW
# pMA+ZIXl/KJVlRdN5H8b0IZiWczfHUyz76fw67tzngUR7CI2xeTkdSpJ1dl2O+Xi
# T33pvcVEnjq/Pql0rddXBbUCAwEAAaOCArEwggKtMD0GCSsGAQQBgjcVBwQwMC4G
# JisGAQQBgjcVCIK0njms71qCqYE6gt6kboK4gAOBOIO8mwSBh4VAAgFkAgEDMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMA4GA1UdDwEB/wQEAwIHgDAbBgkrBgEEAYI3FQoE
# DjAMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBRT5Uu5LaLJBCLOFGRaVsipJu+gMjAf
# BgNVHSMEGDAWgBROXx35Y5WKLzaZqCYJ3GvzXL4RnDCB/QYDVR0fBIH1MIHyMIHv
# oIHsoIHphoHmbGRhcDovLy9DTj1nZW5lcmF0aW9uc2dhaXRoZXItU1JWMDEwMDEw
# MDM4MDM1LUlzc3VpbmdDQSxDTj1zcnYwMTAwMTAwMzgwMzUsQ049Q0RQLENOPVB1
# YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZpZ3VyYXRp
# b24sREM9Z2VuZXJhdGlvbnNnYWl0aGVyLERDPWNvbT9jZXJ0aWZpY2F0ZVJldm9j
# YXRpb25MaXN0P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9uUG9pbnQw
# gekGCCsGAQUFBwEBBIHcMIHZMIHWBggrBgEFBQcwAoaByWxkYXA6Ly8vQ049Z2Vu
# ZXJhdGlvbnNnYWl0aGVyLVNSVjAxMDAxMDAzODAzNS1Jc3N1aW5nQ0EsQ049QUlB
# LENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZp
# Z3VyYXRpb24sREM9Z2VuZXJhdGlvbnNnYWl0aGVyLERDPWNvbT9jQUNlcnRpZmlj
# YXRlP2Jhc2U/b2JqZWN0Q2xhc3M9Y2VydGlmaWNhdGlvbkF1dGhvcml0eTANBgkq
# hkiG9w0BAQsFAAOCAgEAAHvAjyztTm9FmITG34NV4dx+megfwLzllxDHlShSacUx
# XzEPlVd4XScO3O1a+0sngL1XuE8xVDBe6suITmBjbN/BYo8vRjbIUlwUYE54FhRD
# rUOHYYEIecLI1ax1qpnS19Fy8YIOu7y14R2NwbY38uNZ7UDb5TBGiwJdHR+jlQVX
# Qyu0gONFsaP/mqeFKqkOKAQ0UWo38Q6U/4zJ5I9nuiHULQWqEiUEF0kTEudFWwhP
# hiwGjiIRGzmpJtiMuffHRk2kDk3wXcFyR4cjtkQjXqq3crMRnxoC3FohGFL4EmXe
# 3knNDtgR3ODvE0zrzHiPCBeF/goZ5p+/6v35xfCLPDRzXCz1FC3U6/VVomuLf5ln
# m6tO0+X9iFFi2LsnvYi6omNesi+qBRQcXq0uPbK8eA/grIk4+zVVooM2Dc9diS0C
# hwoFqMV0t0H3lpdmCXCLIqYaqO4FwxTy1Mm/Q6PZHPD/Uxq8QUPeOtvD5x7RsNRw
# zT+yaU73mqtqPc/lrcG6SRWd3jE79GbkGM3n+0FfD097Ks0lk/U820Is++u/8gPV
# kEe2UePSM2XYc4CYUlPYStlcyMh1t44TX/5l6qypJBehjdzYnvMe2ZRDL3SmPj4K
# AJiHANKMgoKK9GSW3qCeXMT+qevxRBKnhkBJcBYn/mHIMhHbwSwSTxU0mW+ggLMw
# ggbtMIIE1aADAgECAhAIT9wzT35FTtvDD4/5khg1MA0GCSqGSIb3DQEBCwUAMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwHhcNMjYwODA1MDAwMDAwWhcNMzcxMTA0MjM1OTU5WjBjMQswCQYD
# VQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lD
# ZXJ0IFNIQTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNiAxMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtnum8sn+zUr41JtMZbP9OMYw
# +HwJDpG5xkIu/lqcfNYmMX81YmsUiHLbh9ykpeWBGKTLhYBrAN9Tdg/QEzG32XcO
# bmgIblnr0CoQ3WSAeDZ6nH6X6VkFyYkJw3QBJREwvm4UhLzSxmwPA7cFKRTEOMsm
# EEj6qJk/dqLEAL+oQYuOwE2UuiX1Vnul8YReIyWd4kgLn9gq6LNXM0UplkR6jL/Q
# Hxmb6fMoGBJYbnaUI7XD6cKDpekK2SVMld4iDbzeHDtOaaxldH5IxuNusQ69nd8/
# ZXEiB5Hbxj3RlK13cX1W4DlFXKdv/CEhM8Cj1vvlmvhNroyPdRGbbpBlgyf8Wdu5
# N6ByhFwURn0U6ozlPoxN22v+fviUhP+6DR547OZnpBMWDfei1f5sVGwiiW/KQTWO
# K97g+4RJpPzPNV4VYMAwO2jM2Aty2QYPVmOQTJm0msuXnJrSbl2gf9JylpkJlWXq
# k1Q4LJsxz+TELoQCZIljbgvTJgoPU2R12ydv8i1UqL/adelA0y7U9Pmmtbze9Xx3
# rtajC5SzQd1jgfwAwsa90v9YcSPdmeoyoBBA/27cCL237l5DTYYPDLQ4ON3OLTGW
# nvRb6jDrf/T75gMRfUzSLCBQfBusm9+mSWRlC/Df6S/e9Q8i13CuhzOT2Jx+V/nl
# bXM4QoBwlUAhelwwJT0CAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0O
# BBYEFBTJY4owLtRK+26U8+bjQH717M3iMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esri
# kFb2L9RJ7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcD
# CDCBlQYIKwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRp
# Z2ljZXJ0LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIw
# MjVDQTEuY3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYy
# MDI1Q0ExLmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJ
# KoZIhvcNAQELBQADggIBAI3FOmEenVIK35msCYB+fShAsWvSYvLBItoNdAgQ2jIq
# rGsVsluXMJU/+mRebBc52s6lbKAvOVPXaizmKkMLLflEEKDZQx4CkS2t8aHPjkXh
# a3hYZ010htFa3dhNgmalH5vuWvh3tTCf4frTS7gPtGc4Z/xaPhQ2AB1mR8eEe/Wb
# H0RWHvVIl6VwQ3+g5FKNfN2N/DWJkf13w2H+2GfqEfbd35Ww8CvoYBjLNIDTadcP
# WdgsjsiOaK/7EsKJgLjUNIVgvcaFOLLQ/GlrA+0ZHJoFUbOr5SJN8zykPspXIXlp
# DJY/gqFUZRROeab9GVgmhbdOJcD/63RhxPahFUGbckRONqMe6DYAv6/mOG0pWd3c
# PStsdcS7buj5DyniwRY8yooMH6ptx5vpP/pZzBPBeZD2U4IsthyxB5Jaa8qrOkB5
# z160TXiM5ADMspZ0TfD9MJoq0tFpFPssKRFhWeEDYPvcUuN7U7lvcdHl4ezQ3NT/
# 7Ffs1sR1yh/LRbdZ3B3Vc6q2WmD8mDC0p9kzl2o73iVtS946IkEj7FkRsZGww1te
# YxERROC745xrtjvcw9ZyyUjHZWGRIpJeMNsPquCDf0fkyHtB+J4AiNZqCQk23rxh
# +KbpyMTNVKItJ5l92Svl20U9NbqMBOVYl1h54NEYLJq1/xHWFKPNK903zJZA9P2D
# MIIITDCCBgCgAwIBAgITGQAAAAu8LyA0hwqD9AAAAAAACzBBBgkqhkiG9w0BAQow
# NKAPMA0GCWCGSAFlAwQCAwUAoRwwGgYJKoZIhvcNAQEIMA0GCWCGSAFlAwQCAwUA
# ogMCAUAwbTETMBEGCgmSJomT8ixkARkWA2NvbTEiMCAGCgmSJomT8ixkARkWEmdl
# bmVyYXRpb25zZ2FpdGhlcjEyMDAGA1UEAxMpZ2VuZXJhdGlvbnNnYWl0aGVyLVNS
# VjAxMDAxMDAzNzAzNS1Sb290Q0EwHhcNMjUwMTMxMTcxNzI1WhcNMjcwMTMxMTcy
# NzI1WjBwMRMwEQYKCZImiZPyLGQBGRYDY29tMSIwIAYKCZImiZPyLGQBGRYSZ2Vu
# ZXJhdGlvbnNnYWl0aGVyMTUwMwYDVQQDEyxnZW5lcmF0aW9uc2dhaXRoZXItU1JW
# MDEwMDEwMDM4MDM1LUlzc3VpbmdDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAME7bcPuw+OBlpLFMrUpTOHjElzdC+VrSCfa9scUjHCqDU2B9rTBDzN5
# 5xpCu+NC4psqMzLIbOOOmv1KkfKvdDNkmgK7sJ6v4CxXrLsVELZkugW7mQG2NpTY
# yurNWkIxxn6U8wZHIwRbzH3a5XPHgeejY8+XEn4lDeQ/gy4HZPrT6gO2ML9MoED0
# jkXuSpBlotXDlv8D/EJTvTWoT3i/8sSa6J5uO+r0ckCSCkxvMy4zwifEFLmUNope
# nB8aPzs4NkRnPhNg7OcRyjssDcijiVWV8Tee9N0iAc637aJrTD8CtSyUDMAA0Zhh
# tjaGlcj7xXM1GhBvmlwn0EchVyGsALPC41AMHQRi3FNl6k633iXssKkcQL51EuAx
# XWS73CrcD1w1leFNVZnxmtW3yGzto6ND9ZSuYwyrBrqJLVfXVQJC+0ruUNrz/B/5
# jHey1Se4iLQnGrgrLVhJAAZHGAXuVTYB4f5s1cjjvj7+h6i/ZnJOYlCEW8ipwVW4
# 1AFjnxEAenzxAFv7NeoWuusJoPq9sGvC9xJfxClWt9zZfu4qJ95k1e+t1t4CSnvM
# 5O0uY4KqQDX1I0IOTozy9jT04QSLpm3VdLmznOFebja1213JR/D3GeApyqNJzEr5
# wWiIeZWkk27a+Yc3e9xGTke2nT06j+ytb66v8CIdxuy9JdfBn8aNAgMBAAGjggJ4
# MIICdDAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUTl8d+WOVii82magmCdxr
# 81y+EZwwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDgYDVR0PAQH/BAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUQBf/oJasKe2FCSOPWKt9FaN9
# U1EwgfoGA1UdHwSB8jCB7zCB7KCB6aCB5oaB42xkYXA6Ly8vQ049Z2VuZXJhdGlv
# bnNnYWl0aGVyLVNSVjAxMDAxMDAzNzAzNS1Sb290Q0EsQ049c3J2MDEwMDEwMDM3
# MDM1LENOPUNEUCxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNl
# cyxDTj1Db25maWd1cmF0aW9uLERDPWdlbmVyYXRpb25zZ2FpdGhlcixEQz1jb20/
# Y2VydGlmaWNhdGVSZXZvY2F0aW9uTGlzdD9iYXNlP29iamVjdENsYXNzPWNSTERp
# c3RyaWJ1dGlvblBvaW50MIHmBggrBgEFBQcBAQSB2TCB1jCB0wYIKwYBBQUHMAKG
# gcZsZGFwOi8vL0NOPWdlbmVyYXRpb25zZ2FpdGhlci1TUlYwMTAwMTAwMzcwMzUt
# Um9vdENBLENOPUFJQSxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2
# aWNlcyxDTj1Db25maWd1cmF0aW9uLERDPWdlbmVyYXRpb25zZ2FpdGhlcixEQz1j
# b20/Y0FDZXJ0aWZpY2F0ZT9iYXNlP29iamVjdENsYXNzPWNlcnRpZmljYXRpb25B
# dXRob3JpdHkwQQYJKoZIhvcNAQEKMDSgDzANBglghkgBZQMEAgMFAKEcMBoGCSqG
# SIb3DQEBCDANBglghkgBZQMEAgMFAKIDAgFAA4ICAQCXYn6MOeflWh5jgspvzRQQ
# CWPuI3Ob3d3xt3bCSp1EW7uSAk1vkSc7OmcAUTayZXI7HH9KjIBTey1yuss4ynun
# /ZD87JBLTX9IWZcnD7SsDddk/7Qi4zRMj+Z8orAeLifAHXDGVFogWPr7giAvJU8n
# XPFjmz+5h6Vhujn9Ny5iaCKGXDbsb0FBimSqTyFMZ3hY5Z0AK87dWQIHWnx227Rm
# n5OIJCNC1lqpzHOgRs+VObKNSJMnSjyxOY77AaW73mXf0JGSJ4e61jJGvkghuZmX
# 3D+VvyOeXiNUfVpPRw5EVSUdPqYm6Y7pKTa0Dc7Wat4lCe8UGNwowIA3RfpzxeL3
# o6CvCn2tslFCtyO40fKX6Rgh+Fl5cAddwLYQTIULk4pxLqJBtAUPVhd+yTc+S6gl
# shFy+j1H9m1K9HfoQBTgukTKn3QWkn49FbbiNTAQ/Sr9XN4HF7/zJEu8WrA6GeLq
# QVYtIm2lwELocI3UPzSpp7Vw8TpRsFhJSOvfWEBjbNBvAWB7g79/AuotJ0DHIxnu
# yK6i6mf3ZUi9hj9g+lyXB/TQoRH8p3f01lpl7x60COLxJTSd4C3W0msRsTaqeO7x
# ZNZuc3i35mRD3XPmchB3Xgmx/qxAbnv8vDvOe86nz4wDRcHJtKoOtRdXDuBxqavy
# 8e8SwzOBXivKZRSg9xYQMTGCBWQwggVgAgEBMIGHMHAxEzARBgoJkiaJk/IsZAEZ
# FgNjb20xIjAgBgoJkiaJk/IsZAEZFhJnZW5lcmF0aW9uc2dhaXRoZXIxNTAzBgNV
# BAMTLGdlbmVyYXRpb25zZ2FpdGhlci1TUlYwMTAwMTAwMzgwMzUtSXNzdWluZ0NB
# AhNAAAACq0GQY7VqwS+QAAAAAAKrMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQB
# gjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIBlD5YG0
# 5HwDtWZ/LQ7eVGynzwsYLfZkkK24ZpYjpGbLMA0GCSqGSIb3DQEBAQUABIIBADnw
# 1tehrkv2euzhmce5mobstoNBzEeSnCWBCvZtRc8UCnT1wLbBp2GUxPEOssWUZ1RI
# UOTootU68GYkjsZKfRB23ezd7DpYmqqXcAF7ctg6Ggrzh3SIBmSkkQwYf/67OCtq
# zP1HzLZ1fpU9aD7JbTqziqkIN6Neww3PAsqiuKxcfJRI8w+B5yOYKwKWpFoEwet+
# v/wUddkN7bwPTkB7CaFlLpKgDRWU0+FOQNaMZnPVQCRSSh1mNuSjSBAG8OzI1v62
# XsG93nVMNWxuht+kI5lAxXoVCFSK66nGbrjJD1W0rSewzXZkFrxCCwErNMoKi9MJ
# fLeVWPza6o5pPFkD/zGhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDI1MDI0
# NDA5WjAvBgkqhkiG9w0BCQQxIgQgbKXcM/hhYfKoy/o5yi9CS1AX2Mpf+exI1Ot3
# diX+9PIwDQYJKoZIhvcNAQEBBQAEggIAU4S1xVxquEEtu2B3uRNlV1GxUDUnAeWS
# p/kj2cI9oihn/6BiNVeIcuGCW/NCdv6/MI/Odf30Brtvs7Ts2G+eV971lsWO8OGx
# A1YLTmbMN7/urnPSck97fpaQMKI20N3AX8dHKnCMCf33C77pX3pq8Uy01+2mBadE
# zPwfbeqM67kmHE8sC1/6kR08YxkCBzZd9ivnQfdj6DCUt2sU4NILGaJ+hz4LH2BH
# U7wNxbEWPxYjSKjtAmdAVPoSnNgrpA5pOTGtUpx8bwXvKlmfAle+UyWwi2zpvtGz
# xOJxKv4dZRP9/dVa4tbWprT17flkEOyonEeHqhqpk9UwojpX3+C/8j1/M2ap3knu
# eAcYud424OQKQ4XmusSsokkv+rmXVjnGPgGxfL6bxZhVfVhcrvCThKQlkNsGZgVZ
# z9Ml2VLIHhOoSeOyN8NWiEwjz/xz/ehhwBBSFGBsYHHNW6GJ1vCScUAlCaHBL/D+
# YRyLNxuyMOZBElhNVQ4rEYi1PXzGwCopoUTYUfzpqgwX8negbE1/09v0oQiz3GRi
# e8P68dGPE8lQSK4wkuK6fLEmNqajtoPxdre0di6PrGfV3dyyZ4v6UEvE/B/TRxyz
# cLS3ZoZmfIqpDN3d4gXdYHInMmQkIxloVckjSn7r4Q556TSvNuPbInRI65TWJ0ZW
# Q5C6JF72U0Q=
# SIG # End signature block
