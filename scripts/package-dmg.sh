#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
architecture=$(uname -m)
output="dist/releases/$version/$architecture"
asset="DiskLens-$version-$architecture.dmg"
notes="docs/releases/v$version.md"
if [[ ! -f "$notes" ]]; then
  echo "Missing release notes: $notes" >&2
  exit 1
fi
mkdir -p "$output" .build
bash scripts/build.sh "$output/DiskLens.app"
codesign --verify --strict "$output/DiskLens.app"
lipo "$output/DiskLens.app/Contents/MacOS/DiskLens" -verify_arch "$architecture"

stage=$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$output/DiskLens.app" "$stage/DiskLens.app"
ln -s /Applications "$stage/Applications"
cp "$notes" "$stage/Read Me.md"
cp LICENSE "$stage/LICENSE.txt"
codesign --verify --strict "$stage/DiskLens.app"

hdiutil create -volname "DiskLens $version" -srcfolder "$stage" \
  -format UDZO -ov "$output/$asset"
hdiutil verify "$output/$asset"
(
  cd "$output"
  shasum -a 256 "$asset" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
echo "Packaged: $output/$asset (ad-hoc signed; not notarized)"
