#!/usr/bin/env bash
# browser.sh - what a browser does at the shop, done by curl in the client pod, so it
# can be run and checked without one:
#
#   browser.sh sign-in <user>               sign in as <user> on realm corp's login page
#   browser.sh <user> <METHOD> <path> [curl args...]
#                                           call the shop with <user>'s session cookies
#   browser.sh sign-out <user>              /logout: the front Envoy clears the cookies and
#                                           sends the browser to Keycloak's logout
#
# A browser reaches the shop at https://shop.apps-metallb.crc.testing:20443 - CRC writes
# the host into the laptop's /etc/hosts, and forwards the laptop's port 20443 to the
# ingress shard's MetalLB address (README, step 7) - and that is the address realm corp
# sends it back to. The client pod asks for the same address - curl's --connect-to
# sends the connection to the shard's address instead, port 443 - so the router and the
# front Envoy see what a browser sends: the same Host, the same redirect URI, the same
# Secure cookies over HTTPS. The router's certificate is checked against the enterprise
# CA, as Keycloak's is.
#
# Each user's cookies live in the pod, in /tmp/<user>.envoy.jar (the front Envoy's
# session: encrypted tokens, never shown) and /tmp/<user>.keycloak.jar (Keycloak's).
# The password - the directory's published LAB value for the shop's users, Ldap123!
# (module 17's token.sh says where it is published) - reaches the pod on standard
# input, never as an argument.
# The scripts in single quotes run in the pod's shell, which expands their variables.
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")"
KUBE=$(command -v oc >/dev/null 2>&1 && echo oc || echo kubectl)
usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

addr=${ADDR:-$($KUBE get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')}
[ -n "$addr" ] || { echo "browser.sh: the ingress shard's Service router-metallb has no address" >&2; exit 1; }
# in_pod [-i] <script> <args...> - run a shell script in the client pod, with the
# shard's address as $1; -i passes standard input on (only sign-in has any: the
# form). Without -i, a caller's own standard input - a loop's list - is left alone.
in_pod() {
  local stdin=; [ "$1" = -i ] && { stdin=-i; shift; }
  local script=$1; shift
  $KUBE exec $stdin -n envoy-20 client -- sh -c "$script" sh "$addr" "$@"
}

case "${1:-}" in
  sign-in)
    user=${2:-}; [[ $user =~ ^[a-z][a-z.]*$ ]] || usage
    # Keycloak's certificate and the shard's are signed by the enterprise CA (module 16,
    # step 4; the shard's README).
    $KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d \
      | $KUBE exec -i -n envoy-20 client -- sh -c 'cat > /tmp/ca.crt'
    # The login form's two fields, URL-encoded here and sent on standard input.
    { printf 'username=%s&password=' "$user"
      printf '%s' 'Ldap123!' | python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))'
      printf '&credentialId=\n'; } \
    | in_pod -i '
set -e
addr=$1 user=$2 fe=/tmp/$2.envoy.jar kc=/tmp/$2.keycloak.jar
IFS= read -r form
rm -f "$fe" "$kc"
at_shop() { curl -s -c "$fe" -b "$fe" --cacert /tmp/ca.crt --connect-to "shop.apps-metallb.crc.testing:20443:$addr:443" "$@"; }
# 1. The shop, with no session: the front Envoy answers with a redirect to corp.
login=$(at_shop -o /dev/null -w "%{http_code} %{redirect_url}" https://shop.apps-metallb.crc.testing:20443/)
echo "1. GET https://shop.apps-metallb.crc.testing:20443/ -> ${login%% *}, to ${login#* }" | sed "s/?.*/?.../"
# 2. The login page, and the address its form posts to.
page=$(curl -s -c "$kc" -b "$kc" --cacert /tmp/ca.crt "${login#* }")
action=$(printf "%s" "$page" | sed -n "s/.*id=\"kc-form-login\"[^>]* action=\"\([^\"]*\)\".*/\1/p" | sed "s/&amp;/\&/g")
[ -n "$action" ] || { echo "2. no login form on the page"; exit 1; }
echo "2. corp login page: a form posting to ${action%%\?*}"
# 3. The person signs in. Keycloak answers with a redirect to the redirect URI, with a code...
back=$(printf "%s" "$form" | curl -s -c "$kc" -b "$kc" --cacert /tmp/ca.crt --data-binary @- \
         -o /tmp/$user.page -w "%{http_code} %{redirect_url}" "$action")
case "$back" in
  "302 https://shop.apps-metallb.crc.testing:20443/oauth2/callback?"*) ;;
  *) msg=$(grep -A 1 kc-feedback-text /tmp/$user.page | sed -n "2s/^[[:space:]]*//p")
     echo "3. sign-in as $user refused: ${back%% *}, ${msg:-no redirect}"; exit 1 ;;
esac
echo "3. signed in as $user -> ${back%% *}, back to ${back#* }" | sed "s/?.*/?code=.../"
# 4. ...which the browser brings to the front Envoy. It swaps the code for tokens, keeps
#    them in cookies, and sends the browser on to the page it first asked for.
done=$(at_shop -o /dev/null -w "%{http_code} %{redirect_url}" "${back#* }")
echo "4. the front Envoy swapped the code for tokens -> ${done%% *}, to ${done#* }"
echo "   its session cookies: $(grep -v "^#[^H]" "$fe" | awk -F "\t" "NF > 5 && \$3 == \"/\" { print \$6 }" | sort -u | tr "\n" " ")"
' "$user" ;;
  sign-out)
    user=${2:-}; [[ $user =~ ^[a-z][a-z.]*$ ]] || usage
    in_pod '
addr=$1 fe=/tmp/$2.envoy.jar kc=/tmp/$2.keycloak.jar
# 1. The front Envoy clears its cookies and sends the browser to the corp logout...
out=$(curl -s -c "$fe" -b "$fe" --cacert /tmp/ca.crt --connect-to "shop.apps-metallb.crc.testing:20443:$addr:443" -o /dev/null -w "%{http_code} %{redirect_url}" https://shop.apps-metallb.crc.testing:20443/logout)
echo "1. GET /logout -> ${out%% *}, to ${out#* }" | sed "s/id_token_hint=[^&]*/id_token_hint=.../"
echo "   the front Envoy session cookies left: $(awk -F "\t" "NF > 5 && \$3 == \"/\"" "$fe" | wc -l)"
# 2. ...which ends the Keycloak session and sends it back to the shop.
kc_out=$(curl -s -c "$kc" -b "$kc" --cacert /tmp/ca.crt -o /dev/null -w "%{http_code} %{redirect_url}" "${out#* }")
echo "2. corp logout -> ${kc_out%% *}, to ${kc_out#* }"
' "$user" ;;
  ""|-*) usage ;;
  *)
    user=$1 method=${2:-} path=${3:-}
    [[ $user =~ ^[a-z][a-z.]*$ && $method =~ ^(GET|POST|PATCH|DELETE)$ && $path == /* ]] || usage
    shift 3
    in_pod '
addr=$1 fe=/tmp/$2.envoy.jar method=$3 path=$4; shift 4
[ -s "$fe" ] || { echo "browser.sh: $2 has not signed in - browser.sh sign-in $2" >&2; exit 1; }
curl -s -c "$fe" -b "$fe" --cacert /tmp/ca.crt --connect-to "shop.apps-metallb.crc.testing:20443:$addr:443" -X "$method" "$@" "https://shop.apps-metallb.crc.testing:20443$path"
' "$user" "$method" "$path" "$@" ;;
esac
