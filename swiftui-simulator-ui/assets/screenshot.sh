#!/usr/bin/env bash
# =============================================================================
# screenshot.sh - Capture iOS Simulator screenshot
# =============================================================================
#
# Usage:
#   ./screenshot.sh                                    # Screenshot booted sim
#   DEVICE_NAME="iPhone 16" ./screenshot.sh           # Screenshot specific device
#   DEVICE_UDID="XXXXX" ./screenshot.sh               # Screenshot by UDID
#   OUTPUT_DIR=/tmp/screenshots ./screenshot.sh       # Custom output directory
#   FILENAME=myscreen.png ./screenshot.sh             # Custom filename
#
# Environment Variables:
#   DEVICE_NAME     - Simulator name to screenshot (optional)
#   DEVICE_UDID     - Simulator UDID to screenshot (optional, takes precedence)
#   OUTPUT_DIR      - Output directory (default: /tmp/UIScreenshots)
#   FILENAME        - Output filename (default: screenshot-YYYYMMDD-HHMMSS.png)
#   DELAY           - Delay in seconds before screenshot (default: 0)
#
# If neither DEVICE_NAME nor DEVICE_UDID is set, screenshots the first booted
# simulator (which may be wrong if multiple are booted).
#
# =============================================================================

set -euo pipefail

# Configuration
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/UIScreenshots}"
FILENAME="${FILENAME:-screenshot-$(date +%Y%m%d-%H%M%S).png}"
DEVICE_NAME="${DEVICE_NAME:-}"
DEVICE_UDID="${DEVICE_UDID:-}"
DELAY="${DELAY:-0}"

# Helper functions
resolve_udid() {
  local name="$1"
  xcrun simctl list devices available | sed -nE "/$name/{s/.*\(([A-F0-9-]+)\).*/\1/p; q;}"
}

# Resolve UDID if name provided but no UDID
if [[ -z "$DEVICE_UDID" && -n "$DEVICE_NAME" ]]; then
  DEVICE_UDID=$(resolve_udid "$DEVICE_NAME")
  if [[ -z "$DEVICE_UDID" ]]; then
    echo "error: could not find simulator device named '$DEVICE_NAME'" >&2
    echo "Available devices:" >&2
    xcrun simctl list devices available | grep iPhone >&2
    exit 1
  fi
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

OUTPUT_PATH="$OUTPUT_DIR/$FILENAME"

# Wait if delay specified
if [[ "$DELAY" -gt 0 ]]; then
  sleep "$DELAY"
fi

# Take screenshot
if [[ -n "$DEVICE_UDID" ]]; then
  xcrun simctl io "$DEVICE_UDID" screenshot "$OUTPUT_PATH"
else
  # No specific device - use booted (may be wrong if multiple booted)
  xcrun simctl io booted screenshot "$OUTPUT_PATH"
fi

# Output path for capture by calling script
echo "$OUTPUT_PATH"
