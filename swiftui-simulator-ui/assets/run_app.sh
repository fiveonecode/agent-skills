#!/usr/bin/env bash
# =============================================================================
# run_app.sh - Build, install, and launch a SwiftUI app in iOS Simulator
# =============================================================================
#
# Usage:
#   PROJECT_PATH=/path/to/App.xcodeproj SCHEME=AppScheme BUNDLE_ID=com.example.app ./run_app.sh
#
# Environment Variables:
#   PROJECT_PATH    - Path to .xcodeproj or .xcworkspace (required)
#   SCHEME          - Xcode scheme to build (required)
#   BUNDLE_ID       - App bundle identifier (required)
#   DEVICE_NAME     - Simulator name (default: iPhone 16)
#   DERIVED_DATA    - Build output path (default: /tmp/AppBuild)
#   QUIET           - Set to "1" for minimal output
#
# =============================================================================

set -euo pipefail

# Configuration with defaults
PROJECT_PATH="${PROJECT_PATH:?Error: PROJECT_PATH is required}"
SCHEME="${SCHEME:?Error: SCHEME is required}"
BUNDLE_ID="${BUNDLE_ID:?Error: BUNDLE_ID is required}"
DEVICE_NAME="${DEVICE_NAME:-iPhone 16}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/AppBuild}"
QUIET="${QUIET:-0}"

# Helper functions
log() {
  if [[ "$QUIET" != "1" ]]; then
    echo "[$(date +%H:%M:%S)] $*"
  fi
}

error() {
  echo "ERROR: $*" >&2
  exit 1
}

resolve_udid() {
  local name="$1"
  xcrun simctl list devices available | sed -nE "/$name/{s/.*\(([A-F0-9-]+)\).*/\1/p; q;}"
}

# Determine project type (workspace vs project)
if [[ "$PROJECT_PATH" == *.xcworkspace ]]; then
  BUILD_FLAG="-workspace"
elif [[ "$PROJECT_PATH" == *.xcodeproj ]]; then
  BUILD_FLAG="-project"
else
  error "PROJECT_PATH must be .xcworkspace or .xcodeproj"
fi

# Resolve simulator UDID
log "Finding simulator: $DEVICE_NAME"
UDID=$(resolve_udid "$DEVICE_NAME")
if [[ -z "$UDID" ]]; then
  echo "Available simulators:" >&2
  xcrun simctl list devices available | grep iPhone >&2
  error "Simulator '$DEVICE_NAME' not found"
fi
log "Using UDID: $UDID"

# Boot simulator if needed
if ! xcrun simctl list devices booted | grep -q "$UDID"; then
  log "Booting simulator..."
  xcrun simctl boot "$UDID" 2>/dev/null || true
  sleep 2
fi

# Build
log "Building $SCHEME..."
BUILD_ARGS=(
  "$BUILD_FLAG" "$PROJECT_PATH"
  -scheme "$SCHEME"
  -destination "platform=iOS Simulator,id=$UDID"
  -derivedDataPath "$DERIVED_DATA"
)

if [[ "$QUIET" == "1" ]]; then
  BUILD_ARGS+=(-quiet)
fi

xcodebuild "${BUILD_ARGS[@]}" build

# Find built app
APP_PATH=$(find "$DERIVED_DATA" -name "*.app" -type d | head -1)
if [[ ! -d "$APP_PATH" ]]; then
  error "Built app not found in $DERIVED_DATA"
fi
log "Built app: $APP_PATH"

# Install
log "Installing..."
xcrun simctl install "$UDID" "$APP_PATH"

# Terminate if running, then launch
log "Launching..."
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"

log "Launched $SCHEME on $DEVICE_NAME ($UDID)"

# Output for scripts to capture
echo "UDID=$UDID"
echo "APP_PATH=$APP_PATH"
echo "DEVICE_NAME=$DEVICE_NAME"
