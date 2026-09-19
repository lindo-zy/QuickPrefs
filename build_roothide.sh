#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${THEOS:-}" || ! -d "${THEOS:-}" ]]; then
    THEOS="/Users/xiao/dev/theos-roothide"
fi
export THEOS

MAKE_BIN="$(command -v gmake || command -v make || true)"
if [[ -z "$MAKE_BIN" ]]; then
    echo "error: make or gmake is required" >&2
    exit 1
fi

if [[ ! -d "$THEOS" ]]; then
    echo "error: Theos not found at $THEOS" >&2
    echo "Set THEOS to your local Theos directory before running this script." >&2
    exit 1
fi

# The roothide-scheme Cephei frameworks (jbroot install-names) are vendored
# in this repo; theos searches vendor/lib/iphone/roothide first when the
# roothide scheme is active. The CI theos is cached by theos-action, so
# reinstall unconditionally to guarantee this repo's current frameworks
# are what gets linked.
CEPHEI_DEST_DIR="$THEOS/vendor/lib/iphone/roothide"
for framework in Cephei CepheiPrefs CepheiUI; do
    if [[ ! -d "$ROOT_DIR/Vendor/Cephei/$framework.framework" ]]; then
        echo "error: vendored framework not found: $ROOT_DIR/Vendor/Cephei/$framework.framework" >&2
        exit 1
    fi
    echo "==> Installing $framework.framework into $CEPHEI_DEST_DIR"
    rm -rf "$CEPHEI_DEST_DIR/$framework.framework"
    mkdir -p "$CEPHEI_DEST_DIR"
    cp -R "$ROOT_DIR/Vendor/Cephei/$framework.framework" "$CEPHEI_DEST_DIR/"
done

PACKAGE_ID="$(awk -F': ' '/^Package:/{print $2; exit}' "$ROOT_DIR/control")"
PACKAGE_VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$ROOT_DIR/control")"
if [[ -z "$PACKAGE_ID" || -z "$PACKAGE_VERSION" ]]; then
    echo "error: Package or Version is missing from $ROOT_DIR/control" >&2
    exit 1
fi

if [[ ! "$PACKAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: Version must use MAJOR.MINOR.PATCH format: $PACKAGE_VERSION" >&2
    exit 1
fi

build_one() {
    local label="$1"
    local sdk_version="$2"
    local deployment_version="$3"
    local sdk_path="$THEOS/sdks/iPhoneOS${sdk_version}.sdk"
    local output_dir="$ROOT_DIR/packages/$label"
    local output_path="$output_dir/${PACKAGE_ID}_${PACKAGE_VERSION}_${label}_iphoneos-arm64e.deb"

    if [[ ! -d "$sdk_path" ]]; then
        echo "error: required SDK not found: $sdk_path" >&2
        exit 1
    fi

    echo "==> Building $label with iPhoneOS${sdk_version}.sdk"

    # Keep the package root clean so the result can be identified unambiguously.
    find "$ROOT_DIR/packages" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true
    "$MAKE_BIN" -C "$ROOT_DIR" clean >/dev/null

    (
        cd "$ROOT_DIR"
        # Pass these as command-line variables so they override the root
        # Makefile's hardcoded rootless scheme and toolchain PREFIX.
        "$MAKE_BIN" package \
            THEOS_PACKAGE_SCHEME=roothide \
            TARGET="iphone:clang:${sdk_version}:${deployment_version}" \
            PREFIX= \
            FINALPACKAGE=1 PACKAGE_VERSION="$PACKAGE_VERSION"
    )

    mkdir -p "$output_dir"
    find "$output_dir" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true

    local package_path
    package_path="$(find "$ROOT_DIR/packages" -maxdepth 1 -type f -name "${PACKAGE_ID}_${PACKAGE_VERSION}_*.deb" -print -quit)"
    if [[ -z "$package_path" ]]; then
        echo "error: package was not produced for $label" >&2
        exit 1
    fi

    mv "$package_path" "$output_path"
    echo "==> Output: $output_path"
}

build_one ios16 16.5 16.0
# Keep the iOS 17 build compatible with the reference package:
# build against the iOS 16 SDK while retaining iOS 15+ ABI support.
build_one ios17 16.5 15.0

echo "==> Build completed successfully: $PACKAGE_ID $PACKAGE_VERSION"
