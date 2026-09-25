# 02 — the config file, field by field

Module 01 used the smallest config that works. This one sets the fields you end
up setting on almost every real Envoy, and says what each does, what it defaults
to, and when to change it.

The recurring theme: **Envoy's defaults are permissive**. Most of what follows is
not adding behaviour, it is declining a default you would not have chosen.

## Run it

```bash
./run.sh deploy
./run.sh verify
```

`verify` does not read the config file — it asks the *running* proxy, so a
field that failed to apply is caught rather than assumed.

## The listener and HTTP connection manager

| Field | Default | What it does | Change it when |
|---|---|---|---|
| `stat_prefix` | — (required) | prefixes every stat from this listener | always; it is how you tell listeners apart in metrics |
| `use_remote_address` | **`false`** | trust the peer address and append it to `x-forwarded-for` | `true` at the edge. Module 01 measured what appears |
| `server_header_transformation` | `OVERWRITE` | what to do with the `Server` header | `PASS_THROUGH` only if a client depends on the backend's value |
| `server_name` | `envoy` | the value written when overwriting | to stop advertising that you run Envoy |
| `generate_request_id` | `true` | mint `x-request-id` when absent | leave on; it is the spine of tracing |
| `request_timeout` | **unset — no timeout** | whole-request deadline at the listener | always set it. Unset means a slow client can hold a connection indefinitely |
| `common_http_protocol_options.idle_timeout` | **1 hour** | how long an idle downstream connection survives | shorter than the idle timeout of whatever sits in front, or you get resets |

The two in bold are the ones that bite. `request_timeout` unset is not "a
sensible default" — it is no deadline at all.

## The route

| Field | Default | What it does |
|---|---|---|
| `match.prefix` | — | which requests this route claims |
| `route.cluster` | — | where they go |
| `timeout` | **15s** | per-route deadline; overrides `request_timeout` |
| `retry_policy.retry_on` | **none** | retries are OFF unless you ask |
| `retry_policy.num_retries` | 1 (if `retry_on` set) | additional attempts |
| `retry_policy.per_try_timeout` | the route `timeout` | deadline for each attempt |

**Only retry what is safe to repeat.** The conditions used here —
`connect-failure`, `refused-stream`, `unavailable` — all mean the request did
not reach the application. Adding `5xx` would retry requests the backend may
have already acted on, which turns one payment into two.

### The timeout the backend is actually told

Envoy sends the deadline it is enforcing to the upstream, as a **request**
header. Three timeouts are in play here, and the one that appears is not the
obvious one:

```yaml
request_timeout: 10s          # listener
timeout: 5s                   # route
per_try_timeout: 2s           # retry policy
```

```console
$ curl -s http://envoy:8080/fields | grep expected-rq
"x-envoy-expected-rq-timeout-ms": "2000"
```

**2000** — `per_try_timeout`. Not the route's 5s, and not the listener's 10s.
With retries configured, the deadline that matters to the backend is the one for
*this attempt*: Envoy may abandon it and try another endpoint while the 5s route
budget is still running.

Confirmed by removing that one field and asking again:

```console
$ # same config, per_try_timeout deleted
$ curl -s http://envoy:8080/noptt | grep expected-rq
"x-envoy-expected-rq-timeout-ms": "5000"
```

If you are reading that header to set a client deadline, know which of the three
you are actually seeing.

## The cluster

| Field | Default | What it does |
|---|---|---|
| `type` | — | how endpoints are discovered — module 05 compares them |
| `lb_policy` | `ROUND_ROBIN` | how to choose between them |
| `connect_timeout` | — (required) | TCP connect deadline |
| `dns_refresh_rate` | **5s** | how often `STRICT_DNS` re-resolves |
| `circuit_breakers` | **1024 of everything** | caps on concurrent work |

### Circuit breakers are not off, they are just enormous

The defaults are `max_connections`, `max_pending_requests`, `max_requests` and
`max_retries` at **1024** each. That is high enough that a struggling backend
gets buried rather than protected — Envoy will happily queue a thousand requests
against something that has stopped answering.

```yaml
circuit_breakers:
  thresholds:
  - priority: DEFAULT
    max_connections: 100
    max_pending_requests: 50    # the important one: queue depth
    max_requests: 200
    max_retries: 3              # caps the retry storm, not each request
```

`max_pending_requests` is the one to think about. It is how many requests may
wait for a connection, and it is where "slow backend" turns into "queue that
never drains".

## A startup race worth knowing

`STRICT_DNS` resolves on a timer. An Envoy that starts before its backend is
ready answers:

```text
HTTP/1.1 503 Service Unavailable
no healthy upstream
```

Nothing is misconfigured — Envoy simply has no endpoints yet, and will pick them
up within `dns_refresh_rate`. Deployment readiness does **not** cover this:
Envoy is ready, its upstream is not. That is why `run.sh` waits for the cluster
to report an endpoint before asserting anything:

```bash
curl -s localhost:9901/clusters | grep '^echo_service::[0-9].*::cx_total'
```

## Access logs: JSON, not text

```yaml
json_format:
  start: "%START_TIME%"
  code:  "%RESPONSE_CODE%"
  flags: "%RESPONSE_FLAGS%"
  ...
```

`%RESPONSE_FLAGS%` is the field people wish they had logged. It carries Envoy's
own verdict — `UF` upstream connect failure, `UT` upstream timeout, `NR` no
route, `URX` retry limit exceeded — and distinguishes "the backend returned 503"
from "Envoy gave up before reaching it". Two very different pages at 3am.

## Asking the running proxy

```bash
kubectl port-forward -n envoy-02 deploy/envoy 9901:9901
curl -s localhost:9901/config_dump | jq '.configs[] | select(.["@type"] | contains("Listener"))'
curl -s localhost:9901/clusters | grep echo_service
curl -s localhost:9901/server_info | jq .node
```

## References

- [HTTP connection manager](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/network/http_connection_manager/v3/http_connection_manager.proto)
- [Route configuration](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto)
- [Cluster](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/cluster.proto)
- [Circuit breaking](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking)
- [Access log command operators](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#command-operators) — including `%RESPONSE_FLAGS%`
