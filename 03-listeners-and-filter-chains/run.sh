#!/usr/bin/env bash
# Module 03 — listeners and filter chains.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-03
. ../_shared/lib.sh

deploy() {
  say "deploying into $NS"
  ns_ensure
  $KUBE apply -n "$NS" -f ../_shared/echo-app.yaml >/dev/null
  $KUBE apply -n "$NS" -f manifests/ >/dev/null
  wait_ready echo; wait_ready envoy
  wait_upstream echo_service
  ok "echo and envoy are up"
}

verify() {
  say "1. virtual hosts pick on the Host header (after HTTP is parsed)"
  for h in shop admin; do
    R=$(incluster_curl -i -H "Host: $h.apps-crc.testing" "http://envoy.$NS.svc:8080/")
    assert_contains "Host $h.apps-crc.testing -> vhost $h" "x-matched-vhost: $h" "$R"
  done
  R=$(incluster_curl -i -H "Host: nobody.apps-crc.testing" "http://envoy.$NS.svc:8080/")
  assert_contains "unknown Host hits the catch-all 404" "404" "$R"

  say "2. filter chains pick on SNI (before any HTTP exists)"
  for h in shop admin; do
    # --resolve maps the SNI name to the Service IP, so the TLS handshake
    # carries the right server_name without needing real DNS.
    R=$(incluster_curl -i -k --resolve "$h.apps-crc.testing:8443:$(svc_ip)" \
        "https://$h.apps-crc.testing:8443/")
    assert_contains "SNI $h.apps-crc.testing -> chain sni-$h" "x-matched-chain: sni-$h" "$R"
  done

  say "3. each chain serves its own certificate"
  for h in shop admin; do
    # curl's %{certs} write-out prints the certificate the server presented,
    # so the same client pod reads it - no separate openssl image needed.
    CN=$(incluster_curl -k -o /dev/null --resolve "$h.apps-crc.testing:8443:$(svc_ip)" \
         -w '%{certs}' "https://$h.apps-crc.testing:8443/" | grep -m1 -i '^subject:' | tr -d ' ')
    assert_contains "SNI $h.apps-crc.testing is served the $h cert" "CN=$h.apps-crc.testing" "$CN"
  done

  say "4. tls_inspector is in the running listener"
  CD=$(incluster_curl "http://envoy.$NS.svc:9901/config_dump")
  assert_contains "tls_inspector is present" "tls_inspector" "$CD"

  say "5. the Routes are passthrough (edge would terminate TLS at the router)"
  for h in shop admin; do
    assert "route/$h is passthrough" "passthrough" \
      "$($KUBE get route "$h" -n "$NS" -o jsonpath='{.spec.tls.termination}' 2>/dev/null)"
  done
  summary
}

svc_ip() { $KUBE get svc envoy -n "$NS" -o jsonpath='{.spec.clusterIP}'; }

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
