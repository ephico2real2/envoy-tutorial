#!/usr/bin/env bash
# Module 10 — observability: metrics, access logs, traces.  ./run.sh deploy | verify | clean
cd "$(dirname "$0")"
NS=envoy-10
. ../_shared/lib.sh

deploy() {
  say "deploying into $NS"
  ns_ensure
  $KUBE apply -n "$NS" -f ../_shared/echo-app.yaml -f manifests/ >/dev/null
  wait_ready echo; wait_ready slow; wait_ready zipkin; wait_ready envoy; wait_ready traffic
  # Everything starts at once here, so Envoy can look a backend up before it is
  # ready and answer UH until its next DNS refresh. Wait until every cluster that
  # verify expects to have an endpoint (all but down) has one.
  wait_upstream echo; wait_upstream slow; wait_upstream refused
  ok "echo, slow, zipkin, envoy and traffic are up"
}

# Retry a check until it passes or <seconds> run out. The access log reaches
# stdout in 10 s batches, spans reach Zipkin in batches, and Prometheus reads a
# new ServiceMonitor only at its next config reload - a check made the moment
# after deploy fails on a system that is fine.
eventually() {
  local deadline=$((SECONDS + $1)); shift
  until "$@"; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 5
  done
}

# One request of verify's own, carrying a B3 trace id chosen here. Envoy continues
# the caller's trace, so the id finds exactly this request's log line and span -
# the newest line for a path can be one from before the upstreams resolved.
send() {
  local tid
  tid=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  incluster_curl -o /dev/null -H "x-b3-traceid: $tid" -H "x-b3-spanid: $tid" \
    -H "x-b3-sampled: 1" "http://envoy.$NS.svc:8080$1"
  echo "$tid"
}
# Whether the admin port's Prometheus page shows <text> yet.
stats_have() { incluster_curl "http://envoy.$NS.svc:9901/stats/prometheus" | grep -qF "$1"; }
# The access-log line of one trace id; fails until Envoy has flushed it.
logline() { $KUBE logs -n "$NS" deploy/envoy --tail=2000 | grep -F "\"trace_id\":\"$1\""; }
# The Zipkin trace of one trace id, and whether it shows <text> yet.
span() { incluster_curl "http://zipkin.$NS.svc:9411/api/v2/trace/$1"; }
span_has() { span "$1" | grep -qF "$2"; }

# A bearer token for Thanos's tenancy port, which answers for one namespace to
# anyone allowed to get pods.metrics.k8s.io there - as the view role is. The
# reader's own token when the login has one (oc login). A client-certificate
# login, such as the CRC kubeconfig lib.sh falls back to, has none: then a
# short-lived token for a ServiceAccount that may only view $NS.
thanos_token() {
  $KUBE whoami -t 2>/dev/null && return 0
  $KUBE get serviceaccount metrics-reader -n "$NS" >/dev/null 2>&1 \
    || $KUBE create serviceaccount metrics-reader -n "$NS" >/dev/null
  $KUBE get rolebinding metrics-reader-view -n "$NS" >/dev/null 2>&1 \
    || $KUBE create rolebinding metrics-reader-view -n "$NS" --clusterrole=view \
         --serviceaccount="$NS:metrics-reader" >/dev/null
  $KUBE create token metrics-reader -n "$NS" --duration=10m
}

# One PromQL query through Thanos's tenancy port - namespace-scoped, trusting the
# service CA OpenShift mounts in every pod. The token reaches curl on stdin
# (-H @-): as an argument it would travel in the exec request's URL, which the
# API server's audit log records.
promql() {
  printf 'Authorization: Bearer %s\n' "$TOKEN" \
    | $KUBE exec -i -n "$NS" client -- curl -sS --max-time 10 \
        --cacert /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt -H @- \
        --data-urlencode "namespace=$NS" --data-urlencode "query=$1" \
        -G https://thanos-querier.openshift-monitoring.svc:9092/api/v1/query 2>/dev/null
}
# Whether a PromQL answer shows <text> yet.
promql_has() { promql "$1" | grep -qF "$2"; }

verify() {
  client_ready

  say "1. Envoy's own counters, from the admin port"
  # Envoy creates a histogram with its first value, so a proxy that has not
  # served echo yet has none to show: send echo a request of verify's own first.
  send / >/dev/null
  eventually 15 stats_have 'envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name="echo"'
  P=$(incluster_curl "http://envoy.$NS.svc:9901/stats/prometheus")
  assert_contains "Prometheus format on /stats/prometheus" 'envoy_http_downstream_rq_xx{envoy_response_code_class="2",envoy_http_conn_manager_prefix="ingress"}' "$P"
  assert_contains "a latency histogram for the echo cluster" 'envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name="echo"' "$P"

  say "2. every outcome, named in the access log"
  sent=""
  for pair in "/:-:200" "/slow:UT:504" "/down:UH:503" "/refused:UF:503" "/nowhere:NR:404"; do
    sent="$sent $pair:$(send "${pair%%:*}")"
  done
  # The lines share one buffer, flushed every 10 s: once the last request's line
  # is out, so are the others.
  eventually 30 logline "${sent##*:}" >/dev/null
  down=""
  for entry in $sent; do
    path=${entry%%:*}; rest=${entry#*:}; flag=${rest%%:*}; rest=${rest#*:}
    code=${rest%%:*}; tid=${rest#*:}
    L=$(logline "$tid")
    assert_contains "$path -> $code" "\"code\":$code" "$L"
    assert_contains "$path -> flag $flag" "\"flags\":\"$flag\"" "$L"
    if [ "$path" = /down ]; then down=$tid; fi
  done

  say "3. a log line leads to its trace"
  eventually 20 span_has "$down" '"response_flags":"UH"'
  assert_contains "the trace for a /down request is in Zipkin, flagged UH" '"response_flags":"UH"' "$(span "$down")"

  if $KUBE get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    say "4. OpenShift's monitoring scrapes it"
    TOKEN=$(thanos_token)
    # This run's Envoy pods only: a pod from an earlier run stays in range
    # queries such as rate(...[5m]) until its samples age out of the window.
    # And a recent sample only: a target whose job Prometheus dropped before
    # marking it stale answers instant queries with its last sample for 5 min.
    # (timestamp() of a bare selector is the sample's time; of `up == 1` it
    # would be the query's.)
    pods=$($KUBE get pods -n "$NS" -l app=envoy -o jsonpath='{.items[*].metadata.name}' | tr ' ' '|')
    sel="up{job=\"envoy\",pod=~\"$pods\"}"
    up="$sel == 1 and timestamp($sel) > time() - 60"
    rates="sum by (envoy_response_code_class) (rate(envoy_http_downstream_rq_xx{envoy_http_conn_manager_prefix=\"ingress\",pod=~\"$pods\"}[2m]))"
    if ! promql_has "$up" '"value":['; then
      printf '  · waiting for Prometheus to scrape %s - a new ServiceMonitor is read at its next config reload\n' "${pods//|/, }"
      eventually 420 promql_has "$up" '"value":['
    fi
    assert_contains "the envoy target is up" '"value":[' "$(promql "$up")"
    eventually 60 promql_has "$rates" '"envoy_response_code_class":"5"'
    assert_contains "request rates by response class are queryable" '"envoy_response_code_class":"5"' "$(promql "$rates")"
  fi
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
