#!/usr/bin/env bash

# PhotosVideoSpeed 打包脚本（参考 TypeX/build.sh）
# 依次产出 iOS 16 / iOS 17 两个平台的 deb 到 packages/ios16 与 packages/ios17，
# 双平台构建完成后自动推进 control 的 Version。
# 不做坚果云归档、不发 Bark 通知，只做本地打包。

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

PACKAGE_ID="$(awk -F': ' '/^Package:/{print $2; exit}' "$ROOT_DIR/control")"
PACKAGE_VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$ROOT_DIR/control")"
if [[ -z "$PACKAGE_ID" || -z "$PACKAGE_VERSION" ]]; then
    echo "error: Package or Version is missing from $ROOT_DIR/control" >&2
    exit 1
fi

if [[ ! "$PACKAGE_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "error: Version must use MAJOR.MINOR.PATCH format: $PACKAGE_VERSION" >&2
    exit 1
fi

# PATCH counts 0-10; past 10 it carries into MINOR (3.0.10 -> 3.1.0), MINOR likewise into MAJOR.
NEXT_MAJOR="${BASH_REMATCH[1]}"
NEXT_MINOR="${BASH_REMATCH[2]}"
NEXT_PATCH="$((10#${BASH_REMATCH[3]} + 1))"
if (( NEXT_PATCH > 10 )); then
    NEXT_PATCH=0
    NEXT_MINOR="$((10#${BASH_REMATCH[2]} + 1))"
fi
if (( NEXT_MINOR > 10 )); then
    NEXT_MINOR=0
    NEXT_MAJOR="$((10#${BASH_REMATCH[1]} + 1))"
fi
NEXT_VERSION="${NEXT_MAJOR}.${NEXT_MINOR}.${NEXT_PATCH}"

build_one() {
    local label="$1"
    local sdk_version="$2"
    local deployment_version="$3"
    local sdk_path="$THEOS/sdks/iPhoneOS${sdk_version}.sdk"
    local output_dir="$ROOT_DIR/packages/$label"
    local output_path="$output_dir/${PACKAGE_ID}_${NEXT_VERSION}_${label}_iphoneos-arm64e.deb"

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
        THEOS_PACKAGE_SCHEME=roothide \
            TARGET="iphone:clang:${sdk_version}:${deployment_version}" \
            "$MAKE_BIN" package FINALPACKAGE=1 PACKAGE_VERSION="$NEXT_VERSION"
    )

    mkdir -p "$output_dir"
    find "$output_dir" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true

    local package_path
    package_path="$(find "$ROOT_DIR/packages" -maxdepth 1 -type f -name "${PACKAGE_ID}_${NEXT_VERSION}_*.deb" -print -quit)"
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

# Persist the version only after both platform builds have completed.
CONTROL_TMP="$(mktemp "$ROOT_DIR/control.tmp.XXXXXX")"

awk -v next_version="$NEXT_VERSION" '
    BEGIN { updated = 0 }
    /^Version:/ {
        print "Version: " next_version
        updated = 1
        next
    }
    { print }
    END {
        if (!updated) exit 1
    }
' "$ROOT_DIR/control" > "$CONTROL_TMP"
mv "$CONTROL_TMP" "$ROOT_DIR/control"

echo "==> Build completed successfully: $PACKAGE_VERSION -> $NEXT_VERSION"
