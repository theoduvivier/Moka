#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
VERSION=2.10.1
EXPECTED=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
ROOT="$PROJECT_DIR/build/dependencies"
ARCHIVE="$ROOT/Sparkle-$VERSION.tar.xz"
DESTINATION="$ROOT/sparkle-$VERSION"
mkdir -p "$ROOT"
if [[ ! -f "$ARCHIVE" ]]; then
  /usr/bin/curl --fail --location --retry 2 "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$ARCHIVE.part"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/cut -d ' ' -f 1)"
[[ "$ACTUAL" == "$EXPECTED" ]] || { print -u2 'Sparkle archive checksum mismatch.'; exit 1; }
# Re-extract the verified archive; never trust an edited dependency cache.
mkdir -p "$DESTINATION"
/usr/bin/tar -xf "$ARCHIVE" -C "$DESTINATION"
print "$DESTINATION"
