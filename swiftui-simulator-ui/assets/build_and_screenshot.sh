#!/usr/bin/env bash
# =============================================================================
# build_and_screenshot.sh - Complete workflow: build, install, launch, screenshot
# =============================================================================
#
# Usage:
#   PROJECT_PATH=/path/to/App.xcodeproj \
#   SCHEME=AppScheme \
#   BUNDLE_ID=com.example.app \
#   ./build_and_screenshot.sh
#
# Environment Variables:
#   PROJECT_PATH    - Path to .xcodeproj or .xcworkspace (required)
#   SCHEME          - Xcode scheme to build (required)
#   BUNDLE_ID       - App bundle identifier (required)
#   DEVICE_NAME     - Simulator name (default: iPhone 16)
#   DERIVED_DATA    - Build output path (default: /tmp/AppBuild)
#   SCREENSHOT_DIR  - Screenshot output directory (default: /tmp/UIScreenshots)
#   SCREENSHOT_DELAY - Delay before screenshot in seconds (default: 1)
#   CLEAN_BUILD     - Set to "1" to clean before build
#   STATUS_BAR      - Set to "1" to override status bar for clean screenshots
#   DARK_MODE       - Set to "1" to enable dark mode before screenshot
#
# =============================================================================

set -euo pipefail

# Required configuration
PROJECT_PATH="${PROJECT_PATH:?Error: PROJECT_PATH is required}"
SCHEME="${SCHEME:?Error: SCHEME is required}"
BUNDLE_ID="${BUNDLE_ID:?Error: BUNDLE_ID is required}"

# Optional configuration with defaults
DEVICE_NAME="${DEVICE_NAME:-iPhone 16}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/AppBuild}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/UIScreenshots}"
SCREENSHOT_DELAY="${SCREENSHOT_DELAY:-1}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"
STATUS_BAR="${STATUS_BAR:-0}"
DARK_MODE="${DARK_MODE:-0}"

# Helper functions
log() {
  echo "[$(date +%H:%M:%S)] $*"
}

error() {
  echo "ERROR: $*" >&2
  exit 1
}

resolve_udid() {
  local name="$1"
  xcrun simctl list devices available | sed -nE "/$name/{s/.*\(([A-F0-9-]+)\).*/\1/p; q;}"
}

# Determine project type
if [[ "$PROJECT_PATH" == *.xcworkspace ]]; then
  BUILD_FLAG="-workspace"
elif [[ "$PROJECT_PATH" == *.xcodeproj ]]; then
  BUILD_FLAG="-project"
else
  error "PROJECT_PATH must be .xcworkspace or .xcodeproj"
fi

# Resolve simulator
log "Finding simulator: $DEVICE_NAME"
UDID=$(resolve_udid "$DEVICE_NAME")
if [[ -z "$UDID" ]]; then
  echo "Available simulators:" >&2
  xcrun simctl list devices available | grep iPhone >&2
  error "Simulator '$DEVICE_NAME' not found"
fi
log "Using simulator: $DEVICE_NAME ($UDID)"

# Boot simulator if needed
if ! xcrun simctl list devices booted | grep -q "$UDID"; then
  log "Booting simulator..."
  xcrun simctl boot "$UDID" 2>/dev/null || true
  sleep 2
fi

# Clean if requested
if [[ "$CLEAN_BUILD" == "1" ]]; then
  log "Cleaning..."
  xcodebuild \
    "$BUILD_FLAG" "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    clean 2>/dev/null || true
fi

# Build
log "Building $SCHEME..."
xcodebuild \
  "$BUILD_FLAG" "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  build

# Find built app
APP_PATH=$(find "$DERIVED_DATA" -name "*.app" -type d | head -1)
if [[ ! -d "$APP_PATH" ]]; then
  error "Built app not found in $DERIVED_DATA"
fi
log "Built: $APP_PATH"

# Install
log "Installing..."
xcrun simctl install "$UDID" "$APP_PATH"

# Configure appearance
if [[ "$DARK_MODE" == "1" ]]; then
  log "Enabling dark mode..."
  xcrun simctl ui "$UDID" appearance dark
else
  xcrun simctl ui "$UDID" appearance light
fi

# Configure status bar
if [[ "$STATUS_BAR" == "1" ]]; then
  log "Overriding status bar..."
  xcrun simctl status_bar "$UDID" override \
    --time "9:41" \
    --batteryLevel 100 \
    --batteryState charged \
    --dataNetwork wifi \
    --wifiBars 3
fi

# Terminate if running, then launch
log "Launching..."
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"

# Wait for app to render
log "Waiting ${SCREENSHOT_DELAY}s for app to render..."
sleep "$SCREENSHOT_DELAY"

# Create screenshot directory
mkdir -p "$SCREENSHOT_DIR"

# Take screenshot
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SCREENSHOT_PATH="$SCREENSHOT_DIR/${SCHEME}-${TIMESTAMP}.png"
log "Taking screenshot..."
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_PATH"

# Clear status bar override if applied
if [[ "$STATUS_BAR" == "1" ]]; then
  xcrun simctl status_bar "$UDID" clear
fi

log "Complete!"
echo ""
echo "=========================================="
echo "Screenshot saved: $SCREENSHOT_PATH"
echo "=========================================="
