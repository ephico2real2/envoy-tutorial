# Installing Envoy Gateway on OpenShift 4.19+

Verified end to end on **OpenShift 4.22.7** (CRC) with **Envoy Gateway v1.9.1**.
Every command and every error on this page was run on a real cluster; the output
is pasted, not paraphrased.

Read [`README.md`](README.md) first if you have not — it explains the two CRD
groups, which is the whole reason this page differs from
[`kubernetes.md`](kubernetes.md).

---

## The two differences, up front

1. **Do not install the Gateway API CRDs.** The Ingress Operator owns them.
2. **Do not accept the chart's default UIDs.** `restricted-v2` will reject them.

Everything else is identical to any other Kubernetes cluster.

## Step 0 — confirm what the platform already gives you

```bash
oc get crd | grep gateway.networking.k8s.io
oc get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'
```

On the verified cluster:

```text
backendtlspolicies.gateway.networking.k8s.io
gatewayclasses.gateway.networking.k8s.io
gateways.gateway.networking.k8s.io
grpcroutes.gateway.networking.k8s.io
httproutes.gateway.networking.k8s.io
referencegrants.gateway.networking.k8s.io
v1.4.1
```

**Check `backendtlspolicies` is in that list.** Envoy Gateway watches it, and on
clusters whose Ingress-Operator bundle omits it, older Envoy Gateway builds
crash-loop. v1.9.1 makes the watch conditional, but confirming beats debugging.

### Proof that you must not install them yourself

Try the modification any third-party CRD bundle would make:

```bash
oc label crd gateways.gateway.networking.k8s.io test=1 --dry-run=server
```
```text
Error from server (Forbidden): customresourcedefinitions.apiextensions.k8s.io
"gateways.gateway.networking.k8s.io" is forbidden: ValidatingAdmissionPolicy
'openshift-ingress-operator-gatewayapi-crd-admission' with binding
'openshift-ingress-operator-gatewayapi-crd-admission' denied request:
Gateway API Custom Resource Definitions are managed by the Ingress Operator
and may not be modified
```

That was run as `system:admin`. It is a `ValidatingAdmissionPolicy`, not RBAC —
no amount of privilege gets past it. This is why the default `helm install` from
the quickstart fails here, and why the next step exists.

## Step 1 — install ONLY Envoy Gateway's own CRDs

```bash
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.9.1 \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | oc apply --server-side -f -
```

`crds.gatewayAPI.enabled=false` is the whole trick. Verified output:

```text
customresourcedefinition.apiextensions.k8s.io/backends.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/backendtrafficpolicies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/clienttrafficpolicies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/envoyextensionpolicies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/envoypatchpolicies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/envoyproxies.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/httproutefilters.gateway.envoyproxy.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/securitypolicies.gateway.envoyproxy.io serverside-applied
```

Eight CRDs, all `gateway.envoyproxy.io`, no admission complaint. `--server-side`
matters: these schemas are large enough to exceed the client-side last-applied
annotation limit.

## Step 2 — the SCC problem, and the fix

Installing the controller with chart defaults **fails**:

```text
Error: INSTALLATION FAILED: failed pre-install: resource
Job/envoy-gateway-system/eg-gateway-helm-certgen not ready.
status: InProgress, message: Job in progress
```

That message is misleading — the Job is not slow, its pod was never admitted:

```bash
oc get events -n envoy-gateway-system --sort-by=.lastTimestamp | tail -3
```
```text
Warning FailedCreate job/eg-gateway-helm-certgen Error creating:
pods "eg-gateway-helm-certgen-" is forbidden: unable to validate against any
security context constraint:
  provider restricted-v2: .spec.securityContext.fsGroup: Invalid value: [65532]:
    65532 is not an allowed group,
  provider restricted-v2: .containers[0].runAsUser: Invalid value: 65532:
    must be in the ranges: [1001110000, 1001119999]
```

**Why.** OpenShift assigns each namespace a UID range and `restricted-v2`
requires pods to run inside it:

```bash
oc get ns envoy-gateway-system \
  -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}'
# 1001110000/10000
```

The chart hard-codes `65532` — a sensible upstream default, outside every
OpenShift range. Note it hits the **certgen Job first**, during `pre-install`, so
the controller never even starts.

**The fix: remove the UIDs and let OpenShift assign them.** Helm treats an
explicit `null` as "delete this key", so a values file can strip them:

```yaml
# openshift-values.yaml
deployment:
  pod:
    securityContext:
      runAsUser: null
      runAsGroup: null
      fsGroup: null
  envoyGateway:
    securityContext:
      runAsUser: null
      runAsGroup: null
certgen:
  job:
    pod:
      securityContext:
        runAsUser: null
        runAsGroup: null
        fsGroup: null
    securityContext:
      runAsUser: null
      runAsGroup: null
```

`runAsNonRoot: true` and the `seccompProfile` are deliberately **kept**. We are
not weakening the pod — we are declining to pin a specific UID so the platform
can pick a compliant one. Granting `anyuid` would also "work" and is strictly
worse: it permits root.

## Step 3 — install the controller

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 \
  -n envoy-gateway-system --create-namespace \
  --set crds.enabled=false \
  -f openshift-values.yaml
```

`crds.enabled=false` stops the chart re-applying any CRDs — step 1 handled them.

```bash
oc wait --timeout=5m -n envoy-gateway-system \
  deploy/envoy-gateway --for=condition=Available
```

Verified result:

```text
deployment.apps/envoy-gateway condition met

eg-gateway-helm-certgen-ncq5g    0/1   Completed   0   13s
envoy-gateway-7df8d8b4d9-tp6pr   1/1   Running     0    7s
```

And the UID OpenShift chose, inside the namespace range rather than 65532:

```bash
oc get pod -n envoy-gateway-system -l control-plane=envoy-gateway \
  -o jsonpath='runAsUser={.items[0].spec.containers[0].securityContext.runAsUser}{"\n"}'
# runAsUser=1001110000
```

## Step 4 — the same Gateway resources as anywhere else

From here nothing is OpenShift-specific. That is the point of a standard API.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

`controllerName` must be exactly that string. OpenShift's own Gateway controller
answers to `openshift.io/gateway-controller/v1` and **ignores** anything else, so
the two implementations coexist without fighting.

> The proxy pods a `Gateway` creates hit the same SCC rule. If they are refused,
> patch them with the `EnvoyProxy` CRD (`gateway.envoyproxy.io/v1alpha1`)
> referenced from `spec.infrastructure.parametersRef` on the Gateway — the same
> "do not pin a UID" idea, applied to the data plane.

## Uninstall

```bash
helm uninstall eg -n envoy-gateway-system
oc delete namespace envoy-gateway-system

# Envoy Gateway's own CRDs only. NEVER delete the gateway.networking.k8s.io
# ones - they belong to the platform and other workloads may use them.
oc get crd -o name | grep gateway.envoyproxy.io | xargs -r oc delete
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Forbidden ... may not be modified` on a CRD | tried to install the Gateway API CRDs | use `crds.gatewayAPI.enabled=false`; the platform owns them |
| `failed pre-install: Job ... not ready` | certgen pod refused by SCC | the `null` values file in step 2 |
| `runAsUser: Invalid value: 65532` | chart default UID outside the namespace range | same |
| Controller crash-loops mentioning `BackendTLSPolicy` | platform CRD bundle lacks it | confirm step 0; upgrade Envoy Gateway |
| `GatewayClass` never `Accepted` | wrong `controllerName` | exactly `gateway.envoyproxy.io/gatewayclass-controller` |
| Gateway address empty | no LoadBalancer | MetalLB, or use a Route to the generated Service |

## What was verified, and when

| | |
|---|---|
| Cluster | OpenShift 4.22.7 (CRC) |
| Gateway API | v1.4.1, `standard` channel, Ingress-Operator managed |
| Envoy Gateway | v1.9.1 via Helm v4.3.0 |
| Namespace UID range | `1001110000/10000` |
| Assigned UID | `1001110000` |
| Date | 2026-09-24 |

## References

- [Envoy Gateway — Install with Helm](https://gateway.envoyproxy.io/docs/install/install-helm/)
- [Envoy Gateway — CRDs Helm chart](https://gateway.envoyproxy.io/docs/install/gateway-crds-helm-api/)
- [Envoy Gateway — Customize EnvoyProxy](https://gateway.envoyproxy.io/docs/tasks/operations/customize-envoyproxy/)
- [OpenShift 4.22 — Configuring Gateway API](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/configuring-gateway-api)
- [OpenShift — Managing security context constraints](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/authentication_and_authorization/managing-pod-security-policies)
