#!/usr/bin/env bash
# =============================================================================
# multi_device_screenshots.sh - Capture screenshots on multiple device sizes
# =============================================================================
#
# Usage:
#   PROJECT_PATH=/path/to/App.xcodeproj \
#   SCHEME=AppScheme \
#   BUNDLE_ID=com.example.app \
#   ./multi_device_screenshots.sh
#
# Environment Variables:
#   PROJECT_PATH    - Path to .xcodeproj or .xcworkspace (required)
#   SCHEME          - Xcode scheme to build (required)
#   BUNDLE_ID       - App bundle identifier (required)
#   DERIVED_DATA    - Build output path (default: /tmp/AppBuild)
#   SCREENSHOT_DIR  - Screenshot output directory (default: /tmp/UIScreenshots)
#   DEVICES         - Space-separated device names (default: see below)
#   BOTH_MODES      - Set to "1" to capture both light and dark mode
#
# Default devices tested:
#   - iPhone SE (3rd generation)  (small screen)
#   - iPhone 16                   (standard)
#   - iPhone 16 Pro Max           (large screen)
#
# =============================================================================

set -euo pipefail

# Required configuration
PROJECT_PATH="${PROJECT_PATH:?Error: PROJECT_PATH is required}"
SCHEME="${SCHEME:?Error: SCHEME is required}"
BUNDLE_ID="${BUNDLE_ID:?Error: BUNDLE_ID is required}"

# Optional configuration
DERIVED_DATA="${DERIVED_DATA:-/tmp/AppBuild}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/UIScreenshots}"
BOTH_MODES="${BOTH_MODES:-0}"

# Default devices (can override with DEVICES env var)
if [[ -z "${DEVICES:-}" ]]; then
  DEVICES=(
    "iPhone SE (3rd generation)"
    "iPhone 16"
    "iPhone 16 Pro Max"
  )
else
  # Convert space-separated string to array
  IFS=' ' read -ra DEVICES <<< "$DEVICES"
fi

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

sanitize_name() {
  echo "$1" | tr ' ()' '_' | tr -d ','
}

# Determine project type
if [[ "$PROJECT_PATH" == *.xcworkspace ]]; then
  BUILD_FLAG="-workspace"
elif [[ "$PROJECT_PATH" == *.xcodeproj ]]; then
  BUILD_FLAG="-project"
else
  error "PROJECT_PATH must be .xcworkspace or .xcodeproj"
fi

# Shutdown all simulators first
log "Shutting down all simulators..."
xcrun simctl shutdown all 2>/dev/null || true

# Build once for the first available device
FIRST_DEVICE=""
FIRST_UDID=""
for DEVICE in "${DEVICES[@]}"; do
  UDID=$(resolve_udid "$DEVICE")
  if [[ -n "$UDID" ]]; then
    FIRST_DEVICE="$DEVICE"
    FIRST_UDID="$UDID"
    break
  fi
done

if [[ -z "$FIRST_UDID" ]]; then
  error "No valid simulators found. Available:"
  xcrun simctl list devices available | grep iPhone
fi

log "Building for $FIRST_DEVICE..."
xcodebuild \
  "$BUILD_FLAG" "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$FIRST_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  build

APP_PATH=$(find "$DERIVED_DATA" -name "*.app" -type d | head -1)
if [[ ! -d "$APP_PATH" ]]; then
  error "Built app not found in $DERIVED_DATA"
fi
log "Built: $APP_PATH"

# Create output directory
mkdir -p "$SCREENSHOT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Function to capture screenshot for a device
capture_for_device() {
  local device_name="$1"
  local appearance="${2:-light}"

  local udid
  udid=$(resolve_udid "$device_name")

  if [[ -z "$udid" ]]; then
    log "Skipping $device_name (not available)"
    return
  fi

  log "Processing: $device_name ($appearance mode)"

  # Boot
  xcrun simctl boot "$udid" 2>/dev/null || true
  sleep 2

  # Install
  xcrun simctl install "$udid" "$APP_PATH"

  # Set appearance
  xcrun simctl ui "$udid" appearance "$appearance"

  # Override status bar
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --batteryLevel 100 \
    --batteryState charged \
    --dataNetwork wifi \
    --wifiBars 3

  # Launch
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$udid" "$BUNDLE_ID"
  sleep 2

  # Screenshot
  local safe_name
  safe_name=$(sanitize_name "$device_name")
  local screenshot_path="$SCREENSHOT_DIR/${SCHEME}-${safe_name}-${appearance}-${TIMESTAMP}.png"
  xcrun simctl io "$udid" screenshot "$screenshot_path"
  log "Saved: $screenshot_path"

  # Clear status bar
  xcrun simctl status_bar "$udid" clear

  # Shutdown
  xcrun simctl shutdown "$udid" 2>/dev/null || true
}

# Capture screenshots
log "Starting multi-device screenshot capture..."
echo ""

for DEVICE in "${DEVICES[@]}"; do
  capture_for_device "$DEVICE" "light"

  if [[ "$BOTH_MODES" == "1" ]]; then
    capture_for_device "$DEVICE" "dark"
  fi
done

log "Complete!"
echo ""
echo "=========================================="
echo "Screenshots saved to: $SCREENSHOT_DIR"
echo "Files:"
ls -1 "$SCREENSHOT_DIR"/*"${TIMESTAMP}"*.png 2>/dev/null || echo "  (none)"
echo "=========================================="
