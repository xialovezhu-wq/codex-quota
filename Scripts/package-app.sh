#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="${1:-${project_dir}/dist}"
app_path="${output_dir}/Codex 余量.app"

cd "$project_dir"
swift build -c release

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp ".build/release/CodexQuotaApp" "$app_path/Contents/MacOS/CodexQuotaApp"
cp "Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"

identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p' | head -n 1)"
if [[ -n "$identity" ]]; then
  codesign --force --deep --options runtime --timestamp=none --sign "$identity" "$app_path"
  print "Signed with: $identity"
else
  codesign --force --deep --options runtime --timestamp=none --sign - "$app_path"
  print "Signed ad hoc"
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
print "$app_path"
