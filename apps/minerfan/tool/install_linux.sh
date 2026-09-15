#!/bin/sh
# Installs the Linux release build for this user in ~/.local/opt/minerfan
# (or $MINERFAN_HOME). Build first with `flutter build linux --release`.
# minerfan must not be running: replacing the files of a running app can
# crash it. On its next start the app adds its launcher, dock icon and
# autostart entry by itself.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
bundle="$here/build/linux/x64/release/bundle"
dest="${MINERFAN_HOME:-$HOME/.local/opt/minerfan}"
if [ ! -x "$bundle/minerfan" ]; then
  echo "no build in $bundle; run: flutter build linux --release" >&2
  exit 1
fi
if pgrep -x minerfan >/dev/null; then
  echo "minerfan is running: quit it first (Settings, Quit minerfan)" >&2
  exit 1
fi
mkdir -p "$(dirname "$dest")"
rm -rf "$dest.new"
cp -a "$bundle" "$dest.new"
rm -rf "$dest"
mv "$dest.new" "$dest"
echo "installed in $dest"
