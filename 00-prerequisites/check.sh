#!/usr/bin/env bash
# What this tutorial needs, and whether you have it.  ./check.sh
cd "$(dirname "$0")"
NS=envoy-tut-check
. ../_shared/lib.sh

say "cluster"
SRV=$($KUBE version -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null)
[ -n "$SRV" ] && ok "reachable, server $SRV" || { bad "cannot reach a cluster (KUBECONFIG=$KUBECONFIG)"; exit 1; }
ok "client: $KUBE"

IS_OCP=no
$KUBE api-resources --api-group=security.openshift.io 2>/dev/null | grep -q securitycontextconstraints && IS_OCP=yes
ok "OpenShift: $IS_OCP$([ "$IS_OCP" = yes ] && echo '  (SCC rules apply — modules note where)')"

say "permissions"
for v in "create namespace" "create deployment" "create service" "create configmap"; do
  r=$($KUBE auth can-i $v 2>/dev/null | tail -1)
  assert "can $v" "yes" "$r"
done

say "images the modules pull"
for i in "python:3.12-slim        the echo app" \
         "envoyproxy/envoy:v1.39-latest  the proxy" \
         "curlimages/curl:8.11.1  the in-cluster client" \
         "alpine/openssl:3.3.2    module 03's test certificates"; do
  printf '  · %s\n' "$i"
done
echo "  (all public; nothing is built or pushed by this tutorial)"

say "optional, per module"
have() { $KUBE get crd "$1" >/dev/null 2>&1 && ok "$2" || printf '  · %s — not installed (only module %s needs it)\n' "$2" "$3"; }
have certificates.cert-manager.io "cert-manager"           "08, 09, 12"
have gateways.gateway.networking.k8s.io "Gateway API CRDs" "12"
have ipaddresspools.metallb.io "MetalLB"                   "12"
$KUBE get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 \
  && ok "Prometheus Operator CRDs" || printf '  · %s — not installed (only module %s needs it)\n' "Prometheus Operator CRDs" "10"
# On OpenShift the CRDs are always there; what decides whether YOUR namespaces
# are scraped is user-workload monitoring, a switch in the platform's config.
if [ "$IS_OCP" = yes ]; then
  $KUBE get configmap cluster-monitoring-config -n openshift-monitoring \
      -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -q 'enableUserWorkload: *true' \
    && ok "user-workload monitoring" \
    || printf '  · %s — not enabled, or not readable by you (only module %s needs it)\n' "user-workload monitoring" "10"
fi

say "a real write, end to end"
ns_ensure
# The exact pod every module's walkthrough starts, so a pass here means the
# modules' client will be admitted and its image pulled - not merely that some
# pod could be created.
$KUBE apply -n "$NS" -f ../_shared/client.yaml >/dev/null 2>&1
if $KUBE wait -n "$NS" --for=condition=Ready pod/client --timeout=120s >/dev/null 2>&1; then
  ok "the in-cluster client pod runs — the modules will run"
else
  bad "the client pod from _shared/client.yaml never became ready in $NS"
  # On OpenShift this is usually the namespace uid-range vs an image's baked-in
  # USER. The modules that hit it say so where it happens.
  FAILED=$((FAILED+1))
fi
$KUBE delete ns "$NS" --wait=false >/dev/null 2>&1

summary
