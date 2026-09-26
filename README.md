# Envoy, from zero

A hands-on tutorial. It assumes you have **never used Envoy** and explains the
concepts before the YAML.

Every module is a **step-by-step walkthrough**: numbered steps you type in order,
each with the output you should see and a few lines on what just happened.
Every command runs as written from your laptop.

## Start here

1. [`00-prerequisites`](00-prerequisites/README.md) — check your laptop and
   cluster are ready. Five minutes.
2. Then the modules in order. Each one is self-contained — its own namespace,
   its own manifests — so you can also start at any of them.

## Modules

| | Topic | State |
|---|---|---|
| [`00-prerequisites`](00-prerequisites/README.md) | what your cluster needs, and how to check | **done** |
| [`01-what-is-envoy`](01-what-is-envoy/README.md) | proxy vs reverse proxy; listener, filter, route, cluster | **done** |
| [`02-the-config-file`](02-the-config-file/README.md) | the config file, field by field, and what each field defaults to | **done** |
| [`03-listeners-and-filter-chains`](03-listeners-and-filter-chains/README.md) | `filter_chain_match`, SNI, `tls_inspector`, passthrough Routes | **done** |
| [`04-routing`](04-routing/README.md) | match types, first match wins, rewrites, timeouts, redirects, `direct_response` | **done** |
| [`05-clusters-and-load-balancing`](05-clusters-and-load-balancing/README.md) | STATIC / STRICT_DNS / LOGICAL_DNS / EDS, the headless lesson, load-balancing policies measured, health checks | **done** |
| `06`–`11` | filters, gRPC, TLS, observability, resilience | to come |
| [`12-gateway-api`](12-gateway-api/README.md) | Envoy Gateway, `Gateway`, `HTTPRoute`, and the two OpenShift traps that block them | **done** |

Module 12 was written first because it was the immediate need. The numbering is
the reading order, not the build order.

## What you need

A Kubernetes or OpenShift cluster you can create namespaces in, and `oc` (or
`kubectl`). Everything here was run on **OpenShift Local (CRC) 4.22.7**. Module
00 checks the rest.

## How every module works

Each module's README walks you through it. Once you know what the steps do,
each module's `run.sh` does them in one go:

```bash
./run.sh deploy     # create the namespace and everything in it
./run.sh verify     # check the running proxy behaves as the README says
./run.sh clean      # delete the namespace
```

`verify` is a set of assertions against the **running** proxy, not a wall of
output — a module either passes or names the claim that failed.

## How this tutorial is written

- **Every command runs as written.** [`tooling/walkthrough`](tooling/walkthrough/run.py)
  executes every command in a module's README, in order, against a real cluster,
  and pastes the real output back in. The output you read is from that run.
- **Nothing is asserted that was not measured or sourced.** A default is either
  read from a running Envoy or quoted from the Envoy API reference, and the
  README says which. Where running something corrected the text, the text was
  changed.
- **Options are explained, not just used.** Each module has a table of the
  fields it introduces: what the field does, its default, and when you would
  change it.
- **Diagrams are rendered figures**, light and dark, with traffic flowing top
  to bottom. Each is drawn from the module's manifests and measured output, its
  `alt` text states the same claim for screen readers, and its source is in
  [`docs/diagrams/`](docs/diagrams/).
- **Console screenshots are legible.** Where a module shows the OpenShift
  console, the capture is zoomed to the content and checked before it ships —
  see [`tooling/screenshot`](tooling/screenshot/README.md).
- **References are linked** so you can go deeper than the module goes.

## Tooling

- [`tooling/walkthrough/run.py`](tooling/walkthrough/run.py) — runs every
  command in a README exactly as written and fails on the first that breaks;
  `--update` pastes the real output back in.
  `python3 tooling/walkthrough/run.py 01-what-is-envoy/README.md`
- [`tooling/screenshot`](tooling/screenshot/README.md) — how every console
  capture is taken so the text is legible: `zoom` to a region rather than a
  full-viewport `screenshot`, cropped to the content box, theme matched to the
  UI, and a `verify.py` that fails a capture with a wide flat margin.
- [`_shared/client.yaml`](_shared/client.yaml) — the in-cluster pod every
  walkthrough runs `curl` from.

## A worked example

[`envoy-grpc-modernization`](https://github.com/ephico2real2/envoy-grpc-modernization)
is a complete application built on these ideas: Envoy fronting a gRPC-only
service so a browser can call it over REST, with metrics and autoscaling labs.
The tutorial explains the pieces; that repo shows them assembled.
