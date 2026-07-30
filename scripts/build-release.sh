#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: TEAM_ID=... DEVELOPER_ID_APPLICATION='Developer ID Application: ...' NOTARY_PROFILE=... $0 <version> <build-number>" >&2
  echo "For same-Mac QA only: SKIP_NOTARIZATION=1 (NOTARY_PROFILE is then optional)." >&2
  exit 64
fi

: "${TEAM_ID:?Set TEAM_ID after joining Apple Developer Program}"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the exact certificate name}"
skip_notarization="${SKIP_NOTARIZATION:-0}"
if [[ "$skip_notarization" != "1" ]]; then
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE created by xcrun notarytool store-credentials}"
fi

version="$1"
build_number="$2"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /tmp/quill-release.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
output_dir="$repo_dir/dist"
archive_path="$work_dir/Quill.xcarchive"
export_path="$work_dir/export"
export_options="$work_dir/ExportOptions.plist"
submission_zip="$work_dir/Quill-notary.zip"
if [[ "$skip_notarization" == "1" ]]; then
  output_zip="$output_dir/Quill-$version-local-test.zip"
else
  output_zip="$output_dir/Quill-$version.zip"
fi

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

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>$DEVELOPER_ID_APPLICATION</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options"

app_path="$export_path/Quill.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"
if [[ "$skip_notarization" == "1" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_zip"
  "$repo_dir/scripts/verify-app.sh" "$output_zip"
  echo "Signed local QA build (not notarized): $output_zip"
  exit 0
fi
notary_result="$(xcrun notarytool submit "$submission_zip" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json)"
echo "$notary_result"
notary_status="$(printf '%s' "$notary_result" | plutil -extract status raw -o - -)"
if [[ "$notary_status" != "Accepted" ]]; then
  echo "Notarization failed with status: $notary_status" >&2
  exit 1
fi
xcrun stapler staple "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_zip"

"$repo_dir/scripts/verify-app.sh" "$output_zip" --distribution
echo "Notarized release: $output_zip"
