# Contributing

## Prereqs
- Full Xcode installed (not just Command Line Tools)
- XcodeGen (`brew install xcodegen`)

## Local setup
```bash
xcodegen generate
open ClipDock.xcodeproj
```

## Running tests
```bash
xcodebuild \
  -project ClipDock.xcodeproj \
  -scheme ClipDock \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  test
```

## Pull requests
- Keep changes focused and small when possible.
- If touching photo migration/deletion logic, include a short risk note and manual test steps.

