#!/usr/bin/env bash
# Module 04 — routing: match types, rewrites, timeouts, redirects.  ./run.sh deploy | verify | shadow | clean
cd "$(dirname "$0")"
NS=envoy-04
. ../_shared/lib.sh

deploy() {
  say "deploying into $NS"
  ns_ensure
  $KUBE apply -n "$NS" -f ../_shared/echo-app.yaml >/dev/null
  $KUBE apply -n "$NS" -f manifests/ >/dev/null
  wait_ready echo; wait_ready slow; wait_ready envoy
  wait_upstream echo_service
  wait_upstream slow_service
  ok "echo, slow and envoy are up"
}

# The route each request landed on is reported by that route's own
# response_headers_to_add, so every assertion below reads the running proxy's
# decision rather than this file's intent.
route_of() { # path [curl args...]
  incluster_curl -i "http://envoy.$NS.svc:8080$1" "${@:2}" \
    | tr -d '\r' | awk -F': ' '/^x-matched-route:/ {print $2}'
}
body_of() { incluster_curl "http://envoy.$NS.svc:8080$1" "${@:2}"; }
# Sum of upstream_rq_total across every cluster, read from the running proxy.
upstream_rq_total() {
  incluster_curl "http://envoy.$NS.svc:9901/stats?filter=upstream_rq_total$" \
    | awk -F': ' '{ n += $2 } END { print n + 0 }'
}

verify() {
  say "1. match types, in the order Envoy tries them"
  assert "exact path /exact"                 "exact-path"   "$(route_of /exact)"
  assert "regex /order/42"                   "regex"        "$(route_of /order/42)"
  assert "regex does NOT match /order/abc"   "catch-all"    "$(route_of /order/abc)"
  assert "header x-canary: yes"              "header-canary" "$(route_of / -H 'x-canary: yes')"
  assert "query ?debug=1"                    "query-debug"  "$(route_of '/anything?debug=1')"
  assert "no discriminator falls to catch-all" "catch-all"  "$(route_of /nothing-special)"

  say "2. first match wins — the same request, two orders"
  # /exact is route 1 and the canary header is route 3, so the path wins.
  assert "/exact + canary header -> the earlier route" "exact-path" \
    "$(route_of /exact -H 'x-canary: yes')"
  # /api/v1/ is route 5 and the canary is route 3, so this time the header wins.
  assert "/api/v1/x + canary header -> the earlier route" "header-canary" \
    "$(route_of /api/v1/x -H 'x-canary: yes')"

  say "3. rewrites, seen from the upstream's side"
  assert_contains "prefix_rewrite strips /api/v1" '"path": "/thing"' \
    "$(body_of /api/v1/thing)"
  assert_contains "regex_rewrite moves the capture" '"path": "/profile/42"' \
    "$(body_of /user/42/profile)"
  assert_contains "host_rewrite_literal changes Host upstream" '"host": "upstream.internal"' \
    "$(body_of /rewrite-host)"

  say "4. timeouts"
  # 250ms against a 1s upstream: Envoy gives up and answers 504 itself.
  R=$(incluster_curl -i "http://envoy.$NS.svc:8080/slow")
  assert_contains "250ms timeout against a 1s upstream -> 504" "504" "$R"
  assert_contains "504 says what happened" "upstream request timeout" "$R"
  # The same upstream with 5s: it finishes.
  assert_contains "5s timeout against the same upstream -> 200" "slow reply after 1.0s" \
    "$(body_of /patient)"
  # The budget is forwarded so the upstream can give up too.
  assert_contains "timeout is forwarded as a budget header" \
    '"x-envoy-expected-rq-timeout-ms": "1234"' "$(body_of /budget)"

  say "5. routes Envoy answers without any upstream"
  R=$(incluster_curl -i "http://envoy.$NS.svc:8080/old")
  assert_contains "/old redirects 301" "301" "$R"
  LOC=$(printf '%s' "$R" | tr -d '\r' | tr 'A-Z' 'a-z' | awk -F': ' '/^location:/ {print $2}')
  assert_contains "/old points at the new path" "/exact" "$LOC"
  # path_redirect replaces the PATH, but Envoy emits a full URI rebuilt from the
  # request's scheme and authority - not the bare path it was given. Asserted
  # because the natural expectation ("location: /exact") is wrong.
  assert_contains "Location is an absolute URI, not a bare path" "http://" "$LOC"
  assert "direct_response body" "ok" "$(body_of /healthz)"
  # "Answered by Envoy alone" is checked, not assumed: requests to /healthz and
  # /old must leave every cluster's upstream request counter where it was.
  # Sections 1-4 sent traffic, so a zero here means the stats read failed -
  # and two failed reads would compare equal and pass for the wrong reason.
  BEFORE=$(upstream_rq_total)
  assert "upstream counters are readable (non-zero)" "yes" \
    "$([ "$BEFORE" -gt 0 ] && echo yes || echo no)"
  for _ in 1 2 3; do body_of /healthz >/dev/null; body_of /old >/dev/null; done
  assert "6 requests to /healthz and /old reach no upstream" "$BEFORE" "$(upstream_rq_total)"

  say "6. matcher edge cases"
  assert "prefix is not segment-aware: /slowpoke matches prefix /slow" \
    "timeout-250ms" "$(route_of /slowpoke)"
  assert "path_separated_prefix is: /patients misses /patient" "catch-all" "$(route_of /patients)"
  assert "path_separated_prefix still matches /patient/x"      "timeout-5s" "$(route_of /patient/x)"
  assert "prefix /api/v1/ does not match /api/v1"  "catch-all"  "$(route_of /api/v1)"
  assert "path is case-sensitive: /EXACT"          "catch-all"  "$(route_of /EXACT)"
  assert "path is exact: /exact/ is another path"  "catch-all"  "$(route_of /exact/)"
  assert "path ignores the query string"           "exact-path" "$(route_of '/exact?x=1')"
  assert "header NAME is case-insensitive"  "header-canary" "$(route_of / -H 'X-Canary: yes')"
  assert "header VALUE is exact: YES != yes" "catch-all"    "$(route_of / -H 'x-canary: YES')"
  assert "query parameter NAME is case-sensitive" "catch-all" "$(route_of '/anything?DEBUG=1')"

  say "7. the running proxy really holds these routes"
  CD=$(incluster_curl "http://envoy.$NS.svc:9901/config_dump?resource=static_route_configs")
  assert_contains "route_config 'routing' is loaded" '"name": "routing"' "$CD"
  assert_contains "prefix_rewrite is in the running config" "prefix_rewrite" "$CD"
  assert "13 routes are loaded" "13" "$(printf '%s\n' "$CD" | grep -c '"match": {')"
  assert "the last route is the catch-all" '"prefix": "/"' \
    "$(printf '%s\n' "$CD" | grep -A1 '"match": {' | tail -1 | sed 's/^ *//')"
  summary
}

# The committed config with route 11 (the catch-all) cut out and pasted as the
# first route. Generated from the real file rather than kept as a second copy,
# so the experiment can never drift from the config it is about.
catchall_first() {
  awk '
    /# 11\. CATCH-ALL/      { grab = 1 }
    grab && /http_filters:/ { grab = 0 }
    grab                    { block = block $0 "\n"; next }
                            { line[++n] = $0 }
    END { for (i = 1; i <= n; i++) { print line[i]; if (line[i] ~ /^ *routes:$/) printf "\n%s", block } }
  ' manifests/10-envoy-config.yaml
}

# The config is mounted with subPath, and subPath mounts never receive
# ConfigMap updates - a running Envoy keeps the file it started with. Only a
# new pod reads the new config, so delete the pod rather than wait for a sync
# that will not come.
recreate_envoy() {
  $KUBE delete pod -n "$NS" -l app=envoy --wait=true >/dev/null
  wait_ready envoy
  wait_upstream echo_service
  wait_upstream slow_service
}

restore() {
  say "restoring the committed route order"
  $KUBE apply -n "$NS" -f manifests/10-envoy-config.yaml >/dev/null
  recreate_envoy
}

# The experiment behind this module's central claim: first match wins, so a
# catch-all placed first swallows every request. Envoy accepts the config and
# logs no warning, which is why it is measured here rather than asserted.
shadow() {
  say "moving the catch-all to the top of the route list"
  trap restore EXIT
  catchall_first | $KUBE apply -n "$NS" -f - >/dev/null
  recreate_envoy

  say "every route above it is now dead"
  assert "/exact"                 "catch-all" "$(route_of /exact)"
  assert "/order/42"              "catch-all" "$(route_of /order/42)"
  assert "/ with x-canary: yes"   "catch-all" "$(route_of / -H 'x-canary: yes')"
  assert "/anything?debug=1"      "catch-all" "$(route_of '/anything?debug=1')"
  assert "/api/v1/thing"          "catch-all" "$(route_of /api/v1/thing)"
  assert "/user/42/profile"       "catch-all" "$(route_of /user/42/profile)"
  assert "/rewrite-host"          "catch-all" "$(route_of /rewrite-host)"
  assert "/slow (no longer 504s)" "catch-all" "$(route_of /slow)"
  assert "/patient"               "catch-all" "$(route_of /patient)"
  assert "/budget"                "catch-all" "$(route_of /budget)"
  assert "/old (no longer 301s)"  "catch-all" "$(route_of /old)"
  assert "/healthz (now proxied)" "catch-all" "$(route_of /healthz)"

  restore
  trap - EXIT
  assert "after restoring, /exact matches its own route again" "exact-path" "$(route_of /exact)"
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; shadow) shadow ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
