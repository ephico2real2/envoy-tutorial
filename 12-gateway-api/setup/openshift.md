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

## Step 4 — a Gateway, and the two things that block it

The controller running is not the same as a Gateway working. Both of the
following bit on a real cluster, and neither is mentioned in the upstream docs.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:                      # how the proxy's pod spec is customised
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: openshift-scc
    namespace: envoy-gateway-system
```

`controllerName` must be exactly that string. OpenShift's own controller answers
to `openshift.io/gateway-controller/v1` and ignores anything else, so the two
coexist. Verified: `accepted=True reason=Accepted`.

### Blocker 1 — the proxy pod, again, and the Helm fix does not reach it

Envoy Gateway **generates** the proxy Deployment, so there is no YAML to edit.
The `EnvoyProxy` resource is the supported way in, and the pod-level fix works:

```yaml
envoyDeployment:
  pod:
    securityContext:
      runAsNonRoot: true
      seccompProfile: { type: RuntimeDefault }
```

```console
$ oc get deploy envoy-gwapi-demo-eg-... -o jsonpath='{.spec.template.spec.securityContext}'
pod.runAsUser=      pod.fsGroup=      pod.runAsNonRoot=true      # cleared
```

**But the containers keep theirs**, and the pod is still refused:

```text
restricted-v2: .containers[0].runAsUser: Invalid value: 65532  (envoy)
restricted-v2: .containers[1].runAsUser: Invalid value: 65532  (shutdown-manager)
```

`shutdown-manager`'s security context is hardcoded upstream
([envoyproxy/gateway#4881](https://github.com/envoyproxy/gateway/issues/4881)),
so no amount of `EnvoyProxy` tuning clears it.

**The fix is an SCC grant, and `nonroot-v2` is the right one.** It permits a
specific non-root UID while still forbidding root — unlike `anyuid`:

```console
$ oc get scc nonroot-v2 -o jsonpath='{.runAsUser.type} {.allowPrivilegeEscalation}'
MustRunAsNonRoot false          # a non-root uid is fine; root is not
$ oc get scc anyuid     -o jsonpath='{.runAsUser.type} {.allowPrivilegeEscalation}'
RunAsAny true                   # permits root. Do not reach for this.
```

```bash
SA=$(oc get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg \
      -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}')
oc adm policy add-scc-to-user nonroot-v2 -z "$SA" -n envoy-gateway-system
oc rollout restart deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg
```

```text
envoy-gwapi-demo-eg-8fbae7fe-6cfd6b4bbc-kxl7m   2/2   Running
```

The grant is per-Gateway, because each Gateway gets its own ServiceAccount.

### Blocker 2 — "no available IPs" does not mean the pool is full

With the proxy running, the Gateway was still not programmed:

```text
Accepted=True    The Gateway has been scheduled by Envoy Gateway
Programmed=False AddressNotAssigned: No addresses have been assigned
```
```text
Warning AllocationFailed service/envoy-...  Failed to allocate IP: no available IPs
```

The pool had 20 free addresses. The real cause:

```console
$ oc get ipaddresspool -A -o custom-columns=NAME:.metadata.name,AUTO:.spec.autoAssign
NAME          AUTO
mongot-pool   false
```

**`autoAssign: false` means the pool never volunteers.** A Service must name it.
Read the message as "no pool volunteered", not "no addresses left".

```yaml
envoyService:
  type: LoadBalancer
  annotations:
    metallb.universe.tf/address-pool: mongot-pool
```

```text
LoadBalancer IP: 192.168.127.101
programmed=True  address=192.168.127.101
```

### Proof it carries traffic

```console
$ curl -s http://192.168.127.101/hello
{
  "served_by": "echo-f8fc6d5c9-qnx4z",
  "method": "GET",
  "path": "/hello",
  "headers": {
    "host": "192.168.127.101",
    "x-forwarded-for": "10.217.0.150",
    "x-forwarded-proto": "http",
    "x-envoy-external-address": "10.217.0.150",
    "x-request-id": "a9e3262e-13c8-419c-8fc0-5f1fd129ead2"
  }
}
```

The `x-envoy-*` headers and `x-request-id` are Envoy's fingerprint — the backend
never set them. And it balances:

```console
$ for i in $(seq 1 10); do curl -s http://192.168.127.101/ | grep served_by; done | sort | uniq -c
   4   "served_by": "echo-f8fc6d5c9-jx6lh"
   6   "served_by": "echo-f8fc6d5c9-qnx4z"
```

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
| Gateway address empty, "no available IPs" | the IPAddressPool has `autoAssign: false` | annotate the Service `metallb.universe.tf/address-pool: <pool>` |
| Proxy pod refused, `runAsUser: 65532` | container security contexts are not cleared by `EnvoyProxy`; shutdown-manager's is hardcoded | `oc adm policy add-scc-to-user nonroot-v2 -z <proxy-sa> -n envoy-gateway-system` |

## What was verified, and when

| | |
|---|---|
| Cluster | OpenShift 4.22.7 (CRC) |
| Gateway API | v1.4.1, `standard` channel, Ingress-Operator managed |
| Envoy Gateway | v1.9.1 via Helm v4.3.0 |
| Namespace UID range | `1001110000/10000` |
| Assigned UID | `1001110000` |
| Gateway address | `192.168.127.101` (MetalLB) |
| Date | 2026-09-24 |

## References

- [Envoy Gateway — Install with Helm](https://gateway.envoyproxy.io/docs/install/install-helm/)
- [Envoy Gateway — CRDs Helm chart](https://gateway.envoyproxy.io/docs/install/gateway-crds-helm-api/)
- [Envoy Gateway — Customize EnvoyProxy](https://gateway.envoyproxy.io/docs/tasks/operations/customize-envoyproxy/)
- [OpenShift 4.22 — Configuring Gateway API](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/configuring-gateway-api)
- [OpenShift — Managing security context constraints](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/authentication_and_authorization/managing-pod-security-policies)
