# Troubleshooting SwiftUI Simulator UI

Common issues and solutions when running SwiftUI apps in simulator for visual verification.

## Build Issues

### "No matching destination found"

**Symptom:**
```
xcodebuild: error: Unable to find a destination matching the provided destination specifier
```

**Solutions:**

1. List available destinations:
```bash
xcodebuild -workspace App.xcworkspace -scheme AppScheme -showDestinations
```

2. Check available simulators:
```bash
xcrun simctl list devices available | grep iPhone
```

3. Use exact simulator name from the list

4. Install missing simulators:
   - Open Xcode → Preferences → Platforms
   - Download required iOS versions

### "No provisioning profile" / Code Signing Errors

**Symptom:**
```
error: Signing for "App" requires a development team
```

**Solutions:**

1. Disable code signing for simulator builds:
```bash
xcodebuild ... CODE_SIGNING_ALLOWED=NO build
```

2. Or set signing to automatic in Xcode for Debug configuration

### "Module 'SomeModule' was not compiled for testing"

**Symptom:** Build fails when building for testing

**Solutions:**

1. Clean build:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/AppName-*
xcodebuild clean build
```

2. Ensure "Build Active Architecture Only" is YES for Debug

### "Dependency cycle" Error

**Symptom:**
```
Cycle in dependencies between targets
```

**Solutions:**

1. Check target dependencies in Xcode
2. Review `project.yml` if using XcodeGen
3. Break circular references between frameworks

### Build Takes Too Long

**Solutions:**

1. Use incremental builds (same derived data path):
```bash
xcodebuild -derivedDataPath /tmp/AppBuild build
```

2. Build only specific target:
```bash
xcodebuild -target SpecificTarget build
```

3. Increase parallelism:
```bash
xcodebuild -jobs 8 -parallelizeTargets build
```

4. Disable unnecessary build phases in Debug

## Simulator Issues

### "Unable to boot device in current state: Booted"

**Symptom:** Simulator is already running

**Solution:**
```bash
# Ignore the error
xcrun simctl boot "$UDID" 2>/dev/null || true
```

### "Could not find device named 'iPhone X'"

**Symptom:** Specified simulator doesn't exist

**Solutions:**

1. List available simulators:
```bash
xcrun simctl list devices available
```

2. Use exact name from the list

3. Create the simulator if needed:
```bash
xcrun simctl create "iPhone X" \
  "com.apple.CoreSimulator.SimDeviceType.iPhone-X" \
  "com.apple.CoreSimulator.SimRuntime.iOS-17-0"
```

### Simulator Won't Boot

**Solutions:**

1. Force shutdown and reboot:
```bash
xcrun simctl shutdown all
xcrun simctl boot "$UDID"
```

2. Erase simulator:
```bash
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
```

3. Delete and recreate:
```bash
xcrun simctl delete "$UDID"
xcrun simctl create "iPhone 16" \
  "com.apple.CoreSimulator.SimDeviceType.iPhone-16" \
  "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
```

4. Restart CoreSimulatorService:
```bash
killall Simulator
killall SimulatorBridge
```

### Multiple Simulators Running Causing Confusion

**Solutions:**

1. Shutdown all and boot only target:
```bash
xcrun simctl shutdown all
xcrun simctl boot "$UDID"
```

2. Always use explicit UDID in commands:
```bash
xcrun simctl io "$UDID" screenshot /tmp/screenshot.png
```

### Simulator UI is Frozen

**Solutions:**

1. Terminate and restart app:
```bash
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
```

2. Reset simulator:
```bash
xcrun simctl shutdown "$UDID"
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
```

## App Installation Issues

### "Unable to Install" Error

**Symptom:**
```
An error was encountered processing the command
```

**Solutions:**

1. Check app architecture (must match simulator):
```bash
file /path/to/App.app/App
# Should show: arm64 or x86_64 for simulator
```

2. Rebuild for correct architecture:
```bash
xcodebuild -destination "platform=iOS Simulator,id=$UDID" build
```

3. Check minimum deployment target matches simulator iOS version

### "App is not responding" After Install

**Solutions:**

1. Terminate existing instance first:
```bash
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"
```

2. Check console for crash logs:
```bash
xcrun simctl launch --console "$UDID" "$BUNDLE_ID"
```

### App Opens but Immediately Crashes

**Solutions:**

1. Check crash log:
```bash
xcrun simctl spawn "$UDID" log stream \
  --predicate 'processImagePath CONTAINS "AppName" AND eventMessage CONTAINS "crash"' \
  --level debug
```

2. Common causes:
   - Missing required resources (check bundle)
   - Missing required Info.plist keys
   - Entitlement issues
   - Missing dependencies

3. Verify app bundle:
```bash
ls -la /path/to/App.app/
/usr/libexec/PlistBuddy -c "Print" /path/to/App.app/Info.plist
```

## Screenshot Issues

### Screenshot is Black

**Causes and Solutions:**

1. App not fully launched - add delay:
```bash
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 2
xcrun simctl io "$UDID" screenshot /tmp/screenshot.png
```

2. Simulator window minimized or not visible:
   - Open Simulator.app to bring to foreground
   - Or ensure simulator is in focus

3. App showing loading state - wait longer:
```bash
sleep 5
xcrun simctl io "$UDID" screenshot /tmp/screenshot.png
```

### Screenshot Shows Wrong Simulator

**Cause:** Multiple simulators booted, using `booted` instead of UDID

**Solution:** Always use explicit UDID:
```bash
xcrun simctl io "$UDID" screenshot /tmp/screenshot.png
```

### Screenshot Shows Previous App State

**Solutions:**

1. Terminate and relaunch:
```bash
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 2
xcrun simctl io "$UDID" screenshot /tmp/screenshot.png
```

2. Force refresh by navigating away and back

### "Unable to record video" Error

**Cause:** Previous recording still running

**Solution:**
```bash
# Kill any existing recording
pkill -f "simctl io.*recordVideo" 2>/dev/null || true

# Start new recording
xcrun simctl io "$UDID" recordVideo /tmp/recording.mp4
```

## Configuration Issues

### UserDefaults Not Being Applied

**Cause:** App reads defaults before simctl writes them

**Solutions:**

1. Write defaults BEFORE launch:
```bash
xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" Key -string "value"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
```

2. Terminate and relaunch after writing:
```bash
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" Key -string "value"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
```

### Environment Variables Not Working

**Cause:** Environment variables need to be set for launchd

**Solution:**
```bash
xcrun simctl spawn "$UDID" launchctl setenv MY_VAR "value"
# Relaunch app to pick up changes
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
```

### Dark Mode Not Switching

**Solutions:**

1. Use correct command:
```bash
xcrun simctl ui "$UDID" appearance dark
```

2. Wait for UI to update:
```bash
xcrun simctl ui "$UDID" appearance dark
sleep 1
xcrun simctl io "$UDID" screenshot /tmp/dark-mode.png
```

3. App may override appearance - check for hardcoded values

### Status Bar Override Not Working

**Cause:** App launched before override applied

**Solution:**
```bash
# Apply override first
xcrun simctl status_bar "$UDID" override --time "9:41"
# Then launch app
xcrun simctl launch "$UDID" "$BUNDLE_ID"
# Then screenshot
xcrun simctl io "$UDID" screenshot /tmp/screenshot.png
```

## Deep Link / URL Issues

### Deep Link Not Opening App

**Causes and Solutions:**

1. URL scheme not registered - check Info.plist:
```bash
/usr/libexec/PlistBuddy -c "Print CFBundleURLTypes" /path/to/App.app/Info.plist
```

2. App not installed - install first:
```bash
xcrun simctl install "$UDID" /path/to/App.app
xcrun simctl openurl "$UDID" "yourapp://screen"
```

3. Incorrect URL format - check scheme matches exactly

### Universal Link Not Working

**Causes:**

1. Associated domains entitlement missing
2. AASA file not configured
3. Simulator may not support all universal link features

**Solution:** Test with URL scheme instead for local development

## Performance Issues

### Build is Slow

**Solutions:**

1. Use incremental builds with consistent derived data:
```bash
xcodebuild -derivedDataPath /tmp/AppBuild build
```

2. Build only what you need:
```bash
xcodebuild -target UIModule build
```

3. Disable unnecessary diagnostics:
```bash
xcodebuild \
  SWIFT_OPTIMIZATION_LEVEL="-Onone" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build
```

### Simulator is Slow

**Solutions:**

1. Use Apple Silicon Mac if possible (native simulator)

2. Reduce simulator window size

3. Close other simulators:
```bash
xcrun simctl shutdown all
xcrun simctl boot "$UDID"
```

4. Reset simulator:
```bash
xcrun simctl erase "$UDID"
```

## Diagnostic Commands

### Check Simulator Status

```bash
# All simulators
xcrun simctl list devices

# Booted only
xcrun simctl list devices booted

# Specific device
xcrun simctl list devices | grep "$UDID"
```

### Check App Status

```bash
# Is app installed?
xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" 2>/dev/null && echo "Installed" || echo "Not installed"

# Is app running?
xcrun simctl spawn "$UDID" launchctl list | grep "$BUNDLE_ID" && echo "Running" || echo "Not running"

# App info
xcrun simctl appinfo "$UDID" "$BUNDLE_ID"
```

### Get Logs

```bash
# App logs
xcrun simctl spawn "$UDID" log stream \
  --predicate 'processImagePath CONTAINS "AppName"' \
  --level debug

# System logs
xcrun simctl spawn "$UDID" log stream \
  --predicate 'subsystem == "com.apple.UIKit"' \
  --level debug

# Crash logs
xcrun simctl spawn "$UDID" log show \
  --predicate 'eventMessage CONTAINS "crash"' \
  --last 1h
```

### Full Diagnostics

```bash
# Collect comprehensive diagnostics
xcrun simctl diagnose --output /tmp/simctl-diag

# Check output
ls /tmp/simctl-diag/
```

## Quick Fixes Checklist

When things aren't working, try these in order:

1. [ ] Shutdown all simulators and boot only the target one
2. [ ] Clean build (`rm -rf DerivedData`, then rebuild)
3. [ ] Verify UDID is correct (`xcrun simctl list devices available`)
4. [ ] Verify bundle ID is correct (check build settings)
5. [ ] Terminate app before relaunching
6. [ ] Add sleep delays between commands
7. [ ] Check console output (`xcrun simctl launch --console`)
8. [ ] Erase simulator and start fresh
9. [ ] Restart Simulator.app
10. [ ] Restart Mac (last resort)
