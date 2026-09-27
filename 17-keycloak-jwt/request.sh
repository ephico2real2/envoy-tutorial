#!/usr/bin/env bash
# request.sh <path> [curl args...] - call Gateway eg in envoy-17 at <path>, from the client
# pod, with the bearer token read from standard input:
#
#   ./token.sh alice | ./request.sh /api -w '  -> %{http_code}\n'
#
# The token is never an argument. `oc exec` sends its arguments in the request URL, and the
# API server's audit log records that URL (token.sh, top); `ps` shows every process's
# arguments. So the header goes to curl as a config file on its standard input (curl -K -):
# printf is a shell builtin, and the token travels in the exec stream, not in the URL.
set -euo pipefail
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)

case "${1:-}" in
  /*) ;;
  *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
path=$1; shift

token=
IFS= read -r token || true
[ -n "$token" ] || { echo "request.sh: no token on standard input" >&2; exit 1; }
# A JWT is three base64url parts: nothing that could end the quoted config value below.
case "$token" in
  *[!A-Za-z0-9._-]*) echo "request.sh: that is not a token (only A-Z a-z 0-9 . _ - allowed)" >&2; exit 1 ;;
esac

# run.sh passes the address it already looked up; a reader's command looks it up here.
addr=${ADDR:-$($KUBE get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')}
[ -n "$addr" ] || { echo "request.sh: Gateway eg in envoy-17 has no address" >&2; exit 1; }

printf 'header = "authorization: Bearer %s"\n' "$token" \
  | $KUBE exec -i -n envoy-17 client -- curl -s -K - "$@" "http://$addr$path"
