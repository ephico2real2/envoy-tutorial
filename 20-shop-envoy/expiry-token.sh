#!/usr/bin/env bash
# A short-lived, Keycloak-signed token for module 20's expiry probe only.
# Realm corp, public client shop-envoy-cli, password grant as shop.alice.
# The published LAB password goes to the token endpoint on stdin, never argv.
set -euo pipefail
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
[ "$#" -eq 0 ] || { echo "usage: expiry-token.sh (token on stdout)" >&2; exit 2; }
$KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d \
  | $KUBE exec -i -n keycloak client -- sh -c 'cat > /tmp/ca.crt'
printf '%s' 'grant_type=password&client_id=shop-envoy-cli&username=shop.alice&password=Ldap123%21' \
  | $KUBE exec -i -n keycloak client -- curl -sS --fail --max-time 20 \
      --cacert /tmp/ca.crt --data-binary @- \
      https://keycloak.apps-crc.testing/realms/corp/protocol/openid-connect/token \
  | python3 -c '
import json, sys
try:
    token = json.load(sys.stdin)["access_token"]
    if not isinstance(token, str) or token.count(".") != 2:
        raise ValueError()
except (ValueError, KeyError, TypeError):
    sys.exit("expiry-token.sh: no access token; re-import corp (module 18 step 13)")
print(token)'
