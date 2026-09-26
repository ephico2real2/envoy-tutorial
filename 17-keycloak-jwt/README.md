# 17 — Keycloak tokens at the Gateway

Module 14 checked tokens signed with a secret written in this repository.
Module 16 built a real identity provider. This module joins them: the Gateway
checks **Keycloak's** tokens — fetching Keycloak's **public** keys itself, over
TLS, from inside the cluster — lets through only tokens from the right realm and
meant for the right API, tells the app who is calling, and lets only admins
reach `/admin`.

Nothing here is new machinery. It is module 14's `SecurityPolicy`, module 15's
`BackendTLSPolicy`, and module 16's realm, put together the way a real system
uses them.

## What you'll learn

- how a Gateway gets an identity provider's signing keys: `remoteJWKS`, a
  `ReferenceGrant`, and a `BackendTLSPolicy`
- what the Gateway checks in a token — signature, issuer, audience — and the
  distinct answer for each failure
- how to authorise on a **claim**: Keycloak's realm roles
- what happens when the Gateway cannot fetch the keys

## Before you start

- Module [`16`](../16-keycloak/README.md)'s Keycloak lab is **running**
  (`../16-keycloak/run.sh verify` passes).
- Modules [`14`](../14-gateway-policies/README.md) and
  [`15`](../15-backend-tls-policy/README.md) explain the two policies used here.
- Work from this folder: `cd 17-keycloak-jwt`.
- This module uses the namespace **`envoy-17`**, adds three small resources to
  **`keycloak`**, and takes about 20 minutes.

## The picture

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/17-keycloak-jwt/flow.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/17-keycloak-jwt/flow.light.png">
  <img alt="A caller gets a token from Keycloak's token endpoint, then calls the Gateway with it. The Gateway's jwt_authn filter checks the token's issuer and its audience shop-api, then its signature with Keycloak's public keys, which it fetched itself from keycloak-service.keycloak.svc:8443 over TLS - allowed by a ReferenceGrant and trusted through a BackendTLSPolicy - and cached for 300 seconds; then, on /admin, that the realm role admin is present. Measured answers: no token 401, an edited token 401 Jwt verification fails, another realm 401 Jwt issuer is not configured, another audience 403, alice on /admin 403 RBAC access denied, alice on /api and bob on /admin 200 with x-user set." src="../docs/diagrams/17-keycloak-jwt/flow.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

## Walkthrough

### Step 1 — is Keycloak there?

```console
$ oc get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
True
$ oc get keycloakrealmimport tutorial -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}{"\n"}'
True
```

Both `True`: the server is up and the realm `tutorial` exists. If not, run
module 16 first.

### Step 2 — a Gateway, the echo app, two routes

The Gateway as in module 13, step 1; the echo app; and
[`manifests/20-routes.yaml`](manifests/20-routes.yaml): `/api` and `/admin`, both
to echo, with nothing about tokens in them:

```console
$ oc apply -f ../12-gateway-api/manifests/20-envoyproxy.yaml -f ../12-gateway-api/manifests/10-gatewayclass.yaml
envoyproxy.gateway.envoyproxy.io/openshift-scc unchanged
gatewayclass.gateway.networking.k8s.io/eg unchanged
$ oc apply -f manifests/10-gateway.yaml
namespace/envoy-17 created
gateway.gateway.networking.k8s.io/eg created
$ sleep 10; oc adm policy add-scc-to-user nonroot-v2 -n envoy-gateway-system -z "$(oc get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-17 -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}')"
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:nonroot-v2 added: "envoy-envoy-17-eg-0d84cb63"
$ oc rollout restart deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-17
deployment.apps/envoy-envoy-17-eg-0d84cb63 restarted
$ oc rollout status deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-17 --timeout=240s
Waiting for deployment "envoy-envoy-17-eg-0d84cb63" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "envoy-envoy-17-eg-0d84cb63" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "envoy-envoy-17-eg-0d84cb63" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-17-eg-0d84cb63" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-17-eg-0d84cb63" rollout to finish: 1 old replicas are pending termination...
deployment "envoy-envoy-17-eg-0d84cb63" successfully rolled out
$ oc wait gateway/eg -n envoy-17 --for=condition=Programmed --timeout=120s
gateway.gateway.networking.k8s.io/eg condition met
$ oc apply -n envoy-17 -f ../_shared/client.yaml -f ../_shared/echo-app.yaml -f manifests/20-routes.yaml
pod/client created
configmap/echo-src created
service/echo created
deployment.apps/echo created
httproute.gateway.networking.k8s.io/api created
httproute.gateway.networking.k8s.io/admin created
$ oc rollout status -n envoy-17 deploy/echo --timeout=240s
Waiting for deployment "echo" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "echo" rollout to finish: 1 of 2 updated replicas are available...
deployment "echo" successfully rolled out
$ oc wait -n envoy-17 --for=condition=Ready pod/client --timeout=120s
pod/client condition met
```

### Step 3 — let the Gateway reach Keycloak's keys

To check a token, the Gateway needs Keycloak's public keys (module 16, step 9).
It will fetch them **itself**, straight from Keycloak's Service — not through the
router — which takes three things, all in Keycloak's namespace
([`manifests/30-trust-keycloak.yaml`](manifests/30-trust-keycloak.yaml)):

- the **CA** that signed Keycloak's certificate, in a ConfigMap under `ca.crt`;
- a **`ReferenceGrant`**: the Gateway API does not let a resource in one
  namespace point at a Service in another unless that namespace allows it. This
  one allows `SecurityPolicy` resources in `envoy-17` to use `keycloak-service`;
- a **`BackendTLSPolicy`** (module 15): reach `keycloak-service` over TLS, trust
  that CA, expect the name `keycloak-service.keycloak.svc` — which module 16's
  certificate carries for exactly this reason.

```console
$ oc create configmap keycloak-ca -n keycloak --from-literal=ca.crt="$(oc get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d)"
configmap/keycloak-ca created
$ oc apply -f manifests/30-trust-keycloak.yaml
referencegrant.gateway.networking.k8s.io/envoy-17-fetches-jwks created
backendtlspolicy.gateway.networking.k8s.io/keycloak-service created
```

### Step 4 — a SecurityPolicy that trusts Keycloak

[`manifests/40-jwt.yaml`](manifests/40-jwt.yaml) targets the whole **Gateway**.
Its one JWT provider says:

| Field | Here | So the Gateway |
|---|---|---|
| `issuer` | `https://keycloak.apps-crc.testing/realms/tutorial` | accepts only tokens whose `iss` is exactly that |
| `audiences` | `[shop-api]` | accepts only tokens meant for this API |
| `remoteJWKS.uri` + `backendRefs` | the realm's `certs`, at `keycloak-service` in `keycloak` | fetches the public keys from there |
| `claimToHeaders` | `preferred_username` → `x-user`, `azp` → `x-client` | tells the app who called, through which client |

```console
$ oc apply -f manifests/40-jwt.yaml
securitypolicy.gateway.envoyproxy.io/keycloak-jwt created
$ sleep 20; oc get securitypolicy keycloak-jwt -n envoy-17 -o jsonpath='{range .status.ancestors[0].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
Accepted=True Policy has been accepted.
$ oc get backendtlspolicy keycloak-service -n keycloak -o jsonpath='{range .status.ancestors[0].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
ResolvedRefs=True Resolved all the Object references.
Accepted=True Policy has been accepted.
```

Both accepted. Now the tokens. [`token.sh`](token.sh) asks module 16's Keycloak
for one, from the `client` pod in the `keycloak` namespace — read it: it is the
same request as module 16, step 10, except that the form goes to `curl` on its
standard input. `oc exec` sends a command's arguments in the request URL, and the
API server's audit log keeps that URL (measured) — a password passed as
`-d password=…` would be stored there; on stdin it is not. Without a token, and
with alice's:

```console
$ oc exec -n envoy-17 client -- curl -s -w '  -> %{http_code}\n' "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/api"
Jwt is missing  -> 401
$ oc exec -n envoy-17 client -- curl -s -H "authorization: Bearer $(./token.sh alice)" "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/api" | grep -E '"(x-user|x-client)"'
    "x-user": "alice",
    "x-client": "shop-cli"
```

**What just happened:** no token, **`401 Jwt is missing`**. Alice's token got
through, and the app was told **`x-user: alice`**, via **`x-client:
shop-cli`** — from the token's claims, which the Gateway had just verified. How
did it verify them? It had fetched Keycloak's keys already:

```console
$ ../_shared/eg-admin.sh envoy-17/eg 'config_dump?resource=dynamic_listeners' | python3 -c 'import json,sys; [print(json.dumps({k: p[k] for k in ("issuer", "audiences", "remote_jwks")}, indent=1)) for l in json.load(sys.stdin)["configs"] for fc in [l["active_state"]["listener"].get("default_filter_chain")] + l["active_state"]["listener"].get("filter_chains", []) if fc for f in fc["filters"] for h in f["typed_config"].get("http_filters", []) if h["name"].startswith("envoy.filters.http.jwt_authn") for p in h["typed_config"]["providers"].values()]'
{
 "issuer": "https://keycloak.apps-crc.testing/realms/tutorial",
 "audiences": [
  "shop-api"
 ],
 "remote_jwks": {
  "http_uri": {
   "uri": "https://keycloak-service.keycloak.svc:8443/realms/tutorial/protocol/openid-connect/certs",
   "cluster": "securitypolicy/envoy-17/keycloak-jwt/jwt/0",
   "timeout": "10s"
  },
  "cache_duration": "300s",
  "async_fetch": {}
 }
}
$ ../_shared/eg-admin.sh envoy-17/eg stats | grep -E '^cluster\.securitypolicy/envoy-17/keycloak-jwt/jwt/0\.(ssl\.handshake|upstream_rq_200):|jwt_authn\.jwks_fetch_(success|failed):'
cluster.securitypolicy/envoy-17/keycloak-jwt/jwt/0.ssl.handshake: 1
cluster.securitypolicy/envoy-17/keycloak-jwt/jwt/0.upstream_rq_200: 1
http.http-10080.jwt_authn.jwks_fetch_failed: 1
http.http-10080.jwt_authn.jwks_fetch_success: 1
```

**What just happened:** the keys come from their **own cluster**, over TLS
(`ssl.handshake`), and a `200`. The fetch counters may show a failure before the
first success — in the run shown, one attempt failed and the next succeeded; the
Gateway keeps trying until it has the keys. Two of Envoy Gateway's defaults
matter: **`cache_duration: 300s`** (Envoy's own default is 10 minutes) —
the keys are kept five minutes, then fetched again, which is how a key Keycloak
rotates in reaches the Gateway — and **`async_fetch`**: they are fetched when the
listener starts, not on the first request.

### Step 5 — the tokens that do not get through

Each check has its own answer. A token **edited** after Keycloak signed it — alice
giving herself the `admin` role:

```console
$ oc exec -n envoy-17 client -- curl -s -w '  -> %{http_code}\n' -H "authorization: Bearer $(./token.sh alice | python3 -c 'import base64,json,sys; h, p, s = sys.stdin.read().strip().split("."); c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); c["realm_access"]["roles"].append("admin"); print(".".join([h, base64.urlsafe_b64encode(json.dumps(c).encode()).decode().rstrip("="), s]))')" "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/api"
Jwt verification fails  -> 401
```

A real token from the right realm, but **meant for something else** — Keycloak's
built-in `admin-cli` client puts no `shop-api` audience in it:

```console
$ oc exec -n envoy-17 client -- curl -s -w '  -> %{http_code}\n' -H "authorization: Bearer $(./token.sh alice-admin-cli)" "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/api"
Audiences in Jwt are not allowed  -> 403
```

A real token from **another realm** — `master`, Keycloak's own admin realm:

```console
$ oc exec -n envoy-17 client -- curl -s -w '  -> %{http_code}\n' -H "authorization: Bearer $(./token.sh master-admin)" "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/api"
Jwt issuer is not configured  -> 401
```

**What just happened:**

| Token | Answer | Check that failed |
|---|---|---|
| edited | `401 Jwt verification fails` | the **signature** — the claims no longer match what Keycloak signed |
| another audience | **`403`** `Audiences in Jwt are not allowed` | the **audience** — not for this API. Note the `403`, not `401` |
| another realm | `401 Jwt issuer is not configured` | the **issuer** — not this realm |

The checks run in a fixed order: the issuer, the expiry, the audience — and only
then the signature, with the keys (Envoy's `jwt_authn`, `authenticator.cc`). So
the `403` for the audience and the `401` for the issuer say nothing about the
signature: measured, a token Keycloak never signed, with another `aud`, gets the
same `403`. Only a request that gets past `jwt_authn` — a `200`, or step 6's
`403 RBAC` — has had its signature checked.

And a service with its own identity gets through as itself:

```console
$ oc exec -n envoy-17 client -- curl -s -H "authorization: Bearer $(./token.sh orders-service)" "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/api" | grep '"x-user"'
    "x-user": "service-account-orders-service",
```

### Step 6 — only admins on /admin

[`manifests/50-admin-only.yaml`](manifests/50-admin-only.yaml) is a second
`SecurityPolicy`, on the `admin` **route**: the same JWT provider, plus an
**authorization** rule — deny by default, allow if the token's
`realm_access.roles` contains `admin`:

```console
$ oc apply -f manifests/50-admin-only.yaml
securitypolicy.gateway.envoyproxy.io/admin-only created
$ sleep 10; oc get securitypolicy keycloak-jwt -n envoy-17 -o jsonpath='{range .status.ancestors[0].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
Accepted=True Policy has been accepted.
Overridden=True This policy is being overridden by other securityPolicies for these routes: [envoy-17/admin]
```

**What just happened:** the Gateway's policy now says **`Overridden=True`** for
`envoy-17/admin`. A `SecurityPolicy` on a route **replaces** the Gateway's for
that route — the two are not merged — which is why `50-admin-only.yaml` repeats
the JWT provider instead of relying on the Gateway's: all of it, both
`claimToHeaders` included. Envoy clears from a request only the headers its
provider sets — with `x-client` left out, a caller's own `x-client` header would
reach the app on `/admin` (measured). Now alice, then bob:

```console
$ oc exec -n envoy-17 client -- curl -s -w '  -> %{http_code}\n' -H "authorization: Bearer $(./token.sh alice)" "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/admin"
RBAC: access denied  -> 403
$ oc exec -n envoy-17 client -- curl -s -w '  -> %{http_code}\n' -H "authorization: Bearer $(./token.sh bob)" "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/admin" | grep -E '"x-user"|->'
    "x-user": "bob",
}  -> 200
```

**What just happened:** alice's token is valid — she is signed in — but she is a
`reader`: **`403 RBAC: access denied`**. Bob has `admin`: **`200`**. The
difference between the two answers is the difference between *who are you*
(`401`) and *you may not* (`403`).

### Step 7 — when the Gateway cannot fetch the keys

Take the `BackendTLSPolicy` away and restart the Gateway's Envoy, so it must
fetch the keys again — and now does so in plain HTTP, to a port that speaks only
TLS (module 15, step 3):

```console
$ oc delete backendtlspolicy keycloak-service -n keycloak
backendtlspolicy.gateway.networking.k8s.io "keycloak-service" deleted from keycloak namespace
$ sleep 20; oc rollout restart deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-17
deployment.apps/envoy-envoy-17-eg-0d84cb63 restarted
$ oc rollout status deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-17 --timeout=240s
Waiting for deployment "envoy-envoy-17-eg-0d84cb63" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-17-eg-0d84cb63" rollout to finish: 1 old replicas are pending termination...
deployment "envoy-envoy-17-eg-0d84cb63" successfully rolled out
$ sleep 5; oc exec -n envoy-17 client -- curl -s -w '  -> %{http_code}\n' -H "authorization: Bearer $(./token.sh alice)" "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/api"
Jwks remote fetch is failed  -> 401
$ ../_shared/eg-admin.sh envoy-17/eg stats | grep -E 'jwt_authn\.jwks_fetch_(success|failed):|keycloak-jwt/jwt/0\.upstream_rq_503:'
cluster.securitypolicy/envoy-17/keycloak-jwt/jwt/0.upstream_rq_503: 17
http.http-10080.jwt_authn.jwks_fetch_failed: 33
http.http-10080.jwt_authn.jwks_fetch_success: 0
```

**What just happened:** a perfectly good token, refused — **`401 Jwks remote
fetch is failed`**. With no keys, the Gateway can verify nothing, so it lets
nothing through: it **fails closed**. The counters show every fetch failing, with
`503` from the Keycloak cluster. Put the policy back:

```console
$ oc apply -f manifests/30-trust-keycloak.yaml
referencegrant.gateway.networking.k8s.io/envoy-17-fetches-jwks unchanged
backendtlspolicy.gateway.networking.k8s.io/keycloak-service created
$ sleep 20; oc exec -n envoy-17 client -- curl -s -o /dev/null -w '%{http_code}\n' -H "authorization: Bearer $(./token.sh alice)" "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/api"
200
```

Back to `200`, with no restart: the Gateway kept trying to fetch the keys, and
once the policy was back a fetch succeeded (`jwks_fetch_success` rises).

### Step 8 — check yourself

```console
$ ./run.sh verify

1. the policies
  ✓ BackendTLSPolicy to keycloak-service accepted
  ✓ SecurityPolicy keycloak-jwt accepted
  ✓ SecurityPolicy admin-only accepted
  ✓ ...and the Gateway's policy says it is overridden on /admin
  ✓ the keys came from keycloak-service over TLS

2. who gets through /api
  ✓ no token -> 401
  ✓ alice -> 200
  ✓ ...and the app is told who
  ✓ a token edited to add a role -> 401
  ✓ a token not meant for shop-api -> 403
  ✓ a token from another realm -> 401
  ✓ orders-service -> 200, as itself

3. who gets through /admin (realm role admin)
  ✓ alice (reader) -> 403
  ✓ bob (admin) -> 200
  ✓ ...and the app gets the token's client, not the caller's x-client

all checks passed
```

## The options

**`SecurityPolicy` — `jwt.providers[]`**

| Field | Here | Envoy got |
|---|---|---|
| `issuer` | the realm's URL | `issuer` — checked against `iss` |
| `audiences` | `[shop-api]` | `audiences` — checked against `aud` |
| `remoteJWKS.uri`, `backendRefs` | Keycloak's `certs`, via `keycloak-service` | `remote_jwks`, its own cluster, `cache_duration: 300s`, `async_fetch` |
| `claimToHeaders` | `preferred_username`, `azp` | `claim_to_headers` |

**`SecurityPolicy` — `authorization`**

| Field | Here | What it does |
|---|---|---|
| `defaultAction` | `Deny` | refuse unless a rule allows |
| `rules[].principal.jwt.claims` | `realm_access.roles` contains `admin` (`StringArray`) | a nested claim, by dotted name |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| `401 Jwks remote fetch is failed` for every token | the Gateway cannot fetch the keys — measured without the `BackendTLSPolicy` | step 3; `jwt_authn.jwks_fetch_failed` counts the attempts |
| `401 Jwt issuer is not configured` | `iss` differs from `issuer` — another realm, or Keycloak's `hostname` changed | compare with the realm's discovery document (module 16, step 9) |
| `403 Audiences in Jwt are not allowed` | the token is not for `shop-api` — no audience mapper on its client | add the mapper (module 16's realm) |
| `401 Jwt verification fails` | the signature does not match the claims — the token was edited | a fresh token from Keycloak |
| `401 Jwks doesn't have key to match kid or alg from Jwt` | the token names a key (`kid`) the Gateway has not fetched — Keycloak rotated its keys; measured with a new key | wait for the next fetch, at most `cache_duration` (300 s), or restart the Gateway's Envoy |
| `403 RBAC: access denied` | valid token, missing role | give the user the role in Keycloak |
| a route policy ignores the Gateway's JWT settings | a route's `SecurityPolicy` replaces the Gateway's; status says `Overridden` | repeat the provider in the route's policy |
| `500` for every request; the policy says `Accepted=False` … `backend ref to Service keycloak/keycloak-service not permitted by any ReferenceGrant` | the `ReferenceGrant` in `keycloak` is missing — measured | step 3 |

## Clean up

Remove this module's Gateway and what it added next to Keycloak; the Keycloak
lab itself stays (module 16 removes it):

```console
$ oc adm policy remove-scc-from-user nonroot-v2 -n envoy-gateway-system -z "$(oc get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-17 -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}')"
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:nonroot-v2 removed: "envoy-envoy-17-eg-0d84cb63"
$ oc delete -f manifests/10-gateway.yaml --wait=false
namespace "envoy-17" deleted
gateway.gateway.networking.k8s.io "eg" deleted from envoy-17 namespace
$ oc delete -f manifests/30-trust-keycloak.yaml
referencegrant.gateway.networking.k8s.io "envoy-17-fetches-jwks" deleted from keycloak namespace
backendtlspolicy.gateway.networking.k8s.io "keycloak-service" deleted from keycloak namespace
$ oc delete configmap keycloak-ca -n keycloak
configmap "keycloak-ca" deleted from keycloak namespace
```

## The shortcut

`./run.sh deploy` does steps 2 to 6; `./run.sh verify` is step 8;
`./run.sh clean` is the clean-up.

## References

- [Envoy Gateway — JWT authentication](https://gateway.envoyproxy.io/latest/tasks/security/jwt-authentication/)
- [Envoy Gateway — JWT claim-based authorization](https://gateway.envoyproxy.io/docs/tasks/security/jwt-claim-authorization/)
- [Gateway API — `ReferenceGrant`](https://gateway-api.sigs.k8s.io/api-types/referencegrant/)
- [Envoy — JWT authentication filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/jwt_authn_filter)
- [Red Hat build of Keycloak 26.6 — Server Administration Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/server_administration_guide/index)

## Diagram sources

The figure is rendered from [`docs/diagrams/17-keycloak-jwt/source.html`](../docs/diagrams/17-keycloak-jwt/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
