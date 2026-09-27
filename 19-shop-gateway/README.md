# 19 — the shop behind the Gateway: sign in with the directory

Modules 16 to 18 built the identity side: Keycloak, the realm `corp` whose
people come from the cluster's LDAP directory, and a Gateway that checks
`corp`'s tokens — in front of an echo app. This module puts a **real
application** there: the shop from
[`envoy-grpc-modernization`](https://github.com/ephico2real2/envoy-grpc-modernization)
— a browser page, the kiosk, and a gRPC-only inventory service behind its own
Envoy. People **sign in on realm `corp`'s login page** with their directory
account, the Gateway **checks a JWT on every call**, and **LDAP groups** decide
what each person may do.

Everything here is the Gateway API and Envoy Gateway's own policy: a `Gateway`,
an `HTTPRoute` and **one `SecurityPolicy`**. Module 20 builds the same shop with a
standalone Envoy — the `oauth2`, `jwt_authn` and `rbac` filters written by hand —
behind an OpenShift Route; [the last section](#module-20-does-this-by-hand) maps
one onto the other.

## What you'll learn

- how a Gateway signs a browser in — the OpenID Connect authorization-code flow
  with PKCE, `SecurityPolicy.oidc` — and keeps the session in cookies
- why **the JWT is the contract**: the browser's session and a command-line
  caller's bearer token are checked by the same JWT provider and the same rules
- how to authorise by **role, method and path** (`SecurityPolicy.authorization`),
  and how a change in the directory changes what someone may do

## Before you start

- Module [`16`](../16-keycloak/README.md)'s Keycloak and module
  [`18`](../18-keycloak-ldap/README.md)'s realm `corp` are running
  (`../18-keycloak-ldap/run.sh verify` passes), and the directory has the shop's
  users `shop.alice` and `shop.bob` (module 17, "Before you start").
- Module 16's `BackendTLSPolicy` `keycloak/keycloak-service` (its step 11) is
  there: it is how **every** Gateway reaches Keycloak's Service over TLS. A
  Service port takes one `BackendTLSPolicy` (module 15), so this module uses that
  one rather than adding a second.
- Envoy Gateway is installed (module [`12`](../12-gateway-api/README.md)).
- Work from this folder: `cd 19-shop-gateway`.
- This module uses the namespace **`envoy-19`**, adds a `ReferenceGrant` to
  **`keycloak`**, adds a client to realm `corp` (step 2), and takes about 40
  minutes — its `verify` alone waits six minutes for a token to expire. On the
  operator's CRC it is **permanent**, kept by Argo CD: see
  [Permanent lab](#permanent-lab) before you change anything by hand there.

## The concept

A person opens the shop. The Gateway sees no session and sends the browser to
**realm `corp`'s login page**. The person signs in with their directory account —
only members of the login gate `app-ssb-autobahnusers` can (module 18, step 8).
Keycloak sends the browser back to the Gateway with a one-time **code**; the
Gateway swaps it for tokens at Keycloak — it is the OpenID Connect client, not
the page — and keeps them, encrypted, in **cookies**. From then on, every
request the browser makes carries the cookies, and the Gateway sends it on to the
shop with the **access token** as `Authorization: Bearer <JWT>` — after checking
that JWT exactly as it checks one a command-line caller sends itself, and after
checking what its **realm roles** allow for this **method** and **path**.

One `SecurityPolicy`, three of Envoy's filters, in this order (Envoy Gateway
v1.9.1, `internal/xds/translator/httpfilters.go`: `oauth2` 9, `jwt_authn` 10,
`rbac` 301):

| Filter | From the policy's | Does |
|---|---|---|
| `oauth2` | `oidc` | no session: a redirect to the login page; `/oauth2/callback`: code for tokens; a session: its access token sent on as a bearer token. A request that already carries `Authorization: Bearer …` skips it |
| `jwt_authn` | `jwt` | checks the JWT: issuer `…/realms/corp`, audience `shop-api`, signature, expiry |
| `rbac` | `authorization` | the realm role `admin` may do anything; any `corp` token may `GET` and reserve stock; everything else is `403` |

<!-- markdownlint-disable MD033 -->
<img alt="Two callers reach Gateway eg in envoy-19. A browser on the laptop reaches it at http://localhost:19080, which CRC's network proxy forwards to the Gateway's MetalLB address; a command-line caller sends Authorization: Bearer with a JWT from client shop-cli. The Gateway runs one SecurityPolicy as three filters in order. First oauth2: a browser without a session gets a 302 to realm corp's login page at keycloak.apps-crc.testing, as client shop-kiosk with a PKCE S256 challenge; after the person signs in, Keycloak sends the browser back to /oauth2/callback with a code, which the Gateway swaps for tokens at keycloak-service:8443 and keeps in Secure, HttpOnly, SameSite=Lax cookies; on every later request it forwards the access token as Authorization: Bearer; a request that already carries a Bearer header skips this filter. Second jwt_authn: issuer realms/corp, audience shop-api, the signature with corp's public keys fetched from keycloak-service:8443 over TLS through module 16's BackendTLSPolicy and a ReferenceGrant, cached 300 seconds, and the expiry. Third rbac: the realm role admin may do anything; any corp token may GET and POST items/sku:reserve; everything else is denied with 403. Keycloak reads each person and their groups from the LDAP directory at every login: only members of app-ssb-autobahnusers may sign in, and app-ocp-rbac-ocp-keycloak-admin becomes the role admin. Allowed requests reach the shop vendored from envoy-grpc-modernization: its own Envoy turns REST and JSON into gRPC, then three inventory pods and MongoDB, and the kiosk page; NetworkPolicies let only this Gateway's Envoy call it. Measured answers, the same in the browser and on the command line: shop.alice lists and reserves, 200, and gets 403 RBAC access denied on create, delete and reset; shop.bob creates, deletes and resets, 200. An edited JWT gets 401 Jwt verification fails, a JWT from realm tutorial 401 Jwt issuer is not configured, an expired JWT 401 Jwt is expired; bob.wilson cannot sign in, Invalid username or password, user_not_found; the shop's Envoy called directly does not answer. Removing shop.bob from the admin group in LDAP takes admin away at his next sign-in, and from an open session at its next token refresh." src="../docs/diagrams/19-shop-gateway/flow.light.png">
<!-- markdownlint-enable MD033 -->

### The choices, and why

Researched before building — Envoy Gateway v1.9.1's source, Envoy 1.39.1's, the
Keycloak documentation — and measured on CRC:

1. **Browser sign-in: `SecurityPolicy.oidc`.** Envoy Gateway turns it into Envoy's
   `oauth2` filter. It needs, from Keycloak, a **confidential client** with the
   Gateway's callback as its redirect URI; the client secret goes in a Secret
   under the key `client-secret` (`api/v1alpha1/oidc_types.go`). **PKCE:** Envoy
   always sends a `code_challenge` with `code_challenge_method=S256`
   (`source/extensions/filters/http/oauth2/filter.cc`, lines 1335–1337), so the
   client can **require** it — Keycloak's `pkce.code.challenge.method: S256`
   (Server Administration Guide, "Proof Key for Code Exchange") — and step 7 shows
   the challenge in the redirect. Both of the provider's endpoints are written in
   the policy: given only the issuer, the Envoy Gateway **controller** fetches the
   discovery document itself, trusting the CA and the name of the provider's
   `BackendTLSPolicy` (`internal/gatewayapi/securitypolicy.go`,
   `buildOIDCProvider`) — measured: `Accepted=False`, `x509: certificate is valid
   for *.apps-crc.testing, not keycloak-service.keycloak.svc`, and a `500` on
   every route (Troubleshooting).
2. **The API calls after sign-in: the session, turned into a bearer JWT.** The
   calls carry the session cookies; `forwardAccessToken: true` makes the `oauth2`
   filter send the access token on as `Authorization: Bearer`, and the `jwt`
   provider in the same policy checks **that** JWT — so the browser's calls and a
   command-line caller's meet the same check and the same rules.
   `passThroughAuthHeader: true` lets a request that brings its own bearer token
   skip the sign-in (`internal/xds/translator/oidc.go`, `buildHeaderMatchers`:
   `Authorization`, prefix `Bearer `). Measured: the token the Gateway sends on
   for a browser session names `azp: shop-kiosk` (step 8), a command-line one
   `azp: shop-cli` (module 18, step 9), and both get the same answers (steps 9,
   10 and 12).
3. **REST from gRPC: the Gateway in front of the shop's own Envoy.** Envoy
   Gateway has no API for `grpc_json_transcoder` — its only mention in v1.9.1 is
   the type registered for xDS (`internal/xds/extensions/extensions.gen.go`,
   line 159). The two ways to add it anyway: an **`EnvoyPatchPolicy`**, a JSON
   patch against the xDS Envoy Gateway generates — off unless the controller's
   configuration enables it, which the API calls a risk of "complete security
   compromise" (`api/v1alpha1/envoygateway_types.go`; off here:
   `extensionApis: {}`), and it would also have to get the binary descriptor into
   the distroless proxy; or an **`EnvoyExtensionPolicy`**, which adds Wasm, Lua,
   ext_proc or dynamic modules — none of them the transcoder. Chosen on "easy to
   maintain": **the shop keeps its own Envoy**, vendored unchanged, owned by the
   app team; the Gateway adds sign-in and permissions, owned by the platform. Two
   owners, two files, and the app repository's REST surface works the same with
   or without the Gateway.
4. **How a browser on the laptop reaches the Gateway: its MetalLB address,
   through CRC's network proxy.** The Gateway's address is on the CRC VM's
   network, which the laptop does not route to (module 12, step 6: `curl exit
   code 28`); CRC's network proxy, gvproxy, is the one way in, and its API adds a
   forward from a port on the laptop to that address (step 7). No OpenShift Route
   — module 20's way in — and no `oc port-forward`. What it means for sign-in,
   measured:
   - the browser opens **`http://localhost:19080`**, and that is the **redirect
     URI**, fixed in the policy and registered as the client's only one;
   - Envoy sets its cookies **`secure`** always (`oauth2/filter.cc`, line 57:
     `;path={};Max-Age={};secure;HttpOnly{}`), over plain HTTP here. Browsers keep
     Secure cookies from `localhost`, which they treat as a secure origin
     ([MDN: Secure contexts](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts)):
     measured with a headless Chromium (Playwright), a whole sign-in as
     `shop.alice` at `http://localhost:19080` ended on the kiosk with the five
     session cookies `Secure`, `HttpOnly`, `SameSite=Lax`, and the kiosk's own
     calls answered `200` for the items and `403 RBAC: access denied` for a
     reset. Under **another name** for the same address (`shop19.test`, mapped to
     127.0.0.1) the same Chromium kept **none** of the Gateway's cookies;
   - so the Gateway needs **no HTTPS listener** as long as the browser uses
     `localhost`. Any other hostname needs one — a listener with a certificate,
     from `enterprise-ca` here — and a redirect URI with `https://`.
   On bare metal a MetalLB address is on a network the clients route to: no
   forward, and the browser uses the Gateway's own hostname, over HTTPS.
5. **The kiosk's client in realm `corp`.** An import only creates a realm, so
   adding a client is module 18's measured procedure (step 13 there): pause its
   Application, delete the realm, delete the import, apply, resume — step 2. The
   rebuilt realm has new signing keys, so module 17's Gateway refused `corp`'s
   new tokens until its key cache (300 s) expired (module 18, step 13) — module
   17's `verify`, run 11 minutes after the rebuild, passed. One more change rode
   along, found while building step 13 of this module: with Keycloak's default **user cache**,
   removing `shop.bob` from the admin group in the directory changed nothing —
   his next tokens still had `admin`, 1 s and 6 s later — until the realm's user
   cache was cleared. The LDAP provider now says `cachePolicy: NO_CACHE`: Keycloak
   reads the person and their groups from the directory at every login (the
   component setting `cachePolicy`: `DEFAULT`, `EVICT_DAILY`, `EVICT_WEEKLY`,
   `MAX_LIFESPAN` or `NO_CACHE` — Keycloak 26.6.0,
   `model/storage/src/main/java/org/keycloak/storage/CacheableStorageProviderModel.java`;
   the Server Administration Guide: "operations that fetch a single user (for
   example during login) are usually cached").

**The client secret is written nowhere.** Module 16's "Adding an integration"
recipe: credentials reach a realm through `spec.placeholders` from a Secret,
owned by whoever owns the import. Realm `corp`'s import is module 18's, so module
18's `run.sh deploy` generates Secret `keycloak/shop-kiosk-client` once — a
random value — and never replaces it; this module's `run.sh deploy` copies the
value into the Gateway's Secret `envoy-19/shop-kiosk-oidc` (step 6). Neither is in
git, so neither is Argo CD's. What happens when the import runs before the Secret
exists is measured in module 18 ("Permanent lab"): its Job waits, and completes
once the Secret is there.

## Walkthrough

### Step 1 — what this module builds on

```console
$ oc get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
True
$ oc get keycloakrealmimport corp -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}{"\n"}'
True
$ oc get backendtlspolicy keycloak-service -n keycloak -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
True
```

**What just happened:** Keycloak is up, realm `corp` is imported, and module
16's `BackendTLSPolicy` to Keycloak's Service is accepted — the Gateway will
reach Keycloak through it.

### Step 2 — realm `corp` gets the kiosk's client

The Gateway signs people in as a client of realm `corp`: `shop-kiosk`, in module
18's realm file ([`../18-keycloak-ldap/manifests/20-realm.yaml`](../18-keycloak-ldap/manifests/20-realm.yaml)):

| Field | Here | Why |
|---|---|---|
| `publicClient` | `false`, with a `secret` | the Gateway is a server: it can keep a secret, and proves itself with it when it swaps a code for tokens |
| `standardFlowEnabled` | `true` | the authorization-code flow — the login page |
| `directAccessGrantsEnabled` | `false` | no passwords sent to the token endpoint by this client |
| `redirectUris` | `http://localhost:19080/oauth2/callback` | the one place Keycloak sends a code back to |
| `attributes.pkce.code.challenge.method` | `S256` | refuse a code request without a PKCE challenge |
| `attributes.post.logout.redirect.uris` | `http://localhost:19080/` | where `/logout` may send the browser back to |
| an audience mapper | `shop-api` | its tokens are for the shop's API, as `shop-cli`'s are |

Is it in the realm?

```console
$ ../18-keycloak-ldap/admin.sh GET '/admin/realms/corp/clients?clientId=shop-kiosk' | python3 -c 'import json,sys; [print(c["clientId"], "| confidential:", not c["publicClient"], "| redirect:", c["redirectUris"], "| PKCE:", c["attributes"].get("pkce.code.challenge.method"), "| after logout:", c["attributes"].get("post.logout.redirect.uris")) for c in json.load(sys.stdin)]'
shop-kiosk | confidential: True | redirect: ['http://localhost:19080/oauth2/callback'] | PKCE: S256 | after logout: http://localhost:19080/
```

**What just happened:** the client is there. If the command prints nothing, the
realm predates it: an import only creates, so re-import `corp` the measured way
(module 18, step 13). On the permanent lab Argo CD keeps the import, so pause it
first and resume it after. Run as written on 2026-09-27, 15:42–15:44 UTC:

<!-- walkthrough: skip -->
```console
$ ../18-keycloak-ldap/run.sh pause
  ✓ Argo CD Application 18-keycloak-ldap paused: it no longer puts back what changes
$ ../18-keycloak-ldap/admin.sh DELETE /admin/realms/corp
deleted /admin/realms/corp
$ oc delete keycloakrealmimport corp -n keycloak
keycloakrealmimport.k8s.keycloak.org "corp" deleted from keycloak namespace
$ oc apply -f ../18-keycloak-ldap/manifests/20-realm.yaml
keycloakrealmimport.k8s.keycloak.org/corp created
$ oc wait keycloakrealmimport/corp -n keycloak --for=condition=Done --timeout=300s
keycloakrealmimport.k8s.keycloak.org/corp condition met
$ ../18-keycloak-ldap/run.sh resume
  ✓ Argo CD Application 18-keycloak-ldap resumed: Synced/Healthy - it keeps the lab as git declares it
```

Deleting the realm deleted what Keycloak held for it — the users it had
imported, their sessions — safe for `corp`, whose people come back from the
directory at their next login. It also gave `corp` new signing keys: for up to
five minutes, module 17's Gateway refuses `corp`'s new tokens with `Jwks doesn't
have key to match kid` (module 18, step 13).

### Step 3 — a Gateway

As in module 17, step 2 — module 12's `GatewayClass`, a `Gateway` in this
module's namespace ([`manifests/10-gateway.yaml`](manifests/10-gateway.yaml)),
and the `nonroot-v2` grant for its Envoy (module 12, step 4):

```console
$ oc apply -f ../12-gateway-api/manifests/20-envoyproxy.yaml -f ../12-gateway-api/manifests/10-gatewayclass.yaml
envoyproxy.gateway.envoyproxy.io/openshift-scc unchanged
gatewayclass.gateway.networking.k8s.io/eg unchanged
$ oc apply -f manifests/10-gateway.yaml
namespace/envoy-19 created
gateway.gateway.networking.k8s.io/eg created
$ sleep 10; oc adm policy add-scc-to-user nonroot-v2 -n envoy-gateway-system -z "$(oc get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-19 -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}')"
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:nonroot-v2 added: "envoy-envoy-19-eg-413e95da"
$ oc rollout restart deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-19
deployment.apps/envoy-envoy-19-eg-413e95da restarted
$ oc rollout status deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-19 --timeout=240s
Waiting for deployment "envoy-envoy-19-eg-413e95da" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "envoy-envoy-19-eg-413e95da" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "envoy-envoy-19-eg-413e95da" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-19-eg-413e95da" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-19-eg-413e95da" rollout to finish: 1 old replicas are pending termination...
deployment "envoy-envoy-19-eg-413e95da" successfully rolled out
$ oc wait gateway/eg -n envoy-19 --for=condition=Programmed --timeout=120s
gateway.gateway.networking.k8s.io/eg condition met
```

### Step 4 — the shop, from its own repository

The shop is `envoy-grpc-modernization`'s own code and manifests, not a fork.
[`vendor.sh`](vendor.sh) writes this module's copy from that repository at a
commit: each of its manifests with the namespace changed to `envoy-19`, and each
source file as a ConfigMap — the way its `demo.sh` builds them. The one
difference: the kiosk's OpenShift Route is left out. Which commit:

```console
$ grep -h '^# at ' manifests/2[1-8]-shop-*.yaml | sort -u
# at 1e3ad13938f7ecef81d4a7717b18f7874384b4de. Do not edit here: change the app repository, then run vendor.sh.
```

| File | What |
|---|---|
| [`20-shop-db-secret.yaml`](manifests/20-shop-db-secret.yaml) | the database password — the app's `demo.sh` generates one; here a LAB value, so Argo CD can keep it |
| `21` … `28` | MongoDB and its claim; the inventory service (gRPC only, three pods, a headless Service) and its source; the shop's Envoy, its configuration (`grpc_json_transcoder`) and the proto descriptor; the kiosk page and its web server |
| [`40-route.yaml`](manifests/40-route.yaml) | the `HTTPRoute`: `/v1/…` and `/` to the shop's Envoy; `/oauth2/callback` and `/logout` for the sign-in; `/whoami` to the echo app (step 8) |

```console
$ oc apply -f manifests/20-shop-db-secret.yaml -f manifests/21-shop-database.yaml -f manifests/22-shop-inventory-src.yaml -f manifests/23-shop-inventory.yaml -f manifests/24-shop-envoy-config.yaml -f manifests/25-shop-envoy-proto.yaml -f manifests/26-shop-envoy.yaml -f manifests/27-shop-kiosk-src.yaml -f manifests/28-shop-kiosk.yaml
secret/inventory-db created
persistentvolumeclaim/inventory-db created
service/inventory-db created
deployment.apps/inventory-db created
configmap/inventory-src created
service/inventory created
deployment.apps/inventory created
configmap/envoy-config created
configmap/envoy-proto created
service/envoy created
deployment.apps/envoy created
configmap/kiosk-src created
service/kiosk created
deployment.apps/kiosk created
$ oc apply -n envoy-19 -f ../_shared/client.yaml -f ../_shared/echo-app.yaml -f manifests/40-route.yaml
pod/client created
configmap/echo-src created
service/echo created
deployment.apps/echo created
httproute.gateway.networking.k8s.io/shop created
$ for d in inventory-db inventory envoy kiosk echo; do oc rollout status -n envoy-19 deploy/$d --timeout=300s; done
Waiting for deployment "inventory-db" rollout to finish: 0 of 1 updated replicas are available...
deployment "inventory-db" successfully rolled out
Waiting for deployment "inventory" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "inventory" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "inventory" rollout to finish: 2 of 3 updated replicas are available...
deployment "inventory" successfully rolled out
deployment "envoy" successfully rolled out
deployment "kiosk" successfully rolled out
deployment "echo" successfully rolled out
$ oc wait -n envoy-19 --for=condition=Ready pod/client --timeout=120s
pod/client condition met
```

Is it answering through the Gateway yet? The inventory's pods take a while to
start (they install their Python packages first), and the very first calls can
fail: in this module's first run from scratch, both calls below answered `503`
right after the rollouts. Ask until one answers — each attempt that does not
prints the Gateway's answer:

```console
$ for i in $(seq 1 30); do r=$(oc exec -n envoy-19 client -- curl -s -w ' %{http_code}' "http://$(oc get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}')/v1/items/SKU-1001"); case "$r" in *' 200') echo "attempt $i: 200"; break ;; *) echo "attempt $i: $r"; sleep 2 ;; esac; done
attempt 1: no healthy upstream 503
attempt 2: 200
```

In the run shown, the first attempt got Envoy's `no healthy upstream` — a cluster with no endpoint
yet; which Envoy, the Gateway's or the shop's, the answer does not say — and
the second the shop. The shop answers through the Gateway — to anyone, for
anything:

```console
$ oc exec -n envoy-19 client -- curl -s -o /dev/null -w 'no token, GET /v1/items -> %{http_code}\n' "http://$(oc get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}')/v1/items"
no token, GET /v1/items -> 200
$ oc exec -n envoy-19 client -- curl -s -o /dev/null -w 'no token, POST /v1/items/SKU-1001:reserve -> %{http_code}\n' -H 'content-type: application/json' -d '{"quantity":1,"orderId":"ANYONE"}' "http://$(oc get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}')/v1/items/SKU-1001:reserve"
no token, POST /v1/items/SKU-1001:reserve -> 200
```

**What just happened:** the Gateway sent both on — a read and a write, from
nobody in particular. The rest of this module closes that.

### Step 5 — the Gateway is the only way in

A policy on the Gateway guards the Gateway, not the Services behind it: any pod
in the cluster could call the shop's Envoy at `envoy.envoy-19.svc:8080` and skip
it. [`manifests/30-network-policy.yaml`](manifests/30-network-policy.yaml) lets
each layer accept only the one in front of it — this Gateway's Envoy, then the
shop's Envoy, then the inventory, then MongoDB:

```console
$ oc apply -f manifests/30-network-policy.yaml
networkpolicy.networking.k8s.io/shop-envoy-from-gateway created
networkpolicy.networking.k8s.io/echo-from-gateway created
networkpolicy.networking.k8s.io/kiosk-from-shop-envoy created
networkpolicy.networking.k8s.io/inventory-from-shop-envoy created
networkpolicy.networking.k8s.io/database-from-inventory created
$ sleep 5; oc exec -n envoy-19 client -- curl -s -m 5 -o /dev/null -w 'the shop Envoy, directly -> %{http_code}\n' http://envoy:8080/v1/items; echo "curl exit code $?"
the shop Envoy, directly -> 000
command terminated with exit code 28
curl exit code 28
$ oc exec -n envoy-19 client -- curl -s -o /dev/null -w 'through the Gateway -> %{http_code}\n' "http://$(oc get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}')/v1/items"
through the Gateway -> 200
```

**What just happened:** straight to the shop's Envoy, **no answer** — `000`,
`curl` gave up after 5 s (exit code 28): OVN-Kubernetes dropped the connection.
Through the Gateway, `200`: the Gateway's Envoy is the one caller the policy
admits.

### Step 6 — sign-in, the JWT and the permissions: one SecurityPolicy

The client secret first. Module 18 generated it, in Secret `shop-kiosk-client`
in `keycloak`, and the realm was imported with it (step 2); Envoy Gateway reads a
client secret from a Secret in the policy's own namespace, under the key
`client-secret`. Copy it across — the value goes from one Secret to the other
through a pipe, never on a command line or the screen:

```console
$ oc get secret shop-kiosk-client -n keycloak -o jsonpath='{.data.client-secret}' | base64 -d | oc create secret generic shop-kiosk-oidc -n envoy-19 --from-file=client-secret=/dev/stdin --dry-run=client -o yaml | oc apply -f -
secret/shop-kiosk-oidc created
```

Then [`manifests/50-trust-keycloak.yaml`](manifests/50-trust-keycloak.yaml), a
`ReferenceGrant` in `keycloak` — a policy in `envoy-19` may point at
`keycloak-service` — and [`manifests/70-sign-in.yaml`](manifests/70-sign-in.yaml),
the policy, on the whole Gateway — read it: every field has its reason beside
it, and [The options](#the-options) lists them.

```console
$ oc apply -f manifests/50-trust-keycloak.yaml -f manifests/70-sign-in.yaml
referencegrant.gateway.networking.k8s.io/envoy-19-signs-in-with-keycloak created
securitypolicy.gateway.envoyproxy.io/sign-in created
$ sleep 20; oc get securitypolicy sign-in -n envoy-19 -o jsonpath='{range .status.ancestors[0].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
Accepted=True Policy has been accepted.
$ oc exec -n envoy-19 client -- curl -s -o /dev/null -w 'no token, GET /v1/items -> %{http_code}\n' "http://$(oc get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}')/v1/items"
no token, GET /v1/items -> 302
$ oc exec -n envoy-19 client -- curl -s -o /dev/null -w 'no token, POST /v1/items/SKU-1001:reserve -> %{http_code}\n' -H 'content-type: application/json' -d '{"quantity":1,"orderId":"ANYONE"}' "http://$(oc get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}')/v1/items/SKU-1001:reserve"
no token, POST /v1/items/SKU-1001:reserve -> 302
```

**What just happened:** the policy is accepted, and step 4's two requests now get
**`302`** — a redirect, to sign in. Neither reached the shop.

### Step 7 — how your browser reaches a MetalLB address on CRC

The Gateway's address, from the laptop:

```console
$ oc get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}{"\n"}'
192.168.127.102
$ curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$(oc get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}')/"; echo "curl exit code $?"
000
curl exit code 28
```

**What just happened:** MetalLB gave the Gateway an address on the CRC VM's
network, and from the laptop it does not answer — `000`, a timeout (exit code
28): the laptop has no route to that network. CRC's network proxy, gvproxy, is
how the laptop reaches the VM at all — it forwards the laptop's ports 80 and 443
to the OpenShift router, 127.0.0.1:6443 to the API server — and its API, on the
unix socket `~/.crc/sockets/crc-http.sock`, adds more.
[`../_shared/crc-forward.sh`](../_shared/crc-forward.sh) asks it for one: the
laptop's `127.0.0.1:19080` to the Gateway's address, port 80, read from the
Gateway's status. It first checks that nothing on the laptop listens on 19080,
does nothing when the same forward is already there, refuses one that points
elsewhere, and never touches CRC's own forwards:

```console
$ lsof -nP -iTCP:19080 -sTCP:LISTEN; echo "lsof exit code $? - 1: nothing listens on 19080"
lsof exit code 1 - 1: nothing listens on 19080
$ ../_shared/crc-forward.sh ensure 127.0.0.1:19080 "$(oc get gateway eg -n envoy-19 -o jsonpath='{.status.addresses[0].value}'):80"
127.0.0.1:19080 -> 192.168.127.102:80: forwarded
$ ../_shared/crc-forward.sh list
/Users/olasumbo/.crc/machines/crc/docker.sock -> ssh-tunnel://core@192.168.127.2:22/run/podman/podman.sock?key=%2FUsers%2Folasumbo%2F.crc%2Fmachines%2Fcrc%2Fid_ed25519
127.0.0.1:19080 -> 192.168.127.102:80
127.0.0.1:20443 -> 192.168.127.130:443
127.0.0.1:2222 -> 192.168.127.2:22
127.0.0.1:6443 -> 192.168.127.2:6443
:443 -> 192.168.127.2:443
:80 -> 192.168.127.2:80
```

Now from the laptop, as a browser would:

```console
$ curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://localhost:19080/ | python3 -c 'import sys, urllib.parse as u; code, url = sys.stdin.read().split(); p = u.urlsplit(url); q = u.parse_qs(p.query); print(code, "->", p.scheme + "://" + p.netloc + p.path); [print("  ", k, "=", q[k][0] if k not in ("code_challenge", "state") else "<%d characters>" % len(q[k][0])) for k in sorted(q)]'
302 -> https://keycloak.apps-crc.testing/realms/corp/protocol/openid-connect/auth
   client_id = shop-kiosk
   code_challenge = <43 characters>
   code_challenge_method = S256
   redirect_uri = http://localhost:19080/oauth2/callback
   response_type = code
   scope = openid
   state = <186 characters>
```

**What just happened:** `GET /` from the laptop got a **`302` to realm `corp`'s
authorization endpoint**, for client `shop-kiosk`, with a **PKCE** challenge
(`code_challenge`, `S256`), naming where to come back to:
`http://localhost:19080/oauth2/callback` — this forward. The `state` carries the
page first asked for and a nonce the Gateway also put in a cookie, so the
callback can be tied to this browser. Open **<http://localhost:19080>** in a
browser to use the shop; Keycloak's page is served with a certificate from the
lab's enterprise CA, which the laptop does not trust, so the browser warns once
(module 16, step 7). Plain HTTP is enough on `localhost` — "The choices", item 4.

The forward lives in the running gvproxy: `crc stop` and `crc start` lose it
(not measured here — the lab's CRC is not restarted for it), and
`./run.sh deploy` or `./run.sh verify` makes it again. `./run.sh clean` removes
it; `./run.sh pause` leaves it. On bare metal none of this step exists: the
MetalLB address is routable, and the browser goes to it directly.

### Step 8 — sign in, as a browser does

[`browser.sh`](browser.sh) does what a browser does, with `curl` in the client
pod, so each hop can be seen: it asks the shop, follows the redirect to the login
page, posts the user name and password to its form, and brings the code back to
the Gateway. It asks for `http://localhost:19080`, as the browser does, and sends
the connection to the Gateway's address (`curl --connect-to`): the Gateway sees
the same Host, redirect URI and cookies as from the laptop. The password — the
directory's published lab value — goes to the pod on standard input.

```console
$ ./browser.sh sign-in shop.alice
1. GET http://localhost:19080/ -> 302, to https://keycloak.apps-crc.testing/realms/corp/protocol/openid-connect/auth?...
2. corp login page: a form posting to https://keycloak.apps-crc.testing/realms/corp/login-actions/authenticate
3. signed in as shop.alice -> 302, back to http://localhost:19080/oauth2/callback?code=...
4. the Gateway swapped the code for tokens -> 302, to http://localhost:19080/
   its session cookies: AccessToken IdToken OauthExpires OauthHMAC RefreshToken 
```

**What just happened:**

1. no session: `302` to `corp`'s login page;
2. the login page, `corp`'s — its form posts to `…/login-actions/authenticate`;
3. the password accepted — Keycloak found `shop.alice` through the gate and
   checked her password by binding to the directory as her (module 18, step 9) —
   and a `302` back to the Gateway's callback, with a code;
4. the Gateway swapped the code for tokens at `keycloak-service` (its token
   endpoint, inside the cluster), set its **session cookies** — the access token,
   the ID token and the refresh token, encrypted, plus an HMAC over them and their
   expiry — and sent the browser on to the page it first asked for, `/`.

What does the shop receive from her session? `/whoami` goes to the echo app,
which answers with the request headers it got (a lab-only route —
[`40-route.yaml`](manifests/40-route.yaml)). The command decodes the bearer token
the Gateway sent on and prints its claims, never the token:

```console
$ ./browser.sh shop.alice GET /whoami | python3 -c 'import base64,json,sys; h = json.load(sys.stdin)["headers"]; print("the app got:", sorted(h)); print("x-user:", h["x-user"]); p = h["authorization"].split()[1].split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); print("the JWT in authorization:"); [print("  ", k, c.get(k)) for k in ("iss", "aud", "azp", "preferred_username")]; print("   roles", sorted(c["realm_access"]["roles"])); print("   lives", c["exp"] - c["iat"], "s")'
the app got: ['accept', 'authorization', 'host', 'user-agent', 'x-envoy-external-address', 'x-forwarded-for', 'x-forwarded-proto', 'x-request-id', 'x-user']
x-user: shop.alice
the JWT in authorization:
   iss https://keycloak.apps-crc.testing/realms/corp
   aud ['shop-api', 'account']
   azp shop-kiosk
   preferred_username shop.alice
   roles ['default-roles-corp', 'offline_access', 'uma_authorization']
   lives 300 s
```

**What just happened:** the shop is told who is calling twice over: `x-user` —
the Gateway set it from the verified token — and the **JWT itself**, in
`authorization`: issued by `…/realms/corp`, for `shop-api`, to **`shop-kiosk`**
(the browser's client, `azp`), as `shop.alice`, with no `admin` role, for 300 s.
No `cookie` header: the route drops the session cookies, which the app has no
use for. The session is a cookie at the browser and a JWT everywhere after the
Gateway.

### Step 9 — what `shop.alice` may do

The kiosk's calls, made with her session:

```console
$ ./browser.sh shop.alice GET /v1/items -o /dev/null -w 'GET    /v1/items                    -> %{http_code}\n'
GET    /v1/items                    -> 200
$ ./browser.sh shop.alice GET /v1/warehouses -o /dev/null -w 'GET    /v1/warehouses               -> %{http_code}\n'
GET    /v1/warehouses               -> 200
$ ./browser.sh shop.alice POST /v1/items/SKU-1001:reserve -H 'content-type: application/json' -d '{"quantity":1,"orderId":"ALICE-1"}' -o /dev/null -w 'POST   /v1/items/SKU-1001:reserve   -> %{http_code}\n'
POST   /v1/items/SKU-1001:reserve   -> 200
$ ./browser.sh shop.alice POST /v1/items -H 'content-type: application/json' -d '{"sku":"SKU-T19","name":"a test item","onHand":5,"warehouse":"LEEDS"}' -w '   POST /v1/items -> %{http_code}\n'
RBAC: access denied   POST /v1/items -> 403
$ ./browser.sh shop.alice DELETE /v1/items/SKU-1001 -w '   DELETE /v1/items/SKU-1001 -> %{http_code}\n'
RBAC: access denied   DELETE /v1/items/SKU-1001 -> 403
$ ./browser.sh shop.alice POST /v1/items:reset -H 'content-type: application/json' -d '{}' -w '   POST /v1/items:reset -> %{http_code}\n'
RBAC: access denied   POST /v1/items:reset -> 403
```

**What just happened:** she lists the items and the warehouses and reserves
stock — `200` — and gets **`403 RBAC: access denied`** on create, delete and
reset: signed in, but not allowed. The policy's rules, in order, first match
wins:

| Rule | Allows | For |
|---|---|---|
| `admins` | anything | a token whose `realm_access.roles` holds `admin` |
| `signed-in-may-read` | `GET` | any token `corp` signed |
| `signed-in-may-reserve` | `POST` on `^/v1/items/[^/?#;]+:reserve$` | any token `corp` signed |
| (default) | nothing: `403` | |

The reserve rule's expression is matched against the whole `:path`, query
string included (v1.9.1, `authorization.go`, `buildPathPredicate`), so the item
may contain no `/`, `?`, `#` or `;` — measured with the looser `[^/]+`:
`shop.alice`'s `POST /v1/items/SKU-1001:restock?q=:reserve` got past the Gateway
to the shop (a `503` from the shop's Envoy, not a `403` here).

### Step 10 — `shop.bob`: admin, from his LDAP group

```console
$ ./browser.sh sign-in shop.bob >/dev/null; ./browser.sh shop.bob GET /whoami | python3 -c 'import base64,json,sys; h = json.load(sys.stdin)["headers"]; p = h["authorization"].split()[1].split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); print(c["preferred_username"], "| iss", c["iss"], "| aud", c["aud"], "| azp", c["azp"], "| roles", sorted(c["realm_access"]["roles"]))'
shop.bob | iss https://keycloak.apps-crc.testing/realms/corp | aud ['shop-api', 'account'] | azp shop-kiosk | roles ['admin', 'default-roles-corp', 'offline_access', 'uma_authorization']
$ ./browser.sh shop.bob POST /v1/items -H 'content-type: application/json' -d '{"sku":"SKU-T19","name":"a test item","onHand":5,"warehouse":"LEEDS"}' -o /dev/null -w 'POST   /v1/items (create SKU-T19) -> %{http_code}\n'
POST   /v1/items (create SKU-T19) -> 200
$ ./browser.sh shop.bob DELETE /v1/items/SKU-T19 -o /dev/null -w 'DELETE /v1/items/SKU-T19          -> %{http_code}\n'
DELETE /v1/items/SKU-T19          -> 200
$ ./browser.sh sign-out shop.bob
1. GET /logout -> 302, to https://keycloak.apps-crc.testing/realms/corp/protocol/openid-connect/logout?id_token_hint=...&client_id=shop-kiosk&post_logout_redirect_uri=http%3A%2F%2Flocalhost%3A19080%2F
   the Gateway session cookies left: 0
2. corp logout -> 302, to http://localhost:19080/
```

**What just happened:** `shop.bob`'s JWT carries **`admin`** — `corp` gives it to
the members of the LDAP group `app-ocp-rbac-ocp-keycloak-admin` (module 18, step
10) — so the first rule allows him everything: create, delete, `200`. Then he
signed out: `/logout` cleared the Gateway's cookies and sent the browser to
`corp`'s logout with his ID token, which ended his Keycloak session and sent him
back to the shop, `http://localhost:19080/` — the address registered as the
client's `post.logout.redirect.uris`.

### Step 11 — `bob.wilson` cannot sign in

`bob.wilson` is in the directory, outside the login gate:

<!-- walkthrough: expect-exit 1 -->
```console
$ ./browser.sh sign-in bob.wilson
1. GET http://localhost:19080/ -> 302, to https://keycloak.apps-crc.testing/realms/corp/protocol/openid-connect/auth?...
2. corp login page: a form posting to https://keycloak.apps-crc.testing/realms/corp/login-actions/authenticate
3. sign-in as bob.wilson refused: 200, Invalid username or password.
command terminated with exit code 1
```

```console
$ oc logs keycloak-0 -n keycloak | grep LOGIN_ERROR | grep 'clientId="shop-kiosk"' | grep 'username="bob.wilson"' | tail -n 1 | grep -o 'realmName="[^"]*"\|clientId="[^"]*"\|error="[^"]*"'
realmName="corp"
clientId="shop-kiosk"
error="user_not_found"
```

**What just happened:** the login page answered with itself again — `200`,
**`Invalid username or password.`**, no code — and Keycloak's log says why:
**`user_not_found`**. The gate is `corp`'s user search (module 18, step 8): he
never gets a token, so nothing reaches the Gateway to decide.

### Step 12 — the command line: the JWT is the contract

No browser: a token from `corp`'s `shop-cli` (module 17's
[`token.sh`](../17-keycloak-jwt/token.sh), the password grant — lab only) and
[`request.sh`](request.sh), which reads it on standard input and gives it to curl
as a config file, never as an argument (module 17, step 4). The same questions as
steps 9 and 10:

```console
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh GET /v1/items -o /dev/null -w 'shop.alice  GET    /v1/items                  -> %{http_code}\n'
shop.alice  GET    /v1/items                  -> 200
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh POST /v1/items/SKU-1001:reserve -H 'content-type: application/json' -d '{"quantity":1,"orderId":"ALICE-2"}' -o /dev/null -w 'shop.alice  POST   /v1/items/SKU-1001:reserve -> %{http_code}\n'
shop.alice  POST   /v1/items/SKU-1001:reserve -> 200
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh POST /v1/items -H 'content-type: application/json' -d '{"sku":"SKU-T19","name":"a test item","onHand":5,"warehouse":"LEEDS"}' -o /dev/null -w 'shop.alice  POST   /v1/items                  -> %{http_code}\n'
shop.alice  POST   /v1/items                  -> 403
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh POST /v1/items:reset -H 'content-type: application/json' -d '{}' -o /dev/null -w 'shop.alice  POST   /v1/items:reset            -> %{http_code}\n'
shop.alice  POST   /v1/items:reset            -> 403
$ ../17-keycloak-jwt/token.sh shop.bob | ./request.sh POST /v1/items -H 'content-type: application/json' -d '{"sku":"SKU-T19","name":"a test item","onHand":5,"warehouse":"LEEDS"}' -o /dev/null -w 'shop.bob    POST   /v1/items                  -> %{http_code}\n'
shop.bob    POST   /v1/items                  -> 200
$ ../17-keycloak-jwt/token.sh shop.bob | ./request.sh DELETE /v1/items/SKU-T19 -o /dev/null -w 'shop.bob    DELETE /v1/items/SKU-T19          -> %{http_code}\n'
shop.bob    DELETE /v1/items/SKU-T19          -> 200
```

**What just happened:** the same answers as in the browser. The token names
another client — `azp: shop-cli` — and came another way, but the Gateway asks the
same questions of it: who signed it, for whom, what roles. With a bearer token
the sign-in is skipped (`passThroughAuthHeader`), not the check. Now the tokens
that must not pass — one **edited** to add `admin`, one from realm **`tutorial`**
(module 16's alice: a real token, for `shop-api`, from another issuer):

```console
$ ../17-keycloak-jwt/token.sh shop.alice | python3 -c 'import base64,json,sys; h, p, s = sys.stdin.read().strip().split("."); c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); c["realm_access"]["roles"].append("admin"); print(".".join([h, base64.urlsafe_b64encode(json.dumps(c).encode()).decode().rstrip("="), s]))' | ./request.sh POST /v1/items:reset -H 'content-type: application/json' -d '{}' -w '  -> %{http_code}\n'
Jwt verification fails  -> 401
$ ../17-keycloak-jwt/token.sh alice | ./request.sh GET /v1/items -w '  -> %{http_code}\n'
Jwt issuer is not configured  -> 401
```

**What just happened:** **`401 Jwt verification fails`** — the claims no longer
match `corp`'s signature; **`401 Jwt issuer is not configured`** — the Gateway
trusts one issuer, `…/realms/corp`. And a token that was good and has **expired**
— taken, then used 365 s later (`corp`'s tokens live 300 s; Envoy allows 60 s of
clock skew, `jwt_verify_lib`'s `kClockSkewInSecond`):

<!-- walkthrough: skip -->
```console
$ t=$(../17-keycloak-jwt/token.sh shop.alice); sleep 365; printf '%s\n' "$t" | ./request.sh GET /v1/items -w '  -> %{http_code}\n'
Jwt is expired  -> 401
```

(Longer than the walkthrough runner's limit for one command, so it skips this
block; it was run as written, and `./run.sh verify` checks the same.)

### Step 13 — the directory decides

Who is an admin is decided in one place: the LDAP group. Take `shop.bob` out of
it, as the directory's administrator — the LDIF on standard input, the admin
password read inside the directory's pod, never on a command line:

```console
$ printf 'dn: cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,dc=ephico2real,dc=com\nchangetype: modify\ndelete: member\nmember: uid=shop.bob,ou=People,dc=ephico2real,dc=com\n' | oc exec -i -n ldap-testing deploy/openldap-server -c openldap -- sh -c 'exec 3<&0; printf %s "$LDAP_ADMIN_PASSWORD" | ldapmodify -x -H ldap://localhost:389 -D "cn=admin,$LDAP_BASE_DN" -y /dev/stdin -f /dev/fd/3'
modifying entry "cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,dc=ephico2real,dc=com"
$ ./browser.sh sign-in shop.bob >/dev/null; ./browser.sh shop.bob POST /v1/items:reset -H 'content-type: application/json' -d '{}' -w '   shop.bob, signed in again: POST /v1/items:reset -> %{http_code}\n'
RBAC: access denied   shop.bob, signed in again: POST /v1/items:reset -> 403
```

**What just happened:** at his next sign-in `shop.bob`'s token had no `admin`,
and the Gateway refused him: **`403`**. Nothing changed in Keycloak, the policy
or the shop. Put him back:

```console
$ printf 'dn: cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,dc=ephico2real,dc=com\nchangetype: modify\nadd: member\nmember: uid=shop.bob,ou=People,dc=ephico2real,dc=com\n' | oc exec -i -n ldap-testing deploy/openldap-server -c openldap -- sh -c 'exec 3<&0; printf %s "$LDAP_ADMIN_PASSWORD" | ldapmodify -x -H ldap://localhost:389 -D "cn=admin,$LDAP_BASE_DN" -y /dev/stdin -f /dev/fd/3'
modifying entry "cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,dc=ephico2real,dc=com"
$ ./browser.sh sign-in shop.bob >/dev/null; ./browser.sh shop.bob POST /v1/items:reset -H 'content-type: application/json' -d '{}' -o /dev/null -w '   shop.bob, signed in again: POST /v1/items:reset -> %{http_code}\n'
   shop.bob, signed in again: POST /v1/items:reset -> 200
$ oc exec -n ldap-testing deploy/openldap-server -c openldap -- sh -c 'printf %s "$LDAP_ADMIN_PASSWORD" | ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost:389 -D "cn=admin,$LDAP_BASE_DN" -y /dev/stdin -b "cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,$LDAP_BASE_DN" -s base member' | sed -n 's/^member: uid=\([^,]*\).*/\1/p'
john.doe
alice.cooper
sarah.jones
shop.bob
```

**What just happened:** back in the group, back to `200` — and the group holds
its four members again. Two things make "at his next sign-in" true:

- **Keycloak reads the directory at every login.** With its default user cache,
  it did not: measured, `shop.bob`'s tokens still had `admin` 1 s and 6 s after
  the change, until the realm's user cache was cleared. Realm `corp`'s LDAP
  provider now has `cachePolicy: NO_CACHE` (step 2, "The choices", item 5).
- **An open session follows at its next refresh.** Measured: `shop.bob` signed
  in, then left the group; his same session could still reset — its access token
  still said `admin` — until that token expired; 6 minutes later the Gateway had
  refreshed it (`use_refresh_token`), the new token had no `admin`, and the same
  session got `403`. So a change reaches everyone within one token lifetime,
  300 s — the reason `corp`'s tokens are short-lived.

The directory's own consumers see the change too: group sync mirrors this group
into OpenShift (`group-sync-operator`), where it has no grants (the epic's access
matrix, #6).

### Step 14 — what Envoy got

The three filters Envoy Gateway generated, read from the running Envoy by
[`dump-filters.sh`](dump-filters.sh) and kept in
[`generated/envoy-filters.yaml`](generated/envoy-filters.yaml) — the file module 20
works from:

```console
$ ./dump-filters.sh > generated/envoy-filters.yaml
$ grep -E '^  - name: |^    envoy\.filters\.http\.[a-z_0-9]+:$|^                    name: ' generated/envoy-filters.yaml
  - name: envoy.filters.http.oauth2
  - name: envoy.filters.http.jwt_authn
  - name: envoy.filters.http.rbac
  - name: envoy.filters.http.router
    envoy.filters.http.rbac:
                    name: admins
                    name: signed-in-may-read
                    name: signed-in-may-reserve
    envoy.filters.http.oauth2:
    envoy.filters.http.jwt_authn:
```

**What just happened:** the listener's chain is **`oauth2` → `jwt_authn` →
`rbac` → `router`**. At the listener, `oauth2` and `rbac` have no settings — an
OAuth2 filter without `config` and an RBAC filter without `rules` do nothing
(`api/envoy/extensions/filters/http/oauth2/v3/oauth.proto`, `OAuth2PerRoute`;
`…/rbac/v3/rbac.proto`, `rules`: "If absent, no RBAC enforcement occurs") — and
each of the shop's routes turns all three on (`typed_per_filter_config`), with the
rules by name: `admins`, `signed-in-may-read`, `signed-in-may-reserve`.

### Step 15 — check yourself

`./run.sh verify` asks everything above again — the browser's sign-in, both
users' answers, `bob.wilson`, the command line, the expired token (it waits for
one to expire, about six minutes), the NetworkPolicy — and reads the API server's
audit log to check that no token or password was in any `oc exec`'s arguments:

```console
$ ./run.sh verify

1. the objects, and the filters Envoy Gateway made of them
  ✓ Gateway programmed
  ✓ HTTPRoute shop accepted
  ✓ SecurityPolicy sign-in accepted
  ✓ the Gateway's client secret is module 18's (Secret shop-kiosk-oidc = keycloak/shop-kiosk-client)
  ✓ realm corp's client shop-kiosk: its redirect URI, PKCE S256
  ✓ the Gateway's filter chain: oauth2, jwt_authn, rbac, router

2. a browser with no session is sent to realm corp's login page
  ✓ 127.0.0.1:19080 -> 192.168.127.102:80: already forwarded
  ✓ from this laptop, http://localhost:19080/ -> 302 to corp's login page
  ✓ GET / -> 302 to corp's authorization endpoint
  ✓ ...as client shop-kiosk
  ✓ ...with a PKCE S256 challenge
  ✓ ...and the laptop's address to come back to

3. shop.alice signs in: she may list and reserve, not create, delete or reset
  ✓ shop.alice signs in on corp's login page
  ✓ her JWT, as the Gateway sent it on: issued by corp
  ✓ ...to the kiosk's client
  ✓ ...for the shop's API (aud shop-api)
  ✓ ...as shop.alice, without admin
  ✓ GET /v1/items -> 200
  ✓ GET /v1/warehouses -> 200
  ✓ POST /v1/items/SKU-1001:reserve -> 200
  ✓ POST /v1/items (create) -> 403
  ✓ DELETE /v1/items/SKU-1001 -> 403
  ✓ POST /v1/items:reset -> 403

4. shop.bob signs in: admin, from his LDAP group - he may create and delete
  ✓ shop.bob signs in on corp's login page
  ✓ his JWT: issued by corp, for shop-api, with admin
  ✓ POST /v1/items (create SKU-V19) -> 200
  ✓ DELETE /v1/items/SKU-V19 -> 200
  ✓ shop.bob signs out: back to corp's logout, then the shop

5. bob.wilson - in the directory, outside the login gate - cannot sign in
  ✓ the login page refuses him
  ✓ ...because Keycloak does not find him

6. the command line: a bearer JWT, the same answers
  ✓ shop.alice: GET /v1/items -> 200
  ✓ shop.alice: reserve -> 200
  ✓ shop.alice: create -> 403 RBAC
  ✓ shop.alice: delete -> 403 RBAC
  ✓ shop.alice: reset -> 403 RBAC
  ✓ shop.bob: create -> 200
  ✓ shop.bob: delete -> 200
  ✓ shop.alice's JWT edited to add admin -> 401
  ✓ a JWT from realm tutorial -> 401
  (waiting 360 s for the token taken at the start to expire, plus Envoy's 60 s clock skew and 5 s for the clocks)
  ✓ shop.alice's JWT once it has expired -> 401

7. the Gateway is the only way in
  ✓ the shop's Envoy, called directly from the client pod: no answer
  ✓ the same call through the Gateway, with a JWT -> 200

8. no token or password in a process's arguments
  ✓ pod exec requests the API server recorded during this check (their URLs hold the arguments): some
  ✓ ...none holds a token's signature or the password

all checks passed
```

## The options

**`SecurityPolicy` — `oidc`** (Envoy's `oauth2` filter)

| Field | Here | What it does | Default |
|---|---|---|---|
| `provider.issuer` | `…/realms/corp` | the provider; with no endpoints given, where the controller fetches the discovery document | — |
| `provider.authorizationEndpoint` | `keycloak.apps-crc.testing/…/auth` | where the browser is sent to sign in | discovered |
| `provider.tokenEndpoint` | `keycloak-service.keycloak.svc:8443/…/token` | where Envoy swaps the code for tokens | discovered |
| `provider.endSessionEndpoint` | `…/logout` | where `/logout` sends the browser | discovered, if any |
| `provider.backendRefs` | `keycloak-service:8443` | the connection to the token endpoint — TLS from its `BackendTLSPolicy` (module 16's) | the endpoint's host |
| `clientID`, `clientSecret` | `shop-kiosk`, Secret `shop-kiosk-oidc` (`client-secret`) | who the Gateway is at Keycloak (HTTP Basic, `BASIC_AUTH`) | — |
| `redirectURL` | `http://localhost:19080/oauth2/callback` | where Keycloak sends the code | `%REQ(x-forwarded-proto)%://%REQ(:authority)%/oauth2/callback` |
| `logoutPath` | `/logout` | signs out | `/logout` |
| `forwardAccessToken` | `true` | the session's access token sent on as `Authorization: Bearer` | `false` |
| `passThroughAuthHeader` | `true` | a request with its own `Authorization: Bearer` skips the sign-in, to the JWT check | `false` |
| `cookieConfig.sameSite` | `Lax` | the cookies' `SameSite` | not set |
| `refreshToken` | not set (`true`) | refresh expired tokens with the refresh token (step 13) | `true` |
| `scopes` | not set | `openid` is always added | `openid` |

**`SecurityPolicy` — `jwt.providers[]`** — as module 17: `issuer`, `audiences`,
`remoteJWKS` (`cache_duration: 300s`), `claimToHeaders`.

**`SecurityPolicy` — `authorization`**

| Field | Here | What it does |
|---|---|---|
| `defaultAction` | `Deny` | refuse unless a rule allows |
| `rules[].principal.jwt` | provider `corp`, a claim | the verified token's claims: `realm_access.roles` holds `admin`; `iss` is `corp`'s |
| `rules[].operation.methods` | `GET`; `POST` | the request's method |
| `rules[].operation.path` | `RegularExpression`, `^/v1/items/[^/?#;]+:reserve$` | the whole `:path`, query included; also `Exact`, `PathPrefix` |

## What production does differently

| Here (lab) | Production |
|---|---|
| a CRC forward to the MetalLB address, and `http://localhost:19080` | the MetalLB address, routable; a public hostname with a certificate the browsers trust, and the Gateway listening on HTTPS |
| the database password in git (LAB ONLY); the client secret generated by `run.sh` and copied between namespaces | both from a vault, the client secret delivered to both namespaces by it |
| the password grant (`shop-cli`) for the command line | a service's client credentials, or a person's token from a device or browser flow |
| `/whoami` echoes the bearer token | never echo a token |
| `cachePolicy: NO_CACHE` — the directory at every login | the same, or `MAX_LIFESPAN` with a short `maxLifespan`, weighed against the directory's load |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| the callback or `/logout` answers `404` | no route matches the path, and Envoy Gateway turns the `oauth2` filter on per route — measured with both paths left out of the `HTTPRoute` | keep `/oauth2/callback` and `/logout` in `40-route.yaml` |
| the policy says `Accepted=False` `OIDC: Get "…/.well-known/openid-configuration": … x509: certificate is valid for *.apps-crc.testing, not keycloak-service.keycloak.svc`; every route `500` | the endpoints are not in the policy, so the controller fetches the discovery document from the issuer's host, expecting the name of the `BackendTLSPolicy` — measured | give `authorizationEndpoint` and `tokenEndpoint` (both) |
| a request passes the reserve rule though it is not a reserve | the expression matched something in the query string — measured with `[^/]+` | exclude `/`, `?`, `#`, `;` from the item, anchor it (step 9) |
| someone removed from an LDAP group keeps its role | Keycloak's user cache — measured before `cachePolicy: NO_CACHE`; an open session keeps its token up to 300 s | `NO_CACHE` (step 2); wait one token lifetime |
| `401 Jwt is expired` | the token outlived `corp`'s 300 s (plus 60 s of skew) | a fresh token; a browser session refreshes by itself |
| `401 Jwt issuer is not configured` | a token from another realm — `tutorial`'s | a `corp` token |
| `401 Jwks doesn't have key to match kid` right after step 2 | realm `corp` was rebuilt, with new keys; the Gateway keeps the old ones up to 300 s | wait (module 18, step 13) |
| the shop's Envoy, called from a pod, does not answer | the NetworkPolicies — by design (step 5) | call it through the Gateway |
| the browser cannot load `localhost:19080`, before or after signing in | no forward — CRC was restarted, or the module cleaned — or it points at an old address: Keycloak always sends the browser back to `localhost:19080` (step 7) | `./run.sh verify` or `../_shared/crc-forward.sh ensure …` (step 7) |
| `crc-forward.sh: port 19080 is taken on this laptop by …` | another program listens on 19080 — measured with a Python web server on another port | stop it; the port is fixed by the redirect URI |
| `crc-forward.sh: no CRC network socket …` (exit 3) | not CRC, or CRC is not running | on bare metal no forward is needed |

## Browser screenshots

To be added after the operator signs in — read-only captures with the
`/screenshot` skill, checked with `tooling/screenshot/verify.py`, with a
the laptop's forward in place (step 7):

- `http://localhost:19080` → realm `corp`'s login page (the address bar at
  `keycloak.apps-crc.testing/realms/corp/…`, `client_id=shop-kiosk`).
- The kiosk as `shop.alice`: the item list, and a reserve with its `200` in the
  wire panel.
- The kiosk as `shop.alice`: **Add item** refused — `HTTP 403`, `RBAC: access
  denied` in the wire panel.
- The kiosk as `shop.bob`: an item added (`200`) and deleted (`200`).
- `bob.wilson` on the login page: `Invalid username or password.`
- Optional: `/whoami` as each user — `x-user`, and the token's `azp: shop-kiosk`.

## Permanent lab

On the operator's CRC the shop stays: it is an integration of the Keycloak
offering (module 16, [Integrations index](../16-keycloak/README.md#integrations-index)).
Argo CD's Application `19-shop-gateway`
([`../argocd/19-shop-gateway.yaml`](../argocd/19-shop-gateway.yaml)) keeps this
module's `manifests/` and the echo app behind `/whoami` — the same files
`./run.sh deploy` applies — as they are on the `main` branch.

### What `./run.sh deploy` makes, and who keeps it

| What | Made by | Kept by | Why |
|---|---|---|---|
| namespace `envoy-19`, Gateway `eg`, the shop, the NetworkPolicies, `HTTPRoute` `shop`, `ReferenceGrant` in `keycloak`, `SecurityPolicy` `sign-in` | `manifests/` | Argo CD | manifests |
| **Secret `shop-kiosk-oidc`** — the Gateway's copy of the client secret (step 6) | `./run.sh deploy`, from module 18's `keycloak/shop-kiosk-client` | nobody — `run.sh` only | not in git. Until it exists — a new cluster where Argo CD applied the policy first — the policy is not accepted; `./run.sh deploy` writes it. After a new value in module 18's Secret (and a re-import of `corp`), `./run.sh deploy` copies it again; `./run.sh verify` checks both hold the same |
| the echo app | [`../_shared/echo-app.yaml`](../_shared/echo-app.yaml), with `-n envoy-19` | Argo CD — the Application's second source | as module 17 |
| client `shop-kiosk` and `cachePolicy: NO_CACHE` in realm `corp` | module 18's realm file, imported once (step 2) | Argo CD `18-keycloak-ldap` keeps the import; the realm is created once | an import only creates (module 18, step 13) |
| **the `nonroot-v2` grant** for the Gateway's Envoy, and its restart | `./run.sh deploy` | nobody — `run.sh` only | as module 17: one RoleBinding shared by every Gateway module |
| the MongoDB claim `inventory-db` | the manifest | Argo CD | on CRC its volume outlives it (`reclaimPolicy: Retain`) |
| **the laptop's forward** `127.0.0.1:19080` → the Gateway's MetalLB address | `./run.sh deploy` and `./run.sh verify` (step 7) | nobody — `run.sh` only | it lives in CRC's gvproxy, not in the cluster; lost when CRC stops |
| pod `client` | `./run.sh deploy` | nobody | a test tool |
| the HMAC key the session cookies are signed with | Envoy Gateway (`envoy-gateway-system/envoy-oidc-hmac`) | Envoy Gateway | shared by every OIDC policy of the controller |

`./run.sh deploy` checks what the module builds on — Keycloak, realm `corp` with
`shop-kiosk`, module 16's `BackendTLSPolicy` — and stops with the step that makes
the missing one. Module 16's `clean --delete-data` deletes namespace `keycloak`,
and with it this module's `ReferenceGrant`: sign-in fails until module 16 is back
and Argo CD, or `./run.sh deploy`, applies it again.

## Clean up

On the permanent lab a clean-up is a deliberate reset, never the end of a
walkthrough. `./run.sh clean` pauses Argo CD's Application, removes the laptop's
forward, the `nonroot-v2` grant and the `ReferenceGrant`, and deletes namespace `envoy-19` —
the shop and its database claim. Realm `corp`'s client `shop-kiosk` stays: it is
module 18's.

<!-- walkthrough: skip -->
```console
$ ./run.sh clean
```

## The shortcut

`./run.sh deploy` does steps 3 to 7 (step 2's client must already be in `corp`),
and resumes Argo CD's Application if there is one; `./run.sh verify` is step 15;
`./run.sh clean` is the clean-up; `./run.sh pause` and `./run.sh resume` are the
[Permanent lab](#permanent-lab)'s.

## Module 20 does this by hand

Module 20 builds the same shop with a standalone Envoy behind an OpenShift Route,
writing these filters itself. What Envoy Gateway generated, from
[`generated/envoy-filters.yaml`](generated/envoy-filters.yaml) (step 14), and the
Gateway API object each part came from:

| Envoy got | From |
|---|---|
| `http_filters`: `envoy.filters.http.oauth2`, `envoy.filters.http.jwt_authn`, `envoy.filters.http.rbac`, `envoy.filters.http.router` — in that order | `SecurityPolicy sign-in`'s `oidc`, `jwt`, `authorization`; the order is Envoy Gateway's (`httpfilters.go`) |
| per route, `oauth2` `config`: `authorization_endpoint`, `token_endpoint` (`cluster: securitypolicy/envoy-19/sign-in/oidc/0`), `end_session_endpoint`, `redirect_uri`, `redirect_path_matcher` `/oauth2/callback`, `signout_path` `/logout` | `oidc.provider.*`, `oidc.redirectURL`, `oidc.logoutPath` |
| `credentials.client_id: shop-kiosk`; `token_secret` and `hmac_secret` by SDS name | `oidc.clientID`; `oidc.clientSecret` → Secret `shop-kiosk-oidc` (module 18's generated value, copied); the HMAC key from Envoy Gateway's `envoy-oidc-hmac` |
| `cookie_names` (`AccessToken-`, `IdToken-`, `RefreshToken-`, `OauthHMAC-`, `OauthExpires-`, `OauthNonce-`, `CodeVerifier-` + a suffix); `cookie_configs` `same_site: LAX`, the nonce and verifier on path `/oauth2/callback` | Envoy Gateway's names; `oidc.cookieConfig.sameSite` |
| `forward_bearer_token: true`; `pass_through_matcher`: `Authorization`, prefix `Bearer ` | `oidc.forwardAccessToken`; `oidc.passThroughAuthHeader` with the JWT provider's default location |
| `auth_scopes: [openid]`, `auth_type: BASIC_AUTH`, `use_refresh_token: true` | Envoy Gateway's defaults |
| `jwt_authn` provider `corp_…`: `issuer`, `audiences: [shop-api]`, `remote_jwks` (`cluster: securitypolicy/envoy-19/sign-in/jwt/0`, `cache_duration: 300s`, `async_fetch`), `forward: true`, `payload_in_metadata: corp`, `claim_to_headers` `x-user`; per route, `requirement_name` | `jwt.providers[corp]`; `forward` and `payload_in_metadata` are Envoy Gateway's |
| the two clusters' TLS to `keycloak-service` | `BackendTLSPolicy keycloak/keycloak-service` (module 16), allowed by the `ReferenceGrant` |
| per route, `rbac` matchers `admins`, `signed-in-may-read`, `signed-in-may-reserve` — the claims read from `jwt_authn`'s metadata under `corp`; `:method` and `:path` headers — and `on_no_match` `DENY` | `authorization.rules`, `authorization.defaultAction` |
| the routes `path_separated_prefix: /v1`, `path: /`, `/oauth2/callback`, `/logout`, `/whoami` | `HTTPRoute shop` |

## References

- [Envoy Gateway — OIDC authentication](https://gateway.envoyproxy.io/docs/tasks/security/oidc/)
- [Envoy Gateway — JWT claim-based authorization](https://gateway.envoyproxy.io/docs/tasks/security/jwt-claim-authorization/)
- [Envoy — OAuth2 filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/oauth2_filter)
- [Envoy — RBAC filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/rbac_filter)
- [RFC 7636 — Proof Key for Code Exchange](https://www.rfc-editor.org/rfc/rfc7636)
- [OpenID Connect RP-Initiated Logout 1.0](https://openid.net/specs/openid-connect-rpinitiated-1_0.html)
- [Red Hat build of Keycloak 26.6 — Server Administration Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/server_administration_guide/index)
- [Kubernetes — Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [MDN — Secure contexts](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts)

## Diagram sources

The figure is rendered from [`docs/diagrams/19-shop-gateway/source.html`](../docs/diagrams/19-shop-gateway/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
