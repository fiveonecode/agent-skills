# Xcodebuild Patterns for UI Feedback

Build patterns and configurations for SwiftUI app development with simulator feedback.

## Project Discovery

### Identify Project Type and Schemes

```bash
# Check if workspace or project
ls *.xcworkspace 2>/dev/null && echo "Workspace found"
ls *.xcodeproj 2>/dev/null && echo "Project found"

# List schemes (workspace)
xcodebuild -workspace App.xcworkspace -list

# List schemes (project)
xcodebuild -project App.xcodeproj -list

# List available destinations for a scheme
xcodebuild -workspace App.xcworkspace -scheme AppScheme -showDestinations
```

### Get Build Settings

```bash
# All build settings
xcodebuild -workspace App.xcworkspace -scheme AppScheme -showBuildSettings

# Specific setting
xcodebuild -workspace App.xcworkspace -scheme AppScheme -showBuildSettings | grep PRODUCT_BUNDLE_IDENTIFIER

# Multiple settings
xcodebuild -workspace App.xcworkspace -scheme AppScheme -showBuildSettings | grep -E '(PRODUCT_BUNDLE_IDENTIFIER|BUILT_PRODUCTS_DIR|PRODUCT_NAME)'
```

## Basic Build Commands

### Build for Simulator by Device Name

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -configuration Debug \
  build
```

### Build for Simulator by UDID (Preferred)

```bash
UDID=$(xcrun simctl list devices available | sed -nE '/iPhone 16/{s/.*\(([A-F0-9-]+)\).*/\1/p; q;}')

xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -configuration Debug \
  build
```

### Build with Custom Derived Data Path

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath /tmp/AppBuild \
  build

# Find built app
find /tmp/AppBuild -name "*.app" -type d | head -1
```

### Build with Code Signing Disabled

```bash
# Useful for CI/CD or when signing isn't configured
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath /tmp/AppBuild \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Build Output Control

### Quiet Build (Errors Only)

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -quiet \
  build
```

### Build with xcpretty (Prettier Output)

```bash
# Install xcpretty if needed: gem install xcpretty
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  build 2>&1 | xcpretty
```

### Build with xcbeautify (Modern Alternative)

```bash
# Install: brew install xcbeautify
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  build 2>&1 | xcbeautify
```

### Build with JSON Output

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -resultBundlePath /tmp/build-result \
  build

# Parse result bundle
xcresulttool get --path /tmp/build-result.xcresult --format json
```

## Clean Builds

### Clean Before Build

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  clean build
```

### Clean Only

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  clean
```

### Delete Derived Data (Nuclear Option)

```bash
# Delete specific project's derived data
rm -rf ~/Library/Developer/Xcode/DerivedData/AppName-*

# Delete all derived data (use with caution)
rm -rf ~/Library/Developer/Xcode/DerivedData/*
```

## Parallel and Incremental Builds

### Parallel Target Building

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -parallelizeTargets \
  build
```

### Control Build Jobs

```bash
# Use 8 concurrent jobs
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -jobs 8 \
  build
```

### Incremental Build (Default)

```bash
# Just run build again - xcodebuild will only rebuild changed files
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath /tmp/AppBuild \
  build
```

## Preview Targets

### Build Specific Preview/Lab Target

```bash
# Build a preview-specific target
xcodebuild \
  -workspace App.xcworkspace \
  -scheme PreviewLab \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath /tmp/PreviewBuild \
  build
```

### Build Only Changed Target

```bash
# Build specific target without dependencies
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -target UIComponents \
  -destination "platform=iOS Simulator,id=$UDID" \
  build
```

## Multiple Destinations

### Build for Multiple Simulators

```bash
# Build once, deploy to multiple
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,name=iPhone SE (3rd generation)" \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -destination "platform=iOS Simulator,name=iPhone 16 Pro Max" \
  -derivedDataPath /tmp/AppBuild \
  build
```

### Build and Install to All Booted

```bash
# Build once
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -derivedDataPath /tmp/AppBuild \
  build

APP_PATH=$(find /tmp/AppBuild -name "*.app" -type d | head -1)

# Install to all booted simulators
for UDID in $(xcrun simctl list devices booted --json | jq -r '.devices | .[].[] | .udid'); do
  xcrun simctl install "$UDID" "$APP_PATH"
done
```

## Testing Builds

### Build for Testing (Without Running)

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing
```

### Run Tests

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  test
```

### Run Specific Test

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing "AppTests/ViewModelTests/testLoginSuccess" \
  test
```

## Build Settings Override

### Override Settings at Build Time

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  SWIFT_OPTIMIZATION_LEVEL="-Onone" \
  DEBUG_INFORMATION_FORMAT="dwarf" \
  build
```

### Override Bundle ID (for Testing)

```bash
xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  PRODUCT_BUNDLE_IDENTIFIER="com.example.app.test" \
  build
```

### Enable/Disable Features via Xcconfig

```bash
# Create temporary xcconfig
cat > /tmp/preview.xcconfig << 'EOF'
ENABLE_PREVIEWS = YES
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG PREVIEW
EOF

xcodebuild \
  -workspace App.xcworkspace \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  -xcconfig /tmp/preview.xcconfig \
  build
```

## XcodeGen Integration

For projects using XcodeGen:

```bash
# Regenerate project
cd /path/to/project
xcodegen generate

# Then build normally
xcodebuild \
  -project App.xcodeproj \
  -scheme AppScheme \
  -destination "platform=iOS Simulator,id=$UDID" \
  build
```

## Swift Package Manager Builds

### Build Swift Package

```bash
cd /path/to/Package

# Build
swift build

# Build for release
swift build -c release

# Run tests
swift test
```

### Build Package for iOS Simulator

```bash
# Swift packages targeting iOS need xcodebuild
xcodebuild \
  -scheme PackageName \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  build
```

## Finding Build Artifacts

### Locate Built App

```bash
# From custom derived data
find /tmp/AppBuild -name "*.app" -type d | head -1

# From default derived data
find ~/Library/Developer/Xcode/DerivedData -name "*.app" -path "*Debug-iphonesimulator*" -type d | head -1

# From build settings
PRODUCTS_DIR=$(xcodebuild -workspace App.xcworkspace -scheme AppScheme -showBuildSettings | grep "BUILT_PRODUCTS_DIR" | awk '{print $3}')
echo "$PRODUCTS_DIR"
```

### Locate dSYM (for debugging)

```bash
find /tmp/AppBuild -name "*.dSYM" -type d | head -1
```

## Complete Build + Run Script Template

```bash
#!/usr/bin/env bash
set -euo pipefail

# Configuration
WORKSPACE="${WORKSPACE:-App.xcworkspace}"
SCHEME="${SCHEME:-AppScheme}"
BUNDLE_ID="${BUNDLE_ID:-com.example.app}"
DEVICE_NAME="${DEVICE_NAME:-iPhone 16}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/AppBuild}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/Screenshots}"

# Resolve UDID
UDID=$(xcrun simctl list devices available | sed -nE "/$DEVICE_NAME/{s/.*\(([A-F0-9-]+)\).*/\1/p; q;}")
if [[ -z "$UDID" ]]; then
  echo "Error: Simulator '$DEVICE_NAME' not found"
  exit 1
fi

# Boot simulator
xcrun simctl boot "$UDID" 2>/dev/null || true

# Build
echo "Building $SCHEME..."
xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  build

# Find and install app
APP_PATH=$(find "$DERIVED_DATA" -name "*.app" -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
  echo "Error: Built app not found"
  exit 1
fi

echo "Installing..."
xcrun simctl install "$UDID" "$APP_PATH"

# Launch
echo "Launching..."
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"

# Screenshot
mkdir -p "$SCREENSHOT_DIR"
sleep 1
SCREENSHOT="$SCREENSHOT_DIR/$(date +%Y%m%d-%H%M%S).png"
xcrun simctl io "$UDID" screenshot "$SCREENSHOT"

echo "Screenshot: $SCREENSHOT"
```
