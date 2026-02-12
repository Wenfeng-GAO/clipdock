<p align="center">
  <img src="docs/assets/clipdock-icon-1024.png" width="128" alt="ClipDock app icon" />
</p>

# ClipDock

ClipDock is an iOS app that helps users move videos from iPhone Photos to external storage, then delete originals to free up device space.

[![CI](https://github.com/Wenfeng-GAO/clipdock/actions/workflows/ci.yml/badge.svg)](https://github.com/Wenfeng-GAO/clipdock/actions/workflows/ci.yml)

## Current docs

- Product doc: `docs/product.md`
- Development doc: `docs/development.md`
- Project plan (3-day sprint): `docs/project-plan.md`

## Current implementation status

- M0: Project scaffold completed.
- M1: Photo permission flow completed.
- M2: External folder picker + security-scoped bookmark completed.
- M3 (minimal): Video scan sorted by date (desc) completed.

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

## License

MIT. See `LICENSE`.
