# Setting Up a Preview Lab Target

A Preview Lab is a dedicated iOS app target that isolates specific views for visual testing without navigating through the full app flow. This guide explains how to set one up.

## Why Use a Preview Lab?

1. **Fast iteration** - Skip onboarding, login, and navigation to test specific screens
2. **Controlled state** - Test views with exact data configurations
3. **No side effects** - No analytics, no network calls, no persistence
4. **Multiple variants** - Test different states/variants from launch config
5. **AI agent friendly** - Agents can build, run, and screenshot specific UI states

## Setting Up a Preview Lab

### Step 1: Create a New App Target

In Xcode:
1. File → New → Target
2. Select "App" under iOS
3. Name it `PreviewLab` or `{YourApp}PreviewLab`
4. Ensure it shares the same development team/bundle ID prefix

Or with XcodeGen (`project.yml`):

```yaml
targets:
  YourAppPreviewLab:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: YourAppPreviewLab
      - path: YourApp/Views  # Share views from main app
      - path: YourApp/Models # Share models
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.yourapp.previewlab
        INFOPLIST_FILE: YourAppPreviewLab/Info.plist
    dependencies:
      - target: YourAppDesignSystem  # If you have a design system package
```

### Step 2: Create the Lab Entry Point

Create `PreviewLabApp.swift`:

```swift
import SwiftUI

@main
struct PreviewLabApp: App {
    var body: some Scene {
        WindowGroup {
            PreviewLabRootView()
        }
    }
}
```

### Step 3: Create the Root View with Variant Selection

Create `PreviewLabRootView.swift`:

```swift
import SwiftUI

struct PreviewLabRootView: View {
    // Read launch config from UserDefaults (can be set via simctl)
    @AppStorage("PreviewLabVariant") private var variant: String = "default"
    @AppStorage("PreviewLabStep") private var step: String = ""

    // State for manual selection
    @State private var selectedVariant: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Variant picker for manual testing
                Picker("Variant", selection: $selectedVariant) {
                    Text("Default").tag("default")
                    Text("Settings").tag("settings")
                    Text("Profile").tag("profile")
                    Text("Onboarding").tag("onboarding")
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                // Preview content
                previewContent
            }
            .navigationTitle("Preview Lab")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // Initialize from UserDefaults if set
            if !variant.isEmpty && variant != "default" {
                selectedVariant = variant
            } else {
                selectedVariant = "default"
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch selectedVariant {
        case "settings":
            SettingsView()
        case "profile":
            ProfileView(user: .preview)
        case "onboarding":
            OnboardingView(step: parseStep())
        default:
            DefaultPreviewView()
        }
    }

    private func parseStep() -> Int {
        Int(step) ?? 0
    }
}

// Preview data
extension User {
    static var preview: User {
        User(
            id: "preview",
            name: "Preview User",
            email: "preview@example.com"
        )
    }
}
```

### Step 4: Create Preview-Specific Views

Create `DefaultPreviewView.swift`:

```swift
import SwiftUI

struct DefaultPreviewView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Select a variant above to preview")
                    .foregroundStyle(.secondary)

                Divider()

                // Quick links to common previews
                Section("Quick Previews") {
                    NavigationLink("Button Styles") {
                        ButtonStylesPreview()
                    }
                    NavigationLink("Typography") {
                        TypographyPreview()
                    }
                    NavigationLink("Colors") {
                        ColorPalettePreview()
                    }
                }
            }
            .padding()
        }
    }
}
```

### Step 5: Configure Launch Arguments Support

For more complex state, read environment variables or launch arguments:

```swift
struct PreviewLabApp: App {
    init() {
        // Read environment variable set via simctl
        if let variant = ProcessInfo.processInfo.environment["PREVIEW_VARIANT"] {
            UserDefaults.standard.set(variant, forKey: "PreviewLabVariant")
        }
        if let step = ProcessInfo.processInfo.environment["PREVIEW_STEP"] {
            UserDefaults.standard.set(step, forKey: "PreviewLabStep")
        }
    }

    var body: some Scene {
        WindowGroup {
            PreviewLabRootView()
        }
    }
}
```

## Running the Preview Lab

### Manual Run Script

Create `scripts/ui/run_preview_lab.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

DEVICE_NAME="${DEVICE_NAME:-iPhone 16}"
SCHEME="${SCHEME:-YourAppPreviewLab}"
PROJECT_PATH="${PROJECT_PATH:-YourApp/YourApp.xcodeproj}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/PreviewLabBuild}"
BUNDLE_ID="${BUNDLE_ID:-com.example.yourapp.previewlab}"

# Resolve simulator
resolve_udid() {
  xcrun simctl list devices available | sed -nE "/$1/{s/.*\(([A-F0-9-]+)\).*/\1/p; q;}"
}

UDID=$(resolve_udid "$DEVICE_NAME")
if [[ -z "$UDID" ]]; then
  echo "error: Simulator '$DEVICE_NAME' not found"
  exit 1
fi

# Boot if needed
xcrun simctl boot "$UDID" 2>/dev/null || true

# Build
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  build

# Find and install
APP_PATH=$(find "$DERIVED_DATA" -name "*.app" -type d | head -1)
xcrun simctl install "$UDID" "$APP_PATH"

# Set variant if specified
if [[ -n "${PREVIEW_VARIANT:-}" ]]; then
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" PreviewLabVariant -string "$PREVIEW_VARIANT"
fi
if [[ -n "${PREVIEW_STEP:-}" ]]; then
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" PreviewLabStep -string "$PREVIEW_STEP"
fi

# Launch
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"

echo "Launched $SCHEME on $DEVICE_NAME ($UDID)"
```

### Usage Examples

```bash
# Default view
./scripts/ui/run_preview_lab.sh

# Settings variant
PREVIEW_VARIANT=settings ./scripts/ui/run_preview_lab.sh

# Onboarding step 2
PREVIEW_VARIANT=onboarding PREVIEW_STEP=2 ./scripts/ui/run_preview_lab.sh

# Then screenshot
DEVICE_NAME="iPhone 16" ./scripts/ui/screenshot.sh
```

## Advanced Patterns

### Pattern 1: Mock Data Injection

```swift
struct PreviewLabRootView: View {
    // Inject mock services
    @State private var mockDataService = MockDataService()
    @State private var mockAuthService = MockAuthService()

    var body: some View {
        ContentView()
            .environment(mockDataService)
            .environment(mockAuthService)
    }
}

// Mock that returns predictable data
@Observable
class MockDataService {
    func fetchItems() async throws -> [Item] {
        // Return preview data instead of network call
        [
            Item(id: "1", title: "Preview Item 1"),
            Item(id: "2", title: "Preview Item 2"),
            Item(id: "3", title: "Preview Item 3"),
        ]
    }
}
```

### Pattern 2: State Matrix Testing

Test multiple states in one view:

```swift
struct StateMatrixView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Empty state
                Section("Empty State") {
                    ContentList(items: [])
                }

                // Loading state
                Section("Loading State") {
                    ContentList(items: [], isLoading: true)
                }

                // Error state
                Section("Error State") {
                    ContentList(items: [], error: PreviewError.network)
                }

                // Populated state
                Section("With Items") {
                    ContentList(items: Item.previewItems)
                }
            }
            .padding()
        }
    }
}
```

### Pattern 3: Interactive State Control

```swift
struct InteractivePreviewView: View {
    @State private var isLoggedIn = false
    @State private var itemCount = 3
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            // Control panel
            Form {
                Toggle("Logged In", isOn: $isLoggedIn)
                Stepper("Items: \(itemCount)", value: $itemCount, in: 0...10)
                Toggle("Show Error", isOn: $showError)
            }
            .frame(height: 180)

            Divider()

            // Preview with controlled state
            if showError {
                ErrorView(error: .networkUnavailable)
            } else if !isLoggedIn {
                LoginView()
            } else {
                HomeView(items: Array(Item.previewItems.prefix(itemCount)))
            }
        }
    }
}
```

### Pattern 4: Deep Link Testing

```swift
struct DeepLinkPreviewView: View {
    @State private var path = NavigationPath()
    @State private var deepLinkURL = ""

    var body: some View {
        VStack {
            // Deep link input
            TextField("Deep link URL", text: $deepLinkURL)
                .textFieldStyle(.roundedBorder)
                .padding()

            Button("Navigate") {
                handleDeepLink(deepLinkURL)
            }

            Divider()

            // Navigation stack
            NavigationStack(path: $path) {
                HomeView()
                    .navigationDestination(for: Route.self) { route in
                        route.destination
                    }
            }
        }
    }

    func handleDeepLink(_ url: String) {
        guard let route = Route.from(url: url) else { return }
        path.append(route)
    }
}
```

### Pattern 5: Component Gallery

```swift
struct ComponentGalleryView: View {
    var body: some View {
        List {
            Section("Buttons") {
                NavigationLink("Primary Buttons") { PrimaryButtonGallery() }
                NavigationLink("Secondary Buttons") { SecondaryButtonGallery() }
                NavigationLink("Icon Buttons") { IconButtonGallery() }
            }

            Section("Inputs") {
                NavigationLink("Text Fields") { TextFieldGallery() }
                NavigationLink("Pickers") { PickerGallery() }
                NavigationLink("Toggles") { ToggleGallery() }
            }

            Section("Cards") {
                NavigationLink("Content Cards") { ContentCardGallery() }
                NavigationLink("Action Cards") { ActionCardGallery() }
            }

            Section("Lists") {
                NavigationLink("Simple List") { SimpleListGallery() }
                NavigationLink("Grouped List") { GroupedListGallery() }
            }
        }
        .navigationTitle("Component Gallery")
    }
}
```

## Best Practices

1. **Keep it lightweight** - The preview lab should build fast
2. **No analytics** - Disable all analytics tracking
3. **No network** - Use mock data, not real API calls
4. **No persistence** - Don't write to real databases
5. **Deterministic** - Same input should always produce same output
6. **Comprehensive** - Cover all major views and states
7. **Documented** - List available variants in the script or README

## Directory Structure

```
YourApp/
├── YourApp/                    # Main app
│   ├── Views/
│   ├── Models/
│   └── ...
├── YourAppPreviewLab/          # Preview lab target
│   ├── PreviewLabApp.swift
│   ├── PreviewLabRootView.swift
│   ├── Previews/
│   │   ├── DefaultPreviewView.swift
│   │   ├── StateMatrixView.swift
│   │   └── ComponentGalleryView.swift
│   ├── Mocks/
│   │   ├── MockDataService.swift
│   │   └── MockAuthService.swift
│   └── Info.plist
├── scripts/
│   └── ui/
│       ├── run_preview_lab.sh
│       └── screenshot.sh
└── project.yml                 # XcodeGen config
```

## Integration with CI

```yaml
# GitHub Actions example
- name: Screenshot Preview Lab
  run: |
    # Boot simulator
    xcrun simctl boot "iPhone 16"

    # Build and run
    PREVIEW_VARIANT=onboarding ./scripts/ui/run_preview_lab.sh

    # Screenshot
    ./scripts/ui/screenshot.sh

    # Upload artifact
    - uses: actions/upload-artifact@v3
      with:
        name: preview-screenshots
        path: /tmp/UIScreenshots/
```
