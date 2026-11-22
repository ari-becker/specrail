#!/bin/sh
# Installs specrail from the Debian package on one of its GitHub releases, on
# Debian 13 or a system based on it, for amd64 or arm64. Run it as root, as
# in a Dockerfile:
#
#   sh install.sh [<version>]
#
# The version, such as 0.1.0, is the latest release's when it is not given.
# apt installs git along with specrail, which needs it, and installs curl and
# ca-certificates first when curl is missing, to download the package.
#
# SPECRAIL_RELEASES, when set, is the URL to download from instead of the
# GitHub releases, laid out the same way:
# <url>/download/v<version>/specrail_<version>_<arch>.deb, and beside it the
# file of its checksum, with .sha256 added to its name.
set -eu

releases=${SPECRAIL_RELEASES:-https://github.com/ari-becker/specrail/releases}
version=${1:-}
version=${version#v}

fail() {
  echo "install.sh: $*" >&2
  exit 1
}

# Downloads URL $1 to file $2.
fetch() {
  curl -fsSL -o "$2" "$1" || fail "could not download $1"
}

[ "$(id -u)" -eq 0 ] || fail "this needs to run as root"
command -v dpkg >/dev/null || fail "this installs a Debian package, and there is no dpkg"
arch=$(dpkg --print-architecture)
case $arch in
amd64 | arm64) ;;
*) fail "there is no specrail package for $arch" ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
if ! command -v curl >/dev/null; then
  apt-get install -y -q --no-install-recommends ca-certificates curl
fi

if [ -z "$version" ]; then
  # GitHub redirects the latest release to the page of its tag.
  latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$releases/latest") ||
    fail "could not find the latest release at $releases"
  case $latest in
  */tag/v*) version=${latest##*/tag/v} ;;
  *) fail "found no latest release at $releases" ;;
  esac
fi
case $version in
'' | *[!0-9A-Za-z.+~-]*) fail "not a version: $version" ;;
esac

deb=specrail_${version}_$arch.deb
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM
# apt reads the package as its own user, _apt.
chmod 0755 "$work"
echo "downloading $deb"
fetch "$releases/download/v$version/$deb" "$work/$deb"
fetch "$releases/download/v$version/$deb.sha256" "$work/$deb.sha256"
(cd "$work" && sha256sum --check --quiet "$deb.sha256") ||
  fail "$deb does not match its checksum"
apt-get install -y -q --no-install-recommends "$work/$deb"
