#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: TEAM_ID=... DEVELOPER_ID_APPLICATION='Developer ID Application: ...' NOTARY_PROFILE=... $0 <version> <build-number>" >&2
  exit 64
fi

: "${TEAM_ID:?Set TEAM_ID after joining Apple Developer Program}"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the exact certificate name}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE created by xcrun notarytool store-credentials}"

version="$1"
build_number="$2"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /tmp/quill-release.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
output_dir="$repo_dir/dist"
archive_path="$work_dir/Quill.xcarchive"
submission_zip="$work_dir/Quill-notary.zip"
output_zip="$output_dir/Quill-$version.zip"

mkdir -p "$output_dir"

xcodebuild archive \
  -project "$repo_dir/Quill/Quill.xcodeproj" \
  -scheme Quill \
  -configuration Release \
  -archivePath "$archive_path" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"

app_path="$archive_path/Products/Applications/Quill.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"
xcrun notarytool submit "$submission_zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_zip"

"$repo_dir/scripts/verify-app.sh" "$output_zip" --distribution
echo "Notarized release: $output_zip"
