# ClipDock App Store Submission Checklist (1.0)

This file is a practical, copy/paste oriented checklist for submitting **ClipDock 1.0** to the App Store.

## URLs (ready to use)

- Website (optional): https://wenfeng-gao.github.io/clipdock/
- Privacy Policy URL (required): https://wenfeng-gao.github.io/clipdock/app-store/privacy-policy.html
- Support URL (recommended): https://wenfeng-gao.github.io/clipdock/app-store/support.html
- Support email: elricfeng@gmail.com

## 0. Prerequisites

1. Apple Developer Program membership: Active.
2. Bundle ID: `com.wenfeng.clipdock`.
3. Target devices: iPhone-only (first release).
4. App pricing: Free.
5. Release version:
   - Version: `1.0.0`
   - Build: increment as needed for each upload (`CFBundleVersion`).

## Submission Record

- 2026-02-14: Submitted `1.0.0 (9)` for review. Status: Waiting for Review.

## 1. App Store Connect: Create App Record

1. Go to App Store Connect -> My Apps -> New App.
2. Platform: iOS.
3. Name (App Store display name): `ClipDock: Free Up Space` (must be unique).
4. Primary language: English.
5. Bundle ID: `com.wenfeng.clipdock`.
6. SKU: `clipdock`.

Optional localizations:
- You can add Simplified Chinese localization later.

Important:
- If you do NOT distribute in the EU, you can ignore EU-only requirements in the app metadata.
- However, Apple may still require you to declare your Digital Services Act (DSA) trader status in App Store Connect.
  If you see a red banner about EU/DSA compliance:
  - Go to App Store Connect -> Business -> Compliance -> Digital Services Act
  - Declare your trader status (usually "Not a trader" for a free, offline utility app).

## 2. Pricing and Availability

1. Price: Free.
2. Availability / Territories:
   - China (Mainland) + United States (fast first release, avoids EU-specific compliance).

Note:
- China (Mainland) may require additional compliance info (e.g. ICP/filing related fields shown in App Information for China).
  If App Store Connect blocks "China (Mainland)" without these, the fastest workaround is:
  - Ship to United States first, then add China (Mainland) after compliance is complete.
  - (Alternative) Ship to non-mainland territories first (e.g. Hong Kong / Macau / Taiwan / Singapore), then add China (Mainland).

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

Also check:
- IDFA: not used.
- Ads: not shown.

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
  1) Tap "Choose External Folder" and select a folder in Files (On My iPhone is fine).
  2) Tap "Scan Videos".
  3) Select 1-2 videos (tap rows), then tap "Start Migration".
  4) Verify the exported file exists in the selected folder.
  5) Optional: After migration completes, tap "Delete Originals" (only deletes items migrated+validated in the last run; requires Full Photos access).

## 7. Screenshots (plan)

For the first submission, prepare screenshots for required iPhone sizes.

Recommended set:
1. Home screen (folder selected + scan + selection + selected size).
2. Quick Filter (year grouped months + Top-N).
3. Video list (sorted by size).
4. Migration in progress (progress + filename).
5. Migration completed (Start disabled, Delete highlighted).

### 7.1 Generate the 6.5-inch iPhone screenshot (local helper)

App Store Connect commonly requires a 6.5-inch iPhone screenshot. This repo includes a simulator-only
"screenshot mode" that avoids Photos permission dialogs and does not require real media.

1. Run:
   ```bash
   cd /Users/wenfeng/Documents/iphoneapp
   scripts/generate_app_store_screenshot_iphone65.sh
   ```
2. Output file:
   - `docs/app-store/screenshots/iphone65-1.png` (ignored by git)

## 8. Known Constraints (transparent)

- iOS does not allow moving a Photos item directly. ClipDock does copy to destination and then (optionally) deletes originals after user confirmation.
- Video size display is best-effort and may show `--` for iCloud-only assets until downloaded/exported.
- iOS background execution is limited. Migration is most reliable when ClipDock stays in the foreground.

## 9. Export Compliance

Suggested answers (confirm on each release):
- Uses encryption? No.
