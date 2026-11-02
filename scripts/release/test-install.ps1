# CI test for install.ps1 on a clean Windows machine without AutoCAD.
#
#   powershell -ExecutionPolicy Bypass -File scripts\release\test-install.ps1 -Zip dist-release\cad-agent-mcp-autocad.zip
#
# Fakes the per-user AutoCAD 2020 profile (registry branch + Support folder) and a
# Codex config folder, runs install.ps1 from the local archive, checks every
# artifact, talks MCP to the installed server, then uninstalls and checks cleanup.
# Loading the plugin into a real AutoCAD is NOT covered: that needs AutoCAD.
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [string]$Installer = (Join-Path $PSScriptRoot '..\..\install.ps1')
)
$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "  [ok]   $name" -ForegroundColor Green }
    else     { Write-Host "  [FAIL] $name" -ForegroundColor Red; $failures.Add($name) }
}

$Zip = (Resolve-Path $Zip).Path
# Mark the archive as downloaded from the internet, like a real browser/irm download.
Set-Content -Path $Zip -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
$Installer = (Resolve-Path $Installer).Path

# ---- fake AutoCAD 2020 (en-US) and Codex ----------------------------------
$product = 'HKCU:\Software\Autodesk\AutoCAD\R23.1'
$branch  = Join-Path $product 'ACAD-3001:409'
New-Item -Path (Join-Path $branch 'Applications') -Force | Out-Null
New-Item -Path (Join-Path $branch 'Profiles\<<Unnamed Profile>>\Variables') -Force | Out-Null
Set-ItemProperty -Path $product -Name CurVer -Value 'ACAD-3001:409'
$support = Join-Path $env:APPDATA 'Autodesk\AutoCAD 2020\R23.1\enu\Support'
New-Item -ItemType Directory -Force $support | Out-Null
Set-Content -Path (Join-Path $support 'acaddoc.lsp') -Value '(princ "user content")' -Encoding ASCII
$codexDir = Join-Path $HOME '.codex'
New-Item -ItemType Directory -Force $codexDir | Out-Null
Set-Content -Path (Join-Path $codexDir 'config.toml') -Value 'model = "gpt-5"' -Encoding ASCII

# ---- install ------------------------------------------------------------------
Write-Host "`n### install"
& $Installer -Source $Zip -SkipClaude

$appDir   = Join-Path $env:LOCALAPPDATA 'cad-agent-mcp\autocad'
$manifest = Join-Path $appDir 'installed.json'
Check 'manifest written' (Test-Path $manifest)
$state = Get-Content $manifest -Raw | ConvertFrom-Json
$dll = Join-Path $state.path 'plugin\ClaudeBridge.AutoCad.dll'
Check 'plugin DLL in place' (Test-Path $dll)
Check 'MCP server in place' (Test-Path $state.server)
Check 'Mark-of-the-Web removed' (-not (Get-Item $dll -Stream Zone.Identifier -ErrorAction SilentlyContinue))

$app = Join-Path $branch 'Applications\ClaudeBridge'
Check 'registry LOADER points to DLL' ((Get-ItemProperty $app).LOADER -eq $dll)
Check 'registry MANAGED=1' ((Get-ItemProperty $app).MANAGED -eq 1)
Check 'demand-load commands registered' (@((Get-Item (Join-Path $app 'Commands')).Property) -contains 'CLAUDE_EXTRACT_ROUTE')
$trusted = (Get-ItemProperty (Join-Path $branch 'Profiles\<<Unnamed Profile>>\Variables')).TRUSTEDPATHS
Check 'TRUSTEDPATHS contains plugin folder' ($trusted -like "*$(Split-Path $dll)*")
$lsp = Get-Content (Join-Path $support 'acaddoc.lsp') -Raw
Check 'acaddoc.lsp has NETLOAD block' ($lsp -like '*_.NETLOAD*')
Check 'acaddoc.lsp keeps user content' ($lsp -like '*user content*')

$toml = Get-Content (Join-Path $codexDir 'config.toml') -Raw
Check 'Codex config keeps user settings' ($toml -like '*model = "gpt-5"*')
Check 'Codex config has autocad-bridge' ($toml -like '*[[]mcp_servers.autocad-bridge]*')
Check 'skills copied for Codex' (Test-Path (Join-Path $HOME '.agents\skills\safe-write-workflow\SKILL.md'))

# ---- MCP handshake against the installed server ------------------------------
Write-Host "`n### MCP handshake"
$requests = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"1"}}}'
    '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
) -join "`n"
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$out = $requests | node $state.server 2>$null
$ErrorActionPreference = $prev
$tools = $out | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.id -eq 2 }
Check 'server lists 18 tools' ($tools -and $tools.result.tools.Count -eq 18)

# ---- reinstall is idempotent -------------------------------------------------------
Write-Host "`n### reinstall"
& $Installer -Source $Zip -SkipClaude
$toml = Get-Content (Join-Path $codexDir 'config.toml') -Raw
Check 'Codex block not duplicated' (([regex]::Matches($toml, 'mcp_servers\.autocad-bridge')).Count -eq 1)
$lsp = Get-Content (Join-Path $support 'acaddoc.lsp') -Raw
Check 'acaddoc.lsp block not duplicated' (([regex]::Matches($lsp, 'auto-NETLOAD: BEGIN')).Count -eq 1)

# ---- uninstall -------------------------------------------------------------------
Write-Host "`n### uninstall"
& $Installer -Uninstall
Check 'install folder removed' (-not (Test-Path $appDir))
Check 'registry key removed' (-not (Test-Path $app))
$lsp = Get-Content (Join-Path $support 'acaddoc.lsp') -Raw
Check 'acaddoc.lsp block removed' ($lsp -notlike '*_.NETLOAD*')
Check 'acaddoc.lsp user content kept' ($lsp -like '*user content*')
$toml = Get-Content (Join-Path $codexDir 'config.toml') -Raw
Check 'Codex entry removed' ($toml -notlike '*autocad-bridge*')
Check 'Codex user settings kept' ($toml -like '*model = "gpt-5"*')
Check 'skills removed' (-not (Test-Path (Join-Path $HOME '.agents\skills\safe-write-workflow')))

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
