#!/usr/bin/env bash
# request.sh <METHOD> <path> [curl args...] - call the shop through Gateway eg in
# envoy-19, from the client pod, with the bearer token read from standard input:
#
#   ../17-keycloak-jwt/token.sh shop.alice | ./request.sh GET /v1/items -w '  -> %{http_code}\n'
#
# The token is never an argument - module 17's request.sh says why: `oc exec` sends its
# arguments in the request URL, which the API server's audit log records, and `ps` shows
# every process's arguments. The header goes to curl as a config file on its standard
# input (curl -K -); printf is a shell builtin, and the token travels in the exec stream.
# A request body, if any, is an argument (-d '{...}'): it holds no credential.
set -euo pipefail
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)

case "${1:-}/${2:-}" in
  GET//* | POST//* | PATCH//* | DELETE//*) ;;
  *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
method=$1 path=$2; shift 2

token=
IFS= read -r token || true
[ -n "$token" ] || { echo "request.sh: no token on standard input" >&2; exit 1; }
# A compact JWS: three non-empty base64url parts - and nothing that could end the
# quoted config value below.
if [[ ! $token =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
  echo "request.sh: not a JWT (expected three non-empty base64url parts)" >&2
  exit 1
fi

# run.sh passes the address it already looked up; a reader's command looks it up here.
addr=${ADDR:-$($KUBE get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}')}
[ -n "$addr" ] || { echo "request.sh: Gateway eg in envoy-19 has no address" >&2; exit 1; }

printf 'header = "authorization: Bearer %s"\n' "$token" \
  | $KUBE exec -i -n envoy-19 client -- curl -s -K - -X "$method" "$@" "http://$addr$path"
