#!/bin/sh
# Builds a universal (Apple silicon and Intel) Skillscout Mod.app, with the fork's command
# inside, and an ad-hoc signature. Checks the signature survives zipping, and writes
# dist/Skillscout-Mod-<version>.zip. The names and version come from project.yml.
# Usage: scripts/build-release.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
NAME=$(sed -n 's/^name: *//p' project.yml)
APP_NAME=$(sed -n 's/^        PRODUCT_NAME: "\(.*\)"$/\1/p' project.yml | head -n 1)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
BUILD="$ROOT/build/release"
APP="$BUILD/Release/$APP_NAME.app"
ZIP="$ROOT/dist/Skillscout-Mod-$VERSION.zip"
CHECK=$(mktemp -d)

rm -rf "$BUILD" "$ZIP"
mkdir -p dist
xcodebuild -project "$NAME.xcodeproj" -target "$NAME" -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO SYMROOT="$BUILD" -quiet build

lipo "$APP/Contents/MacOS/$APP_NAME" -verify_arch arm64 x86_64
lipo "$APP/Contents/Helpers/skillscout-mod" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/$APP_NAME.app"
rm -rf "$CHECK"

echo "$ZIP"
shasum -a 256 "$ZIP"
