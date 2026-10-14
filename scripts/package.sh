#!/usr/bin/env bash
# Build dist/opencode-subagents.zip: the skill folder as marketplaces (Agensi and others) expect it,
# opencode-subagents/{SKILL.md,run.sh,README.md,LICENSE}.
set -euo pipefail
cd "$(dirname "$0")/.."
name="$(sed -n 's/^name: //p' SKILL.md | head -1)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/$name" dist
cp SKILL.md run.sh README.md LICENSE "$tmp/$name/"
chmod +x "$tmp/$name/run.sh"
rm -f "dist/$name.zip"
(cd "$tmp" && zip -qrX - "$name") >"dist/$name.zip"
echo "dist/$name.zip"
