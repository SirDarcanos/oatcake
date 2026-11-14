#!/bin/bash
# Builds build/Oatcake.app: the app, with the recorder as its own app bundle inside it (macOS counts
# what the recorder uses as Oatcake's, and asks for the microphone and system audio in Oatcake's
# name), and with llama.cpp's
# server, which runs the language model on this Mac (see Sources/OatcakeCore/LocalModel.swift).
#
#   Scripts/bundle.sh            release build
#   Scripts/bundle.sh debug      debug build
#
# Signed with the "Oatcake Release" certificate when it's in a keychain (OATCAKE_SIGN_IDENTITY and
# OATCAKE_SIGN_KEYCHAIN choose another), otherwise ad-hoc. macOS ties the recorder's permissions and
# Oatcake's Keychain items to that identity: an ad-hoc build is a new app to macOS every time, and
# only a release-signed copy can update itself. OATCAKE_REQUIRE_SIGNING=1 refuses to fall back to ad-hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/build/Oatcake.app"
cd "$ROOT"

# OATCAKE_BIN names the folder of binaries when they're already built. The release workflow builds
# before the signing identity is on the runner and passes it, so nothing of the package's or its
# dependency's runs once there is something to sign with.
if [[ -n "${OATCAKE_BIN:-}" ]]; then
    BIN="$OATCAKE_BIN"
else
    swift build -c "$CONFIG" --product Oatcake
    swift build -c "$CONFIG" --product OatcakeRecorder
    BIN="$(swift build -c "$CONFIG" --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Oatcake" "$APP/Contents/MacOS/Oatcake"
sed "s/VERSION/$VERSION/g" Resources/Oatcake-Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp assets/Oatcake.icns "$APP/Contents/Resources/Oatcake.icns"

RECORDER="$APP/Contents/Resources/OatcakeRecorder.app"
mkdir -p "$RECORDER/Contents/MacOS"
cp "$BIN/OatcakeRecorder" "$RECORDER/Contents/MacOS/oatcake-recorder"
sed "s/VERSION/$VERSION/g" Resources/OatcakeRecorder-Info.plist > "$RECORDER/Contents/Info.plist"

# llama.cpp's server and the libraries it loads: one fixed build from llama.cpp's own releases,
# checked against its SHA-256 before anything is taken from it. To move to a newer build, change the
# tag and the checksum together (shasum -a 256 on the archive), and measure before shipping.
LLAMA_TAG=b12110
LLAMA_SHA256=4f5b8de12e0b9516658ca6a5764c6ffb3d7c659c3dd538556b1413c7b4050662
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-bin-macos-arm64.tar.gz"
LLAMA_FILES=(llama-server libllama-server-impl.dylib libllama-common.0.dylib libmtmd.0.dylib libllama.0.dylib libggml.0.dylib
             libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib libggml-rpc.0.dylib libggml-base.0.dylib)
CACHE="$ROOT/.build/llama"
ARCHIVE="$CACHE/llama-$LLAMA_TAG-bin-macos-arm64.tar.gz"
checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }
mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" || "$(checksum "$ARCHIVE")" != "$LLAMA_SHA256" ]]; then
    curl -fsSL --retry 3 -o "$ARCHIVE" "$LLAMA_URL"
fi
if [[ "$(checksum "$ARCHIVE")" != "$LLAMA_SHA256" ]]; then
    echo "error: $ARCHIVE isn't the llama.cpp build that was expected (its SHA-256 doesn't match)." >&2
    exit 1
fi
rm -rf "$CACHE/unpacked"
mkdir -p "$CACHE/unpacked"
tar -xzf "$ARCHIVE" -C "$CACHE/unpacked"
LLAMA_FROM="$(dirname "$(find "$CACHE/unpacked" -type f -name llama-server | head -1)")"
LLAMA="$APP/Contents/Resources/llama"
mkdir -p "$LLAMA"
# -L: the archive has each library under three names, two of them links. The one it's loaded by is kept, as a file.
for file in "${LLAMA_FILES[@]}"; do cp -L "$LLAMA_FROM/$file" "$LLAMA/$file"; done
cp "$LLAMA_FROM/LICENSE" "$LLAMA/LICENSE"
# Everything they load from beside themselves has to have come along.
for file in "${LLAMA_FILES[@]}"; do
    for needed in $(otool -L "$LLAMA/$file" | awk 'NR > 1 { print $1 }' | grep '^@rpath/' || true); do
        if [[ ! -f "$LLAMA/${needed#@rpath/}" ]]; then
            echo "error: $file needs ${needed#@rpath/}, which isn't in LLAMA_FILES." >&2
            exit 1
        fi
    done
done

IDENTITY="${OATCAKE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q '"Oatcake Release"'; then IDENTITY="Oatcake Release"; else IDENTITY=-; fi
fi
if [[ "$IDENTITY" == "-" && -n "${OATCAKE_REQUIRE_SIGNING:-}" ]]; then
    echo 'error: OATCAKE_REQUIRE_SIGNING is set, but no "Oatcake Release" signing identity was found.' >&2
    exit 1
fi
KEYCHAIN=()
if [[ -n "${OATCAKE_SIGN_KEYCHAIN:-}" ]]; then KEYCHAIN=(--keychain "$OATCAKE_SIGN_KEYCHAIN"); fi
# The recorder and llama.cpp sit in Resources, where --deep doesn't reach, so they're signed on
# their own first: llama.cpp's files with the same identity as the app, in place of the ad-hoc
# signatures they come with.
#
# Everything is signed for the hardened runtime, so macOS won't let another program on this Mac
# load its own code into Oatcake or the recorder (and so borrow the recorder's microphone
# permission, or Oatcake's Keychain items). The recorder says it uses the microphone, which the
# hardened runtime asks it to, and so does Oatcake, because macOS counts the recorder's use as
# Oatcake's (Resources/Oatcake.entitlements); llama.cpp's server may load the libraries that came with it.
for file in "${LLAMA_FILES[@]}"; do
    if [[ "$file" == llama-server ]]; then
        codesign --force --options runtime --entitlements Resources/Llama.entitlements --sign "$IDENTITY" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} "$LLAMA/$file"
    else
        codesign --force --options runtime --sign "$IDENTITY" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} "$LLAMA/$file"
    fi
done
codesign --force --options runtime --entitlements Resources/OatcakeRecorder.entitlements --sign "$IDENTITY" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} "$RECORDER"
codesign --force --options runtime --entitlements Resources/Oatcake.entitlements --sign "$IDENTITY" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} "$APP"
# macOS remembers the permissions Oatcake is given (the microphone and system audio, which the
# recorder inside it uses) against Oatcake's designated requirement. Left to itself that's "this
# identifier, this certificate", which every earlier release meets too, and before 0.5.0 their
# recorders record for whoever starts them. So the requirement also says 0.5.0 or later: an earlier
# copy of Oatcake doesn't inherit what this one is allowed. The version is in Info.plist, which the
# signature seals. Releases before this one still accept it as an update: it meets theirs.
# Not for an ad-hoc build, whose requirement is its own hash.
if [[ "$IDENTITY" != "-" ]]; then
    REQUIREMENT="$(codesign -d -r - "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
    codesign --force --options runtime --entitlements Resources/Oatcake.entitlements --sign "$IDENTITY" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} \
        -r="designated => $REQUIREMENT and info [CFBundleShortVersionString] >= \"0.5.0\"" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP $VERSION, signed $([[ "$IDENTITY" == "-" ]] && echo ad-hoc || echo "with \"$IDENTITY\"")"
