#!/usr/bin/env bash
# browser.sh - what a browser does at the shop, done by curl in the client pod, so it
# can be run and checked without one:
#
#   browser.sh sign-in <user>               sign in as <user> on realm corp's login page
#   browser.sh <user> <METHOD> <path> [curl args...]
#                                           call the shop with <user>'s session cookies
#   browser.sh sign-out <user>              /logout: the Gateway clears the cookies and
#                                           sends the browser to Keycloak's logout
#
# A browser reaches the Gateway at http://localhost:19080 - CRC forwards the laptop's
# port 19080 to the Gateway's MetalLB address (README, step 7) - and that is the
# address realm corp sends it back to. The client pod
# asks for the same address - curl's --connect-to sends the connection to the Gateway's
# MetalLB address instead - so the Gateway sees what a browser sends: the same Host,
# the same redirect URI, and cookies kept for "localhost", where curl, like a browser,
# accepts the Secure cookies the Gateway sets over plain HTTP.
#
# Each user's cookies live in the pod, in /tmp/<user>.gateway.jar (the Gateway's
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

addr=${ADDR:-$($KUBE get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}')}
[ -n "$addr" ] || { echo "browser.sh: Gateway eg in envoy-19 has no address" >&2; exit 1; }
# in_pod [-i] <script> <args...> - run a shell script in the client pod, with the
# Gateway's address as $1; -i passes standard input on (only sign-in has any: the
# form). Without -i, a caller's own standard input - a loop's list - is left alone.
in_pod() {
  local stdin=; [ "$1" = -i ] && { stdin=-i; shift; }
  local script=$1; shift
  $KUBE exec $stdin -n envoy-19 client -- sh -c "$script" sh "$addr" "$@"
}

case "${1:-}" in
  sign-in)
    user=${2:-}; [[ $user =~ ^[a-z][a-z.]*$ ]] || usage
    # Keycloak's certificate is signed by the enterprise CA (module 16, step 4).
    $KUBE get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d \
      | $KUBE exec -i -n envoy-19 client -- sh -c 'cat > /tmp/ca.crt'
    # The login form's two fields, URL-encoded here and sent on standard input.
    { printf 'username=%s&password=' "$user"
      printf '%s' 'Ldap123!' | python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))'
      printf '&credentialId=\n'; } \
    | in_pod -i '
set -e
addr=$1 user=$2 gw=/tmp/$2.gateway.jar kc=/tmp/$2.keycloak.jar
IFS= read -r form
rm -f "$gw" "$kc"
at_gateway() { curl -s -c "$gw" -b "$gw" --connect-to "localhost:19080:$addr:80" "$@"; }
# 1. The shop, with no session: the Gateway answers with a redirect to corp.
login=$(at_gateway -o /dev/null -w "%{http_code} %{redirect_url}" http://localhost:19080/)
echo "1. GET http://localhost:19080/ -> ${login%% *}, to ${login#* }" | sed "s/?.*/?.../"
# 2. The login page, and the address its form posts to.
page=$(curl -s -c "$kc" -b "$kc" --cacert /tmp/ca.crt "${login#* }")
action=$(printf "%s" "$page" | sed -n "s/.*id=\"kc-form-login\"[^>]* action=\"\([^\"]*\)\".*/\1/p" | sed "s/&amp;/\&/g")
[ -n "$action" ] || { echo "2. no login form on the page"; exit 1; }
echo "2. corp login page: a form posting to ${action%%\?*}"
# 3. The person signs in. Keycloak answers with a redirect to the redirect URI, with a code...
back=$(printf "%s" "$form" | curl -s -c "$kc" -b "$kc" --cacert /tmp/ca.crt --data-binary @- \
         -o /tmp/$user.page -w "%{http_code} %{redirect_url}" "$action")
case "$back" in
  "302 http://localhost:19080/oauth2/callback?"*) ;;
  *) msg=$(grep -A 1 kc-feedback-text /tmp/$user.page | sed -n "2s/^[[:space:]]*//p")
     echo "3. sign-in as $user refused: ${back%% *}, ${msg:-no redirect}"; exit 1 ;;
esac
echo "3. signed in as $user -> ${back%% *}, back to ${back#* }" | sed "s/?.*/?code=.../"
# 4. ...which the browser brings to the Gateway. It swaps the code for tokens, keeps them
#    in cookies, and sends the browser on to the page it first asked for.
done=$(at_gateway -o /dev/null -w "%{http_code} %{redirect_url}" "${back#* }")
echo "4. the Gateway swapped the code for tokens -> ${done%% *}, to ${done#* }"
echo "   its session cookies: $(grep -v "^#[^H]" "$gw" | awk -F "\t" "NF > 5 && \$3 == \"/\" { print \$6 }" | sed "s/-[0-9a-f]*$//" | sort -u | tr "\n" " ")"
' "$user" ;;
  sign-out)
    user=${2:-}; [[ $user =~ ^[a-z][a-z.]*$ ]] || usage
    in_pod '
addr=$1 gw=/tmp/$2.gateway.jar kc=/tmp/$2.keycloak.jar
# 1. The Gateway clears its cookies and sends the browser to the corp logout...
out=$(curl -s -c "$gw" -b "$gw" --connect-to "localhost:19080:$addr:80" -o /dev/null -w "%{http_code} %{redirect_url}" http://localhost:19080/logout)
echo "1. GET /logout -> ${out%% *}, to ${out#* }" | sed "s/id_token_hint=[^&]*/id_token_hint=.../"
echo "   the Gateway session cookies left: $(awk -F "\t" "NF > 5 && \$3 == \"/\"" "$gw" | wc -l)"
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
addr=$1 gw=/tmp/$2.gateway.jar method=$3 path=$4; shift 4
[ -s "$gw" ] || { echo "browser.sh: $2 has not signed in - browser.sh sign-in $2" >&2; exit 1; }
curl -s -c "$gw" -b "$gw" --connect-to "localhost:19080:$addr:80" -X "$method" "$@" "http://localhost:19080$path"
' "$user" "$method" "$path" "$@" ;;
esac
