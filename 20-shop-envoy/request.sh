#!/usr/bin/env bash
# request.sh <METHOD> <path> [curl args...] - call the shop through Route shop in
# envoy-20, from the client pod, with the bearer token read from standard input:
#
#   ../17-keycloak-jwt/token.sh shop.alice | ./request.sh GET /v1/items -w '  -> %{http_code}\n'
#
# The token is never an argument - module 17's request.sh says why: `oc exec` sends its
# arguments in the request URL, which the API server's audit log records, and `ps` shows
# every process's arguments. The header goes to curl as a config file on its standard
# input (curl -K -); printf is a shell builtin, and the token travels in the exec stream.
# A request body, if any, is an argument (-d '{...}'): it holds no credential.
#
# It asks for https://shop.apps-metallb.crc.testing:20443, as a browser on the laptop
# does, and sends the connection to the ingress shard's MetalLB address instead (curl
# --connect-to): the router sees the same host, and its certificate is checked against
# the enterprise CA (/tmp/ca.crt in the pod, which browser.sh and run.sh copy there).
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
addr=${ADDR:-$($KUBE get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')}
[ -n "$addr" ] || { echo "request.sh: the ingress shard's Service router-metallb has no address" >&2; exit 1; }
# The CA the shard's certificate chains to, copied in once.
if ! $KUBE exec -n envoy-20 client -- test -s /tmp/ca.crt 2>/dev/null; then
  $KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d \
    | $KUBE exec -i -n envoy-20 client -- sh -c 'cat > /tmp/ca.crt'
fi

printf 'header = "authorization: Bearer %s"\n' "$token" \
  | $KUBE exec -i -n envoy-20 client -- curl -s -K - --cacert /tmp/ca.crt \
      --connect-to "shop.apps-metallb.crc.testing:20443:$addr:443" \
      -X "$method" "$@" "https://shop.apps-metallb.crc.testing:20443$path"
