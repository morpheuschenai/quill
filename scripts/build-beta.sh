#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_path="${1:-$repo_dir/dist/Quill-beta.zip}"
work_dir="$(mktemp -d /tmp/quill-beta.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$(dirname "$output_path")"

xcodebuild build \
  -project "$repo_dir/Quill/Quill.xcodeproj" \
  -scheme Quill \
  -configuration Release \
  -derivedDataPath "$work_dir/DerivedData" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO

app_path="$work_dir/DerivedData/Build/Products/Release/Quill.app"
codesign --force --deep --sign - "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_path"

"$repo_dir/scripts/verify-app.sh" "$output_path"
echo "Beta archive: $output_path"
