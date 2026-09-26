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
  wait_upstream echo
  ok "echo, slow, zipkin, envoy and traffic are up"
}

# One PromQL query through Thanos's tenancy port - namespace-scoped, with the
# caller's own token, trusting the service CA OpenShift mounts in every pod.
promql() {
  incluster_curl --cacert /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt \
    -H "Authorization: Bearer $($KUBE whoami -t)" --data-urlencode "namespace=$NS" \
    --data-urlencode "query=$1" -G https://thanos-querier.openshift-monitoring.svc:9092/api/v1/query
}
# The access-log line for a path, most recent first.
logline() { $KUBE logs -n "$NS" deploy/envoy --tail=300 | grep -F "\"path\":\"$1\"" | tail -1; }

verify() {
  client_ready

  say "1. Envoy's own counters, from the admin port"
  P=$(incluster_curl "http://envoy.$NS.svc:9901/stats/prometheus")
  assert_contains "Prometheus format on /stats/prometheus" 'envoy_http_downstream_rq_xx{envoy_response_code_class="2",envoy_http_conn_manager_prefix="ingress"}' "$P"
  assert_contains "a latency histogram per cluster" 'envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name="echo"' "$P"

  say "2. every outcome, named in the access log"
  for pair in "/:-:200" "/slow:UT:504" "/down:UH:503" "/refused:UF:503" "/nowhere:NR:404"; do
    path=${pair%%:*}; rest=${pair#*:}; flag=${rest%%:*}; code=${rest#*:}
    L=$(logline "$path")
    assert_contains "$path -> $code" "\"code\":$code" "$L"
    assert_contains "$path -> flag $flag" "\"flags\":\"$flag\"" "$L"
  done

  say "3. a log line leads to its trace"
  TID=$(logline /down | sed 's/.*"trace_id":"\([0-9a-f]*\)".*/\1/')
  assert_contains "the trace for a /down request is in Zipkin, flagged UH" '"response_flags":"UH"' \
    "$(incluster_curl "http://zipkin.$NS.svc:9411/api/v2/trace/$TID")"

  if $KUBE get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    say "4. OpenShift's monitoring scrapes it"
    assert_contains "the envoy target is up" '"value":[' "$(promql 'up{job="envoy"} == 1')"
    assert_contains "request rates by response class are queryable" '"envoy_response_code_class":"5"' \
      "$(promql 'sum by (envoy_response_code_class) (rate(envoy_http_downstream_rq_xx{envoy_http_conn_manager_prefix="ingress"}[5m]))')"
  fi
  summary
}

clean() { $KUBE delete ns "$NS" --wait=false >/dev/null 2>&1; ok "namespace $NS deleting"; }

case "${1:-deploy}" in
  deploy) deploy ;; verify) verify ;; clean) clean ;;
  *) sed -n '2p' "$0" | sed 's/^# //'; exit 2 ;;
esac
