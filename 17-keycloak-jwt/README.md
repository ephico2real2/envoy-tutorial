# 17 — Keycloak tokens at the Gateway

Module 14 checked tokens signed with a secret written in this repository.
Module 16 built a real identity provider. This module joins them: the Gateway
checks **Keycloak's** tokens — fetching Keycloak's **public** keys itself, over
TLS, from inside the cluster — lets through only tokens from the right realm and
meant for the right API, tells the app who is calling, and lets only admins
reach `/admin`. Then it trusts a **second** realm, module 18's `corp`, whose
people come from the cluster's LDAP directory — and on `/admin`, an **LDAP
group** decides who is an admin.

Nothing here is new machinery. It is module 14's `SecurityPolicy`, module 15's
`BackendTLSPolicy`, and the realms of modules 16 and 18, put together the way a
real system uses them.

## What you'll learn

- how a Gateway gets an identity provider's signing keys: `remoteJWKS`, a
  `ReferenceGrant`, and a `BackendTLSPolicy`
- what the Gateway checks in a token — signature, issuer, audience — and the
  distinct answer for each failure
- how to authorise on a **claim**: Keycloak's realm roles
- what happens when the Gateway cannot fetch the keys
- how one Gateway trusts two issuers, and how an LDAP group reaches `/admin`

## Before you start

- Module [`16`](../16-keycloak/README.md)'s Keycloak lab is **running**
  (`../16-keycloak/run.sh verify` passes).
- For steps 8 to 10: module [`18`](../18-keycloak-ldap/README.md)'s realm `corp`
  is there (`../18-keycloak-ldap/run.sh verify` passes), and the directory has
  the shop's two users, `shop.alice` and `shop.bob` — group-sync-operator-helm-chart,
  `setup-local-ldap-testing/ldap-shop-users.ldif` (its header has the command).
- Modules [`14`](../14-gateway-policies/README.md) and
  [`15`](../15-backend-tls-policy/README.md) explain the two policies used here.
- Work from this folder: `cd 17-keycloak-jwt`.
- This module uses the namespace **`envoy-17`**, adds three small resources to
  **`keycloak`**, and takes about 20 minutes. On the operator's CRC it is
  **permanent**, kept by Argo CD: see [Permanent lab](#permanent-lab) before you
  change anything by hand there.

## The picture

<!-- markdownlint-disable MD033 -->
<img alt="A caller gets a token from Keycloak's token endpoint, then calls the Gateway with it. The Gateway's jwt_authn filter checks the token's issuer and its audience shop-api, then its signature with Keycloak's public keys, which it fetched itself from keycloak-service.keycloak.svc:8443 over TLS - allowed by a ReferenceGrant and trusted through a BackendTLSPolicy - and cached for 300 seconds; then, on /admin, that the realm role admin is present. Measured answers: no token 401, an edited token 401 Jwt verification fails, another realm 401 Jwt issuer is not configured, another audience 403, alice on /admin 403 RBAC access denied, alice on /api and bob on /admin 200 with x-user set. Beside the realm tutorial, the Gateway trusts a second issuer, the realm corp, whose people come from LDAP: one SecurityPolicy with two providers, which Envoy joins with requires_any, each with its own keys from the same Service. On /admin one Allow rule per provider requires the role admin, which corp gives the members of the LDAP group app-ocp-rbac-ocp-keycloak-admin. Measured answers for corp: shop.alice on /api 200 with x-user shop.alice, shop.alice on /admin 403, shop.bob on /admin 200; bob.wilson, outside the login gate, gets no token." src="../docs/diagrams/17-keycloak-jwt/flow.light.png">
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
It has two JWT providers. The second, `corp`, is for module 18's realm and waits
for step 8; the first, `keycloak`, says:

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
`-d password=…` would be stored there; on stdin it is not. The token is a
credential too — whoever holds it is alice until it expires, 300 s later — so
it gets the same treatment: [`request.sh`](request.sh) reads it on its standard
input and gives `curl` the `authorization` header as a config file on curl's
standard input (`curl -K -`), never as an argument. Without a token, and with
alice's:

```console
$ oc exec -n envoy-17 client -- curl -s -w '  -> %{http_code}\n' "http://$(oc get gateway eg -n envoy-17 -o jsonpath='{.status.addresses[0].value}')/api"
Jwt is missing  -> 401
$ ./token.sh alice | ./request.sh /api | grep -E '"(x-user|x-client)"'
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
{
 "issuer": "https://keycloak.apps-crc.testing/realms/corp",
 "audiences": [
  "shop-api"
 ],
 "remote_jwks": {
  "http_uri": {
   "uri": "https://keycloak-service.keycloak.svc:8443/realms/corp/protocol/openid-connect/certs",
   "cluster": "securitypolicy/envoy-17/keycloak-jwt/jwt/1",
   "timeout": "10s"
  },
  "cache_duration": "300s",
  "async_fetch": {}
 }
}
$ ../_shared/eg-admin.sh envoy-17/eg stats | grep -E '^cluster\.securitypolicy/envoy-17/keycloak-jwt/jwt/0\.(ssl\.handshake|upstream_rq_200):|jwt_authn\.jwks_fetch_(success|failed):'
cluster.securitypolicy/envoy-17/keycloak-jwt/jwt/0.ssl.handshake: 1
cluster.securitypolicy/envoy-17/keycloak-jwt/jwt/0.upstream_rq_200: 1
http.http-10080.jwt_authn.jwks_fetch_failed: 2
http.http-10080.jwt_authn.jwks_fetch_success: 2
```

**What just happened:** the keys come from their **own cluster**, over TLS
(`ssl.handshake`), and a `200` — one cluster per provider: `jwt/0` is
`keycloak`'s, and the second provider, `corp`, has its own, `jwt/1`, with its
realm in the URI. The fetch counters, which add up both providers, may show
failures before the successes — in the run shown, two attempts failed and two
succeeded; the Gateway keeps trying until it has the keys. Two of Envoy Gateway's defaults
matter: **`cache_duration: 300s`** (Envoy's own default is 10 minutes) —
the keys are kept five minutes, then fetched again, which is how a key Keycloak
rotates in reaches the Gateway — and **`async_fetch`**: they are fetched when the
listener starts, not on the first request.

### Step 5 — the tokens that do not get through

Each check has its own answer. A token **edited** after Keycloak signed it — alice
giving herself the `admin` role:

```console
$ ./token.sh alice | python3 -c 'import base64,json,sys; h, p, s = sys.stdin.read().strip().split("."); c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); c["realm_access"]["roles"].append("admin"); print(".".join([h, base64.urlsafe_b64encode(json.dumps(c).encode()).decode().rstrip("="), s]))' | ./request.sh /api -w '  -> %{http_code}\n'
Jwt verification fails  -> 401
```

A real token from the right realm, but **meant for something else** — Keycloak's
built-in `admin-cli` client puts no `shop-api` audience in it:

```console
$ ./token.sh alice-admin-cli | ./request.sh /api -w '  -> %{http_code}\n'
Audiences in Jwt are not allowed  -> 403
```

A real token from **another realm** — `master`, Keycloak's own admin realm:

```console
$ ./token.sh master-admin | ./request.sh /api -w '  -> %{http_code}\n'
Jwt issuer is not configured  -> 401
```

**What just happened:**

| Token | Answer | Check that failed |
|---|---|---|
| edited | `401 Jwt verification fails` | the **signature** — the claims no longer match what Keycloak signed |
| another audience | **`403`** `Audiences in Jwt are not allowed` | the **audience** — not for this API. Note the `403`, not `401` |
| another realm | `401 Jwt issuer is not configured` | the **issuer** — not a realm the Gateway trusts |

The checks run in a fixed order: the issuer, the expiry, the audience — and only
then the signature, with the keys (Envoy's `jwt_authn`, `authenticator.cc`). So
the `403` for the audience and the `401` for the issuer say nothing about the
signature: measured, a token Keycloak never signed, with another `aud`, gets the
same `403`. Only a request that gets past `jwt_authn` — a `200`, or step 6's
`403 RBAC` — has had its signature checked.

And a service with its own identity gets through as itself:

```console
$ ./token.sh orders-service | ./request.sh /api | grep '"x-user"'
    "x-user": "service-account-orders-service",
```

### Step 6 — only admins on /admin

[`manifests/50-admin-only.yaml`](manifests/50-admin-only.yaml) is a second
`SecurityPolicy`, on the `admin` **route**: the same two JWT providers, plus
**authorization** — deny by default, allow if the token's `realm_access.roles`
contains `admin` (one rule per provider; step 9 says why):

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
the JWT providers instead of relying on the Gateway's: all of each, both
`claimToHeaders` included. Envoy clears from a request only the headers its
provider sets — with `x-client` left out, a caller's own `x-client` header would
reach the app on `/admin` (measured). Now alice, then bob:

```console
$ ./token.sh alice | ./request.sh /admin -w '  -> %{http_code}\n'
RBAC: access denied  -> 403
$ ./token.sh bob | ./request.sh /admin -w '  -> %{http_code}\n' | grep -E '"x-user"|->'
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
TLS (module 15, step 3). `./run.sh pause` first: on the permanent lab it stops
Argo CD putting the policy back ([Permanent lab](#permanent-lab)); on a cluster
without it, it does nothing.

```console
$ ./run.sh pause >/dev/null
$ oc delete backendtlspolicy keycloak-service -n keycloak
backendtlspolicy.gateway.networking.k8s.io "keycloak-service" deleted from keycloak namespace
$ sleep 20; oc rollout restart deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-17
deployment.apps/envoy-envoy-17-eg-0d84cb63 restarted
$ oc rollout status deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-17 --timeout=240s
Waiting for deployment "envoy-envoy-17-eg-0d84cb63" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-17-eg-0d84cb63" rollout to finish: 1 old replicas are pending termination...
deployment "envoy-envoy-17-eg-0d84cb63" successfully rolled out
$ sleep 5; ./token.sh alice | ./request.sh /api -w '  -> %{http_code}\n'
Jwks remote fetch is failed  -> 401
$ ../_shared/eg-admin.sh envoy-17/eg stats | grep -E 'jwt_authn\.jwks_fetch_(success|failed):|keycloak-jwt/jwt/0\.upstream_rq_503:'
cluster.securitypolicy/envoy-17/keycloak-jwt/jwt/0.upstream_rq_503: 17
http.http-10080.jwt_authn.jwks_fetch_failed: 65
http.http-10080.jwt_authn.jwks_fetch_success: 0
```

**What just happened:** a perfectly good token, refused — **`401 Jwks remote
fetch is failed`**. With no keys, the Gateway can verify nothing, so it lets
nothing through: it **fails closed**. The counters show every fetch failing, with
`503` from the Keycloak cluster. Put the policy back, and hand the lab back to
Argo CD:

```console
$ oc apply -f manifests/30-trust-keycloak.yaml
referencegrant.gateway.networking.k8s.io/envoy-17-fetches-jwks unchanged
backendtlspolicy.gateway.networking.k8s.io/keycloak-service created
$ sleep 20; ./token.sh alice | ./request.sh /api -o /dev/null -w '%{http_code}\n'
200
$ ./run.sh resume >/dev/null
```

Back to `200`, with no restart: the Gateway kept trying to fetch the keys, and
once the policy was back a fetch succeeded (`jwks_fetch_success` rises).

### Step 8 — a second issuer: people from the directory

Realm `tutorial`'s people are written in a file. Module 18 built a second realm,
**`corp`**, whose people and groups come from the cluster's LDAP directory — and
only the members of its login gate, `app-ssb-autobahnusers`, may log in. The
Gateway has trusted it since step 4: `40-jwt.yaml`'s second provider, `corp`, is
the first with another realm in two places — the issuer, `…/realms/corp`, and
the keys, `…/realms/corp/protocol/openid-connect/certs`. Each realm signs with a
key of its own, so each needs its own JWKS. Is the realm there?

```console
$ oc get keycloakrealmimport corp -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}{"\n"}'
True
```

How does one policy with two providers decide? Ask the Gateway's Envoy which
**requirement** each route uses — then what each requirement says:

```console
$ ../_shared/eg-admin.sh envoy-17/eg 'config_dump?resource=dynamic_route_configs' | python3 -c 'import json,sys; [print(r["match"]["path_separated_prefix"], "->", r["typed_per_filter_config"]["envoy.filters.http.jwt_authn"]["requirement_name"]) for c in json.load(sys.stdin)["configs"] for vh in c["route_config"]["virtual_hosts"] for r in vh["routes"]]'
/admin -> keycloak-or-corp_4415a9690c753596
/api -> keycloak-or-corp_d89af36ae9adc751
$ ../_shared/eg-admin.sh envoy-17/eg 'config_dump?resource=dynamic_listeners' | python3 -c 'import json,sys; [print(n + "\n  " + "".join(k for k in r) + ":" + "".join("\n    " + x["provider_name"] + "  " + p[x["provider_name"]]["issuer"] for x in r["requires_any"]["requirements"])) for l in json.load(sys.stdin)["configs"] for fc in [l["active_state"]["listener"].get("default_filter_chain")] + l["active_state"]["listener"].get("filter_chains", []) if fc for f in fc["filters"] for h in f["typed_config"].get("http_filters", []) if h["name"].startswith("envoy.filters.http.jwt_authn") for p in [h["typed_config"]["providers"]] for n, r in h["typed_config"]["requirement_map"].items()]'
keycloak-or-corp_d89af36ae9adc751
  requires_any:
    keycloak_da84ee5a9f7b6799  https://keycloak.apps-crc.testing/realms/tutorial
    corp_486c8a95a22e8d31  https://keycloak.apps-crc.testing/realms/corp
keycloak-or-corp_4415a9690c753596
  requires_any:
    keycloak_3bacc451fa4b4cc4  https://keycloak.apps-crc.testing/realms/tutorial
    corp_63e132447cbdc778  https://keycloak.apps-crc.testing/realms/corp
```

**What just happened:** each route's requirement is **`requires_any`** over two
providers, one per realm: a token that **either** accepts gets through. Envoy
Gateway builds it that way whenever a policy lists more than one provider
(v1.9.1, `internal/xds/translator/jwt.go`, `buildJWTRequirement`); with one
provider the requirement is just that provider — measured with `corp` removed:
`/api` named `keycloak` alone. Each policy brings its own pair — `/admin`'s from
`admin-only` — so Envoy holds four providers, each with its own JWKS cluster.

The shop's users in `corp` are two ordinary directory people, `shop.alice` and
`shop.bob`, mirroring `tutorial`'s alice and bob: both are in the login gate, and
`shop.bob` is also in `app-ocp-rbac-ocp-keycloak-admin` — the LDAP group `corp`
turns into the role `admin` (module 18, step 10). Their tokens, read:

```console
$ for u in shop.alice shop.bob; do ./token.sh $u | python3 -c 'import base64,json,sys; p = sys.stdin.read().strip().split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); print(c["preferred_username"], c["iss"], sorted(c["realm_access"]["roles"]))'; done
shop.alice https://keycloak.apps-crc.testing/realms/corp ['default-roles-corp', 'offline_access', 'uma_authorization']
shop.bob https://keycloak.apps-crc.testing/realms/corp ['admin', 'default-roles-corp', 'offline_access', 'uma_authorization']
```

Both from `corp`; only `shop.bob` has `admin`. Now `shop.alice` on `/api`:

```console
$ ./token.sh shop.alice | ./request.sh /api -w '  -> %{http_code}\n' | grep -E '"(x-user|x-client)"|->'
    "x-user": "shop.alice",
    "x-client": "shop-cli"
}  -> 200
```

**What just happened:** a token from the second realm, **`200`**, and the app is
told **`x-user: shop.alice`** — her LDAP `uid`, through the same `claimToHeaders`
as `tutorial`'s users. The app cannot tell, and need not care, which realm she
came from.

### Step 9 — /admin follows an LDAP group

`50-admin-only.yaml` lists both providers too: the route's policy replaces the
Gateway's (step 6), so without `corp` there a `corp` token is refused on `/admin`
before any rule is read — measured: `401 Jwt issuer is not configured`. And it
has **one `Allow` rule per provider**. Here they are, as Envoy's RBAC filter got
them:

```console
$ ../_shared/eg-admin.sh envoy-17/eg 'config_dump?resource=dynamic_route_configs' | python3 -c 'import json,sys; [print(m["on_match"]["action"]["name"] + ":", m["on_match"]["action"]["typed_config"]["name"], "if", "/".join(k["key"] for k in m["predicate"]["single_predicate"]["input"]["typed_config"]["path"]), "has", m["predicate"]["single_predicate"]["custom_match"]["typed_config"]["value"]["list_match"]["one_of"]["string_match"]["exact"]) for c in json.load(sys.stdin)["configs"] for vh in c["route_config"]["virtual_hosts"] for r in vh["routes"] for t in [r.get("typed_per_filter_config", {}).get("envoy.filters.http.rbac")] if t for m in t["rbac"]["matcher"]["matcher_list"]["matchers"]]'
admins: ALLOW if keycloak/realm_access/roles has admin
corp-admins: ALLOW if corp/realm_access/roles has admin
```

**Why one rule per provider:** `jwt_authn` stores the claims of the token it
verified under the **name of the provider** that verified it — `keycloak/…` for
a `tutorial` token, `corp/…` for a `corp` one — and each rule reads one of those
places. A rule for `keycloak` alone never sees `shop.bob`'s role: measured, with
only `admins`, his token got `403 RBAC: access denied`. Now `shop.alice`, then
`shop.bob`:

```console
$ ./token.sh shop.alice | ./request.sh /admin -w '  -> %{http_code}\n'
RBAC: access denied  -> 403
$ ./token.sh shop.bob | ./request.sh /admin -w '  -> %{http_code}\n' | grep -E '"x-user"|->'
    "x-user": "shop.bob",
}  -> 200
```

And every user of both realms, on both paths — `tutorial`'s answers as in steps 4
and 6:

```console
$ for u in alice bob shop.alice shop.bob; do for p in /api /admin; do printf '%-10s %-6s ' $u $p; ./token.sh $u | ./request.sh $p -o /dev/null -w '%{http_code}\n'; done; done
alice      /api   200
alice      /admin 403
bob        /api   200
bob        /admin 200
shop.alice /api   200
shop.alice /admin 403
shop.bob   /api   200
shop.bob   /admin 200
```

**What just happened:** `shop.alice` is signed in but has no `admin`: **`403`**.
`shop.bob` has it: **`200`**. Nothing in the Gateway names an LDAP group — it
reads a role in a token. The realm file turns the group into the role, and the
**directory** decides who is in the group: that is where an admin is made or
unmade.

### Step 10 — outside the gate, no token

`bob.wilson` is in the directory, but not in the login gate:

<!-- walkthrough: expect-exit 1 -->
```console
$ ./token.sh bob.wilson
no token: {'error': 'invalid_grant', 'error_description': 'Invalid user credentials'}
```

```console
$ oc logs keycloak-0 -n keycloak | grep LOGIN_ERROR | grep 'username="bob.wilson"' | tail -n 1 | grep -o 'realmName=.*clientId="[^"]*"\|error="[^"]*"\|username="[^"]*"'
realmName="corp", clientId="shop-cli"
error="user_not_found"
username="bob.wilson"
```

**What just happened:** Keycloak's user search goes through the gate and finds
nobody — **`user_not_found`** in its log, while the caller hears only `Invalid
user credentials`, the answer for a wrong password too. There is no token, so
there is nothing for the Gateway to check: the gate is enforced once, in the
realm, before a request ever reaches it (module 18, steps 8 and 9).

### Step 11 — check yourself

```console
$ ./run.sh verify

1. the policies
  ✓ BackendTLSPolicy to keycloak-service accepted
  ✓ SecurityPolicy keycloak-jwt accepted
  ✓ SecurityPolicy admin-only accepted
  ✓ ...and the Gateway's policy says it is overridden on /admin
  ✓ the keys came from keycloak-service over TLS
  ✓ ...and corp's keys too
  ✓ /api accepts a token from either realm (requires_any)
  ✓ /admin accepts a token from either realm (requires_any)

2. who gets through /api
  ✓ no token -> 401
  ✓ alice -> 200
  ✓ ...and the app is told who
  ✓ a token edited to add a role -> 401
  ✓ a token not meant for shop-api -> 403
  ✓ a token from another realm -> 401
  ✓ orders-service -> 200
  ✓ ...as itself
  ✓ bob -> 200
  ✓ ...as bob

3. who gets through /admin (realm role admin)
  ✓ alice (reader) -> 403
  ✓ bob (admin) -> 200
  ✓ ...and the app gets the token's client, not the caller's x-client

4. realm corp: people from LDAP (module 18), admin from an LDAP group
  ✓ realm corp imported (module 18)
  ✓ shop.alice (gate member) -> /api 200
  ✓ ...and the app is told her LDAP uid
  ✓ shop.bob -> /api 200
  ✓ shop.alice (not in keycloak-admin) -> /admin 403
  ✓ shop.bob (in keycloak-admin) -> /admin 200
  ✓ ...as himself
  ✓ ...and the app gets the token's client, not the caller's x-client
  ✓ jeff (ns-developer): corp's default roles only
  ✓ jeff -> /api 200
  ✓ jeff -> /admin 403
  ✓ bob.wilson (outside the login gate): no corp token
  ✓ ...because Keycloak does not find him (not a wrong password)

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
| more than one provider | `keycloak` (realm `tutorial`) and `corp` | one `requires_any` requirement over them: a token that either provider accepts passes (step 8) |

**`SecurityPolicy` — `authorization`**

| Field | Here | What it does |
|---|---|---|
| `defaultAction` | `Deny` | refuse unless a rule allows |
| `rules[].principal.jwt.provider` | `keycloak`, `corp` — one rule each | the one provider whose verified claims the rule reads (step 9) |
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
| a `corp` token: `200` on `/api`, `401 Jwt issuer is not configured` on `/admin` | the route's policy lacks the `corp` provider — measured | list every provider in the route's policy too (step 9) |
| a `corp` admin gets `403 RBAC: access denied` on `/admin` | no `Allow` rule names provider `corp`: a rule reads only its own provider's claims — measured | one rule per provider (step 9) |
| a directory user gets `invalid_grant`, `Invalid user credentials`; Keycloak's log says `user_not_found` | not in the login gate `app-ssb-autobahnusers` | add them to the gate in the directory (module 18, step 8) |
| `500` for every request; the policy says `Accepted=False` … `backend ref to Service keycloak/keycloak-service not permitted by any ReferenceGrant` | the `ReferenceGrant` in `keycloak` is missing — measured | step 3 |

## Permanent lab

On the operator's CRC this Gateway stays: it is part of the Keycloak offering
(module 16, [Permanent lab](../16-keycloak/README.md#permanent-lab)). Argo CD's
Application `17-keycloak-jwt`
([`../argocd/17-keycloak-jwt.yaml`](../argocd/17-keycloak-jwt.yaml)) keeps this
module's `manifests/` and the echo app behind the routes — the same files
`./run.sh deploy` applies — as they are on the `main` branch. Delete one of its
objects, the echo app's source, and it is back:

<!-- walkthrough: skip -->
```console
$ date -u +%T; oc delete configmap echo-src -n envoy-17; until oc get configmap echo-src -n envoy-17 >/dev/null 2>&1; do sleep 1; done; oc get configmap echo-src -n envoy-17 -o jsonpath='{.metadata.creationTimestamp}  {.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
11:15:58
configmap "echo-src" deleted from envoy-17 namespace
2026-09-27T11:16:39Z  17-keycloak-jwt:/ConfigMap:envoy-17/echo-src
```

**What just happened:** Argo CD saw the ConfigMap go and applied it again from
git — a new object, with Argo CD's tracking annotation — 41 seconds later. Not
at once: Argo CD spaces out repairs made one after another — 2 s, 6 s, 18 s …
up to five minutes after the previous one — and its previous repair here was
4 minutes before, when `./run.sh deploy` resumed it. Run again right after, the
same command waited exactly five minutes; with no repair before it, the same
deletion was undone in 0.7 s ([`../argocd`](../argocd/README.md) has the
measurements).
(This block needs the Application, so the walkthrough runner skips it; it was
run as written.)

### What `./run.sh deploy` makes, and who keeps it

| What | Made by | Kept by | Why |
|---|---|---|---|
| namespace `envoy-17`, Gateway `eg`; HTTPRoutes `api`, `admin`; `ReferenceGrant` and `BackendTLSPolicy` in `keycloak`; SecurityPolicies `keycloak-jwt`, `admin-only` | `manifests/` | Argo CD | manifests |
| the echo app: ConfigMap `echo-src`, Service and Deployment `echo` | [`../_shared/echo-app.yaml`](../_shared/echo-app.yaml), applied with `-n envoy-17` | Argo CD — the Application's second source | the backend of both routes; its objects carry no namespace and take the Application's, `envoy-17` |
| GatewayClass `eg`, EnvoyProxy `openshift-scc` | module 12's files, applied in step 2 | nobody here — module 12 owns them | shared by modules 12 to 17; only module 12's clean removes them. An Application of this module must not own another module's objects |
| **the `nonroot-v2` grant** for the Gateway's Envoy (step 2) | `./run.sh deploy`: `oc adm policy add-scc-to-user` | nobody — `run.sh` only | `oc adm policy` writes it into one RoleBinding, `system:openshift:scc:nonroot-v2` in `envoy-gateway-system`, which every Gateway module (12 to 17) adds its own ServiceAccount to: an Application owning that object would remove the others. The grant stays in that RoleBinding until `./run.sh clean` removes it. (A RoleBinding of this module's own could hold it: Envoy Gateway names the ServiceAccount `envoy-envoy-17-eg-` plus the first 8 hex digits of the SHA-256 of `envoy-17/eg` — measured, `0d84cb63` — but every Gateway module's `gw_up` would have to change with it.) |
| **restarting the Envoy** after the grant (step 2) | `./run.sh deploy` | — | needed once, so a pod starts now rather than after the ReplicaSet's back-off |
| **ConfigMap `keycloak-ca`** in `keycloak` (step 3) | `./run.sh deploy`, from Secret `keycloak-tls` | nobody — `run.sh` only | it holds the cluster's own CA — `enterprise-ca`'s, which each cluster makes for itself (module 00). A copy in git would be this CRC's CA, and wrong on every other cluster. Without it the `BackendTLSPolicy` is refused — `Accepted=False` `NoValidCACertificate` (measured in module 15's Troubleshooting) — so `./run.sh verify` fails on its first check, and `./run.sh deploy` writes it again |
| pod `client` in `envoy-17` | `./run.sh deploy` | nobody | a test tool |
| the Envoy's Deployment and Service in `envoy-gateway-system` | Envoy Gateway | Envoy Gateway | made from the Gateway |

### Walkthroughs, experiments and clean

Step 7 deletes the `BackendTLSPolicy` to show the Gateway failing closed. With
Argo CD on, the policy would be put back like the ConfigMap above, and the
failure would not show. So step 7 pauses this module's Application first and
resumes it after — `./run.sh pause`, `./run.sh resume` on its command lines, as
in module 16's [Permanent lab](../16-keycloak/README.md#permanent-lab); they do
nothing on a cluster without the Application.
To walk the module again from the start, `./run.sh clean` pauses it for you, and
`./run.sh resume` hands the lab back once you are done — or `./run.sh deploy`,
which resumes it at its end.

## Clean up

On the permanent lab a clean-up is a deliberate reset, never the end of a
walkthrough — leave the Gateway running, as module 16 leaves Keycloak. Pause
Argo CD first: it would put the manifests back as you delete them, and it
cannot put back the `nonroot-v2` grant or ConfigMap `keycloak-ca`, which are
`run.sh`'s ([Permanent lab](#permanent-lab)). `./run.sh clean` does both.

Remove this module's Gateway and what it added next to Keycloak; the Keycloak
lab itself stays (module 16 removes it), and so do realm `corp` (module 18) and
the directory's shop users (the chart's `ldap-shop-users.ldif`):

<!-- walkthrough: skip -->
```console
$ ./run.sh pause
  ✓ Argo CD Application 17-keycloak-jwt paused: it no longer puts back what changes
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

`./run.sh deploy` does steps 2 to 6, and resumes Argo CD's Application if there
is one; `./run.sh verify` is step 11; `./run.sh clean` is the clean-up, with the
Application paused first; `./run.sh pause` and `./run.sh resume` are the
[Permanent lab](#permanent-lab)'s.

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
