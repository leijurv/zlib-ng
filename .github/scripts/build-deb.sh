#!/bin/sh
# Build the zlib-ng Debian packages from this packaging-only repository.
#
# This repository only carries debian/, so the upstream source is fetched as
# the .orig tarball (from the same location debian/watch points at), unpacked
# into build/, and built with dpkg-buildpackage. Meant to run inside a
# debian:trixie container, both in CI and locally:
#
#   docker run --rm -v "$PWD:/src" -w /src debian:trixie .github/scripts/build-deb.sh
#
# Environment:
#   BUILD_TYPE        dpkg-buildpackage --build value (default: full)
#   SNAPSHOT_SUFFIX   if set, "+SUFFIX" is appended to the changelog version
#   OUTPUT_DIR        where the build products are collected (default: build)
set -eu

OUTPUT_DIR=${OUTPUT_DIR:-build}
BUILD_TYPE=${BUILD_TYPE:-full}
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n==> %s\n' "$*"; }

step "Installing packaging tools"
apt-get update
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl devscripts dpkg-dev fakeroot lintian

step "Determining versions from debian/changelog"
source=$(dpkg-parsechangelog -SSource)
version=$(dpkg-parsechangelog -SVersion)
# Strip the epoch and the Debian revision to get the upstream version.
upstream=${version#*:}
upstream=${upstream%-*}
echo "source=$source version=$version upstream=$upstream"

orig="$OUTPUT_DIR/${source}_${upstream}.orig.tar.gz"
srcdir="$OUTPUT_DIR/${source}-${upstream}"

step "Fetching upstream tarball"
mkdir -p "$OUTPUT_DIR"
# Drop products of a previous run, but keep the (cached) upstream tarball.
find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 ! -name '*.orig.tar.*' -exec rm -rf {} +
if [ ! -s "$orig" ]; then
  curl -fsSL --retry 5 --retry-all-errors \
    -o "$orig" "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${upstream}.tar.gz"
fi
sha256sum "$orig"

step "Preparing source tree in $srcdir"
rm -rf "$srcdir"
mkdir -p "$srcdir"
tar -xzf "$orig" -C "$srcdir" --strip-components=1
cp -a debian "$srcdir/"

if [ -n "${SNAPSHOT_SUFFIX:-}" ]; then
  step "Marking snapshot version $version+$SNAPSHOT_SUFFIX"
  (
    cd "$srcdir"
    DEBFULLNAME=${DEBFULLNAME:-GitHub Actions} \
    DEBEMAIL=${DEBEMAIL:-actions@github.com} \
      dch --newversion "$version+$SNAPSHOT_SUFFIX" --distribution UNRELEASED \
        "CI snapshot build."
    dpkg-parsechangelog -SVersion
  )
fi

step "Installing build dependencies"
apt-get build-dep -y --no-install-recommends "./$srcdir"

step "Building packages (--build=$BUILD_TYPE)"
(
  cd "$srcdir"
  dpkg-buildpackage -us -uc --build="$BUILD_TYPE"
)

step "Running lintian"
lintian --info --fail-on error "$OUTPUT_DIR"/*.changes

step "Checking that the packages install"
apt-get install -y --no-install-recommends "./$OUTPUT_DIR"/*.deb
dpkg -l 'libz-ng*'

step "Build products in $OUTPUT_DIR"
rm -rf "$srcdir"
ls -l "$OUTPUT_DIR"
