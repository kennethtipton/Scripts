#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows Forms tool to manage this server's Posh-ACME account, Let's Encrypt certificates and the
    IIS deployment mapping.
.DESCRIPTION
    Tabs:
      Account          Let's Encrypt server (production or staging), the ACME account(s): create one,
                       change the contact e-mail, choose the current one.
      Certificates     Every Posh-ACME order: names, expiry, DNS plugin and what uses it.
                         New...           Request a certificate. DNS validation either copies the
                                          plugin settings of an existing certificate, or uses any of
                                          Posh-ACME's DNS plugins (HurricaneElectric, Cloudflare,
                                          Route53, Azure, Windows, ...); the fields of the chosen
                                          plugin and login method are built from the plugin itself.
                         Renew now        Submit-Renewal -Force for the selected certificate.
                         DNS settings...  Replace the plugin settings of an order (e.g. after the
                                          DNS provider password changed).
                         Assign to IIS    Opens the IIS Deployments tab for the certificate.
                         Remove...        Removes the order (optionally revoking the certificate).
      IIS Deployments  (when the IisServer role is on this server) One row per HTTPS binding in
                       IIS; choose the Let's Encrypt certificate it gets, or (none) to stop
                       managing it. Saved in IisServer\Data\Deployments\IisCertificates.json
                       (previous version kept in Backups). Deploy runs Renew-IisLE.ps1
                       -DeployCurrent in its own console window. Bindings themselves are added
                       and removed in IIS Manager.

    Posh-ACME saves the DNS plugin settings with each order, encrypted for the Windows account that
    entered them (it reuses them on every renewal). Run this tool as the account the renewal
    tasks use (RunAs in Data\PoshAcme.json); the Account tab warns when you are someone else.
    Secrets are never written to this application's files or logs.

    Let's Encrypt calls run in the background; their progress shows in the log at the bottom.

    Run in Windows PowerShell 5.1, elevated, on the server itself:
      powershell.exe -STA -File .\Show-PoshAcmeCertificateManagement.ps1
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Show-PoshAcmeCertificateManagement.ps1
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-21
    Time: 18:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.1.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Requesting certificates counts against Let's Encrypt's rate limits. Use the staging server
    (Account tab) to try out a new DNS plugin.

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: PoshAcmeCertificateManagement
    Overide Text Log File Path: C:\SCRIPTS\Logs\PoshAcmeCertificateManagement.log
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ScriptName = 'Show-PoshAcmeCertificateManagement.ps1'
$AppTitle   = 'Posh-ACME Certificate Management'

# Windows Forms needs a single-threaded apartment; Posh-ACME.Deploy and WebAdministration need 5.1
if ($PSVersionTable.PSEdition -ne 'Desktop' -or [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    return
}

#region Standard locations
$SCA = $PSScriptRoot
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL  = Split-Path -Path $SA -Parent
$SF  = Join-Path -Path $SL -ChildPath 'Functions'
$SG  = Join-Path -Path $SL -ChildPath 'Logs'
$IisRole = Join-Path -Path $SCA -ChildPath 'IisServer'
#endregion

#region Settings and logging
. (Join-Path -Path $SF -ChildPath 'Get-ApplicationSettings.ps1')
$Cfg = Get-ApplicationSettings -Path (Join-Path -Path $SCA -ChildPath 'Data\PoshAcme.json')
$PoshMod = $Cfg.Modules | Where-Object { $_.Name -eq 'Posh-ACME' } | Select-Object -First 1
$Script:PoshHome = if ($PoshMod -and $PoshMod.DataFolder) { "$($PoshMod.DataFolder)" } else { Join-Path -Path $SCA -ChildPath 'Certs' }
$env:POSHACME_HOME = $Script:PoshHome
$M = $Cfg.Manager
$Opt = @{
    DefaultPlugin    = if ($M -and $M.DefaultPlugin) { "$($M.DefaultPlugin)" } else { 'HurricaneElectric' }
    DnsSleep         = if ($M -and "$($M.DnsSleep)" -match '^\d+$') { [int]$M.DnsSleep } else { 120 }
    CertKeyLength    = if ($M -and $M.CertKeyLength) { "$($M.CertKeyLength)" } else { '2048' }
    AccountKeyLength = if ($M -and $M.AccountKeyLength) { "$($M.AccountKeyLength)" } else { 'ec-256' }
}
$Me = "$env:USERDOMAIN\$env:USERNAME"
$RunAs = "$($Cfg.RunAs)"
$WrongUser = [bool]($RunAs -and $Me -ne $RunAs)

$P = Join-Path -Path $SF -ChildPath 'Write-AdvancedLog.ps1'; if (Test-Path $P) { . $P }
function Write-ActionLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
        $LogArgs = @{ Message = "$Me : $Message"; ScriptName = $ScriptName; LogFileName = 'PoshAcmeCertificateManagement'; LogFile = (Join-Path $SG 'PoshAcmeCertificateManagement.log'); LogType = $LogType }
        if ($LogType -ne 'INFO') { $LogArgs.WriteEventLog = $true }
        try { Write-AdvancedLog @LogArgs } catch { }
    }
}
#endregion

#region Modules
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
function Show-Message { param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') [System.Windows.Forms.MessageBox]::Show($Text, $AppTitle, $Buttons, $Icon) }

try { Import-Module Posh-ACME -ErrorAction Stop }
catch { [void](Show-Message "Posh-ACME is not installed: $($_.Exception.Message)`r`n`r`nCopy the PoshAcme application with SetupApplications (it installs the modules) and run Install-PoshAcme.ps1." 'Error'); return }
$PluginDir = Join-Path -Path (Get-Module Posh-ACME).ModuleBase -ChildPath 'Plugins'
$DnsPlugins = @(Get-PAPlugin | Where-Object { $_.ChallengeType -eq 'dns-01' -and $_.Name -ne 'Manual' } | ForEach-Object { "$($_.Name)" } | Sort-Object)

$Script:HaveIis = $false
if (Test-Path -Path (Join-Path $IisRole 'Functions\Get-IisCertificateConfig.ps1')) {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        foreach ($F in 'Get-IisCertificateConfig.ps1', 'Save-IisCertificateConfig.ps1', 'Get-IisHttpsBinding.ps1') { . (Join-Path -Path $IisRole -ChildPath "Functions\$F") }
        $Script:HaveIis = $true
    }
    catch { }
}
$HaveExchange = [bool]$env:ExchangeInstallPath -and (Test-Path -Path (Join-Path $SCA 'ExchangeServer'))
$ExchangeDomain = if ("$($Cfg.Domain)") { "$($Cfg.Domain)".ToLower() } else { ('{0}.{1}' -f $env:COMPUTERNAME, (Get-CimInstance Win32_ComputerSystem).Domain).ToLower() }
#endregion

#region DNS plugin metadata (read from the plugin's Add-DnsTxt parameters)
$Script:PluginCache = @{}
function Get-PluginInfo {
    param([string]$Name)
    if ($Script:PluginCache.ContainsKey($Name)) { return $Script:PluginCache[$Name] }
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PluginDir "$Name.ps1"), [ref]$null, [ref]$null)
    $Fn = $Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-DnsTxt' }, $true)
    $Help = $null; try { $Help = $Fn.GetHelpContent() } catch { }
    $DefaultSet = ''
    $Cb = $Fn.Body.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } | Select-Object -First 1
    if ($Cb) { $D = $Cb.NamedArguments | Where-Object { $_.ArgumentName -eq 'DefaultParameterSetName' }; if ($D) { $DefaultSet = "$($D.Argument.Value)" } }

    $Params = @(foreach ($Prm in $Fn.Body.ParamBlock.Parameters) {
        $N = $Prm.Name.VariablePath.UserPath
        if ($N -in 'RecordName', 'TxtValue', 'ExtraParams') { continue }
        $TypeName = "$(($Prm.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1).TypeName.FullName)"
        $Kind = switch -Regex ($TypeName) {
            '^(System\.Management\.Automation\.)?pscredential$' { 'Credential'; break }
            '^(System\.Security\.)?securestring$'               { 'Secret'; break }
            '^(switch|switchparameter|bool|boolean)$'           { 'Switch'; break }
            '^(int|int32|int64|long)$'                          { 'Int'; break }
            '^string\[\]$'                                      { 'List'; break }
            '^(hashtable|pscredential\[\]|.*\[\])$'             { 'Unsupported'; break }
            default                                             { 'Text' }
        }
        $Choices = @()
        $Vs = $Prm.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' } | Select-Object -First 1
        if ($Vs) { $Choices = @($Vs.PositionalArguments | ForEach-Object { "$($_.Value)" }); if ($Kind -eq 'Text') { $Kind = 'Choice' } }
        $Sets = @{}
        $PAttrs = @($Prm.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'Parameter' })
        if (-not $PAttrs) { $Sets['__All'] = $false }
        foreach ($A in $PAttrs) {
            $SetArg = $A.NamedArguments | Where-Object { $_.ArgumentName -eq 'ParameterSetName' } | Select-Object -First 1
            $Mand = $A.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' } | Select-Object -First 1
            $IsMand = [bool]$Mand -and ($Mand.ExpressionOmitted -or "$($Mand.Argument.Extent.Text)" -notmatch 'false')
            $Key = if ($SetArg) { "$($SetArg.Argument.Value)" } else { '__All' }
            $Sets[$Key] = $IsMand
        }
        $HelpText = ''
        if ($Help -and $Help.Parameters.ContainsKey($N.ToUpper())) { $HelpText = ($Help.Parameters[$N.ToUpper()] -replace '\s+', ' ').Trim() }
        [pscustomobject]@{
            Name = $N; Type = $TypeName; Kind = $Kind; Choices = $Choices; Sets = $Sets; Help = $HelpText
            Default = if ($Prm.DefaultValue) { "$($Prm.DefaultValue.Extent.Text)".Trim("'", '"') } else { '' }
        }
    })

    $SetNames = @($Params | ForEach-Object { $_.Sets.get_Keys() } | Where-Object { $_ -ne '__All' -and $_ -notmatch '^Deprecated' } | Select-Object -Unique)
    if (-not $SetNames) { $SetNames = @('Default') }
    if ($DefaultSet -and $SetNames -contains $DefaultSet) { $SetNames = @($DefaultSet) + @($SetNames | Where-Object { $_ -ne $DefaultSet }) }
    $Info = [pscustomobject]@{
        Name = $Name
        Sets = @(foreach ($S in $SetNames) {
            [pscustomobject]@{
                Name   = $S
                Params = @(foreach ($Prm in $Params) {
                    if (-not ($Prm.Sets.ContainsKey($S) -or $Prm.Sets.ContainsKey('__All'))) { continue }
                    $Mand = if ($Prm.Sets.ContainsKey($S)) { $Prm.Sets[$S] } else { $Prm.Sets['__All'] }
                    $Prm | Select-Object *, @{ n = 'Mandatory'; e = { [bool]$Mand } }
                })
            }
        })
    }
    $Script:PluginCache[$Name] = $Info
    $Info
}
#endregion

#region Controls helpers
$Font = New-Object System.Drawing.Font('Segoe UI', 9)
function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 130, [int]$H = 20)
    $L = New-Object System.Windows.Forms.Label
    $L.Text = $Text; $L.Location = New-Object System.Drawing.Point($X, ($Y + 3)); $L.Size = New-Object System.Drawing.Size($W, $H)
    $L
}
function New-TextBox {
    param([int]$X, [int]$Y, [int]$W, [switch]$Password)
    $T = New-Object System.Windows.Forms.TextBox
    $T.Location = New-Object System.Drawing.Point($X, $Y); $T.Size = New-Object System.Drawing.Size($W, 23)
    if ($Password) { $T.UseSystemPasswordChar = $true }
    $T
}
function New-Combo {
    param([int]$X, [int]$Y, [int]$W, [object[]]$Items = @())
    $C = New-Object System.Windows.Forms.ComboBox
    $C.DropDownStyle = 'DropDownList'
    $C.Location = New-Object System.Drawing.Point($X, $Y); $C.Size = New-Object System.Drawing.Size($W, 23)
    if ($Items) { [void]$C.Items.AddRange([object[]]$Items) }
    $C
}
function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 110)
    $B = New-Object System.Windows.Forms.Button
    $B.Text = $Text; $B.Location = New-Object System.Drawing.Point($X, $Y); $B.Size = New-Object System.Drawing.Size($W, 28)
    $B
}
function New-ListView {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [object[]]$Columns)
    $L = New-Object System.Windows.Forms.ListView
    $L.View = 'Details'; $L.FullRowSelect = $true; $L.HideSelection = $false; $L.MultiSelect = $false; $L.GridLines = $true
    $L.Location = New-Object System.Drawing.Point($X, $Y); $L.Size = New-Object System.Drawing.Size($W, $H)
    foreach ($C in $Columns) { [void]$L.Columns.Add($C[0], $C[1]) }
    $L
}
#endregion

#region Form
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "$AppTitle - $env:COMPUTERNAME"
$Form.Size = New-Object System.Drawing.Size(1120, 800)
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'FixedDialog'
$Form.MaximizeBox = $false
$Form.Font = $Font

$Tabs = New-Object System.Windows.Forms.TabControl
$Tabs.Location = New-Object System.Drawing.Point(8, 8)
$Tabs.Size = New-Object System.Drawing.Size(1090, 560)
$TabAccount = New-Object System.Windows.Forms.TabPage; $TabAccount.Text = 'Account'
$TabCerts   = New-Object System.Windows.Forms.TabPage; $TabCerts.Text = 'Certificates'
$TabIis     = New-Object System.Windows.Forms.TabPage; $TabIis.Text = 'IIS Deployments'
[void]$Tabs.TabPages.AddRange(@($TabAccount, $TabCerts, $TabIis))

$TxtLog = New-Object System.Windows.Forms.TextBox
$TxtLog.Multiline = $true; $TxtLog.ReadOnly = $true; $TxtLog.ScrollBars = 'Vertical'; $TxtLog.WordWrap = $true
$TxtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$TxtLog.Location = New-Object System.Drawing.Point(8, 574)
$TxtLog.Size = New-Object System.Drawing.Size(1090, 150)
$Status = New-Object System.Windows.Forms.StatusStrip
$StatusText = New-Object System.Windows.Forms.ToolStripStatusLabel
[void]$Status.Items.Add($StatusText)
$Form.Controls.AddRange(@($Tabs, $TxtLog, $Status))
$Tip = New-Object System.Windows.Forms.ToolTip

function Write-UiLog {
    param([string]$Text)
    $TxtLog.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Text) + "`r`n")
}
#endregion

#region Account tab
$CmbServer = New-Combo -X 160 -Y 16 -W 200 -Items @('LE_PROD', 'LE_STAGE')
$LblServerNote = New-Label -Text 'LE_PROD = real certificates (the renewal tasks use it). LE_STAGE = test certificates, for trying a new DNS plugin.' -X 370 -Y 16 -W 690
$LblHome = New-Label -Text "Posh-ACME data: $Script:PoshHome" -X 16 -Y 48 -W 1040
$LblUser = New-Label -Text '' -X 16 -Y 72 -W 1040 -H 40
$LstAccounts = New-ListView -X 16 -Y 120 -W 1050 -H 220 -Columns @(@('Current', 60), @('Account ID', 180), @('Status', 90), @('Contact', 360), @('Key', 90), @('Location', 250))
$TxtContact = New-TextBox -X 160 -Y 356 -W 360
$CmbAcctKey = New-Combo -X 640 -Y 356 -W 110 -Items @('ec-256', 'ec-384', '2048', '3072', '4096')
$BtnAcctNew     = New-Button -Text 'Create account' -X 16  -Y 396 -W 140
$BtnAcctContact = New-Button -Text 'Update contact' -X 166 -Y 396 -W 140
$BtnAcctSwitch  = New-Button -Text 'Make current'   -X 316 -Y 396 -W 140
$BtnAcctRefresh = New-Button -Text 'Refresh'        -X 466 -Y 396 -W 140
$LblAcctHelp = New-Label -Text ("One account per Let's Encrypt server is enough; every certificate of this server is ordered with the current account. " +
    'The contact e-mail gets Let''s Encrypt expiry and policy notices (optional; separate several with commas).') -X 16 -Y 440 -W 1040 -H 40
$LblAcctHelp.ForeColor = [System.Drawing.Color]::DimGray
$CmbAcctKey.SelectedItem = $Opt.AccountKeyLength
$TabAccount.Controls.AddRange(@(
    (New-Label "Let's Encrypt server:" 16 16 140), $CmbServer, $LblServerNote, $LblHome, $LblUser, $LstAccounts,
    (New-Label 'Contact e-mail:' 16 356 140), $TxtContact, (New-Label 'Account key:' 540 356 100), $CmbAcctKey,
    $BtnAcctNew, $BtnAcctContact, $BtnAcctSwitch, $BtnAcctRefresh, $LblAcctHelp
))
if ($WrongUser) {
    $LblUser.Text = "You are $Me, but the renewal tasks run as $RunAs. DNS settings you enter now would be encrypted for $Me and the nightly renewal could not read them. Log on as $RunAs to add or change DNS settings."
    $LblUser.ForeColor = [System.Drawing.Color]::Firebrick
}
else { $LblUser.Text = "Running as $Me$(if ($RunAs) { ' (the account the renewal tasks use)' })." }
#endregion

#region Certificates tab
$LstCerts = New-ListView -X 8 -Y 8 -W 1066 -H 440 -Columns @(@('Main name', 230), @('Other names', 200), @('Status', 70), @('Expires', 90), @('Renew after', 90), @('DNS plugin', 120), @('Thumbprint', 110), @('Used by', 150))
$BtnCertNew     = New-Button -Text 'New...'          -X 8   -Y 458
$BtnCertRenew   = New-Button -Text 'Renew now'       -X 124 -Y 458
$BtnCertDns     = New-Button -Text 'DNS settings...' -X 240 -Y 458
$BtnCertAssign  = New-Button -Text 'Assign to IIS'   -X 356 -Y 458
$BtnCertRemove  = New-Button -Text 'Remove...'       -X 472 -Y 458
$BtnCertFolder  = New-Button -Text 'Open folder'     -X 588 -Y 458
$BtnCertRefresh = New-Button -Text 'Refresh'         -X 704 -Y 458
$LblCertHelp = New-Label -Text 'Renewals happen automatically (nightly task) 30 days before expiry. A renewed certificate reaches IIS / Exchange through the role''s task or its Deploy.' -X 8 -Y 494 -W 1060
$LblCertHelp.ForeColor = [System.Drawing.Color]::DimGray
$TabCerts.Controls.AddRange(@($LstCerts, $BtnCertNew, $BtnCertRenew, $BtnCertDns, $BtnCertAssign, $BtnCertRemove, $BtnCertFolder, $BtnCertRefresh, $LblCertHelp))
#endregion

#region IIS Deployments tab
# One row per HTTPS binding in IIS (plus mapped bindings IIS no longer has). Bindings themselves are
# created and removed in IIS Manager; this tab only chooses the certificate each one gets.
$GridMap = New-Object System.Windows.Forms.DataGridView
$GridMap.Location = New-Object System.Drawing.Point(8, 8); $GridMap.Size = New-Object System.Drawing.Size(1066, 420)
$GridMap.AllowUserToAddRows = $false; $GridMap.AllowUserToDeleteRows = $false; $GridMap.RowHeadersVisible = $false
$GridMap.AutoSizeColumnsMode = 'Fill'; $GridMap.SelectionMode = 'FullRowSelect'; $GridMap.MultiSelect = $false
$ColSite   = New-Object System.Windows.Forms.DataGridViewTextBoxColumn;  $ColSite.HeaderText = 'IIS site'; $ColSite.Name = 'Site'; $ColSite.FillWeight = 15; $ColSite.ReadOnly = $true
$ColBind   = New-Object System.Windows.Forms.DataGridViewTextBoxColumn;  $ColBind.HeaderText = 'Binding (IP:port:host)'; $ColBind.Name = 'Binding'; $ColBind.FillWeight = 24; $ColBind.ReadOnly = $true
$ColSni    = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $ColSni.HeaderText = 'SNI'; $ColSni.Name = 'Sni'; $ColSni.FillWeight = 4; $ColSni.ReadOnly = $true
$ColNow    = New-Object System.Windows.Forms.DataGridViewTextBoxColumn;  $ColNow.HeaderText = 'Certificate in IIS now'; $ColNow.Name = 'Now'; $ColNow.FillWeight = 22; $ColNow.ReadOnly = $true
$ColCert   = New-Object System.Windows.Forms.DataGridViewComboBoxColumn; $ColCert.HeaderText = 'Let''s Encrypt certificate'; $ColCert.Name = 'Cert'; $ColCert.FillWeight = 20; $ColCert.FlatStyle = 'Flat'
$ColStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn;  $ColStatus.HeaderText = 'Status'; $ColStatus.Name = 'Status'; $ColStatus.FillWeight = 15; $ColStatus.ReadOnly = $true
[void]$GridMap.Columns.AddRange($ColSite, $ColBind, $ColSni, $ColNow, $ColCert, $ColStatus)
$GridMap.Add_DataError({ $_.ThrowException = $false })
$BtnMapSave    = New-Button -Text 'Save'            -X 8   -Y 438
$BtnMapDeploy  = New-Button -Text 'Deploy selected' -X 124 -Y 438 -W 130
$BtnMapAll     = New-Button -Text 'Deploy all'      -X 260 -Y 438
$BtnMapReload  = New-Button -Text 'Reload'          -X 376 -Y 438
$BtnMapFolder  = New-Button -Text 'Open folder'     -X 492 -Y 438
$BtnMapInetMgr = New-Button -Text 'IIS Manager'     -X 608 -Y 438
$LblMapHelp = New-Label -Text ("Choose the Let's Encrypt certificate for each HTTPS binding; (none) = not managed (the binding keeps whatever certificate it has). " +
    'Save writes IisCertificates.json (previous version kept in Backups). Deploy runs Renew-IisLE.ps1 -DeployCurrent in a console window. ' +
    'Bindings are added or removed in IIS Manager; then Reload.') -X 8 -Y 474 -W 1066 -H 48
$LblMapHelp.ForeColor = [System.Drawing.Color]::DimGray
$LblNoIis = New-Label -Text '' -X 16 -Y 16 -W 1040 -H 60
if ($Script:HaveIis) {
    $TabIis.Controls.AddRange(@($GridMap, $BtnMapSave, $BtnMapDeploy, $BtnMapAll, $BtnMapReload, $BtnMapFolder, $BtnMapInetMgr, $LblMapHelp))
}
else {
    $LblNoIis.Text = "The IIS role (PoshAcmeIisServer) is not on this server, or IIS / WebAdministration is missing.`r`nCopy PoshAcmeIisServer with SetupApplications to manage IIS bindings here."
    $TabIis.Controls.Add($LblNoIis)
}
#endregion

#region Background work (Let's Encrypt calls)
$Script:Job = $null
$BusyButtons = @($BtnAcctNew, $BtnAcctContact, $BtnAcctSwitch, $BtnAcctRefresh, $CmbServer, $BtnCertNew, $BtnCertRenew, $BtnCertDns, $BtnCertRemove, $BtnCertRefresh, $BtnMapReload)
function Set-Busy {
    param([bool]$Busy, [string]$Text = '')
    foreach ($B in $BusyButtons) { $B.Enabled = -not $Busy }
    $Form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::AppStarting } else { [System.Windows.Forms.Cursors]::Default }
    $StatusText.Text = $Text
}
$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 500

function Send-JobStream {
    param($J)
    $S = $J.Ps.Streams
    while ($J.V -lt $S.Verbose.Count)     { Write-UiLog "  $($S.Verbose[$J.V].Message)"; $J.V = $J.V + 1 }
    while ($J.I -lt $S.Information.Count) { Write-UiLog "  $($S.Information[$J.I].MessageData)"; $J.I = $J.I + 1 }
    while ($J.W -lt $S.Warning.Count)     { Write-UiLog "  WARNING: $($S.Warning[$J.W].Message)"; $J.W = $J.W + 1 }
}

# Runs $Body (script text with a param block) in its own runspace with Posh-ACME loaded and the
# chosen server set; $OnDone gets (results, error message) back on the UI thread.
function Start-Work {
    param([string]$Title, [string]$Body, [hashtable]$Arguments = @{}, [scriptblock]$OnDone, [hashtable]$Context = @{})
    if ($Script:Job) { [void](Show-Message 'Wait for the running task to finish.'); return }
    Write-UiLog "$Title ..."
    $Wrapper = {
        param($PoshHome, $Server, $Body, $A)
        $ErrorActionPreference = 'Stop'
        $VerbosePreference = 'Continue'
        $env:POSHACME_HOME = $PoshHome
        Import-Module Posh-ACME -Verbose:$false
        Set-PAServer $Server -Verbose:$false
        & ([scriptblock]::Create($Body)) @A
    }
    $Ps = [powershell]::Create()
    [void]$Ps.AddScript($Wrapper.ToString()).AddArgument($Script:PoshHome).AddArgument($Script:ServerName).AddArgument($Body).AddArgument($Arguments)
    $In  = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $Out = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $Script:Job = [pscustomobject]@{ Ps = $Ps; Out = $Out; Handle = $Ps.BeginInvoke($In, $Out); Title = $Title; OnDone = $OnDone; Context = $Context; V = 0; I = 0; W = 0 }
    Set-Busy $true "$Title ..."
    $Timer.Start()
}

$Timer.Add_Tick({
    $J = $Script:Job
    if (-not $J) { $Timer.Stop(); return }
    Send-JobStream $J
    if (-not $J.Handle.IsCompleted) { return }
    $Timer.Stop()
    $Err = ''
    try { [void]$J.Ps.EndInvoke($J.Handle) }
    catch { $E = $_.Exception; while ($E.InnerException) { $E = $E.InnerException }; $Err = $E.Message }
    Send-JobStream $J
    if (-not $Err -and $J.Ps.Streams.Error.Count) { $Err = ($J.Ps.Streams.Error | ForEach-Object { $_.Exception.Message }) -join ' | ' }
    $Results = @($J.Out)
    $J.Ps.Dispose()
    $Script:Job = $null
    Set-Busy $false
    if ($Err) { Write-UiLog "$($J.Title) FAILED: $Err"; Write-ActionLog "$($J.Title) failed: $Err" -LogType ERROR }
    else { Write-UiLog "$($J.Title): done." }
    if ($J.OnDone) { & $J.OnDone $Results $Err $J.Context }
})
#endregion

#region Data
$Script:ServerName = 'LE_PROD'
$Script:Account = $null
$Script:Orders = @()
$Script:Certs = @{}
$Script:MapEntries = @()
$Script:MapPath = ''
$Script:MapKeep = 30
$Script:MapDirty = $false
$Script:Loading = $false
$Script:Live = @()

function Update-PoshAcmeData {
    # Reload the module so state changed by background runspaces is read from disk again
    Import-Module Posh-ACME -Force -ErrorAction Stop
    Set-PAServer $Script:ServerName
    $Script:Account = Get-PAAccount
    $Script:Accounts = @(Get-PAAccount -List)
    $Script:Orders = @(if ($Script:Account) { Get-PAOrder -List })
    $Script:Certs = @{}
    foreach ($O in $Script:Orders) { $C = Get-PACertificate -MainDomain $O.MainDomain -ErrorAction SilentlyContinue; if ($C) { $Script:Certs[$O.MainDomain] = $C } }
}

function Show-Accounts {
    $LstAccounts.Items.Clear()
    foreach ($A in $Script:Accounts) {
        $Cur = $Script:Account -and $A.id -eq $Script:Account.id
        $I = New-Object System.Windows.Forms.ListViewItem($(if ($Cur) { 'yes' } else { '' }))
        [void]$I.SubItems.Add("$($A.id)"); [void]$I.SubItems.Add("$($A.status)")
        [void]$I.SubItems.Add((@($A.contact) | ForEach-Object { "$_" -replace '^mailto:', '' }) -join ', ')
        [void]$I.SubItems.Add("$($A.KeyLength)"); [void]$I.SubItems.Add("$($A.location)")
        $I.Tag = $A
        if ($Cur) { $I.Font = New-Object System.Drawing.Font($Font, [System.Drawing.FontStyle]::Bold) }
        [void]$LstAccounts.Items.Add($I)
    }
    if ($Script:Account) { $TxtContact.Text = (@($Script:Account.contact) | ForEach-Object { "$_" -replace '^mailto:', '' }) -join ', ' }
    $TabCerts.Text = if ($Script:Account) { "Certificates ($($Script:Orders.Count))" } else { 'Certificates' }
}

function Get-UsedBy {
    param([string]$MainDomain)
    $U = @()
    $E = $Script:MapEntries | Where-Object { $_.MainDomain -eq $MainDomain } | Select-Object -First 1
    if ($E) { $U += "IIS: $((@($E.Bindings) | ForEach-Object { $_.SiteName } | Select-Object -Unique) -join ', ')$(if (-not $E.Enabled) { ' (disabled)' })" }
    if ($HaveExchange -and $MainDomain -eq $ExchangeDomain) { $U += 'Exchange' }
    $U -join '; '
}

function Show-Certs {
    $Sel = if ($LstCerts.SelectedItems.Count) { $LstCerts.SelectedItems[0].Tag.MainDomain } else { '' }
    $LstCerts.Items.Clear()
    foreach ($O in $Script:Orders | Sort-Object MainDomain) {
        $C = $Script:Certs[$O.MainDomain]
        $I = New-Object System.Windows.Forms.ListViewItem("$($O.MainDomain)")
        [void]$I.SubItems.Add((@($O.SANs) | Where-Object { $_ -and $_ -ne $O.MainDomain }) -join ', ')
        [void]$I.SubItems.Add("$($O.status)")
        [void]$I.SubItems.Add($(if ($C) { $C.NotAfter.ToString('yyyy-MM-dd') } else { '' }))
        [void]$I.SubItems.Add($(if ($O.RenewAfter) { ([datetime]$O.RenewAfter).ToString('yyyy-MM-dd') } else { '' }))
        [void]$I.SubItems.Add((@($O.Plugin) | Select-Object -Unique) -join ', ')
        [void]$I.SubItems.Add($(if ($C) { "$($C.Thumbprint)".Substring(0, 12) + '...' } else { '' }))
        [void]$I.SubItems.Add((Get-UsedBy $O.MainDomain))
        $I.Tag = $O
        if ($C -and $C.NotAfter -lt (Get-Date).AddDays(14)) { $I.ForeColor = [System.Drawing.Color]::Firebrick }
        elseif ("$($O.status)" -ne 'valid') { $I.ForeColor = [System.Drawing.Color]::DarkOrange }
        [void]$LstCerts.Items.Add($I)
        if ($O.MainDomain -eq $Sel) { $I.Selected = $true }
    }
    if (-not $Script:Account) { $StatusText.Text = "No account for $Script:ServerName yet: create one on the Account tab." }
}

function Update-All {
    try {
        Update-PoshAcmeData
        if ($Script:HaveIis -and -not $Script:MapDirty) { Read-Map }
        Show-Accounts
        Show-Certs
        if ($Script:HaveIis) { if ($Script:MapDirty) { Add-CertChoices } else { Show-Map } }
        $StatusText.Text = "$Script:ServerName - account $(if ($Script:Account) { $Script:Account.id } else { '(none)' }) - $($Script:Orders.Count) certificate(s)"
    }
    catch { Write-UiLog "Refresh failed: $($_.Exception.Message)" }
}
#endregion

#region IIS mapping
$NoCert = '(none)'

function Read-Map {
    $C = Get-IisCertificateConfig -ApplicationPath $IisRole
    $Script:MapPath = $C.DeploymentsPath
    $Script:MapKeep = $C.KeepBackups
    $Script:MapEntries = @($C.Certificates)
    $Script:Live = @(Get-IisHttpsBinding)
    $Script:MapDirty = $false
}

# Certificate (MainDomain) a binding has in the saved mapping, or ''
function Get-MappedCert {
    param([string]$Site, [string]$Key)
    foreach ($E in $Script:MapEntries) { if (@($E.Bindings) | Where-Object { $_.SiteName -eq $Site -and $_.Key -eq $Key }) { return $E.MainDomain } }
    ''
}

function Add-CertChoices {
    $Names = @($Script:Orders | ForEach-Object { "$($_.MainDomain)" }) + @($Script:MapEntries | ForEach-Object { $_.MainDomain }) | Select-Object -Unique | Sort-Object
    foreach ($N in @($NoCert) + @($Names)) { if (-not $ColCert.Items.Contains($N)) { [void]$ColCert.Items.Add($N) } }
}

function Update-RowStatus {
    param($Row)
    $T = $Row.Tag
    $Cert = "$($Row.Cells['Cert'].Value)"
    $C = if ($Cert -and $Cert -ne $NoCert) { $Script:Certs[$Cert] } else { $null }
    $Text, $Color = if (-not $Cert -or $Cert -eq $NoCert) {
        if ($T.Mapped) { 'unmanaged after Save', [System.Drawing.Color]::DarkOrange } else { 'not managed', [System.Drawing.Color]::Gray }
    }
    elseif (-not $C) { 'no Posh-ACME certificate', [System.Drawing.Color]::Firebrick }
    elseif (-not $T.InIis) { 'not in IIS (deploy creates it)', [System.Drawing.Color]::Firebrick }
    elseif ($T.Thumbprint -eq "$($C.Thumbprint)".ToUpper()) { 'current', [System.Drawing.Color]::DarkGreen }
    else { 'deploy needed', [System.Drawing.Color]::DarkOrange }
    if ($Cert -and $Cert -ne $T.Mapped -and -not ($Cert -eq $NoCert -and -not $T.Mapped)) { $Text = "$Text *" }
    $Row.Cells['Status'].Value = $Text
    $Row.Cells['Status'].Style.ForeColor = $Color
}

function Show-Map {
    $Script:Loading = $true
    Add-CertChoices
    $GridMap.Rows.Clear()
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($L in $Script:Live) {
        $Rows.Add([pscustomobject]@{ SiteName = $L.SiteName; IPAddress = $L.IPAddress; Port = $L.Port; HostHeader = $L.HostHeader; RequireSNI = [bool]$L.RequireSNI; Key = $L.Key
            InIis = $true; Thumbprint = "$($L.Thumbprint)"; Mapped = (Get-MappedCert $L.SiteName $L.Key)
            Now = if (-not $L.Thumbprint) { 'none' } else { "$($L.CertSubject -replace '^CN=', '' -replace ',.*$', '')$(if ($L.CertNotAfter) { ', expires ' + ([datetime]$L.CertNotAfter).ToString('yyyy-MM-dd') })$(if (-not $L.CertInStore) { ' (NOT IN STORE)' })" } })
    }
    foreach ($E in $Script:MapEntries) {
        foreach ($B in @($E.Bindings)) {
            if ($Script:Live | Where-Object { $_.SiteName -eq $B.SiteName -and $_.Key -eq $B.Key }) { continue }
            $Rows.Add([pscustomobject]@{ SiteName = $B.SiteName; IPAddress = $B.IPAddress; Port = $B.Port; HostHeader = $B.HostHeader; RequireSNI = [bool]$B.RequireSNI; Key = $B.Key
                InIis = $false; Thumbprint = ''; Mapped = $E.MainDomain; Now = '(binding not in IIS)' })
        }
    }
    foreach ($T in $Rows | Sort-Object SiteName, Port, HostHeader) {
        $i = $GridMap.Rows.Add($T.SiteName, $T.Key, $T.RequireSNI, $T.Now, $(if ($T.Mapped) { $T.Mapped } else { $NoCert }), '')
        $GridMap.Rows[$i].Tag = $T
        if (-not $T.InIis) { $GridMap.Rows[$i].DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose }
        Update-RowStatus $GridMap.Rows[$i]
    }
    $TabIis.Text = 'IIS Deployments'
    $Script:Loading = $false
}

function Set-MapDirty { if (-not $Script:Loading) { $Script:MapDirty = $true; $TabIis.Text = 'IIS Deployments *' } }

function Save-Map {
    [void]$GridMap.EndEdit()
    $New = [ordered]@{}
    $Changes = New-Object System.Collections.Generic.List[string]
    foreach ($R in $GridMap.Rows) {
        $T = $R.Tag
        $Cert = "$($R.Cells['Cert'].Value)"; if ($Cert -eq $NoCert) { $Cert = '' }
        if ($Cert -ne $T.Mapped) { $Changes.Add("$($T.SiteName) $($T.Key): $(if ($T.Mapped) { $T.Mapped } else { $NoCert }) -> $(if ($Cert) { $Cert } else { $NoCert })") }
        if (-not $Cert) { continue }
        if (-not $New.Contains($Cert)) { $New[$Cert] = New-Object System.Collections.Generic.List[object] }
        $New[$Cert].Add([pscustomobject]@{ SiteName = $T.SiteName; IPAddress = $T.IPAddress; Port = $T.Port; HostHeader = $T.HostHeader; RequireSNI = $T.RequireSNI; Key = $T.Key })
    }
    if (-not $Changes.Count) { Write-UiLog 'IIS mapping: nothing changed.'; $Script:MapDirty = $false; $TabIis.Text = 'IIS Deployments'; return $true }
    $Missing = @($New.Keys | Where-Object { -not $Script:Certs[$_] })
    $Msg = "Save these changes to IisCertificates.json?`r`n`r`n  $(($Changes | Select-Object -First 15) -join "`r`n  ")$(if ($Changes.Count -gt 15) { "`r`n  ... and $($Changes.Count - 15) more" })" +
        $(if ($Missing) { "`r`n`r`nNo Posh-ACME certificate yet for: $($Missing -join ', ') (the nightly task reports an error until it is requested)." } else { '' }) +
        "`r`n`r`n(none) only stops the renewal from managing a binding; IIS keeps its current certificate."
    if ((Show-Message $Msg 'Question' 'YesNo') -ne 'Yes') { return $false }
    $Entries = @(foreach ($Main in @($New.Keys)) {
        $Old = $Script:MapEntries | Where-Object { $_.MainDomain -eq $Main } | Select-Object -First 1
        $O = $Script:Orders | Where-Object { $_.MainDomain -eq $Main } | Select-Object -First 1
        $Names = if ($O) { @(@($O.MainDomain) + @($O.SANs) | Where-Object { $_ } | ForEach-Object { "$_".ToLower() } | Select-Object -Unique) } elseif ($Old) { @($Old.Names) } else { @($Main) }
        $Enabled = $true; if ($Old) { $Enabled = [bool]$Old.Enabled }
        $Bindings = $New[$Main].ToArray()
        [pscustomobject]@{ MainDomain = $Main; Names = $Names; Enabled = $Enabled; Bindings = $Bindings }
    })
    try {
        Save-IisCertificateConfig -Certificates $Entries -Path $Script:MapPath -KeepBackups $Script:MapKeep
        Write-UiLog "Saved $Script:MapPath ($($Entries.Count) certificate(s)): $($Changes -join '; ')"
        Write-ActionLog "IIS mapping saved: $($Changes -join '; ')"
        Read-Map
        Show-Map
        Show-Certs
        return $true
    }
    catch { [void](Show-Message "Save failed: $($_.Exception.Message)" 'Error'); return $false }
}

function Start-Deploy {
    param([string]$MainDomain)
    if ($Script:MapDirty) {
        $A = Show-Message 'Save the changes first?' 'Question' 'YesNoCancel'
        if ($A -eq 'Cancel') { return }
        if ($A -eq 'Yes' -and -not (Save-Map)) { return }
    }
    $Renew = Join-Path -Path $IisRole -ChildPath 'Renew-IisLE.ps1'
    $ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$Renew`"", '-DeployCurrent')
    if ($MainDomain) { $ArgList += @('-MainDomain', $MainDomain) }
    Start-Process -FilePath powershell.exe -ArgumentList $ArgList
    Write-UiLog "Started Renew-IisLE.ps1 -DeployCurrent$(if ($MainDomain) { " -MainDomain $MainDomain" }) in a console window. Reload afterwards to see the bindings."
    Write-ActionLog "Deploy started: Renew-IisLE.ps1 -DeployCurrent $MainDomain"
}
#endregion

#region DNS settings dialog
# Returns @{ Names; CopyFrom; Plugin; PluginArgs; DnsSleep } or $null
function Show-DnsDialog {
    param([string]$Title, [string]$Names = '', [bool]$NamesEditable = $true, [string]$Plugin = '')
    $D = @{ Fields = New-Object System.Collections.Generic.List[object]; Result = $null }
    $Dlg = New-Object System.Windows.Forms.Form
    $Dlg.Text = $Title; $Dlg.Size = New-Object System.Drawing.Size(760, 680); $Dlg.StartPosition = 'CenterParent'
    $Dlg.FormBorderStyle = 'FixedDialog'; $Dlg.MaximizeBox = $false; $Dlg.MinimizeBox = $false; $Dlg.Font = $Font

    $TxtNames = New-TextBox -X 150 -Y 12 -W 580
    $TxtNames.Text = $Names; $TxtNames.ReadOnly = -not $NamesEditable
    $Tip.SetToolTip($TxtNames, 'DNS names on the certificate, separated by commas. The first is the main name. *.example.com for a wildcard.')
    $Sources = @($Script:Orders | Where-Object { $_.Plugin } | Sort-Object MainDomain)
    $RadCopy = New-Object System.Windows.Forms.RadioButton
    $RadCopy.Text = 'Use the DNS settings already saved with:'; $RadCopy.Location = New-Object System.Drawing.Point(12, 48); $RadCopy.Size = New-Object System.Drawing.Size(290, 24)
    $CmbCopy = New-Combo -X 310 -Y 48 -W 420 -Items @($Sources | ForEach-Object { '{0}   ({1})' -f $_.MainDomain, ((@($_.Plugin) | Select-Object -Unique) -join ',') })
    $RadEnter = New-Object System.Windows.Forms.RadioButton
    $RadEnter.Text = 'Enter DNS provider settings:'; $RadEnter.Location = New-Object System.Drawing.Point(12, 80); $RadEnter.Size = New-Object System.Drawing.Size(290, 24)
    $CmbPlugin = New-Combo -X 150 -Y 112 -W 250 -Items $DnsPlugins
    $CmbSet = New-Combo -X 520 -Y 112 -W 210
    $Pnl = New-Object System.Windows.Forms.Panel
    $Pnl.Location = New-Object System.Drawing.Point(12, 148); $Pnl.Size = New-Object System.Drawing.Size(718, 340); $Pnl.AutoScroll = $true; $Pnl.BorderStyle = 'FixedSingle'
    $NumSleep = New-Object System.Windows.Forms.NumericUpDown
    $NumSleep.Location = New-Object System.Drawing.Point(230, 500); $NumSleep.Size = New-Object System.Drawing.Size(80, 23); $NumSleep.Minimum = 0; $NumSleep.Maximum = 1800; $NumSleep.Value = $Opt.DnsSleep
    $LblNote = New-Label -Text ("Secrets are passed to Posh-ACME, which saves them with the order encrypted for $Me; they are reused on every renewal and never written to this application's files or logs." +
        $(if ($WrongUser) { "`r`nWARNING: the renewal tasks run as $RunAs and will not be able to read settings saved by $Me." } else { '' })) -X 12 -Y 532 -W 718 -H 56
    $LblNote.ForeColor = if ($WrongUser) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DimGray }
    $BtnOk = New-Button -Text 'OK' -X 520 -Y 596; $BtnCancel = New-Button -Text 'Cancel' -X 636 -Y 596 -W 94
    $Dlg.AcceptButton = $BtnOk; $Dlg.CancelButton = $BtnCancel
    $Dlg.Controls.AddRange(@((New-Label 'DNS names:' 12 12 130), $TxtNames, $RadCopy, $CmbCopy, $RadEnter,
        (New-Label 'DNS plugin:' 32 112 110), $CmbPlugin, (New-Label 'Login method:' 410 112 105), $CmbSet, $Pnl,
        (New-Label 'Wait for DNS to update (seconds):' 12 500 215), $NumSleep, $LblNote, $BtnOk, $BtnCancel))

    $BuildFields = {
        $Pnl.Controls.Clear(); $D.Fields.Clear()
        if (-not $CmbPlugin.SelectedItem -or -not $CmbSet.SelectedItem) { return }
        $Info = Get-PluginInfo "$($CmbPlugin.SelectedItem)"
        $Set = $Info.Sets | Where-Object { $_.Name -eq "$($CmbSet.SelectedItem)" } | Select-Object -First 1
        $Y = 8
        if (-not @($Set.Params).Count) { $Pnl.Controls.Add((New-Label 'This plugin needs no settings.' 8 $Y 600)); return }
        foreach ($Prm in $Set.Params) {
            $Lbl = New-Label -Text ($Prm.Name + $(if ($Prm.Mandatory) { ' *' })) -X 8 -Y $Y -W 200
            $Pnl.Controls.Add($Lbl)
            $C1 = $null; $C2 = $null
            switch ($Prm.Kind) {
                'Credential' {
                    $C1 = New-TextBox -X 215 -Y $Y -W 220; $C2 = New-TextBox -X 445 -Y $Y -W 240 -Password
                    $Tip.SetToolTip($C1, 'User name'); $Tip.SetToolTip($C2, 'Password')
                }
                'Secret' { $C1 = New-TextBox -X 215 -Y $Y -W 470 -Password }
                'Switch' {
                    $C1 = New-Object System.Windows.Forms.CheckBox; $C1.Location = New-Object System.Drawing.Point(215, $Y); $C1.Size = New-Object System.Drawing.Size(470, 24)
                    if ($Prm.Mandatory) { $C1.Checked = $true; $C1.Enabled = $false; $C1.Text = '(required by this login method)' }
                }
                'Choice' { $C1 = New-Combo -X 215 -Y $Y -W 250 -Items (@('') + $Prm.Choices) }
                'Unsupported' {
                    $C1 = New-Label -Text "($($Prm.Type): not supported here; use New-PACertificate in PowerShell)" -X 215 -Y $Y -W 470
                    $C1.ForeColor = [System.Drawing.Color]::DimGray
                }
                default {
                    $C1 = New-TextBox -X 215 -Y $Y -W 470
                    if ($Prm.Kind -eq 'List') { $Tip.SetToolTip($C1, 'Several values: separate with commas.') }
                }
            }
            $Pnl.Controls.Add($C1); if ($C2) { $Pnl.Controls.Add($C2) }
            $Hint = @($Prm.Help, $(if ($Prm.Default) { "Default: $($Prm.Default)" })) | Where-Object { $_ }
            if ($Hint) { $Tip.SetToolTip($Lbl, ($Hint -join "`r`n")); if ($Prm.Kind -ne 'Credential') { $Tip.SetToolTip($C1, ($Hint -join "`r`n")) } }
            $D.Fields.Add([pscustomobject]@{ Param = $Prm; C1 = $C1; C2 = $C2 })
            $Y += 32
        }
    }
    $CmbPlugin.Add_SelectedIndexChanged({
        $CmbSet.Items.Clear()
        $Info = Get-PluginInfo "$($CmbPlugin.SelectedItem)"
        [void]$CmbSet.Items.AddRange([object[]]@($Info.Sets | ForEach-Object { $_.Name }))
        $CmbSet.SelectedIndex = 0
    })
    $CmbSet.Add_SelectedIndexChanged($BuildFields)
    $SetMode = { $Copy = $RadCopy.Checked; $CmbCopy.Enabled = $Copy; $CmbPlugin.Enabled = -not $Copy; $CmbSet.Enabled = -not $Copy; $Pnl.Enabled = -not $Copy }
    $RadCopy.Add_CheckedChanged($SetMode); $RadEnter.Add_CheckedChanged($SetMode)

    $BtnOk.Add_Click({
        $NameList = @("$($TxtNames.Text)" -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() } | Select-Object -Unique)
        if (-not $NameList) { [void](Show-Message 'Enter at least one DNS name.' 'Warning'); return }
        $Bad = $NameList | Where-Object { $_ -notmatch '^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' }
        if ($Bad) { [void](Show-Message "Not a valid DNS name: $($Bad -join ', ')" 'Warning'); return }
        $R = @{ Names = $NameList; CopyFrom = ''; Plugin = ''; PluginArgs = @{}; DnsSleep = [int]$NumSleep.Value }
        if ($RadCopy.Checked) {
            if ($CmbCopy.SelectedIndex -lt 0) { [void](Show-Message 'Choose the certificate to copy the DNS settings from.' 'Warning'); return }
            $R.CopyFrom = "$($Sources[$CmbCopy.SelectedIndex].MainDomain)"
        }
        else {
            if (-not $CmbPlugin.SelectedItem) { [void](Show-Message 'Choose a DNS plugin.' 'Warning'); return }
            $R.Plugin = "$($CmbPlugin.SelectedItem)"
            foreach ($F in $D.Fields) {
                $Prm = $F.Param
                switch ($Prm.Kind) {
                    'Credential' {
                        $U = "$($F.C1.Text)".Trim(); $Pw = "$($F.C2.Text)"
                        if ($U -and $Pw) { $R.PluginArgs[$Prm.Name] = New-Object System.Management.Automation.PSCredential($U, (ConvertTo-SecureString -String $Pw -AsPlainText -Force)) }
                        elseif ($U -or $Pw) { [void](Show-Message "$($Prm.Name): enter both the user name and the password." 'Warning'); return }
                    }
                    'Secret' { if ("$($F.C1.Text)") { $R.PluginArgs[$Prm.Name] = ConvertTo-SecureString -String "$($F.C1.Text)" -AsPlainText -Force } }
                    'Switch' { if ($F.C1.Checked) { $R.PluginArgs[$Prm.Name] = $true } }
                    'Choice' { if ("$($F.C1.SelectedItem)") { $R.PluginArgs[$Prm.Name] = "$($F.C1.SelectedItem)" } }
                    'Int' {
                        $V = "$($F.C1.Text)".Trim()
                        if ($V -and $V -notmatch '^\d+$') { [void](Show-Message "$($Prm.Name) must be a number." 'Warning'); return }
                        if ($V) { $R.PluginArgs[$Prm.Name] = [int]$V }
                    }
                    'List' { $V = @("$($F.C1.Text)" -split '\s*,\s*' | Where-Object { $_ }); if ($V) { $R.PluginArgs[$Prm.Name] = [string[]]$V } }
                    'Unsupported' { }
                    default {
                        $V = "$($F.C1.Text)".Trim()
                        if ($V) { $R.PluginArgs[$Prm.Name] = if ($Prm.Type -match 'uri$') { [uri]$V } else { $V } }
                    }
                }
                if ($Prm.Mandatory -and -not $R.PluginArgs.ContainsKey($Prm.Name)) { [void](Show-Message "$($Prm.Name) is required for this login method." 'Warning'); return }
            }
        }
        $D.Result = $R
        $Dlg.DialogResult = 'OK'
        $Dlg.Close()
    })

    if ($Sources) { $RadCopy.Checked = $true; $CmbCopy.SelectedIndex = 0 } else { $RadCopy.Enabled = $false; $RadEnter.Checked = $true }
    $Start = if ($Plugin -and $DnsPlugins -contains $Plugin) { $Plugin } elseif ($DnsPlugins -contains $Opt.DefaultPlugin) { $Opt.DefaultPlugin } else { $DnsPlugins[0] }
    $CmbPlugin.SelectedItem = $Start
    if ($Plugin) { $RadEnter.Checked = $true }
    & $SetMode
    [void]$Dlg.ShowDialog($Form)
    foreach ($F in $D.Fields) { if ($F.C1 -is [System.Windows.Forms.TextBox]) { $F.C1.Clear() }; if ($F.C2 -is [System.Windows.Forms.TextBox]) { $F.C2.Clear() } }
    $Dlg.Dispose()
    $D.Result
}
#endregion

#region Events: Account
$CmbServer.Add_SelectedIndexChanged({
    if ($Script:Loading) { return }
    $Script:ServerName = "$($CmbServer.SelectedItem)"
    Write-UiLog "Let's Encrypt server: $Script:ServerName"
    Update-All
})
$BtnAcctRefresh.Add_Click({ Update-All })
$BtnAcctNew.Add_Click({
    $Contact = @("$($TxtContact.Text)" -split '[,;\s]+' | Where-Object { $_ })
    $Msg = "Create a new $Script:ServerName account$(if ($Contact) { " with contact $($Contact -join ', ')" })?`r`nBy creating it you accept the Let's Encrypt Subscriber Agreement."
    if ($Script:Account) { $Msg = "This server already has account $($Script:Account.id) on $Script:ServerName; a new one becomes the current account and existing certificates stay with the old one.`r`n`r`n$Msg" }
    if ((Show-Message $Msg 'Question' 'YesNo') -ne 'Yes') { return }
    Start-Work -Title "Create $Script:ServerName account" -Arguments @{ Contact = $Contact; KeyLength = "$($CmbAcctKey.SelectedItem)" } -Body {
        param($Contact, $KeyLength)
        $P = @{ AcceptTOS = $true; KeyLength = $KeyLength; Force = $true }
        if ($Contact) { $P.Contact = $Contact }
        New-PAAccount @P | Select-Object id, status
    }.ToString() -OnDone { param($R, $Err) if (-not $Err) { Write-ActionLog "Created $Script:ServerName account $($R[0].id)." }; Update-All }
})
$BtnAcctContact.Add_Click({
    if (-not $LstAccounts.SelectedItems.Count) { [void](Show-Message 'Select an account.'); return }
    $Id = "$($LstAccounts.SelectedItems[0].Tag.id)"
    $Contact = @("$($TxtContact.Text)" -split '[,;\s]+' | Where-Object { $_ })
    if (-not $Contact) { [void](Show-Message 'Enter the contact e-mail.'); return }
    Start-Work -Title "Update contact of account $Id" -Arguments @{ Id = $Id; Contact = $Contact } -Body {
        param($Id, $Contact)
        Set-PAAccount -ID $Id -Contact $Contact
    }.ToString() -Context @{ Id = $Id; Contact = $Contact } -OnDone { param($R, $Err, $C) if (-not $Err) { Write-ActionLog "Account $($C.Id) contact set to $($C.Contact -join ', ')." }; Update-All }
})
$BtnAcctSwitch.Add_Click({
    if (-not $LstAccounts.SelectedItems.Count) { [void](Show-Message 'Select an account.'); return }
    $Id = "$($LstAccounts.SelectedItems[0].Tag.id)"
    try { Set-PAAccount -ID $Id; Write-UiLog "Current account: $Id"; Write-ActionLog "Current $Script:ServerName account set to $Id." } catch { Write-UiLog "Failed: $($_.Exception.Message)" }
    Update-All
})
#endregion

#region Events: Certificates
function Get-SelectedOrder {
    if (-not $LstCerts.SelectedItems.Count) { [void](Show-Message 'Select a certificate.'); return $null }
    $LstCerts.SelectedItems[0].Tag
}
$BtnCertRefresh.Add_Click({ Update-All })
$BtnCertFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$Script:PoshHome`"" })
$BtnCertNew.Add_Click({
    if (-not $Script:Account) { [void](Show-Message "There is no $Script:ServerName account yet. Create it on the Account tab first." 'Warning'); return }
    $Fqdn = ('{0}.{1}' -f $env:COMPUTERNAME, (Get-CimInstance Win32_ComputerSystem).Domain).ToLower()
    $R = Show-DnsDialog -Title "New certificate ($Script:ServerName)" -Names $(if ($Script:Orders | Where-Object MainDomain -eq $Fqdn) { '' } else { $Fqdn })
    if (-not $R) { return }
    if ($Script:Orders | Where-Object { $_.MainDomain -eq $R.Names[0] }) {
        if ((Show-Message "$($R.Names[0]) already has a certificate. Replace its order with these names and settings?" 'Warning' 'YesNo') -ne 'Yes') { return }
    }
    $Via = if ($R.CopyFrom) { "the DNS settings of $($R.CopyFrom)" } else { "plugin $($R.Plugin)" }
    if ((Show-Message "Request a $Script:ServerName certificate for:`r`n  $($R.Names -join "`r`n  ")`r`n`r`nDNS validation with $Via. This takes a few minutes." 'Question' 'YesNo') -ne 'Yes') { return }
    Start-Work -Title "Request certificate $($R.Names[0])" -Arguments @{ Names = $R.Names; Plugin = $R.Plugin; PluginArgs = $R.PluginArgs; CopyFrom = $R.CopyFrom; DnsSleep = $R.DnsSleep; KeyLength = $Opt.CertKeyLength } -Body {
        param($Names, $Plugin, $PluginArgs, $CopyFrom, $DnsSleep, $KeyLength)
        if ($CopyFrom) {
            $Src = Get-PAOrder -MainDomain $CopyFrom
            $Plugin = @($Src.Plugin)[0]
            $PluginArgs = Get-PAPluginArgs -MainDomain $CopyFrom
            Write-Verbose "Using plugin $Plugin and the saved settings of $CopyFrom."
        }
        $C = New-PACertificate -Domain $Names -Plugin $Plugin -PluginArgs $PluginArgs -DnsSleep $DnsSleep -CertKeyLength $KeyLength -AcceptTOS -Force -Verbose
        if (-not $C) { throw "Let's Encrypt did not issue a certificate for $($Names -join ', ')." }
        $C | Select-Object Subject, Thumbprint, NotAfter
    }.ToString() -Context @{ R = $R } -OnDone {
        param($R2, $Err, $Ctx)
        $R = $Ctx.R
        if (-not $Err -and $R2) {
            $Msg = "Issued $($R.Names[0]): $($R2[0].Thumbprint), expires $($R2[0].NotAfter)$(if ($R.CopyFrom) { " (DNS settings of $($R.CopyFrom))" } else { " (plugin $($R.Plugin))" })."
            Write-UiLog $Msg; Write-ActionLog $Msg
        }
        Update-All
        if (-not $Err -and $Script:HaveIis -and -not ($Script:MapEntries | Where-Object MainDomain -eq $R.Names[0]) -and
            (Show-Message "Certificate issued. Assign $($R.Names[0]) to IIS bindings now?" 'Question' 'YesNo') -eq 'Yes') { Open-IisEntry $R.Names[0] }
    }
})
$BtnCertRenew.Add_Click({
    $O = Get-SelectedOrder; if (-not $O) { return }
    if ((Show-Message "Renew $($O.MainDomain) now (even though it is not due)? Let's Encrypt allows only a few renewals of the same names per week." 'Question' 'YesNo') -ne 'Yes') { return }
    $Main = "$($O.MainDomain)"
    Start-Work -Title "Renew $Main" -Arguments @{ MainDomain = $Main } -Body {
        param($MainDomain)
        $C = Submit-Renewal -MainDomain $MainDomain -Force -Verbose
        if (-not $C) { throw "No certificate came back for $MainDomain." }
        $C | Select-Object Subject, Thumbprint, NotAfter
    }.ToString() -Context @{ Main = $Main } -OnDone {
        param($R, $Err, $Ctx)
        $Main = $Ctx.Main
        if (-not $Err -and $R) { $Msg = "Renewed ${Main}: $($R[0].Thumbprint), expires $($R[0].NotAfter)."; Write-UiLog $Msg; Write-ActionLog $Msg }
        Update-All
        if (-not $Err) {
            if ($Script:HaveIis -and ($Script:MapEntries | Where-Object MainDomain -eq $Main)) {
                if ((Show-Message "Deploy the renewed $Main to its IIS bindings now?" 'Question' 'YesNo') -eq 'Yes') { Start-Deploy $Main }
            }
            elseif ($HaveExchange -and $Main -eq $ExchangeDomain) {
                [void](Show-Message "Exchange picks the new certificate up with: Renew-ExchangeLE.ps1 -DeployCurrent (ExchangeServer folder), or the nightly task.")
            }
        }
    }
})
$BtnCertDns.Add_Click({
    $O = Get-SelectedOrder; if (-not $O) { return }
    $Main = "$($O.MainDomain)"
    $R = Show-DnsDialog -Title "DNS settings of $Main" -Names ((@($O.MainDomain) + @($O.SANs) | Where-Object { $_ } | Select-Object -Unique) -join ', ') -NamesEditable $false -Plugin "$(@($O.Plugin)[0])"
    if (-not $R) { return }
    if ($R.CopyFrom -eq $Main) { [void](Show-Message 'That is this certificate''s own settings; nothing to change.'); return }
    Start-Work -Title "Change DNS settings of $Main" -Arguments @{ MainDomain = $Main; Plugin = $R.Plugin; PluginArgs = $R.PluginArgs; CopyFrom = $R.CopyFrom; DnsSleep = $R.DnsSleep } -Body {
        param($MainDomain, $Plugin, $PluginArgs, $CopyFrom, $DnsSleep)
        if ($CopyFrom) { $Plugin = @((Get-PAOrder -MainDomain $CopyFrom).Plugin)[0]; $PluginArgs = Get-PAPluginArgs -MainDomain $CopyFrom }
        Set-PAOrder -MainDomain $MainDomain -Plugin $Plugin -PluginArgs $PluginArgs -DnsSleep $DnsSleep
        Write-Verbose "Saved plugin $Plugin settings with $MainDomain; the next renewal uses them."
    }.ToString() -Context @{ R = $R; Main = $Main } -OnDone {
        param($R2, $Err, $Ctx)
        $R = $Ctx.R; $Main = $Ctx.Main
        if (-not $Err) { Write-ActionLog "DNS settings of $Main changed ($(if ($R.CopyFrom) { "copied from $($R.CopyFrom)" } else { "plugin $($R.Plugin)" }))." }
        Update-All
    }
})
$BtnCertAssign.Add_Click({
    $O = Get-SelectedOrder; if (-not $O) { return }
    if (-not $Script:HaveIis) { [void](Show-Message 'The IIS role is not on this server.'); return }
    Open-IisEntry "$($O.MainDomain)"
})
$BtnCertRemove.Add_Click({
    $O = Get-SelectedOrder; if (-not $O) { return }
    $Main = "$($O.MainDomain)"
    $Used = Get-UsedBy $Main
    $A = Show-Message ("Remove the certificate order $Main from Posh-ACME?$(if ($Used) { "`r`n`r`nIt is used by: $Used. Remove it from the IIS mapping first, or the nightly task reports errors." })" +
        "`r`n`r`nYes = remove and REVOKE the certificate (it stops working everywhere)`r`nNo = remove the order only (the certificate keeps working until it expires)`r`nCancel = do nothing") 'Warning' 'YesNoCancel'
    if ($A -eq 'Cancel') { return }
    $Revoke = $A -eq 'Yes'
    Start-Work -Title "Remove $Main$(if ($Revoke) { ' (revoke)' })" -Arguments @{ MainDomain = $Main; Revoke = $Revoke } -Body {
        param($MainDomain, $Revoke)
        Remove-PAOrder -MainDomain $MainDomain -RevokeCert:$Revoke -Force
    }.ToString() -Context @{ Main = $Main; Revoke = $Revoke } -OnDone { param($R, $Err, $C) $Main = $C.Main; $Revoke = $C.Revoke; if (-not $Err) { Write-ActionLog "Removed order $Main$(if ($Revoke) { ' and revoked its certificate' })." -LogType WARNING }; Update-All }
})
$LstCerts.Add_DoubleClick({ if ($Script:HaveIis -and $LstCerts.SelectedItems.Count) { Open-IisEntry "$($LstCerts.SelectedItems[0].Tag.MainDomain)" } })
#endregion

#region Events: IIS Deployments
# Show the IIS tab with the bindings of $MainDomain selected (or ask to choose them)
function Open-IisEntry {
    param([string]$MainDomain)
    $Tabs.SelectedTab = $TabIis
    $GridMap.ClearSelection()
    $First = $null
    foreach ($R in $GridMap.Rows) { if ("$($R.Cells['Cert'].Value)" -eq $MainDomain) { $R.Selected = $true; if (-not $First) { $First = $R } } }
    if ($First) { $GridMap.FirstDisplayedScrollingRowIndex = $First.Index }
    else { $StatusText.Text = "Choose $MainDomain in the certificate column of the binding(s) it should serve, then Save." }
}
$GridMap.Add_CurrentCellDirtyStateChanged({ if ($GridMap.IsCurrentCellDirty) { [void]$GridMap.CommitEdit('CurrentCellChange') } })
$GridMap.Add_CellValueChanged({
    if ($Script:Loading -or $_.RowIndex -lt 0 -or $GridMap.Columns[$_.ColumnIndex].Name -ne 'Cert') { return }
    Set-MapDirty
    Update-RowStatus $GridMap.Rows[$_.RowIndex]
})
$BtnMapSave.Add_Click({ [void](Save-Map) })
$BtnMapReload.Add_Click({
    if ($Script:MapDirty -and (Show-Message 'Discard the unsaved changes?' 'Question' 'YesNo') -ne 'Yes') { return }
    $Script:MapDirty = $false
    Update-All
})
$BtnMapDeploy.Add_Click({
    if (-not $GridMap.SelectedRows.Count) { [void](Show-Message 'Select a binding.'); return }
    $Cert = "$($GridMap.SelectedRows[0].Cells['Cert'].Value)"
    if (-not $Cert -or $Cert -eq $NoCert) { [void](Show-Message 'This binding has no Let''s Encrypt certificate chosen.'); return }
    Start-Deploy $Cert
})
$BtnMapAll.Add_Click({ Start-Deploy '' })
$BtnMapFolder.Add_Click({ $Dir = Split-Path -Path $Script:MapPath -Parent; if (-not (Test-Path $Dir)) { $Dir = Join-Path $IisRole 'Data' }; Start-Process explorer.exe -ArgumentList "`"$Dir`"" })
$BtnMapInetMgr.Add_Click({ Start-Process -FilePath (Join-Path $env:windir 'System32\inetsrv\InetMgr.exe') })
#endregion

#region Start
$Form.Add_FormClosing({
    if ($Script:Job -and (Show-Message 'A Let''s Encrypt task is still running. Close anyway?' 'Warning' 'YesNo') -ne 'Yes') { $_.Cancel = $true; return }
    if ($Script:MapDirty -and (Show-Message 'The IIS mapping has unsaved changes. Close without saving?' 'Warning' 'YesNo') -ne 'Yes') { $_.Cancel = $true; return }
    if ($Script:Job) { try { $Script:Job.Ps.Stop(); $Script:Job.Ps.Dispose() } catch { } }
})
$Form.Add_Shown({
    $Script:Loading = $true
    # Get-PAServer names the server by host (acme-v02... / acme-staging-v02...)
    try { $Cur = "$((Get-PAServer).Name) $((Get-PAServer).location)" } catch { $Cur = '' }
    $Script:ServerName = if ($Cur -match 'staging') { 'LE_STAGE' } else { 'LE_PROD' }
    $CmbServer.SelectedItem = $Script:ServerName
    $Script:Loading = $false
    Write-UiLog "Posh-ACME $((Get-Module Posh-ACME).Version), data in $Script:PoshHome, $($DnsPlugins.Count) DNS plugins."
    if ($WrongUser) { Write-UiLog "WARNING: running as $Me; the renewal tasks run as $RunAs." }
    Update-All
    if ($Script:Account -and $Script:Orders.Count) { $Tabs.SelectedTab = $TabCerts }
})
Write-ActionLog 'Opened.'
[void]$Form.ShowDialog()
$Timer.Dispose()
$Form.Dispose()
#endregion

# Example usage:
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Show-PoshAcmeCertificateManagement.ps1


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBipSdFhndGRLpm
# 18ApMMy4rRKOcZ0u3PJG+ttfExR2BqCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIJDE5q1l
# rsZJdRHw9nRjD/yACn7vO3vbGv5Z4CoavUKDMA0GCSqGSIb3DQEBAQUABIIBAKmW
# rc4DqO9CYTNyWXH5tJDlHC6cUbgZpxQh8BlPqL0QJ5izHivFR2XKzk87rQ1fwwVl
# jHn/JYHQoZbDTMe2VlBZcI66eW8JDBQb1ls8tj5HEIRlFCiCOulQTL2DfULNhEJj
# wM749lEonKX4lfnU/n8oS9F5NrqSbMAPEMectl7gSvIV4p/XPefXF4o4u5ccvsAS
# EHpeTyBtW0EGZnIQoMa/xAv7mVq/a3DNYfYDw3UUIFCAbK3Y8WMQuQJf4HYwqvRg
# NjiEMzITddUjDof3pO3sf42lB77D15Jjauz0YEsg9YYDW8vTMJyetfE05n0WhV9b
# 9KiT38F8M+ayXp4/HYKhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIyMTI0
# NzI0WjAvBgkqhkiG9w0BCQQxIgQglvXxBARuBRUXKUCB45Vlo5j+jrvD49KDAjNf
# b6VFhOkwDQYJKoZIhvcNAQEBBQAEggIAL/IJOKn2oKXIydNEX8RaOoHRNNa5AfdX
# oOSRnANYOahJK9J8Om1DCpUUI5sINygbntUdzB4Zj/b3Kd3u3OtCL/GoqyTMMzlf
# GklTXm+/T6/uP1NPvHphg0RjiPgG9yStT5bY7Gxt+6DcsxGZyJ14X9D8vzd10xSn
# zvMSn5djPaoTCzUhGpEh6uycb3gNLUlYYRrP/g+TLCCa4JdKuC0fRkLILA+5WRtv
# PnfIIRo6M5/TJVcnperhdeC/OQqMOZIZ14Abt+TyTVZHHCeagRwNdsy+UJpyoQAk
# p7FoOK9hsmYC0Y6XXPZzi58Ky+hhTNAKf2uuEvvAQKraClZaGlF/B4DatjOnjbbV
# kT+RbFToCv4yF0exgXjemk34Rkn8wV/SAPQXigRxdjiVuTC1SjYA1MGt4A8EIy34
# id2bEWOO1XNUKtAIrbpZ/GJClM4DnMWHrosXpw4c8A2hjMF/kN/ViROnaK93s2r+
# L+aGYdo9T3rDO2qgUcoRXSxf1TvUD+qC8L21zFMfSHDp5gWbOJwqMrVSjV1GRGxq
# ZPrAGM4Brjv7Ujg2lbc85rPU6gTPckcieIp8RYQ1oB3gb5KSSEhyaEqmSFVoOAz6
# FFsqoEkVkvL2eGEEgQo9FesV+NBczFApwqaD8j0j0glpM2AWaZc1+8hNieS9z1ye
# Uab29W+Bc/g=
# SIG # End signature block
