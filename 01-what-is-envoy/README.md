# 01 — what Envoy is

Envoy is a **proxy**: a program that accepts a network connection, decides what
to do with it, and opens its own connection somewhere else. That is the whole
idea. Everything else is configuration.

This module puts Envoy in front of an app that already works, then shows what
changed — because "what changed" is the clearest definition of what a proxy is.

## Proxy, reverse proxy, sidecar

Same program, three deployment positions. The words describe *where it sits*,
not what it does.

| Term | Sits in front of | Knows about |
|---|---|---|
| forward proxy | the **client** | where the client wants to go |
| **reverse proxy** | the **server** | which servers exist |
| sidecar | one pod, both ways | that one app |

Envoy is used as a reverse proxy here, and in almost every Kubernetes context.

## The four nouns

Open `manifests/10-envoy-config.yaml` alongside this. Every Envoy config is
these four, nested:

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/01-what-is-envoy/four-nouns.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/01-what-is-envoy/four-nouns.light.png">
  <img alt="Every Envoy config is four nouns, nested: a listener is a port Envoy accepts connections on; a filter chain is what to do with a connection that arrives; filters see bytes, and http_connection_manager turns them into requests; routes decide which cluster a request belongs to; a cluster is a named group of upstream endpoints." src="../docs/diagrams/01-what-is-envoy/four-nouns.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

```text
  LISTENER            a port Envoy accepts connections on
    └── FILTER CHAIN  what to do with a connection that arrives
          └── FILTERS  network filters see bytes;
                       http_connection_manager turns them into requests
                └── ROUTES    which cluster a request belongs to
                        │
                        ▼
  CLUSTER             a named group of upstream endpoints
```

Read it as a sentence: *accept on this port, speak HTTP, match this path, send
it to that cluster.*

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/01-what-is-envoy/request-path.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/01-what-is-envoy/request-path.light.png">
  <img alt="curl sends GET /hello to Envoy's listener on port 8080; the filter chain's http connection manager matches route slash to cluster echo_service, STRICT_DNS and ROUND_ROBIN, which sends it to echo-1 or echo-2; the reply passes back through Envoy to curl: 200, plus headers the app never set." src="../docs/diagrams/01-what-is-envoy/request-path.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

```text
   curl                    ENVOY                         echo
    │                ┌──────────────────┐
    │  GET /hello    │ listener :8080   │
    ├───────────────▶│  filter_chain    │
    │                │   hcm            │
    │                │    route "/" ────┼──▶ cluster echo_service
    │                │                  │      STRICT_DNS
    │                │                  │      ROUND_ROBIN
    │                │                  │        │      │
    │                │                  │        ▼      ▼
    │                │                  │     echo-1  echo-2
    │◀───────────────┤  reply returns   │◀───────┴──────┘
    │                │  through Envoy   │
    │                └──────────────────┘
       200, plus headers the app never set
```

## Run it

```bash
./run.sh deploy
./run.sh verify
./run.sh clean
```

## What the proxy actually changed

The echo app reports the request it received. Call it directly, then through
Envoy, and diff the headers.

**Direct — `curl http://echo:8080/direct`:**

```json
"headers": {
  "host": "echo.envoy-01.svc:8080",
  "user-agent": "curl/8.11.1",
  "accept": "*/*"
}
```

**Through Envoy — `curl http://envoy:8080/direct`:**

```json
"headers": {
  "host": "envoy.envoy-01.svc:8080",
  "user-agent": "curl/8.11.1",
  "accept": "*/*",
  "x-forwarded-for": "10.217.0.169",
  "x-forwarded-proto": "http",
  "x-envoy-external-address": "10.217.0.169",
  "x-request-id": "6adb95c5-b72d-493e-8a65-45fcb7eabae9",
  "x-envoy-expected-rq-timeout-ms": "15000"
}
```

Five headers appeared. **The app did not set any of them** — it only reports
what arrived. That difference is the proxy, made visible:

| Header | What it tells you |
|---|---|
| `x-forwarded-for` | the original client address, which the backend would otherwise never see |
| `x-forwarded-proto` | whether the *client* spoke http or https, even if this hop is plaintext |
| `x-envoy-external-address` | the trusted client address Envoy settled on |
| `x-request-id` | one id, propagated across hops — the basis of tracing |
| `x-envoy-expected-rq-timeout-ms` | the deadline Envoy is enforcing, told to the backend |

## The one field worth pausing on

`x-forwarded-for` only appears because of a single line:

```yaml
use_remote_address: true
```

It **defaults to false**, and the consequence surprises people: no XFF header at
all, and a backend that cannot see its client. Measured both ways on this exact
config:

| | headers added |
|---|---|
| `false` (default) | `x-request-id`, `x-envoy-expected-rq-timeout-ms` |
| `true` | …plus `x-forwarded-for`, `x-envoy-external-address` |

`true` is right for an **edge** proxy, which is what this is. Behind another
proxy it should stay `false`, or the address Envoy appends is the hop in front
of it rather than the client.

## Ask Envoy what it thinks it is doing

The admin interface is not on the request path and is the first place to look
when something is wrong:

```bash
kubectl port-forward -n envoy-01 deploy/envoy 9901:9901

curl localhost:9901/ready            # has it loaded a valid config?
curl localhost:9901/config_dump      # the ENTIRE running config, as JSON
curl localhost:9901/clusters         # every endpoint, with health and counters
curl localhost:9901/stats | grep rq_ # request counters
```

`/config_dump` answers "is the config I applied the config it is running?" —
the question behind most Envoy debugging. It is also how `verify` checks the
listener and cluster exist, rather than assuming the apply worked.

## It is already load balancing

`echo` runs two replicas, and twelve requests reach both:

```console
$ for i in $(seq 1 12); do curl -s http://envoy:8080/ | grep served_by; done | sort | uniq -c
   5   "served_by": "echo-f8fc6d5c9-jx6lh"
   7   "served_by": "echo-f8fc6d5c9-qx4xw"
```

Two lines make that possible, and one of them is not in the Envoy config at all:

```yaml
type: STRICT_DNS        # re-resolve the name, keep one endpoint per address
lb_policy: ROUND_ROBIN  # rotate between them
```
```yaml
clusterIP: None         # in the SERVICE - so DNS returns pod IPs, not one VIP
```

Without `clusterIP: None`, DNS returns a single virtual IP, Envoy sees one
endpoint, and `ROUND_ROBIN` has nothing to choose between. Module 05 measures
exactly that failure.

## What this module skipped

TLS, timeouts, retries, health checks, multiple routes, anything dynamic. Each
gets its own module. The config here is the smallest thing that is still real.

## References

- [Envoy — Life of a Request](https://www.envoyproxy.io/docs/envoy/latest/intro/life_of_a_request)
- [Listener configuration](https://www.envoyproxy.io/docs/envoy/latest/configuration/listeners/listeners)
- [HTTP connection manager](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/http_conn_man)
- [`use_remote_address` and XFF](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/headers#x-forwarded-for)
- [The admin interface](https://www.envoyproxy.io/docs/envoy/latest/operations/admin)

## Diagram sources

The figures are rendered from [`docs/diagrams/01-what-is-envoy/source.html`](../docs/diagrams/01-what-is-envoy/source.html)
(inline SVG, light and dark). The picture, its text twin and the page change
together; re-render with the `/visual` skill's `render.py`.
