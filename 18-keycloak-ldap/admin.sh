#!/usr/bin/env bash
# admin.sh - realm corp through Keycloak's admin REST API, as module 16's lab admin.
#
#   admin.sh GET <path>                      print the JSON at an admin path, e.g.
#                                            /admin/realms/corp/users/count
#   admin.sh DELETE <path>                   delete what the path names - only for the
#                                            README's "Changing corp" and run.sh clean,
#                                            which remove the realm corp itself
#   admin.sh test-ldap <action> [url]        the LDAP provider's own checks, as the admin
#                                            console's "Test connection" (action connection)
#                                            and "Test authentication" (action authentication)
#                                            buttons run them - with the bind password
#                                            Keycloak stored, which never leaves Keycloak.
#                                            [url] dials another address with the same settings.
#
# GET and test-ldap change nothing in Keycloak. The admin token goes to the client
# pod on stdin, never as an `oc exec` argument (token.sh says why).
set -euo pipefail
cd "$(dirname "$0")"
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
KC=https://keycloak.apps-crc.testing

# call <METHOD> <path> - the admin token, then any request body, on stdin; prints
# the body, then "HTTP <status>" on a line of its own.
call() {
  { ./token.sh master-admin; [ "$1" = POST ] && cat; true; } \
    | $KUBE exec -i -n keycloak client -- sh -c \
        'read -r t; curl -s -w "\nHTTP %{http_code}\n" --cacert /tmp/ca.crt -X "$1" -H "Authorization: Bearer $t" -H "Content-Type: application/json" $([ "$1" = POST ] && echo --data-binary @-) "$2"' \
        sh "$1" "$KC$2"
}

case "${1:-}" in
  GET)
    out=$(call GET "$2")
    [ "$(tail -n 1 <<<"$out")" = "HTTP 200" ] || { echo "$out" >&2; exit 1; }
    sed '$d' <<<"$out" ;;
  DELETE)
    out=$(call DELETE "$2")
    [ "$(tail -n 1 <<<"$out")" = "HTTP 204" ] || { echo "$out" >&2; exit 1; }
    echo "deleted $2" ;;
  test-ldap)
    case "${2:-}" in connection) action=testConnection ;; authentication) action=testAuthentication ;;
      *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
    # The provider's id and settings, as the realm import stored them.
    provider=$(call GET '/admin/realms/corp/components?type=org.keycloak.storage.UserStorageProvider&name=ldap' | sed '$d')
    python3 - "$action" "${3:-}" "$provider" <<'PY' | call POST /admin/realms/corp/testLDAPConnection | sed '/^$/d'
import json, sys
action, url, provider = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])[0]
c = {k: v[0] for k, v in provider["config"].items()}
print(json.dumps({
    "action": action,
    "componentId": provider["id"],  # with the id, Keycloak uses the stored bind password...
    "bindCredential": "**********",  # ...for this, the mask it shows in place of the value
    "connectionUrl": url or c["connectionUrl"],
    "bindDn": c["bindDn"], "authType": c["authType"],
    "useTruststoreSpi": c["useTruststoreSpi"], "startTls": "false", "connectionTimeout": "",
}))
PY
    ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
