# install-autoload.ps1 -- per-user (HKCU) registration of ClaudeBridge.AutoCad
# as a demand-loaded .NET plugin in AutoCAD 2020.
#
# Mechanism: AutoCAD's standard Applications-registry autoload, identical to how
# native .ARX/.CRX plugins are registered, with one extra flag (MANAGED=1) that
# tells AutoCAD's loader "this DLL is .NET — route it through NETLOAD".
#
# Effect after running once:
#   - AutoCAD 2020 sees ClaudeBridge in APPLOAD's "Startup Suite" list
#   - First call to any CLAUDE_* command (CLAUDE_PING, CLAUDE_SUMMARY, etc.)
#     auto-loads the plugin DLL via the registered LOADER path
#   - Subsequent builds rebuild the DLL behind the `current\` junction; on the
#     next AutoCAD start the fresh DLL gets loaded with no script changes needed
#
# Why HKCU (and not HKLM): per-user install, no admin elevation required.
# Why MANAGED=1: differentiates managed (.NET) from native ARX in AutoCAD's loader.
# Why LOADCTRLS=3 (=0x01|0x02): load on AutoCAD startup AND on first command.
#   Pure on-command (=0x02) is finicky for .NET plugins in AutoCAD 2020 — it
#   sometimes silently fails to fire demand-load, leaving the user with
#   "Unknown command" errors. The startup-bit (=0x01) guarantees the plugin
#   is in memory by the time any CLAUDE_* is typed. Plugin is ~140KB, no
#   meaningful startup overhead.
#
# Idempotent: re-running updates LOADER path but doesn't duplicate. -Remove
# unregisters cleanly. Original NanoCAD-side ncad.lsp chain logic is gone.

[CmdletBinding()]
param(
    # AutoCAD product/locale branch, e.g. ACAD-3001:419 (ru-RU) or ACAD-3001:409
    # (en-US). Empty = auto-detect from the CurVer value written by AutoCAD.
    [string]$LocaleKey = "",
    # R-version under HKCU\Software\Autodesk\AutoCAD\
    [string]$RVersion = "R23.1",
    # Absolute path to the plugin DLL. Defaults to the build.ps1-maintained
    # `current\` junction so we always load the most recent successful build.
    [string]$DllPath = (Join-Path $PSScriptRoot "..\..\artifacts\ClaudeBridge.AutoCad\current\ClaudeBridge.AutoCad.dll"),
    # Application key name under Applications\. Stay alphanumeric.
    [string]$AppName = "ClaudeBridge",
    # If set, unregister instead of register.
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# ---- locale detection ----------------------------------------------------

$ProductRoot = "HKCU:\Software\Autodesk\AutoCAD\$RVersion"
if (-not $LocaleKey) {
    if (-not (Test-Path $ProductRoot)) {
        throw "AutoCAD $RVersion not found in the current user profile ($ProductRoot). Install AutoCAD 2020 and start it at least once, then re-run."
    }
    $LocaleKey = (Get-ItemProperty $ProductRoot -Name CurVer -ErrorAction SilentlyContinue).CurVer
    if (-not $LocaleKey -or -not (Test-Path (Join-Path $ProductRoot $LocaleKey))) {
        $candidates = @(Get-ChildItem $ProductRoot | Where-Object { $_.PSChildName -like 'ACAD-*:*' } | Sort-Object PSChildName)
        if ($candidates.Count -eq 0) {
            throw "No ACAD-*:* product branch under $ProductRoot. Start AutoCAD 2020 once, then re-run."
        }
        $LocaleKey = $candidates[0].PSChildName
    }
}

# Language folder name used under %APPDATA%\Autodesk\AutoCAD 2020\<R>\<lang>\Support,
# derived from the LCID suffix of the locale key (ACAD-3001:419 -> 419 -> rus).
$LangByLcid = @{
    '409' = 'enu'; '419' = 'rus'; '407' = 'deu'; '40C' = 'fra'; '410' = 'ita'
    '40A' = 'esp'; '416' = 'ptb'; '405' = 'csy'; '415' = 'plk'; '40E' = 'hun'
    '411' = 'jpn'; '412' = 'kor'; '804' = 'chs'; '404' = 'cht'
}
$lcid = ($LocaleKey -split ':')[-1].ToUpperInvariant()
$LangCode = $LangByLcid[$lcid]
$SupportDir = $null
if ($LangCode) {
    $SupportDir = Join-Path $env:APPDATA "Autodesk\AutoCAD 2020\$RVersion\$LangCode\Support"
}
if (-not $SupportDir -or -not (Test-Path $SupportDir)) {
    # Unknown LCID or a vertical product (Map 3D, Mechanical...) with its own folder name.
    $found = @(Get-ChildItem (Join-Path $env:APPDATA 'Autodesk') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName $RVersion) -Directory -ErrorAction SilentlyContinue } |
        ForEach-Object { Join-Path $_.FullName 'Support' } |
        Where-Object { Test-Path $_ })
    $SupportDir = if ($found.Count -gt 0) { $found[0] } else { $null }
}

# acaddoc.lsp is read by AutoCAD 2020 in the system ANSI code page, so write it
# that way (keeps non-ASCII user-profile paths intact). No BOM.
$AnsiEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
function Read-Lsp([string]$path) { [System.IO.File]::ReadAllText($path, $AnsiEncoding) }
function Write-Lsp([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, $AnsiEncoding) }

# Full registry path for this app under the user's AutoCAD profile.
$AppsRoot = "HKCU:\Software\Autodesk\AutoCAD\$RVersion\$LocaleKey\Applications"
$AppKey   = Join-Path $AppsRoot $AppName
$CmdsKey  = Join-Path $AppKey "Commands"

# The complete CLAUDE_* command surface registered by our [CommandMethod] attributes
# in src/AutoCad/Commands/*.cs (see CommandClass list in Properties/AssemblyInfo.cs) + HttpControlCommands.
# AutoCAD uses this list for demand-load: when any of these is typed at the
# command line, the LOADER DLL is loaded automatically.
$Commands = @(
    "CLAUDE_PING",
    "CLAUDE_SUMMARY",
    "CLAUDE_SNAPSHOT",
    "CLAUDE_PROBE",
    "CLAUDE_QUERY",
    "CLAUDE_EXEC",
    "CLAUDE_CAMERA",
    "CLAUDE_OVERLAY",
    "CLAUDE_PROBE_SEND",
    "CLAUDE_BATCH_CAPTURE",
    "CLAUDE_BATCH_CAPTURE_LAYOUTS",
    "CLAUDE_EXTRACT_ROUTE",
    "CLAUDE_HTTP_START",
    "CLAUDE_HTTP_STOP",
    "CLAUDE_HTTP_STATUS"
)

# ---- precondition checks ------------------------------------------------

if (-not (Test-Path $AppsRoot)) {
    throw "AutoCAD Applications branch not found: $AppsRoot. Either AutoCAD $RVersion is not installed under this user profile, or the LocaleKey is wrong. Use -LocaleKey '<ACAD-XXXX:YYY>' to override; current detected value: '$LocaleKey'."
}

# ---- uninstall path ----------------------------------------------------

if ($Remove) {
    if (Test-Path $AppKey) {
        Remove-Item -Path $AppKey -Recurse -Force
        Write-Host "Unregistered: $AppKey"
    } else {
        Write-Host "Nothing to remove at $AppKey (already absent)."
    }
    # Strip our acaddoc.lsp block too.
    $acaddocPath = if ($SupportDir) { Join-Path $SupportDir "acaddoc.lsp" } else { $null }
    $markerOpen  = ";; cad-agent-mcp (AutoCAD) auto-NETLOAD: BEGIN (managed by install-autoload.ps1)"
    $markerClose = ";; cad-agent-mcp (AutoCAD) auto-NETLOAD: END"
    if ($acaddocPath -and (Test-Path $acaddocPath)) {
        $existing = Read-Lsp $acaddocPath
        if ($existing.Contains($markerOpen) -and $existing.Contains($markerClose)) {
            $startIdx = $existing.IndexOf($markerOpen)
            $endIdx   = $existing.IndexOf($markerClose) + $markerClose.Length
            $new = ($existing.Substring(0, $startIdx) + $existing.Substring($endIdx)).TrimEnd()
            if ([string]::IsNullOrWhiteSpace($new)) {
                Remove-Item $acaddocPath
                Write-Host "Removed empty acaddoc.lsp at $acaddocPath"
            } else {
                Write-Lsp $acaddocPath $new
                Write-Host "Stripped block from acaddoc.lsp at $acaddocPath"
            }
        }
    }
    exit 0
}

# ---- install path ------------------------------------------------------

if (-not (Test-Path $DllPath)) {
    Write-Warning "DLL path does not exist: $DllPath. Run build.ps1 first, otherwise AutoCAD will fail to load on first CLAUDE_* call."
    # Continue anyway — registry can point at a not-yet-existing path; user can
    # run build.ps1 afterwards. AutoCAD only resolves the path on first load.
}

# Create / update the application key.
if (-not (Test-Path $AppKey)) {
    New-Item -Path $AppKey -Force | Out-Null
    Write-Host "Created: $AppKey"
}

# Set required values.
# LOADER     — full path to the assembly DLL. AutoCAD resolves this on demand.
# MANAGED    — DWORD 1 = treat as .NET assembly (routed through NETLOAD).
# LOADCTRLS  — DWORD 3 = load on startup (=0x01) + on registered command (=0x02).
#              Bit-mask per Autodesk: 1=onstart, 2=on-command, 4=on-proxy,
#              8=on-request. Combined value 3 gives the plugin both auto-load
#              on every AutoCAD launch and demand-load fallback if the startup
#              load is suppressed for any reason.
# DESCRIPTION — REG_SZ shown in APPLOAD's Contents list.
Set-ItemProperty -Path $AppKey -Name "LOADER"      -Value $DllPath              -Type String
Set-ItemProperty -Path $AppKey -Name "MANAGED"     -Value 1                     -Type DWord
Set-ItemProperty -Path $AppKey -Name "LOADCTRLS"   -Value 3                     -Type DWord
Set-ItemProperty -Path $AppKey -Name "DESCRIPTION" -Value "ClaudeBridge for AutoCAD: eyes-and-hands MCP bridge" -Type String

# (Re)create Commands subkey populated from the canonical list.
# Each entry: value-name = global command, value-data = local (translated) name.
# We keep them identical; if a locale needs differing names, add a $LocalCommands map.
if (Test-Path $CmdsKey) {
    Remove-Item -Path $CmdsKey -Recurse -Force
}
New-Item -Path $CmdsKey -Force | Out-Null
foreach ($cmd in $Commands) {
    Set-ItemProperty -Path $CmdsKey -Name $cmd -Value $cmd -Type String
}

# ---- TRUSTEDPATHS ------------------------------------------------------

# AutoCAD 2014+ refuses to autoload .NET assemblies from paths NOT listed in
# the active profile's TRUSTEDPATHS sysvar (SECURELOAD=1 default behavior).
# Manual NETLOAD shows a "trust this DLL?" dialog the user can dismiss; autoload
# silently skips. Since AutoCAD profiles can be switched between sessions and
# we can't reliably know which profile is active at next start, register our
# artifacts folder in EVERY profile under this locale branch.
$DllDir = Split-Path -Parent $DllPath
$ProfilesRoot = "HKCU:\Software\Autodesk\AutoCAD\$RVersion\$LocaleKey\Profiles"
$trustedAdded = 0
$trustedSkipped = 0
if (Test-Path $ProfilesRoot) {
    foreach ($profile in Get-ChildItem $ProfilesRoot) {
        $varsKey = Join-Path $profile.PSPath "Variables"
        if (-not (Test-Path $varsKey)) {
            # Profile has no Variables subkey yet — AutoCAD creates it on first
            # launch with that profile. Create it now so our entry persists.
            New-Item -Path $varsKey -Force | Out-Null
        }
        $existing = (Get-ItemProperty $varsKey -Name "TRUSTEDPATHS" -ErrorAction SilentlyContinue).TRUSTEDPATHS
        if ($null -eq $existing) { $existing = "" }
        # Normalize: split on ';', drop empties, check if our dir is already in.
        $entries = $existing -split ';' | Where-Object { $_ -ne "" } | ForEach-Object { $_.TrimEnd('\') }
        $needle = $DllDir.TrimEnd('\')
        if ($entries -contains $needle) {
            $trustedSkipped++
        } else {
            $entries = @($entries) + $needle
            $newValue = ($entries -join ';') + ';'   # canonical trailing-semicolon form
            Set-ItemProperty -Path $varsKey -Name "TRUSTEDPATHS" -Value $newValue -Type String
            $trustedAdded++
        }
    }
}

# ---- acaddoc.lsp NETLOAD hook ------------------------------------------

# Registry-based autoload (Applications + MANAGED=1) is the canonical Autodesk
# pattern but is known to silently fail in some AutoCAD 2020 setups (profile
# overrides, HKCU vs HKLM resolution quirks). The acaddoc.lsp hook is the
# bulletproof fallback: AutoCAD reads it on every document open, and we
# invoke `_.NETLOAD` directly. With TRUSTEDPATHS containing our DLL dir
# (set above), the security prompt is bypassed.
#
# Path: %APPDATA%\Autodesk\AutoCAD 2020\R23.1\<lang>\Support\acaddoc.lsp (lang from LocaleKey)
# We use sentinel comments around our block for idempotency / clean uninstall.
$acaddocPath = if ($SupportDir) { Join-Path $SupportDir "acaddoc.lsp" } else { $null }
$markerOpen  = ";; cad-agent-mcp (AutoCAD) auto-NETLOAD: BEGIN (managed by install-autoload.ps1)"
$markerClose = ";; cad-agent-mcp (AutoCAD) auto-NETLOAD: END"

# LISP-escape the DLL path: backslashes need doubling.
$lispDllPath = $DllPath -replace '\\', '\\'

$block = @"
$markerOpen
(vl-load-com)
(if (findfile "$lispDllPath")
  (vl-catch-all-apply
    '(lambda () (command "_.NETLOAD" "$lispDllPath")))
  (princ "\ncad-agent-mcp (AutoCAD): skip auto-NETLOAD, DLL not built yet at $lispDllPath"))
(princ)
$markerClose
"@

if (-not $acaddocPath) {
    Write-Warning "AutoCAD support folder not found under $env:APPDATA\Autodesk. Skipping acaddoc.lsp hook; start AutoCAD 2020 at least once to create the profile, then re-run."
} else {
    if ($acaddocPath -and (Test-Path $acaddocPath)) {
        $existing = Read-Lsp $acaddocPath
        if ($existing.Contains($markerOpen) -and $existing.Contains($markerClose)) {
            # Replace our existing block in-place via substring math (regex
            # replacement on multiline blocks with backslashes is fragile).
            $startIdx = $existing.IndexOf($markerOpen)
            $endIdx   = $existing.IndexOf($markerClose) + $markerClose.Length
            $new = $existing.Substring(0, $startIdx) + $block + $existing.Substring($endIdx)
            Write-Lsp $acaddocPath $new
            Write-Host "acaddoc.lsp: updated existing block at $acaddocPath"
        } else {
            Write-Lsp $acaddocPath ($existing.TrimEnd() + "`r`n" + $block)
            Write-Host "acaddoc.lsp: appended block to existing file at $acaddocPath"
        }
    } else {
        Write-Lsp $acaddocPath $block
        Write-Host "acaddoc.lsp: created fresh at $acaddocPath"
    }
}

Write-Host ""
Write-Host "AutoCAD profile branch: $LocaleKey"
Write-Host "Registered ClaudeBridge.AutoCad for autoload (two mechanisms, belt-and-suspenders):"
Write-Host "  1. Applications registry: $AppKey"
Write-Host "       LOADER:    $DllPath"
Write-Host "       Commands:  $($Commands.Count) registered"
Write-Host "  2. acaddoc.lsp NETLOAD:    $acaddocPath"
Write-Host "  TRUSTEDPATHS: added '$DllDir' to $trustedAdded profile(s), already present in $trustedSkipped"
Write-Host ""
Write-Host "To activate: close AutoCAD if running, then start fresh. The plugin loads automatically"
Write-Host "the first time you type any registered CLAUDE_* command. To verify, run CLAUDE_PING."
Write-Host ""
Write-Host "To unregister: .\install-autoload.ps1 -Remove"
