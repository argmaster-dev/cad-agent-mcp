#!/usr/bin/env bash
# Builds the AutoCAD release archive: dist-release/cad-agent-mcp-autocad.zip
#
#   scripts/release/package.sh v0.1.0
#
# Works on Linux and macOS (and in GitHub Actions): the plugin compiles against
# Autodesk's AutoCAD.NET reference package from NuGet, no AutoCAD install needed.
# Requires: .NET SDK (see global.json), Node.js 18+, zip.
#
# Archive layout (what install.ps1 expects):
#   VERSION
#   plugin/ClaudeBridge.AutoCad.dll, Newtonsoft.Json.dll
#   server/index.mjs                 single-file MCP server, needs only Node.js
#   skills/<name>/SKILL.md
#   tools/install-autoload.ps1
#   LICENSE, README.md
set -euo pipefail

VERSION="${1:?usage: package.sh <version, e.g. v0.1.0>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/dist-release"
STAGE="$OUT/stage-autocad"
DOTNET="${DOTNET:-dotnet}"

rm -rf "$STAGE" "$OUT/cad-agent-mcp-autocad.zip"
mkdir -p "$STAGE"/{plugin,server,tools}

echo "==> plugin"
"$DOTNET" build "$ROOT/src/AutoCad/ClaudeBridge.AutoCad.csproj" -c Release \
  -o "$OUT/build-autocad" -nologo -v quiet
cp "$OUT/build-autocad/ClaudeBridge.AutoCad.dll" "$OUT/build-autocad/Newtonsoft.Json.dll" "$STAGE/plugin/"

echo "==> MCP server"
(cd "$ROOT/mcp-server/autocad" && npm ci --no-audit --no-fund --silent && npm run --silent bundle)
cp "$ROOT/mcp-server/autocad/bundle/index.mjs" "$STAGE/server/index.mjs"

echo "==> skills and tools"
cp -r "$ROOT/skills" "$STAGE/skills"
cp "$ROOT/scripts/autocad/install-autoload.ps1" "$STAGE/tools/"
cp "$ROOT/LICENSE" "$ROOT/README.md" "$STAGE/"
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

(cd "$STAGE" && zip -qr "$OUT/cad-agent-mcp-autocad.zip" .)
cp "$ROOT/install.ps1" "$OUT/install.ps1"
echo "==> $OUT/cad-agent-mcp-autocad.zip"
(cd "$OUT" && unzip -l cad-agent-mcp-autocad.zip | tail -n +4 | head -n -2 | awk '{print "   " $4}')
