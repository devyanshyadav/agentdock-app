#!/bin/bash
set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "Usage: SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)' NOTARY_PROFILE='AgentDock-notary' $0" >&2
    exit 2
fi
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate name.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your saved notarytool Keychain profile.}"

case "$SIGNING_IDENTITY" in
    "Developer ID Application: "*) ;;
    *) echo "Internet distribution requires a Developer ID Application certificate." >&2; exit 1 ;;
esac
if ! security find-identity -v -p codesigning | grep -Fq -- "\"$SIGNING_IDENTITY\""; then
    echo "The signing certificate and its private key are not available in this Mac's Keychain." >&2
    exit 1
fi
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANDING_DOWNLOADS="$ROOT/../agent-dock-landing/public/downloads"
DOWNLOAD_DMG="AgentDock.dmg"

PLIST="$ROOT/Resources/Info.plist"
APP_JSON="$ROOT/update.json"
LANDING_JSON="$ROOT/../agent-dock-landing/public/update.json"
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
plist_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
json_version=$(jq -r '.version' "$APP_JSON")
json_build=$(jq -r '.build' "$APP_JSON")
if [[ "$json_version" != "$plist_version" ]] || [[ "$json_build" != "$plist_build" ]]; then
    echo "error: update.json ($json_version/$json_build) != Info.plist ($plist_version/$plist_build)" >&2
    exit 1
fi
if [[ -f "$LANDING_JSON" ]]; then
    landing_version=$(jq -r '.version' "$LANDING_JSON")
    landing_build=$(jq -r '.build' "$LANDING_JSON")
    if [[ "$landing_version" != "$plist_version" ]] || [[ "$landing_build" != "$plist_build" ]]; then
        echo "error: agent-dock-landing/public/update.json ($landing_version/$landing_build) != Info.plist ($plist_version/$plist_build)" >&2
        exit 1
    fi
fi
echo "Release metadata OK: v$plist_version (build $plist_build)"

SIGNING_IDENTITY="$SIGNING_IDENTITY" "$ROOT/scripts/bundle.sh"
APP="$ROOT/build/AgentDock.app"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ || ! "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "App version and build number must be numeric dotted values." >&2
    exit 1
fi
mkdir -p "$ROOT/dist"
NAME="AgentDock-$VERSION-$BUILD-arm64"
REPORT="$ROOT/dist/$NAME-notary.json"
DIST_DMG="$ROOT/dist/$NAME.dmg"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

DMG_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-dmg.XXXXXX")"
cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
/usr/bin/hdiutil create -volname "AgentDock" -srcfolder "$DMG_STAGING" -ov -format UDZO "$WORK/upload.dmg"
rm -rf "$DMG_STAGING"

xcrun notarytool submit "$WORK/upload.dmg" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$REPORT"
STATUS="$(/usr/bin/plutil -extract status raw -o - "$REPORT")"
SUBMISSION="$(/usr/bin/plutil -extract id raw -o - "$REPORT")"
xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" "$ROOT/dist/$NAME-notary-log.json"
if [ "$STATUS" != "Accepted" ]; then
    echo "Apple returned $STATUS. Review $ROOT/dist/$NAME-notary-log.json." >&2
    exit 1
fi

cp -f "$WORK/upload.dmg" "$DIST_DMG"
xcrun stapler staple "$DIST_DMG"
xcrun stapler validate "$DIST_DMG"
MOUNT="$(/usr/bin/hdiutil attach -nobrowse -readonly "$DIST_DMG" | awk '/\/Volumes\// {print $3; exit}')"
if [ -n "$MOUNT" ] && [ -d "$MOUNT/AgentDock.app" ]; then
    spctl -a -vv "$MOUNT/AgentDock.app" 2>&1
    /usr/bin/hdiutil detach "$MOUNT" >/dev/null
else
    echo "Could not mount DMG to verify AgentDock.app." >&2
    [ -n "$MOUNT" ] && /usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    exit 1
fi

mkdir -p "$LANDING_DOWNLOADS"
cp -f "$DIST_DMG" "$LANDING_DOWNLOADS/$DOWNLOAD_DMG"

echo "Notarized release: $DIST_DMG"
echo "Landing download: $LANDING_DOWNLOADS/$DOWNLOAD_DMG"
echo "URL: https://agentdock.siliconapps.dev/downloads/$DOWNLOAD_DMG"
