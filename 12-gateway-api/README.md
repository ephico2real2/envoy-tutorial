# 12 — the Gateway API

Everything so far configured Envoy by handing it a config file. This module uses
the **Gateway API**: you declare *intent* as Kubernetes resources, and a
controller writes the Envoy config for you.

Verified on OpenShift 4.22.7 with Envoy Gateway v1.9.1.

## The shift

| | Static config (modules 01–11) | Gateway API |
|---|---|---|
| You write | `envoy.yaml` — listeners, routes, clusters | `Gateway`, `HTTPRoute` |
| Envoy config comes from | a ConfigMap you maintain | a controller, generated |
| Changing a route | edit YAML, restart Envoy | apply an `HTTPRoute` |
| Who owns what | one team owns the whole file | cluster team owns the `Gateway`; app teams own their `HTTPRoute`s |

That last row is the point. A single `envoy.yaml` is a contention point — every
team that wants a route edits the same file. The Gateway API splits it along
the line the org already has.

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/diagrams/12-gateway-api/ownership.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="../docs/diagrams/12-gateway-api/ownership.light.png">
  <img alt="The cluster operator owns the GatewayClass, which names the controller, and the Gateway: ports, TLS, and who may attach. The application team's HTTPRoute holds paths and backends and attaches to the Gateway, subject to allowedRoutes. The controller generates an Envoy Deployment and LoadBalancer Service, which you do not edit, and which sends traffic to your Service." src="../docs/diagrams/12-gateway-api/ownership.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

## Setup

**Read [`setup/`](setup/README.md) first.** Installing Envoy Gateway differs
between Kubernetes and OpenShift 4.19+, and the difference is not about Envoy —
it is about who owns the Gateway API CRDs.

- [`setup/README.md`](setup/README.md) — the two CRD groups, and what **not** to
  do on OpenShift
- [`setup/kubernetes.md`](setup/kubernetes.md) — vanilla Kubernetes
- [`setup/openshift.md`](setup/openshift.md) — OpenShift 4.19+, with every error
  hit on the way and its fix

## Run

```bash
./run.sh deploy
./run.sh verify
./run.sh clean
```

## The resources

| File | What |
|---|---|
| `manifests/10-gatewayclass.yaml` | which controller serves us, and the `EnvoyProxy` it should use |
| `manifests/20-envoyproxy.yaml` | the proxy's pod spec and Service — the OpenShift SCC and MetalLB fixes |
| `manifests/30-gateway.yaml` | the listener: port 80, routes from this namespace only |
| `manifests/40-httproute.yaml` | path `/` to the `echo` Service |

## What "verified" means here

```console
$ oc get gateway eg -n gwapi-demo
programmed=True  address=192.168.127.101

$ curl -s http://192.168.127.101/hello
{
  "served_by": "echo-f8fc6d5c9-qnx4z",
  "path": "/hello",
  "headers": {
    "x-forwarded-for": "10.217.0.150",
    "x-envoy-external-address": "10.217.0.150",
    "x-request-id": "a9e3262e-13c8-419c-8fc0-5f1fd129ead2"
  }
}
```

The `x-envoy-*` headers and `x-request-id` are Envoy's fingerprint. The echo app
never set them — it only reports what arrived, which is how you can tell a proxy
was in the path at all.

And it balances across the backend's two replicas:

```console
$ for i in $(seq 1 10); do curl -s http://192.168.127.101/ | grep served_by; done | sort | uniq -c
   4   "served_by": "echo-f8fc6d5c9-jx6lh"
   6   "served_by": "echo-f8fc6d5c9-qnx4z"
```

Ten requests over two pods will not split 5/5 — round-robin is per upstream
connection, not per request, and ten is a small sample. Module 05 measures this
properly.

## Two traps this module exists to teach

**The controller running is not a Gateway working.** Both of these left the
Gateway `Programmed=False` on a cluster where the controller was healthy:

1. The generated **proxy pod** is refused by `restricted-v2`. The `EnvoyProxy`
   resource clears the *pod-level* security context but not the *containers'* —
   and `shutdown-manager`'s is hardcoded upstream. Fixed with an SCC grant of
   `nonroot-v2`, which allows a non-root UID without allowing root.
2. MetalLB reported **"no available IPs"** on a pool with 20 free. The pool had
   `autoAssign: false`, so it never volunteers; a Service must name it. Read
   that message as *"no pool volunteered"*.

Both are in [`setup/openshift.md`](setup/openshift.md) with the real output.

## References

- [Gateway API](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway](https://gateway.envoyproxy.io/)
- [`EnvoyProxy` API](https://gateway.envoyproxy.io/docs/api/extension_types/#envoyproxy)
- [MetalLB — IPAddressPool](https://metallb.universe.tf/configuration/)

## Diagram sources

The figures are rendered from [`docs/diagrams/12-gateway-api/source.html`](../docs/diagrams/12-gateway-api/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
