#!/bin/sh
set -eu

version=0.5.2
destination=${1:-.tmp/v}
archive=.tmp/v-${version}.zip
extract=.tmp/v-release

mkdir -p .tmp "$destination"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) asset=v_macos_arm64.zip ;;
  Darwin-x86_64) asset=v_macos_x86_64.zip ;;
  Linux-aarch64) asset=v_linux_arm64.zip ;;
  Linux-x86_64) asset=v_linux.zip ;;
  *) echo "unsupported platform" >&2; exit 1 ;;
esac
curl -fL "https://github.com/vlang/v/releases/download/${version}/${asset}" -o "$archive"
rm -rf "$extract"
mkdir -p "$extract"
unzip -q -o "$archive" -d "$extract"
cp -R "$extract/v/." "$destination/"
modules=${VMODULES:-.tmp/vmodules}
mkdir -p "$modules"
VMODULES="$modules" "$destination/v" version
