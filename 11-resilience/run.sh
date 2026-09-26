#!/usr/bin/env bash
# Module 11 — resilience: retries, outlier detection, circuit breaking.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-11
. ../_shared/lib.sh

deploy() {
  say "deploying into $NS"
  ns_ensure
  $KUBE apply -n "$NS" -f ../_shared/echo-app.yaml -f manifests/ >/dev/null
  wait_ready echo; wait_ready sick; wait_ready slow; wait_ready envoy
  wait_upstream pool
  ok "echo (2), sick, slow and envoy are up"
}

# A new Envoy starts with no outlier ejections and empty counters, so each
# experiment below begins from a known state.
restart_envoy() {
  $KUBE delete pod -n "$NS" -l app=envoy --wait=true >/dev/null
  wait_ready envoy
  wait_upstream pool
}
# codes <path> <n> - "count×code" for n requests.
codes() {
  incluster_sh "for i in \$(seq 1 $2); do curl -s -o /dev/null -w '%{http_code}\n' http://envoy:8080$1; done" \
    | sort | uniq -c | awk '{ printf "%s×%s ", $1, $2 }' | sed 's/ $//'
}
count() { printf '%s\n' "$1" | tr ' ' '\n' | awk -F'×' -v c="$2" '$2 == c { print $1 }'; }
stat() {
  incluster_curl "http://envoy.$NS.svc:9901/stats?filter=^$1\$" | awk -F': ' '{ print $2 }'
}

verify() {
  client_ready
  restart_envoy

  say "1. no defence: the sick pod's share of requests fails"
  C=$(codes /none 90)
  assert "some requests fail" "yes" "$([ "$(count "$C" 503)" -gt 0 ] 2>/dev/null && echo yes || echo no)"

  say "2. retries"
  # previous_hosts lowers the odds of retrying on the sick pod to 1 in 81; it
  # does not make them zero (see the config), so neither check demands 180 of
  # 180. Over 180 requests /retry fails about 20 times and /retry-elsewhere
  # about once; more than 6 happens once in 86,000 runs. "Fewer than /retry"
  # alone would pass almost half the time with a predicate that does nothing.
  R=$(count "$(codes /retry 180)" 503); E=$(count "$(codes /retry-elsewhere 180)" 503)
  echo "  503s in 180 requests: /retry ${R:-0}, /retry-elsewhere ${E:-0}"
  assert "retrying on another host fails less often than a plain retry" "yes" \
    "$([ "${E:-0}" -lt "${R:-0}" ] && echo yes || echo no)"
  assert "retrying on another host fails at most 6 times in 180" "yes" \
    "$([ "${E:-0}" -le 6 ] && echo yes || echo no)"
  # Every response carries the header; a retried one says 2. Over 30 requests,
  # none retried is (2/3)^30 - about 5 in a million.
  assert_contains "a retried response says x-envoy-attempt-count: 2" "x-envoy-attempt-count: 2" \
    "$(incluster_sh "for i in \$(seq 1 30); do curl -s -o /dev/null -D - http://envoy:8080/retry-elsewhere; done")"
  assert "retries were counted" "yes" \
    "$([ "$(stat 'cluster\.pool\.upstream_rq_retry')" -gt 0 ] && echo yes || echo no)"

  say "3. outlier detection ejects the sick pod"
  codes /ejecting 30 >/dev/null
  assert "one host ejected" "1" "$(stat 'cluster\.pool_outlier\.outlier_detection\.ejections_active')"
  assert "after the ejection, 30 of 30 succeed" "30×200" "$(codes /ejecting 30)"

  say "4. the circuit breaker refuses the overflow"
  # One line per request: "<code> <seconds>".
  B=$(incluster_sh "seq 1 10 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://envoy:8080/slow")
  OK=$(printf '%s\n' "$B" | awk '$1 == 200' | wc -l | tr -d ' ')
  REFUSED=$(printf '%s\n' "$B" | awk '$1 == 503' | wc -l | tr -d ' ')
  SLOWEST_REFUSAL=$(printf '%s\n' "$B" | awk '$1 == 503 && $2 > m { m = $2 } END { print m + 0 }')
  echo "  10 at once: $OK answered, $REFUSED refused, the slowest refusal in ${SLOWEST_REFUSAL}s"
  # max_requests 2 in flight. A request waiting for a connection is refused when
  # it gets one, because 2 are still in flight (README step 7). Worker threads
  # check the shared count and then increment it, with no lock between, so a
  # race can let a third or fourth request through.
  assert "2 to 4 answered (max_requests 2, and worker threads can race past it)" "yes" \
    "$([ "$OK" -ge 2 ] && [ "$OK" -le 4 ] && echo yes || echo no)"
  assert "the other requests were refused with 503" "10" "$((OK + REFUSED))"
  assert "every refusal came back at once, not after the app's 1 s" "yes" \
    "$(awk -v t="$SLOWEST_REFUSAL" 'BEGIN { print (t < 0.5) ? "yes" : "no" }')"
  # Each refusal lands in one of two counters, depending on whether the request
  # was still waiting for a connection (pending) or had one (active).
  OVERFLOW=$(( $(stat 'cluster\.slow_limited\.upstream_rq_pending_overflow') + $(stat 'cluster\.slow_limited\.upstream_rq_active_overflow') ))
  assert "Envoy counted every refusal as an overflow" "$REFUSED" "$OVERFLOW"
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
