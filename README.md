# Envoy, from zero

A hands-on tutorial. It assumes you have **never used Envoy** and explains the
concepts before the YAML.

Every module is self-contained: its own namespace, its own manifests, its own
`run.sh`. Start anywhere.

## Modules

| | Topic | State |
|---|---|---|
| [`12-gateway-api`](12-gateway-api/README.md) | Envoy Gateway, `Gateway`, `HTTPRoute`, and the two OpenShift traps that block them | **done** |
| [`00-prerequisites`](00-prerequisites/README.md) | what your cluster needs, and how to check | **done** |
| [`01-what-is-envoy`](01-what-is-envoy/README.md) | proxy vs reverse proxy; listener, filter, route, cluster | **done** |
| [`02-the-config-file`](02-the-config-file/README.md) | the bootstrap config, field by field | **done** |
| [`03-listeners-and-filter-chains`](03-listeners-and-filter-chains/README.md) | `filter_chain_match`, SNI, `tls_inspector` | **done** |
| [`04-routing`](04-routing/README.md) | match types, first match wins, rewrites, timeouts, redirects, `direct_response` | **done** |
| `05`–`11` | load balancing, filters, gRPC, TLS, observability, resilience | to come |

Module 12 is written first because it was the immediate need. The numbering is
the reading order, not the build order.

Every module runs on its own: its own namespace, its own manifests, and

```bash
./run.sh deploy | verify | clean
```

`verify` is a set of assertions, not a wall of output — a module either passes
or names the claim that failed.

## How this tutorial is written

- **Nothing is asserted that was not run.** Command output is pasted from a real
  cluster, not paraphrased. Where a thing failed first, the failure is shown,
  because the error message is usually the most useful part.
- **Options are explained, not just used.** Each module has a table of the
  fields it introduces: what the field does, its default, and when you would
  change it.
- **Diagrams come in pairs** — a rendered figure and a text twin, so the
  content survives a terminal, a diff, and a screen reader. Each figure is
  drawn from the module's manifests and measured output, and its source is in
  [`docs/diagrams/`](docs/diagrams/).
- **References are linked** so you can go deeper than the module goes.

## Tooling

[`tooling/screenshot`](tooling/screenshot/README.md) — how every console capture
here was taken so the text is legible: `zoom` to a region rather than a
full-viewport `screenshot`, cropped to the content box, theme matched to the UI,
and a `verify.py` that fails a capture with a wide flat margin.

## A worked example

[`envoy-grpc-modernization`](https://github.com/ephico2real2/envoy-grpc-modernization)
is a complete application built on these ideas: Envoy fronting a gRPC-only
service so a browser can call it over REST, with metrics and autoscaling labs.
The tutorial explains the pieces; that repo shows them assembled.
