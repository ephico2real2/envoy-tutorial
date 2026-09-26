#!/usr/bin/env bash
# token.sh <who> - print an access token from module 16's Keycloak, for:
#
#   alice            realm tutorial, client shop-cli, password grant   (role reader)
#   bob              realm tutorial, client shop-cli, password grant   (roles reader, admin)
#   orders-service   realm tutorial, client credentials                (a service)
#   alice-admin-cli  realm tutorial, Keycloak's built-in admin-cli client - no shop-api audience
#   master-admin     realm master, the operator's temporary admin      - another issuer
#
# It asks from the client pod in the keycloak namespace, which trusts only the
# enterprise CA (module 16, step 6). The passwords and the secret are module
# 16's LAB values; master-admin's is read from its Secret and never printed.
#
# Every form goes to curl on its standard input, never as an argument: `oc exec`
# sends its arguments in the request URL, and the API server's audit log records
# that URL verbatim (measured) - a password passed as `-d password=...` would be
# stored there, and shown by `ps` while it runs.
set -euo pipefail
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
REALMS=https://keycloak.apps-crc.testing/realms

# The CA file the requests trust, copied in once.
if ! $KUBE exec -n keycloak client -- test -s /tmp/ca.crt 2>/dev/null; then
  $KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d \
    | $KUBE exec -i -n keycloak client -- sh -c 'cat > /tmp/ca.crt'
fi

# ask <realm> - POST the form read from stdin to the realm's token endpoint; print the access token.
ask() {
  $KUBE exec -i -n keycloak client -- curl -s --cacert /tmp/ca.crt --data-binary @- \
    "$REALMS/$1/protocol/openid-connect/token" \
    | python3 -c 'import json, sys; t = json.load(sys.stdin); print(t["access_token"]) if "access_token" in t else sys.exit("no token: %s" % t)'
}
# urlencode - stdin to stdout, encoded for a form value (a generated password may hold & + = %).
urlencode() { python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))'; }
secret() { $KUBE get secret keycloak-initial-admin -n keycloak -o jsonpath="{.data.$1}" | base64 -d; }

case "${1:-}" in
  alice|bob)       printf 'grant_type=password&client_id=shop-cli&username=%s&password=%s-lab-password' "$1" "$1" | ask tutorial ;;
  orders-service)  printf 'grant_type=client_credentials&client_id=orders-service&client_secret=orders-service-lab-secret' | ask tutorial ;;
  alice-admin-cli) printf 'grant_type=password&client_id=admin-cli&username=alice&password=alice-lab-password' | ask tutorial ;;
  master-admin)    { printf 'grant_type=password&client_id=admin-cli&username='; secret username | urlencode
                     printf '&password=';                                        secret password | urlencode; } | ask master ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
