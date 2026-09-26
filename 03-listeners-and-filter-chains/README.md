# 03 — listeners and filter chains

A **listener** is a port. A **filter chain** is one possible way to handle a
connection arriving on it. `filter_chain_match` decides which chain applies.

The distinction this module exists to teach:

> A filter chain is chosen **before a single byte of HTTP has been parsed**.
> A virtual host is chosen **after**.

That is why SNI selects a chain and the `Host` header cannot.

## What you'll learn

- the two ways Envoy routes "by name" — **SNI** (the name inside the TLS
  handshake) and the **`Host` header** — and exactly when each one is visible
- what `tls_inspector` does, and what breaks without it
- why an OpenShift Route must be **passthrough** for SNI to reach Envoy

## Before you start

- [`00-prerequisites`](../00-prerequisites/README.md) passes; modules
  [01](../01-what-is-envoy/README.md) and [02](../02-the-config-file/README.md)
  are worth doing first.
- Work from this folder: `cd 03-listeners-and-filter-chains`.
- This module uses the namespace **`envoy-03`** and takes about 20 minutes.
- Step 8 uses OpenShift Routes and the CRC hostnames `*.apps-crc.testing`. On
  another cluster, skip it — every other step works anywhere.

## Five stages, in order

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/03-listeners-and-filter-chains/chain-vs-vhost.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/03-listeners-and-filter-chains/chain-vs-vhost.light.png">
  <img alt="A TCP connection passes five stages in order: listener filters run, where tls_inspector reads SNI; filter_chain_match picks one chain, where SNI is available and the Host header is not; transport_socket terminates TLS with the chain's own certificate; http_connection_manager, where there is now HTTP; and virtual_hosts match domains, where the Host header is available." src="../docs/diagrams/03-listeners-and-filter-chains/chain-vs-vhost.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

| | `filter_chain_match` | `virtual_hosts.domains` |
|---|---|---|
| runs | before TLS termination | after HTTP parsing |
| can see | SNI, source/destination IP, port, ALPN | `Host`, path, headers, method |
| cannot see | anything HTTP | anything pre-TLS |
| picks | a whole chain, including its certificate | a route |
| on no match | connection closed — for TLS the handshake fails | the `["*"]` vhost, or 404 |

Reaching for `filter_chain_match` to select on a hostname is the classic
mistake. It works for **TLS** traffic, because SNI carries the name — and fails
for plaintext HTTP, because at that point the name does not exist yet.

This module runs **two listeners** to show both:

- **`:8080`, plaintext** — one filter chain, three virtual hosts chosen by `Host`
- **`:8443`, TLS** — two filter chains chosen by SNI, each with its own certificate

## Walkthrough

### Step 1 — a namespace, a client, and the app

```console
$ oc create namespace envoy-03
namespace/envoy-03 created
$ oc apply -n envoy-03 -f ../_shared/client.yaml
pod/client created
$ oc apply -n envoy-03 -f ../_shared/echo-app.yaml
configmap/echo-src created
service/echo created
deployment.apps/echo created
$ oc wait -n envoy-03 --for=condition=Ready pod/client --timeout=120s
pod/client condition met
$ oc rollout status -n envoy-03 deploy/echo --timeout=180s
Waiting for deployment "echo" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "echo" rollout to finish: 1 of 2 updated replicas are available...
deployment "echo" successfully rolled out
```

### Step 2 — read the two listeners

```console
$ grep -nE 'name: (http|tls)_listener|port_value: (8080|8443)|domains:|listener_filters:|tls_inspector$|server_names:|certificate_chain:' manifests/10-envoy-config.yaml
20:      - name: http_listener
22:          socket_address: { address: 0.0.0.0, port_value: 8080 }
38:                  domains: ["shop.apps-crc.testing"]
45:                  domains: ["admin.apps-crc.testing"]
52:                  domains: ["*"]
64:      - name: tls_listener
66:          socket_address: { address: 0.0.0.0, port_value: 8443 }
74:        listener_filters:
75:        - name: envoy.filters.listener.tls_inspector
81:            server_names: ["shop.apps-crc.testing"]
88:                - certificate_chain: { filename: /etc/certs/shop.crt }
99:                  domains: ["*"]
111:            server_names: ["admin.apps-crc.testing"]
118:                - certificate_chain: { filename: /etc/certs/admin.crt }
129:                  domains: ["*"]
151:                  socket_address: { address: echo, port_value: 8080 }
```

**What just happened:** from top to bottom — `http_listener` on 8080 with three
virtual hosts (`shop`, `admin`, and the `*` catch-all), then `tls_listener` on
8443 with `tls_inspector` as a **listener filter**, and two filter chains, each
matching one name in `server_names` and presenting its own certificate. Each TLS
chain has a single `domains: ["*"]` vhost — the name was already chosen by SNI.
The last line is the cluster's endpoint, `echo` on 8080.

### Step 3 — start Envoy

```console
$ oc apply -n envoy-03 -f manifests/10-envoy-config.yaml
configmap/envoy-config created
$ oc apply -n envoy-03 -f manifests/20-envoy.yaml
service/envoy created
deployment.apps/envoy created
$ oc rollout status -n envoy-03 deploy/envoy --timeout=180s
Waiting for deployment "envoy" rollout to finish: 0 of 1 updated replicas are available...
deployment "envoy" successfully rolled out
```

**What just happened:** before Envoy starts, an init container (`certgen`)
generates two self-signed certificates — `CN=shop.apps-crc.testing` and
`CN=admin.apps-crc.testing` — into a volume the Envoy container reads. Module 08
replaces this with cert-manager.

### Step 4 — choosing by `Host`, on plaintext :8080

```console
$ oc exec -n envoy-03 client -- curl -s -i -H 'Host: shop.apps-crc.testing' http://envoy:8080/ | grep x-matched
x-matched-vhost: shop
$ oc exec -n envoy-03 client -- curl -s -i -H 'Host: admin.apps-crc.testing' http://envoy:8080/ | grep x-matched
x-matched-vhost: admin
$ oc exec -n envoy-03 client -- curl -s -i -H 'Host: nobody.apps-crc.testing' http://envoy:8080/ | grep -E '^HTTP|virtual host'
HTTP/1.1 404 Not Found
no virtual host for that Host header
```

**What just happened:** one filter chain, and the `Host` header picked the
virtual host. Each vhost's route adds an `x-matched-vhost` header saying which
one fired. An unknown `Host` lands on the `domains: ["*"]` catch-all, whose
`direct_response` explains the 404 — without it, you get Envoy's own 404 and no
explanation.

### Step 5 — choosing by SNI, on TLS :8443

`--connect-to` makes curl **connect** to `envoy:8443` while it **names**
`shop.apps-crc.testing` in the TLS handshake — the SNI. No `Host` header is set
by hand.

```console
$ oc exec -n envoy-03 client -- curl -sk -i --connect-to shop.apps-crc.testing:8443:envoy:8443 https://shop.apps-crc.testing:8443/ | grep x-matched
x-matched-chain: sni-shop
$ oc exec -n envoy-03 client -- curl -sk -i --connect-to admin.apps-crc.testing:8443:envoy:8443 https://admin.apps-crc.testing:8443/ | grep x-matched
x-matched-chain: sni-admin
```

**What just happened:** same address, same port — and a different filter chain
each time. The only thing that differed was the name in the TLS handshake.

### Step 6 — each chain presents its own certificate

```console
$ oc exec -n envoy-03 client -- curl -sk -o /dev/null -w '%{certs}' --connect-to shop.apps-crc.testing:8443:envoy:8443 https://shop.apps-crc.testing:8443/ | grep -i '^subject:'
Subject:CN = shop.apps-crc.testing
$ oc exec -n envoy-03 client -- curl -sk -o /dev/null -w '%{certs}' --connect-to admin.apps-crc.testing:8443:envoy:8443 https://admin.apps-crc.testing:8443/ | grep -i '^subject:'
Subject:CN = admin.apps-crc.testing
```

**What just happened:** curl's `%{certs}` prints the certificate the server sent.
Each chain has its own `transport_socket` with its own certificate — which is why
a chain has to be chosen **before** TLS is terminated: the choice decides which
certificate to present.

### Step 7 — an SNI that matches no chain

<!-- walkthrough: expect-exit 35 -->
```console
$ oc exec -n envoy-03 client -- curl -sk --connect-to nobody.apps-crc.testing:8443:envoy:8443 https://nobody.apps-crc.testing:8443/
command terminated with exit code 35
```

**What just happened:** curl exit code **35** — the TLS handshake failed. No
chain matched, so there was no certificate to present, and Envoy closed the
connection. Envoy counts it:

```console
$ oc exec -n envoy-03 client -- curl -s http://envoy:9901/stats | grep 'listener.0.0.0.0_8443.no_filter_chain_match'
listener.0.0.0.0_8443.no_filter_chain_match: 1
```

Unlike a `Host` miss on :8080, there is no friendly 404 here: without a chain,
there is no HTTP to answer with.

### Step 8 — from your laptop, through OpenShift Routes

On OpenShift, two Routes make the real hostnames reach Envoy's TLS listener:

```console
$ oc apply -n envoy-03 -f manifests/30-routes.yaml
route.route.openshift.io/shop created
route.route.openshift.io/admin created
$ oc get route -n envoy-03 -o custom-columns=NAME:.metadata.name,HOST:.spec.host,TLS:.spec.tls.termination
NAME    HOST                     TLS
admin   admin.apps-crc.testing   passthrough
shop    shop.apps-crc.testing    passthrough
```

The router needs a few seconds to pick up new Routes. Then, from your laptop:

```console
$ sleep 5; curl -sk -i https://shop.apps-crc.testing/ | grep x-matched
x-matched-chain: sni-shop
$ curl -sk -i https://admin.apps-crc.testing/ | grep x-matched
x-matched-chain: sni-admin
```

**What just happened:** no `--connect-to`, no `Host` header — just the real
names. The Routes are **passthrough**: the router forwards the TCP stream
untouched and takes no part in the TLS handshake, so the ClientHello — and the
SNI in it — reaches Envoy exactly as your laptop sent it.

With `edge` or `reencrypt`, the router terminates TLS itself and opens its own
connection to Envoy. Envoy would then see whatever SNI the *router* chose, and
every request would land on the same chain.

### Step 9 — check yourself

```console
$ ./run.sh verify

[1m1. virtual hosts pick on the Host header (after HTTP is parsed)[0m
  [32m✓[0m Host shop.apps-crc.testing -> vhost shop
  [32m✓[0m Host admin.apps-crc.testing -> vhost admin
  [32m✓[0m unknown Host hits the catch-all 404

[1m2. filter chains pick on SNI (before any HTTP exists)[0m
  [32m✓[0m SNI shop.apps-crc.testing -> chain sni-shop
  [32m✓[0m SNI admin.apps-crc.testing -> chain sni-admin

[1m3. each chain serves its own certificate[0m
  [32m✓[0m SNI shop.apps-crc.testing is served the shop cert
  [32m✓[0m SNI admin.apps-crc.testing is served the admin cert

[1m4. tls_inspector is in the running listener[0m
  [32m✓[0m tls_inspector is present

[1m5. the Routes are passthrough (edge would terminate TLS at the router)[0m
  [32m✓[0m route/shop is passthrough
  [32m✓[0m route/admin is passthrough

[1mall checks passed[0m
```

**Try this — remove `tls_inspector`.** In `manifests/10-envoy-config.yaml`,
delete the four lines from `listener_filters:` down to its `"@type"` line. Apply,
and delete the pod so it restarts with the new file (the config is mounted with
`subPath` and never updates in a running pod):

```bash
oc apply -n envoy-03 -f manifests/10-envoy-config.yaml
oc delete pod -n envoy-03 -l app=envoy
oc rollout status -n envoy-03 deploy/envoy
oc exec -n envoy-03 client -- curl -sk -i --connect-to shop.apps-crc.testing:8443:envoy:8443 https://shop.apps-crc.testing:8443/
```

Measured on CRC:

| | shop | admin |
|---|---|---|
| with `tls_inspector` | `x-matched-chain: sni-shop` | `x-matched-chain: sni-admin` |
| without it | handshake fails, curl exit 35 | handshake fails, curl exit 35 |

`no_filter_chain_match` counted both. Nothing had read the ClientHello, so
Envoy never learned the SNI and no `server_names` chain could match. Put the
lines back when you are done.

Worth knowing: `/config_dump` still mentions `tls_inspector` even when it is not
declared, so **the config dump is not a reliable way to check this**. Test the
behaviour, not the config.

## The order that trips people up

Envoy picks the **most specific** matching chain, not the first one written.
The documented precedence, in order:

1. destination port
2. destination IP
3. `server_names` (SNI)
4. transport protocol
5. application protocol (ALPN)
6. source type, source IP, source port

A chain with **no** `filter_chain_match` matches everything and is the fallback.
Reordering chains in the file changes nothing — if two chains could both match,
Envoy rejects the config rather than guessing. (Routes, in module 04, are the
opposite: first match wins.)

## The fields this module used

| Field | Where | What it does |
|---|---|---|
| `listener_filters` | listener | filters that run on the raw connection, before any chain is chosen |
| `tls_inspector` | listener filter | reads SNI (and ALPN) from the TLS ClientHello without terminating TLS |
| `filter_chain_match.server_names` | filter chain | pick this chain when the SNI is one of these names |
| `transport_socket` (TLS) | filter chain | terminate TLS with this chain's certificate |
| `virtual_hosts[].domains` | route config | pick this vhost when the `Host` header matches; `"*"` matches anything |
| `direct_response` | route | answer from the config, with no upstream — here, the explained 404 |
| Route `tls.termination: passthrough` | OpenShift Route | forward the TCP stream untouched, so SNI reaches Envoy |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| curl exit 35 for `shop` or `admin` | no chain matched the SNI — or `tls_inspector` is missing | check step 2's output shows `tls_inspector`; check the name you used |
| `x-matched-chain` is always the same | the Route is `edge` or `reencrypt`, so Envoy sees the router's SNI | `oc get route -n envoy-03` — it must say `passthrough` |
| step 8 answers with the OpenShift "Application is not available" page | the router has not picked up the Route yet | wait a few seconds and retry |
| Envoy pod stuck in `Init` | the `certgen` init container could not pull `alpine/openssl:3.3.2` | `oc describe pod -n envoy-03 -l app=envoy` |

## Clean up

```console
$ oc delete namespace envoy-03 --wait=false
namespace "envoy-03" deleted
```

## The shortcut

`./run.sh deploy` does steps 1, 3 and the Routes from step 8; `./run.sh verify`
is step 9; `./run.sh clean` removes the namespace.

## References

- [Listener filters](https://www.envoyproxy.io/docs/envoy/latest/configuration/listeners/listener_filters/listener_filters)
- [TLS Inspector](https://www.envoyproxy.io/docs/envoy/latest/configuration/listeners/listener_filters/tls_inspector)
- [`FilterChainMatch` and its precedence](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/listener/v3/listener_components.proto#config-listener-v3-filterchainmatch)
- [curl `--connect-to`](https://curl.se/docs/manpage.html#--connect-to) and [`-w '%{certs}'`](https://curl.se/docs/manpage.html#-w)
- [OpenShift — passthrough Routes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ingress_and_load_balancing/configuring-routes)

## Diagram sources

The figure is rendered from [`docs/diagrams/03-listeners-and-filter-chains/source.html`](../docs/diagrams/03-listeners-and-filter-chains/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
