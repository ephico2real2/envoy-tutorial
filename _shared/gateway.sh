# Helpers for the modules that use Envoy Gateway (13, 14). Source after lib.sh,
# which sets $KUBE. Envoy Gateway runs each Gateway's Envoy as a Deployment in
# envoy-gateway-system, labelled with the Gateway's name and namespace.

GW_SYSTEM_NS=envoy-gateway-system

# gw_selector <namespace> <gateway> - the label selector of that Gateway's Envoy.
gw_selector() {
  echo "gateway.envoyproxy.io/owning-gateway-name=$2,gateway.envoyproxy.io/owning-gateway-namespace=$1"
}

# gw_proxy_sa <namespace> <gateway> - the ServiceAccount its Envoy runs as, or
# nothing if the controller has not generated the Deployment yet.
gw_proxy_sa() {
  $KUBE get deploy -n "$GW_SYSTEM_NS" -l "$(gw_selector "$1" "$2")" \
    -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}' 2>/dev/null
}

has_sccs() { $KUBE api-resources --api-group=security.openshift.io 2>/dev/null | grep -q '^securitycontextconstraints'; }

# gw_up <namespace> <gateway> - wait for the generated Envoy and, on OpenShift,
# let it run: grant nonroot-v2 to its ServiceAccount (module 12, step 4) and
# restart it, so a pod is created now rather than after the ReplicaSet's
# back-off. Then wait until the Gateway is Programmed.
gw_up() {
  local sa=
  for _ in $(seq 1 30); do sa=$(gw_proxy_sa "$1" "$2"); [ -n "$sa" ] && break; sleep 2; done
  [ -n "$sa" ] || { bad "Envoy Gateway generated no proxy Deployment for $1/$2"; exit 1; }
  if has_sccs; then
    $KUBE adm policy add-scc-to-user nonroot-v2 -z "$sa" -n "$GW_SYSTEM_NS" >/dev/null
    $KUBE rollout restart deploy -n "$GW_SYSTEM_NS" -l "$(gw_selector "$1" "$2")" >/dev/null
  fi
  $KUBE rollout status deploy -n "$GW_SYSTEM_NS" -l "$(gw_selector "$1" "$2")" --timeout=240s >/dev/null \
    || { bad "the Envoy for $1/$2 never became ready"; exit 1; }
  $KUBE wait "gateway/$2" -n "$1" --for=condition=Programmed --timeout=120s >/dev/null \
    || { bad "Gateway $1/$2 never Programmed - see module 12's Troubleshooting"; exit 1; }
}

# gw_down <namespace> <gateway> - remove the nonroot-v2 grant, before the
# Gateway (and with it the ServiceAccount the grant names) is deleted.
gw_down() {
  local sa; sa=$(gw_proxy_sa "$1" "$2")
  if [ -n "$sa" ] && has_sccs; then
    $KUBE adm policy remove-scc-from-user nonroot-v2 -z "$sa" -n "$GW_SYSTEM_NS" >/dev/null 2>&1
  fi
  return 0
}

# gw_address <namespace> <gateway> - the address the Gateway was given.
gw_address() { $KUBE get "gateway/$2" -n "$1" -o jsonpath='{.status.addresses[0].value}'; }
