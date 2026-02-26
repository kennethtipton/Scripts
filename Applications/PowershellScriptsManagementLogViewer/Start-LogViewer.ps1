Import-Module Pode

# Config
$LogPath = "C:\Scripts\Logs"
$Port    = 8080

Start-PodeServer {
    Add-PodeEndpoint -Address * -Port $Port -Protocol Http

    # API: Get log file list
    Add-PodeRoute -Method Get -Path '/api/logfiles' -ScriptBlock {
        $files = Get-ChildItem $LogPath -Filter *.log | Select-Object Name, FullName
        Write-PodeJsonResponse -Value $files
    }

    # API: Get log file content
    Add-PodeRoute -Method Get -Path '/api/log' -ScriptBlock {
        param($file)

        $fullPath = Join-Path $LogPath $file
        if (Test-Path $fullPath) {
            $content = Get-Content $fullPath -Tail 5000
            Write-PodeJsonResponse -Value $content
        }
        else {
            Write-PodeJsonResponse -Value @("File not found")
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
.tabs { display:flex; border-bottom:1px solid #555; }
.tab { padding:10px; cursor:pointer; background:#222; margin-right:2px; }
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
    document.getElementById('logcontent').innerText = lines.join('\\n');
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