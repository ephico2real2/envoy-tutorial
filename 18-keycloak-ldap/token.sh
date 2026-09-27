#!/usr/bin/env bash
# token.sh <who> - print an access token from realm corp, whose people live in LDAP:
#
#   sarah.jones, john.doe, alice.cooper   gate members, in app-ocp-rbac-ocp-keycloak-admin (role admin)
#   jane.smith, dana.lee, jeff            gate members
#   lateef.o                              gate member, in app-ocp-rbac-ocp-ns-audit
#   shop.alice                            gate member - module 17's shop reader
#   shop.bob                              gate member, in app-ocp-rbac-ocp-keycloak-admin (role admin)
#   bob.wilson, charlie.brown             in the directory, NOT in the gate: refused
#   master-admin                          realm master, module 16's lab admin - for admin.sh
#
# The passwords are the directory's LAB values, published in the chart
# repository (setup-local-ldap-testing) and measured with ldapwhoami on #7 and
# #8 (shop.alice, shop.bob: ldap-shop-users.ldif): Ldap123! for everyone but
# lateef.o, whose is newuser123. bob.wilson's and
# charlie.brown's are not known; they are asked with Ldap123! and refused
# before any password is checked - Keycloak does not find them.
#
# Every form goes to curl on its standard input, never as an argument: `oc exec`
# sends its arguments in the request URL, and the API server's audit log records
# that URL (measured in module 17) - a password there would be stored.
set -euo pipefail
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
REALMS=https://keycloak.apps-crc.testing/realms

# The CA that signed Keycloak's own certificate, copied into the client pod once.
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
urlencode() { python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))'; }
secret() { $KUBE get secret keycloak-admin -n keycloak -o jsonpath="{.data.$1}" | base64 -d; }
# person <username> <password> - the password grant, through shop-cli.
person() { printf 'grant_type=password&client_id=shop-cli&username=%s&password=' "$1"; printf '%s' "$2" | urlencode; }

case "${1:-}" in
  sarah.jones|john.doe|alice.cooper|jane.smith|dana.lee|jeff|shop.alice|shop.bob|bob.wilson|charlie.brown)
                 person "$1" 'Ldap123!' | ask corp ;;
  lateef.o)      person "$1" newuser123 | ask corp ;;
  master-admin)  { printf 'grant_type=password&client_id=admin-cli&username='; secret username | urlencode
                   printf '&password=';                                        secret password | urlencode; } | ask master ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
