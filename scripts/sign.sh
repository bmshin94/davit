#!/bin/bash
# Signs Davit.app, including the embedded Sparkle framework.
#
# Split out of bundle.sh so the release pipeline can sign a bundle it did not
# build: the build job runs without any credentials and uploads an unsigned
# bundle, and only the release job holds the certificate. That separation is the
# point -- `swift build` compiles the whole SPM dependency tree and runs build
# plugins, and none of that should ever share an environment with a signing key.
#
# Usage: scripts/sign.sh [path/to/Davit.app]
#   CODESIGN_IDENTITY unset -> ad-hoc signing (development only)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-$PWD/dist/Davit.app}"
[ -d "$APP" ] || { echo "No bundle at $APP" >&2; exit 1; }

# The certificate rotated on 2026-09-11 after it was exposed to 31 release runs
# through a workflow-level env block. Two Developer ID certificates share an
# identical common name, so the name proves nothing about which key signs --
# pin the fingerprint. On rotation, update this and the workflow's copy.
EXPECTED_CERT_SHA1="89AFE2B56FFCB7344A7600B5E38E97C68A544591"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  [ "$CODESIGN_IDENTITY" = "$EXPECTED_CERT_SHA1" ] || {
    echo "Refusing to sign: expected the pinned certificate $EXPECTED_CERT_SHA1," >&2
    echo "got $CODESIGN_IDENTITY. Export the current certificate, or update the pin." >&2
    exit 1
  }
  echo "==> Codesigning with Developer ID (hardened runtime)"
  SIGN=(codesign --force --options runtime --timestamp -s "$CODESIGN_IDENTITY")
else
  echo "==> Codesigning (ad-hoc; not suitable for publication)"
  SIGN=(codesign --force -s -)
fi

# Nested code signs inside-out: each XPC service and helper first, then the
# framework, then the app. `--deep` is documented as unsuitable for signing and
# silently produces bundles that fail notarization.
SPARKLE_V="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE_V" ]; then
  "${SIGN[@]}" "$SPARKLE_V/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$SPARKLE_V/XPCServices/Installer.xpc"
  "${SIGN[@]}" "$SPARKLE_V/Autoupdate"
  "${SIGN[@]}" "$SPARKLE_V/Updater.app"
  "${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
fi
"${SIGN[@]}" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
