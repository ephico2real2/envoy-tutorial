#!/usr/bin/env bash
# Module 09 — gRPC over TLS end to end, mutual TLS upstream, certificate rotation.
#   ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-09
. ../_shared/lib.sh

has_routes() { $KUBE api-resources --api-group=route.openshift.io 2>/dev/null | grep -q '^routes'; }

deploy() {
  say "deploying into $NS"
  ns_ensure
  $KUBE apply -n "$NS" -f manifests/10-certificates.yaml >/dev/null
  $KUBE wait -n "$NS" --for=condition=Ready certificate --all --timeout=120s >/dev/null \
    || { bad "the certificates never became Ready"; exit 1; }
  $KUBE create configmap catalog-proto -n "$NS" --from-file=proto/catalog.proto \
    --dry-run=client -o yaml | $KUBE apply -f - >/dev/null
  $KUBE create configmap catalog-app -n "$NS" --from-file=app/server.py \
    --dry-run=client -o yaml | $KUBE apply -f - >/dev/null
  $KUBE apply -n "$NS" -f manifests/20-catalog.yaml -f manifests/30-envoy-config.yaml \
    -f manifests/35-sds.yaml -f manifests/40-envoy.yaml -f manifests/60-grpc-client.yaml >/dev/null
  has_routes && $KUBE apply -n "$NS" -f manifests/50-route.yaml >/dev/null
  wait_ready catalog 300s; wait_ready envoy
  $KUBE wait -n "$NS" --for=condition=Ready pod/grpc-client --timeout=120s >/dev/null
  wait_upstream catalog
  ok "certificates issued; catalog (mutual TLS) and envoy are up"
}

# The CA, copied into both client pods, which trust nothing else.
copy_ca() {
  $KUBE get secret envoy-edge -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
  for p in client grpc-client; do $KUBE exec -i -n "$NS" "$p" -- sh -c 'cat > /tmp/ca.crt' < ca.crt; done
}
grpc() { $KUBE exec -n "$NS" grpc-client -- grpcurl -cacert /tmp/ca.crt "$@" 2>&1; }
# serial <port> - the serial number of the certificate a listener presents.
serial() {
  incluster_sh "curl -sk -o /dev/null -w '%{certs}' https://envoy.$NS.svc:$1/" \
    | grep -m1 -i 'serial' | sed 's/.*[Ss]erial[^:]*: *//' | tr -d ':' | tr 'A-F' 'a-f'
}

verify() {
  client_ready
  copy_ca

  say "1. three certificates from cert-manager"
  for c in envoy-edge catalog-tls envoy-client; do
    assert "certificate/$c is Ready" "True" \
      "$($KUBE get certificate "$c" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  done
  assert_contains "envoy-client is a CLIENT certificate" "TLS Web Client Authentication" \
    "$($KUBE get secret envoy-client -n "$NS" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text)"

  say "2. gRPC over TLS, through Envoy"
  assert_contains "grpcurl, trusting only the enterprise CA" "tutorial.catalog.v1.Catalog" \
    "$(grpc "envoy.$NS.svc:8443" list)"
  assert_contains "GetItem" '"sku": "widget"' \
    "$(grpc -d '{"sku":"widget"}' "envoy.$NS.svc:8443" tutorial.catalog.v1.Catalog/GetItem)"

  say "3. mutual TLS between Envoy and the service"
  assert_contains "the service logged Envoy's identity" "caller=spiffe://envoy-tutorial/ns/envoy-09/envoy" \
    "$($KUBE logs -n "$NS" deploy/catalog -c catalog --tail=5)"
  assert_contains "without a client certificate, the service refuses" "Failed to dial" \
    "$(grpc -connect-timeout 5 "catalog.$NS.svc:50051" list)"
  S=$(incluster_curl "http://envoy.$NS.svc:9901/stats?filter=^cluster\.catalog\.ssl\.(handshake|fail_verify_san)$")
  assert_contains "Envoy's upstream handshakes succeeded" "ssl.fail_verify_san: 0" "$S"

  if has_routes; then
    say "4. from outside, through the passthrough Route"
    assert_contains "grpc.apps-crc.testing:443" "tutorial.catalog.v1.Catalog" "$(grpc grpc.apps-crc.testing:443 list)"
  fi

  say "5. rotation: cert-manager replaces envoy-edge while Envoy runs"
  OLD=$(serial 8443)
  $KUBE delete secret envoy-edge -n "$NS" >/dev/null
  NEW=$OLD
  for _ in $(seq 1 60); do
    sleep 3; NEW=$(serial 8443); [ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && break
  done
  assert "SDS listener :8443 now presents the new certificate" "changed" \
    "$([ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && echo changed || echo unchanged)"
  assert "static listener :8444 still presents the old one" "$OLD" "$(serial 8444)"
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; rm -f ca.crt; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2,3p' "$0" | sed 's/^# //'; exit 2 ;;
esac
