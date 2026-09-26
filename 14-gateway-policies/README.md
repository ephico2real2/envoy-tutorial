# 14 — Envoy Gateway policies: resilience and security as resources

Module 13 stayed inside the standard `HTTPRoute`. Much of what modules 06 and
11 built by hand — retries, outlier detection, circuit breakers, rate limits,
JWT, CORS — is not in that standard. Envoy Gateway adds it with **policies**:
resources of its own that **attach to a route** (or a Gateway) and change how
traffic through it is handled, without touching the route itself.

| Policy | For | Modules it replaces |
|---|---|---|
| **`BackendTrafficPolicy`** | the proxy → backend side: retries, health checks, circuit breakers, rate limits, load balancing | 05, 06, 11 |
| **`SecurityPolicy`** | who may call: JWT, CORS, basic auth, API keys, authorization | 06 |

The trade: these are **Envoy Gateway's** resources (`gateway.envoyproxy.io`),
not the portable Gateway API — module 12's second figure. Each step below
applies one policy, measures the effect against the same misbehaving backends as
module 11, and reads what Envoy got.

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/14-gateway-policies/policies.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/14-gateway-policies/policies.light.png">
  <img alt="Three plain HTTPRoutes, /pool, /slow and /api, with no retry, limit or authentication in them. Policies attach to them with targetRefs: a BackendTrafficPolicy on pool with a retry on 503 and a passive health check; a BackendTrafficPolicy on slow with a circuit breaker of 2 in flight and 2 waiting; on api, a BackendTrafficPolicy rate limit of 3 a minute and a SecurityPolicy with JWT and CORS. Envoy got: for pool, a route retry_policy with previous_hosts and 5 picks added by Envoy Gateway, and cluster outlier detection that ejected the sick pod; for slow, cluster circuit breakers, 2 served and 8 refused within 0.02 seconds; for api, the filters cors, jwt_authn, local_ratelimit in Envoy Gateway&#x27;s order, 401 without a token, 429 after 3, and the token forwarded to the app." src="../docs/diagrams/14-gateway-policies/policies.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

## What you'll learn

- how a policy **targets** a route, and how to read whether it was accepted
- module 11's retry, outlier detection and circuit breaker as a
  `BackendTrafficPolicy` — and what Envoy Gateway adds on its own
- why a policy that changes a **cluster** takes about 15 seconds to arrive, when
  a route change takes under one
- module 06's JWT, CORS and rate limit as policies, and the filter order Envoy
  Gateway chooses for you

## Before you start

- Module [`12`](../12-gateway-api/README.md) — at least its setup — and modules
  [`06`](../06-http-filters/README.md) and [`11`](../11-resilience/README.md),
  whose features this module re-creates. Module 06's `make-jwt.sh` mints the
  tokens.
- Work from this folder: `cd 14-gateway-policies`.
- This module uses the namespace **`envoy-14`** and takes about 25 minutes.

## Walkthrough

### Step 1 — a Gateway, a pool with a sick pod, a slow app

The `GatewayClass` from module 12, this module's `Gateway`, and the OpenShift fix
from module 12, step 4:

```console
$ oc apply -f ../12-gateway-api/manifests/20-envoyproxy.yaml -f ../12-gateway-api/manifests/10-gatewayclass.yaml
envoyproxy.gateway.envoyproxy.io/openshift-scc unchanged
gatewayclass.gateway.networking.k8s.io/eg unchanged
$ oc apply -f manifests/10-gateway.yaml
namespace/envoy-14 created
gateway.gateway.networking.k8s.io/eg created
$ sleep 10; oc adm policy add-scc-to-user nonroot-v2 -n envoy-gateway-system -z "$(oc get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-14 -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}')"
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:nonroot-v2 added: "envoy-envoy-14-eg-8619a82a"
$ oc rollout restart deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-14
deployment.apps/envoy-envoy-14-eg-8619a82a restarted
$ oc rollout status deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-14 --timeout=240s
Waiting for deployment "envoy-envoy-14-eg-8619a82a" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "envoy-envoy-14-eg-8619a82a" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "envoy-envoy-14-eg-8619a82a" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-14-eg-8619a82a" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "envoy-envoy-14-eg-8619a82a" rollout to finish: 1 old replicas are pending termination...
deployment "envoy-envoy-14-eg-8619a82a" successfully rolled out
$ oc wait gateway/eg -n envoy-14 --for=condition=Programmed --timeout=120s
gateway.gateway.networking.k8s.io/eg condition met
```

The backends. [`manifests/20-pool.yaml`](manifests/20-pool.yaml) is a Service
`pool` over **three** pods: two healthy `good` pods and, from
[`30-sick-app.yaml`](manifests/30-sick-app.yaml), module 05's **sick** pod —
Ready, but answering every request with `503`. Plus the echo app and module 04's
one-second **slow** app. And three plain `HTTPRoute`s: `/pool`, `/slow`, `/api`:

```console
$ oc apply -n envoy-14 -f ../_shared/client.yaml -f ../_shared/echo-app.yaml -f manifests/20-pool.yaml -f manifests/30-sick-app.yaml -f manifests/35-slow-app.yaml -f manifests/40-routes.yaml
pod/client created
configmap/echo-src created
service/echo created
deployment.apps/echo created
service/pool created
deployment.apps/good created
configmap/sick-src created
service/sick created
deployment.apps/sick created
configmap/slow-src created
service/slow created
deployment.apps/slow created
httproute.gateway.networking.k8s.io/pool created
httproute.gateway.networking.k8s.io/slow created
httproute.gateway.networking.k8s.io/api created
$ for d in echo good sick slow; do oc rollout status -n envoy-14 deploy/$d --timeout=240s; done
Waiting for deployment "echo" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "echo" rollout to finish: 1 of 2 updated replicas are available...
deployment "echo" successfully rolled out
deployment "good" successfully rolled out
deployment "sick" successfully rolled out
deployment "slow" successfully rolled out
$ oc wait -n envoy-14 --for=condition=Ready pod/client --timeout=120s
pod/client condition met
```

### Step 2 — no policy

Ninety requests to `/pool`:

```console
$ oc exec -n envoy-14 client -- sh -c "for i in \$(seq 1 90); do curl -s -o /dev/null -w '%{http_code}\n' http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/pool; done" | sort | uniq -c
  55 200
  35 503
```

**What just happened:** about one request in three failed — the sick pod's
share, as in module 11, step 3.

### Step 3 — a retry, as a policy

[`manifests/50-retry.yaml`](manifests/50-retry.yaml) is a `BackendTrafficPolicy`
whose **`targetRefs`** names the `HTTPRoute` `pool`. It says: on a `503`, retry
once. The route itself is unchanged:

```console
$ oc apply -f manifests/50-retry.yaml
backendtrafficpolicy.gateway.envoyproxy.io/pool created
$ sleep 5; oc get backendtrafficpolicy pool -n envoy-14 -o jsonpath='{range .status.ancestors[0].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
Accepted=True Policy has been accepted.
$ oc exec -n envoy-14 client -- sh -c "for i in \$(seq 1 90); do curl -s -o /dev/null -w '%{http_code}\n' http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/pool; done" | sort | uniq -c
  90 200
```

A policy reports on itself in `status.ancestors` — here, accepted for the
Gateway `eg`. And the failures are gone. Module 11 needed two lines more than a
retry to get there — ask Envoy what it was given:

```console
$ ../_shared/eg-admin.sh envoy-14/eg 'config_dump?resource=dynamic_route_configs' | python3 -c 'import json,sys; [print(json.dumps(r["route"]["retry_policy"], indent=1)) for rc in json.load(sys.stdin)["configs"] for vh in rc["route_config"]["virtual_hosts"] for r in vh["routes"] if "/pool/" in r["route"].get("cluster", "")]'
{
 "retry_on": "connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes",
 "num_retries": 1,
 "retry_host_predicate": [
  {
   "name": "envoy.retry_host_predicates.previous_hosts",
   "typed_config": {
    "@type": "type.googleapis.com/envoy.extensions.retry.host.previous_hosts.v3.PreviousHostsPredicate"
   }
  }
 ],
 "host_selection_retry_max_attempts": "5",
 "retriable_status_codes": [
  503
 ]
}
```

**What just happened:** Envoy Gateway turned "retry once on 503" into module
11's **`/retry-elsewhere`**, on its own: `previous_hosts`, so the retry avoids the
pod that just failed, with **five** extra picks (`host_selection_retry_max_attempts`,
module 11 used three). It also retries on connection failures and on gRPC
`unavailable` and `cancelled`, besides the `503` asked for.

### Step 4 — a passive health check: eject the sick pod

[`manifests/55-retry-and-eject.yaml`](manifests/55-retry-and-eject.yaml) is the
**same** policy — same name, so applying it replaces step 3's — plus a
**passive health check**: Envoy Gateway's name for module 11's outlier detection.
Two `5xx` in a row and a pod is ejected for 30 s:

```console
$ oc apply -f manifests/55-retry-and-eject.yaml
backendtrafficpolicy.gateway.envoyproxy.io/pool configured
$ sleep 20; ../_shared/eg-admin.sh envoy-14/eg 'config_dump?resource=dynamic_active_clusters' | python3 -c 'import json,sys; [print(json.dumps(c["cluster"]["outlier_detection"], indent=1)) for c in json.load(sys.stdin)["configs"] if "/pool/" in c["cluster"]["name"]]'
{
 "consecutive_5xx": 2,
 "interval": "1s",
 "base_ejection_time": "30s",
 "max_ejection_percent": 50,
 "consecutive_local_origin_failure": 5,
 "always_eject_one_host": false
}
```

Why `sleep 20`? A route change reaches Envoy in under a second (module 12, step
9), but this change is to the **cluster**, and a changed cluster takes about
**15 seconds** — measured 15.1 and 15.2 s. Envoy *warms* a changed cluster before
using it: it waits for its endpoints (EDS), and for an unchanged endpoint list
no new update came. Envoy waits out `initial_fetch_timeout` — **15 s** by default
— and carries on; the old cluster serves in the meantime. Envoy counts both:

```console
$ ../_shared/eg-admin.sh envoy-14/eg stats | grep -E '^cluster_manager\.cluster_modified:|^cluster\.httproute/envoy-14/pool/rule/0\.init_fetch_timeout:'
cluster.httproute/envoy-14/pool/rule/0.init_fetch_timeout: 1
cluster_manager.cluster_modified: 1
```

One cluster change, one initial-fetch timeout. Now send traffic and look at the
pods:

```console
$ oc exec -n envoy-14 client -- sh -c "for i in \$(seq 1 30); do curl -s -o /dev/null -w '%{http_code}\n' http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/pool; done" | sort | uniq -c
  30 200
$ ../_shared/eg-admin.sh envoy-14/eg clusters | grep '^httproute/envoy-14/pool/.*health_flags'
httproute/envoy-14/pool/rule/0::10.217.0.252:8080::health_flags::healthy
httproute/envoy-14/pool/rule/0::10.217.0.251:8080::health_flags::healthy
httproute/envoy-14/pool/rule/0::10.217.0.253:8080::health_flags::/failed_outlier_check
$ oc get pod -n envoy-14 -l app=sick -o jsonpath='{.items[0].status.podIP}{"\n"}'
10.217.0.253
```

**What just happened:** the sick pod's IP is marked **`/failed_outlier_check`** —
ejected, as in module 11, step 6. The two failures that condemned it were
retried, so the client saw none: retry and ejection together.

### Step 5 — a circuit breaker

[`manifests/60-circuit-breaker.yaml`](manifests/60-circuit-breaker.yaml), on the
route `/slow`: at most 2 requests in flight and 2 waiting. Another cluster
change, so wait again. Then ten requests at once:

```console
$ oc apply -f manifests/60-circuit-breaker.yaml
backendtrafficpolicy.gateway.envoyproxy.io/slow created
$ sleep 20; oc exec -n envoy-14 client -- sh -c "seq 1 10 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code} after %{time_total}s\n' http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/slow" | sort
200 after 1.003958s
200 after 1.004723s
503 after 0.000316s
503 after 0.002538s
503 after 0.003492s
503 after 0.003615s
503 after 0.014001s
503 after 0.014385s
503 after 0.014712s
503 after 0.015795s
$ ../_shared/eg-admin.sh envoy-14/eg 'config_dump?resource=dynamic_active_clusters' | python3 -c 'import json,sys; [print(json.dumps(c["cluster"]["circuit_breakers"])) for c in json.load(sys.stdin)["configs"] if "/slow/" in c["cluster"]["name"]]'
{"thresholds": [{"max_connections": 1024, "max_pending_requests": 2, "max_requests": 2, "max_retries": 1024}]}
```

**What just happened:** module 11, step 7, again: two served after the app's one
second, the rest refused at once. `maxParallelRequests` and `maxPendingRequests`
became `max_requests` and `max_pending_requests`; the limits not set stay at
Envoy's defaults (`max_connections: 1024`) — except `max_retries`, which Envoy
Gateway raises from Envoy's 3 to 1024.

### Step 6 — a rate limit

[`manifests/70-rate-limit.yaml`](manifests/70-rate-limit.yaml), on `/api`: 3
requests a minute. Five requests in a row:

```console
$ oc apply -f manifests/70-rate-limit.yaml
backendtrafficpolicy.gateway.envoyproxy.io/api created
$ sleep 3; oc exec -n envoy-14 client -- sh -c "for i in 1 2 3 4 5; do curl -s -o /dev/null -w '%{http_code} ' http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/api; done; echo"
200 200 200 429 429 
$ oc exec -n envoy-14 client -- curl -s -o /dev/null -D - "http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/api" | grep -iE '^(HTTP|x-ratelimit)'
HTTP/1.1 429 Too Many Requests
x-ratelimit-limit: 3
x-ratelimit-remaining: 0
x-ratelimit-reset: 20
$ ../_shared/eg-admin.sh envoy-14/eg 'config_dump?resource=dynamic_route_configs' | python3 -c 'import json,sys; [print(json.dumps({k: v for k, v in r["typed_per_filter_config"]["envoy.filters.http.local_ratelimit"].items() if k in ("token_bucket", "filter_enabled", "filter_enforced", "enable_x_ratelimit_headers")}, indent=1)) for rc in json.load(sys.stdin)["configs"] for vh in rc["route_config"]["virtual_hosts"] for r in vh["routes"] if "/api/" in r["route"].get("cluster", "")]'
{
 "token_bucket": {
  "max_tokens": 3,
  "tokens_per_fill": 3,
  "fill_interval": "60s"
 },
 "filter_enabled": {
  "default_value": {
   "numerator": 100
  }
 },
 "filter_enforced": {
  "default_value": {
   "numerator": 100
  }
 },
 "enable_x_ratelimit_headers": "DRAFT_VERSION_03"
}
```

**What just happened:** three `200`s, then **`429 Too Many Requests`**, with
headers that tell the client the limit and when to come back. Underneath is
module 06's `local_ratelimit`: a token bucket of 3, refilled by 3 every 60 s —
and, as module 06 measured, the refill is continuous: one token every 20 s,
which is the `x-ratelimit-reset` the client was given. Envoy Gateway also set
`filter_enabled` and `filter_enforced` to 100 % — module 06's trap, where both
default to 0 % and the filter does nothing, handled for you.

### Step 7 — JWT: only signed-in callers

[`manifests/80-jwt-cors.yaml`](manifests/80-jwt-cors.yaml) is a
**`SecurityPolicy`** on `/api`: tokens signed with module 06's key, and the
token's subject passed to the app as `x-user`:

```console
$ oc apply -f manifests/80-jwt-cors.yaml
securitypolicy.gateway.envoyproxy.io/api created
$ sleep 5; oc exec -n envoy-14 client -- curl -s -w '  -> %{http_code}\n' "http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/api"
Jwt is missing  -> 401
$ oc exec -n envoy-14 client -- curl -s -w '  -> %{http_code}\n' -H "authorization: Bearer $(../06-http-filters/make-jwt.sh alice forged)" "http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/api"
Jwt verification fails  -> 401
```

No token, and a forged one: both **`401`**, with module 06's reasons. Now a real
token — after a pause, because step 6's limit still applies to `/api` and its
bucket is empty:

```console
$ sleep 20; oc exec -n envoy-14 client -- curl -s -H "authorization: Bearer $(../06-http-filters/make-jwt.sh alice)" "http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/api" | grep -E '"(served_by|x-user|authorization)"'
  "served_by": "echo-f8fc6d5c9-sk4n2",
    "authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InR1dG9yaWFsIn0.eyJpc3MiOiJlbnZveS10dXRvcmlhbCIsInN1YiI6ImFsaWNlIiwiZXhwIjoxNzkwNDA1Nzc4fQ.j1GpiluDJl4kadNdzr9kthx203OjfT3XQiL3Vpo0G_0",
    "x-user": "alice"
```

**What just happened:** alice reached the app, and the app was told
**`x-user: alice`** — a header it can trust, because Envoy verified the token
first. One difference from module 06: the app also received the
**`authorization`** header. Plain Envoy removes the token once verified (`forward`
defaults to `false`); Envoy Gateway sets `forward: true`, so the token travels on.
If the app should not see it, that is a setting to know about.

### Step 8 — CORS

The same `SecurityPolicy` allows browser calls from `https://shop.example.com`.
A browser asks first, with a **preflight** `OPTIONS` request:

```console
$ oc exec -n envoy-14 client -- curl -s -o /dev/null -D - -X OPTIONS -H 'origin: https://shop.example.com' -H 'access-control-request-method: POST' "http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/api" | grep -iE '^(HTTP|access-control)'
HTTP/1.1 200 OK
access-control-allow-origin: https://shop.example.com
access-control-allow-methods: GET, POST
access-control-allow-headers: authorization, content-type
access-control-max-age: 600
$ oc exec -n envoy-14 client -- curl -s -o /dev/null -D - -X OPTIONS -H 'origin: https://evil.example.com' -H 'access-control-request-method: POST' "http://$(oc get gateway eg -n envoy-14 -o jsonpath='{.status.addresses[0].value}')/api" | grep -iE '^(HTTP|access-control)'
HTTP/1.1 200 OK
access-control-allow-methods: GET, POST
access-control-allow-headers: authorization, content-type
access-control-max-age: 600
```

**What just happened:** the allowed origin got
`access-control-allow-origin: https://shop.example.com`; the other got **no**
`access-control-allow-origin`, so a browser blocks the call. Neither preflight
carried a token, yet neither got a `401` — which depends on the order of the
filters.

### Step 9 — the filter order you did not choose

In module 06 you wrote the filter chain yourself, and its order changed what
happened. Here, Envoy Gateway wrote it:

```console
$ ../_shared/eg-admin.sh envoy-14/eg 'config_dump?resource=dynamic_listeners' | python3 -c 'import json,sys; [print(h["name"]) for l in json.load(sys.stdin)["configs"] if l["name"] == "envoy-14/eg/http" for fc in [l["active_state"]["listener"].get("default_filter_chain")] + l["active_state"]["listener"].get("filter_chains", []) if fc for f in fc["filters"] for h in f["typed_config"].get("http_filters", [])]'
envoy.filters.http.cors
envoy.filters.http.jwt_authn
envoy.filters.http.local_ratelimit
envoy.filters.http.router
```

**What just happened:** **`cors` → `jwt_authn` → `local_ratelimit` → `router`** —
the order module 06 argued for. CORS first, so a preflight is answered before JWT
could reject it for having no token (step 8). JWT before the rate limit, so a
caller without a valid token is refused without spending a token of the limit.
With Envoy Gateway you do not choose the order — the filters it adds each have a
fixed place.

### Step 10 — check yourself

```console
$ ./run.sh verify

1. the policies
  ✓ backendtrafficpolicy/pool accepted
  ✓ backendtrafficpolicy/slow accepted
  ✓ backendtrafficpolicy/api accepted
  ✓ securitypolicy/api accepted

2. retry and passive health check on /pool (two good pods, one sick)
  ✓ 90 requests, 90 succeed
  ✓ Envoy Gateway added previous_hosts to the retry
  ✓ the sick pod is ejected

3. circuit breaker on /slow (2 in flight, 2 waiting)
  10 at once: 2 answered, 8 refused
  ✓ 2 to 4 answered
  ✓ the other requests were refused with 503
  ✓ every refusal came back at once

4. JWT on /api
  ✓ no token -> 401
  ✓ forged token -> 401
  ✓ alice -> 200
  ✓ the app is told the verified subject

5. rate limit on /api (3 a minute)
  5 requests at once: 200 429 429 429 429 
  ✓ at least 2 of 5 refused with 429
  ✓ a 429 says the limit

6. CORS on /api
  ✓ shop.example.com may call it
  ✓ another origin is not allowed

all checks passed
```

## The options

**`BackendTrafficPolicy`** — used here, and what Envoy got

| Field | Here | Envoy got |
|---|---|---|
| `retry.numRetries` / `retryOn.httpStatusCodes` | `1`, `[503]` | `retry_policy` with `previous_hosts` and 5 host-selection attempts, added by Envoy Gateway |
| `healthCheck.passive` | 2 × 5xx, 1 s, 30 s, 50 % | the cluster's `outlier_detection` |
| `circuitBreaker.maxParallelRequests` / `maxPendingRequests` | `2`, `2` | `circuit_breakers.thresholds` |
| `rateLimit.local.rules[].limit` | 3 per minute | `local_ratelimit`: a bucket of 3, 3 tokens per 60 s, enabled and enforced |
| `loadBalancer.type` | — (not set) | `least_request` by default; also `RoundRobin`, `Random`, `ConsistentHash` |

**`SecurityPolicy`**

| Field | Here | Envoy got |
|---|---|---|
| `jwt.providers[].localJWKS` | module 06's HS256 key, inline | `jwt_authn`, `forward: true` |
| `jwt.providers[].claimToHeaders` | `sub` → `x-user` | `claim_to_headers` |
| `cors` | one origin, `GET`/`POST` | the `cors` filter, first in the chain |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| a policy has no effect | not accepted, or not arrived yet | read `status.ancestors` (step 3); a cluster change takes about 15 s (step 4) |
| a policy has no `status` at all | its `targetRefs` names nothing that exists — measured: no condition, no error | check the name, kind and namespace of the target; a policy targets resources in its own namespace |
| `Accepted=False`, reason `Conflicted`: *Unable to target HTTPRoute pool, another BackendTrafficPolicy has already attached to it* | a second `BackendTrafficPolicy` on the same route; the first one keeps working | put the settings in one policy, as step 4 does |
| a browser's preflight gets `401` and `www-authenticate: Bearer` | a `SecurityPolicy` with `jwt` but no `cors` — measured | add `cors` to the same `SecurityPolicy` (step 8) |
| `429` for everybody | a local rate limit is per Envoy, not per caller | add `clientSelectors`, or use Envoy Gateway's global rate limit |
| the app receives the bearer token | Envoy Gateway forwards it | expected (step 7) |

## Clean up

```console
$ oc adm policy remove-scc-from-user nonroot-v2 -n envoy-gateway-system -z "$(oc get deploy -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=envoy-14 -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}')"
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:nonroot-v2 removed: "envoy-envoy-14-eg-8619a82a"
$ oc delete -f manifests/10-gateway.yaml --wait=false
namespace "envoy-14" deleted
gateway.gateway.networking.k8s.io "eg" deleted from envoy-14 namespace
```

Module 12's `GatewayClass` stays — other modules use it; module 12's clean-up
removes it.

## The shortcut

`./run.sh deploy` does steps 1 to 8 (with step 4's policy in place of step 3's);
`./run.sh verify` is step 10; `./run.sh clean` is the clean-up.

## References

- [Envoy Gateway — `BackendTrafficPolicy`](https://gateway.envoyproxy.io/docs/concepts/gateway_api_extensions/backend-traffic-policy/)
- [Envoy Gateway — `SecurityPolicy`](https://gateway.envoyproxy.io/docs/concepts/gateway_api_extensions/security-policy/)
- [Envoy Gateway — retry](https://gateway.envoyproxy.io/docs/tasks/traffic/retry/)
- [Envoy Gateway — circuit breakers](https://gateway.envoyproxy.io/docs/tasks/traffic/circuit-breaker/)
- [Envoy Gateway — local rate limit](https://gateway.envoyproxy.io/docs/tasks/traffic/local-rate-limit/)
- [Envoy Gateway — JWT authentication](https://gateway.envoyproxy.io/docs/tasks/security/jwt-authentication/)
- [Envoy — `ConfigSource.initial_fetch_timeout`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/config_source.proto)
- [Envoy — cluster warming](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/cluster_manager#cluster-warming)

## Diagram sources

The figures are rendered from [`docs/diagrams/14-gateway-policies/source.html`](../docs/diagrams/14-gateway-policies/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
