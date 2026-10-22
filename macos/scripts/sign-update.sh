#!/bin/bash
# Signs a DMG for the in-app updater: writes <dmg>.sig, a base64 Ed25519 signature,
# which goes on the release next to the DMG. The app checks it with the public key in
# AppUpdater.swift. The private key never goes in the repository; it is read from
# LIMITA_SIGNING_KEY, by default ~/.limita-signing/macos-ed25519.key (base64, raw).
set -euo pipefail

DMG="${1:?usage: sign-update.sh Limita-X.Y.Z.dmg}"
KEY="${LIMITA_SIGNING_KEY:-$HOME/.limita-signing/macos-ed25519.key}"
[ -f "$KEY" ] || { echo "No signing key at $KEY" >&2; exit 1; }

SCRIPT="$(mktemp -t limita-sign).swift"
trap 'rm -f "$SCRIPT"' EXIT
cat > "$SCRIPT" <<'SWIFT'
import CryptoKit
import Foundation
let args = CommandLine.arguments
let keyText = try String(contentsOfFile: args[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: keyText)!)
let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let signature = try key.signature(for: data)
guard key.publicKey.isValidSignature(signature, for: data) else { exit(1) }
print(signature.base64EncodedString())
SWIFT
swift "$SCRIPT" "$KEY" "$DMG" > "$DMG.sig"
echo "$DMG.sig"
