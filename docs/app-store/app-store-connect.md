# ClipDock App Store Submission Checklist (Pre-1.0)

This file is a practical, copy/paste oriented checklist for submitting ClipDock to the App Store.

## URLs (ready to use)

- Website (optional): https://wenfeng-gao.github.io/clipdock/
- Privacy Policy URL (required): https://wenfeng-gao.github.io/clipdock/app-store/privacy-policy.html
- Support URL (recommended): https://wenfeng-gao.github.io/clipdock/app-store/support.html
- Support email: elricfeng@gmail.com

## 0. Prerequisites

1. Apple Developer Program membership: Active.
2. Bundle ID: `com.wenfeng.clipdock`.
3. Target devices: iPhone-only (first release).
4. App pricing: Free (can change later).

## 1. App Store Connect: Create App Record

1. Go to App Store Connect -> My Apps -> New App.
2. Platform: iOS.
3. Name: `ClipDock`.
4. Primary language: English.
5. Bundle ID: `com.wenfeng.clipdock`.
6. SKU: `clipdock`.

Optional localizations:
- You can add Simplified Chinese localization, but keep the name as `ClipDock`.

## 2. Pricing and Availability

1. Price: Free.
2. Availability / Territories:
   - China (Mainland)
   - English-speaking markets (suggested minimum): United States, United Kingdom, Canada, Australia, New Zealand, Ireland
   - Optional: Singapore

Note:
- If China (Mainland) submission is blocked by additional compliance requirements, unselect China temporarily and ship to other territories first.

## 3. App Information

1. Category (suggestion): Utilities.
2. Age rating: likely 4+ (unless you add content).
3. Privacy Policy URL: use the URL above.
4. Support URL: use the URL above.

## 4. App Privacy (Nutrition Label)

ClipDock is designed to be offline.

Suggested answers:
- Data used to track you: No.
- Data collected: No.

## 5. Build Upload

In Xcode:
1. Select the `ClipDock` scheme.
2. Product -> Archive.
3. Distribute App -> App Store Connect -> Upload.

After upload:
- App Store Connect -> TestFlight -> select the build.

## 6. Review Notes (highly recommended)

Paste something like this in "Review Notes":

- ClipDock copies selected videos from the Photos library to a folder chosen via the Files app.
- External drive is optional for review: you can choose a local folder (On My iPhone) in Files as the destination.
- Steps to test:
  1) Grant Photos access.
  2) Tap "Choose External Folder" and select a folder in Files.
  3) Tap "Scan Videos", select 1-2 videos, then tap "Start Migration".
  4) Verify the exported file exists in the selected folder.
  5) Optional: After migration, tap "Delete Migrated Originals" (only deletes items migrated+validated in the last run).

## 7. Screenshots (plan)

For the first submission, prepare screenshots for required iPhone sizes.

Recommended set:
1. Home screen (folder selected + scan + sort).
2. Video list with selection.
3. Migration in progress.
4. Migration completed (post-migration).
5. History screen.

## 8. Known Constraints (transparent)

- iOS does not allow moving a Photos item directly. ClipDock does copy to destination and then (optionally) deletes originals after user confirmation.
- Video size display is best-effort and may show `--` for iCloud-only assets until downloaded/exported.
