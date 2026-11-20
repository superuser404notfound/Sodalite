#!/usr/bin/env bash
# Regenerate Sodalite.xcodeproj from project.yml.
#
# project.yml is the single source of truth for the Xcode project. Never edit
# build settings in the Xcode UI, they are overwritten on the next generate.
# Edit project.yml and run this script.
#
# The pinned Package.resolved is preserved across regeneration so transitive
# SwiftPM dependencies never silently drift; only what project.yml requires
# (e.g. a bumped AetherEngine revision) changes on the following resolve.
set -euo pipefail
cd "$(dirname "$0")/.."

RESOLVED="Sodalite.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
BACKUP="$(mktemp)"
if [ -f "$RESOLVED" ]; then
  cp "$RESOLVED" "$BACKUP"
fi

xcodegen generate --spec project.yml

# XcodeGen cannot express package traits, so the `traits:` list under a package in project.yml is
# written into its package reference here, the way Xcode itself stores it. Without this every
# opt-in trait of AetherEngine (object audio) would silently be off after a generate.
python3 - <<'PY'
import re
pbx_path = "Sodalite.xcodeproj/project.pbxproj"
pbx = open(pbx_path).read()
traits, package, inside = {}, None, False
for line in open("project.yml").read().splitlines():
    if line == "packages:":
        inside = True
    elif inside and line and not line.startswith(" "):
        break
    elif inside and (m := re.match(r"^  ([\w-]+):$", line)):
        package = m.group(1)
    elif inside and package and (m := re.match(r"^    traits:\s*\[(.*)\]$", line)):
        traits[package] = [t.strip() for t in m.group(1).split(",") if t.strip()]
for name, names in traits.items():
    block = re.compile(r'(/\* XCRemoteSwiftPackageReference "' + re.escape(name)
                       + r'" \*/ = \{\n(?:\t\t\t.*\n)*?)(\t\t\};)')
    entry = "\t\t\ttraits = (\n" + "".join(f"\t\t\t\t{t},\n" for t in names) + "\t\t\t);\n"
    pbx, count = block.subn(lambda m: m.group(1) + entry + m.group(2), pbx, count=1)
    if count != 1:
        raise SystemExit(f"generate-project.sh: no package reference {name} to give its traits")
    print(f"Package {name}: traits {', '.join(names)}")
open(pbx_path, "w").write(pbx)
PY

if [ -s "$BACKUP" ]; then
  mkdir -p "$(dirname "$RESOLVED")"
  cp "$BACKUP" "$RESOLVED"
fi
rm -f "$BACKUP"

echo "Regenerated Sodalite.xcodeproj from project.yml (Package.resolved preserved)"

# The repo's hooks are tracked in Scripts/git-hooks, so a fresh clone gets them from the
# first generate rather than from a step nobody remembers. See that folder for what they guard.
if [ "$(git config --get core.hooksPath || true)" != "Scripts/git-hooks" ]; then
  chmod +x Scripts/git-hooks/*
  git config core.hooksPath Scripts/git-hooks
  echo "Installed the repo's git hooks (core.hooksPath = Scripts/git-hooks)"
fi
