# 바로렌즈 · Barolens

<img src="Sources/Barolens/Resources/Assets.xcassets/AppIcon.appiconset/icon-128.png" width="96" height="96" alt="Barolens: A becomes 가 through a glass overlay">

Translate text where you see it on your Mac. Place a resizable overlay over a document, website, or app to read translations near the original text. Recognition and translation use Apple's on-device frameworks; no separate model server is needed.

## Download and requirements

**[Download Barolens for macOS](https://github.com/kuil09/barolens/releases)** — choose the DMG and its SHA-256 sidecar from the release. Exact versions, signing/notarization results, checksums, and known validation limits belong to the release notes, not the source checkout.

- Apple Silicon Mac, macOS 26.4 or later.
- Screen Recording permission and a supported, installed translation language pair.
- Internet access to download additional translation languages. Xcode is **not** required to run the downloaded app; source-build requirements are in [Development](docs/development.md).

## Get started

1. Open the DMG, drag **바로렌즈** to **Applications**, and open it there. To update, quit the previous copy first; downloading alone does not update the installed app.
2. Follow the first-launch guide to allow screen access, select installed languages, and choose the shared image/video folder. Only Barolens's explicit screen-access action hides the overlay for authentication; ordinary System Settings visits leave translation and recording running.
3. Place the overlay over horizontal text, select source and target, and turn on **Translation**. Translation off shows frosted Liquid Glass; on reveals the screen with translated text.
4. Enable **Pass Through Clicks and Scrolling** to use the app underneath. Only the body passes input through; the toolbar and resize edges stay interactive.
5. Use the camera and record controls to save PNG images or silent MP4 videos directly to your chosen folder. The folder button opens that folder in Finder.

The app is named **바로렌즈** (Barolens). Its identifier is `dev.local.barolens`; existing preferences migrate once at startup. Screen Recording access must be checked for this new identity.

The interface follows macOS language preferences and supports English, Korean, and Japanese. Translation choices are separate: only installed routes with compatible source OCR appear. Add languages through **System Language Download…** in Help or Settings.

## Limits and guides

Barolens is a beta focused on horizontal text, not vertical writing or games. Ambiguous short text can remain untranslated. Exports include the captured background even when the overlay is transparent; inspect files before sharing. Notarization is an Apple security check, not a translation-quality or runtime guarantee. Never disable macOS security protections to install Barolens.

- [Using Barolens](docs/usage.md) · [Troubleshooting](docs/troubleshooting.md) · [Privacy](docs/privacy.md)
- [Development](docs/development.md) · [Contributing](CONTRIBUTING.md)
- [Release procedure](docs/releasing.md) · [Verification boundaries](docs/validation-history.md)
- [Changelog](CHANGELOG.md) · [Security reporting](SECURITY.md)

Licensed under the [MIT License](LICENSE), copyright **2026 kuil09**.
