#!/usr/bin/env bash
# Module 15 — BackendTLSPolicy: TLS from the Gateway to the backend.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-15
. ../_shared/lib.sh
. ../_shared/gateway.sh

deploy() {
  say "deploying into $NS"
  $KUBE apply -f ../12-gateway-api/manifests/20-envoyproxy.yaml -f ../12-gateway-api/manifests/10-gatewayclass.yaml >/dev/null
  $KUBE wait gatewayclass/eg --for=condition=Accepted --timeout=60s >/dev/null
  $KUBE apply -f manifests/10-gateway.yaml >/dev/null
  gw_up "$NS" eg
  $KUBE apply -n "$NS" -f manifests/20-certificate.yaml >/dev/null
  $KUBE wait -n "$NS" certificate/secure-echo-tls --for=condition=Ready --timeout=120s >/dev/null \
    || { bad "certificate secure-echo-tls never Ready - is the enterprise-ca ClusterIssuer Ready?"; exit 1; }
  # The CA the policy trusts, from the Secret cert-manager wrote, under the key
  # the Gateway API spec requires: ca.crt.
  $KUBE create configmap enterprise-ca -n "$NS" --dry-run=client -o yaml \
    --from-literal=ca.crt="$($KUBE get secret secure-echo-tls -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)" \
    | $KUBE apply -f - >/dev/null
  $KUBE apply -n "$NS" -f ../_shared/client.yaml -f manifests/30-secure-echo.yaml -f manifests/40-httproute.yaml \
    -f manifests/50-backendtlspolicy.yaml >/dev/null
  wait_ready secure-echo
  ok "Gateway eg programmed at $(gw_address "$NS" eg)"
}

# tls_conf - "sni=... san=... ca=..." of the upstream TLS Envoy has for /secure.
tls_conf() {
  ../_shared/eg-admin.sh "$NS/eg" 'config_dump?resource=dynamic_active_clusters' | python3 -c '
import json, sys
for c in json.load(sys.stdin)["configs"]:
    cl = c["cluster"]
    if "/secure/" not in cl["name"]:
        continue
    for m in cl.get("transport_socket_matches", []):
        tc = m["transport_socket"]["typed_config"]
        cv = tc["common_tls_context"].get("combined_validation_context", {})
        san = [x["matcher"]["exact"] for x in cv.get("default_validation_context", {}).get("match_typed_subject_alt_names", [])]
        ca = cv.get("validation_context_sds_secret_config", {}).get("name") or "system_ca_certificates"
        print("sni=%s san=%s ca=%s" % (tc.get("sni"), ",".join(san), ca))'
}
# want <file> - the upstream TLS (in tls_conf's words) that manifests/<file> asks for.
want() {
  case "$1" in
    50-backendtlspolicy.yaml) echo "sni=secure-echo.$NS.svc san=secure-echo.$NS.svc ca=secure-echo/$NS-ca" ;;
    55-wrong-hostname.yaml)   echo "sni=payments.$NS.svc san=payments.$NS.svc ca=secure-echo/$NS-ca" ;;
    56-system-cas.yaml)       echo "sni=secure-echo.$NS.svc san=secure-echo.$NS.svc ca=system_ca_certificates" ;;
  esac
}
# apply_and_wait <file> - apply a policy and wait until Envoy runs exactly the TLS
# config it asks for: a change to an existing policy is a cluster-only change,
# about 15 s (module 14, step 4). Waiting for that config - not for "any change" -
# also covers a re-run whose policy is already in place; a timeout is a failed check.
apply_and_wait() {
  local want_conf; want_conf=$(want "$1")
  $KUBE apply -f "manifests/$1" >/dev/null
  for _ in $(seq 1 60); do [ "$(tls_conf)" = "$want_conf" ] && return 0; sleep 1; done
  bad "Envoy's TLS config is not [$want_conf] 60 s after applying $1 - it is [$(tls_conf)]"
  FAILED=$((FAILED+1))
  return 1
}
ssl_stat() { ../_shared/eg-admin.sh "$NS/eg" "stats?filter=^cluster\.httproute/$NS/secure/rule/0\.ssl\.$1\$" | awk -F': ' '{ print $2 }'; }
code() { incluster_curl -o /dev/null -w '%{http_code}' "http://$ADDR/secure"; }

verify() {
  client_ready
  ADDR=$(gw_address "$NS" eg)
  [ -n "$ADDR" ] || { bad "Gateway eg has no address"; FAILED=$((FAILED+1)); summary; exit 1; }
  # A previous run may have been interrupted on a failure step.
  [ "$(tls_conf)" = "$(want 50-backendtlspolicy.yaml)" ] || apply_and_wait 50-backendtlspolicy.yaml

  say "1. the policy"
  for c in Accepted ResolvedRefs; do
    assert "BackendTLSPolicy $c" "True" \
      "$($KUBE get backendtlspolicy secure-echo -n "$NS" -o jsonpath="{.status.ancestors[0].conditions[?(@.type==\"$c\")].status}")"
  done

  say "2. the Gateway reaches the TLS-only backend over TLS"
  BODY=$(incluster_curl "http://$ADDR/secure")
  assert_contains "the backend answered"                   '"served_by"'                          "$BODY"
  assert_contains "over TLS 1.3"                           '"version": "TLSv1.3"'                 "$BODY"
  assert_contains "asking for the policy's hostname (SNI)" "\"sni\": \"secure-echo.$NS.svc\""    "$BODY"
  assert "Envoy got: SNI, SAN check and CA from the policy" "$(want 50-backendtlspolicy.yaml)" "$(tls_conf)"

  say "3. a name the certificate does not carry is refused"
  apply_and_wait 55-wrong-hostname.yaml
  N=$(ssl_stat fail_verify_san)
  assert "request -> 503" "503" "$(code)"
  assert "counted as ssl.fail_verify_san" "$((N + 1))" "$(ssl_stat fail_verify_san)"

  say "4. a CA that did not sign it is refused"
  apply_and_wait 56-system-cas.yaml
  N=$(ssl_stat fail_verify_error)
  assert "request -> 503" "503" "$(code)"
  assert "counted as ssl.fail_verify_error" "$((N + 1))" "$(ssl_stat fail_verify_error)"

  say "5. back to the right policy"
  apply_and_wait 50-backendtlspolicy.yaml
  assert "request -> 200" "200" "$(code)"
  summary
}

clean() {
  gw_down "$NS" eg
  $KUBE delete -f manifests/10-gateway.yaml --ignore-not-found --wait=false >/dev/null 2>&1
  ok "namespace $NS deleting (module 12's GatewayClass eg is left for other modules)"
}

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
