# 04 — routing

Module 03 chose a **virtual host** by the `Host` header. This module is about
what happens next: inside one virtual host, a list of **routes** decides where a
request goes — to a cluster, back to the client as a redirect, or nowhere at all
because Envoy answers it itself.

The rule this module exists to teach:

> Routes are tried **in the order written**, and the **first match wins**.

That is the opposite of module 03, where Envoy picks the *most specific* filter
chain regardless of order. Here the order is the config.

## What you'll learn

- the ways a route can **match** a request — exact path, prefix, regex, header,
  query parameter — and the traps in each
- what a route can **do** — proxy, rewrite, time out, redirect, or answer by itself
- why the order of routes matters, by breaking it on purpose and measuring

## Before you start

- [`00-prerequisites`](../00-prerequisites/README.md) passes; modules
  [01](../01-what-is-envoy/README.md)–[03](../03-listeners-and-filter-chains/README.md)
  are worth doing first.
- Work from this folder: `cd 04-routing`.
- This module uses the namespace **`envoy-04`** and takes about 30 minutes.

## First match wins — and what a catch-all in the wrong place does

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/04-routing/first-match-wins.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/04-routing/first-match-wins.light.png">
  <img alt="Routes are tried in order and the first match wins: with the catch-all last, thirteen routes give thirteen outcomes; moved to the top, it answers every request and the twelve routes below it are never reached." src="../docs/diagrams/04-routing/first-match-wins.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Both columns are measured on the running proxy — the right one in step 11.
Envoy accepts the reordered config, and nothing it logs mentions the order.*

## Who answers a request

Traffic flows down: client, then Envoy, then — only for some routes — the
upstream.

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/04-routing/who-answers.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/04-routing/who-answers.light.png">
  <img alt="Traffic flows down from the client to Envoy and, for a route to a cluster, on to the upstream. A route to a cluster is answered by the upstream. A route whose timeout expires is answered by Envoy with a 504 after 0.25 seconds. A redirect and a direct_response are answered by Envoy alone, and the upstream request counters do not move." src="../docs/diagrams/04-routing/who-answers.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Who answers depends on the route's action, not its match. Steps 7–9 measure
each column.*

## Walkthrough

Every route in this config adds an `x-matched-route` response header naming
itself, so each step can show **which route Envoy chose** — not which one the
file intended.

### Step 1 — a namespace, a client, and two apps

The echo app from earlier modules, plus a **slow** app that waits one second
before answering, so a timeout has something to time out against.

```console
$ oc create namespace envoy-04
namespace/envoy-04 created
$ oc apply -n envoy-04 -f ../_shared/client.yaml
pod/client created
$ oc apply -n envoy-04 -f ../_shared/echo-app.yaml
configmap/echo-src created
service/echo created
deployment.apps/echo created
$ oc apply -n envoy-04 -f manifests/30-slow-app.yaml
configmap/slow-src created
service/slow created
deployment.apps/slow created
$ oc wait -n envoy-04 --for=condition=Ready pod/client --timeout=120s
pod/client condition met
$ oc rollout status -n envoy-04 deploy/echo --timeout=180s
Waiting for deployment "echo" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "echo" rollout to finish: 1 of 2 updated replicas are available...
deployment "echo" successfully rolled out
$ oc rollout status -n envoy-04 deploy/slow --timeout=180s
deployment "slow" successfully rolled out
```

### Step 2 — read the route list

Each route in `manifests/10-envoy-config.yaml` starts with a numbered comment:

```console
$ grep -nE '^ +# [0-9]+[bc]?\. ' manifests/10-envoy-config.yaml
41:                  # 1. EXACT path. Placed first deliberately: any `prefix: "/"`
48:                  # 2. REGEX (RE2). The pattern must match the WHOLE :path, so
57:                  # 3. HEADER match. The prefix is "/" so the header is the only
70:                  # 4. QUERY PARAMETER match. Same shape as the header matcher.
80:                  # 5. PREFIX REWRITE. The upstream is sent the path with the
91:                  # 6. REGEX REWRITE with a capture group. Single-quoted so the
104:                  # 7. HOST REWRITE. Changes the Host header sent upstream. The
115:                  # 8. TIMEOUT shorter than the upstream's 1s delay -> 504.
127:                  # 8b. The same slow upstream with room to finish, for contrast.
139:                  # 8c. A timeout against the FAST upstream, so the budget
151:                  # 9. REDIRECT. No cluster is named — Envoy answers this itself
158:                  # 10. DIRECT RESPONSE. Also answered by Envoy alone. Useful for
166:                  # 11. CATCH-ALL, and it must be LAST. First match wins, so
```

**What just happened:** thirteen routes, in the order Envoy tries them. 8b and 8c
are variations on 8. The last one, `prefix: "/"`, matches everything — which is
why it has to be last.

### Step 3 — start Envoy

```console
$ oc apply -n envoy-04 -f manifests/10-envoy-config.yaml
configmap/envoy-config created
$ oc apply -n envoy-04 -f manifests/20-envoy.yaml
service/envoy created
deployment.apps/envoy created
$ oc rollout status -n envoy-04 deploy/envoy --timeout=180s
Waiting for deployment "envoy" rollout to finish: 0 of 1 updated replicas are available...
deployment "envoy" successfully rolled out
```

### Step 4 — five ways to match

```console
$ oc exec -n envoy-04 client -- curl -s -i http://envoy:8080/exact | grep x-matched-route
x-matched-route: exact-path
$ oc exec -n envoy-04 client -- curl -s -i http://envoy:8080/order/42 | grep x-matched-route
x-matched-route: regex
$ oc exec -n envoy-04 client -- curl -s -i http://envoy:8080/order/abc | grep x-matched-route
x-matched-route: catch-all
$ oc exec -n envoy-04 client -- curl -s -i -H 'x-canary: yes' http://envoy:8080/ | grep x-matched-route
x-matched-route: header-canary
$ oc exec -n envoy-04 client -- curl -s -i 'http://envoy:8080/anything?debug=1' | grep x-matched-route
x-matched-route: query-debug
$ oc exec -n envoy-04 client -- curl -s -i http://envoy:8080/nothing-special | grep x-matched-route
x-matched-route: catch-all
```

**What just happened:** an exact `path`, a `safe_regex` (`/order/[0-9]+` — so
`/order/abc` falls through to the catch-all), a **header** match, a **query
parameter** match, and finally a request no specific route claims, which lands on
the catch-all.

### Step 5 — first match wins

The same canary header, sent with two different paths:

```console
$ oc exec -n envoy-04 client -- curl -s -i -H 'x-canary: yes' http://envoy:8080/exact | grep x-matched-route
x-matched-route: exact-path
$ oc exec -n envoy-04 client -- curl -s -i -H 'x-canary: yes' http://envoy:8080/api/v1/x | grep x-matched-route
x-matched-route: header-canary
```

**What just happened:** each request could match two routes, and the earlier one
won each time:

| Request | Could match | Wins | Why |
|---|---|---|---|
| `/exact` + `x-canary: yes` | route 1 (path), route 3 (header) | `exact-path` | route 1 is earlier |
| `/api/v1/x` + `x-canary: yes` | route 3 (header), route 5 (prefix) | `header-canary` | route 3 is earlier |

Same header, opposite outcome — the only difference is where the other route sits
in the list.

### Step 6 — rewrites, seen from the app

The echo app reports the path and headers **it received**, so a rewrite is
visible instead of taken on trust:

```console
$ oc exec -n envoy-04 client -- curl -s http://envoy:8080/api/v1/thing | grep -E '"path"|original-path'
  "path": "/thing",
    "x-envoy-original-path": "/api/v1/thing"
$ oc exec -n envoy-04 client -- curl -s http://envoy:8080/user/42/profile | grep -E '"path"|original-path'
  "path": "/profile/42",
    "x-envoy-original-path": "/user/42/profile"
$ oc exec -n envoy-04 client -- curl -s http://envoy:8080/rewrite-host | grep -E '"host"|original-host'
    "host": "upstream.internal",
    "x-envoy-original-host": "envoy:8080"
```

**What just happened:**

- `prefix_rewrite: "/"` replaced the matched `/api/v1/` — the app received `/thing`.
- `regex_rewrite` moved the captured number — `/user/42/profile` became `/profile/42`.
- `host_rewrite_literal` replaced the `Host` header the app received.

Envoy keeps the original in `x-envoy-original-path` / `x-envoy-original-host`, so
the app can still see what the client asked for.

### Step 7 — timeouts

`slow` sleeps one second. `/slow` gives it 250 ms; `/patient` gives it 5 s:

```console
$ for i in 1 2 3; do
>   oc exec -n envoy-04 client -- curl -s -o /dev/null -w 'slow    %{http_code} %{time_total}s\n' http://envoy:8080/slow
>   oc exec -n envoy-04 client -- curl -s -o /dev/null -w 'patient %{http_code} %{time_total}s\n' http://envoy:8080/patient
> done
slow    504 0.243633s
patient 200 1.001813s
slow    504 0.251724s
patient 200 1.002106s
slow    504 0.257319s
patient 200 1.001805s
```

The 504 comes from Envoy, not the app:

```console
$ oc exec -n envoy-04 client -- curl -s -i http://envoy:8080/slow
HTTP/1.1 504 Gateway Timeout
x-matched-route: timeout-250ms
content-length: 24
content-type: text/plain
date: Sat, 26 Sep 2026 03:31:33 GMT
server: envoy

upstream request timeout
```

And Envoy **tells the upstream its deadline**, in a request header the echo app
reports back. `/budget` sets `timeout: 1.234s`; `/exact` sets none:

```console
$ oc exec -n envoy-04 client -- curl -s http://envoy:8080/budget | grep expected-rq
    "x-envoy-expected-rq-timeout-ms": "1234"
$ oc exec -n envoy-04 client -- curl -s http://envoy:8080/exact | grep expected-rq
    "x-envoy-expected-rq-timeout-ms": "15000"
```

**What just happened:** 504 in about a quarter of a second, 200 in about one. The
504's body is Envoy's own, and it has no `x-envoy-upstream-service-time` header —
the header a proxied response carries — because no upstream answered in time.
`/exact` is told `15000`: the default 15 s route timeout, in force although the
config never mentions it.

The slow app is a *threaded* server on purpose. With a single thread, a request
Envoy has already given up on still occupies the app for its full second, and the
next one queues behind it — an earlier version measured `/patient` at 2.5 s that
way. That was the test app, not Envoy.

### Step 8 — routes Envoy answers by itself

A redirect, and a health check written as a `direct_response`:

```console
$ oc exec -n envoy-04 client -- curl -s -i http://envoy:8080/old | grep -iE '^HTTP|^location'
HTTP/1.1 301 Moved Permanently
location: http://envoy:8080/exact
$ oc exec -n envoy-04 client -- curl -s -i -H 'Host: shop.example' http://envoy:8080/old | grep -iE '^HTTP|^location'
HTTP/1.1 301 Moved Permanently
location: http://shop.example/exact
$ oc exec -n envoy-04 client -- curl -s http://envoy:8080/healthz
ok
```

`path_redirect: "/exact"` replaces only the **path**. The `Location` Envoy sends
is a full URI rebuilt from the request's `Host` — change the `Host` and the
redirect points somewhere else.

Neither route names a cluster. To prove no upstream is contacted, read the
upstream request counters, send twenty requests to those two routes, read them
again — then send ten to `/exact` for contrast:

```console
$ oc exec -n envoy-04 client -- curl -s 'http://envoy:9901/stats?filter=upstream_rq_total$'
cluster.echo_service.upstream_rq_total: 13
cluster.slow_service.upstream_rq_total: 7
$ for i in 1 2 3 4 5 6 7 8 9 10; do oc exec -n envoy-04 client -- curl -s -o /dev/null http://envoy:8080/old; oc exec -n envoy-04 client -- curl -s -o /dev/null http://envoy:8080/healthz; done
$ oc exec -n envoy-04 client -- curl -s 'http://envoy:9901/stats?filter=upstream_rq_total$'
cluster.echo_service.upstream_rq_total: 13
cluster.slow_service.upstream_rq_total: 7
$ for i in 1 2 3 4 5 6 7 8 9 10; do oc exec -n envoy-04 client -- curl -s -o /dev/null http://envoy:8080/exact; done
$ oc exec -n envoy-04 client -- curl -s 'http://envoy:9901/stats?filter=upstream_rq_total$'
cluster.echo_service.upstream_rq_total: 23
cluster.slow_service.upstream_rq_total: 7
```

**What just happened:** the twenty requests to `/old` and `/healthz` left both
counters where they were; the ten to `/exact` added ten to `echo_service`.

### Step 9 — with every upstream down

Scale both apps to zero and ask again:

```console
$ oc scale -n envoy-04 deploy/echo deploy/slow --replicas=0
deployment.apps/echo scaled
deployment.apps/slow scaled
$ oc wait -n envoy-04 --for=delete pod -l 'app in (echo,slow)' --timeout=120s; sleep 10
pod/echo-f8fc6d5c9-cxnnq condition met
pod/echo-f8fc6d5c9-lbr8h condition met
pod/slow-68bfc7675b-5q5kg condition met
$ oc exec -n envoy-04 client -- curl -s -o /dev/null -w '%{http_code}\n' http://envoy:8080/healthz
200
$ oc exec -n envoy-04 client -- curl -s -o /dev/null -w '%{http_code}\n' http://envoy:8080/old
301
$ oc exec -n envoy-04 client -- curl -s -w ' %{http_code}\n' http://envoy:8080/exact
no healthy upstream 503
```

**What just happened:** the health check still says 200 and the redirect still
redirects; only the route to a cluster fails — Envoy's own `503`, with the body
`no healthy upstream`.
A health check written as a `direct_response` reports on Envoy itself. One written
as a route to a cluster reports on the cluster — a different question, and
sometimes the one you want.

Bring the apps back. Envoy re-resolves DNS every 5 s, so give it ten, then check
it sees all three pods again:

```console
$ oc scale -n envoy-04 deploy/echo --replicas=2
deployment.apps/echo scaled
$ oc scale -n envoy-04 deploy/slow --replicas=1
deployment.apps/slow scaled
$ oc rollout status -n envoy-04 deploy/echo --timeout=180s; oc rollout status -n envoy-04 deploy/slow --timeout=180s; sleep 10
Waiting for deployment "echo" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "echo" rollout to finish: 1 of 2 updated replicas are available...
deployment "echo" successfully rolled out
deployment "slow" successfully rolled out
$ oc exec -n envoy-04 client -- curl -s http://envoy:9901/clusters | grep -c 'health_flags::healthy'
3
```

### Step 10 — the traps in each matcher

```console
$ for p in /slowpoke /patients /patient/x /api/v1 /EXACT /exact/ '/exact?x=1'; do printf '%-12s ' "$p"; oc exec -n envoy-04 client -- curl -s -i "http://envoy:8080$p" | grep x-matched-route; done
/slowpoke    x-matched-route: timeout-250ms
/patients    x-matched-route: catch-all
/patient/x   x-matched-route: timeout-5s
/api/v1      x-matched-route: catch-all
/EXACT       x-matched-route: catch-all
/exact/      x-matched-route: catch-all
/exact?x=1   x-matched-route: exact-path
```

**What just happened**, line by line:

| Request | Matched | Why |
|---|---|---|
| `/slowpoke` | `timeout-250ms` | `prefix: /slow` compares **strings**, not path segments |
| `/patients` | `catch-all` | `path_separated_prefix: /patient` only matches at a `/` boundary |
| `/patient/x` | `timeout-5s` | …which `/patient/x` is |
| `/api/v1` | `catch-all` | `prefix: /api/v1/` has a trailing slash that `/api/v1` lacks |
| `/EXACT` | `catch-all` | path matching is case-sensitive |
| `/exact/` | `catch-all` | `path` is exact — a trailing slash makes another path |
| `/exact?x=1` | `exact-path` | `path` ignores the query string |

Two more, for headers and query parameters:

```console
$ oc exec -n envoy-04 client -- curl -s -i -H 'X-Canary: yes' http://envoy:8080/ | grep x-matched-route
x-matched-route: header-canary
$ oc exec -n envoy-04 client -- curl -s -i -H 'x-canary: YES' http://envoy:8080/ | grep x-matched-route
x-matched-route: catch-all
$ oc exec -n envoy-04 client -- curl -s -i 'http://envoy:8080/anything?DEBUG=1' | grep x-matched-route
x-matched-route: catch-all
```

A header's **name** is case-insensitive, but its **value** is compared exactly
(`YES` is not `yes`); a query parameter's **name** is case-sensitive.

### Step 11 — break the order on purpose

`./run.sh shadow` takes the committed config, cuts the catch-all out, pastes it
**first**, restarts Envoy, and asks every route again. Then it restores the
original:

```console
$ ./run.sh shadow

moving the catch-all to the top of the route list
  ✓ upstream echo_service has endpoints
  ✓ upstream slow_service has endpoints

every route above it is now dead
  ✓ /exact
  ✓ /order/42
  ✓ / with x-canary: yes
  ✓ /anything?debug=1
  ✓ /api/v1/thing
  ✓ /user/42/profile
  ✓ /rewrite-host
  ✓ /slow (no longer 504s)
  ✓ /patient
  ✓ /budget
  ✓ /old (no longer 301s)
  ✓ /healthz (now proxied)

restoring the committed route order
  ✓ upstream echo_service has endpoints
  ✓ upstream slow_service has endpoints
  ✓ after restoring, /exact matches its own route again

all checks passed
```

**What just happened:** every one of those requests got `x-matched-route:
catch-all`. The timeout stopped firing, the redirect stopped redirecting, and the
health check started depending on the upstream it was meant to outlive. Envoy
accepted the config without a single warning about it — in a route list, the
order *is* the config.

### Step 12 — check yourself

```console
$ ./run.sh verify

1. match types, in the order Envoy tries them
  ✓ exact path /exact
  ✓ regex /order/42
  ✓ regex does NOT match /order/abc
  ✓ header x-canary: yes
  ✓ query ?debug=1
  ✓ no discriminator falls to catch-all

2. first match wins — the same request, two orders
  ✓ /exact + canary header -> the earlier route
  ✓ /api/v1/x + canary header -> the earlier route

3. rewrites, seen from the upstream's side
  ✓ prefix_rewrite strips /api/v1
  ✓ regex_rewrite moves the capture
  ✓ host_rewrite_literal changes Host upstream

4. timeouts
  ✓ 250ms timeout against a 1s upstream -> 504
  ✓ 504 says what happened
  ✓ 5s timeout against the same upstream -> 200
  ✓ timeout is forwarded as a budget header

5. routes Envoy answers without any upstream
  ✓ /old redirects 301
  ✓ /old points at the new path
  ✓ Location is an absolute URI, not a bare path
  ✓ direct_response body
  ✓ upstream counters are readable (non-zero)
  ✓ 6 requests to /healthz and /old reach no upstream

6. matcher edge cases
  ✓ prefix is not segment-aware: /slowpoke matches prefix /slow
  ✓ path_separated_prefix is: /patients misses /patient
  ✓ path_separated_prefix still matches /patient/x
  ✓ prefix /api/v1/ does not match /api/v1
  ✓ path is case-sensitive: /EXACT
  ✓ path is exact: /exact/ is another path
  ✓ path ignores the query string
  ✓ header NAME is case-insensitive
  ✓ header VALUE is exact: YES != yes
  ✓ query parameter NAME is case-sensitive

7. the running proxy really holds these routes
  ✓ route_config 'routing' is loaded
  ✓ prefix_rewrite is in the running config
  ✓ 13 routes are loaded
  ✓ the last route is the catch-all

all checks passed
```

## The options

A route is `match` (which requests) plus exactly one action (what to do with them).

**`match` — pick exactly one path matcher, then optionally narrow it:**

| Field | What it matches | Measured here |
|---|---|---|
| `path` | the whole path, exactly — query string excluded | `/exact?x=1` matches `path: /exact`; `/exact/` and `/EXACT` do not |
| `prefix` | the path starts with this **string** — not segment-aware | `prefix: /slow` also matches `/slowpoke` |
| `path_separated_prefix` | the prefix, but only at a `/` boundary | `/patient` and `/patient/x` match; `/patients` does not |
| `safe_regex` | an RE2 pattern against the **whole** path | `/order/[0-9]+` matches `/order/42`, not `/order/abc` |
| `headers` | a request header, with a `string_match` | the **name** is case-insensitive, the **value** exact |
| `query_parameters` | a query parameter, with a `string_match` | the **name** is case-sensitive |

Path matching is case-sensitive by default; the API reference documents
`case_sensitive: false` on the match to change that.

**Actions — exactly one per route:**

| Field | What Envoy does | When you want it |
|---|---|---|
| `route.cluster` | proxies to that cluster | almost always |
| `route.prefix_rewrite` | replaces the matched prefix before proxying | the app is mounted at `/`, the public URL is `/api/v1/` |
| `route.regex_rewrite` | rewrites the path with a capture group | restructuring a path, not just trimming it |
| `route.host_rewrite_literal` | replaces `Host` sent upstream | an upstream that routes on its own hostname |
| `route.timeout` | the upstream deadline, from sending the request to the full response — **default 15 s** | anything that must fail fast, or legitimately runs long |
| `redirect` | answers `3xx` itself; no cluster is contacted | moved URLs, http → https |
| `direct_response` | answers with a fixed status and body; no cluster | health checks, explicit 404s, maintenance pages |

`response_headers_to_add` is on every route here only so each step can see which
one fired. It is a real option — adding headers to responses — not a routing one.

One YAML detail in the regex rewrite: the substitution is single-quoted,
`'/profile/\1'`. In double quotes `\1` is an invalid YAML escape, and Envoy
refuses the whole file (measured on Envoy 1.39.1: *yaml-cpp: … unknown escape
character: 1*).

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| every request says `catch-all` | the catch-all is above the other routes | it must be the last route — step 11 shows the effect |
| a regex route never matches | RE2 must match the **whole** path, not part of it | write the pattern for the full path |
| `no healthy upstream` after step 9 | Envoy has not re-resolved the apps' DNS yet | wait 5–10 s; `/clusters` shows when they are back |
| a redirect points at the wrong host | `Location` is built from the request's `Host` | send the `Host` you want clients redirected to |

## Clean up

```console
$ oc delete namespace envoy-04 --wait=false
namespace "envoy-04" deleted
```

## The shortcut

`./run.sh deploy` does steps 1 and 3, `./run.sh shadow` is step 11,
`./run.sh verify` is step 12, and `./run.sh clean` removes the namespace.

## What this module skipped

Retries and `per_try_timeout` (module 02 shows they change the deadline the app
is told; module 11, still to come, goes further), weighted clusters and traffic
splitting, and routes delivered at runtime over RDS instead of written in the
file.

## References

- [Route matching — `RouteMatch`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto#config-route-v3-routematch)
- [Route actions — `RouteAction`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto#config-route-v3-routeaction)
- [`RedirectAction`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto#config-route-v3-redirectaction)
- [`DirectResponseAction`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto#config-route-v3-directresponseaction)
- [HTTP routing overview](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/http_routing)
- [Router filter headers, including `x-envoy-expected-rq-timeout-ms`](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter)
- [RE2 syntax](https://github.com/google/re2/wiki/Syntax)

## Diagram sources

The figures are rendered from [`docs/diagrams/04-routing/source.html`](../docs/diagrams/04-routing/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
