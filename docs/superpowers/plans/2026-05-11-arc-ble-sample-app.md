# ArcBLE Sample App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real-device iOS SwiftUI sample app for scanning, connecting, saving a peripheral identifier, and reconnecting with ArcBLEKit.

**Architecture:** The sample app lives under `Examples/ArcBLESampleApp` as an independent Xcode project that references the root ArcBLEKit Swift Package locally. A small SwiftUI view talks to an `ArcBLESampleViewModel`, which owns `BLEClient`, scan tasks, connection state, saved identifier persistence, and user-facing logs.

**Tech Stack:** SwiftUI, iOS 14+, CoreBluetooth, ArcBLEKit, Xcode project, local Swift Package dependency.

---

### Task 1: Create the iOS Sample App Project

**Files:**
- Create: `Examples/ArcBLESampleApp/ArcBLESampleApp.xcodeproj/project.pbxproj`
- Create: `Examples/ArcBLESampleApp/ArcBLESampleApp/ArcBLESampleApp.swift`
- Create: `Examples/ArcBLESampleApp/ArcBLESampleApp/ContentView.swift`
- Create: `Examples/ArcBLESampleApp/ArcBLESampleApp/ArcBLESampleViewModel.swift`
- Create: `Examples/ArcBLESampleApp/ArcBLESampleApp/Info.plist`
- Create: `Examples/ArcBLESampleApp/README.md`

- [ ] **Step 1: Add the Xcode project**

Create a single iOS app target named `ArcBLESampleApp`. Reference the root package with a local Swift Package dependency at `../..` and link product `ArcBLEKit`.

- [ ] **Step 2: Add the SwiftUI app entry point**

Create `ArcBLESampleApp.swift`:

```swift
import SwiftUI

@main
struct ArcBLESampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [ ] **Step 3: Add the BLE view model**

Create `ArcBLESampleViewModel.swift` with:

- editable `serviceUUIDText`
- discovered devices list
- scanning state
- connected session state
- saved identifier in `UserDefaults`
- `startScan()`, `stopScan()`, `connect(to:)`, `reconnectSavedDevice()`, and `clearSavedIdentifier()`

- [ ] **Step 4: Add the SwiftUI debug panel**

Create `ContentView.swift` with:

- Service UUID text field
- Start/stop scan button
- discovered device list
- connect buttons
- saved identifier section
- reconnect and clear buttons
- log output

- [ ] **Step 5: Add app permissions**

Create `Info.plist` with `NSBluetoothAlwaysUsageDescription`.

- [ ] **Step 6: Add sample README**

Create `Examples/ArcBLESampleApp/README.md` with opening and real-device build instructions.

- [ ] **Step 7: Verify**

Run:

```bash
xcodebuild -project Examples/ArcBLESampleApp/ArcBLESampleApp.xcodeproj -scheme ArcBLESampleApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
swift test
```

Expected: project builds and package tests pass.

- [ ] **Step 8: Commit**

```bash
git add Examples/ArcBLESampleApp docs/superpowers/plans/2026-05-11-arc-ble-sample-app.md
git commit -m "feat: add ArcBLE sample app"
```
