#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/photos-video-speed-tests.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT

xcrun clang -O2 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework AVFoundation -framework QuartzCore \
    -framework CoreGraphics -framework CoreMedia \
    "$test_dir/VideoDetectionTests.m" -o "$test_tmp/video-detection-tests"
"$test_tmp/video-detection-tests"

python3 "$test_dir/extract_manager_methods.py" \
    "$test_dir/../Tweak.xm" "$test_tmp/ProductionManagerMethods.inc"
xcrun clang -O2 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework AVFoundation -framework QuartzCore \
    -framework CoreMedia \
    -I "$test_tmp" "$test_dir/ManagerRegressionTests.m" -o "$test_tmp/manager-regression-tests"
"$test_tmp/manager-regression-tests"
