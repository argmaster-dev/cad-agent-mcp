<#
.SYNOPSIS
    Installs cad-agent-mcp for AutoCAD 2020: the ClaudeBridge plugin, the MCP server
    and the agent skills, then connects the server to Claude Code and/or Codex.

.DESCRIPTION
    One-liner (PowerShell, no admin rights needed):

        irm https://github.com/argmaster-dev/cad-agent-mcp/releases/latest/download/install.ps1 | iex

    With parameters (specific version, uninstall, ...):

        & ([scriptblock]::Create((irm https://github.com/argmaster-dev/cad-agent-mcp/releases/latest/download/install.ps1))) -Uninstall

    What it does:
      1. downloads cad-agent-mcp-autocad.zip from GitHub Releases;
      2. unpacks it to %LOCALAPPDATA%\cad-agent-mcp\autocad\<version>\ and unblocks the files;
      3. registers the plugin for autoload in AutoCAD 2020 (registry + TRUSTEDPATHS + acaddoc.lsp);
      4. registers the MCP server "autocad-bridge" in Claude Code (user scope) and Codex, if present;
      5. copies the skills to ~\.claude\skills and/or ~\.agents\skills.

    Requirements: Windows, AutoCAD 2020 started at least once, Node.js 18+.

.PARAMETER Version
    Release tag to install, e.g. v0.1.0. Default: the latest release.

.PARAMETER Source
    Path to an already downloaded cad-agent-mcp-autocad.zip (offline install / CI).

.PARAMETER Uninstall
    Remove everything this script installed.
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$Source = '',
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'cad-agent-mcp'),
    [switch]$Uninstall,
    [switch]$SkipClaude,
    [switch]$SkipCodex,
    [switch]$SkipSkills
)

# Everything lives inside functions: with `irm | iex` the script runs in the user's
# own session, so `exit` would close their window and global preference changes
# would leak. Errors are reported, never thrown at the caller.

function Invoke-CadAgentInstaller {
    param($Version, $Source, $InstallRoot, $Uninstall, $SkipClaude, $SkipCodex, $SkipSkills)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is 10x slower with the progress bar

    $Repo        = 'argmaster-dev/cad-agent-mcp'
    $AssetName   = 'cad-agent-mcp-autocad.zip'
    $ServerName  = 'autocad-bridge'
    $ProductRoot = 'HKCU:\Software\Autodesk\AutoCAD\R23.1'
    $AppDir      = Join-Path $InstallRoot 'autocad'
    $Manifest    = Join-Path $AppDir 'installed.json'
    $CodexBegin  = '# >>> cad-agent-mcp (managed by install.ps1) >>>'
    $CodexEnd    = '# <<< cad-agent-mcp <<<'

    function Say([string]$msg)  { Write-Host "  $msg" }
    function Step([string]$msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
    function Warn([string]$msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }

    # Run a native command without PowerShell 5.1 turning its stderr into errors.
    function Invoke-Native([string]$exe, [string[]]$arguments) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $exe @arguments 2>&1 | Out-String
            return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out.Trim() }
        } finally {
            $ErrorActionPreference = $prev
        }
    }

    function Write-Utf8NoBom([string]$path, [string]$text) {
        [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    }

    function Remove-CodexBlock([string]$text) {
        $start = $text.IndexOf($CodexBegin)
        $end = $text.IndexOf($CodexEnd)
        if ($start -lt 0 -or $end -lt $start) { return $text }
        return ($text.Substring(0, $start) + $text.Substring($end + $CodexEnd.Length)).Trim() + "`n"
    }

    function Get-CodexConfigPath {
        $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
        return Join-Path $codexHome 'config.toml'
    }

    function Test-Codex {
        return [bool](Get-Command codex -ErrorAction SilentlyContinue) -or (Test-Path (Split-Path (Get-CodexConfigPath)))
    }

    # ------------------------------------------------------------------ uninstall

    if ($Uninstall) {
        Step 'Uninstalling cad-agent-mcp (AutoCAD)'
        $state = $null
        if (Test-Path $Manifest) { $state = Get-Content $Manifest -Raw | ConvertFrom-Json }

        $autoload = @(Get-ChildItem $AppDir -Recurse -Filter 'install-autoload.ps1' -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($autoload) {
            try { & $autoload.FullName -Remove | Out-Null; Say 'AutoCAD autoload removed' }
            catch { Warn "AutoCAD autoload: $($_.Exception.Message)" }
        }

        if (Get-Command claude -ErrorAction SilentlyContinue) {
            $r = Invoke-Native 'claude' @('mcp', 'remove', '-s', 'user', $ServerName)
            if ($r.Code -eq 0) { Say "Claude Code: MCP server '$ServerName' removed" }
        }

        $codexConfig = Get-CodexConfigPath
        if (Test-Path $codexConfig) {
            $text = [System.IO.File]::ReadAllText($codexConfig)
            if ($text.Contains($CodexBegin)) {
                Write-Utf8NoBom $codexConfig (Remove-CodexBlock $text)
                Say 'Codex: MCP server removed from config.toml'
            }
        }

        if ($state -and $state.skills) {
            foreach ($dir in $state.skills) {
                if (Test-Path $dir) { Remove-Item $dir -Recurse -Force; Say "skill removed: $dir" }
            }
        }

        try {
            Remove-Item $AppDir -Recurse -Force
            if (-not (Get-ChildItem $InstallRoot -ErrorAction SilentlyContinue)) { Remove-Item $InstallRoot -Force }
            Say "files removed: $AppDir"
        } catch {
            Warn "Some files are in use (is AutoCAD running?). Close AutoCAD and delete $AppDir manually."
        }
        Write-Host ""
        Write-Host 'Done. Restart AutoCAD and your agent.' -ForegroundColor Green
        return
    }

    # ------------------------------------------------------------------ preflight

    Write-Host ""
    Write-Host 'cad-agent-mcp: AI agent for AutoCAD 2020 via MCP' -ForegroundColor Green
    Write-Host "https://github.com/$Repo  |  https://sitimlab.ru"

    Step 'Checking prerequisites'
    if ($env:OS -ne 'Windows_NT') { Warn 'This installer is for Windows only.'; return }

    if (-not (Test-Path $ProductRoot)) {
        Warn 'AutoCAD 2020 profile not found for the current user.'
        Warn 'Install AutoCAD 2020 and start it at least once, then run the installer again.'
        return
    }
    Say 'AutoCAD 2020: found'

    $nodeOk = $false
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeVersion = (Invoke-Native 'node' @('--version')).Output
        if ($nodeVersion -match '^v(\d+)\.' -and [int]$Matches[1] -ge 18) {
            $nodeOk = $true
            Say "Node.js: $nodeVersion"
        } else {
            Warn "Node.js $nodeVersion is too old, 18+ is required."
        }
    } else {
        Warn 'Node.js not found. The MCP server needs Node.js 18+.'
    }
    if (-not $nodeOk) {
        Warn 'Install it (e.g. `winget install OpenJS.NodeJS.LTS`), then restart your agent. Continuing.'
    }

    $autocadRunning = [bool](Get-Process -Name acad -ErrorAction SilentlyContinue)
    if ($autocadRunning) { Warn 'AutoCAD is running: the plugin will be picked up after a restart.' }

    # ------------------------------------------------------------------ download

    Step 'Downloading the release'
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cad-agent-mcp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        if ($Source) {
            $zip = (Resolve-Path $Source).Path
            Say "local archive: $zip"
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $url = if ($Version -eq 'latest') {
                "https://github.com/$Repo/releases/latest/download/$AssetName"
            } else {
                "https://github.com/$Repo/releases/download/$Version/$AssetName"
            }
            $zip = Join-Path $tmp $AssetName
            Say $url
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        }

        $unpacked = Join-Path $tmp 'unpacked'
        Expand-Archive -Path $zip -DestinationPath $unpacked -Force
        $versionFile = Join-Path $unpacked 'VERSION'
        if (-not (Test-Path $versionFile)) { throw "Archive has no VERSION file: $zip" }
        $releaseVersion = (Get-Content $versionFile -Raw).Trim()
        Say "version: $releaseVersion"

        # Each version goes to its own folder: a DLL loaded by a running AutoCAD
        # is locked, so we never overwrite in place.
        $target = Join-Path $AppDir $releaseVersion
        if (Test-Path $target) {
            try { Remove-Item $target -Recurse -Force }
            catch { throw "Version $releaseVersion is already installed and in use. Close AutoCAD and run the installer again." }
        }
        New-Item -ItemType Directory -Force $AppDir | Out-Null
        Move-Item $unpacked $target
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Files downloaded from the internet carry Mark-of-the-Web; .NET refuses to
    # load such DLLs into AutoCAD ("loadFromRemoteSources"). Strip it.
    Get-ChildItem $target -Recurse -File | Unblock-File

    $dll      = Join-Path $target 'plugin\ClaudeBridge.AutoCad.dll'
    $server   = Join-Path $target 'server\index.mjs'
    $autoload = Join-Path $target 'tools\install-autoload.ps1'
    foreach ($f in @($dll, $server, $autoload)) {
        if (-not (Test-Path $f)) { throw "Archive is incomplete, missing: $f" }
    }
    Say "installed to: $target"

    # ------------------------------------------------------------------ AutoCAD

    Step 'Registering the plugin in AutoCAD 2020'
    & $autoload -DllPath $dll | ForEach-Object { Say $_ }

    # ------------------------------------------------------------------ agents

    $skillDirs = @()
    $agents = @()

    if (-not $SkipClaude) {
        Step 'Claude Code'
        if (Get-Command claude -ErrorAction SilentlyContinue) {
            Invoke-Native 'claude' @('mcp', 'remove', '-s', 'user', $ServerName) | Out-Null
            $r = Invoke-Native 'claude' @('mcp', 'add', '-s', 'user', $ServerName, '--', 'node', $server)
            if ($r.Code -eq 0) {
                Say "MCP server '$ServerName' registered (user scope)"
                $agents += 'Claude Code'
            } else {
                Warn "claude mcp add failed: $($r.Output)"
            }
        } else {
            Say 'not found, skipped. Later: claude mcp add -s user autocad-bridge -- node "<path>"'
        }
        if (-not $SkipSkills) {
            $skillDirs += Join-Path $HOME '.claude\skills'
        }
    }

    if (-not $SkipCodex) {
        Step 'Codex'
        if (Test-Codex) {
            $codexConfig = Get-CodexConfigPath
            New-Item -ItemType Directory -Force (Split-Path $codexConfig) | Out-Null
            $text = if (Test-Path $codexConfig) { [System.IO.File]::ReadAllText($codexConfig) } else { '' }
            $text = Remove-CodexBlock $text
            if ($text -match '(?m)^\[mcp_servers\.autocad-bridge\]') {
                Warn "config.toml already has [mcp_servers.autocad-bridge] not managed by this installer; left as is."
            } else {
                # TOML literal string ('...') keeps Windows backslashes as is.
                $block = @(
                    $CodexBegin
                    "[mcp_servers.$ServerName]"
                    'command = "node"'
                    "args = ['$server']"
                    $CodexEnd
                ) -join "`n"
                $newText = if ($text.Trim()) { $text.TrimEnd() + "`n`n" + $block + "`n" } else { $block + "`n" }
                Write-Utf8NoBom $codexConfig $newText
                Say "MCP server '$ServerName' added to $codexConfig"
                $agents += 'Codex'
            }
            if (-not $SkipSkills) {
                $skillDirs += Join-Path $HOME '.agents\skills'
            }
        } else {
            Say 'not found, skipped'
        }
    }

    $installedSkills = @()
    if (-not $SkipSkills -and $skillDirs.Count -gt 0) {
        Step 'Skills'
        $source = Join-Path $target 'skills'
        foreach ($root in $skillDirs) {
            New-Item -ItemType Directory -Force $root | Out-Null
            foreach ($skill in Get-ChildItem $source -Directory) {
                $dest = Join-Path $root $skill.Name
                if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
                Copy-Item $skill.FullName $dest -Recurse
                $installedSkills += $dest
            }
            Say "$((Get-ChildItem $source -Directory).Count) skills -> $root"
        }
    }

    # ------------------------------------------------------------------ cleanup

    # Drop older versions that are no longer locked by AutoCAD.
    foreach ($old in Get-ChildItem $AppDir -Directory | Where-Object { $_.FullName -ne $target }) {
        try { Remove-Item $old.FullName -Recurse -Force } catch { }
    }

    $state = [ordered]@{
        version   = $releaseVersion
        path      = $target
        server    = $server
        agents    = $agents
        skills    = $installedSkills
        installed = (Get-Date).ToString('s')
    }
    Write-Utf8NoBom $Manifest ($state | ConvertTo-Json)

    Write-Host ""
    Write-Host "cad-agent-mcp $releaseVersion installed." -ForegroundColor Green
    Write-Host ""
    Write-Host 'Next steps:'
    Write-Host '  1. Restart AutoCAD 2020 and open a saved drawing.'
    Write-Host '     Check: type CLAUDE_HTTP_STATUS in the command line.'
    if ($agents.Count -gt 0) {
        Write-Host "  2. Restart $($agents -join ' / ') and ask: ""check the connection to AutoCAD and take a snapshot""."
    } else {
        Write-Host "  2. Connect an agent to the MCP server: node ""$server"""
    }
    Write-Host ""
    Write-Host 'Uninstall:'
    Write-Host "  & ([scriptblock]::Create((irm https://github.com/$Repo/releases/latest/download/install.ps1))) -Uninstall"
}

try {
    Invoke-CadAgentInstaller -Version $Version -Source $Source -InstallRoot $InstallRoot `
        -Uninstall:$Uninstall -SkipClaude:$SkipClaude -SkipCodex:$SkipCodex -SkipSkills:$SkipSkills
} catch {
    Write-Host ""
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Report the problem: https://github.com/argmaster-dev/cad-agent-mcp/issues" -ForegroundColor Red
}
