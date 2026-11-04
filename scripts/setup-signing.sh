#!/usr/bin/env bash
# One-time setup: a self-signed code-signing identity for MiniTab, stored in its own
# password-protected keychain, so rebuilds keep their macOS permissions.
#
# Why a separate keychain: with a stable identity, macOS grants MiniTab's permissions to
# *anything* signed with this key under MiniTab's bundle ID. Keeping the key in a keychain
# that auto-locks, and that asks before every use, means nothing can use it silently.
set -euo pipefail
cd "$(dirname "$0")/.."

KEYCHAIN="$HOME/Library/Keychains/minitab-signing.keychain-db"
NAME="MiniTab Local Signing"

if [[ -f .signing.env ]]; then
    echo "Already set up (.signing.env exists). Delete it and $KEYCHAIN to start over."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Choose a password for the new signing keychain (not your login password):"
read -rs KC_PASS
echo
[[ -n "$KC_PASS" ]] || { echo "Empty password, aborting."; exit 1; }

security create-keychain -p "$KC_PASS" "$KEYCHAIN"
# Lock after 5 minutes of inactivity and on sleep.
security set-keychain-settings -l -u -t 300 "$KEYCHAIN"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12_PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -passout pass:"$P12_PASS" -out "$TMP/identity.p12"

security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
# No -T / -A flags on purpose: no app gets silent access to the key; every signing asks.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -f pkcs12 >/dev/null
# Trust the certificate for code signing only (your user's trust settings). Without this,
# macOS treats the signature as untrusted and doesn't keep permissions across builds.
# macOS asks for your password here.
echo "Marking the certificate as trusted for code signing (macOS will ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
security lock-keychain "$KEYCHAIN"

HASH=$(/usr/bin/openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
cat > .signing.env <<ENV
# Created by scripts/setup-signing.sh. Local only (git-ignored).
SIGN_IDENTITY=$HASH
SIGN_KEYCHAIN=$KEYCHAIN
ENV

echo
echo "Done. Next: ./build.sh --install"
echo "- macOS will ask for this keychain's password, then whether codesign may use the key:"
echo "  click \"Allow\", never \"Always Allow\"."
echo "- Enable MiniTab's permissions one last time. From now on, rebuilds keep them."
echo
echo "To undo: security delete-keychain \"$KEYCHAIN\" && rm .signing.env"
echo "(and remove \"$NAME\" from Keychain Access > Certificate trust settings if listed)"
