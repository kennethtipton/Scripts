<#
.SYNOPSIS
    Publishes the shared files and selected applications from this development computer to the DFS scripts share (the release store).
.DESCRIPTION
    The release store is the Dfs transport's Root in C:\SCRIPTS\Data\Settings\Scripts.json
    (\\generationsgaither.com\all_scripts\scripts). Every server's PSM Frontend pulls from it, so a
    publish is how a change reaches production. Run on the development computer, where the code
    signing certificate is (SetupApplications, "Publish to DFS" tab, or directly).

    What is published:
      Shared        Functions\*.ps1 (all, including the setup tools the management server needs),
                    Data\ (with subfolders), Modules\ (with subfolders), Installs\*.ps1 and
                    Installs\Data\*.json (the manifests).
      <application> the folders and files its manifest lists, plus the manifests it DependsOn, plus
                    the manifest files themselves (Installs\Data\<Name>.json), so servers can find them.
    Never published: Logs, Applications\Data (inventory records), .git, server-local data that is not
    in a manifest (DynamicGroups Data\Rules, PoshAcme Certs and Backups, transcripts), *.tmp, and
    anything matching Publish.Exclude in Data\Settings\Scripts.json (private files such as server
    lists; shown as "Excluded"). An excluded file already on DFS is retired from there.

    Steps:
      1. Builds the file list and checks every script (.ps1/.psm1/.psd1) has a Valid signature. One
         that is not stops the whole publish before anything is copied.
      2. Backs up C:\SCRIPTS (Backup-ScriptsFolder), unless -NoBackup or -WhatIf.
      3. Copies each new or changed file (SHA256) to DFS under a temporary name, then renames it, so a
         server never pulls half a file. Unchanged files are left alone.
      4. Retires files in the published folders on DFS that are no longer part of what is published
         (deleted or renamed here): they are moved to DFS\_Retired\<yyyyMMdd_HHmmss>\, not deleted.
         Only the folders of what is being published are looked at, and only those it publishes
         files into (each folder by itself, not its subfolders, except Data and Modules in Shared);
         parent folders a manifest lists just so they exist (Applications\Microsoft) are left alone.
      5. Records the publish in DFS\Release.json (when, by whom, from where, each item's version).

    -WhatIf shows every Add / Update / Retire without changing anything.
.PARAMETER Name
    What to publish: 'Shared' and/or manifest names from Installs\Data (for example PoshAcmeExchangeServer).
.PARAMETER DfsRoot
    Release store. Defaults to the Dfs transport's Root in Scripts.json.
.PARAMETER Root
    The development copy. Defaults to C:\SCRIPTS (the parent of this Functions folder).
.PARAMETER NoBackup
    Skip the Backup-ScriptsFolder backup before publishing.
.PARAMETER NoRetire
    Leave files on DFS that are no longer part of what is published.
.PARAMETER LogFileName
    Base name of the text log in C:\SCRIPTS\Logs. Defaults to Publish-ScriptsToDfs.
.EXAMPLE
    PS> Publish-ScriptsToDfs -Name Shared, PoshAcmeExchangeServer -WhatIf | Format-Table -AutoSize
.EXAMPLE
    PS> Publish-ScriptsToDfs -Name Shared, PSMFrontendScriptsSync, PSMBackendScriptsSync
.INPUTS
    [string[]] Name, [string] DfsRoot, [string] Root, [switch] NoBackup, [switch] NoRetire, [string] LogFileName
.OUTPUTS
    [pscustomobject] one row per file: Item (Shared or application), Path (relative), Action
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-20
    Time: 17:00:00
    Time Zone: Central Standard Time
    Function Or Application: Function
    Version: 1.1.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Setup-only tool: Base.json leaves it out of the files copied to servers.
    The account running it needs write access to the release store (FLD-SCRIPTS.ADMINS).

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: Publish-ScriptsToDfs
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>

function Publish-ScriptsToDfs {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Name,

        [Parameter(Mandatory = $false)]
        [string]$DfsRoot,

        [Parameter(Mandatory = $false)]
        [string]$Root = (Split-Path -Path $PSScriptRoot -Parent),

        [Parameter(Mandatory = $false)]
        [switch]$NoBackup,

        [Parameter(Mandatory = $false)]
        [switch]$NoRetire,

        [Parameter(Mandatory = $false)]
        [string]$LogFileName = 'Publish-ScriptsToDfs'
    )

    #region Logging and helpers
    foreach ($F in 'Write-AdvancedLog.ps1', 'Get-ApplicationSettings.ps1', 'Get-ScriptsTransport.ps1', 'Backup-ScriptsFolder.ps1') {
        $P = Join-Path -Path $PSScriptRoot -ChildPath $F
        if (Test-Path -Path $P) { . $P }
    }
    function Write-PubLog {
        param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
        switch ($LogType) { 'WARNING' { Write-Warning $Message } 'ERROR' { Write-Host $Message -ForegroundColor Red } default { Write-Verbose $Message } }
        if (-not $WhatIfPreference -and (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue)) {
            try { Write-AdvancedLog -Message $Message -ScriptName 'Publish-ScriptsToDfs.ps1' -LogFileName $LogFileName -LogType $LogType } catch { }
        }
    }
    $Std = 'C:\SCRIPTS'
    $Root = $Root.TrimEnd('\')
    # C:\SCRIPTS\x (as written in manifests) -> relative path x
    function Get-RelPath {
        param([string]$Path)
        foreach ($Base in @($Std, $Root)) {
            if ($Path.StartsWith("$Base\", [System.StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($Base.Length + 1) }
        }
        throw "'$Path' is not under $Std."
    }
    #endregion

    #region Where to
    if (-not $DfsRoot) {
        $Cfg = Get-ApplicationSettings -Path (Join-Path -Path $Root -ChildPath 'Data\Settings\Scripts.json')
        $DfsRoot = "$((Get-ScriptsTransport -Settings $Cfg -Type Dfs -All | Where-Object Root | Select-Object -First 1).Root)"
    }
    if (-not $DfsRoot) { throw 'No Dfs transport Root in Scripts.json and no -DfsRoot given.' }
    $DfsRoot = $DfsRoot.TrimEnd('\')
    if (-not (Test-Path -Path $DfsRoot -PathType Container)) { throw "Release store $DfsRoot is not reachable." }
    $InstallsData = Join-Path -Path $Root -ChildPath 'Installs\Data'
    #endregion

    #region What: relative file list per item, and the folders each item owns on DFS
    $Files = [ordered]@{}            # rel path -> item name
    $Owned = New-Object System.Collections.Generic.List[object]   # { Rel; Recurse; Item }
    $Versions = [ordered]@{}
    function Add-File { param([string]$Rel, [string]$Item) if ($Rel -notlike '*.tmp' -and -not $Files.Contains($Rel)) { $Files[$Rel] = $Item } }
    function Add-Folder { param([string]$Rel, [bool]$Recurse, [string]$Item) $Owned.Add([pscustomobject]@{ Rel = $Rel.TrimEnd('\'); Recurse = $Recurse; Item = $Item }) }

    $Wanted = @($Name | Select-Object -Unique)
    foreach ($N in $Wanted) {
        if ($N -eq 'Shared') {
            foreach ($F in Get-ChildItem -Path (Join-Path $Root 'Functions') -Filter '*.ps1' -File) { Add-File "Functions\$($F.Name)" 'Shared' }
            Add-Folder 'Functions' $false 'Shared'
            foreach ($Sub in 'Data', 'Modules') {
                $Dir = Join-Path -Path $Root -ChildPath $Sub
                if (-not (Test-Path $Dir)) { continue }
                foreach ($F in Get-ChildItem -Path $Dir -File -Recurse -Force) { Add-File $F.FullName.Substring($Root.Length + 1) 'Shared' }
                Add-Folder $Sub $true 'Shared'
            }
            foreach ($F in Get-ChildItem -Path (Join-Path $Root 'Installs') -Filter '*.ps1' -File) { Add-File "Installs\$($F.Name)" 'Shared' }
            foreach ($F in Get-ChildItem -Path $InstallsData -Filter '*.json' -File) { Add-File "Installs\Data\$($F.Name)" 'Shared' }
            Add-Folder 'Installs' $false 'Shared'; Add-Folder 'Installs\Data' $false 'Shared'
            $Versions['Shared'] = "$((Get-Content -Path (Join-Path $Root 'Data\Settings\Scripts.json') -Raw | ConvertFrom-Json).Version)"
            continue
        }
        # An application: its manifest and every manifest it depends on (Base comes with Shared)
        $Todo = New-Object System.Collections.Generic.Queue[string]; $Todo.Enqueue($N); $Done = @{}
        while ($Todo.Count) {
            $M = $Todo.Dequeue()
            if ($Done.ContainsKey($M) -or $M -eq 'Base') { continue }
            $Done[$M] = $true
            $MPath = Join-Path -Path $InstallsData -ChildPath "$M.json"
            if (-not (Test-Path $MPath)) { throw "Manifest not found: $MPath" }
            $Man = Get-Content -Path $MPath -Raw | ConvertFrom-Json
            foreach ($D in @($Man.DependsOn | Where-Object { $_ })) { $Todo.Enqueue("$D") }
            Add-File "Installs\Data\$M.json" $N
            foreach ($Folder in @($Man.Folders | Where-Object { $_ })) { Add-Folder (Get-RelPath "$Folder") $false $N }
            foreach ($F in @($Man.Files | Where-Object { $_ })) {
                $Src = "$($F.Source)"
                if ($Src -match '[\*\?]') {
                    $Exclude = @($F.Exclude | Where-Object { $_ })
                    foreach ($Hit in @(Get-ChildItem -Path ($Root + '\' + (Get-RelPath $Src)) -File -ErrorAction SilentlyContinue)) {
                        if ($Exclude | Where-Object { $Hit.Name -like $_ }) { continue }
                        Add-File $Hit.FullName.Substring($Root.Length + 1) $N
                    }
                }
                else { Add-File (Get-RelPath $Src) $N }
            }
            if ($Man.AppData) {
                $Ad = Join-Path -Path $Root -ChildPath (Get-RelPath "$($Man.AppData)")
                if (Test-Path $Ad) { $Versions[$M] = "$((Get-Content -Path $Ad -Raw | ConvertFrom-Json).Version)" }
            }
        }
    }
    #endregion

    #region Exclusions (Publish.Exclude in Scripts.json): private files never go to DFS
    $ExcludeCfg = $null
    try { $ExcludeCfg = Get-ApplicationSettings -Path (Join-Path -Path $Root -ChildPath 'Data\Settings\Scripts.json') } catch { }
    $Excludes = @(if ($ExcludeCfg -and $ExcludeCfg.PSObject.Properties['Publish'] -and $ExcludeCfg.Publish.PSObject.Properties['Exclude']) { $ExcludeCfg.Publish.Exclude | Where-Object { $_ } })
    $Excluded = @(foreach ($Rel in @($Files.Keys)) {
        if ($Excludes | Where-Object { $Rel -like $_ }) { $Rel }
    })
    foreach ($Rel in $Excluded) {
        $Item = $Files[$Rel]
        $Files.Remove($Rel)
        [pscustomobject]@{ Item = $Item; Path = $Rel; Action = 'Excluded (Publish.Exclude)' }
    }
    #endregion

    #region 1. Signature check (all or nothing)
    $Missing = @($Files.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf) })
    if ($Missing.Count) { throw "Listed in a manifest but missing here: $($Missing -join ', ')" }
    $Unsigned = @(foreach ($Rel in $Files.Keys) {
        if ([System.IO.Path]::GetExtension($Rel) -in '.ps1', '.psm1', '.psd1') {
            $St = "$((Get-AuthenticodeSignature -LiteralPath (Join-Path $Root $Rel)).Status)"
            if ($St -ne 'Valid') { "$Rel ($St)" }
        }
    })
    if ($Unsigned.Count) {
        Write-PubLog "Publish of $($Wanted -join ', ') stopped: $($Unsigned.Count) script(s) not validly signed: $($Unsigned -join ', '). Run Set-ScriptSignature first." -LogType ERROR
        throw "Not validly signed (run Set-ScriptSignature first): $($Unsigned -join ', ')"
    }
    #endregion

    #region 2. Backup
    if (-not $NoBackup -and -not $WhatIfPreference -and (Get-Command -Name Backup-ScriptsFolder -ErrorAction SilentlyContinue)) {
        try { $Bk = Backup-ScriptsFolder -Path $Root -Reason "Publish $($Wanted -join ' ')" -WarningAction SilentlyContinue; Write-PubLog "Backup: $($Bk.ZipPath)." }
        catch { throw "Backup before publishing failed: $($_.Exception.Message) (use -NoBackup to publish anyway)" }
    }
    #endregion

    #region 3. Copy
    $Counts = @{ Added = 0; Updated = 0; Unchanged = 0; Retired = 0; Failed = 0 }
    foreach ($Rel in $Files.Keys) {
        $Tmp = $null
        $Src = Join-Path -Path $Root -ChildPath $Rel
        $Dst = Join-Path -Path $DfsRoot -ChildPath $Rel
        $Exists = Test-Path -LiteralPath $Dst -PathType Leaf
        if ($Exists -and (Get-FileHash -LiteralPath $Dst).Hash -eq (Get-FileHash -LiteralPath $Src).Hash) {
            $Counts.Unchanged++
            [pscustomobject]@{ Item = $Files[$Rel]; Path = $Rel; Action = 'Unchanged' }
            continue
        }
        $Verb = if ($Exists) { 'Updated' } else { 'Added' }
        if (-not $PSCmdlet.ShouldProcess($Dst, $(if ($Exists) { 'Replace (contents differ)' } else { 'Add new file' }))) {
            [pscustomobject]@{ Item = $Files[$Rel]; Path = $Rel; Action = "Would be $($Verb.ToLower()) (WhatIf)" }
            continue
        }
        try {
            $Dir = Split-Path -Path $Dst -Parent
            if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
            # *.tmp: DFS Replication skips it by default, so a half-written file is never replicated or pulled
            $Tmp = '{0}.{1}.tmp' -f $Dst, [guid]::NewGuid().ToString('N').Substring(0, 8)
            Copy-Item -LiteralPath $Src -Destination $Tmp -Force
            Move-Item -LiteralPath $Tmp -Destination $Dst -Force
            $Counts[$Verb]++
            [pscustomobject]@{ Item = $Files[$Rel]; Path = $Rel; Action = $Verb }
        }
        catch {
            $Counts.Failed++
            if ($Tmp -and (Test-Path -LiteralPath $Tmp)) { Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue }
            Write-PubLog "Could not publish ${Rel}: $($_.Exception.Message)" -LogType ERROR
            [pscustomobject]@{ Item = $Files[$Rel]; Path = $Rel; Action = "Failed: $($_.Exception.Message)" }
        }
    }
    #endregion

    #region 4. Retire what is no longer published in the owned folders
    if (-not $NoRetire) {
        $Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $Seen = @{}
        foreach ($O in $Owned) {
            if ($Seen.ContainsKey($O.Rel)) { continue }; $Seen[$O.Rel] = $true
            # Only folders this item publishes files into; parents listed just to exist (Applications\Microsoft) are left alone
            $Publishes = if ($O.Recurse) { @($Files.Keys | Where-Object { $_.StartsWith("$($O.Rel)\", [System.StringComparison]::OrdinalIgnoreCase) }).Count }
                         else { @($Files.Keys | Where-Object { (Split-Path -Path $_ -Parent) -eq $O.Rel }).Count }
            if (-not $Publishes) { continue }
            $Dir = Join-Path -Path $DfsRoot -ChildPath $O.Rel
            if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { continue }
            foreach ($F in @(Get-ChildItem -LiteralPath $Dir -File -Force -Recurse:$O.Recurse -ErrorAction SilentlyContinue)) {
                $Rel = $F.FullName.Substring($DfsRoot.Length + 1)
                if ($Files.Contains($Rel) -or $F.Name -like '*.tmp') { continue }
                if ($O.Item -eq 'Shared' -and $Rel -like 'Applications\*') { continue }
                $To = Join-Path -Path $DfsRoot -ChildPath "_Retired\$Stamp\$Rel"
                if (-not $PSCmdlet.ShouldProcess($F.FullName, "Retire to _Retired\$Stamp")) {
                    [pscustomobject]@{ Item = $O.Item; Path = $Rel; Action = 'Would be retired (WhatIf)' }; continue
                }
                try {
                    New-Item -ItemType Directory -Path (Split-Path $To -Parent) -Force | Out-Null
                    Move-Item -LiteralPath $F.FullName -Destination $To -Force
                    $Counts.Retired++
                    Write-PubLog "Retired $Rel to _Retired\$Stamp (no longer part of $($O.Item))."
                    [pscustomobject]@{ Item = $O.Item; Path = $Rel; Action = 'Retired' }
                }
                catch {
                    $Counts.Failed++
                    [pscustomobject]@{ Item = $O.Item; Path = $Rel; Action = "Failed to retire: $($_.Exception.Message)" }
                }
            }
        }
    }
    #endregion

    #region 5. Release record
    if (-not $WhatIfPreference) {
        $RelPath = Join-Path -Path $DfsRoot -ChildPath 'Release.json'
        $Rec = [ordered]@{}
        if (Test-Path $RelPath) {
            try { $Old = Get-Content -Path $RelPath -Raw | ConvertFrom-Json; foreach ($P in $Old.Items.PSObject.Properties) { $Rec[$P.Name] = $P.Value } } catch { }
        }
        $Now = Get-Date -Format 's'
        foreach ($K in $Versions.Keys) {
            $Rec[$K] = [ordered]@{ Version = $Versions[$K]; Published = $Now; By = "$env:USERDOMAIN\$env:USERNAME"; From = $env:COMPUTERNAME }
        }
        $Doc = [ordered]@{ Updated = $Now; UpdatedBy = "$env:USERDOMAIN\$env:USERNAME"; From = $env:COMPUTERNAME; Items = $Rec }
        $Tmp = "$RelPath.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
        [System.IO.File]::WriteAllText($Tmp, (ConvertTo-Json -InputObject $Doc -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $Tmp -Destination $RelPath -Force
        $Summary = 'Published {0} to {1}: {2} added, {3} updated, {4} unchanged, {5} retired, {6} failed. Versions: {7}.' -f ($Wanted -join ', '), $DfsRoot, $Counts.Added, $Counts.Updated, $Counts.Unchanged, $Counts.Retired, $Counts.Failed, (($Versions.Keys | ForEach-Object { "$_ $($Versions[$_])" }) -join ', ')
        Write-PubLog $Summary -LogType $(if ($Counts.Failed) { 'WARNING' } else { 'INFO' })
    }
    #endregion
}

# Example usage:
# PS> . C:\SCRIPTS\Functions\Publish-ScriptsToDfs.ps1
# PS> Publish-ScriptsToDfs -Name Shared, PoshAcmeExchangeServer -WhatIf | Where-Object Action -ne 'Unchanged' | Format-Table -AutoSize
# PS> Publish-ScriptsToDfs -Name Shared, PSMFrontendScriptsSync -Verbose | Format-Table -AutoSize


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCARxjJigWyiaeQ8
# aQvDGLCoMxAmEIN/GWU/TMJpzggRIKCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIFQnDN6
# FBdnyAqbVET7CzuU7jlVMiCcF/vyROgn1ibaMA0GCSqGSIb3DQEBAQUABIIBAA78
# UTZxgk4BIC8fAeQSQDCjdPaITlFhfVazTapQ2Sa21XuDRhKgaw9MIYj2MXrHNGvW
# qKmWhm+qkHt1+Hw4i2OKdTY5+yIurG3h9yJ7dJ0t454/yB6UabGa3glSu3mBmHeG
# WysanyGEvAxK7TVtjlmRYpjG2xqi3XWz29sJx6GuNLFqmLCYRXVlzV91sLluA1IZ
# C0BV8WGHvqzef5fMRZKHfXab89atiEZTyVI8i4gvkylpFUr8C82/Y0HobXZ3Bpld
# 2TaTSQCFvnBYdDpb5i18xP5qlhChUM/bysktNk0VZ9bQW2EsTW1h70t1prL154pe
# UA03P7ColULBycqMmrGhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIxMTY1
# NzU3WjAvBgkqhkiG9w0BCQQxIgQgYB6Xk2iq/Z01Qj9/FwuDDXMVqNfhXWoVDeEY
# fYU1qNYwDQYJKoZIhvcNAQEBBQAEggIAWKvHkZbmeWiyengW5bX04vuxvB5jc04F
# 0XdJEBrdXHs6YXurUE6cRdoZ81oY1jKaYFRw/JOKjBmcTMeztOiHf/Yuk6CrOPhB
# qdpWAjjeOpJWQ6wmkG6ferey4gKYEOQAFRp+ulHraxi2jQMkT2mOFTChMP7519WF
# Cl7H1pYMM2F8rmpu7ALk925UuvlDx5nCv+X3q3meC1Z5kztNJs5eSRpa+K1aVsS4
# cn5AuYqbybjsz3/osuc8ZXoZC6yvYRB3lp7s8qYa8mbre14nvoLlfM+PcJDeo3I/
# hVNHjjvdxeGMGFj5iFlvwVMQ604LIfFQhMlZrGpIRzKOUBdgzVr2nZQmfo8dDz0B
# 0qlflAiX0vXcG3vZxitDAhskIfz3D9fn1srrOjbYvDc1+XnwVH/a3JkMPZps1WdZ
# M8OjQq2xRtXkOBzAVELehoM7pP2fJJWLWsBRuB1rMAkf5IswatNYS/Z3jEjbWE79
# clDnPfE8MAmT9vYlRm5Gjei2BYtkbaqBwKliKONgvUVt2qcDxEad75Ps0iDqCtt/
# k197KWRI/g256p2gMDqGN+6orHt9WcOfQ6rL5BfZJ7nOOWReQ9gHqABk9G0lSnVf
# Tgv+wkfCuEJtyfcGjd35Zu/BtbyYvwSeCWJe9lDet8My+iM2HMoHRQkhky8AN010
# s5mw6sWIKJ0=
# SIG # End signature block
