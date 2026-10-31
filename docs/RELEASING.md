# Signing and notarization

Full Xcode is optional. This SwiftPM project uses Command Line Tools, `codesign`, `notarytool`, and `stapler`.

AgentDock is free to use. Its License tab is informational; no activation, license key, subscription, or payment configuration is required.

## One-time setup

1. Open Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority. Enter your developer email and a key name, leave CA Email empty, and select Saved to disk.
2. In https://developer.apple.com/account/resources/certificates/list create a **Developer ID Application** certificate using that CSR. Download the `.cer` and double-click it to install it in the same Mac's login Keychain. Keep the private key on this Mac.
3. Run `security find-identity -v -p codesigning` and copy the full `Developer ID Application: … (TEAMID)` certificate name.
4. Create an app-specific password at https://account.apple.com. In your own Terminal, store notarization credentials interactively:

```sh
xcrun notarytool store-credentials AgentDock-notary
```

Enter your Apple Account email, developer Team ID, and app-specific password when prompted. Do not paste passwords/private keys into chat, scripts, or source control. An App Store Connect API key can also be stored with `notarytool store-credentials`; the release script only needs the resulting Keychain profile name.

## Build and notarize

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='AgentDock-notary' \
./scripts/notarize.sh
```

The script signs the app, builds a DMG, submits it to Apple, saves the notary result/log in `dist/`, checks for `Accepted`, staples the DMG, verifies Gatekeeper, and copies `AgentDock.dmg` to `agent-dock-landing/public/downloads/`. No public hosting or GitHub release is created. Do not edit the app after signing/stapling.

Regular `./scripts/bundle.sh` continues to make an ad-hoc signed local development build. Passing `SIGNING_IDENTITY` enables Developer ID signing without submitting to Apple.

Before public distribution, set the intended app version/build in Resources/Info.plist, sync `update.json` and the landing `public/update.json`, and test the quarantined download on another Apple Silicon Mac. AgentDock requires macOS 13 or later and Apple Silicon.

## Update manifest

Ship `update.json` at `https://agentdock.siliconapps.dev/update.json` (see repo root and landing `public/update.json`). Fields: `version`, `build` (must exceed `CFBundleVersion` on clients), `downloadURL`, optional `releaseNotes`. `./scripts/notarize.sh` refuses to run if those files disagree with `Info.plist`.

Apple references:
- https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request
- https://developer.apple.com/help/account/certificates/create-developer-id-certificates
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
