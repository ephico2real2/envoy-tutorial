# 02 — the config file, field by field

Module 01 used the smallest config that works. This one sets the fields you end
up setting on almost every real Envoy, and says what each does, what it defaults
to, and when to change it.

The recurring theme: **Envoy's defaults are permissive.** Most of what follows is
not adding behaviour — it is declining a default you would not have chosen.

## What you'll learn

- the shape of an Envoy config file, top to bottom
- what the important fields **default to** when you leave them out — and which of
  those defaults bite
- how to prove a field is in effect by asking the **running** proxy, not by
  re-reading the file

## Before you start

- [`00-prerequisites`](../00-prerequisites/README.md) passes, and
  [`01-what-is-envoy`](../01-what-is-envoy/README.md) is worth doing first.
- Work from this folder: `cd 02-the-config-file`.
- This module uses the namespace **`envoy-02`** and takes about 20 minutes.

## The config file, top to bottom

<!-- markdownlint-disable MD033 -->
<img alt="The shape of envoy.yaml: node and admin, then static_resources holding the listener, whose http_connection_manager has use_remote_address default false, server_name default envoy, generate_request_id default true, request_timeout default none, idle_timeout default one hour, and a route with timeout default 15 seconds and no retries; and the cluster, with lb_policy default ROUND_ROBIN, connect_timeout 5 seconds, dns_refresh_rate 5 seconds, and circuit breakers of 1024 connections, pending requests and requests and 3 retries." src="../docs/diagrams/02-the-config-file/config-anatomy.light.png">
<!-- markdownlint-enable MD033 -->

Every value in that picture is what you get **if you leave the line out**.
"measured" means it was read from a running Envoy on CRC; "API" means it is
taken from the Envoy API reference (linked at the bottom).

## Walkthrough

### Step 1 — a namespace, a client, and the app

The same start as module 01: a namespace, the in-cluster `client` pod to run
curl from, and the echo app.

```console
$ oc create namespace envoy-02
namespace/envoy-02 created
$ oc apply -n envoy-02 -f ../_shared/client.yaml
pod/client created
$ oc apply -n envoy-02 -f ../_shared/echo-app.yaml
configmap/echo-src created
service/echo created
deployment.apps/echo created
$ oc wait -n envoy-02 --for=condition=Ready pod/client --timeout=120s
pod/client condition met
$ oc rollout status -n envoy-02 deploy/echo --timeout=180s
Waiting for deployment "echo" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "echo" rollout to finish: 1 of 2 updated replicas are available...
deployment "echo" successfully rolled out
```

### Step 2 — read the shape of the config

The top-level sections of `manifests/10-envoy-config.yaml`, with their line
numbers:

```console
$ grep -nE '^    (node|admin|static_resources):|^      (listeners|clusters):|http_connection_manager$|route_config:|http_filters:' manifests/10-envoy-config.yaml
16:    node:
20:    admin:
24:    static_resources:
25:      listeners:
31:          - name: envoy.filters.network.http_connection_manager
85:              route_config:
110:              http_filters:
115:      clusters:
```

**What just happened:** that is the picture above, as line numbers. `node` names
this proxy, `admin` is the admin interface, and `static_resources` holds the
listener (with its HTTP connection manager, routes and filters) and the cluster.
Open the file and read the comments — each field says why it is set.

### Step 3 — start Envoy

```console
$ oc apply -n envoy-02 -f manifests/10-envoy-config.yaml
configmap/envoy-config created
$ oc apply -n envoy-02 -f manifests/20-envoy.yaml
service/envoy created
deployment.apps/envoy created
$ oc rollout status -n envoy-02 deploy/envoy --timeout=180s
Waiting for deployment "envoy" rollout to finish: 0 of 1 updated replicas are available...
deployment "envoy" successfully rolled out
```

### Step 4 — the `Server` header

```console
$ oc exec -n envoy-02 client -- curl -s -i http://envoy:8080/fields | grep -i '^server:'
server: tutorial-gateway
```

**What just happened:** the echo app sends `Server: BaseHTTP/0.6 Python/3.12.14`,
and the client saw `tutorial-gateway` instead. `server_header_transformation`
defaults to `OVERWRITE`: Envoy replaces the upstream's `Server` header with
`server_name` — which itself defaults to `envoy` (measured on module 01's
config). Setting `server_name` stops your responses advertising which proxy you
run.

### Step 5 — the deadline the app is told

Envoy tells the upstream the deadline it is enforcing, in a **request** header
the echo app reports back:

```console
$ oc exec -n envoy-02 client -- curl -s http://envoy:8080/fields | grep expected-rq
    "x-envoy-expected-rq-timeout-ms": "2000"
```

**What just happened:** `2000` ms. Three of this config's timeouts bound a
request, and the one the app is told is not the obvious one:

```yaml
request_timeout: 10s          # listener: how long to wait to RECEIVE the request
timeout: 5s                   # route: from sending it upstream to the full response
per_try_timeout: 2s           # retry policy: the deadline for each attempt
```

With a retry policy, the app is told the deadline of *this attempt* — and here
it is the whole deadline. Envoy retries an attempt that timed out only under a
`retry_on` that covers it, such as `reset`, `5xx` or `gateway-error`; this
config's `connect-failure,refused-stream,unavailable` does not. Measured on
Envoy 1.39.1 against an upstream that takes 3 s: `504` after 2.0 s with
`upstream_rq_retry: 0`; under `reset`, `5xx` or `gateway-error`, two retries
and `504` after 5.0 s, when the route's `timeout` ran out. The "Try this" in
step 9 removes `per_try_timeout` and watches the number change.

### Step 6 — the access log is JSON

```console
$ sleep 10; oc logs -n envoy-02 deploy/envoy | grep '"path":"/fields"' | tail -1
{"bytes_in":0,"bytes_out":406,"code":200,"duration":1,"flags":"-","method":"GET","path":"/fields","protocol":"HTTP/1.1","req_id":"2ce31844-15fa-480c-b87a-788709be6776","start":"2026-09-26T03:30:29.757Z","upstream":"10.217.0.148:8080"}
```

**What just happened:** one JSON object per request, with the fields listed under
`json_format` in the config. Envoy writes the log in batches, which is why the
command waits ten seconds first.

`flags` is the field people wish they had logged. It is Envoy's own verdict on
the request — `UF` upstream connection failure, `UT` upstream timeout, `NR` no
route, `URX` retry limit exceeded — and it separates "the app returned 503" from
"Envoy gave up before reaching it". `-` means no flag: nothing went wrong.

### Step 7 — the circuit breakers, as the running proxy sees them

```console
$ oc exec -n envoy-02 client -- curl -s http://envoy:9901/clusters | grep -E '^echo_service::default_priority::max_(connections|pending_requests|requests|retries)::'
echo_service::default_priority::max_connections::100
echo_service::default_priority::max_pending_requests::50
echo_service::default_priority::max_requests::200
echo_service::default_priority::max_retries::3
```

**What just happened:** the limits this config sets — 100 connections, 50 pending
requests, 200 requests, 3 retries. Module 01's config sets none, and the same
command there shows the defaults: **1024, 1024, 1024 and 3**.

Circuit breakers are never "off" — the defaults are just enormous. A struggling
app behind 1024-deep limits gets buried rather than protected: Envoy will queue a
thousand requests against something that has stopped answering.
`max_pending_requests` is the one to think about — it is how many requests may
wait for a connection, and where "slow backend" turns into "queue that never
drains".

### Step 8 — the node identity

```console
$ oc exec -n envoy-02 client -- curl -s http://envoy:9901/server_info | grep -E '"(id|cluster)": '
  "id": "tutorial-envoy",
  "cluster": "envoy-tutorial",
```

**What just happened:** the `node` block at the top of the config, as the running
proxy reports it — what a control plane uses to recognise each proxy. It is not
in `/stats` or `/stats/prometheus` (measured on Envoy 1.39.1: no line contains
`tutorial-envoy`), and this access log has no field for it, so on its own it does
not tell several Envoys' metrics or logs apart.

### Step 9 — check yourself

```console
$ ./run.sh verify

the fields are actually in effect, not just in the file
  ✓ Server header rewritten to server_name
  ✓ backend is told the per-try deadline (2s), not the route's 5s

the access log is JSON with the fields we asked for
  ✓ log has "start"
  ✓ log has "method"
  ✓ log has "path"
  ✓ log has "protocol"
  ✓ log has "code"
  ✓ log has "flags"
  ✓ log has "duration"
  ✓ log has "upstream"
  ✓ log has "req_id"

circuit breakers are registered with the values we set
  ✓ max_connections 100
  ✓ max_pending_requests 50
  ✓ max_requests 200

the retry policy is live
  ✓ retry_on set
  ✓ num_retries 2

node identity is in /server_info
  ✓ node id

all checks passed
```

**Try this:** delete the line `per_try_timeout: 2s` from
`manifests/10-envoy-config.yaml`, then apply it and restart Envoy — delete the
pod, because the config is mounted with `subPath` and never updates in a running
pod:

```bash
oc apply -n envoy-02 -f manifests/10-envoy-config.yaml
oc delete pod -n envoy-02 -l app=envoy
oc rollout status -n envoy-02 deploy/envoy
oc exec -n envoy-02 client -- curl -s http://envoy:8080/fields | grep expected-rq
```

The app is now told `5000` — the route's timeout. Measured on CRC: `2000` with
`per_try_timeout`, `5000` without it, `2000` again when it is put back. If you
read that header to set a client deadline, know which of the three you are
seeing. Put the line back when you are done.

## The fields, their defaults, and when to change them

"How we know" says where the default comes from: **measured** on a running Envoy
on CRC, or taken from the **API** reference.

**The listener's HTTP connection manager**

| Field | Default | How we know | Change it when |
|---|---|---|---|
| `stat_prefix` | — (required) | API | always; it is how you tell listeners apart in metrics |
| `use_remote_address` | **`false`** | measured (module 01) | `true` at the edge, so the app sees the client's address |
| `server_header_transformation` | `OVERWRITE` | measured | `PASS_THROUGH` only if a client depends on the app's value |
| `server_name` | `envoy` | measured | to stop advertising which proxy you run |
| `generate_request_id` | `true` | measured (module 01) | leave on; `x-request-id` is the spine of tracing |
| `request_timeout` | **none** | API: *"If not specified or set to 0, this timeout is disabled."* | always set it; unset, a slow client can take forever to send a request |
| `common_http_protocol_options.idle_timeout` | **1 hour** | API | shorter than the idle timeout of whatever sits in front, or you get resets |

**The route**

| Field | Default | How we know | What it does |
|---|---|---|---|
| `timeout` | **15 s** | measured (`15000` in module 01) | the upstream deadline: from sending the request on to receiving the whole response |
| `retry_policy` | **none** | API | retries happen only when a retry policy is set |
| `retry_policy.num_retries` | 1 | API | additional attempts, once `retry_on` is set |
| `retry_policy.per_try_timeout` | the route `timeout` | measured (step 9) | the deadline for each attempt |

**Only retry what is safe to repeat.** The conditions this config retries on:

| `retry_on` | Envoy's definition | Safe to repeat? |
|---|---|---|
| `connect-failure` | the connection to the upstream failed (connect timeout, etc.) | yes — the request never reached the app |
| `refused-stream` | the upstream reset the stream with `REFUSED_STREAM` | yes — Envoy's docs: *"indicates that a request is safe to retry"* |
| `unavailable` | the gRPC status in the response is `unavailable` (14) | **not always** — gRPC's own docs: *"it is not always safe to retry non-idempotent operations"* |

Adding `5xx` would retry requests the app may already have acted on, which turns
one payment into two.

**The cluster**

| Field | Default | How we know | What it does |
|---|---|---|---|
| `type` | `STATIC` | API | how endpoints are found — [module 05](../05-clusters-and-load-balancing/README.md) compares the types |
| `lb_policy` | `ROUND_ROBIN` | API | how to choose between endpoints |
| `connect_timeout` | 5 s | API | how long to wait for a TCP connection to an endpoint |
| `dns_refresh_rate` | 5 s | API | how often `STRICT_DNS` re-resolves the name |
| `circuit_breakers` | **1024 / 1024 / 1024 / 3** | measured (step 7's command, on module 01) | caps on connections, pending requests, requests and retries |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| `no healthy upstream` right after starting Envoy | `STRICT_DNS` resolves on a timer; Envoy has no endpoints yet | wait up to `dns_refresh_rate` (5 s) and retry |
| step 6 prints nothing | the access log has not been written yet | wait a few seconds and run it again |
| a config change has no effect | the file is mounted with `subPath` and never updates in a running pod | `oc delete pod -n envoy-02 -l app=envoy` |
| `namespaces "envoy-02" already exists` | you ran step 1 before | carry on, or `./run.sh clean` and start again |

## Clean up

```console
$ oc delete namespace envoy-02 --wait=false
namespace "envoy-02" deleted
```

## The shortcut

`./run.sh deploy` does steps 1 and 3, `./run.sh verify` is step 9, and
`./run.sh clean` removes the namespace.

## References

- [HTTP connection manager — every field and default](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/network/http_connection_manager/v3/http_connection_manager.proto)
- [HTTP protocol options — `idle_timeout`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto)
- [Route configuration — `timeout`, `retry_policy`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto)
- [Router filter — retry conditions](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter)
- [gRPC status codes — `UNAVAILABLE`](https://grpc.github.io/grpc/core/md_doc_statuscodes.html)
- [Cluster — `connect_timeout`, `dns_refresh_rate`, `lb_policy`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/cluster.proto)
- [Circuit breaking](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking)
- [Access log command operators — including `%RESPONSE_FLAGS%`](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#command-operators)

## Diagram sources

The figure is rendered from [`docs/diagrams/02-the-config-file/source.html`](../docs/diagrams/02-the-config-file/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
