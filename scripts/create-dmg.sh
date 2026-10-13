#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <Quill.app> <output.dmg> [en|zh-TW]" >&2
  exit 64
fi

app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output_path="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
language="${3:-en}"
case "$language" in
  en) background_svg="$repo_dir/release-assets/dmg-background.svg" ;;
  zh-TW) background_svg="$repo_dir/release-assets/dmg-background-zh-TW.svg" ;;
  *)
    echo "Unsupported DMG language: $language (use en or zh-TW)" >&2
    exit 64
    ;;
esac
work_dir="$(mktemp -d /tmp/quill-dmg.XXXXXX)"
stage_dir="$work_dir/stage"
mount_dir=""
rw_dmg="$work_dir/Quill-rw.dmg"
volume_name="Quill Installer"

cleanup() {
  if [[ -n "$mount_dir" ]] && mount | grep -Fq "on $mount_dir "; then
    hdiutil detach "$mount_dir" -quiet || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ ! -d "$app_path" ]]; then
  echo "App not found: $app_path" >&2
  exit 66
fi

mkdir -p "$stage_dir/.background"
ditto "$app_path" "$stage_dir/Quill.app"
ln -s /Applications "$stage_dir/Applications"

sips -s format png "$background_svg" \
  --out "$stage_dir/.background/background.png" >/dev/null 2>&1
sips -s format png -z 840 1320 "$background_svg" \
  --out "$stage_dir/.background/background@2x.png" >/dev/null 2>&1
if [[ ! -f "$stage_dir/.background/background.png" || \
      ! -f "$stage_dir/.background/background@2x.png" ]]; then
  echo "Could not render DMG background" >&2
  exit 1
fi

hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$stage_dir" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$rw_dmg" >/dev/null

attach_output="$(hdiutil attach "$rw_dmg" \
  -readwrite \
  -noverify \
  -noautoopen)"
mount_dir="$(printf '%s\n' "$attach_output" | tail -1 | awk -F '\t' '{print $NF}')"

if [[ -z "$mount_dir" || ! -d "$mount_dir" ]]; then
  echo "Could not mount writable DMG" >&2
  exit 1
fi

open "$mount_dir"
sleep 1

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume_name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {120, 120, 780, 540}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 104
    set text size of theViewOptions to 16
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "Quill.app" of container window to {180, 210}
    set position of item "Applications" of container window to {480, 210}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$mount_dir" -quiet
hdiutil convert "$rw_dmg" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$output_path" >/dev/null

if [[ -n "${DMG_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$DMG_SIGN_IDENTITY" --timestamp "$output_path"
fi

hdiutil verify "$output_path" >/dev/null
echo "Created DMG: $output_path"
