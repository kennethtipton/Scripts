<#
.SYNOPSIS
    Starts a Pode web server that displays PowerShell script log files in a browser UI.
.DESCRIPTION
    Launches a lightweight Pode HTTP server on the specified port. The web interface
    provides one tab per log file found in the Logs folder, with auto-refresh every
    5 seconds. Exposes two JSON API endpoints (/api/logfiles and /api/log) used by
    the front-end. Includes advanced logging, verbose support, and structured error
    handling per project coding standards.
.PARAMETER Port
    The TCP port for the Pode web server to listen on. Defaults to 8080.
.PARAMETER LogPath
    Full path to the folder containing .log files. Defaults to the Logs folder
    under the repository root (three levels above this script).
.EXAMPLE
    PS> .\Start-LogViewer.ps1
.EXAMPLE
    PS> .\Start-LogViewer.ps1 -Port 9090 -Verbose
.EXAMPLE
    PS> .\Start-LogViewer.ps1 -Port 8080 -LogPath "D:\MyLogs"
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-03
    Time: 22:28:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: GitHub Copilot

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename:
    Overide Text Log File Path:
    Overide Log Type:

    Dependencies: Pode module (Install-Module Pode)
.LINK
    https://www.tnandc.com
    https://badgerati.github.io/Pode/
#>

[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string]$LogPath = (Join-Path -Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) -ChildPath 'Logs')
)

# Import Write-AdvancedLog function
$writeLogFunc = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\Functions\Write-AdvancedLog.ps1'
if (Test-Path $writeLogFunc) {
    . $writeLogFunc
}

Write-Verbose "LogPath: $LogPath"
Write-Verbose "Port: $Port"

try {
    Import-Module Pode -ErrorAction Stop
    Write-AdvancedLog -Message "Pode module imported successfully." -ScriptName $MyInvocation.MyCommand.Name -LogType 'INFO'
}
catch {
    Write-Error "Failed to import Pode module. Install it with: Install-Module Pode -Scope CurrentUser"
    Write-AdvancedLog -Message "Failed to import Pode module: $_" -ScriptName $MyInvocation.MyCommand.Name -LogType 'ERROR'
    exit 1
}

Write-AdvancedLog -Message "Starting Log Viewer server on port $Port. LogPath: $LogPath" -ScriptName $MyInvocation.MyCommand.Name -LogType 'INFO'

try {
    Start-PodeServer {
        Add-PodeEndpoint -Address * -Port $using:Port -Protocol Http

        # API: Get log file list
        Add-PodeRoute -Method Get -Path '/api/logfiles' -ScriptBlock {
            try {
                $files = Get-ChildItem -Path $using:LogPath -Filter '*.log' -ErrorAction Stop |
                    Select-Object -Property Name, FullName
                Write-PodeJsonResponse -Value $files
            }
            catch {
                Write-PodeJsonResponse -StatusCode 500 -Value @{ error = $_.ToString() }
            }
        }

        # API: Get log file content
        Add-PodeRoute -Method Get -Path '/api/log' -ScriptBlock {
            try {
                $file = $WebEvent.Query['file']
                if ([string]::IsNullOrWhiteSpace($file)) {
                    Write-PodeJsonResponse -StatusCode 400 -Value @("Missing 'file' query parameter")
                    return
                }
                # Prevent path traversal: only allow filenames, no directory separators
                $safeName = [System.IO.Path]::GetFileName($file)
                $fullPath = Join-Path -Path $using:LogPath -ChildPath $safeName
                if (Test-Path -Path $fullPath -PathType Leaf) {
                    $content = Get-Content -Path $fullPath -Tail 5000
                    Write-PodeJsonResponse -Value $content
                }
                else {
                    Write-PodeJsonResponse -StatusCode 404 -Value @("File not found")
                }
            }
            catch {
                Write-PodeJsonResponse -StatusCode 500 -Value @{ error = $_.ToString() }
            }
        }

        # Web UI
        Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
            $html = @"
<!DOCTYPE html>
<html>
<head>
<title>PowerShell Log Viewer</title>
<style>
body { font-family: Consolas, monospace; background:#111; color:#ddd; }
.tabs { display:flex; flex-wrap:wrap; border-bottom:1px solid #555; }
.tab { padding:10px; cursor:pointer; background:#222; margin-right:2px; margin-bottom:2px; }
.tab.active { background:#444; font-weight:bold; }
pre { white-space:pre-wrap; padding:10px; background:#000; border:1px solid #444; height:80vh; overflow:auto; }
</style>
</head>
<body>
<h2>PowerShell Script Log Viewer</h2>
<div id="tabs" class="tabs"></div>
<pre id="logcontent">Loading...</pre>

<script>
async function loadTabs() {
    const res = await fetch('/api/logfiles');
    const files = await res.json();
    const tabsDiv = document.getElementById('tabs');

    files.forEach((f, i) => {
        const tab = document.createElement('div');
        tab.className = 'tab';
        tab.innerText = f.Name;
        tab.onclick = () => loadLog(f.Name, tab);
        tabsDiv.appendChild(tab);
        if (i === 0) tab.click();
    });
}

async function loadLog(file, tab) {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    tab.classList.add('active');

    const res = await fetch('/api/log?file=' + encodeURIComponent(file));
    const lines = await res.json();
    document.getElementById('logcontent').innerText = Array.isArray(lines) ? lines.join('\n') : JSON.stringify(lines);
}

// Auto refresh every 5 seconds
setInterval(() => {
    const active = document.querySelector('.tab.active');
    if (active) loadLog(active.innerText, active);
}, 5000);

loadTabs();
</script>
</body>
</html>
"@
            Write-PodeHtmlResponse -Value $html
        }
    }
}
catch {
    Write-Error "Log Viewer server encountered an error: $_"
    Write-AdvancedLog -Message "Log Viewer server error: $_" -ScriptName $MyInvocation.MyCommand.Name -LogType 'ERROR'
}

# Example footer
# PS> .\Start-LogViewer.ps1
# PS> .\Start-LogViewer.ps1 -Port 9090 -Verbose
# PS> .\Start-LogViewer.ps1 -Port 8080 -LogPath "D:\MyLogs" -Verbose