#!/usr/bin/env bash
# The MetalLB ingress shard.  ./run.sh deploy | verify | clean | pause | resume
cd "$(dirname "$0")"
NS=ingress-shard
. ../../_shared/lib.sh
. ../../_shared/argocd.sh

APP=ingress-shard
ADDR=192.168.127.130                 # the only address in ingress-shard-pool (manifests/10-pool.yaml)
HOST=canary.apps-metallb.crc.testing # the canary Route (manifests/40-canary.yaml)
LOCAL=127.0.0.1:20443                # the laptop's way in; CRC's own :443 is the default router's

# The laptop does not route to the CRC network (192.168.127.0/24); CRC's network
# proxy, gvproxy, carries a laptop port there. Its forwarder API is used raw here
# until ../../_shared/crc-forward.sh (#15) is merged; then this block becomes
# calls to that helper. On bare metal the address is routable: no forward.
SOCK=$HOME/.crc/sockets/crc-http.sock
FWD=http://crc/network/services/forwarder

# forward_target - where $LOCAL forwards now ("<ip>:<port>"), or nothing. Fatal
# when gvproxy cannot be asked.
forward_target() {
  local all
  all=$(curl -sf --unix-socket "$SOCK" "$FWD/all") \
    || { bad "cannot read CRC's forwards from $SOCK"; exit 1; }
  python3 -c 'import json, sys
print("".join(f["remote"] for f in json.load(sys.stdin) if f["local"] == sys.argv[1]))' "$LOCAL" <<<"$all"
}
# forward_post <expose|unexpose> <json> - one request to gvproxy; fatal unless it answers 200.
forward_post() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" -X POST -d "$2" "$FWD/$1") || code=000
  [ "$code" = 200 ] || { bad "gvproxy refused $1 $2 (HTTP $code) - is port ${LOCAL##*:} taken? lsof -nP -iTCP:${LOCAL##*:} -sTCP:LISTEN"; exit 1; }
}
forward_ensure() {
  local now
  [ -S "$SOCK" ] || { echo "  note: no CRC socket at $SOCK - not CRC: reach $ADDR:443 directly"; return 0; }
  now=$(forward_target)
  if [ "$now" = "$ADDR:443" ]; then ok "$LOCAL already forwards to $ADDR:443"; return 0; fi
  [ -z "$now" ] || { bad "$LOCAL already forwards to $now, not $ADDR:443 - left alone"; exit 1; }
  forward_post expose "{\"local\":\"$LOCAL\",\"remote\":\"$ADDR:443\",\"protocol\":\"tcp\"}"
  [ "$(forward_target)" = "$ADDR:443" ] || { bad "gvproxy accepted $LOCAL -> $ADDR:443 but does not list it"; exit 1; }
  ok "$LOCAL forwards to $ADDR:443"
}
forward_remove() {
  [ -S "$SOCK" ] || return 0
  [ -n "$(forward_target)" ] || return 0
  forward_post unexpose "{\"local\":\"$LOCAL\",\"protocol\":\"tcp\"}"
  [ -z "$(forward_target)" ] || { bad "gvproxy still lists $LOCAL"; exit 1; }
  ok "forward $LOCAL removed"
}

# The default router admits every Route unless it has a selector, so without one
# a shard Route is served twice: by the shard on its MetalLB address, and by the
# default router on CRC's :443. This selector - the operator's choice - makes the
# default router ignore Routes labelled ingress-shard; none of the 21 Routes had
# the label when it was added. It is set here, not by Argo CD: an Application
# that owned the default IngressController could prune it.
DEFAULT_SELECTOR='{"matchExpressions":[{"key":"ingress-shard","operator":"DoesNotExist"}]}'

# default_selector - the default IngressController's routeSelector as canonical
# JSON ("" when it has none). Fatal when it cannot be read.
default_selector() {
  local raw
  raw=$($KUBE get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.routeSelector}') \
    || { bad "cannot read IngressController default" >&2; exit 1; }
  [ -n "$raw" ] || return 0
  python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$raw"
}
# default_rollout <what> - after a change to the default IngressController: wait
# until the ingress operator has rewritten router-default (its generation moves
# past $1) and the new pod is serving. With one replica on HostNetwork the old pod
# stops before the new one binds 80/443: every Route is down meanwhile.
default_rollout() {
  local before=$1 attempt gen
  for attempt in $(seq 0 60); do
    gen=$($KUBE get deploy router-default -n openshift-ingress -o jsonpath='{.metadata.generation}') \
      || { bad "cannot read deploy/router-default"; exit 1; }
    [ "$gen" -gt "$before" ] && break
    [ "$attempt" -eq 60 ] || sleep 2
  done
  [ "$gen" -gt "$before" ] || { bad "the ingress operator did not update router-default in 2 minutes"; exit 1; }
  $KUBE rollout status deploy/router-default -n openshift-ingress --timeout=300s >/dev/null \
    || { bad "router-default did not roll out - oc get pods -n openshift-ingress"; exit 1; }
}
default_exclude() {
  local now want before
  now=$(default_selector) || exit 1
  want=$(python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$DEFAULT_SELECTOR")
  if [ "$now" = "$want" ]; then ok "the default router already ignores Routes labelled ingress-shard"; return 0; fi
  [ -z "$now" ] || { bad "IngressController default already has routeSelector $now - left alone"; exit 1; }
  before=$($KUBE get deploy router-default -n openshift-ingress -o jsonpath='{.metadata.generation}') \
    || { bad "cannot read deploy/router-default"; exit 1; }
  $KUBE patch ingresscontroller default -n openshift-ingress-operator --type=merge \
    -p "{\"spec\":{\"routeSelector\":$DEFAULT_SELECTOR}}" >/dev/null \
    || { bad "cannot set the default router's routeSelector"; exit 1; }
  default_rollout "$before"
  ok "the default router ignores Routes labelled ingress-shard (router-default rolled out)"
}
# svc_address - the shard Service's load-balancer address, or nothing.
svc_address() {
  $KUBE get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
}

deploy() {
  say "deploying the ingress shard"
  $KUBE apply -f manifests/10-pool.yaml -f manifests/20-certificate.yaml >/dev/null || { bad "apply failed"; exit 1; }
  $KUBE wait certificate/router-metallb-default -n openshift-ingress --for=condition=Ready --timeout=120s >/dev/null \
    || { bad "certificate router-metallb-default is not Ready - oc describe certificate router-metallb-default -n openshift-ingress"; exit 1; }
  # Before the canary exists, so the default router never admits it.
  default_exclude
  $KUBE apply -f manifests/30-ingresscontroller.yaml -f manifests/40-canary.yaml >/dev/null || { bad "apply failed"; exit 1; }
  $KUBE apply -n "$NS" -f ../../_shared/echo-app.yaml >/dev/null || { bad "apply failed"; exit 1; }
  # Available needs the router's Deployment and LoadBalancerReady: the Service has
  # its address (cluster-ingress-operator, status.go, computeIngressAvailableCondition).
  $KUBE wait ingresscontroller/metallb -n openshift-ingress-operator --for=condition=Available --timeout=300s >/dev/null \
    || { bad "IngressController metallb is not Available - oc get ingresscontroller metallb -n openshift-ingress-operator -o yaml"; exit 1; }
  [ "$(svc_address)" = "$ADDR" ] || { bad "router-metallb has [$(svc_address)], not $ADDR"; exit 1; }
  ok "router-metallb is published at $ADDR"
  wait_ready echo
  forward_ensure
  app_resume "$APP"
}

# routers_of <route> <namespace> - the routers that list the Route, as sorted
# "<router>=<Admitted status>" pairs, e.g. "default=True metallb=True".
routers_of() {
  $KUBE get route "$1" -n "$2" -o jsonpath='{range .status.ingress[*]}{.routerName}={.conditions[?(@.type=="Admitted")].status}{"\n"}{end}' \
    | sort | paste -sd' ' -
}
# routes_not <check> - every Route, "<namespace>/<name>", that fails <check>:
#   shard-label    admitted by the shard, but not labelled ingress-shard=metallb
#   default        not labelled, and not admitted by the default router
#   default-label  labelled, and admitted by the default router
# Empty when every Route passes. Fatal when the Routes cannot be read.
routes_not() {
  local json
  json=$($KUBE get routes -A -o json) || { bad "cannot list Routes"; exit 1; }
  python3 -c '
import json, sys
check = sys.argv[1]
for r in json.load(sys.stdin)["items"]:
    admitted = {i["routerName"] for i in r.get("status", {}).get("ingress", [])
                for c in i.get("conditions", []) if c["type"] == "Admitted" and c["status"] == "True"}
    labelled = r["metadata"].get("labels", {}).get("ingress-shard") == "metallb"
    if (check == "shard-label" and "metallb" in admitted and not labelled) or \
       (check == "default" and not labelled and "default" not in admitted) or \
       (check == "default-label" and labelled and "default" in admitted):
        print(r["metadata"]["namespace"] + "/" + r["metadata"]["name"])' "$1" <<<"$json" | sort | paste -sd' ' -
}
# cert_subject <host:port> <sni> - the subject of the certificate served there, as
# "subject=CN=...", with no spaces (LibreSSL prints "subject= /CN=...").
cert_subject() {
  openssl s_client -connect "$1" -servername "$2" </dev/null 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | tr -d ' ' | sed 's#^subject=/#subject=#'
}

verify() {
  say "1. the address"
  assert "pool ingress-shard-pool holds $ADDR only" "192.168.127.130/32" \
    "$($KUBE get ipaddresspool ingress-shard-pool -n metallb-system -o jsonpath='{.spec.addresses[*]}')"
  assert "IngressController metallb is Available" "True" \
    "$($KUBE get ingresscontroller metallb -n openshift-ingress-operator -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
  assert "...and its load balancer is ready" "True" \
    "$($KUBE get ingresscontroller metallb -n openshift-ingress-operator -o jsonpath='{.status.conditions[?(@.type=="LoadBalancerReady")].status}')"
  assert "router-metallb has $ADDR" "$ADDR" "$(svc_address)"
  assert "...from ingress-shard-pool" "ingress-shard-pool" \
    "$($KUBE get svc router-metallb -n openshift-ingress -o jsonpath='{.metadata.annotations.metallb\.io/ip-allocated-from-pool}')"
  assert "no other Service holds an address from ingress-shard-pool" "openshift-ingress/router-metallb" \
    "$($KUBE get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}{end}' | awk '$2 == "ingress-shard-pool" { print $1 }' | paste -sd' ' -)"

  say "2. which router admits what"
  assert "the default router ignores Routes labelled ingress-shard" \
    "$(python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$DEFAULT_SELECTOR")" \
    "$(default_selector)"
  assert "canary is admitted by the shard alone" "metallb=True" "$(routers_of canary "$NS")"
  assert "the shard admits only Routes labelled ingress-shard=metallb" "" "$(routes_not shard-label)"
  assert "the default router admits no Route labelled ingress-shard" "" "$(routes_not default-label)"
  assert "every other Route is still admitted by the default router" "" "$(routes_not default)"

  say "3. from this laptop"
  if [ -S "$SOCK" ]; then
    assert "$LOCAL forwards to $ADDR:443" "$ADDR:443" "$(forward_target)"
  else
    echo "  note: not CRC - the checks below assume $LOCAL reaches $ADDR:443"
  fi
  # enterprise-ca's root, to check the shard's certificate against; removed on exit.
  CA_FILE=$(mktemp) || exit 1
  trap 'rm -f "$CA_FILE"' EXIT
  $KUBE get secret enterprise-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d >"$CA_FILE"
  R=$(curl -sS --max-time 10 --cacert "$CA_FILE" --resolve "$HOST:${LOCAL##*:}:127.0.0.1" -w ' -> %{http_code}' "https://$HOST:${LOCAL##*:}/" 2>&1)
  assert_contains "https://$HOST:${LOCAL##*:}/ -> 200, the certificate checked against enterprise-ca" " -> 200" "$R"
  assert_contains "...answered by the echo app behind the canary Route" "\"host\": \"$HOST:${LOCAL##*:}\"" "$R"
  assert "...with the shard's certificate" "subject=CN=*.apps-metallb.crc.testing" "$(cert_subject "$LOCAL" "$HOST")"
  # CRC's :443 is the default router, which ignores the canary: it answers a host
  # it does not admit with 503 (-k: its certificate is for another domain).
  assert "on :443 the default router does not serve the canary" "503" \
    "$(curl -sk -o /dev/null --max-time 10 --resolve "$HOST:443:127.0.0.1" -w '%{http_code}' "https://$HOST/")"

  say "4. the default router's Routes still answer from this laptop"
  assert "console"  "200" "$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' https://console-openshift-console.apps-crc.testing/)"
  assert "oauth"    "403" "$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' https://oauth-openshift.apps-crc.testing/)"
  assert "keycloak" "302" "$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' https://keycloak.apps-crc.testing/)"
  assert "kiosk"    "200" "$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' https://kiosk-modernize-demo.apps-crc.testing/)"
  assert "ldaps (passthrough, by SNI)" "subject=CN=openldap-service.ldap-testing.svc" \
    "$(cert_subject ldaps-ldap-testing.apps-crc.testing:443 ldaps-ldap-testing.apps-crc.testing)"
  summary
}

clean() {
  # Argo CD would put everything back as it is deleted.
  app_pause "$APP"
  forward_remove
  $KUBE delete -f manifests/40-canary.yaml --ignore-not-found --wait=false >/dev/null 2>&1
  # The operator removes router-metallb (Deployment and Service) with its
  # IngressController; the address goes back to the pool once the Service is gone.
  $KUBE delete -f manifests/30-ingresscontroller.yaml --ignore-not-found >/dev/null 2>&1
  $KUBE wait svc/router-metallb -n openshift-ingress --for=delete --timeout=120s >/dev/null 2>&1
  $KUBE delete -f manifests/20-certificate.yaml --ignore-not-found >/dev/null 2>&1
  $KUBE delete secret router-metallb-default-cert -n openshift-ingress --ignore-not-found >/dev/null 2>&1
  $KUBE delete -f manifests/10-pool.yaml --ignore-not-found >/dev/null 2>&1
  # The default router's selector stays: with no Route labelled ingress-shard it
  # changes nothing. Removing it is not safe - the ingress operator reads a
  # missing routeSelector as "select nothing" when it clears status
  # (cluster-ingress-operator router_status.go, clearRoutesNotAdmittedByIngress;
  # apimachinery LabelSelectorAsSelector(nil) = labels.Nothing()), so it clears
  # the Admitted status of every Route on the default router. Measured
  # 2026-09-27: 21 of 21 cleared; the image registry's route lost its hostname
  # and kube-apiserver rolled out twice (revisions 9 and 10).
  ok "ingress shard removed; the default router keeps its selector (a no-op now); mongot-pool and CRC's own forwards are untouched"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  pause) app_pause "$APP" ;; resume) app_resume "$APP" ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
