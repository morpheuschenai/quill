#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <notarized-Quill-version.zip> <download-url-prefix>" >&2
  exit 64
fi

archive_path="$1"
download_prefix="${2%/}"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
sparkle_root="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' -type f -print -quit)"

if [[ -z "$sparkle_root" ]]; then
  echo "Sparkle generate_appcast was not found. Resolve Swift packages in Xcode first." >&2
  exit 1
fi

work_dir="$(mktemp -d /tmp/quill-appcast.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
cp "$archive_path" "$work_dir/"

"$sparkle_root" \
  --account com.morpheus.quill \
  --download-url-prefix "$download_prefix" \
  --link "https://quill.morpheuschen.com/" \
  --maximum-versions 3 \
  "$work_dir"

cp "$work_dir/appcast.xml" "$repo_dir/landing/appcast.xml"
echo "Updated: $repo_dir/landing/appcast.xml"
