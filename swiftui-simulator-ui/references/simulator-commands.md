# iOS Simulator Commands Reference

Complete reference for `xcrun simctl` commands used in UI feedback loops.

## Simulator Discovery

### List All Simulators

```bash
# Human-readable format
xcrun simctl list devices

# JSON format (better for parsing)
xcrun simctl list devices --json

# Only available (installed runtime) simulators
xcrun simctl list devices available

# Filter by iOS version
xcrun simctl list devices "iOS 18"
xcrun simctl list devices "iOS 17"

# List device types (models available)
xcrun simctl list devicetypes

# List installed runtimes
xcrun simctl list runtimes
```

### Extract Simulator UDID

```bash
# Using sed (no external dependencies)
DEVICE_NAME="iPhone 16"
UDID=$(xcrun simctl list devices available | sed -nE "/$DEVICE_NAME/{s/.*\(([A-F0-9-]+)\).*/\1/p; q;}")

# Using jq (more robust for complex queries)
UDID=$(xcrun simctl list devices --json | jq -r '.devices | .[].[] | select(.name=="iPhone 16 Pro") | .udid' | head -1)

# Get first available iPhone
UDID=$(xcrun simctl list devices --json | jq -r '.devices | .[].[] | select(.name | startswith("iPhone")) | select(.isAvailable==true) | .udid' | head -1)

# Get all booted simulators
xcrun simctl list devices --json | jq -r '.devices | .[].[] | select(.state=="Booted") | {name, udid}'
```

## Simulator Lifecycle

### Boot and Shutdown

```bash
# Boot specific simulator
xcrun simctl boot $UDID

# Boot (ignore if already booted)
xcrun simctl boot $UDID 2>/dev/null || true

# Shutdown specific simulator
xcrun simctl shutdown $UDID

# Shutdown all simulators
xcrun simctl shutdown all

# Check if simulator is booted
if xcrun simctl list devices booted | grep -q "$UDID"; then
  echo "Simulator is booted"
fi
```

### Create and Delete Simulators

```bash
# Create new simulator
xcrun simctl create "My Test iPhone" \
  "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro" \
  "com.apple.CoreSimulator.SimRuntime.iOS-18-0"

# Delete simulator
xcrun simctl delete $UDID

# Erase simulator (reset to clean state, keep simulator)
xcrun simctl erase $UDID

# Clone simulator
xcrun simctl clone $UDID "Cloned iPhone"
```

## App Management

### Install and Uninstall

```bash
# Install app
xcrun simctl install $UDID /path/to/App.app

# Install to booted simulator (any)
xcrun simctl install booted /path/to/App.app

# Uninstall app
xcrun simctl uninstall $UDID com.example.app

# Check if app is installed
xcrun simctl get_app_container $UDID com.example.app 2>/dev/null && echo "Installed"
```

### Launch and Terminate

```bash
# Basic launch
xcrun simctl launch $UDID com.example.app

# Launch with console output (stdout/stderr)
xcrun simctl launch --console $UDID com.example.app

# Launch with arguments
xcrun simctl launch $UDID com.example.app --argument1 --argument2

# Launch with stdout/stderr to files
xcrun simctl launch \
  --stdout=/tmp/stdout.log \
  --stderr=/tmp/stderr.log \
  $UDID com.example.app

# Launch and wait for debugger
xcrun simctl launch -w $UDID com.example.app

# Terminate app
xcrun simctl terminate $UDID com.example.app

# Terminate (ignore if not running)
xcrun simctl terminate $UDID com.example.app 2>/dev/null || true
```

### App Information

```bash
# List all installed apps
xcrun simctl listapps $UDID

# Get specific app info
xcrun simctl appinfo $UDID com.example.app

# Get app container path (data directory)
xcrun simctl get_app_container $UDID com.example.app data

# Get app bundle path
xcrun simctl get_app_container $UDID com.example.app app

# Get app groups container
xcrun simctl get_app_container $UDID com.example.app groups
```

## Screenshots and Video

### Screenshots

```bash
# Basic screenshot (PNG)
xcrun simctl io $UDID screenshot /tmp/screenshot.png

# JPEG format
xcrun simctl io $UDID screenshot --type=jpeg /tmp/screenshot.jpg

# TIFF format (lossless)
xcrun simctl io $UDID screenshot --type=tiff /tmp/screenshot.tiff

# With mask (device frame)
xcrun simctl io $UDID screenshot --mask=black /tmp/screenshot.png

# Ignore alpha channel
xcrun simctl io $UDID screenshot --mask=ignored /tmp/screenshot.png

# From booted simulator
xcrun simctl io booted screenshot /tmp/screenshot.png
```

### Video Recording

```bash
# Start recording (blocks until stopped)
xcrun simctl io $UDID recordVideo /tmp/recording.mp4

# Record with specific codec
xcrun simctl io $UDID recordVideo --codec=h264 /tmp/recording.mp4
xcrun simctl io $UDID recordVideo --codec=hevc /tmp/recording.mp4

# Background recording
xcrun simctl io $UDID recordVideo /tmp/recording.mp4 &
RECORD_PID=$!

# ... do stuff ...

# Stop recording (send interrupt signal)
kill -INT $RECORD_PID

# With mask
xcrun simctl io $UDID recordVideo --mask=black /tmp/recording.mp4
```

## User Interaction

### Open URL

```bash
# Open URL (web)
xcrun simctl openurl $UDID "https://example.com"

# Open deep link
xcrun simctl openurl $UDID "myapp://screen/settings"

# Open universal link
xcrun simctl openurl $UDID "https://example.com/app/profile"
```

### Keyboard Input

```bash
# Type text into focused field
xcrun simctl io $UDID keyboard write "Hello World"

# Special keys are not directly supported - use XCUITest for complex interactions
```

## Configuration

### UserDefaults (App Settings)

```bash
# Write string
xcrun simctl spawn $UDID defaults write com.example.app KeyName -string "value"

# Write boolean
xcrun simctl spawn $UDID defaults write com.example.app FeatureEnabled -bool true
xcrun simctl spawn $UDID defaults write com.example.app FeatureEnabled -bool false

# Write integer
xcrun simctl spawn $UDID defaults write com.example.app MaxRetries -int 5

# Write float
xcrun simctl spawn $UDID defaults write com.example.app AnimationSpeed -float 1.5

# Write array
xcrun simctl spawn $UDID defaults write com.example.app Features -array "feature1" "feature2"

# Read value
xcrun simctl spawn $UDID defaults read com.example.app KeyName

# Delete key
xcrun simctl spawn $UDID defaults delete com.example.app KeyName

# Delete all app defaults
xcrun simctl spawn $UDID defaults delete com.example.app
```

### Environment Variables

```bash
# Set environment variable (persists until simulator shutdown)
xcrun simctl spawn $UDID launchctl setenv MY_VAR "my_value"

# Multiple variables
xcrun simctl spawn $UDID launchctl setenv DEBUG_MODE "true"
xcrun simctl spawn $UDID launchctl setenv API_URL "https://staging.example.com"

# Unset variable
xcrun simctl spawn $UDID launchctl unsetenv MY_VAR
```

### Appearance (Dark/Light Mode)

```bash
# Enable dark mode
xcrun simctl ui $UDID appearance dark

# Enable light mode
xcrun simctl ui $UDID appearance light

# Toggle (if supported)
xcrun simctl ui $UDID appearance toggle
```

### Status Bar Override

```bash
# Full status bar override
xcrun simctl status_bar $UDID override \
  --time "9:41" \
  --batteryLevel 100 \
  --batteryState charged \
  --cellularMode active \
  --cellularBars 4 \
  --dataNetwork wifi \
  --wifiBars 3 \
  --operatorName "Carrier"

# Time only
xcrun simctl status_bar $UDID override --time "9:41"

# Battery only
xcrun simctl status_bar $UDID override --batteryLevel 50 --batteryState discharging

# Clear all overrides
xcrun simctl status_bar $UDID clear
```

### Location

```bash
# Set location by coordinates
xcrun simctl location $UDID set 37.7749,-122.4194

# Set location by name (requires network)
xcrun simctl location $UDID set "San Francisco, CA"

# Clear custom location
xcrun simctl location $UDID clear

# Simulate movement along route (GPX file)
xcrun simctl location $UDID start /path/to/route.gpx
xcrun simctl location $UDID stop
```

## Privacy and Permissions

```bash
# Grant permission
xcrun simctl privacy $UDID grant photos com.example.app
xcrun simctl privacy $UDID grant camera com.example.app
xcrun simctl privacy $UDID grant microphone com.example.app
xcrun simctl privacy $UDID grant location com.example.app
xcrun simctl privacy $UDID grant contacts com.example.app
xcrun simctl privacy $UDID grant calendar com.example.app
xcrun simctl privacy $UDID grant reminders com.example.app
xcrun simctl privacy $UDID grant health com.example.app

# Revoke permission
xcrun simctl privacy $UDID revoke photos com.example.app

# Reset all permissions for app
xcrun simctl privacy $UDID reset all com.example.app

# Reset specific permission for all apps
xcrun simctl privacy $UDID reset photos
```

## Push Notifications

```bash
# Send push notification
xcrun simctl push $UDID com.example.app /path/to/payload.json

# Payload file example (payload.json):
cat > /tmp/push.json << 'EOF'
{
  "aps": {
    "alert": {
      "title": "Test Notification",
      "body": "This is a test push notification"
    },
    "badge": 1,
    "sound": "default"
  },
  "custom_key": "custom_value"
}
EOF

xcrun simctl push $UDID com.example.app /tmp/push.json

# Silent push
cat > /tmp/silent-push.json << 'EOF'
{
  "aps": {
    "content-available": 1
  }
}
EOF

xcrun simctl push $UDID com.example.app /tmp/silent-push.json
```

## Pasteboard (Copy/Paste)

```bash
# Copy text to simulator pasteboard
echo "Hello World" | xcrun simctl pbcopy $UDID

# Copy file content
cat /path/to/file.txt | xcrun simctl pbcopy $UDID

# Paste from simulator pasteboard
xcrun simctl pbpaste $UDID

# Get pasteboard info
xcrun simctl pbinfo $UDID
```

## Keychain

```bash
# Add root certificate
xcrun simctl keychain $UDID add-root-cert /path/to/cert.pem

# Add CA certificate
xcrun simctl keychain $UDID add-ca-cert /path/to/ca-cert.pem

# Reset keychain
xcrun simctl keychain $UDID reset
```

## Diagnostics and Logging

### Collect Diagnostics

```bash
# Collect comprehensive diagnostic info
xcrun simctl diagnose

# Output to specific directory
xcrun simctl diagnose --output /tmp/simctl-diagnostics
```

### Logging

```bash
# Enable verbose logging for simulator
xcrun simctl logverbose $UDID enable

# Reproduce issue...

# Disable verbose logging
xcrun simctl logverbose $UDID disable

# Stream logs from simulator process
xcrun simctl spawn $UDID log stream --level debug

# Stream logs for specific app
xcrun simctl spawn $UDID log stream \
  --predicate 'processImagePath CONTAINS "YourApp"' \
  --level debug

# Stream with message filter
xcrun simctl spawn $UDID log stream \
  --predicate 'eventMessage CONTAINS "error"' \
  --level debug
```

### Run Arbitrary Commands

```bash
# Spawn process in simulator
xcrun simctl spawn $UDID /bin/ls /

# Run with environment
xcrun simctl spawn $UDID /usr/bin/env DEBUG=1 /path/to/binary

# Check simulator architecture
xcrun simctl spawn $UDID /usr/bin/arch
```

## Useful Patterns

### Wait for Simulator to Boot

```bash
wait_for_boot() {
  local udid="$1"
  local timeout="${2:-60}"
  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    if xcrun simctl list devices booted | grep -q "$udid"; then
      return 0
    fi
    sleep 1
    ((elapsed++))
  done

  return 1
}

xcrun simctl boot "$UDID"
wait_for_boot "$UDID" 30 || { echo "Boot timeout"; exit 1; }
```

### Wait for App to Launch

```bash
wait_for_app() {
  local udid="$1"
  local bundle_id="$2"
  local timeout="${3:-10}"
  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    if xcrun simctl spawn "$udid" launchctl list | grep -q "$bundle_id"; then
      return 0
    fi
    sleep 0.5
    ((elapsed++))
  done

  return 1
}

xcrun simctl launch "$UDID" com.example.app
wait_for_app "$UDID" "com.example.app" 10 || { echo "Launch timeout"; exit 1; }
```

### Clean Simulator State

```bash
# Full reset (like new device)
clean_simulator() {
  local udid="$1"

  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl erase "$udid"
  xcrun simctl boot "$udid"
}

clean_simulator "$UDID"
```

### Screenshot with Retry

```bash
screenshot_with_retry() {
  local udid="$1"
  local output="$2"
  local max_attempts="${3:-3}"
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    if xcrun simctl io "$udid" screenshot "$output" 2>/dev/null; then
      return 0
    fi
    sleep 1
    ((attempt++))
  done

  return 1
}

screenshot_with_retry "$UDID" "/tmp/screenshot.png" 3
```
