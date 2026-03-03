<#
.SYNOPSIS
    Starts a Pode web server that displays PowerShell script log files in a browser UI.
.DESCRIPTION
    Launches a lightweight Pode HTTP server on the specified port. The web interface
    provides one tab per log file found in the Logs folder. Each tab shows a sortable,
    searchable table of log entries. Clicking any row opens a detail popup. Log entries
    are color-coded by type (INFO/WARNING/ERROR). Auto-refreshes every 5 seconds.
    Exposes JSON API endpoints used by the front-end. Includes advanced logging,
    verbose support, and structured error handling per project coding standards.
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
    PS> .\Start-LogViewer.ps1 -Port 8080 -LogPath "C:\Scripts\Logs"
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-03
    Time: 22:38:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 2.0.0
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
    Log entry format expected: YYYY-MM-DD HH:MM:SS | Script: name | TYPE: message
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

        # API: Get log file content as structured entries
        Add-PodeRoute -Method Get -Path '/api/logentries' -ScriptBlock {
            try {
                $file = $WebEvent.Query['file']
                if ([string]::IsNullOrWhiteSpace($file)) {
                    Write-PodeJsonResponse -StatusCode 400 -Value @{ error = "Missing 'file' query parameter" }
                    return
                }
                # Prevent path traversal: only allow filenames, no directory separators
                $safeName = [System.IO.Path]::GetFileName($file)
                $fullPath = Join-Path -Path $using:LogPath -ChildPath $safeName
                if (-not (Test-Path -Path $fullPath -PathType Leaf)) {
                    Write-PodeJsonResponse -StatusCode 404 -Value @{ error = 'File not found' }
                    return
                }

                # Helper: parse "TYPE: message" field into Type and Message
                function ConvertFrom-LogTypeMessage {
                    param([string]$TypeMsgRaw)
                    $colonIdx = $TypeMsgRaw.IndexOf(': ')
                    if ($colonIdx -gt 0) {
                        return @{
                            Type    = $TypeMsgRaw.Substring(0, $colonIdx).Trim().ToUpper()
                            Message = $TypeMsgRaw.Substring($colonIdx + 2).Trim()
                        }
                    }
                    return @{ Type = 'UNKNOWN'; Message = $TypeMsgRaw }
                }

                $lines = Get-Content -Path $fullPath -Tail 5000
                $entries = [System.Collections.Generic.List[object]]::new()
                $id = 0
                foreach ($line in $lines) {
                    $trimmed = $line.Trim()
                    # Skip blank lines and the header row
                    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                    if ($trimmed -eq 'Timestamp | Script | Type | Message') { continue }

                    # Expected format: YYYY-MM-DD HH:MM:SS | Script: name | TYPE: message
                    $parts = $trimmed -split ' \| ', 3
                    if ($parts.Count -eq 3) {
                        $parsed = ConvertFrom-LogTypeMessage -TypeMsgRaw $parts[2].Trim()
                        $entries.Add([PSCustomObject]@{
                            Id        = $id++
                            Timestamp = $parts[0].Trim()
                            Script    = ($parts[1] -replace '^Script:\s*', '').Trim()
                            Type      = $parsed.Type
                            Message   = $parsed.Message
                            Raw       = $trimmed
                        })
                    } else {
                        # Line does not match expected format
                        $entries.Add([PSCustomObject]@{
                            Id        = $id++
                            Timestamp = ''
                            Script    = ''
                            Type      = 'UNPARSED'
                            Message   = $trimmed
                            Raw       = $trimmed
                        })
                    }
                }
                Write-PodeJsonResponse -Value $entries
            }
            catch {
                Write-PodeJsonResponse -StatusCode 500 -Value @{ error = $_.ToString() }
            }
        }

        # Web UI
        Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
            $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>PowerShell Log Viewer</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: Consolas, 'Courier New', monospace; background: #0d1117; color: #c9d1d9; font-size: 13px; }
  header { background: #161b22; border-bottom: 1px solid #30363d; padding: 12px 20px; display: flex; align-items: center; gap: 12px; }
  header h1 { font-size: 18px; color: #58a6ff; flex: 1; }
  #refresh-indicator { font-size: 11px; color: #8b949e; }

  .tabs-bar { display: flex; flex-wrap: wrap; background: #161b22; border-bottom: 1px solid #30363d; padding: 0 12px; }
  .tab { padding: 10px 16px; cursor: pointer; color: #8b949e; border-bottom: 2px solid transparent; transition: color .15s, border-color .15s; }
  .tab:hover { color: #c9d1d9; }
  .tab.active { color: #58a6ff; border-bottom-color: #58a6ff; font-weight: 600; }

  .toolbar { display: flex; align-items: center; gap: 10px; padding: 10px 16px; background: #0d1117; border-bottom: 1px solid #21262d; flex-wrap: wrap; }
  .toolbar input[type=text] { flex: 1; min-width: 180px; padding: 6px 10px; background: #161b22; border: 1px solid #30363d; border-radius: 6px; color: #c9d1d9; font-size: 13px; outline: none; }
  .toolbar input[type=text]:focus { border-color: #58a6ff; }
  .toolbar label { color: #8b949e; font-size: 12px; white-space: nowrap; }
  .toolbar select { padding: 6px 8px; background: #161b22; border: 1px solid #30363d; border-radius: 6px; color: #c9d1d9; font-size: 12px; outline: none; cursor: pointer; }
  .toolbar select:focus { border-color: #58a6ff; }
  #entry-count { font-size: 12px; color: #8b949e; white-space: nowrap; margin-left: auto; }

  .table-wrap { overflow: auto; height: calc(100vh - 155px); }
  table { width: 100%; border-collapse: collapse; }
  thead th { position: sticky; top: 0; background: #161b22; color: #8b949e; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .05em; padding: 8px 12px; text-align: left; border-bottom: 1px solid #30363d; cursor: pointer; user-select: none; white-space: nowrap; }
  thead th:hover { color: #c9d1d9; }
  thead th .sort-arrow { margin-left: 4px; opacity: .4; }
  thead th.sorted-asc .sort-arrow::after { content: '▲'; opacity: 1; }
  thead th.sorted-desc .sort-arrow::after { content: '▼'; opacity: 1; }
  thead th:not(.sorted-asc):not(.sorted-desc) .sort-arrow::after { content: '⇅'; }

  tbody tr { border-bottom: 1px solid #21262d; cursor: pointer; transition: background .1s; }
  tbody tr:hover { background: #1c2128; }
  tbody td { padding: 7px 12px; vertical-align: top; word-break: break-word; }
  td.ts { white-space: nowrap; color: #8b949e; font-size: 12px; min-width: 155px; }
  td.type-badge { width: 80px; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 700; letter-spacing: .04em; }
  .badge-INFO     { background: #0d2d6e; color: #58a6ff; border: 1px solid #1f6feb; }
  .badge-WARNING  { background: #3d2a00; color: #e3b341; border: 1px solid #9e6a03; }
  .badge-ERROR    { background: #3d0f0f; color: #ff7b72; border: 1px solid #da3633; }
  .badge-UNKNOWN  { background: #2d2d2d; color: #8b949e; border: 1px solid #444; }
  .badge-UNPARSED { background: #2d2d2d; color: #8b949e; border: 1px solid #444; }
  td.script-col { color: #8b949e; font-size: 12px; white-space: nowrap; min-width: 140px; }
  td.msg { color: #c9d1d9; }
  .no-rows { text-align: center; padding: 40px; color: #8b949e; }

  /* Modal */
  #modal-overlay { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.65); z-index: 100; align-items: center; justify-content: center; }
  #modal-overlay.open { display: flex; }
  #modal { background: #161b22; border: 1px solid #30363d; border-radius: 10px; width: min(720px, 95vw); max-height: 85vh; overflow: auto; padding: 24px; position: relative; }
  #modal h2 { font-size: 15px; color: #58a6ff; margin-bottom: 16px; }
  #modal-close { position: absolute; top: 14px; right: 16px; background: none; border: none; color: #8b949e; font-size: 20px; cursor: pointer; line-height: 1; }
  #modal-close:hover { color: #c9d1d9; }
  .detail-grid { display: grid; grid-template-columns: 110px 1fr; gap: 8px 14px; }
  .detail-label { color: #8b949e; font-size: 12px; text-align: right; padding-top: 2px; white-space: nowrap; }
  .detail-value { color: #c9d1d9; word-break: break-all; }
  .detail-value.raw { background: #0d1117; border: 1px solid #21262d; border-radius: 6px; padding: 8px 10px; font-size: 12px; white-space: pre-wrap; }
</style>
</head>
<body>

<header>
  <h1>&#x1F4CB; PowerShell Script Log Viewer</h1>
  <span id="refresh-indicator">Auto-refresh: 5s</span>
</header>

<div class="tabs-bar" id="tabs"></div>

<div class="toolbar">
  <input type="text" id="search" placeholder="Search logs..." oninput="applyFilters()" />
  <label for="filter-type">Type:</label>
  <select id="filter-type" onchange="applyFilters()">
    <option value="">All</option>
    <option value="INFO">INFO</option>
    <option value="WARNING">WARNING</option>
    <option value="ERROR">ERROR</option>
  </select>
  <label for="sort-col">Sort by:</label>
  <select id="sort-col" onchange="applyFilters()">
    <option value="ts-desc">Date (newest first)</option>
    <option value="ts-asc">Date (oldest first)</option>
    <option value="type-asc">Type (A-Z)</option>
    <option value="type-desc">Type (Z-A)</option>
  </select>
  <span id="entry-count"></span>
</div>

<div class="table-wrap">
  <table id="log-table">
    <thead>
      <tr>
        <th data-col="Timestamp" class="sorted-desc">Timestamp<span class="sort-arrow"></span></th>
        <th data-col="Type">Type<span class="sort-arrow"></span></th>
        <th data-col="Script">Script<span class="sort-arrow"></span></th>
        <th data-col="Message">Message<span class="sort-arrow"></span></th>
      </tr>
    </thead>
    <tbody id="log-body"><tr><td colspan="4" class="no-rows">Loading&hellip;</td></tr></tbody>
  </table>
</div>

<!-- Detail modal -->
<div id="modal-overlay" role="dialog" aria-modal="true" aria-labelledby="modal-title">
  <div id="modal">
    <button id="modal-close" onclick="closeModal()" aria-label="Close">&times;</button>
    <h2 id="modal-title">Log Entry Detail</h2>
    <div class="detail-grid" id="modal-body"></div>
  </div>
</div>

<script>
  let allEntries = [];
  let currentFile = null;
  let sortCol = 'Timestamp';
  let sortDir = 'desc';
  let refreshTimer = null;

  // ── Tab management ────────────────────────────────────────────────────────
  async function loadTabs() {
    try {
      const res = await fetch('/api/logfiles');
      const files = await res.json();
      const tabsDiv = document.getElementById('tabs');
      tabsDiv.innerHTML = '';
      files.forEach((f, i) => {
        const tab = document.createElement('div');
        tab.className = 'tab';
        tab.innerText = f.Name;
        tab.dataset.name = f.Name;
        tab.onclick = () => selectTab(f.Name, tab);
        tabsDiv.appendChild(tab);
        if (i === 0) selectTab(f.Name, tab);
      });
    } catch (e) {
      document.getElementById('log-body').innerHTML = '<tr><td colspan="4" class="no-rows">Could not load file list: ' + escHtml(String(e)) + '</td></tr>';
    }
  }

  function selectTab(name, tabEl) {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    tabEl.classList.add('active');
    currentFile = name;
    clearInterval(refreshTimer);
    loadEntries();
    refreshTimer = setInterval(loadEntries, 5000);
  }

  // ── Data loading ──────────────────────────────────────────────────────────
  async function loadEntries() {
    if (!currentFile) return;
    try {
      const res = await fetch('/api/logentries?file=' + encodeURIComponent(currentFile));
      const data = await res.json();
      allEntries = Array.isArray(data) ? data : [];
    } catch (e) {
      allEntries = [];
    }
    applyFilters();
    updateRefreshIndicator();
  }

  function updateRefreshIndicator() {
    const el = document.getElementById('refresh-indicator');
    const now = new Date();
    el.textContent = 'Refreshed: ' + now.toLocaleTimeString();
  }

  // ── Filtering & sorting ───────────────────────────────────────────────────
  function applyFilters() {
    const query   = document.getElementById('search').value.toLowerCase();
    const typeFilter = document.getElementById('filter-type').value;
    const sortVal    = document.getElementById('sort-col').value;

    let filtered = allEntries.filter(e => {
      if (typeFilter && e.Type !== typeFilter) return false;
      if (query) {
        const hay = (e.Timestamp + ' ' + e.Type + ' ' + e.Script + ' ' + e.Message).toLowerCase();
        if (!hay.includes(query)) return false;
      }
      return true;
    });

    // Determine sort
    const [col, dir] = sortVal.split('-');
    const colMap = { ts: 'Timestamp', type: 'Type' };
    const sortField = colMap[col] || 'Timestamp';
    filtered.sort((a, b) => {
      const av = (a[sortField] || '').toLowerCase();
      const bv = (b[sortField] || '').toLowerCase();
      return dir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
    });

    renderTable(filtered);
  }

  // ── Rendering ─────────────────────────────────────────────────────────────
  function renderTable(entries) {
    const tbody = document.getElementById('log-body');
    document.getElementById('entry-count').textContent = entries.length + ' entr' + (entries.length === 1 ? 'y' : 'ies');

    if (entries.length === 0) {
      tbody.innerHTML = '<tr><td colspan="4" class="no-rows">No entries match the current filter.</td></tr>';
      return;
    }

    const rows = entries.map(e => {
      const badge = badgeHtml(e.Type);
      return '<tr onclick="openDetail(' + e.Id + ')">' +
        '<td class="ts">'          + escHtml(e.Timestamp) + '</td>' +
        '<td class="type-badge">'  + badge + '</td>' +
        '<td class="script-col">'  + escHtml(e.Script)    + '</td>' +
        '<td class="msg">'         + escHtml(e.Message)   + '</td>' +
        '</tr>';
    });
    tbody.innerHTML = rows.join('');
  }

  function badgeHtml(type) {
    const known = ['INFO','WARNING','ERROR','UNKNOWN','UNPARSED'];
    const cls = known.includes(type) ? type : 'UNKNOWN';
    return '<span class="badge badge-' + cls + '">' + escHtml(type) + '</span>';
  }

  function escHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // ── Detail modal ──────────────────────────────────────────────────────────
  function openDetail(id) {
    const entry = allEntries.find(e => e.Id === id);
    if (!entry) return;
    const grid = document.getElementById('modal-body');
    grid.innerHTML =
      row('Timestamp', escHtml(entry.Timestamp)) +
      row('Type',      badgeHtml(entry.Type)) +
      row('Script',    escHtml(entry.Script)) +
      row('Message',   escHtml(entry.Message)) +
      '<div class="detail-label">Raw</div><div class="detail-value raw">' + escHtml(entry.Raw) + '</div>';
    document.getElementById('modal-overlay').classList.add('open');
  }

  function row(label, valueHtml) {
    return '<div class="detail-label">' + escHtml(label) + '</div><div class="detail-value">' + valueHtml + '</div>';
  }

  function closeModal() {
    document.getElementById('modal-overlay').classList.remove('open');
  }

  // Close modal on overlay click or Escape key
  document.getElementById('modal-overlay').addEventListener('click', function(e) {
    if (e.target === this) closeModal();
  });
  document.addEventListener('keydown', e => { if (e.key === 'Escape') closeModal(); });

  // ── Bootstrap ─────────────────────────────────────────────────────────────
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
# PS> .\Start-LogViewer.ps1 -Port 8080 -LogPath "C:\Scripts\Logs" -Verbose