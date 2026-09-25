# 00 — prerequisites

```bash
./check.sh
```

It asserts rather than prints: you either get a clean pass or the exact claim
that failed.

## What you need

| | Why |
|---|---|
| a Kubernetes or OpenShift cluster | kind, minikube, k3s, CRC, or anything real |
| `kubectl` or `oc` | `check.sh` picks whichever is on your PATH |
| permission to create namespaces | each module uses its own |
| egress to Docker Hub | three public images, listed below |

Nothing is built and nothing is pushed. Every module runs stock images with its
source in a ConfigMap, so there is no registry in the loop.

| Image | Used as |
|---|---|
| `envoyproxy/envoy:v1.39-latest` | the proxy |
| `python:3.12-slim` | the echo app |
| `curlimages/curl:8.11.1` | the in-cluster client that `verify` uses |

## Needed by some modules only

`check.sh` reports these as present or "only module N needs it", so a missing
one is not a failure:

| | Modules |
|---|---|
| cert-manager | 08, 09, 12 |
| Gateway API CRDs | 12 |
| MetalLB (or any LoadBalancer) | 12 |
| Prometheus Operator CRDs | 10 |

## If you are on OpenShift

`check.sh` says so, and it matters. `restricted-v2` assigns each namespace a UID
range and refuses pods that pin a UID outside it — which upstream images
routinely do. Where a module hits this, it says so and shows the fix; module 12
has the worked example.

## Running a module

Every module is self-contained and offers the same three verbs:

```bash
cd 01-what-is-envoy
./run.sh deploy
./run.sh verify
./run.sh clean
```

Each deploys into its own namespace (`envoy-01`, `envoy-02`, …), so modules
never collide and you can start at any of them.
