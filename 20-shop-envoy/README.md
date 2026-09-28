# 20 — the shop behind a standalone Envoy, on an OpenShift Route

Module 19 put the shop from
[`envoy-grpc-modernization`](https://github.com/ephico2real2/envoy-grpc-modernization)
behind a Gateway: people **sign in on realm `corp`'s login page** with their
directory account, a **JWT is checked on every call**, and **LDAP groups** decide
what each person may do — all from one Envoy Gateway `SecurityPolicy`. This
module builds **the same shop, with the same sign-in and the same answers**, the
way modules 01 to 11 build things: **one Envoy, configured by hand**, with its
own `oauth2`, `jwt_authn` and `rbac` filters, behind an **OpenShift Route** on the
MetalLB ingress shard.

Many teams run Envoy themselves rather than through a Gateway API controller.
Side by side with module 19, this module also shows exactly what a
`SecurityPolicy` becomes: [the last section](#module-19-and-module-20-side-by-side)
puts the two configurations, and their measured answers, next to each other.

## What you'll learn

- how Envoy's **`oauth2`** filter signs a browser in — OpenID Connect's
  authorization-code flow with PKCE — and keeps the session in cookies, and what
  it needs when a router in front of it ends TLS
- how **`jwt_authn`** checks the JWT, and **`rbac`** decides by role, method and
  path — the same rules as module 19, written as Envoy's own policies
- where each secret, certificate and file lives when there is no controller to
  generate them, and what that costs to keep

## Before you start

- Module [`16`](../16-keycloak/README.md)'s Keycloak and module
  [`18`](../18-keycloak-ldap/README.md)'s realm `corp` are running
  (`../18-keycloak-ldap/run.sh verify` passes), and the directory has the shop's
  users `shop.alice` and `shop.bob` (module 17, "Before you start").
- The MetalLB ingress shard is running
  (`../00-prerequisites/ingress-shard/run.sh verify` passes): a second router,
  on `192.168.127.130`, for Routes labelled `ingress-shard=metallb`, and the
  laptop's forward `127.0.0.1:20443` to it
  ([its README](../00-prerequisites/ingress-shard/README.md)).
- Module [`19`](../19-shop-gateway/README.md) is running too, for the side-by-side
  checks (step 13 and `./run.sh verify`); without it they say so and skip.
- Work from this folder: `cd 20-shop-envoy`.
- This module uses the namespace **`envoy-20`**, adds a client to realm `corp`
  (step 2). A walk from scratch takes about 3 minutes (measured: 174 s, after
  `./run.sh clean`), and `verify` about 80 s: its expiry probe uses a 45-second
  test token. On the operator's CRC it is **permanent**, kept by Argo CD:
  see [Permanent lab](#permanent-lab) before you change anything by hand there.

## The concept

A person opens the shop at `https://shop.apps-metallb.crc.testing:20443`. The
ingress shard's router ends TLS and hands the request to the **front Envoy**,
which sees no session and sends the browser to **realm `corp`'s login page**. The
person signs in with their directory account — only members of the login gate
`app-ssb-autobahnusers` can (module 18, step 8). Keycloak sends the browser back
with a one-time **code**; the front Envoy swaps it for tokens at Keycloak — it is
the OpenID Connect client, not the page — and keeps them, encrypted, in
**cookies**. From then on, every request the browser makes carries the cookies,
and the front Envoy sends it on to the shop with the **access token** as
`Authorization: Bearer <JWT>` — after checking that JWT exactly as it checks one
a command-line caller sends itself, and after checking what its **realm roles**
allow for this **method** and **path**.

One Envoy, three of its filters, in this order — written by hand in
[`manifests/70-front-envoy-config.yaml`](manifests/70-front-envoy-config.yaml):

| Filter | Does |
|---|---|
| `oauth2` | no session: a redirect to the login page; `/oauth2/callback`: code for tokens; a session: its access token sent on as a bearer token. A request that already carries `Authorization: Bearer …` skips it |
| `jwt_authn` | checks the JWT: issuer `…/realms/corp`, audience `shop-api`, signature, expiry |
| `rbac` | the realm role `admin` may do anything; any `corp` token may `GET` and reserve stock; everything else is `403` |

<!-- markdownlint-disable MD033 -->
<img alt="Two callers reach the shop in envoy-20 through Route shop on the MetalLB ingress shard. A browser on the laptop opens https://shop.apps-metallb.crc.testing:20443, which /etc/hosts maps to 127.0.0.1 and CRC forwards to the shard's address 192.168.127.130, port 443; a command-line caller sends Authorization: Bearer with a JWT from client shop-cli. The shard's router, which admits Routes labelled ingress-shard=metallb, ends TLS with its certificate for *.apps-metallb.crc.testing from enterprise-ca (an edge Route), sets no affinity cookie, and sends plain HTTP to the front Envoy with X-Forwarded-Proto: https. The front Envoy, configured by hand in 70-front-envoy-config.yaml, sets the scheme to https on every request and runs three filters in order. First oauth2: a browser without a session gets a 302 to realm corp's login page at keycloak.apps-crc.testing, as client shop-envoy with a PKCE S256 challenge; after the person signs in, Keycloak sends the browser back to https://shop.apps-metallb.crc.testing:20443/oauth2/callback with a code, which the front Envoy swaps for tokens at keycloak-service:8443 and keeps in Secure, HttpOnly, SameSite=Lax cookies; on every later request it forwards the access token as Authorization: Bearer; a request that already carries a Bearer header skips this filter; the client secret and the cookie-signing key are files from two Secrets that are not in git. Second jwt_authn: issuer realms/corp, audience shop-api, the signature with corp's public keys fetched from keycloak-service:8443 over TLS, the certificate's name checked and its CA from ConfigMap keycloak-ca, run.sh's copy, cached 300 seconds, and the expiry. Third rbac: policy admins, the realm role admin, may do anything; policy signed-in, any corp token, may GET and POST items/sku:reserve; when no policy matches, 403. Keycloak reads each person and their groups from the LDAP directory at every login: only members of app-ssb-autobahnusers may sign in, and app-ocp-rbac-ocp-keycloak-admin becomes the role admin. Allowed requests reach the shop vendored from envoy-grpc-modernization, with x-user set to the LDAP uid and no cookies: its own Envoy turns REST and JSON into gRPC, then three inventory pods and MongoDB, and the kiosk page; NetworkPolicies let only the shard's router reach the front Envoy, and only the front Envoy reach the shop. Measured answers, the same as module 19's and the same in the browser and on the command line: shop.alice lists and reserves, 200, and gets 403 RBAC access denied on create, delete and reset; shop.bob creates, deletes and resets, 200. An edited JWT gets 401 Jwt verification fails, a JWT from realm tutorial 401 Jwt issuer is not configured, an expired JWT 401 Jwt is expired; bob.wilson cannot sign in, user_not_found; the front Envoy or the shop called directly does not answer. Envoy reads its configuration and both secrets once, at start: a change takes a restart." src="../docs/diagrams/20-shop-envoy/flow.light.png">
<!-- markdownlint-enable MD033 -->

### The choices, and why

Researched before building — Envoy 1.39.1's source (`envoyproxy/envoy` at tag
`v1.39.1`, the pinned `envoyproxy/envoy:v1.39.1` (#19): measured, `envoy
--version` in the pod says `1.39.1`, image digest `sha256:57e14a54…`, the tag's
digest on Docker Hub), the Keycloak documentation, module 19 — and measured on
CRC:

1. **One Envoy in front of the shop's own Envoy, not a combined chain.** The
   shop's Envoy is the app team's file (`24-shop-envoy-config.yaml`, vendored
   unchanged, `grpc_json_transcoder`). Putting `oauth2`, `jwt_authn` and `rbac`
   into it would fork the app's configuration: every re-vendoring would have to
   merge them back in. A front Envoy keeps two owners and two files — the
   platform's sign-in and permissions, the app's REST surface — exactly as module
   19's Gateway does, so the two modules compare filter for filter. The cost is
   one more hop inside the namespace.
2. **Browser sign-in: `envoy.filters.http.oauth2`.** It always sends a PKCE
   `code_challenge` with `code_challenge_method=S256`
   (`source/extensions/filters/http/oauth2/filter.cc`, lines 1335–1337), so
   the client **requires** it (Keycloak's `pkce.code.challenge.method: S256`).
   With `forward_bearer_token: true` it sends the session's access token on as
   `Authorization: Bearer`, and with a `pass_through_matcher` on
   `Authorization: Bearer ` a command-line caller skips the sign-in — and meets
   `jwt_authn` like everyone else. It drops only its own flow cookies (nonce,
   verifier, HMAC, expiry, refresh token) before the request goes on; the access
   and ID token cookies go upstream (`removeOAuthFlowCookies`, filter.cc lines
   1951–1991), so the route configuration removes `cookie` for every route
   (step 8).
3. **The two secrets: files from mounted Secrets, never in git, never in argv.**
   The filter reads its client secret and its HMAC key (which signs the session
   cookies) through `SdsSecretConfig`; without an `sds_config` it looks the name
   up among the **static** secrets (`config.cc`, `secretsProvider`, lines
   31–41). So the configuration declares two static `generic_secret`s, each read
   from a file of a projected volume of two Secrets. Envoy reads them **once, at
   start**: `ThreadLocalGenericSecretProvider` reads the file when it is created
   and again only on an xDS update, which static secrets never get
   (`source/common/secret/secret_provider_impl.cc`, lines 22–54). A new value
   takes a restart; `./run.sh deploy` does it, and `./run.sh verify` fails while
   the running Envoy is older than its inputs. SDS from files would reload, but
   needs each Secret to hold an xDS discovery response in YAML — more to generate,
   for a value that changes only when realm `corp` is rebuilt.
4. **The Route: edge, on the MetalLB ingress shard.** Labelled
   `ingress-shard=metallb`, it is admitted by the shard alone
   (`../00-prerequisites/ingress-shard`, which also keeps the default router off
   it). **Edge**: the router ends TLS with the shard's certificate for
   `*.apps-metallb.crc.testing`, from `enterprise-ca`, which cert-manager renews
   and the router reloads by itself — nothing in the Route or the Envoy to
   renew. **Reencrypt** would add a serving certificate to the front Envoy, which
   Envoy reads once from a file (a restart at every renewal) and whose CA the
   Route must carry inline in `destinationCACertificate` (the cluster's own CA
   is not in git, module 16's rule). The hop that edge leaves in plain HTTP is
   inside the namespace's NetworkPolicies: only the shard's router reaches the
   front Envoy (step 4).
5. **What the router's edge TLS means for the `oauth2` filter — measured.** The
   filter builds the address it sends the browser back to after the sign-in from
   `:scheme` and the Host (`redirectToOAuthServer`, filter.cc lines 1237–1252),
   and Envoy sets `:scheme` from `X-Forwarded-Proto` when it is `http` or `https`
   (`source/common/http/conn_manager_utility.cc`, lines 245–251). The router
   sends `X-Forwarded-Proto: https` — but it **appends** to one the client sends:
   measured, a request with `X-Forwarded-Proto: http` reached the app as
   `http,https`, and the `state` Envoy built pointed the browser back to
   `http://shop.apps-metallb.crc.testing:20443/`, a plain-HTTP request to a TLS
   port. So the listener says `scheme_header_transformation: { scheme_to_overwrite:
   https }`: every request here came over HTTPS. Measured again: `https://…` in
   the `state`, and `X-Forwarded-Proto: https` at the app. The address Keycloak
   sends the browser back to after `/logout` is written out too
   (`post_logout_redirect_uri`), the one the client registers.
6. **The browser's address, and its cookies.** CRC's routes-controller writes a
   Route's host into the laptop's `/etc/hosts` as `127.0.0.1` for hosts ending in
   `.crc.testing` — `shop.apps-metallb.crc.testing` appeared there once the Route
   was admitted — and the shard's forward carries the laptop's port `20443` to
   the shard (step 7). The browser opens
   **`https://shop.apps-metallb.crc.testing:20443`**, and that is the redirect
   URI. Module 19 measured that Chromium keeps Envoy's `Secure` cookies over plain
   HTTP only on `localhost`; here the origin is HTTPS. Measured with a headless
   Chromium (Playwright): a whole sign-in as `shop.alice` ended on the kiosk
   (`Depot Kiosk`) with the five session cookies `Secure`, `HttpOnly`,
   `SameSite=Lax`, the kiosk's own calls answered `200` for the items and
   `403 RBAC: access denied` for a reset, and `/logout` left none of them. The
   same run showed a sixth cookie, the router's affinity cookie (`Secure`,
   `SameSite=None`); the session is in the front Envoy's own signed cookies, which
   any replica reads, so the Route turns it off
   (`haproxy.router.openshift.io/disable_cookies`).
7. **Keycloak over TLS, from the front Envoy.** The token endpoint and `corp`'s
   public keys are fetched from `keycloak-service.keycloak.svc:8443`, as module
   19's Gateway does, through a cluster with an `UpstreamTlsContext`: SNI and the
   certificate's name `keycloak-service.keycloak.svc`, the CA from ConfigMap
   `keycloak-ca` — `./run.sh deploy`'s copy of `ca.crt` from Secret
   `keycloak/keycloak-tls`, as module 16 copies it for the Gateways (the cluster's
   own CA, so not in git). `jwt_authn` fetches the keys when Envoy starts
   (`async_fetch`), and the listener opens only after that first fetch
   (`JwksAsyncFetch.fast_listener`, default `false`): the readiness probe is the
   listener's port. The admin API answers on the pod's loopback only.
8. **A client of its own in realm `corp`: `shop-envoy`, not `shop-kiosk` with a
   second redirect URI.** Either needs realm `corp` rebuilt — an import only
   creates (module 18, step 13). A client of its own gives this front door its own
   secret and its one redirect URI, so either door can be changed or revoked
   without the other, Keycloak's events say which door (`clientId="shop-envoy"`),
   and module 19 is left exactly as it is: its `verify` asserts `shop-kiosk`'s
   one redirect URI, which a second one would break. It follows module 16's
   "Adding an integration": module 18's `run.sh deploy` generates Secret
   `keycloak/shop-envoy-client` once, the realm import takes it through a
   placeholder, and this module copies it (step 5).

**No secret is committed, printed, logged, or put in a process argument.** Every
value goes from one object to another through a pipe; tokens reach `curl` on
standard input; `./run.sh verify` reads the API server's audit log to check that
no `oc exec` carried one.

## Walkthrough

### Step 1 — what this module builds on

```console
$ oc get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
True
$ oc get keycloakrealmimport corp -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}{"\n"}'
True
$ oc get ingresscontroller metallb -n openshift-ingress-operator -o jsonpath='{.spec.domain} {.status.conditions[?(@.type=="Available")].status}{"\n"}'
apps-metallb.crc.testing True
$ oc get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
192.168.127.130
```

**What just happened:** Keycloak is up, realm `corp` is imported, and the
ingress shard's router serves `apps-metallb.crc.testing` on its MetalLB address.

### Step 2 — realm `corp` gets the front Envoy's client

The front Envoy signs people in as a client of realm `corp`: `shop-envoy`, in
module 18's realm file
([`../18-keycloak-ldap/manifests/20-realm.yaml`](../18-keycloak-ldap/manifests/20-realm.yaml)),
the same settings as module 19's `shop-kiosk` but for its address:

| Field | Here | Why |
|---|---|---|
| `publicClient` | `false`, with a `secret` | the front Envoy is a server: it keeps a secret, and proves itself with it when it swaps a code for tokens |
| `standardFlowEnabled` | `true` | the authorization-code flow — the login page |
| `directAccessGrantsEnabled` | `false` | no passwords sent to the token endpoint by this client |
| `redirectUris` | `https://shop.apps-metallb.crc.testing:20443/oauth2/callback` | the one place Keycloak sends a code back to |
| `attributes.pkce.code.challenge.method` | `S256` | refuse a code request without a PKCE challenge |
| `attributes.post.logout.redirect.uris` | `https://shop.apps-metallb.crc.testing:20443/` | where `/logout` may send the browser back to |
| an audience mapper | `shop-api` | its tokens are for the shop's API, as `shop-cli`'s and `shop-kiosk`'s are |
| `secret` | `${SHOP_ENVOY_CLIENT_SECRET}` | a placeholder, from Secret `keycloak/shop-envoy-client`, which module 18's `run.sh deploy` generates once |

Is it in the realm?

```console
$ ../18-keycloak-ldap/admin.sh GET '/admin/realms/corp/clients?clientId=shop-envoy' | python3 -c 'import json,sys; [print(c["clientId"], "| confidential:", not c["publicClient"], "| redirect:", c["redirectUris"], "| PKCE:", c["attributes"].get("pkce.code.challenge.method"), "| after logout:", c["attributes"].get("post.logout.redirect.uris")) for c in json.load(sys.stdin)]'
shop-envoy | confidential: True | redirect: ['https://shop.apps-metallb.crc.testing:20443/oauth2/callback'] | PKCE: S256 | after logout: https://shop.apps-metallb.crc.testing:20443/
```

**What just happened:** the client is there. If the command prints nothing, the
realm predates it: an import only creates, so make its Secret and re-import
`corp` the measured way (module 18, step 13) — on the permanent lab, with Argo
CD's Application paused first and resumed after. Run as written on 2026-09-28,
02:10:39–02:11:26 UTC:

<!-- walkthrough: skip -->
```console
$ oc get secret shop-envoy-client -n keycloak >/dev/null 2>&1 && echo "Secret shop-envoy-client kept" || python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' | oc create secret generic shop-envoy-client -n keycloak --from-file=client-secret=/dev/stdin
secret/shop-envoy-client created
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
directory at their next login. It also gave `corp` new signing keys, which the
Gateways of modules 17 and 19 cache for up to 300 s (module 18, step 13): their
`verify`, started 6 minutes after the rebuild (02:17 UTC), passed, as did 16's,
18's and the ingress shard's.

While this change was not yet on `main`, the resumed Application put the import
back as `main` declares it — measured: the import's `spec.realm.clients` listed
`shop-api shop-cli shop-kiosk` again, and no new import Job ran — while the realm
kept `shop-envoy`: an import only creates (module 18, step 13).

### Step 3 — the shop, from its own repository — and no way to it yet

The shop is `envoy-grpc-modernization`'s own code and manifests, the same commit
as module 19's. [`vendor.sh`](vendor.sh) writes this module's copy from that
repository — each manifest with the namespace changed to `envoy-20`, each source
file as a ConfigMap — and leaves out the app's own Route, which leads to the
shop's Envoy; this module's Route leads to the front Envoy (step 6). Which commit:

```console
$ grep -h '^# at ' manifests/2[1-8]-shop-*.yaml | sort -u
# at 1e3ad13938f7ecef81d4a7717b18f7874384b4de. Do not edit here: change the app repository, then run vendor.sh.
$ for f in manifests/2[0-8]-shop-*.yaml; do sed 's/envoy-20/envoy-19/; s/the front Envoy is the way in/the Gateway is the way in/' "$f" | cmp -s - "../19-shop-gateway/$f" && echo "$f: module 19's copy, but for the namespace" || echo "$f: DIFFERS from module 19's"; done
manifests/20-shop-db-secret.yaml: module 19's copy, but for the namespace
manifests/21-shop-database.yaml: module 19's copy, but for the namespace
manifests/22-shop-inventory-src.yaml: module 19's copy, but for the namespace
manifests/23-shop-inventory.yaml: module 19's copy, but for the namespace
manifests/24-shop-envoy-config.yaml: module 19's copy, but for the namespace
manifests/25-shop-envoy-proto.yaml: module 19's copy, but for the namespace
manifests/26-shop-envoy.yaml: module 19's copy, but for the namespace
manifests/27-shop-kiosk-src.yaml: module 19's copy, but for the namespace
manifests/28-shop-kiosk.yaml: module 19's copy, but for the namespace
```

| File | What |
|---|---|
| [`10-namespace.yaml`](manifests/10-namespace.yaml) | namespace `envoy-20`; Argo CD never prunes it |
| [`20-shop-db-secret.yaml`](manifests/20-shop-db-secret.yaml) | the database password — a LAB value, as in module 19 |
| `21` … `28` | MongoDB and its claim; the inventory service (gRPC only, three pods, a headless Service) and its source; the shop's Envoy, its configuration (`grpc_json_transcoder`) and the proto descriptor; the kiosk page and its web server |

```console
$ oc apply -f manifests/10-namespace.yaml
namespace/envoy-20 created
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
$ oc apply -n envoy-20 -f ../_shared/client.yaml -f ../_shared/echo-app.yaml
pod/client created
configmap/echo-src created
service/echo created
deployment.apps/echo created
$ for d in inventory-db inventory envoy kiosk echo; do oc rollout status -n envoy-20 deploy/$d --timeout=300s; done
Waiting for deployment "inventory-db" rollout to finish: 0 of 1 updated replicas are available...
deployment "inventory-db" successfully rolled out
Waiting for deployment "inventory" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "inventory" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "inventory" rollout to finish: 2 of 3 updated replicas are available...
deployment "inventory" successfully rolled out
deployment "envoy" successfully rolled out
deployment "kiosk" successfully rolled out
deployment "echo" successfully rolled out
$ oc wait -n envoy-20 --for=condition=Ready pod/client --timeout=120s
pod/client condition met
$ oc get route -n envoy-20 -o name | wc -l | tr -d ' '
0
```

**What just happened:** the shop runs — MongoDB, three inventory pods, its own
Envoy, the kiosk — and no Route leads to it: the Route comes **last**, once the
front Envoy with its sign-in is running (step 6).

### Step 4 — each layer admits only the one in front of it

The sign-in guards what comes through the front Envoy, not the Services beside
it: any pod in the cluster could call the shop's Envoy at
`envoy.envoy-20.svc:8080` and skip it.
[`manifests/30-network-policy.yaml`](manifests/30-network-policy.yaml) lets each
layer accept only the one in front of it — the shard's router, then the front
Envoy, then the shop's Envoy, then the inventory, then MongoDB. The client pod
tries to open a connection to each, straight (curl's `telnet://`, 3 s), and to
the shard's address as a control:

```console
$ oc apply -f manifests/30-network-policy.yaml
networkpolicy.networking.k8s.io/front-envoy-from-shard-router created
networkpolicy.networking.k8s.io/shop-envoy-from-front-envoy created
networkpolicy.networking.k8s.io/echo-from-front-envoy created
networkpolicy.networking.k8s.io/kiosk-from-shop-envoy created
networkpolicy.networking.k8s.io/inventory-from-shop-envoy created
networkpolicy.networking.k8s.io/database-from-inventory created
$ sleep 5; for ep in "$(oc get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):443" envoy:8080 echo:8080 kiosk:8080 inventory:50051 inventory-db:27017; do printf '%-24s ' "$ep"; oc exec -n envoy-20 client -- sh -c "curl -sv --connect-timeout 3 -m 4 telnet://$ep </dev/null 2>&1 | grep -q 'Connected to' && echo reachable || echo blocked"; done
192.168.127.130:443      reachable
envoy:8080               blocked
echo:8080                blocked
kiosk:8080               blocked
inventory:50051          blocked
inventory-db:27017       blocked
```

**What just happened:** the shard's address is **reachable**; every layer of the
shop, straight from the client pod, is **blocked** — OVN-Kubernetes drops the
connection. The front Envoy's own policy admits only the pods of the shard's
router (`openshift-ingress`, `deployment-ingresscontroller: metallb`); the
default router runs on the node's network and matches no pod selector, so it is
not admitted either. Step 6 probes the front Envoy once it exists.

### Step 5 — the front Envoy: its secrets, then its configuration

First what the front Envoy reads and git does not hold — each value through a
pipe, never on a command line or the screen:

- Secret `shop-envoy-client`: a copy of module 18's `keycloak/shop-envoy-client`,
  the client secret the realm was imported with (step 2);
- Secret `shop-envoy-hmac`: the key the session cookies are signed with — a
  random value, made once and never replaced (a new one signs every session out);
- ConfigMap `keycloak-ca`: the CA Keycloak's certificate chains to, from Secret
  `keycloak/keycloak-tls` (the certificate only).

```console
$ oc get secret shop-envoy-client -n keycloak -o jsonpath='{.data.client-secret}' | base64 -d | oc create secret generic shop-envoy-client -n envoy-20 --from-file=client-secret=/dev/stdin --dry-run=client -o yaml | oc apply -f -
secret/shop-envoy-client created
$ oc get secret shop-envoy-hmac -n envoy-20 >/dev/null 2>&1 && echo "Secret shop-envoy-hmac kept" || python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' | oc create secret generic shop-envoy-hmac -n envoy-20 --from-file=hmac-secret=/dev/stdin
secret/shop-envoy-hmac created
$ oc get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d | oc create configmap keycloak-ca -n envoy-20 --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml | oc apply -f -
configmap/keycloak-ca created
```

Then the front Envoy:
[`manifests/70-front-envoy-config.yaml`](manifests/70-front-envoy-config.yaml) —
its whole configuration: read it, every field has its reason beside it, and
[The options](#the-options) lists them — and
[`manifests/71-front-envoy.yaml`](manifests/71-front-envoy.yaml), the Deployment
that mounts it, the two Secrets and the CA:

```console
$ oc apply -f manifests/70-front-envoy-config.yaml -f manifests/71-front-envoy.yaml
configmap/front-envoy-config created
service/front-envoy created
deployment.apps/front-envoy created
$ oc rollout status deploy/front-envoy -n envoy-20 --timeout=180s
Waiting for deployment "front-envoy" rollout to finish: 0 of 1 updated replicas are available...
deployment "front-envoy" successfully rolled out
$ oc logs -n envoy-20 deploy/front-envoy | grep -o -E 'loading [0-9]+ (static secret|cluster|listener)\(s\)|all dependencies initialized. starting workers'
loading 2 static secret(s)
loading 3 cluster(s)
loading 1 listener(s)
all dependencies initialized. starting workers
$ oc exec -n envoy-20 deploy/front-envoy -- envoy --version | grep -o '/1\.[0-9.]*/'
/1.39.1/
```

**What just happened:** Envoy 1.39.1 loaded the two secrets from their files, the
three clusters (the shop's Envoy, the echo app, Keycloak's Service over TLS) and
the listener, fetched `corp`'s public keys, and only then opened the listener —
its readiness probe. Nothing leads to it yet.

### Step 6 — only now the Route

The front Envoy is the only way in — directly from the client pod it does not
answer. Then [`manifests/80-route.yaml`](manifests/80-route.yaml): host
`shop.apps-metallb.crc.testing`, labelled `ingress-shard: metallb`, edge TLS, to
the front Envoy. Which routers admit it, and a read and a write with no token:

```console
$ oc exec -n envoy-20 client -- sh -c "curl -sv --connect-timeout 3 -m 4 telnet://front-envoy:8080 </dev/null 2>&1 | grep -q 'Connected to' && echo reachable || echo blocked"
blocked
$ oc apply -f manifests/80-route.yaml
route.route.openshift.io/shop created
$ sleep 5; oc get route shop -n envoy-20 -o jsonpath='{range .status.ingress[*]}{.routerName}={.conditions[?(@.type=="Admitted")].status}{"\n"}{end}'
metallb=True
$ oc get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d | oc exec -i -n envoy-20 client -- sh -c 'cat > /tmp/ca.crt'
$ for i in $(seq 1 30); do r=$(oc exec -n envoy-20 client -- curl -s --cacert /tmp/ca.crt --connect-to "shop.apps-metallb.crc.testing:20443:$(oc get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):443" -o /dev/null -w '%{http_code}' https://shop.apps-metallb.crc.testing:20443/v1/items); echo "no token, GET /v1/items -> $r"; [ "$r" = 302 ] && break; sleep 2; done
no token, GET /v1/items -> 302
$ oc exec -n envoy-20 client -- curl -s --cacert /tmp/ca.crt --connect-to "shop.apps-metallb.crc.testing:20443:$(oc get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):443" -o /dev/null -w 'no token, POST /v1/items/SKU-1001:reserve -> %{http_code}\n' -H 'content-type: application/json' -d '{"quantity":1,"orderId":"ANYONE"}' https://shop.apps-metallb.crc.testing:20443/v1/items/SKU-1001:reserve
no token, POST /v1/items/SKU-1001:reserve -> 302
```

**What just happened:** the Route is admitted by the shard's router
(`metallb=True`) and no other, and from the moment it exists the shop asks for a
sign-in: a read and a write with no token both get **`302`**, a redirect to
`corp`'s login page, and neither reaches the shop. The client pod checked the
router's certificate against the enterprise CA (`--cacert`) — the same as a
browser, as step 7 shows. `./run.sh deploy` keeps this order, and Argo CD does
too: the Route carries `argocd.argoproj.io/sync-wave: "1"`, so it is applied once
the rest of the module — the front Envoy's Deployment among it — is healthy.

Is the shop answering yet? The inventory's pods take a while (they install their
Python packages first). Ask, as `shop.alice`, until one gets the shop's answer —
[`request.sh`](request.sh) reads the token on standard input and calls the shop
from the client pod, as the step above does:

```console
$ for i in $(seq 1 30); do r=$(../17-keycloak-jwt/token.sh shop.alice | ./request.sh GET /v1/items/SKU-1001 -o /dev/null -w '%{http_code}'); echo "attempt $i: $r"; [ "$r" = 200 ] && break; sleep 2; done
attempt 1: 200
```

### Step 7 — how your browser reaches the Route on CRC

The shard's router has an address on the CRC VM's network, which the laptop
does not route to; the shard's `run.sh` asked CRC's network proxy for a forward
from the laptop's port `20443` to it (the laptop's own `:443` goes to the default
router). And CRC's routes-controller wrote the Route's host into the laptop's
`/etc/hosts`:

```console
$ ../_shared/crc-forward.sh get 127.0.0.1:20443
192.168.127.130:443
$ grep -o 'shop.apps-metallb.crc.testing' /etc/hosts
shop.apps-metallb.crc.testing
```

Now from the laptop, as a browser would — the router's certificate checked
against the enterprise CA:

```console
$ curl -s --cacert <(oc get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d) -o /dev/null -w '%{http_code} %{redirect_url}\n' https://shop.apps-metallb.crc.testing:20443/ | python3 -c 'import sys, base64, urllib.parse as u; code, url = sys.stdin.read().split(); p = u.urlsplit(url); q = u.parse_qs(p.query); print(code, "->", p.scheme + "://" + p.netloc + p.path); [print("  ", k, "=", q[k][0] if k not in ("code_challenge", "state") else "<%d characters>" % len(q[k][0])) for k in sorted(q)]; s = q["state"][0]; print("   the state says: come back to", __import__("json").loads(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))["url"])'
302 -> https://keycloak.apps-crc.testing/realms/corp/protocol/openid-connect/auth
   client_id = shop-envoy
   code_challenge = <43 characters>
   code_challenge_method = S256
   redirect_uri = https://shop.apps-metallb.crc.testing:20443/oauth2/callback
   response_type = code
   scope = openid
   state = <214 characters>
   the state says: come back to https://shop.apps-metallb.crc.testing:20443/
```

**What just happened:** `GET /` from the laptop got a **`302` to realm `corp`'s
authorization endpoint**, for client `shop-envoy`, with a **PKCE** challenge,
naming where to come back to: the Route's host on port `20443`. The `state`
carries the page first asked for — `https://`, because the listener sets the
scheme ("The choices", item 5) — and a nonce the front Envoy also put in a
cookie, so the callback can be tied to this browser. Open
**<https://shop.apps-metallb.crc.testing:20443>** in a browser to use the shop;
the router's and Keycloak's certificates are from the lab's enterprise CA, which
the laptop does not trust, so the browser warns (module 16, step 7).

The forward lives in CRC's running network proxy: `crc stop` and `crc start`
lose it (not measured here — the lab's CRC is not restarted for it), and
`../00-prerequisites/ingress-shard/run.sh deploy` makes it again; this module
only reads it. On bare metal the shard's address is routable, and a DNS record
for `*.apps-metallb…` points at it: no forward, and the port is 443.

### Step 8 — sign in, as a browser does

[`browser.sh`](browser.sh) does what a browser does, with `curl` in the client
pod, so each hop can be seen: it asks the shop, follows the redirect to the login
page, posts the login to its form, and brings the code back to
the front Envoy. It asks for `https://shop.apps-metallb.crc.testing:20443`, as the
browser does, and sends the connection to the shard's address (`curl
--connect-to`): the router and the front Envoy see the same Host, redirect URI and
cookies as from the laptop. It logs in with `shop.alice` / `Ldap123!` (a lab user),
sent to the pod on standard input.

```console
$ ./browser.sh sign-in shop.alice
1. GET https://shop.apps-metallb.crc.testing:20443/ -> 302, to https://keycloak.apps-crc.testing/realms/corp/protocol/openid-connect/auth?...
2. corp login page: a form posting to https://keycloak.apps-crc.testing/realms/corp/login-actions/authenticate
3. signed in as shop.alice -> 302, back to https://shop.apps-metallb.crc.testing:20443/oauth2/callback?code=...
4. the front Envoy swapped the code for tokens -> 302, to https://shop.apps-metallb.crc.testing:20443/
   its session cookies: BearerToken IdToken OauthExpires OauthHMAC RefreshToken 
```

**What just happened:** no session, a `302` to `corp`'s login page; the password
accepted — Keycloak found `shop.alice` through the gate and checked her password
by binding to the directory as her (module 18, step 9) — and a `302` back to the
callback with a code; the front Envoy swapped it for tokens at `keycloak-service`,
set its **session cookies** — the access token (Envoy's default name,
`BearerToken`), the ID token and the refresh token, encrypted, plus an HMAC over
them and their expiry — and sent the browser on to the page it first asked for.

What does the shop receive from her session? `/whoami` goes to the echo app,
which answers with the request headers it got (a lab-only route). The command
decodes the bearer token the front Envoy sent on and prints its claims, never the
token:

```console
$ ./browser.sh shop.alice GET /whoami | python3 -c 'import base64,json,sys; h = json.load(sys.stdin)["headers"]; print("the app got:", sorted(h)); print("x-user:", h["x-user"], "| x-forwarded-proto:", h["x-forwarded-proto"]); p = h["authorization"].split()[1].split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); print("the JWT in authorization:"); [print("  ", k, c.get(k)) for k in ("iss", "aud", "azp", "preferred_username")]; print("   roles", sorted(c["realm_access"]["roles"])); print("   lives", c["exp"] - c["iat"], "s")'
the app got: ['accept', 'authorization', 'forwarded', 'host', 'user-agent', 'x-envoy-expected-rq-timeout-ms', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-port', 'x-forwarded-proto', 'x-request-id', 'x-user']
x-user: shop.alice | x-forwarded-proto: https
the JWT in authorization:
   iss https://keycloak.apps-crc.testing/realms/corp
   aud ['shop-api', 'account']
   azp shop-envoy
   preferred_username shop.alice
   roles ['default-roles-corp', 'offline_access', 'uma_authorization']
   lives 300 s
```

**What just happened:** the shop is told who is calling twice over: `x-user` —
the front Envoy set it from the verified token (`claim_to_headers`) — and the
**JWT itself**, in `authorization`: issued by `…/realms/corp`, for `shop-api`, to
**`shop-envoy`** (`azp`), as `shop.alice`, with no `admin` role, for 300 s. No
`cookie` header: the route configuration removes it
(`request_headers_to_remove`). The `forwarded` and `x-forwarded-*` headers are the
router's.

### Step 9 — what `shop.alice` may do

The kiosk's calls, made with her session:

```console
$ ./browser.sh shop.alice GET /v1/items -o /dev/null -w 'GET    /v1/items                    -> %{http_code}\n'
GET    /v1/items                    -> 200
$ ./browser.sh shop.alice GET /v1/warehouses -o /dev/null -w 'GET    /v1/warehouses               -> %{http_code}\n'
GET    /v1/warehouses               -> 200
$ ./browser.sh shop.alice POST /v1/items/SKU-1001:reserve -H 'content-type: application/json' -d '{"quantity":1,"orderId":"ALICE-1"}' -o /dev/null -w 'POST   /v1/items/SKU-1001:reserve   -> %{http_code}\n'
POST   /v1/items/SKU-1001:reserve   -> 200
$ ./browser.sh shop.alice POST /v1/items -H 'content-type: application/json' -d '{"sku":"SKU-T20","name":"a test item","onHand":5,"warehouse":"LEEDS"}' -w '   POST /v1/items -> %{http_code}\n'
RBAC: access denied   POST /v1/items -> 403
$ ./browser.sh shop.alice DELETE /v1/items/SKU-1001 -w '   DELETE /v1/items/SKU-1001 -> %{http_code}\n'
RBAC: access denied   DELETE /v1/items/SKU-1001 -> 403
$ ./browser.sh shop.alice POST /v1/items:reset -H 'content-type: application/json' -d '{}' -w '   POST /v1/items:reset -> %{http_code}\n'
RBAC: access denied   POST /v1/items:reset -> 403
```

**What just happened:** she lists the items and the warehouses and reserves
stock — `200` — and gets **`403 RBAC: access denied`** on create, delete and
reset: signed in, but not allowed. The `rbac` filter allows a request when one of
its policies matches both what is asked (its permissions) and who asks (its
principals, read from the claims `jwt_authn` verified, under `corp`):

| Policy | Permission | Principal |
|---|---|---|
| `admins` | anything (`any: true`) | `realm_access.roles` holds `admin` |
| `signed-in-may-read` | `:method` is `GET` | `iss` is `corp`'s |
| `signed-in-may-reserve` | `:method` is `POST` and `:path` matches `^/v1/items/[A-Za-z0-9._~-]+:reserve$` | `iss` is `corp`'s |
| (none matches) | `403` | |

`:path` is the whole path as sent — query string included, nothing decoded — so
the item's name is an **allow-list**, the same as module 19's: RFC 3986's
unreserved characters. No `%` means no encoded `/`, `?` or `;`; no `:` means no
second verb. Every item the shop holds is named that way (`SKU-1001` …
`SKU-5002`). Step 12 sends the requests shaped to slip past it.

### Step 10 — `shop.bob`: admin, from his LDAP group

```console
$ ./browser.sh sign-in shop.bob >/dev/null; ./browser.sh shop.bob GET /whoami | python3 -c 'import base64,json,sys; h = json.load(sys.stdin)["headers"]; p = h["authorization"].split()[1].split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); print(c["preferred_username"], "| iss", c["iss"], "| aud", c["aud"], "| azp", c["azp"], "| roles", sorted(c["realm_access"]["roles"]))'
shop.bob | iss https://keycloak.apps-crc.testing/realms/corp | aud ['shop-api', 'account'] | azp shop-envoy | roles ['admin', 'default-roles-corp', 'offline_access', 'uma_authorization']
$ ./browser.sh shop.bob POST /v1/items -H 'content-type: application/json' -d '{"sku":"SKU-T20","name":"a test item","onHand":5,"warehouse":"LEEDS"}' -o /dev/null -w 'POST   /v1/items (create SKU-T20) -> %{http_code}\n'
POST   /v1/items (create SKU-T20) -> 200
$ ./browser.sh shop.bob DELETE /v1/items/SKU-T20 -o /dev/null -w 'DELETE /v1/items/SKU-T20          -> %{http_code}\n'
DELETE /v1/items/SKU-T20          -> 200
$ ./browser.sh sign-out shop.bob
1. GET /logout -> 302, to https://keycloak.apps-crc.testing/realms/corp/protocol/openid-connect/logout?id_token_hint=...&client_id=shop-envoy&post_logout_redirect_uri=https%3A%2F%2Fshop.apps-metallb.crc.testing%3A20443%2F
   the front Envoy session cookies left: 0
2. corp logout -> 302, to https://shop.apps-metallb.crc.testing:20443/
```

**What just happened:** `shop.bob`'s JWT carries **`admin`** — `corp` gives it to
the members of the LDAP group `app-ocp-rbac-ocp-keycloak-admin` (module 18, step
10) — so the `admins` policy allows him everything: create, delete, `200`. Then
he signed out: `/logout` cleared the front Envoy's cookies and sent the browser
to `corp`'s logout with his ID token, which ended his Keycloak session and sent
him back to the shop — the address registered as the client's
`post.logout.redirect.uris`.

### Step 11 — `bob.wilson` cannot sign in

`bob.wilson` is in the directory, outside the login gate:

<!-- walkthrough: expect-exit 1 -->
```console
$ ./browser.sh sign-in bob.wilson
1. GET https://shop.apps-metallb.crc.testing:20443/ -> 302, to https://keycloak.apps-crc.testing/realms/corp/protocol/openid-connect/auth?...
2. corp login page: a form posting to https://keycloak.apps-crc.testing/realms/corp/login-actions/authenticate
3. sign-in as bob.wilson refused: 200, Invalid username or password.
command terminated with exit code 1
```

```console
$ oc logs keycloak-0 -n keycloak | grep LOGIN_ERROR | grep 'clientId="shop-envoy"' | grep 'username="bob.wilson"' | tail -n 1 | grep -o 'realmName="[^"]*"\|clientId="[^"]*"\|error="[^"]*"'
realmName="corp"
clientId="shop-envoy"
error="user_not_found"
```

**What just happened:** the login page answered with itself again — `200`,
**`Invalid username or password.`**, no code — and Keycloak's log says why,
naming this front door's client: **`user_not_found`**. He never gets a token, so
nothing reaches the front Envoy to decide.

### Step 12 — the command line: the JWT is the contract

No browser: a token from `corp`'s `shop-cli` (module 17's
[`token.sh`](../17-keycloak-jwt/token.sh), the password grant — lab only) and
[`request.sh`](request.sh), which reads it on standard input and gives it to curl
as a config file, never as an argument. The same questions as steps 9 and 10:

```console
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh GET /v1/items -o /dev/null -w 'shop.alice  GET    /v1/items                  -> %{http_code}\n'
shop.alice  GET    /v1/items                  -> 200
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh POST /v1/items/SKU-1001:reserve -H 'content-type: application/json' -d '{"quantity":1,"orderId":"ALICE-2"}' -o /dev/null -w 'shop.alice  POST   /v1/items/SKU-1001:reserve -> %{http_code}\n'
shop.alice  POST   /v1/items/SKU-1001:reserve -> 200
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh POST /v1/items -H 'content-type: application/json' -d '{"sku":"SKU-T20","name":"a test item","onHand":5,"warehouse":"LEEDS"}' -o /dev/null -w 'shop.alice  POST   /v1/items                  -> %{http_code}\n'
shop.alice  POST   /v1/items                  -> 403
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh POST /v1/items:reset -H 'content-type: application/json' -d '{}' -o /dev/null -w 'shop.alice  POST   /v1/items:reset            -> %{http_code}\n'
shop.alice  POST   /v1/items:reset            -> 403
$ ../17-keycloak-jwt/token.sh shop.bob | ./request.sh POST /v1/items -H 'content-type: application/json' -d '{"sku":"SKU-T20","name":"a test item","onHand":5,"warehouse":"LEEDS"}' -o /dev/null -w 'shop.bob    POST   /v1/items                  -> %{http_code}\n'
shop.bob    POST   /v1/items                  -> 200
```

**What just happened:** the same answers as in the browser. The token names
another client — `azp: shop-cli` — and came another way, but the front Envoy asks
the same questions of it. With a bearer token the sign-in is skipped
(`pass_through_matcher`), not the check.

While `SKU-T20` exists, the requests shaped to slip past the reserve rule, as
`shop.alice`, sent exactly as written (`curl --path-as-is`) — the set module 19
sends:

```console
$ for p in '/v1/items/SKU-T20%2Fx:reserve' '/v1/items/SKU-T20%3Fx:reserve' '/v1/items/SKU-T20%3Bx:reserve' '/v1/items/SKU-T20:reserve/' '/v1/items/SKU-T20:reserve?x=1' '/v1/items/SKU-T20:restock'; do printf '%-36s ' "POST $p"; ../17-keycloak-jwt/token.sh shop.alice | ./request.sh POST "$p" --path-as-is -H 'content-type: application/json' -d '{"quantity":1}' -o /dev/null -w '%{http_code}\n'; done
POST /v1/items/SKU-T20%2Fx:reserve   307
POST /v1/items/SKU-T20%3Fx:reserve   403
POST /v1/items/SKU-T20%3Bx:reserve   403
POST /v1/items/SKU-T20:reserve/      403
POST /v1/items/SKU-T20:reserve?x=1   403
POST /v1/items/SKU-T20:restock       403
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh PATCH /v1/items/SKU-T20 -H 'content-type: application/json' -d '{"onHand":99}' -o /dev/null -w 'PATCH /v1/items/SKU-T20                -> %{http_code}\n'
PATCH /v1/items/SKU-T20                -> 403
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh POST /v1/items/SKU-T20 -H 'X-HTTP-Method-Override: DELETE' -o /dev/null -w 'POST + X-HTTP-Method-Override: DELETE -> %{http_code}\n'
POST + X-HTTP-Method-Override: DELETE -> 403
$ ../17-keycloak-jwt/token.sh shop.alice | ./request.sh POST /v1/items/SKU-T20:reserve -X post -H 'content-type: application/json' -d '{"quantity":1}' -w '  -> %{http_code} (the method sent as "post")\n'
Bad Request  -> 400 (the method sent as "post")
$ sleep 11; oc logs -n envoy-20 deploy/front-envoy --since=3m | grep '^{' | python3 -c 'import json, sys; [print(e["status"], e["details"]) for e in map(json.loads, sys.stdin) if e["status"] in (307, 400)]'
307 path_normalization_failed
400 http1.codec_error
$ ../17-keycloak-jwt/token.sh shop.bob | ./request.sh GET /v1/items/SKU-T20 | python3 -c 'import json,sys; d = json.load(sys.stdin); print(d["sku"], "onHand", d["onHand"], "reserved", d["reserved"])'
SKU-T20 onHand 5 reserved 0
$ ../17-keycloak-jwt/token.sh shop.bob | ./request.sh DELETE /v1/items/SKU-T20 -o /dev/null -w 'shop.bob    DELETE /v1/items/SKU-T20          -> %{http_code}\n'
shop.bob    DELETE /v1/items/SKU-T20          -> 200
```

**What just happened:** none got through, and every answer is module 19's. The
encoded `/` got **`307`**: the listener unescapes an escaped slash and redirects
to the decoded path (`path_with_escaped_slashes_action: UNESCAPE_AND_REDIRECT`,
with `normalize_path` and `merge_slashes`, set as Envoy Gateway sets module 19's
listener) — `/v1/items/SKU-T20/x:reserve`, which the rule refuses (`./run.sh
verify` follows it: `403`). The rest got **`403 RBAC: access denied`**. The
lower-case `post` passed the router and got **`400 Bad Request`** from the front
Envoy's HTTP/1 codec before any filter — its access log, which Envoy writes out
every 10 s (`--file-flush-interval-msec`, default 10000; hence the `sleep`), says
`http1.codec_error` — as at module 19's Gateway. And `SKU-T20` was never touched — `onHand 5,
reserved 0` — before `shop.bob` removed it.

Now the tokens that must not pass — one **edited** to add `admin`, one from realm
**`tutorial`** (module 16's alice: a real token, for `shop-api`, from another
issuer):

```console
$ ../17-keycloak-jwt/token.sh shop.alice | python3 -c 'import base64,json,sys; h, p, s = sys.stdin.read().strip().split("."); c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); c["realm_access"]["roles"].append("admin"); print(".".join([h, base64.urlsafe_b64encode(json.dumps(c).encode()).decode().rstrip("="), s]))' | ./request.sh POST /v1/items:reset -H 'content-type: application/json' -d '{}' -w '  -> %{http_code}\n'
Jwt verification fails  -> 401
$ ../17-keycloak-jwt/token.sh alice | ./request.sh GET /v1/items -w '  -> %{http_code}\n'
Jwt issuer is not configured  -> 401
```

**What just happened:** **`401 Jwt verification fails`** — the claims no longer
match `corp`'s signature; **`401 Jwt issuer is not configured`** — the front
Envoy trusts one issuer, `…/realms/corp`. And a token that was good and has
**expired**. The regular CLI path remains `../17-keycloak-jwt/token.sh`:
realm `corp`, public client `shop-cli`, password grant. The expiry probe uses
`./expiry-token.sh`: the same grant and user, but client **`shop-envoy-cli`**
with `attributes.access.token.lifespan: "45"`. Only this test client gets short
tokens; `shop-cli`, both browser clients and realm `accessTokenLifespan: 300`
are unchanged. This avoids shortening modules 17 and 19's test tokens.

Keycloak 26.6 reads the client override for non-implicit grants in
[TokenManager.getTokenExpiration](https://github.com/keycloak/keycloak/blob/26.6.0/services/src/main/java/org/keycloak/protocol/oidc/TokenManager.java#L1004-L1039);
[OIDCConfigAttributes](https://github.com/keycloak/keycloak/blob/26.6.0/server-spi-private/src/main/java/org/keycloak/protocol/oidc/OIDCConfigAttributes.java#L52)
names the attribute. The password grant therefore honors it. Envoy's
[JwtProvider proto](https://github.com/envoyproxy/envoy/blob/v1.39.1/api/envoy/extensions/filters/http/jwt_authn/v3/config.proto)
defines `clock_skew_seconds` for `exp` and `nbf`, default 60; this provider now
sets **5**, and the probe waits to `exp + 5 + 5` (skew plus clock margin).
This tightens the verifier's tolerance for all tokens without changing browser
session lifetimes or refresh behavior.

**Existing realm: re-import `corp` using module 18 README step 13**, as in step 2
above. Applying the import alone does not add the client or its attribute.
Keep the Applications paused while testing branch changes that are not on
`main`. Rebuilding the realm invalidates sessions and changes its signing keys;
allow the existing 300-second JWKS caches to age out before testing.

Measure the issued token before relying on the override, from this directory
(bash 3.2 or zsh; no token printed or passed as a process argument):

```sh
t=$(./expiry-token.sh) || exit 1
printf '%s' "$t" | python3 -c 'import base64,json,sys; p=sys.stdin.read().strip().split(".")[1]; c=json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))); d=c["exp"]-c["iat"]; print("azp:",c["azp"],"exp - iat:",d,"seconds"); assert c["azp"]=="shop-envoy-cli" and 45 <= d <= 46'
printf '%s\n' "$t" | ./request.sh GET /v1/items -o /dev/null -w '%{http_code}\n'
wait_s=$(printf '%s' "$t" | python3 -c 'import base64,json,sys,time; p=sys.stdin.read().strip().split(".")[1]; c=json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))); print(max(0,c["exp"]+10-int(time.time())))')
sleep "$wait_s"
printf '%s\n' "$t" | ./request.sh GET /v1/items -w ' -> %{http_code}\n'
unset t
```

Measured on CRC (2026-09-28): `azp: shop-envoy-cli exp - iat: 45 seconds`, then
`200`, then, after a 55 s wait, `Jwt is expired -> 401`; the whole probe took
56 s. (46 is possible across a second boundary.) `verify` enforces the lifetime and both responses using
one unchanged token. It stops with re-import instructions if the override is
missing, rather than silently waiting six minutes. Other verification work can
consume most or all of the wait; total run time also depends on the cluster.

### Step 13 — the directory decides, at both front doors

Who is an admin is decided in one place: the LDAP group. Take `shop.bob` out of
it, as the directory's administrator — the LDIF on standard input, the admin
password read inside the directory's pod, never on a command line — and ask both
front doors, this module's and module 19's, after a new sign-in:

```console
$ printf 'dn: cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,dc=ephico2real,dc=com\nchangetype: modify\ndelete: member\nmember: uid=shop.bob,ou=People,dc=ephico2real,dc=com\n' | oc exec -i -n ldap-testing deploy/openldap-server -c openldap -- sh -c 'exec 3<&0; printf %s "$LDAP_ADMIN_PASSWORD" | ldapmodify -x -H ldap://localhost:389 -D "cn=admin,$LDAP_BASE_DN" -y /dev/stdin -f /dev/fd/3'
modifying entry "cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,dc=ephico2real,dc=com"
$ ./browser.sh sign-in shop.bob >/dev/null; ./browser.sh shop.bob POST /v1/items:reset -H 'content-type: application/json' -d '{}' -w '   module 20, shop.bob signed in again: POST /v1/items:reset -> %{http_code}\n'
RBAC: access denied   module 20, shop.bob signed in again: POST /v1/items:reset -> 403
$ ../19-shop-gateway/browser.sh sign-in shop.bob >/dev/null; ../19-shop-gateway/browser.sh shop.bob POST /v1/items:reset -H 'content-type: application/json' -d '{}' -w '   module 19, shop.bob signed in again: POST /v1/items:reset -> %{http_code}\n'
RBAC: access denied   module 19, shop.bob signed in again: POST /v1/items:reset -> 403
```

**What just happened:** at his next sign-in `shop.bob`'s token had no `admin`,
and both front doors refused him: **`403`**. Nothing changed in Keycloak, the
front Envoy, the Gateway or the shop. Put him back:

```console
$ printf 'dn: cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,dc=ephico2real,dc=com\nchangetype: modify\nadd: member\nmember: uid=shop.bob,ou=People,dc=ephico2real,dc=com\n' | oc exec -i -n ldap-testing deploy/openldap-server -c openldap -- sh -c 'exec 3<&0; printf %s "$LDAP_ADMIN_PASSWORD" | ldapmodify -x -H ldap://localhost:389 -D "cn=admin,$LDAP_BASE_DN" -y /dev/stdin -f /dev/fd/3'
modifying entry "cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,dc=ephico2real,dc=com"
$ ./browser.sh sign-in shop.bob >/dev/null; ./browser.sh shop.bob POST /v1/items:reset -H 'content-type: application/json' -d '{}' -o /dev/null -w '   module 20, shop.bob signed in again: POST /v1/items:reset -> %{http_code}\n'
   module 20, shop.bob signed in again: POST /v1/items:reset -> 200
$ ../19-shop-gateway/browser.sh sign-in shop.bob >/dev/null; ../19-shop-gateway/browser.sh shop.bob POST /v1/items:reset -H 'content-type: application/json' -d '{}' -o /dev/null -w '   module 19, shop.bob signed in again: POST /v1/items:reset -> %{http_code}\n'
   module 19, shop.bob signed in again: POST /v1/items:reset -> 200
$ oc exec -n ldap-testing deploy/openldap-server -c openldap -- sh -c 'printf %s "$LDAP_ADMIN_PASSWORD" | ldapsearch -x -LLL -o ldif-wrap=no -H ldap://localhost:389 -D "cn=admin,$LDAP_BASE_DN" -y /dev/stdin -b "cn=app-ocp-rbac-ocp-keycloak-admin,ou=Groups,$LDAP_BASE_DN" -s base member' | sed -n 's/^member: uid=\([^,]*\).*/\1/p'
john.doe
alice.cooper
sarah.jones
shop.bob
```

**What just happened:** back in the group, back to `200` at both — and the group
holds its four members again. Keycloak reads the person and their groups from
the directory at every login (`corp`'s LDAP provider has `cachePolicy:
NO_CACHE`, module 19, "The choices", item 5). An open session follows at its next
token refresh (`use_refresh_token`), and a bearer token already issued keeps its
claims until it expires — module 19 measured both (its step 13); the filters here
are the same. `./run.sh verify` checks the live `cachePolicy`, and does not change
the directory: `verify` of modules 17 and 19, run at the same time, would see
`shop.bob` without `admin`.

### Step 14 — what Envoy runs

The filter chain the front Envoy loaded, read from its admin API by
[`admin.sh`](admin.sh) — the admin API answers on the pod's loopback only, so
`admin.sh` reaches it through `oc port-forward` for the one request — and what
each filter counted during the steps above:

```console
$ ./admin.sh 'config_dump?resource=static_listeners' | python3 -c 'import json, sys; l = json.load(sys.stdin)["configs"][0]["listener"]; [print(f["name"]) for f in l["filter_chains"][0]["filters"][0]["typed_config"]["http_filters"]]'
envoy.filters.http.oauth2
envoy.filters.http.jwt_authn
envoy.filters.http.rbac
envoy.filters.http.router
$ ./admin.sh stats | grep -E '^http\.shop\.(oauth_(unauthorized_rq|passthrough|success)|jwt_authn\.(allowed|denied)|rbac\.(allowed|denied)):' | sed 's/^http\.shop\.//'
jwt_authn.allowed: 31
jwt_authn.denied: 2
oauth_passthrough: 17
oauth_success: 20
oauth_unauthorized_rq: 8
rbac.allowed: 18
rbac.denied: 13
```

**What just happened:** the chain is **`oauth2` → `jwt_authn` → `rbac` →
`router`**, the order written in the file and the order module 19's Gateway
runs. Each filter counted its part: `oauth_unauthorized_rq` — a browser without a
session sent to the login page; `oauth_passthrough` — a request with its own
bearer token; `oauth_success` — a session accepted; `jwt_authn.denied` — the
edited, the `tutorial` and the expired JWT; `rbac.denied` — the `403`s. Unlike
module 19's, the configuration is one file, the same on every route: the filters
are on at the listener, not turned on route by route.

The front Envoy access log uses `%PATH(NQ:PATH)%`: callback query parameters
(`code`, `state`) are omitted. Do not enable request-header or cookie logging;
those carry credentials. Validate this with a new sign-in after restarting the
front Envoy; historical logs are not rewritten by a configuration change.

### Step 15 — check yourself

`./run.sh verify` asks everything above again — the Route and the front Envoy's
inputs, the browser's sign-in, both users' answers, `bob.wilson`, the command
line and the requests shaped to slip past the reserve rule; the **same requests
at module 19's Gateway**, whose answers must be the same; the expired token (it
measures a 45-second test token, proves it works, then waits until `exp + 10`); every layer blocked from the client
pod — and reads the API server's audit log to check that no token or password
was in any `oc exec`'s arguments. The whole run takes about 80 s (measured). Its reservations are real ones, on items
`shop.bob` makes for the check and removes after it:

```console
$ ./run.sh verify

1. the objects, and the filters the front Envoy runs
  ✓ Route shop: admitted by the MetalLB ingress shard, and by no other router
  ✓ ...edge TLS, to the front Envoy
  ✓ the front Envoy is ready
  ✓ its client secret is module 18's (Secret shop-envoy-client = keycloak/shop-envoy-client)
  ✓ its cookie-signing key (Secret shop-envoy-hmac) holds 32 random bytes or more
  ✓ it trusts Keycloak's CA (ConfigMap keycloak-ca = Secret keycloak/keycloak-tls's ca.crt)
  ✓ it runs the configuration, Secrets and CA the cluster holds now
  ✓ realm corp's client shop-envoy: its redirect URI, PKCE S256
  ✓ the front Envoy's filter chain: oauth2, jwt_authn, rbac, router
  ✓ corp JWT provider: explicit 5 s clock skew

2. a browser with no session is sent to realm corp's login page
  ✓ the ingress shard's forward: 127.0.0.1:20443 -> 192.168.127.130:443
  ✓ from this laptop, https://shop.apps-metallb.crc.testing:20443/ -> 302 to corp's login page
  ✓ GET / -> 302 to corp's authorization endpoint
  ✓ ...as client shop-envoy
  ✓ ...with a PKCE S256 challenge
  ✓ ...and the Route's address to come back to

3. shop.alice signs in: she may list and reserve, not create, delete or reset
  ✓ shop.alice signs in on corp's login page
  ✓ her JWT, as the front Envoy sent it on: issued by corp
  ✓ ...to the front Envoy's client
  ✓ ...for the shop's API (aud shop-api)
  ✓ ...as shop.alice, without admin
  ✓ ...and no session cookie reaches the app
  ✓ GET /v1/items -> 200
  ✓ GET /v1/warehouses -> 200
  ✓ (shop.bob makes a disposable item, VERIFY-20-B-1790568999)
  ✓ POST /v1/items/VERIFY-20-B-1790568999:reserve -> reserved (ok true, 1 reserved)
  ✓ POST /v1/items (create) -> 403
  ✓ DELETE /v1/items/VERIFY-20-B-1790568999 -> 403
  ✓ POST /v1/items:reset -> 403

4. shop.bob signs in: admin, from his LDAP group - he may create and delete
  ✓ shop.bob signs in on corp's login page
  ✓ his JWT: issued by corp, for shop-api, with admin
  ✓ POST /v1/items (create SKU-V20) -> 200
  ✓ DELETE /v1/items/SKU-V20 -> 200
  ✓ POST /v1/items:reset -> 200
  ✓ DELETE /v1/items/VERIFY-20-B-1790568999 (the disposable item) -> 200
  ✓ shop.bob signs out: back to corp's logout, then the shop

5. bob.wilson - in the directory, outside the login gate - cannot sign in
  ✓ the login page refuses him
  ✓ ...because Keycloak does not find him

6. the command line: a bearer JWT, the same answers
  ✓ shop.alice: GET /v1/items -> 200
  ✓ (shop.bob makes a disposable item, VERIFY-20-C-1790569002)
  ✓ shop.alice: reserve -> reserved (ok true, 1 reserved)
  ✓ shop.alice: create -> 403 RBAC
  ✓ shop.alice: delete -> 403 RBAC
  ✓ shop.alice: reset -> 403 RBAC
  ✓ shop.bob: create -> 200
  ✓ shop.bob: delete -> 200
  ✓ shop.alice: POST /v1/items/VERIFY-20-C-1790569002%2Fx:reserve -> 307
  ✓ shop.alice: POST /v1/items/VERIFY-20-C-1790569002%3Fx:reserve -> 403
  ✓ shop.alice: POST /v1/items/VERIFY-20-C-1790569002%3Bx:reserve -> 403
  ✓ shop.alice: POST /v1/items/VERIFY-20-C-1790569002:reserve/ -> 403
  ✓ shop.alice: POST /v1/items/VERIFY-20-C-1790569002:reserve?x=1 -> 403
  ✓ shop.alice: POST /v1/items/VERIFY-20-C-1790569002:restock -> 403
  ✓ shop.alice: PATCH /v1/items/VERIFY-20-C-1790569002 -> 403
  ✓ shop.alice: POST /v1/items/VERIFY-20-C-1790569002 + X-HTTP-Method-Override: DELETE -> 403
  ✓ shop.alice: post /v1/items/VERIFY-20-C-1790569002:reserve -> 400
  ✓ ...and the %2F one's redirect, /v1/items/VERIFY-20-C-1790569002/x:reserve -> 403
  ✓ ...and VERIFY-20-C-1790569002 holds only the one reservation made above
  ✓ (shop.bob removes VERIFY-20-C-1790569002)
  ✓ shop.bob: reset -> 200
  ✓ shop.alice's JWT edited to add admin -> 401
  ✓ a JWT from realm tutorial -> 401

7. side by side with module 19: the same requests, the same answers
  ✓ shop.alice GET /v1/items: at 19 [200], at 20 the same
  ✓ shop.alice POST /v1/items (create): at 19 [RBAC: access denied -> 403], at 20 the same
  ✓ shop.alice POST /v1/items:reset: at 19 [RBAC: access denied -> 403], at 20 the same
  ✓ shop.alice PATCH /v1/items/SKU-1001: at 19 [RBAC: access denied -> 403], at 20 the same
  ✓ shop.alice POST .../SKU-1001:restock: at 19 [RBAC: access denied -> 403], at 20 the same
  ✓ shop.alice POST .../SKU-1001:reserve?x=1: at 19 [RBAC: access denied -> 403], at 20 the same
  ✓ shop.alice POST .../SKU-1001%2Fx:reserve: at 19 [ -> 307], at 20 the same
  ✓ shop.alice post (lower case) .../SKU-1001:reserve: at 19 [Bad Request -> 400], at 20 the same
  ✓ shop.bob GET /v1/warehouses: at 19 [200], at 20 the same
  ✓ the edited JWT, GET /v1/items: at 19 [Jwt verification fails -> 401], at 20 the same
  ✓ the realm tutorial JWT, GET /v1/items: at 19 [Jwt issuer is not configured -> 401], at 20 the same

8. the directory decides, at every login
  ✓ realm corp's LDAP provider reads the directory at every login (cachePolicy)
  (the change itself - shop.bob out of the admin group and back - is README step 13: verify does not change the directory)

9. an expired JWT
  (waiting 41 s: exp + 5 s provider skew + 5 s margin)
  ✓ shop.alice's JWT once it has expired -> 401

10. the Route is the only way in
  ✓ the probe itself: the shard's address, port 443, from the client pod
  ✓ the front Envoy (:8080), directly from the client pod
  ✓ the shop's Envoy (:8080), directly
  ✓ the echo app (:8080), directly
  ✓ the kiosk (:8080), directly
  ✓ the inventory, gRPC (:50051), directly
  ✓ MongoDB (:27017), directly
  ✓ the same call through the Route, with a JWT -> 200

11. no token or password in a process's arguments
  ✓ pod exec requests the API server recorded during this check (their URLs hold the arguments): some
  ✓ ...none holds a token's signature or the password

all checks passed
```

## The options

**`oauth2`** (`envoy.extensions.filters.http.oauth2.v3.OAuth2Config`)

| Field | Here | What it does | Default |
|---|---|---|---|
| `authorization_endpoint` | `keycloak.apps-crc.testing/…/auth` | where the browser is sent to sign in | — (required) |
| `token_endpoint` | `keycloak-service.keycloak.svc:8443/…/token`, cluster `keycloak` | where Envoy swaps the code for tokens | — |
| `end_session_endpoint` | `…/logout` | where `/logout` sends the browser | not set: `/logout` clears the cookies and sends the browser to `/` |
| `post_logout_redirect_uri.uri` | `https://shop.apps-metallb.crc.testing:20443/` | where Keycloak sends it back after that | `<:scheme>://<host>/` of the request |
| `credentials.client_id` | `shop-envoy` | who Envoy is at Keycloak | — |
| `credentials.token_secret`, `hmac_secret` | static secrets `client-secret`, `hmac-secret` (files) | the client secret; the key the cookies are signed with | — (by SDS when `sds_config` is set) |
| `redirect_uri` | `https://shop.apps-metallb.crc.testing:20443/oauth2/callback` | where Keycloak sends the code | — (formatter tokens allowed) |
| `redirect_path_matcher`, `signout_path` | `/oauth2/callback`, `/logout` | the two paths the filter answers itself | — |
| `forward_bearer_token` | `true` | the session's access token sent on as `Authorization: Bearer` | `false` |
| `pass_through_matcher` | `authorization`, prefix `Bearer ` | a request with its own bearer token skips the sign-in | none |
| `auth_scopes` | `[openid]` | the scopes asked for | `user` |
| `auth_type` | `BASIC_AUTH` | how the client proves itself at the token endpoint | `URL_ENCODED_BODY` |
| `use_refresh_token` | `true` | refresh an expired access token with the refresh token | `true` |
| `cookie_configs` | `same_site: LAX` on all seven; nonce and verifier on path `/oauth2/callback` | the cookies' `SameSite` and `Path` | no `SameSite`, path `/` |
| `credentials.cookie_names` | not set | `BearerToken`, `IdToken`, `RefreshToken`, `OauthHMAC`, `OauthExpires`, `OauthNonce`, `OauthCodeVerifier` | those |

**`jwt_authn`** — provider `corp`: `issuer`, `audiences: [shop-api]`,
`remote_jwks` (cluster `keycloak`, `cache_duration: 300s`, `async_fetch: {}`),
`forward: true` (keep the `Authorization` header for the app; the default removes
it), `payload_in_metadata: corp` (the claims, for `rbac`), `claim_to_headers`
`preferred_username` → `x-user`; one rule, prefix `/`, requires `corp`.

**`rbac`** — `rules.action: ALLOW` and three `policies`, each `permissions` (the
method, the `:path`) and `principals` (`sourced_metadata` from
`envoy.filters.http.jwt_authn`, key `corp`). The older `metadata` principal is
deprecated in favour of `sourced_metadata` (`api/envoy/config/rbac/v3/rbac.proto`).
A request no policy allows gets `403` `RBAC: access denied`.

**The listener** — `scheme_header_transformation.scheme_to_overwrite: https`
("The choices", item 5); `normalize_path`, `merge_slashes`,
`path_with_escaped_slashes_action: UNESCAPE_AND_REDIRECT` (step 12);
`request_headers_to_remove: [cookie]` on the virtual host (step 8).

## What production does differently

| Here (lab) | Production |
|---|---|
| a CRC forward to the shard's address, and port `20443` in the redirect URI | the shard's address routable, a DNS record for its domain, port 443, and a certificate the browsers trust |
| edge TLS: plain HTTP from the router to the front Envoy, inside NetworkPolicies | the same, or reencrypt with a serving certificate for the front Envoy, delivered by SDS so a renewal needs no restart |
| the client secret generated by `run.sh` and copied between namespaces; the HMAC key generated once | both from a vault, delivered to the pod (for example by SDS), rotated without a restart |
| one front Envoy replica | two or more — any replica reads any session: they share the HMAC key |
| the password grant (`shop-cli`) for the command line | a service's client credentials, or a person's token from a device or browser flow |
| `/whoami` echoes the bearer token | never echo a token |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| after signing in, the browser goes to `http://shop…:20443/` and fails | the front Envoy built the address from `:scheme` `http` — measured without `scheme_header_transformation`, with a client's `X-Forwarded-Proto: http` appended to by the router | keep `scheme_to_overwrite: https` on the listener |
| the front Envoy's pod stays `ContainerCreating` | a Secret or ConfigMap it mounts is missing — `shop-envoy-client`, `shop-envoy-hmac`, `keycloak-ca` are not in git | `./run.sh deploy` writes them |
| `verify`: "it runs the configuration, Secrets and CA the cluster holds now" fails | the ConfigMap changed since Envoy read it (its content in the pod differs from the API's), or a Secret or the CA was written after Envoy started — Envoy reads them only at start | `./run.sh deploy` restarts it |
| `401 Jwks doesn't have key to match kid` right after step 2 | realm `corp` was rebuilt, with new keys; Envoy keeps the old ones up to 300 s | wait (module 18, step 13) |
| Keycloak says `Invalid parameter: redirect_uri` | the client's `redirectUris` and the filter's `redirect_uri` differ | the same value in both (step 2) |
| the browser cannot load `shop.apps-metallb.crc.testing:20443` | no forward — CRC was restarted, or the shard cleaned — or the host is not in `/etc/hosts` | `../00-prerequisites/ingress-shard/run.sh deploy`; the Route must be admitted |
| `503` from the router | the Route is admitted, but the front Envoy has no ready pod | `oc get pods -n envoy-20 -l app=front-envoy` |
| `401 Jwt is expired` | the token outlived its lifespan (300 s normally, 45 s for the expiry probe) plus 5 s of skew | a fresh token; a browser session refreshes by itself |
| `401 Jwt issuer is not configured` | a token from another realm — `tutorial`'s | a `corp` token |
| the front Envoy, called from a pod, does not answer | the NetworkPolicies — by design (step 4) | call it through the Route |
| a path the shop does not have: `302` to the login page, then `404` | the filters are on at the listener, for every path (step 14) — module 19's Gateway answers `404` at once (its filters are per route) | nothing to fix; see the last section |

## Browser screenshots

To be added after the operator signs in — read-only captures with the
`/screenshot` skill, checked with `tooling/screenshot/verify.py`:

- `https://shop.apps-metallb.crc.testing:20443` → realm `corp`'s login page (the
  address bar at `keycloak.apps-crc.testing/realms/corp/…`, `client_id=shop-envoy`).
- The kiosk as `shop.alice`: the item list, and a reserve with its `200`.
- The kiosk as `shop.alice`: **Add item** refused — `HTTP 403`, `RBAC: access
  denied`.
- The kiosk as `shop.bob`: an item added (`200`) and deleted (`200`).
- `bob.wilson` on the login page: `Invalid username or password.`
- Optional: `/whoami` as each user — `x-user`, and the token's `azp: shop-envoy`.

## Permanent lab

On the operator's CRC the shop stays: it is an integration of the Keycloak
offering (module 16, [Integrations index](../16-keycloak/README.md#integrations-index)).
Argo CD's Application `20-shop-envoy`
([`../argocd/20-shop-envoy.yaml`](../argocd/20-shop-envoy.yaml)) keeps this
module's `manifests/` and the echo app behind `/whoami` — the same files
`./run.sh deploy` applies — as they are on the `main` branch. It is applied once
this module is on `main` (the Application reads `main`; before, the path does not
exist there).

### What `./run.sh deploy` makes, and who keeps it

| What | Made by | Kept by | Why |
|---|---|---|---|
| namespace `envoy-20`, the shop, the NetworkPolicies, the front Envoy's ConfigMap, Deployment and Service, Route `shop` | `manifests/` | Argo CD | manifests. The namespace carries `Prune=false` |
| **Secret `shop-envoy-client`** — the front Envoy's copy of the client secret (step 5) | `./run.sh deploy`, from module 18's `keycloak/shop-envoy-client` | nobody — `run.sh` only | not in git. After a new value in module 18's Secret (and a re-import of `corp`), `./run.sh deploy` copies it again and restarts the front Envoy; `./run.sh verify` checks both hold the same |
| **Secret `shop-envoy-hmac`** — the key the session cookies are signed with | `./run.sh deploy`, once, random | nobody — `run.sh` only | not in git; a new one signs every session out |
| **ConfigMap `keycloak-ca`** — the CA the front Envoy trusts Keycloak with | `./run.sh deploy`, from Secret `keycloak/keycloak-tls` | nobody — `run.sh` only | the cluster's own CA, as module 16's copy |
| **a restart of the front Envoy** when it is older than any of those inputs or its ConfigMap | `./run.sh deploy` | nobody — `run.sh` only | Envoy reads them once, at start ("The choices", item 3). Argo CD applies a changed ConfigMap and restarts nothing; `verify` fails until `deploy` has restarted it |
| the echo app | [`../_shared/echo-app.yaml`](../_shared/echo-app.yaml), with `-n envoy-20` | Argo CD — the Application's second source | as module 19 |
| client `shop-envoy` in realm `corp` | module 18's realm file, imported once (step 2) | Argo CD `18-keycloak-ldap` keeps the import; the realm is created once | an import only creates (module 18, step 13) |
| the MongoDB claim `inventory-db` | the manifest | Argo CD | on CRC its volume outlives it (`reclaimPolicy: Retain`) |
| the laptop's forward `127.0.0.1:20443` | the ingress shard's `run.sh` | the ingress shard's `run.sh` | this module only reads it |
| pod `client` | `./run.sh deploy` | nobody | a test tool |

Without its three inputs the front Envoy's pod does not start, so nothing is
served; the Route is in a later sync wave, which Argo CD applies once the
Deployment is healthy (Argo CD's sync waves — not measured here: the Application
exists only once this module is on `main`). So on a new cluster run `./run.sh
deploy` before `oc apply -f ../argocd/20-shop-envoy.yaml`.

## Clean up

On the permanent lab a clean-up is a deliberate reset, never the end of a
walkthrough. `./run.sh clean` pauses Argo CD's Application and deletes namespace
`envoy-20` — the shop, its database claim, the front Envoy, its Secrets and the
Route. Realm `corp`'s client `shop-envoy` and Secret `keycloak/shop-envoy-client`
stay: they are module 18's. The ingress shard and its forward stay: they are the
shard's.

<!-- walkthrough: skip -->
```console
$ ./run.sh clean
```

## The shortcut

`./run.sh deploy` does steps 3 to 6 (step 2's client must already be in `corp`),
and resumes Argo CD's Application if there is one; `./run.sh verify` is step 15;
`./run.sh clean` is the clean-up; `./run.sh pause` and `./run.sh resume` are the
[Permanent lab](#permanent-lab)'s.

## Module 19 and module 20, side by side

The same shop, the same realm and the same rules, built two ways: module 19 with
the **Gateway API and Envoy Gateway** (a `Gateway`, an `HTTPRoute`, one
`SecurityPolicy`), module 20 with **a standalone Envoy configured by hand**
behind an **OpenShift Route**. Both run Envoy 1.39.1 and the same three filters
in the same order, `oauth2` → `jwt_authn` → `rbac` (module 19's step 14, module
20's step 14). This section is the same in both modules' READMEs.

### The same answers

Measured on CRC; module 20's `./run.sh verify` sends the command-line requests to
both front doors with the same tokens and compares the answers (its section 7):

| Case | Module 19 (Gateway) | Module 20 (Route + Envoy) |
|---|---|---|
| a browser with no session | `302` to `corp`'s login page, client `shop-kiosk`, PKCE `S256` | `302` to `corp`'s login page, client `shop-envoy`, PKCE `S256` |
| `shop.alice`: list, reserve | `200` | `200` |
| `shop.alice`: create, delete, reset, `PATCH`, `:restock`, `:reserve?x=1` | `403 RBAC: access denied` | `403 RBAC: access denied` |
| `shop.alice`: `…%2Fx:reserve` | `307`, then `403` | `307`, then `403` |
| `shop.alice`: `post` in lower case | `400 Bad Request` (HTTP/1 codec) | `400 Bad Request` (HTTP/1 codec, behind the router) |
| `shop.bob`: create, delete, reset | `200` | `200` |
| `bob.wilson` | cannot sign in, `user_not_found` | cannot sign in, `user_not_found` |
| a bearer JWT from the command line | the same answers as the browser | the same answers as the browser |
| an edited JWT; a `tutorial` JWT; an expired JWT | `401 Jwt verification fails`; `401 Jwt issuer is not configured`; `401 Jwt is expired` | the same three |
| the layers behind it, called directly | no answer (NetworkPolicies) | no answer (NetworkPolicies) |
| `shop.bob` out of the LDAP group, signed in again | `403`; back in: `200` | `403`; back in: `200` (module 20, step 13, both measured) |
| the JWT the app receives | `azp: shop-kiosk`, `x-user`, no cookie on `/whoami` | `azp: shop-envoy`, `x-user`, no cookie on any route |

One configuration difference, measured: module 20 allows 5 seconds of JWT clock
skew (`clock_skew_seconds: 5` in the running `config_dump`); module 19 keeps the default 60.
Both reject expired tokens, at different boundaries. Module 20 uses a dedicated
45-second `shop-envoy-cli` token for its expiry test; regular `shop-cli` and
browser token lifetimes remain 300 seconds.

**Other measured differences:**

- **A path the shop does not have** (`/nothing`), without a session: module 19
  answers `404` at once — Envoy Gateway turns the filters on per route, and no
  route matches; module 20 answers `302` to the login page, then `404` once
  signed in — its filters are on at the listener. With a token both answer `404`;
  neither routes the shop's native gRPC paths (`404` at both).
- **The browser's address.** Module 19: `http://localhost:19080`, plain HTTP —
  Chromium keeps Envoy's `Secure` cookies over plain HTTP only on `localhost`.
  Module 20: `https://shop.apps-metallb.crc.testing:20443`, the router's
  certificate — and so a setting module 19 does not need: the router appends to a
  client's `X-Forwarded-Proto`, which made the `oauth2` filter send the browser
  back to `http://` until the listener said `scheme_to_overwrite: https`.
- **The cookies.** Module 19's are named by Envoy Gateway, with a suffix
  (`AccessToken-ab2789d9` …); module 20's are Envoy's defaults (`BearerToken` …).
  Both `Secure`, `HttpOnly`, `SameSite=Lax`.
- **The Envoy's pod.** Module 19's runs under the `nonroot-v2` SCC, granted by its
  `run.sh` (module 12, step 4); module 20's under the default `restricted-v2`, no
  grant (measured, `openshift.io/scc` on each pod).

### Where each piece of configuration lives

| What | Module 19 | Module 20 |
|---|---|---|
| the way in | `Gateway eg` (a MetalLB address) + `HTTPRoute shop`, and a CRC forward from `127.0.0.1:19080` | `Route shop`, label `ingress-shard=metallb`, edge TLS on the shard's certificate, and the shard's forward from `127.0.0.1:20443` |
| the sign-in | `SecurityPolicy sign-in` → `oidc` | `70-front-envoy-config.yaml` → `http_filters` → `envoy.filters.http.oauth2` |
| the JWT check | `SecurityPolicy sign-in` → `jwt.providers[corp]` | → `envoy.filters.http.jwt_authn`, provider `corp`, one rule for `/` |
| the permissions | `SecurityPolicy sign-in` → `authorization.rules` | → `envoy.filters.http.rbac`, three `policies` |
| the order of the filters | Envoy Gateway's (`httpfilters.go`) | the order written in the file |
| the client secret | Secret `envoy-19/shop-kiosk-oidc`, a copy of `keycloak/shop-kiosk-client`; Envoy gets it by SDS from Envoy Gateway | Secret `envoy-20/shop-envoy-client`, a copy of `keycloak/shop-envoy-client`, mounted as a file; a static secret, read at start |
| the cookie-signing key | Envoy Gateway's `envoy-gateway-system/envoy-oidc-hmac`, one for every OIDC policy of the controller | Secret `envoy-20/shop-envoy-hmac`, generated once by `run.sh`, mounted as a file |
| TLS to Keycloak's Service | module 16's `BackendTLSPolicy keycloak-service` and a `ReferenceGrant` in `keycloak` | a cluster with an `UpstreamTlsContext` (SNI, the certificate's name) and ConfigMap `envoy-20/keycloak-ca`, `run.sh`'s copy |
| the paths | `HTTPRoute shop`'s matches | the virtual host's `routes` |
| the client in realm `corp` | `shop-kiosk`, redirect `http://localhost:19080/oauth2/callback` | `shop-envoy`, redirect `https://shop.apps-metallb.crc.testing:20443/oauth2/callback` |
| who reaches the shop | NetworkPolicies: this Gateway's Envoy pods only | NetworkPolicies: the shard's router pods reach the front Envoy, the front Envoy reaches the shop |

### What Envoy Gateway generated, and what module 20 writes by hand

Module 19's [`generated/envoy-filters.yaml`](../19-shop-gateway/generated/envoy-filters.yaml) is
read from its running Envoy: 242 lines for the listener's chain and **one** route
of five, generated from 63 lines of `SecurityPolicy` (without comments). Module
20's [`manifests/70-front-envoy-config.yaml`](manifests/70-front-envoy-config.yaml)
is Envoy's **whole** configuration — listener, routes, filters, clusters, secrets
— in 186 lines (without comments). Filter by filter:

| | Envoy Gateway generated (module 19) | Written by hand (module 20) |
|---|---|---|
| where each filter's settings are | at the listener, `oauth2` and `rbac` **empty** (off); each of the five routes turns all three on in `typed_per_filter_config` — the same `oauth2` block five times | at the listener, once, for every route |
| `oauth2` | `OAuth2PerRoute.config`: the endpoints, `credentials` with `token_secret`/`hmac_secret` by SDS name (`oauth2/client_secret/securitypolicy/envoy-19/sign-in`), `cookie_names` with a suffix, `cookie_configs` `LAX` (nonce and verifier on `/oauth2/callback`), `forward_bearer_token`, `pass_through_matcher` `Authorization: Bearer `, `auth_type: BASIC_AUTH`, `use_refresh_token`, `end_session_endpoint` | the same fields, with `token_secret`/`hmac_secret` naming static secrets read from files, Envoy's default cookie names, and `post_logout_redirect_uri` written out |
| `jwt_authn` | provider `corp_ce9edcdadc53325b` (a hash), cluster `securitypolicy/envoy-19/sign-in/jwt/0`, `cache_duration: 300s`, `async_fetch`, `forward`, `payload_in_metadata: corp`, `claim_to_headers`; a `requirement_map`, chosen per route by `requirement_name` | provider `corp`, cluster `keycloak`, those settings plus explicit `clock_skew_seconds: 5`; one `rules` entry, prefix `/` |
| `rbac` | the **matcher** API: a `matcher_list` of predicates on `DynamicMetadataInput` (`jwt_authn`/`corp`/…) and `HttpRequestHeaderMatchInput` (`:method` with `ignore_case`, `:path` with a `safe_regex`), first match wins, `on_no_match: DENY` | the **policy** API: `action: ALLOW` and three named `policies`, each `permissions` (`:method`, `:path`) and `principals` (`sourced_metadata` from `jwt_authn`/`corp`); no policy matches → `403` |
| the listener | `normalize_path`, `merge_slashes`, `path_with_escaped_slashes_action: UNESCAPE_AND_REDIRECT`, set by Envoy Gateway | the same three, written out, and `scheme_header_transformation` (the router in front) |
| names | derived: `httproute/envoy-19/shop/rule/0/match/0/*`, `securitypolicy/envoy-19/sign-in/oidc/0` | chosen: `shop`, `keycloak`, `echo` |

### When to choose which — from what was measured

**The Gateway (module 19)** when the platform runs a Gateway API controller and
wants one object per concern:

- the sign-in, the JWT check and the permissions are 63 lines of one
  `SecurityPolicy`; Envoy Gateway writes the 242-line per-route filter
  configuration, the Keycloak clusters, the SDS secrets and the cookie key;
- the policy targets the Gateway, so every route gets the same three filters,
  per route: a path no route has gets `404` without a sign-in;
- TLS to Keycloak is one shared `BackendTLSPolicy` (module 16's), allowed by a
  `ReferenceGrant`;
- what it costs: Envoy Gateway's names and choices (cookie names, the matcher
  API, the filter order), a controller to run, and the Gateway's `nonroot-v2`
  grant on OpenShift. A field its API does not expose — `grpc_json_transcoder`
  (module 19, "The choices", item 3) — needs `EnvoyPatchPolicy`, off by default,
  or another Envoy behind it, as here.

**A standalone Envoy (module 20)** when a team runs its own Envoy, behind
OpenShift's routers, or needs a filter setting no Gateway API exposes:

- every field is in one file, read top to bottom in the order Envoy runs it;
  nothing is generated, and the names are the team's;
- anything Envoy has is one field away — here `scheme_header_transformation`,
  needed because an OpenShift router ends TLS in front (measured);
- the default `restricted-v2` SCC is enough: no extra grant;
- what it costs, measured and read in the source: Envoy reads its configuration
  and static secrets **once, at start** — a change is a restart, which
  `./run.sh deploy` does and `./run.sh verify` checks; Argo CD updates the
  ConfigMap and restarts nothing. Three inputs are `run.sh`'s, not git's — the
  client secret's copy, the cookie key, the CA's copy — where Envoy Gateway keeps
  the key itself and reads the client secret by SDS. And the configuration is
  186 lines to own, against 63.

Both give the same answers to the same requests; the choice is who writes the
Envoy configuration, and who keeps it running.

## References

- [Envoy — OAuth2 filter](https://www.envoyproxy.io/docs/envoy/v1.39.1/configuration/http/http_filters/oauth2_filter)
- [Envoy — JWT Authentication filter](https://www.envoyproxy.io/docs/envoy/v1.39.1/configuration/http/http_filters/jwt_authn_filter)
- [Envoy — RBAC filter](https://www.envoyproxy.io/docs/envoy/v1.39.1/configuration/http/http_filters/rbac_filter)
- [Envoy v1.39.1 source](https://github.com/envoyproxy/envoy/tree/v1.39.1) — `source/extensions/filters/http/oauth2/{config,filter}.cc`, `source/common/secret/secret_provider_impl.cc`, `source/common/http/conn_manager_utility.cc`
- [OpenShift — route configuration (annotations, `disable_cookies`)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/routes)
- [RFC 7636 — Proof Key for Code Exchange](https://www.rfc-editor.org/rfc/rfc7636)
- [OpenID Connect RP-Initiated Logout 1.0](https://openid.net/specs/openid-connect-rpinitiated-1_0.html)
- [Red Hat build of Keycloak 26.6 — Server Administration Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/server_administration_guide/index)
- [Kubernetes — ConfigMaps: a subPath mount receives no updates](https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically)
- [Kubernetes — Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

## Diagram sources

The figure is rendered from [`docs/diagrams/20-shop-envoy/source.html`](../docs/diagrams/20-shop-envoy/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
