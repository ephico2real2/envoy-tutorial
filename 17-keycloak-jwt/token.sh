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
set -euo pipefail
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
REALMS=https://keycloak.apps-crc.testing/realms

# The CA file the requests trust, copied in once.
if ! $KUBE exec -n keycloak client -- test -s /tmp/ca.crt 2>/dev/null; then
  $KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d \
    | $KUBE exec -i -n keycloak client -- sh -c 'cat > /tmp/ca.crt'
fi

ask() {  # ask <realm> <curl -d args...>
  local realm=$1; shift
  $KUBE exec -n keycloak client -- curl -s --cacert /tmp/ca.crt "$@" \
    "$REALMS/$realm/protocol/openid-connect/token" \
    | python3 -c 'import json, sys; t = json.load(sys.stdin); print(t["access_token"]) if "access_token" in t else sys.exit("no token: %s" % t)'
}
secret() { $KUBE get secret keycloak-initial-admin -n keycloak -o jsonpath="{.data.$1}" | base64 -d; }

case "${1:-}" in
  alice|bob)       ask tutorial -d grant_type=password -d client_id=shop-cli -d username="$1" -d password="$1-lab-password" ;;
  orders-service)  ask tutorial -d grant_type=client_credentials -d client_id=orders-service -d client_secret=orders-service-lab-secret ;;
  alice-admin-cli) ask tutorial -d grant_type=password -d client_id=admin-cli -d username=alice -d password=alice-lab-password ;;
  master-admin)    ask master -d grant_type=password -d client_id=admin-cli -d username="$(secret username)" -d password="$(secret password)" ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
