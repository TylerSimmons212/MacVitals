#!/usr/bin/env bash
# Build, sign, notarize and package a Mac Vitals release, then write the Sparkle appcast.
#
#   scripts/release.sh                 # build + notarize + appcast (nothing published)
#   scripts/release.sh --install       # …and replace /Applications/Mac Vitals.app
#   scripts/release.sh --publish       # …and create the GitHub release, then push appcast.xml
#
# Before a release: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml
# (Sparkle compares CURRENT_PROJECT_VERSION, so it must go up every release).
#
# One-time setup (same as Speek / VideoPro):
#   • Developer ID Application certificate in the login keychain (team 7MGPA96634)
#   • Sparkle EdDSA private key in the login keychain (shared with Speek/VideoPro)
#   • Notary credentials, e.g.:
#       xcrun notarytool store-credentials MacVitals-Notary \
#         --apple-id <you> --team-id 7MGPA96634 --password <app-specific password>
#     (or reuse an existing profile: NOTARY_PROFILE=Speek-Notary scripts/release.sh)

set -euo pipefail

INSTALL=0
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --publish) PUBLISH=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

TEAM_ID="7MGPA96634"
# Notary credentials belong to the Apple account, not the app: use MacVitals-Notary if it
# exists, otherwise the profile Speek already set up.
if [ -z "${NOTARY_PROFILE:-}" ]; then
  NOTARY_PROFILE="MacVitals-Notary"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || NOTARY_PROFILE="Speek-Notary"
fi
REPO="TylerSimmons212/MacVitals"
APP_NAME="Mac Vitals"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="$ROOT_DIR/build/release"
ARCHIVE="$BUILD_DIR/MacVitals.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/MacVitals.app"
TOOLS_DIR="$ROOT_DIR/scripts/.sparkle-tools"

# Check notary credentials up front, so a missing profile doesn't waste a whole build.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "❌ No notary credentials named \"$NOTARY_PROFILE\". Create them once with:"
  echo "   xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you> --team-id $TEAM_ID --password <app-specific password>"
  echo "   or reuse one: NOTARY_PROFILE=Speek-Notary scripts/release.sh"
  exit 1
fi

echo "🧹 Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

echo "🔧 Regenerating the Xcode project"
xcodegen generate >/dev/null

echo "📦 Archiving (Release, Developer ID, hardened runtime)"
xcodebuild -project MacVitals.xcodeproj -scheme MacVitals -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" archive -quiet

cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF

echo "📤 Exporting the signed app"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" -quiet
codesign --verify --deep --strict "$APP"

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$APP/Contents/Info" CFBundleVersion)
DMG="$BUILD_DIR/MacVitals-$VERSION.dmg"
echo "✅ Mac Vitals $VERSION ($BUILD)"

echo "💿 Building the disk image"
STAGING="$BUILD_DIR/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "🔐 Notarizing (usually 1–5 minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" && echo "   Gatekeeper accepts it"

echo "📡 Writing the Sparkle appcast"
SPARKLE_VERSION=$(python3 -c "import json; d=json.load(open('MacVitals.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')); print(next(p['state']['version'] for p in d['pins'] if p['identity']=='sparkle'))")
if [ ! -x "$TOOLS_DIR/$SPARKLE_VERSION/bin/generate_appcast" ]; then
  echo "   Fetching Sparkle $SPARKLE_VERSION tools from github.com/sparkle-project"
  mkdir -p "$TOOLS_DIR/$SPARKLE_VERSION"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$TOOLS_DIR/$SPARKLE_VERSION"
fi
FEED_DIR="$BUILD_DIR/feed"
mkdir -p "$FEED_DIR"
cp "$DMG" "$FEED_DIR/"
[ -f "$ROOT_DIR/appcast.xml" ] && cp "$ROOT_DIR/appcast.xml" "$FEED_DIR/appcast.xml"
# Signs the DMG with the EdDSA key from the login keychain and adds this version.
"$TOOLS_DIR/$SPARKLE_VERSION/bin/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  "$FEED_DIR"
cp "$FEED_DIR/appcast.xml" "$ROOT_DIR/appcast.xml"
# Release notes: the GitHub release page (Sparkle's window is empty without a link).
python3 - "$ROOT_DIR/appcast.xml" "$REPO" <<'PY'
import re, sys
path, repo = sys.argv[1], sys.argv[2]
xml = open(path).read()
def add(match):
    item = match.group(0)
    version = re.search(r"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>", item)
    if "releaseNotesLink" in item or not version or "<enclosure" not in item:
        return item
    link = f"<sparkle:releaseNotesLink>https://github.com/{repo}/releases/tag/v{version.group(1)}</sparkle:releaseNotesLink>\n            "
    return item.replace("<enclosure", link + "<enclosure", 1)
open(path, "w").write(re.sub(r"<item>.*?</item>", add, xml, flags=re.S))
PY

if [ "$INSTALL" = 1 ]; then
  echo "📲 Installing to /Applications"
  osascript -e 'tell application id "com.tylersimmons.MacVitals" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x MacVitals >/dev/null || break; sleep 0.5; done
  ditto "$APP" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
fi

if [ "$PUBLISH" = 1 ]; then
  # Order matters: the download must exist before the appcast points at it.
  echo "🚀 Publishing v$VERSION"
  git tag -f "v$VERSION"
  git push origin "v$VERSION"
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --title "Mac Vitals $VERSION" --generate-notes
  # The project file carries the version too (regenerated above from project.yml).
  git add appcast.xml MacVitals.xcodeproj/project.pbxproj
  git commit -m "Release $VERSION appcast"
  git push origin HEAD
  echo "🎉 Published. Installed copies will find it at their next daily check (or Check for Updates…)."
else
  echo ""
  echo "🎉 Built $DMG"
  echo "   Publish with: scripts/release.sh --publish (creates the GitHub release, then pushes appcast.xml)"
fi
