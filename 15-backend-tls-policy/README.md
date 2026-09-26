# 15 — BackendTLSPolicy: TLS from the Gateway to the backend

Modules 08 and 12 put TLS where the **client** meets the proxy. The hop after it
— proxy to backend — is often left in plain HTTP "because it is inside the
cluster". Module 09 closed that gap by hand, with an `UpstreamTlsContext` in an
`envoy.yaml`. The Gateway API has a standard resource for it: the
**`BackendTLSPolicy`**. It attaches to a **Service** (not a route) and says: to
reach this port, use TLS, trust this CA, and expect this name.

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/15-backend-tls-policy/outcomes.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/15-backend-tls-policy/outcomes.light.png">
  <img alt="A client sends plain HTTP to the Gateway for /secure; the HTTPRoute sends it to the Service secure-echo, whose pods speak only TLS with a certificate for secure-echo.envoy-15.svc signed by enterprise-ca. A BackendTLSPolicy attaches to that Service. Four measured outcomes: with no policy, the Gateway speaks plain HTTP to the TLS port, the backend logs a failed handshake and the client gets 503. With the right policy, TLS 1.3 with SNI secure-echo.envoy-15.svc and 200. With hostname payments, the SAN check fails, 503, ssl.fail_verify_san. With wellKnownCACertificates System, the chain leads to no trusted CA, 503, ssl.fail_verify_error." src="../docs/diagrams/15-backend-tls-policy/outcomes.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

## What you'll learn

- what happens when a Gateway speaks plain HTTP to a TLS-only backend
- how a `BackendTLSPolicy` makes it speak TLS — and exactly which name it sends
  (SNI) and checks (the certificate's SAN)
- what the Envoy got: module 09's upstream TLS, delivered by the controller
- the two failures that matter — a wrong name and an untrusted CA — and the
  counters that tell them apart

## Before you start

- Module [`12`](../12-gateway-api/README.md) — at least its setup — and module
  [`08`](../08-tls-on-envoy/README.md), for cert-manager and the `enterprise-ca`
  `ClusterIssuer` (`00-prerequisites` reports both).
- Work from this folder: `cd 15-backend-tls-policy`.
- This module uses the namespace **`envoy-15`** and takes about 20 minutes.

## Walkthrough

### Step 1 — a Gateway

As in module 13, step 1:

```console
$ oc apply -f ../12-gateway-api/manifests/20-envoyproxy.yaml -f ../12-gateway-api/manifests/10-gatewayclass.yaml
envoyproxy.gateway.envoyproxy.io/openshift-scc created
gatewayclass.gateway.networking.k8s.io/eg created
$ oc apply -f manifests/10-gateway.yaml
namespace/envoy-15 created
gateway.gateway.networking.k8s.io/eg created
$ sleep 10; oc adm policy add-scc-to-user nonroot-v2 -n envoy-gateway-system -z "$(oc get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-15 -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}')"
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:nonroot-v2 added: "envoy-envoy-15-eg-b2e1d487"
$ oc rollout restart deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-15
deployment.apps/envoy-envoy-15-eg-b2e1d487 restarted
$ oc rollout status deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-15 --timeout=240s
Waiting for deployment "envoy-envoy-15-eg-b2e1d487" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "envoy-envoy-15-eg-b2e1d487" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "envoy-envoy-15-eg-b2e1d487" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-15-eg-b2e1d487" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-15-eg-b2e1d487" rollout to finish: 1 old replicas are pending termination...
deployment "envoy-envoy-15-eg-b2e1d487" successfully rolled out
$ oc wait gateway/eg -n envoy-15 --for=condition=Programmed --timeout=120s
gateway.gateway.networking.k8s.io/eg condition met
```

### Step 2 — the backend's certificate, and the CA to trust

[`manifests/20-certificate.yaml`](manifests/20-certificate.yaml) asks
cert-manager for a certificate for the backend's Service names:

```console
$ oc apply -n envoy-15 -f manifests/20-certificate.yaml
certificate.cert-manager.io/secure-echo-tls created
$ oc wait -n envoy-15 certificate/secure-echo-tls --for=condition=Ready --timeout=120s
certificate.cert-manager.io/secure-echo-tls condition met
$ oc get secret secure-echo-tls -n envoy-15 -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -ext subjectAltName
subject=
issuer=O=Enterprise POC, CN=Enterprise Root CA
X509v3 Subject Alternative Name: critical
    DNS:secure-echo.envoy-15.svc, DNS:secure-echo.envoy-15.svc.cluster.local
```

The certificate names `secure-echo.envoy-15.svc`, and the enterprise CA signed
it. A `BackendTLSPolicy` reads the CA to trust from a **ConfigMap**, under the
key **`ca.crt`**. Copy it out of the Secret cert-manager wrote:

```console
$ oc create configmap enterprise-ca -n envoy-15 --from-literal=ca.crt="$(oc get secret secure-echo-tls -n envoy-15 -o jsonpath='{.data.ca\.crt}' | base64 -d)"
configmap/enterprise-ca created
```

### Step 3 — a TLS-only backend, and a route to it

[`manifests/30-secure-echo.yaml`](manifests/30-secure-echo.yaml) is the echo app
over **TLS only**, on port 8443. It also reports what it saw of each TLS
connection: the version, the cipher, and the name the client asked for (SNI).
[`manifests/40-httproute.yaml`](manifests/40-httproute.yaml) sends `/secure` to
it:

```console
$ oc apply -n envoy-15 -f ../_shared/client.yaml -f manifests/30-secure-echo.yaml -f manifests/40-httproute.yaml
pod/client created
configmap/secure-echo-src created
service/secure-echo created
deployment.apps/secure-echo created
httproute.gateway.networking.k8s.io/secure created
$ oc rollout status -n envoy-15 deploy/secure-echo --timeout=240s
Waiting for deployment "secure-echo" rollout to finish: 0 of 1 updated replicas are available...
deployment "secure-echo" successfully rolled out
$ oc wait -n envoy-15 --for=condition=Ready pod/client --timeout=120s
pod/client condition met
$ sleep 3; oc exec -n envoy-15 client -- curl -s -w '  -> %{http_code}\n' "http://$(oc get gateway eg -n envoy-15 -o jsonpath='{.status.addresses[0].value}')/secure"
upstream connect error or disconnect/reset before headers. reset reason: connection termination  -> 503
$ oc logs -n envoy-15 deploy/secure-echo --tail=20 | grep 'handshake failed' | tail -1
TLS handshake failed from 10.217.1.55: [SSL: HTTP_REQUEST] http request (_ssl.c:1010)
```

**What just happened:** `503`. Nothing in an `HTTPRoute` says "TLS" — it names a
Service and a port — so the Gateway spoke **plain HTTP** to a port that speaks
only TLS. The backend's log says exactly that: the TLS handshake failed because
what arrived was an HTTP request.

### Step 4 — the BackendTLSPolicy

[`manifests/50-backendtlspolicy.yaml`](manifests/50-backendtlspolicy.yaml)
targets the Service `secure-echo`, port `https`, trusts the CA in the ConfigMap
`enterprise-ca`, and expects the name `secure-echo.envoy-15.svc`:

```console
$ oc apply -f manifests/50-backendtlspolicy.yaml
backendtlspolicy.gateway.networking.k8s.io/secure-echo created
$ sleep 5; oc get backendtlspolicy secure-echo -n envoy-15 -o jsonpath='{range .status.ancestors[0].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
ResolvedRefs=True Resolved all the Object references.
Accepted=True Policy has been accepted.
$ oc exec -n envoy-15 client -- curl -s "http://$(oc get gateway eg -n envoy-15 -o jsonpath='{.status.addresses[0].value}')/secure" | python3 -c 'import json,sys; d = json.load(sys.stdin); print(d["served_by"], d["tls"])'
secure-echo-84bd487c8f-cv88r {'version': 'TLSv1.3', 'cipher': 'TLS_AES_256_GCM_SHA384', 'sni': 'secure-echo.envoy-15.svc'}
```

**What just happened:** the policy is accepted, and the backend now answers — over
**TLS 1.3**, and the name the Gateway asked for (SNI) is the policy's
**`hostname`**. The client still spoke plain HTTP to the Gateway; only the hop
behind it changed. Look at what Envoy got:

```console
$ ../_shared/eg-admin.sh envoy-15/eg 'config_dump?resource=dynamic_active_clusters' | python3 -c 'import json,sys; [print(json.dumps({"sni": tc["sni"], "tls_params": tc["common_tls_context"]["tls_params"], "combined_validation_context": tc["common_tls_context"]["combined_validation_context"]}, indent=1)) for c in json.load(sys.stdin)["configs"] if "/secure/" in c["cluster"]["name"] for m in c["cluster"]["transport_socket_matches"] for tc in [m["transport_socket"]["typed_config"]]]'
{
 "sni": "secure-echo.envoy-15.svc",
 "tls_params": {
  "tls_minimum_protocol_version": "TLSv1_2",
  "tls_maximum_protocol_version": "TLSv1_3"
 },
 "combined_validation_context": {
  "default_validation_context": {
   "match_typed_subject_alt_names": [
    {
     "san_type": "DNS",
     "matcher": {
      "exact": "secure-echo.envoy-15.svc"
     }
    }
   ]
  },
  "validation_context_sds_secret_config": {
   "name": "secure-echo/envoy-15-ca",
   "sds_config": {
    "ads": {},
    "resource_api_version": "V3"
   }
  }
 }
}
```

**What just happened:** module 09's upstream TLS, written for you:

| The policy said | Envoy got | Module 09 wrote by hand |
|---|---|---|
| `hostname: secure-echo.envoy-15.svc` | `sni` — the name asked for | `sni` |
| … the same name | `match_typed_subject_alt_names`, `DNS` exact — the name the certificate must carry | `match_typed_subject_alt_names` |
| `caCertificateRefs: enterprise-ca` | the CA, delivered by the controller over **SDS** (`secure-echo/envoy-15-ca`) | `trusted_ca` from a file |
| — | TLS 1.2 to 1.3 | the defaults |

The TLS settings sit in the cluster's `transport_socket_matches` — one per
backend of the route, picked by endpoint — which is how a route with several
backends can use TLS to some and not others.

### Step 5 — the wrong name

[`manifests/55-wrong-hostname.yaml`](manifests/55-wrong-hostname.yaml) is the
same policy expecting `payments.envoy-15.svc`, a name the certificate does not
carry. Changing a policy changes the **cluster**, and a changed cluster takes
about 15 seconds to reach Envoy (module 14, step 4 — measured here too, 15.3 to
15.4 s), so wait before asking:

```console
$ oc apply -f manifests/55-wrong-hostname.yaml
backendtlspolicy.gateway.networking.k8s.io/secure-echo configured
$ sleep 20; oc exec -n envoy-15 client -- curl -s -w '  -> %{http_code}\n' "http://$(oc get gateway eg -n envoy-15 -o jsonpath='{.status.addresses[0].value}')/secure"
upstream connect error or disconnect/reset before headers. reset reason: remote connection failure  -> 503
$ ../_shared/eg-admin.sh envoy-15/eg stats | grep -E '^cluster\.httproute/envoy-15/secure/rule/0\.ssl\.(handshake|fail_verify_san|fail_verify_error):'
cluster.httproute/envoy-15/secure/rule/0.ssl.fail_verify_error: 0
cluster.httproute/envoy-15/secure/rule/0.ssl.fail_verify_san: 1
cluster.httproute/envoy-15/secure/rule/0.ssl.handshake: 1
```

**What just happened:** `503`, `remote connection failure` — the client sees only
that the connection behind the Gateway failed. The Gateway's counters say why:
**`ssl.fail_verify_san`** — the certificate is trusted, but it does not carry
the expected name. The Gateway received the certificate and rejected it; the
backend's log shows the connection cut off mid-handshake
(`UNEXPECTED_EOF_WHILE_READING`).

### Step 6 — the wrong CA

[`manifests/56-system-cas.yaml`](manifests/56-system-cas.yaml) replaces the CA
with **`wellKnownCACertificates: System`** — the public CAs an operating system
ships. They did not sign this certificate:

```console
$ oc apply -f manifests/56-system-cas.yaml
backendtlspolicy.gateway.networking.k8s.io/secure-echo configured
$ sleep 20; oc exec -n envoy-15 client -- curl -s -w '  -> %{http_code}\n' "http://$(oc get gateway eg -n envoy-15 -o jsonpath='{.status.addresses[0].value}')/secure"
upstream connect error or disconnect/reset before headers. reset reason: remote connection failure  -> 503
$ ../_shared/eg-admin.sh envoy-15/eg stats | grep -E '^cluster\.httproute/envoy-15/secure/rule/0\.ssl\.(handshake|fail_verify_san|fail_verify_error):'
cluster.httproute/envoy-15/secure/rule/0.ssl.fail_verify_error: 1
cluster.httproute/envoy-15/secure/rule/0.ssl.fail_verify_san: 1
cluster.httproute/envoy-15/secure/rule/0.ssl.handshake: 1
```

**What just happened:** the same `503` for the client, a different counter:
**`ssl.fail_verify_error`** — the certificate's chain does not lead to a
trusted CA. `System` is right for a backend with a public certificate (an
external API); for an internal CA, name it in `caCertificateRefs`.

Put the right policy back:

```console
$ oc apply -f manifests/50-backendtlspolicy.yaml
backendtlspolicy.gateway.networking.k8s.io/secure-echo configured
$ sleep 20; oc exec -n envoy-15 client -- curl -s -o /dev/null -w '%{http_code}\n' "http://$(oc get gateway eg -n envoy-15 -o jsonpath='{.status.addresses[0].value}')/secure"
200
```

### Step 7 — check yourself

```console
$ ./run.sh verify

1. the policy
  ✓ BackendTLSPolicy Accepted
  ✓ BackendTLSPolicy ResolvedRefs

2. the Gateway reaches the TLS-only backend over TLS
  ✓ the backend answered
  ✓ over TLS 1.3
  ✓ asking for the policy's hostname (SNI)
  ✓ Envoy got: SNI, SAN check and CA from the policy

3. a name the certificate does not carry is refused
  ✓ request -> 503
  ✓ counted as ssl.fail_verify_san

4. a CA that did not sign it is refused
  ✓ request -> 503
  ✓ counted as ssl.fail_verify_error

5. back to the right policy
  ✓ request -> 200

all checks passed
```

## The options

[`BackendTLSPolicy`](https://gateway-api.sigs.k8s.io/reference/api-types/policy/backendtlspolicy/)
(`gateway.networking.k8s.io/v1` — on this cluster, `v1` is served and the older
`v1alpha3` is not):

| Field | Here | What it does |
|---|---|---|
| `targetRefs` | Service `secure-echo`, `sectionName: https` | which Service port the Gateway must reach over TLS — every route to it |
| `validation.caCertificateRefs` | ConfigMap `enterprise-ca`, key `ca.crt` | the CA(s) the backend's certificate must chain to |
| `validation.wellKnownCACertificates` | `System` (step 6) | the platform's public CAs instead — one or the other, not both |
| `validation.hostname` | `secure-echo.envoy-15.svc` | the SNI sent, and the name the certificate must carry |
| `validation.subjectAltNames` | — | check for these names instead of `hostname` — type `Hostname` or `URI` (a SPIFFE ID, module 09) |

What the standard policy does **not** do is present a client certificate — module
09's mutual TLS. Envoy Gateway adds that in its own `EnvoyProxy` resource
([backend mutual TLS](https://gateway.envoyproxy.io/docs/tasks/security/backend-mtls/)).

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| `503` … `connection termination`; the backend logs a handshake failure, `http request` | no `BackendTLSPolicy`: the Gateway speaks plain HTTP to a TLS port (step 3) | add the policy |
| `503` … `remote connection failure`; `ssl.fail_verify_san` rises | the certificate does not carry `hostname` (step 5) | fix `hostname`, or the certificate's `dnsNames` |
| `503` … `remote connection failure`; `ssl.fail_verify_error` rises | the certificate does not chain to the trusted CA (step 6) | reference the CA that signed it |
| `500`, and the policy says `Accepted=False` `NoValidCACertificate`, `ResolvedRefs=False` `InvalidCACertificateRef` | the CA ConfigMap does not exist — measured | create it in the policy's namespace |
| a CA ConfigMap without a `ca.crt` key works | Envoy Gateway v1.9.1 accepted one under another key — measured — though the spec calls it invalid | use `ca.crt`; another implementation will refuse it |
| a changed policy seems ignored | a cluster change takes about 15 s to reach Envoy | wait; read the generated config (step 4) |

## Clean up

```console
$ oc adm policy remove-scc-from-user nonroot-v2 -n envoy-gateway-system -z "$(oc get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-15 -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}')"
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:nonroot-v2 removed: "envoy-envoy-15-eg-b2e1d487"
$ oc delete -f manifests/10-gateway.yaml --wait=false
namespace "envoy-15" deleted
gateway.gateway.networking.k8s.io "eg" deleted from envoy-15 namespace
```

## The shortcut

`./run.sh deploy` does steps 1 to 4; `./run.sh verify` is step 7 — including
steps 5 and 6's failures, and the way back; `./run.sh clean` is the clean-up.

## References

- [Gateway API — `BackendTLSPolicy`](https://gateway-api.sigs.k8s.io/reference/api-types/policy/backendtlspolicy/)
- [Gateway API — GEP-1897, BackendTLSPolicy](https://gateway-api.sigs.k8s.io/geps/gep-1897/)
- [Envoy Gateway — Backend TLS: Gateway to Backend](https://gateway.envoyproxy.io/docs/tasks/security/backend-tls/)
- [Envoy Gateway — Backend mutual TLS](https://gateway.envoyproxy.io/docs/tasks/security/backend-mtls/)
- [Envoy — TLS statistics](https://www.envoyproxy.io/docs/envoy/latest/configuration/listeners/stats#tls-statistics)

## Diagram sources

The figure is rendered from [`docs/diagrams/15-backend-tls-policy/source.html`](../docs/diagrams/15-backend-tls-policy/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
