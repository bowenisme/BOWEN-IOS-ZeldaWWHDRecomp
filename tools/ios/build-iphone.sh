#!/bin/bash
# Build The Wind Waker HD for iPhone/iPad from YOUR OWN copy of the game, then install it.
#
#   tools/ios/build-iphone.sh --wua "path/to/game.wua"      # or --wud/--wux disc image (keys next to it)
#   tools/ios/build-iphone.sh --game path/to/extracted/game  # code/ content/ meta/
#
# Options:
#   --team ID          your Apple developer team ID (detected from your Xcode certificate if you have one)
#   --bundle-id ID     app identifier (default: org.wwhdrecomp.ios.<your team ID>)
#   --free-account     you sign with a free Apple ID: no paid-only entitlements; the app expires every 7 days
#   --sidestore        build an .ipa for SideStore/AltStore instead of installing (no paid entitlements)
#   --no-install       build only (the .ipa is saved in build/ios-work/)
#
# The app contains game code recompiled from your copy: it is for your own devices. Never share it.
# Re-running is safe: extraction and finished build steps are reused. Updating keeps your saves.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-$SRC/build/ios-work}"
GAME="$WORK/game"
USA_TITLE=0005000010143500
IMAGE="" GAMEDIR="" TEAM="${TEAM:-}" BUNDLE_ID="${BUNDLE_ID:-}" FREE=0 SIDESTORE=0 INSTALL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --wua|--wud|--wux|--image) IMAGE="$2"; shift 2 ;;
    --game) GAMEDIR="$2"; shift 2 ;;
    --team) TEAM="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --free-account) FREE=1; shift ;;
    --sidestore) SIDESTORE=1; FREE=1; INSTALL=0; shift ;;
    --no-install) INSTALL=0; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mStopped: %s\033[0m\n' "$*" >&2; exit 1; }
mkdir -p "$WORK"

# ---------------------------------------------------------------- tools
step "Checking Xcode"
xcodebuild -version >/dev/null 2>&1 || die "Full Xcode isn't installed/selected. Install Xcode (App Store, or
developer.apple.com/download/all for older macOS), open it once, then:  sudo xcode-select -s /Applications/Xcode.app"
xcodebuild -version | head -1
xcodebuild -showsdks 2>/dev/null | grep -q iphoneos || die "Xcode has no iOS platform. Run:  xcodebuild -downloadPlatform iOS"
if ! command -v cmake >/dev/null 2>&1; then
  [ -x "$WORK/.venv/bin/cmake" ] || { echo "Installing CMake into $WORK/.venv"; python3 -m venv "$WORK/.venv"; "$WORK/.venv/bin/pip" install -q cmake; }
  export PATH="$WORK/.venv/bin:$PATH"
fi

# ---------------------------------------------------------------- game files
step "Game files"
if [ -n "$GAMEDIR" ]; then
  GAME="$(cd "$GAMEDIR" && pwd)"
elif [ ! -f "$GAME/code/cking.rpx" ]; then
  [ -n "$IMAGE" ] || die "Give your game: --wua FILE, --wud FILE (with its key) or --game EXTRACTED_FOLDER."
  [ -f "$IMAGE" ] || die "Can't find $IMAGE"
  EXTRACT="${WWHD_EXTRACT:-}"
  if [ -z "$EXTRACT" ]; then
    for c in /Applications/WindWakerHD*/tools/bin/wwhd-extract "$HOME"/Applications/WindWakerHD*/tools/bin/wwhd-extract \
             "$HOME"/Downloads/WindWakerHD*/tools/bin/wwhd-extract; do [ -x "$c" ] && EXTRACT="$c" && break; done
  fi
  [ -n "$EXTRACT" ] || die "The extractor (wwhd-extract) wasn't found. Download the macOS release of Wind Waker HD Recomp
(github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp/releases), unzip it into Applications, and run this again."
  echo "Extracting the USA v0 game (a few minutes)"
  rm -rf "$GAME.partial"
  "$EXTRACT" --title "$USA_TITLE" --progress extract "$IMAGE" "$GAME.partial"
  mv "$GAME.partial" "$GAME"
fi
python3 "$SRC/ios/build.py" --check-game --game "$GAME"

# ---------------------------------------------------------------- signing team and app ID
step "Signing team"
if [ -z "$TEAM" ]; then
  CERTS="$(mktemp -d)"
  security find-certificate -a -c "Apple Development" -p > "$CERTS/all.pem" 2>/dev/null || true
  awk -v dir="$CERTS" '/BEGIN CERT/{n++} n{print > (dir "/c" n ".pem")}' "$CERTS/all.pem"
  TEAMS=$(for f in "$CERTS"/c*.pem; do if [ -f "$f" ]; then openssl x509 -noout -subject -in "$f"; fi; done 2>/dev/null \
          | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | sort -u || true)
  rm -rf "$CERTS"
  case "$(printf '%s\n' "$TEAMS" | grep -c . || true)" in
    1) TEAM="$TEAMS" ;;
    0) die "No Apple Development certificate. In Xcode: Settings > Accounts > + (your Apple ID) > Manage Certificates
> + > Apple Development. A free Apple ID works too (add --free-account)." ;;
    *) die "Several teams found ($(echo $TEAMS)). Pick one:  --team XXXXXXXXXX" ;;
  esac
fi
BUNDLE_ID="${BUNDLE_ID:-org.wwhdrecomp.ios.$(echo "$TEAM" | tr 'A-Z' 'a-z')}"
echo "Team $TEAM, app ID $BUNDLE_ID$([ $FREE = 1 ] && echo ' (free-account build: expires after 7 days)')"

# ---------------------------------------------------------------- phone
UDID="" DEVICE=""
if [ $INSTALL = 1 ]; then
  step "Finding your iPhone (USB, unlocked, Trust this Mac, Developer Mode on)"
  command -v idevice_id >/dev/null 2>&1 && UDID="$(idevice_id -l 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
  DEVJSON="$(mktemp)"
  xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1 || echo '{"result":{"devices":[]}}' > "$DEVJSON"
  DEVICE=$(python3 - "$DEVJSON" "$UDID" <<'PY'
import json, sys
want = sys.argv[2]
ok = [d for d in json.load(open(sys.argv[1]))["result"]["devices"]
      if d.get("hardwareProperties", {}).get("platform") == "iOS"
      and d.get("connectionProperties", {}).get("pairingState") == "paired"
      and (not want or d.get("hardwareProperties", {}).get("udid") == want)]
print(ok[0]["identifier"] if ok else "")
if ok and not want: open(sys.argv[1] + ".udid", "w").write(ok[0]["hardwareProperties"].get("udid", ""))
PY
)
  [ -z "$UDID" ] && UDID="$(cat "$DEVJSON.udid" 2>/dev/null || true)"
  rm -f "$DEVJSON" "$DEVJSON.udid"
  [ -n "$UDID" ] && echo "  found UDID $UDID" || echo "  no iPhone connected: building anyway"
fi

# ---------------------------------------------------------------- build
step "Recompiling the game and building the app (first time: 20-60 min)"
EXTRA=(); [ $FREE = 1 ] && EXTRA+=(--free-account)
run_build() { python3 "$SRC/ios/build.py" --game "$GAME" --team "$TEAM" --bundle-id "$BUNDLE_ID" --configuration Release "${EXTRA[@]}" 2>&1 | tee "$WORK/build.log"; }
if ! run_build; then
  echo; echo "---- errors (full log: $WORK/build.log) ----"
  grep -E "error:" "$WORK/build.log" | sort -u | head -25
  grep -q -i -E "no devices|provisioning profile|Signing for|entitlement" "$WORK/build.log" && \
    echo "Signing problem? Register your iPhone (UDID ${UDID:-?}) at developer.apple.com > Devices, or use --free-account."
  die "The build failed. Please open an issue with the errors above."
fi
APP="$SRC/build/ios-game/Release-iphoneos/wwhd.app"
[ -d "$APP" ] || die "Build finished but $APP is missing."

# a newly registered phone needs a fresh signing profile
profile_has_phone() {
  security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | python3 -c \
    'import plistlib,sys; print("\n".join(plistlib.loads(sys.stdin.buffer.read()).get("ProvisionedDevices",[])))' 2>/dev/null | grep -qi "$UDID"
}
if [ $INSTALL = 1 ] && [ -n "$UDID" ] && ! profile_has_phone; then
  step "Refreshing the signing profile for this iPhone"
  for d in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.mobileprovision "$d"/*.provisionprofile; do
      [ -f "$f" ] && security cms -D -i "$f" 2>/dev/null | grep -q "<string>$TEAM.$BUNDLE_ID</string>" && rm -f "$f"
    done
  done
  run_build >/dev/null || die "Signing again failed; see $WORK/build.log."
  profile_has_phone || die "This iPhone isn't registered to your developer team: developer.apple.com > Account >
Certificates, IDs & Profiles > Devices > +  (UDID $UDID), then run again."
fi

IPA="$WORK/WindWakerHD$([ $SIDESTORE = 1 ] && echo -SideStore).ipa"
rm -rf "$WORK/.ipa" && mkdir -p "$WORK/.ipa/Payload" && cp -R "$APP" "$WORK/.ipa/Payload/"
(cd "$WORK/.ipa" && rm -f "$IPA" && zip -qry "$IPA" Payload) && rm -rf "$WORK/.ipa"
echo "Saved: $IPA"
if [ $INSTALL = 0 ]; then
  step "Done"
  [ $SIDESTORE = 1 ] && echo "AirDrop it to your iPhone > SideStore > My Apps > + > pick the file."
  echo "Then copy your extracted game folder into the app as 'game' (Finder > iPhone > Files)."
  exit 0
fi

# ---------------------------------------------------------------- install
step "Installing"
[ -n "$UDID" ] || die "No iPhone connected; the app is built ($IPA). Plug it in and run this again."
if [ -n "$DEVICE" ] && xcrun devicectl device install app --device "$DEVICE" "$APP" 2>/dev/null; then :
elif command -v ideviceinstaller >/dev/null 2>&1; then
  ideviceinstaller -u "$UDID" install "$IPA" || ideviceinstaller -u "$UDID" -i "$IPA" || die "Install failed. Is the iPhone unlocked?"
else
  die "This Xcode can't install to your iOS version. Run  brew install ideviceinstaller  and try again."
fi

step "Done"
echo "First install: Finder > your iPhone > Files tab > drag $GAME onto 'The Legend of Zelda: The Wind Waker HD'"
echo "(it must appear as a folder named 'game'). If iOS says the developer isn't trusted:"
echo "Settings > General > VPN & Device Management > trust your certificate."
