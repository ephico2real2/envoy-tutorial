#!/usr/bin/env bash
# Module 08 — TLS on Envoy, with a certificate from cert-manager.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-08
. ../_shared/lib.sh

has_routes() { $KUBE api-resources --api-group=route.openshift.io 2>/dev/null | grep -q '^routes'; }

deploy() {
  say "deploying into $NS"
  ns_ensure
  $KUBE apply -n "$NS" -f ../_shared/echo-app.yaml -f manifests/10-certificate.yaml >/dev/null
  $KUBE wait -n "$NS" --for=condition=Ready certificate/shop-tls --timeout=120s >/dev/null \
    || { bad "certificate/shop-tls never became Ready"; exit 1; }
  $KUBE apply -n "$NS" -f manifests/20-envoy-config.yaml -f manifests/30-envoy.yaml >/dev/null
  $KUBE get secret shop-tls -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
  if has_routes; then
    $KUBE apply -n "$NS" -f manifests/40-routes.yaml >/dev/null
    $KUBE get route shop-reencrypt -n "$NS" >/dev/null 2>&1 || \
      $KUBE create route reencrypt shop-reencrypt -n "$NS" --service=envoy --port=https \
        --hostname=shop-reencrypt.apps-crc.testing --dest-ca-cert=ca.crt >/dev/null
  fi
  wait_ready echo; wait_ready envoy
  wait_upstream echo_service
  ok "certificate issued; echo and envoy are up"
}

# tls <url> [curl args] - "<http code> exit=<curl exit>" from the client pod,
# trusting only the enterprise CA copied into it.
tls() {
  incluster_sh "curl -sS --cacert /tmp/ca.crt -o /dev/null -w '%{http_code} ' ${2:-} $1 2>/dev/null; echo exit=\$?"
}
issuer() { incluster_sh "curl -sk -o /dev/null -w '%{certs}' $1" | grep -m1 -i '^issuer:'; }

verify() {
  client_ready
  $KUBE get secret shop-tls -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d \
    | $KUBE exec -i -n "$NS" client -- sh -c 'cat > /tmp/ca.crt'

  say "1. cert-manager issued the certificate"
  CRT=$($KUBE get secret shop-tls -n "$NS" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -text)
  assert_contains "signed by the enterprise CA" "Enterprise Root CA" "$CRT"
  for n in shop.apps-crc.testing shop-reencrypt.apps-crc.testing envoy.envoy-08.svc; do
    assert_contains "SAN $n" "DNS:$n" "$CRT"
  done

  say "2. trust, and the name in the certificate"
  assert "the right name, trusting the CA: 200"      "200 exit=0"  "$(tls https://envoy.envoy-08.svc:8443/)"
  assert "not trusting the CA: curl exit 60"         "000 exit=60" "$(incluster_sh "curl -sS -o /dev/null -w '%{http_code} ' https://envoy.envoy-08.svc:8443/ 2>/dev/null; echo exit=\$?")"
  assert "a name not in the certificate: exit 60"    "000 exit=60" "$(tls https://envoy:8443/)"

  say "3. forwarded headers without a router"
  assert_contains "plain port: Envoy sets x-forwarded-proto http" '"x-forwarded-proto": "http"' \
    "$(incluster_curl "http://envoy.$NS.svc:8080/")"

  if has_routes; then
    say "4. who terminates TLS decides which certificate the client sees"
    assert "passthrough: Envoy's certificate, trusted"        "200 exit=0"  "$(tls https://shop.apps-crc.testing/)"
    assert_contains "passthrough: issued by the enterprise CA" "Enterprise Root CA" "$(issuer https://shop.apps-crc.testing/)"
    assert "edge: the router's certificate, not trusted"       "000 exit=60" "$(tls https://shop-edge.apps-crc.testing/)"
    assert_contains "edge: issued by the router's own CA"      "ingress-operator" "$(issuer https://shop-edge.apps-crc.testing/)"
    assert_contains "edge: Envoy gets plain HTTP on :8080"     "x-envoy-listener: plain-8080" \
      "$(incluster_curl -k -i https://shop-edge.apps-crc.testing/)"
    assert_contains "edge: the app still sees https (the router's header)" '"x-forwarded-proto": "https"' \
      "$(incluster_curl -k https://shop-edge.apps-crc.testing/)"
    assert_contains "reencrypt: Envoy gets TLS again on :8443" "x-envoy-listener: tls-8443" \
      "$(incluster_curl -k -i https://shop-reencrypt.apps-crc.testing/)"
  else
    say "4. skipped: no OpenShift Routes on this cluster"
  fi
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; rm -f ca.crt; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
