#!/usr/bin/env bash
# make-dev-signing-cert.sh — create a STABLE self-signed code-signing
# identity ("AXIØM TrustMesh Project") in the login keychain.
#
# WHY THIS EXISTS
#
# The macOS Keychain gates access to the wallet's at-rest data key
# (WalletVault's AXMK device key) on the app's CODE SIGNATURE. Ad-hoc
# signing (`codesign --sign -`) produces a *different* signature on every
# rebuild, so the Keychain treats each build as a brand-new app and
# re-prompts "AxiomWallet wants to use your confidential information…" —
# and "Always Allow" never sticks, because the identity it would pin to
# changes next build.
#
# A STABLE signing identity fixes that at the root: sign every build with
# the same self-signed cert, click "Always Allow" once, and it persists
# across all future rebuilds. This keeps the Keychain security model
# (device key, Touch ID / Face ID unlock) AND kills the per-launch prompt.
#
# This is the local-dev answer. A shipped release should use a real Apple
# Developer ID (also stable, plus notarizable). Either way the principle
# is the same: never sign the app ad-hoc if you want the Keychain to
# remember the grant.
#
# Idempotent — re-running is a no-op if the identity already exists.
# After running this once, build-dev-app.sh / release-dmg.sh pick the
# identity up automatically (they fall back to ad-hoc only if it's absent).

set -euo pipefail

IDENTITY="${AXIOM_CODESIGN_IDENTITY:-AXIØM TrustMesh Project}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "✓ Code-signing identity '$IDENTITY' already exists — nothing to do."
    echo "  Rebuild with build-dev-app.sh; it will sign with this identity."
    exit 0
fi

echo "==> Creating self-signed code-signing identity '$IDENTITY'…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Self-signed cert + RSA key carrying the codeSigning extended key usage.
# 10-year validity so it doesn't silently expire mid-project. `-utf8` so a
# non-ASCII CN (e.g. the Ø in "AXIØM") is encoded as a UTF8String, not mangled.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -utf8 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/$IDENTITY.p12" -name "$IDENTITY" -passout pass:axiomdev >/dev/null 2>&1

# Import cert+key into the login keychain. `-A` lets local tools (codesign)
# use the private key without a per-sign authorisation prompt — appropriate
# for a throwaway local signing cert (it is not a sensitive secret; its only
# job is to give builds a constant identity).
security import "$TMP/$IDENTITY.p12" -k "$KEYCHAIN" -P axiomdev -A >/dev/null

# NOTE on the key's display name: LibreSSL's `pkcs12 -name` labels only the CERT
# bag, so the imported private key shows in Keychain Access as the generic
# "Imported Private Key". That is purely cosmetic — codesign finds the key via
# the cert, and the CERT is named "$IDENTITY". We deliberately do NOT script a
# rename: relabeling a key requires keychain authorization, which pops a scary
# "<tool> wants to access key … enter your login password" prompt. If the
# generic key name bothers you, rename it once by hand in Keychain Access
# (login keychain → Keys → the key under "$IDENTITY" → rename). It changes
# nothing functional.

echo "✓ Created code-signing identity '$IDENTITY'."
echo
echo "Next:"
echo "  1. Rebuild:   bash build-dev-app.sh"
echo "  2. On the FIRST launch of the newly-signed build, the Keychain will"
echo "     prompt ONCE for the existing wallet key (the old build's grant was"
echo "     tied to the ad-hoc identity). Click \"Always Allow\"."
echo "  3. Every rebuild after that is signed with this same identity, so the"
echo "     grant sticks — no more prompts, Touch ID / Face ID intact."
