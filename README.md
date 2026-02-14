<p align="center">
  <img src="docs/assets/clipdock-icon-1024.png" width="128" alt="ClipDock app icon" />
</p>

# ClipDock

App Store display name: **ClipDock: Free Up Space** (1.0).

ClipDock is an iOS app that helps you copy selected videos from iPhone Photos to an external folder (Files), then optionally delete originals to free up device space.

[![CI](https://github.com/Wenfeng-GAO/clipdock/actions/workflows/ci.yml/badge.svg)](https://github.com/Wenfeng-GAO/clipdock/actions/workflows/ci.yml)

## Docs (1.0)

- Product doc: `docs/releases/1.0/product.md`
- Development doc: `docs/releases/1.0/development.md`
- App Store prep: `docs/app-store/app-store-connect.md`

## Key Features (1.0)

- Choose an external destination folder (security-scoped bookmark).
- Scan videos from Photos.
- Sort by date or size (local-only, best-effort).
- Select videos manually, Select All, or use Quick Filter (by year/month and/or Top-N by size).
- Migrate (copy) selected videos to the destination folder.
- After a successful migration run, optionally delete migrated originals (explicit confirmation).

## Notes / Limitations

- Video size is best-effort and local-only (iCloud-only items may show `--` until downloaded/exported).
- Migration is most reliable when ClipDock stays in the foreground; background execution is limited by iOS.

## Local setup

1. Ensure full Xcode is installed (not just Command Line Tools).
2. Generate the project:
   ```bash
   xcodegen generate
   ```
3. Open:
   ```bash
   open ClipDock.xcodeproj
   ```
4. Run on a real iPhone for external storage testing.

If `xcodebuild` reports Command Line Tools only, switch developer directory after installing Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## CI

GitHub Actions runs `xcodegen generate` and `xcodebuild test` on PRs and `main`.

## App Store Links

- Privacy Policy: https://wenfeng-gao.github.io/clipdock/app-store/privacy-policy.html
- Support: https://wenfeng-gao.github.io/clipdock/app-store/support.html

## License

MIT. See `LICENSE`.
