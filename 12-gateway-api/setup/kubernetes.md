# Installing Envoy Gateway on Kubernetes

For kind, minikube, k3s, EKS, GKE, AKS — and OpenShift **4.18 or older**, where
the platform does not yet manage the Gateway API CRDs.

If you are on **OpenShift 4.19 or later**, stop and use
[`openshift.md`](openshift.md) instead. This page will fail there, on purpose —
see [`README.md`](README.md).

---

## What this installs

Two things, and it is worth knowing which is which:

1. **The Gateway API CRDs** (`gateway.networking.k8s.io`) — the vendor-neutral
   standard. Not part of Kubernetes; somebody has to install them, and here that
   is you.
2. **Envoy Gateway** — the controller that watches those resources and runs
   Envoy, plus its own `gateway.envoyproxy.io` CRDs.

## Prerequisites

| Need | Why | Check |
|---|---|---|
| Kubernetes v1.29+ | Envoy Gateway v1.9's floor | `kubectl version` |
| Helm v3.8+ | OCI registry support, which the chart is published to | `helm version` |
| A LoadBalancer implementation | a `Gateway` asks for one; without it the Service stays `<pending>` | see below |
| Cluster-admin | installing CRDs is cluster-scoped | `kubectl auth can-i create crd` |

On a local cluster with no cloud load balancer, install MetalLB (or use
`kubectl port-forward` for a quick look). A `Gateway` with no LoadBalancer just
sits `<pending>` — that is not an Envoy Gateway fault.

## Install

One command, because the chart brings both CRD sets:

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 \
  -n envoy-gateway-system --create-namespace
```

Wait for it:

```bash
kubectl wait --timeout=5m -n envoy-gateway-system \
  deployment/envoy-gateway --for=condition=Available
```

### Verify

```bash
# the controller
kubectl get deploy -n envoy-gateway-system

# both CRD groups are now present
kubectl get crd | grep -E 'gateway\.networking\.k8s\.io|gateway\.envoyproxy\.io'
```

You should see the standard kinds (`gateways`, `gatewayclasses`, `httproutes`,
`grpcroutes`, `referencegrants`) **and** Envoy Gateway's own (`envoyproxies`,
`clienttrafficpolicies`, `backendtrafficpolicies`, `securitypolicies`,
`envoypatchpolicies`, `backends`).

## A first Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  # The exact string Envoy Gateway watches for. A controller ignores any
  # GatewayClass that does not name it, which is how several controllers
  # coexist on one cluster.
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
```

Creating the `Gateway` makes Envoy Gateway deploy **an Envoy pod and a Service**
in `envoy-gateway-system`, named after the Gateway that owns it.

```bash
# the generated Service, found by its ownership labels rather than a guessed name
kubectl get svc -n envoy-gateway-system \
  --selector=gateway.envoyproxy.io/owning-gateway-namespace=default,gateway.envoyproxy.io/owning-gateway-name=eg

# the address to call
kubectl get gateway/eg -o jsonpath='{.status.addresses[0].value}{"\n"}'
```

## Uninstall

```bash
helm uninstall eg -n envoy-gateway-system
kubectl delete namespace envoy-gateway-system
```

Helm does **not** delete CRDs on uninstall — deliberate, because deleting a CRD
deletes every object of that kind. Remove them only if you mean it:

```bash
kubectl get crd | grep gateway.envoyproxy.io | awk '{print $1}' | xargs kubectl delete crd
```

## Advanced: separating CRDs from the controller

The one-command install is fine for a tutorial cluster. In a real one you often
want CRDs managed separately from the release — different RBAC, different
change windows, and CRDs surviving a `helm uninstall`.

```bash
# CRDs on their own, applied server-side so large schemas do not hit the
# last-applied annotation size limit
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.9.1 \
  --set crds.gatewayAPI.enabled=true \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -

# then the controller, told not to touch CRDs
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 \
  -n envoy-gateway-system --create-namespace \
  --set crds.enabled=false
```

Those two toggles are the whole difference between this page and the OpenShift
one. There, `crds.gatewayAPI.enabled` is `false` because the platform already
owns that half.

## Troubleshooting

**`Gateway` address stays empty / Service `<pending>`** — no LoadBalancer
implementation. Install MetalLB, or port-forward the generated Service.

**`GatewayClass` never becomes `Accepted`** — the `controllerName` does not
match. It must be exactly `gateway.envoyproxy.io/gatewayclass-controller`.
Check with `kubectl get gatewayclass eg -o yaml` and read `status.conditions`.

**`HTTPRoute` not taking effect** — check `status.parents[].conditions` on the
route. `ResolvedRefs=False` usually means the backend Service does not exist or
is in another namespace without a `ReferenceGrant`.

**CRDs already exist and Helm refuses** — something else installed the Gateway
API (another controller, or the platform). Use the separated form above with
`crds.gatewayAPI.enabled=false`, and confirm the existing bundle version is
compatible.

## References

- [Envoy Gateway — Install with Helm](https://gateway.envoyproxy.io/docs/install/install-helm/)
- [Envoy Gateway — Quickstart](https://gateway.envoyproxy.io/docs/tasks/quickstart/)
- [Gateway API — Introduction](https://gateway-api.sigs.k8s.io/)
- [MetalLB installation](https://metallb.universe.tf/installation/)
