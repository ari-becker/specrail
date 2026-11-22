#!/bin/sh
# Builds specrail's Debian package for one architecture, into dist/, with a
# file of its SHA-256 checksum beside it:
#
#   tools/package-deb.sh <amd64|arm64>
#
# The version is the one build.zig.zon names. The binary is static and built
# for the architecture's baseline CPU, so the package installs on Debian 13,
# or any system based on it, on any machine of that architecture. This needs
# dpkg-deb and sha256sum; the Release workflow runs it on Ubuntu.
set -eu

usage="usage: tools/package-deb.sh <amd64|arm64>"
case ${1:-} in
amd64) target=x86_64-linux ;;
arm64) target=aarch64-linux ;;
*)
  echo "$usage" >&2
  exit 2
  ;;
esac
arch=$1

cd "$(dirname "$0")/.."
version=$(sed -n 's/^    \.version = "\(.*\)",$/\1/p' build.zig.zon)
deb=specrail_${version}_$arch.deb
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

# Packages hold their files with these permissions, whatever the umask.
umask 022
root=$work/root
mkdir "$root"
zig build -Doptimize=ReleaseSafe -Dtarget="$target" -Dcpu=baseline --prefix "$root/usr"
install -D -m 0644 LICENSE "$root/usr/share/doc/specrail/copyright"

mkdir -m 0755 "$root/DEBIAN"
cat >"$root/DEBIAN/control" <<EOF
Package: specrail
Version: $version
Architecture: $arch
Maintainer: Ari Becker <ari-becker@users.noreply.github.com>
Installed-Size: $(du -sk "$root/usr" | cut -f 1)
Depends: git
Section: devel
Priority: optional
Homepage: https://github.com/ari-becker/specrail
Description: spec-driven development, on guardrails
 specrail keeps natural-language specs linked to the tests that prove them.
 Requirements live in numbered sections of Markdown files, and a test names
 the requirement it verifies in a one-line comment. specrail check fails
 while any finished requirement has no test, or while any comment no longer
 matches the section it names.
EOF

mkdir -p dist
dpkg-deb --root-owner-group -Zxz --build "$root" "dist/$deb" >/dev/null
(cd dist && sha256sum "$deb" >"$deb.sha256")
echo "dist/$deb"
