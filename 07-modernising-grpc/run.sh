#!/usr/bin/env bash
# Module 07 — REST + JSON in front of a gRPC-only service.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-07
. ../_shared/lib.sh

deploy() {
  say "deploying into $NS"
  ns_ensure
  # The .proto and the service's source, as ConfigMaps built from the files in
  # this folder - so the running code is exactly what you are reading.
  $KUBE create configmap catalog-proto -n "$NS" --from-file=proto/catalog.proto \
    --dry-run=client -o yaml | $KUBE apply -f - >/dev/null
  $KUBE create configmap catalog-app -n "$NS" --from-file=app/server.py \
    --dry-run=client -o yaml | $KUBE apply -f - >/dev/null
  $KUBE apply -n "$NS" -f manifests/ >/dev/null
  # The init containers install from PyPI on every start, so allow for it.
  wait_ready catalog 300s; wait_ready envoy 300s
  $KUBE wait -n "$NS" --for=condition=Ready pod/grpc-client --timeout=120s >/dev/null
  wait_upstream catalog
  ok "catalog (gRPC only) and envoy are up"
}

grpc() { $KUBE exec -n "$NS" grpc-client -- grpcurl -plaintext "$@" 2>&1; }
rest() { incluster_curl "$@"; }
on_hand() { rest "http://envoy.$NS.svc:8080/v1/items/$1" | awk -F': ' '/"onHand"/ { gsub(/[^0-9]/, "", $2); print $2 }'; }

verify() {
  client_ready
  say "1. the service speaks only gRPC"
  assert_contains "plain HTTP/1.1 straight at it fails" "HTTP/0.9" \
    "$($KUBE exec -n "$NS" client -- curl -sS "http://catalog.$NS.svc:50051/v1/items" 2>&1)"

  say "2. REST + JSON through Envoy"
  L=$(rest "http://envoy.$NS.svc:8080/v1/items")
  assert_contains "GET /v1/items lists widget" '"sku": "widget"' "$L"
  assert_contains "JSON uses lowerCamelCase: onHand" '"onHand"' "$L"
  R=$(rest -i "http://envoy.$NS.svc:8080/v1/items/nope")
  assert_contains "unknown sku -> HTTP 404" "404 Not Found" "$R"
  assert_contains "...with the gRPC code in the body (5 = NOT_FOUND)" '"code": 5' "$R"
  assert_contains "too many -> 400, code 9 = FAILED_PRECONDITION" '"code": 9' \
    "$(rest -X POST -H 'content-type: application/json' -d '{"quantity": 100000}' "http://envoy.$NS.svc:8080/v1/items/gadget:reserve")"
  assert_contains "zero -> 400, code 3 = INVALID_ARGUMENT" '"code": 3' \
    "$(rest -X POST -H 'content-type: application/json' -d '{"quantity": 0}' "http://envoy.$NS.svc:8080/v1/items/gadget:reserve")"
  BEFORE=$(on_hand widget)
  rest -X POST -H 'content-type: application/json' -d '{"quantity": 1}' \
    "http://envoy.$NS.svc:8080/v1/items/widget:reserve" >/dev/null
  assert "POST :reserve changed the service's state (widget -1)" "$((BEFORE - 1))" "$(on_hand widget)"

  say "3. native gRPC through the same Envoy port"
  assert_contains "grpcurl lists the service" "tutorial.catalog.v1.Catalog" "$(grpc "envoy.$NS.svc:8080" list)"
  assert_contains "GetItem over gRPC (proto field names: on_hand)" '"on_hand"' \
    "$(grpc -d '{"sku":"widget"}' "envoy.$NS.svc:8080" tutorial.catalog.v1.Catalog/GetItem)"
  assert_contains "a gRPC error stays a gRPC error" "Code: NotFound" \
    "$(grpc -d '{"sku":"nope"}' "envoy.$NS.svc:8080" tutorial.catalog.v1.Catalog/GetItem)"

  say "4. upstream, everything is HTTP/2"
  S=$(incluster_curl "http://envoy.$NS.svc:9901/stats?filter=^cluster\.catalog\.upstream_cx_http(1|2)_total$")
  assert_contains "no HTTP/1.1 connections to the service" "upstream_cx_http1_total: 0" "$S"
  assert "HTTP/2 connections to the service" "yes" \
    "$(printf '%s\n' "$S" | awk -F': ' '/http2_total/ { print ($2 > 0) ? "yes" : "no" }')"
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
