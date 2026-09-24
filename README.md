# Envoy, from zero

A hands-on tutorial. It assumes you have **never used Envoy** and explains the
concepts before the YAML.

Every module is self-contained: its own namespace, its own manifests, its own
`run.sh`. Start anywhere.

## Modules

| | Topic |
|---|---|
| `00-prerequisites` | what your cluster needs, and how to check |
| `12-gateway-api` | Envoy Gateway, the Gateway API, `GRPCRoute`, TLS from cert-manager |

*(modules 01–11 are in progress — see the repository history)*

## How this tutorial is written

- **Nothing is asserted that was not run.** Command output is pasted from a real
  cluster, not paraphrased. Where a thing failed first, the failure is shown,
  because the error message is usually the most useful part.
- **Options are explained, not just used.** Each module has a table of the
  fields it introduces: what the field does, its default, and when you would
  change it.
- **Diagrams come in pairs** — a rendered figure and an ASCII twin, so the
  content survives a terminal, a diff, and a screen reader.
- **References are linked** so you can go deeper than the module goes.

## A worked example

[`envoy-grpc-modernization`](https://github.com/ephico2real2/envoy-grpc-modernization)
is a complete application built on these ideas: Envoy fronting a gRPC-only
service so a browser can call it over REST, with metrics and autoscaling labs.
The tutorial explains the pieces; that repo shows them assembled.
