# Contributing to ArcBLEKit

English | [简体中文](CONTRIBUTING.zh-CN.md)

Thanks for helping improve ArcBLEKit. Bug reports, documentation fixes, tests, and focused API proposals are welcome.

## Before opening an issue

- Search existing issues and confirm the problem still occurs with the latest release.
- Reduce bugs to the smallest reproducible example you can share.
- Include the ArcBLEKit, Xcode, Swift, operating-system, and device versions.
- For BLE behavior, describe the relevant services, characteristics, and characteristic properties.
- Remove device identifiers, payloads, and logs that contain private information.

Use a feature request to describe the problem before proposing a large public API change. This makes it easier to preserve source compatibility and keep the package focused.

## Local development

ArcBLEKit requires macOS with Xcode and a Swift 5.5-or-newer toolchain.

```bash
git clone https://github.com/ilawsonlu/ArcBLEKit.git
cd ArcBLEKit
swift package dump-package
swift test
```

Validate an iOS build with:

```bash
xcodebuild build \
  -scheme ArcBLEKit \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

The sample app in `Examples/ArcBLESampleApp` requires a physical iPhone or iPad and a BLE peripheral. Follow its README for the manual test flow.

## Pull requests

- Keep changes small and focused.
- Add or update tests for every behavior change.
- Preserve task cancellation, timeout, and disconnect behavior when changing asynchronous operations.
- Avoid adding dependencies unless the benefit clearly outweighs the integration cost.
- Document public APIs and update `CHANGELOG.md` for user-visible changes.
- Do not commit `.build`, Derived Data, signing settings, device identifiers, or captured BLE payloads.

CI runs the SwiftPM test suite, an iOS build, and a DocC documentation build. Real-device behavior cannot be covered by CI, so describe any device testing performed in the pull request.

## Reporting security issues

Do not open a public issue for a vulnerability that could expose application or device data. Use GitHub's private vulnerability reporting for the repository when available.
