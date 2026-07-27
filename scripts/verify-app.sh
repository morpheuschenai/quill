#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <Quill.app|Quill.zip> [--distribution]" >&2
  exit 64
fi

input_path="$1"
mode="${2:-}"
work_dir=""

if [[ "$input_path" == *.zip ]]; then
  work_dir="$(mktemp -d /tmp/quill-verify.XXXXXX)"
  trap 'rm -rf "$work_dir"' EXIT
  ditto -x -k "$input_path" "$work_dir"
  app_path="$work_dir/Quill.app"
else
  app_path="$input_path"
fi

test -d "$app_path"
binary="$app_path/Contents/MacOS/Quill"
architectures="$(lipo -archs "$binary")"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")"
feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app_path/Contents/Info.plist")"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app_path/Contents/Info.plist")"

[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]]
[[ "$minimum_system" == "13.0" ]]
[[ "$feed_url" == "https://quill.morpheuschen.com/appcast.xml" ]]
[[ -n "$public_key" ]]
codesign --verify --deep --strict --verbose=2 "$app_path"

if [[ "$mode" == "--distribution" ]]; then
  spctl --assess --type execute --verbose=2 "$app_path"
  xcrun stapler validate "$app_path"
fi

echo "Architectures: $architectures"
echo "Minimum macOS: $minimum_system"
echo "Sparkle feed: $feed_url"
echo "Verification: passed"
