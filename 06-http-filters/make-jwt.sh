#!/usr/bin/env bash
# Mint a JSON Web Token that Envoy's jwt_authn filter in this module accepts.
#
#   ./make-jwt.sh alice            a valid token for user alice, good for an hour
#   ./make-jwt.sh alice forged     the same token signed with the WRONG key
#
# A JWT is three base64url parts joined by dots: header.payload.signature. The
# signature here is an HMAC-SHA256 of the first two parts with a shared secret -
# the one whose base64url form sits in the config's local_jwks. It is a
# TUTORIAL-ONLY secret; real identity providers sign with a private key and
# publish only the public half.
set -euo pipefail
USER_NAME=${1:?usage: ./make-jwt.sh <user> [forged]}
SECRET='tutorial-only-secret-do-not-reuse'
[ "${2:-}" = forged ] && SECRET='not-the-key-envoy-has'

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

EXP=$(( $(date +%s) + 3600 ))
HEADER=$(printf '{"alg":"HS256","typ":"JWT","kid":"tutorial"}' | b64url)
PAYLOAD=$(printf '{"iss":"envoy-tutorial","sub":"%s","exp":%d}' "$USER_NAME" "$EXP" | b64url)
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64url)
printf '%s.%s.%s\n' "$HEADER" "$PAYLOAD" "$SIG"
