# 11 — resilience: retries, outlier detection, circuit breaking

Sooner or later a pod behind Envoy misbehaves: it fails requests, or it slows
down under load. Envoy has three defences, each for a different failure:

| Defence | For | What Envoy does |
|---|---|---|
| **retry** | one request that failed | send it again — ideally to a different pod |
| **outlier detection** | a pod that keeps failing | stop sending it traffic for a while |
| **circuit breaker** | a backend that cannot keep up | refuse the excess at once, instead of queueing it |

## What you'll learn

- how a **retry** turns a failure into a success — and why it needs
  `previous_hosts` not to retry on the same bad pod, and why even that is not a
  guarantee
- how **outlier detection** ejects a failing pod using the real traffic, with no
  health check
- how a **circuit breaker** caps the requests in flight to a backend, and how to
  read its refusals in the access log and the counters

## Before you start

- [`00-prerequisites`](../00-prerequisites/README.md) passes.
- Module [`02`](../02-core-concepts/README.md) explains which requests are safe to
  retry; this module retries only reads.
- Work from this folder: `cd 11-resilience`.
- This module uses the namespace **`envoy-11`** and takes about 20 minutes.

## The pool, and three defences

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/11-resilience/retry-paths.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/11-resilience/retry-paths.light.png">
  <img alt="A request enters Envoy and is sent to one of three pods, picked at random: two healthy echo pods and a sick pod that answers every request with 503. With no defence, one request in three fails. With a retry, a 503 from the sick pod is sent again - to a random pod, which is the sick pod again one time in three. With previous_hosts, the retry rejects the sick pod and picks again, up to three more times; only if all four picks are the sick pod does the retry still go there, one retry in 81. Measured: 23 of 90, 12 of 90 and 0 of 180 failed." src="../docs/diagrams/11-resilience/retry-paths.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

## Walkthrough

### Step 1 — the backends

Two healthy echo pods; the **sick** app from module 05, which is Ready but answers
every request with `503`; and the **slow** app from module 04, which takes one
second per request:

```console
$ oc create namespace envoy-11
namespace/envoy-11 created
$ oc apply -n envoy-11 -f ../_shared/client.yaml -f ../_shared/echo-app.yaml
pod/client created
configmap/echo-src created
service/echo created
deployment.apps/echo created
$ oc apply -n envoy-11 -f manifests/30-sick-app.yaml -f manifests/40-slow-app.yaml
configmap/sick-src created
service/sick created
deployment.apps/sick created
configmap/slow-src created
service/slow created
deployment.apps/slow created
$ oc wait -n envoy-11 --for=condition=Ready pod/client --timeout=120s
pod/client condition met
$ for d in echo sick slow; do oc rollout status -n envoy-11 deploy/$d --timeout=240s; done
Waiting for deployment "echo" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "echo" rollout to finish: 1 of 2 updated replicas are available...
deployment "echo" successfully rolled out
deployment "sick" successfully rolled out
deployment "slow" successfully rolled out
```

### Step 2 — start Envoy

```console
$ oc apply -n envoy-11 -f manifests/10-envoy-config.yaml -f manifests/20-envoy.yaml
configmap/envoy-config created
service/envoy created
deployment.apps/envoy created
$ oc rollout status -n envoy-11 deploy/envoy --timeout=240s
Waiting for deployment "envoy" rollout to finish: 0 of 1 updated replicas are available...
deployment "envoy" successfully rolled out
```

**What just happened:** Envoy has one route per defence — read the comment at the
top of [`manifests/10-envoy-config.yaml`](manifests/10-envoy-config.yaml).
Behind every route but `/slow` is the same **pool** of three pods: `echo` (two
pods) and `sick` (one), and the load balancer picks one **at random** for each
request (`lb_policy: RANDOM`). Random, not round robin, on purpose: round robin
would move a retry to the next pod on its own and hide what the retry settings do.

### Step 3 — no defence

Ninety requests to `/none`, which has no retry, then count the status codes:

```console
$ oc exec -n envoy-11 client -- sh -c 'for i in $(seq 1 90); do curl -s -o /dev/null -w "%{http_code}\n" http://envoy:8080/none; done' | sort | uniq -c
  67 200
  23 503
```

**What just happened:** every request that the load balancer sent to the sick pod
failed — about one in three, since it is one pod of three. Envoy passed the `503`
straight back to the client.

### Step 4 — retry once

`/retry` has a retry policy: on any `5xx`, send the request once more
(`retry_on: 5xx`, `num_retries: 1`):

```console
$ oc exec -n envoy-11 client -- sh -c 'for i in $(seq 1 90); do curl -s -o /dev/null -w "%{http_code}\n" http://envoy:8080/retry; done' | sort | uniq -c
  78 200
  12 503
```

Fewer failures — but not none. The access log records how many attempts
each request took (`%UPSTREAM_REQUEST_ATTEMPT_COUNT%`) and its response flags.
Wait for Envoy to write the log, then tally the `/retry` requests:

```console
$ sleep 10; oc logs -n envoy-11 deploy/envoy | grep -F '"path":"/retry"' | python3 -c 'import collections,json,sys; c = collections.Counter((j["attempts"], j["code"], j["flags"]) for j in map(json.loads, sys.stdin)); [print("attempts=%s code=%s flags=%-4s %3d requests" % (k + (n,))) for k, n in sorted(c.items())]'
attempts=1 code=200 flags=-     57 requests
attempts=2 code=200 flags=-     21 requests
attempts=2 code=503 flags=URX   12 requests
```

**What just happened:** three kinds of request:

| `attempts` | `code` | Meaning |
|---|---|---|
| 1 | 200 | the first pick was a healthy pod |
| 2 | 200 | the first pick was the sick pod; the retry went to a healthy one |
| 2 | 503, flag **`URX`** | the retry *also* went to the sick pod — `URX`: **u**pstream **r**etry limit e**x**ceeded |

The last row is the flaw: the retry is load-balanced like any request, so it
picks the sick pod one time in three, and a third of a third — about one request
in nine — still fails.

Envoy can also tell the *client* how many attempts a response took, in
`x-envoy-attempt-count`, because the virtual host sets
`include_attempt_count_in_response: true`:

```console
$ oc exec -n envoy-11 client -- sh -c 'for i in $(seq 1 30); do curl -s -o /dev/null -D - http://envoy:8080/retry | grep -i "^x-envoy-attempt-count"; done' | sort | uniq -c
  21 x-envoy-attempt-count: 1
   9 x-envoy-attempt-count: 2
```

### Step 5 — retry on a different pod

`/retry-elsewhere` adds a **retry host predicate**: `previous_hosts` rejects a pod
this request has already tried, and the load balancer picks again — up to
`host_selection_retry_max_attempts: 3` more times. Send 180 requests to each
retry route and count the failures:

```console
$ for p in /retry /retry-elsewhere; do printf '%-17s' "$p"; oc exec -n envoy-11 client -- sh -c "for i in \$(seq 1 180); do curl -s -o /dev/null -w '%{http_code}\n' http://envoy:8080$p; done" | sort | uniq -c | tr -s ' \n' ' '; echo; done
/retry            159 200 21 503 
/retry-elsewhere  180 200 
```

**What just happened:** `previous_hosts` cut the failures sharply — but it is not
a guarantee. When every pick is rejected, Envoy does not give up: it sends the
retry to the **last pod it picked**, rejected or not. From Envoy's source
(`load_balancer_impl.cc`, `chooseHost`):

```text
  const size_t max_attempts = context ? context->hostSelectionRetryCount() + 1 : 1;
  ...
  // If we didn't find anything, return the last host.
```

So a retry makes **four** random picks (the first, plus 3 more); all four land on
the sick pod with probability (1/3)⁴ — **one retry in 81**. Retries happen on
about a third of requests, so expect about one failure in 243 requests: over 180,
usually none, sometimes one. When it happens, the tally below gets a third row,
`attempts=2 code=503 flags=URX` — seen once in 361 requests while writing this
module, and that request's access-log line named the sick pod as its `upstream`:

```console
$ sleep 10; oc logs -n envoy-11 deploy/envoy | grep -F '"path":"/retry-elsewhere"' | python3 -c 'import collections,json,sys; c = collections.Counter((j["attempts"], j["code"], j["flags"]) for j in map(json.loads, sys.stdin)); [print("attempts=%s code=%s flags=%-4s %3d requests" % (k + (n,))) for k, n in sorted(c.items())]'
attempts=1 code=200 flags=-    115 requests
attempts=2 code=200 flags=-     65 requests
```

Raising `host_selection_retry_max_attempts` shrinks the odds further. The real
cure is not to keep picking the sick pod at all — the next step.

### Step 6 — outlier detection ejects the sick pod

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/11-resilience/ejection-and-breaker.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/11-resilience/ejection-and-breaker.light.png">
  <img alt="Left, outlier detection on /ejecting: in the first 30 requests the sick pod fails twice in a row and is ejected, measured 28 200s and 2 503s. It is ejected for 30 seconds with health flag failed_outlier_check while Kubernetes still reports it Ready; the next 30 requests all succeed. Thirty seconds later it is let back in, fails twice and is ejected again, for 60 seconds per the documentation. Right, the circuit breaker on /slow: 10 requests at once to an app that takes one second; with max_requests 2 and max_pending_requests 2, 2 are served after one second and 8 are refused at once with 503 flag UO; pending_overflow 6 plus active_overflow 2 equals 8." src="../docs/diagrams/11-resilience/ejection-and-breaker.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

The cluster behind `/ejecting` has **outlier detection**: two `5xx` in a row from
one pod (`consecutive_5xx: 2`) and Envoy **ejects** it — takes it out of the load
balancer — for 30 seconds (`base_ejection_time`). No health check is involved:
Envoy judges each pod by the answers it gives to real requests. Send 30 requests:

```console
$ oc exec -n envoy-11 client -- sh -c 'for i in $(seq 1 30); do curl -s -o /dev/null -w "%{http_code}\n" http://envoy:8080/ejecting; done' | sort | uniq -c
  28 200
   2 503
```

Exactly two failures — the two that condemned the sick pod. Envoy's counters and
its view of each pod confirm the ejection:

```console
$ oc exec -n envoy-11 client -- curl -s 'http://envoy:9901/stats?filter=^cluster\.pool_outlier\.outlier_detection\.(ejections_active|ejections_enforced_consecutive_5xx)$'
cluster.pool_outlier.outlier_detection.ejections_active: 1
cluster.pool_outlier.outlier_detection.ejections_enforced_consecutive_5xx: 1
$ oc get pod -n envoy-11 -l app=sick -o jsonpath='{.items[0].status.podIP}{"\n"}'
10.217.0.111
$ oc exec -n envoy-11 client -- curl -s http://envoy:9901/clusters | grep '^pool_outlier::.*::health_flags::'
pool_outlier::10.217.0.109:8080::health_flags::healthy
pool_outlier::10.217.0.110:8080::health_flags::healthy
pool_outlier::10.217.0.111:8080::health_flags::/failed_outlier_check
```

**What just happened:** `ejections_active: 1` — one pod is out. In `/clusters`,
the sick pod's IP (compare with `oc get pod`) carries **`/failed_outlier_check`**;
the two echo pods are `healthy`. The pod is still Ready as far as Kubernetes is
concerned — only this Envoy has stopped using it. Now every request goes to a
healthy pod:

```console
$ oc exec -n envoy-11 client -- sh -c 'for i in $(seq 1 30); do curl -s -o /dev/null -w "%{http_code}\n" http://envoy:8080/ejecting; done' | sort | uniq -c
  30 200
```

An ejection is not forever. After 30 seconds the pod is let back in — and,
still sick, fails twice more and is ejected again. Envoy's documentation says
each ejection lasts `base_ejection_time` × the number of times the pod has been
ejected (up to `max_ejection_time`, 300 s by default), so this second one lasts
60 seconds.

```console
$ sleep 35; oc exec -n envoy-11 client -- sh -c 'for i in $(seq 1 30); do curl -s -o /dev/null -w "%{http_code}\n" http://envoy:8080/ejecting; done' | sort | uniq -c
  28 200
   2 503
$ oc exec -n envoy-11 client -- curl -s 'http://envoy:9901/stats?filter=^cluster\.pool_outlier\.outlier_detection\.(ejections_active|ejections_enforced_consecutive_5xx)$'
cluster.pool_outlier.outlier_detection.ejections_active: 1
cluster.pool_outlier.outlier_detection.ejections_enforced_consecutive_5xx: 2
```

`max_ejection_percent: 50` is the safety catch: Envoy never ejects more than half
the pool, so a fault that makes *every* pod fail cannot leave the cluster empty.
Mind the default, `10`: Envoy ejects only if the pods out *after* the ejection
are at most that share of the pool — one pod of three is 33 %, so with the default
this pool would never eject anything.

### Step 7 — the circuit breaker refuses the excess

`/slow` goes to the slow app, which takes one second per request. Its cluster has
a **circuit breaker**: at most `max_requests: 2` in flight, and at most
`max_pending_requests: 2` waiting for a connection. Send ten requests at once,
timing each:

```console
$ oc exec -n envoy-11 client -- sh -c "seq 1 10 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code} after %{time_total}s\n' http://envoy:8080/slow" | sort
200 after 1.002761s
200 after 1.002874s
503 after 0.000645s
503 after 0.000754s
503 after 0.000820s
503 after 0.000870s
503 after 0.000950s
503 after 0.001217s
503 after 0.001272s
503 after 0.002082s
```

**What just happened:** two requests were served, each after the app's one
second. The other eight were refused **at once** — no waiting behind the slow
app, no timeout. That is the point of a circuit breaker: a backend that cannot
keep up gets the load it can handle, and the excess fails fast, so callers are
not tied up and the backend is not buried.

Why not four, when `max_pending_requests: 2` lets two more wait? A pending
request waits for a **connection**, not for an in-flight request to finish.
Envoy opens a new connection for it within milliseconds; when the request is
put on it, two are still in flight, so it is refused after all. In 22 bursts
measured while writing this module, 21 served exactly two and one served three;
the check in step 8 accepts two to four. The access log gives the refusals their
own flag:

```console
$ sleep 10; oc logs -n envoy-11 deploy/envoy | grep -F '"path":"/slow"' | python3 -c 'import collections,json,sys; c = collections.Counter((j["code"], j["flags"]) for j in map(json.loads, sys.stdin)); [print("code=%s flags=%-3s %2d requests" % (k + (n,))) for k, n in sorted(c.items())]'
code=200 flags=-    2 requests
code=503 flags=UO   8 requests
$ oc exec -n envoy-11 client -- curl -s 'http://envoy:9901/stats?filter=^cluster\.slow_limited\.upstream_rq_(total|pending_overflow|active_overflow)$'
cluster.slow_limited.upstream_rq_active_overflow: 2
cluster.slow_limited.upstream_rq_pending_overflow: 6
cluster.slow_limited.upstream_rq_total: 2
```

**What just happened:** **`UO`** — **u**pstream **o**verflow — marks every
refusal. The counters split the same eight between two reasons:

| Counter | The request was refused because |
|---|---|
| `upstream_rq_pending_overflow` | it had no connection yet, and 2 requests were already waiting for one |
| `upstream_rq_active_overflow` | it had a connection — often one Envoy had just opened for it — but 2 requests were already in flight |

The split changes from run to run — it depends on how the ten requests race
through Envoy's worker threads — but the two always add up to the number of
`UO`s — Envoy's source (`conn_pool_base.cc`) counts each refusal in exactly
one. When you alert on circuit breaking, alert on both.

### Step 8 — check yourself

`verify` restarts Envoy first, so every experiment starts with no ejections and
empty counters:

```console
$ ./run.sh verify
  ✓ upstream pool has endpoints

1. no defence: the sick pod's share of requests fails
  ✓ some requests fail

2. retries
  503s in 180 requests: /retry 7, /retry-elsewhere 1
  ✓ retrying on another host fails less often than a plain retry
  ✓ the retry shows in x-envoy-attempt-count
  ✓ retries were counted

3. outlier detection ejects the sick pod
  ✓ one host ejected
  ✓ after the ejection, 30 of 30 succeed

4. the circuit breaker refuses the overflow
  10 at once: 2 answered, 8 refused, the slowest refusal in 0.099216s
  ✓ 2 to 4 answered (max_requests 2 + max_pending_requests 2)
  ✓ the other requests were refused with 503
  ✓ every refusal came back at once, not after the app's 1 s
  ✓ Envoy counted every refusal as an overflow

all checks passed
```

## The options

**Retries** — [`RetryPolicy`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto#config-route-v3-retrypolicy), on the route

| Field | Here | What it does |
|---|---|---|
| `retry_on` | `5xx` | which failures to retry — also `gateway-error`, `reset`, `connect-failure`, `retriable-status-codes`, … |
| `num_retries` | `1` | retries after the first attempt (default 1) |
| `retry_host_predicate` | `previous_hosts` | reject pods this request already tried |
| `host_selection_retry_max_attempts` | `3` | extra picks when a pod is rejected; after that, the last pick is used anyway |
| `include_attempt_count_in_response` | `true` (virtual host) | adds `x-envoy-attempt-count` to the response |

**Outlier detection** — [`OutlierDetection`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/outlier_detection.proto), on the cluster

| Field | Here | Default | What it does |
|---|---|---|---|
| `consecutive_5xx` | `2` | `5` | `5xx` in a row that eject a pod |
| `interval` | `1s` | `10s` | how often ejections are reviewed and expired ones let back in |
| `base_ejection_time` | `30s` | `30s` | ejection length, multiplied by the number of times the pod has been ejected |
| `max_ejection_percent` | `50` | `10` | the most of the pool that can be ejected at once — with the default, a pool of fewer than 10 pods ejects nothing |

**Circuit breakers** — [`CircuitBreakers`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/circuit_breaker.proto), on the cluster

| Field | Here | Default | What it does |
|---|---|---|---|
| `max_requests` | `2` | `1024` | requests in flight to the whole cluster |
| `max_pending_requests` | `2` | `1024` | requests waiting for a connection |
| `max_connections` | — | `1024` | connections to the cluster — but each worker thread keeps at least one, so it is a soft limit |
| `max_retries` | — | `3` | retries in flight to the whole cluster, across all requests |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| a retry still fails with `URX` | the retry landed on a bad pod too | add `previous_hosts`; add outlier detection so the bad pod is ejected |
| retries stop happening under load (`upstream_rq_retry_overflow` rising) | `max_retries` (default 3) caps retries in flight across the cluster | raise it — or ask why so many requests are failing |
| outlier detection never ejects | fewer than `consecutive_5xx` failures in a row from one pod, or one more ejection would pass `max_ejection_percent` — with the 10 % default, any pool under 10 pods | raise `max_ejection_percent`, or set `always_eject_one_host: true` |
| `503 UO` under normal load | a circuit breaker limit is too low for the traffic | compare `upstream_rq_active` with `max_requests`; raise the limit |
| `upstream_cx_total` above `max_connections` | each worker thread's pool may open one connection even at the limit | expected; limit requests, not connections |

## Clean up

```console
$ oc delete namespace envoy-11 --wait=false
namespace "envoy-11" deleted
```

## The shortcut

`./run.sh deploy` does steps 1 and 2; `./run.sh verify` is step 8;
`./run.sh clean` removes the namespace.

## References

- [Envoy — automatic retries](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/http_connection_management#arch-overview-http-routing-retry)
- [Envoy — retry plugin configuration](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/http/http_connection_management#retry-plugin-configuration)
- [Envoy — outlier detection](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier)
- [Envoy — circuit breaking](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking)
- [Envoy — response flags](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#config-access-log-format-response-flags)
- [Envoy source — `ZoneAwareLoadBalancerBase::chooseHost`](https://github.com/envoyproxy/envoy/blob/release/v1.39/source/extensions/load_balancing_policies/common/load_balancer_impl.cc)

## Diagram sources

The figures are rendered from [`docs/diagrams/11-resilience/source.html`](../docs/diagrams/11-resilience/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
