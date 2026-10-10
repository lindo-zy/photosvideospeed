#!/usr/bin/env python3
"""Extract unchanged production methods for the macOS UIKit-stub harness."""
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
methods = []
for signature in ("- (BOOL)bindPlayer:", "- (void)fadeView:", "- (void)hideViewNow:",
                  "- (BOOL)videoLayerIsGone", "- (void)sliderTouchEnded"):
    # Production top-level method closing braces are unindented. The nested
    # blocks in these methods are indented; reject ambiguous/missing matches.
    matches = list(re.finditer(r"^" + re.escape(signature) + r".*?^}", source, re.M | re.S))
    if len(matches) != 1:
        raise SystemExit(f"Expected one production method for {signature}, found {len(matches)}")
    methods.append(matches[0].group(0))
Path(sys.argv[2]).write_text("// Generated from Tweak.xm; do not edit.\n\n" + "\n\n".join(methods) + "\n")
