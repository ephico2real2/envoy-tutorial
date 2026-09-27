# A second router on a MetalLB address — an IngressController shard

> **Not walked yet.** The commands below were written for CRC and checked with
> `oc apply --dry-run=server`. They have not been run: the cluster writes were
> not allowed in the session that wrote them
> ([#17](https://github.com/ephico2real2/envoy-tutorial/issues/17)). The output
> blocks are empty until the first walk. `python3 tooling/walkthrough/run.py
> 00-prerequisites/ingress-shard/README.md --update` pastes the real output.
> Until then, nothing here counts as measured.

OpenShift's own router, the **default IngressController**, carries every Route on
this cluster: the console, OAuth, Keycloak, the kiosk. On CRC it listens on the
node's own ports 80 and 443 (`HostNetwork`).

This page adds a **second router**, a *shard*, which:

- serves only the Routes that ask for it, through a label;
- has **its own address**, `192.168.127.130`, which MetalLB gives it;
- leaves the default router exactly as it is.

Module 20 puts its Route here
([#16](https://github.com/ephico2real2/envoy-tutorial/issues/16)). Module 19 puts
its Gateway on a MetalLB address. The laptop reaches both the same way, through
CRC's network proxy.

## What you'll learn

- how an `IngressController` shard picks its Routes (`routeSelector`), and why
  the default router still admits them;
- how a router published as a `LoadBalancerService` gets a MetalLB address. The
  address is chosen by a pool, so nothing has to be added to a Service the
  ingress operator owns;
- why a laptop running CRC needs a port forward to reach that address, and why
  bare metal does not.

## Before you start

- Module [`00`](../README.md)'s `check.sh` passes, including MetalLB and the
  `enterprise-ca` ClusterIssuer.
- You are a cluster admin: this adds an `IngressController`, a MetalLB pool and a
  certificate in `openshift-ingress`.
- **OpenSSL 3** on your laptop (`brew install openssl`), as in module 18.
- Work from this folder: `cd 00-prerequisites/ingress-shard`.
- It uses the namespace **`ingress-shard`** for its canary Route and takes about
  10 minutes. On the operator's CRC it is **permanent**, kept by Argo CD: see
  [Permanent lab](#permanent-lab) before you change anything by hand there.

## The picture

<!-- Figure to come (the /visual skill): the laptop's 127.0.0.1:20443 and CRC's :443
     at the top; gvproxy; 192.168.127.130 (router-metallb, MetalLB L2 on br-ex) and
     192.168.127.2 (router-default, HostNetwork) side by side; both admit Route
     canary; the echo app at the bottom. -->

*Figure to come.*

## Walkthrough

### Step 1 — MetalLB, as it is

```console
$ oc get ipaddresspool,l2advertisement -n metallb-system
$ oc get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}{end}'
```

**What just happened:** there is one pool, `mongot-pool`, holding
`192.168.127.100` to `.120`, with `autoAssign: false`. With that setting a
Service gets one of its addresses only when it asks for the pool by name, in the
annotation `metallb.io/address-pool` (or the older `metallb.universe.tf/…`). The
three Services listed asked for it: `mongodb-poc`'s and the Gateways of modules
17 and 19. `mongot-l2` advertises the pool at layer 2 on `br-ex`, the node's
interface on the CRC network: the node answers ARP for those addresses.

### Step 2 — the default router

```console
$ oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.endpointPublishingStrategy.type}  {.status.domain}  namespaceSelector={.spec.namespaceSelector}  routeSelector={.spec.routeSelector}{"\n"}'
```

**What just happened:** the default router listens on the node's own ports
(`HostNetwork`), for `apps-crc.testing`, and has **no selector**: it admits every
Route in the cluster. Nothing on this page changes it.

### Step 3 — a pool for the shard

The shard's Service is made by the ingress operator, not by you. An
`IngressController` has no field for that Service's annotations (`oc explain
ingresscontroller.spec.endpointPublishingStrategy.loadBalancer`), so asking for
a pool by annotation would mean editing an object the operator owns, by hand,
after it exists. Instead, [`manifests/10-pool.yaml`](manifests/10-pool.yaml)
defines a pool that **selects the Service**:

| Field | Here | Why |
|---|---|---|
| `addresses` | `192.168.127.130/32` | one address, so the shard always gets the same one. It lies outside `mongot-pool` (MetalLB refuses overlapping pools), and it is not `.1`, `.2` or `.254`, which are gvproxy's gateway, the node and the host |
| `serviceAllocation.namespaces` | `openshift-ingress` | where the operator puts router Services |
| `serviceAllocation.serviceSelectors` | `ingresscontroller.operator.openshift.io/owning-ingresscontroller: metallb` | the label the operator itself puts on the shard's Service (`load_balancer_service.go`, `desiredLoadBalancerService`) |
| `autoAssign` | `true` | MetalLB tries a pool that selects a Service only when the pool may auto-assign, and never gives a pool with `serviceAllocation` to a Service it does not select (`allocator.go`, `pinnedPoolsForService`, `Allocate`) |

`L2Advertisement ingress-shard-l2` advertises it on `br-ex`. `mongot-l2` names
only `mongot-pool`, and stays as it is.

```console
$ oc apply -f manifests/10-pool.yaml
$ oc get ipaddresspool -n metallb-system -o custom-columns=NAME:.metadata.name,ADDRESSES:.spec.addresses,AUTOASSIGN:.spec.autoAssign,ASSIGNED:.status.assignedIPv4
```

### Step 4 — the shard's certificate

A router presents its **default certificate** for every Route that brings none
of its own. [`manifests/20-certificate.yaml`](manifests/20-certificate.yaml)
asks cert-manager for `*.apps-metallb.crc.testing` from `enterprise-ca`, in
`openshift-ingress`. That is the only namespace an `IngressController` reads it
from.

```console
$ oc apply -f manifests/20-certificate.yaml
$ oc wait certificate/router-metallb-default -n openshift-ingress --for=condition=Ready --timeout=120s
```

### Step 5 — the shard

[`manifests/30-ingresscontroller.yaml`](manifests/30-ingresscontroller.yaml):

| Field | Here | Why |
|---|---|---|
| `domain` | `apps-metallb.crc.testing` | its own domain. It is not a subdomain of `apps-crc.testing`, whose names resolve inside the cluster to the default router |
| `endpointPublishingStrategy` | `LoadBalancerService`, `scope: External`, `dnsManagementPolicy: Unmanaged` | a Service of type `LoadBalancer` in front of the router; no cloud DNS to manage |
| `routeSelector` | `ingress-shard: metallb` | only Routes with that label; a Route opts in by itself, not its whole namespace |
| `replicas` | `1` | one node |
| `defaultCertificate` | `router-metallb-default-cert` | step 4 |

```console
$ oc apply -f manifests/30-ingresscontroller.yaml
$ oc wait ingresscontroller/metallb -n openshift-ingress-operator --for=condition=Available --timeout=300s
$ oc get svc router-metallb -n openshift-ingress -o jsonpath='{.spec.type}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}'
```

**What to look for:** the operator made Deployment and Service `router-metallb`
in `openshift-ingress`. `Available` waits for both the router's Deployment and
`LoadBalancerReady`, which means the Service has its address
(`status.go`, `computeIngressAvailableCondition`). The Service should show
`LoadBalancer  192.168.127.130  ingress-shard-pool`.

### Step 6 — a Route on the shard, and the default router too

[`manifests/40-canary.yaml`](manifests/40-canary.yaml) is namespace
`ingress-shard` and an edge Route `canary`, labelled `ingress-shard: metallb`,
host `canary.apps-metallb.crc.testing`, to the echo app:

```console
$ oc apply -f manifests/40-canary.yaml
$ oc apply -n ingress-shard -f ../../_shared/echo-app.yaml
$ oc rollout status deploy/echo -n ingress-shard --timeout=180s
$ oc get route canary -n ingress-shard -o jsonpath='{range .status.ingress[*]}{.routerName}  Admitted={.conditions[?(@.type=="Admitted")].status}  {.routerCanonicalHostname}{"\n"}{end}'
```

**What to look for:** the Route lists two routers, not one. `metallb` admits it
because of its label. `default` admits it because the default router has no
selector (step 2). Red Hat's docs say so: "there might be routes that are admitted
to your new Ingress shard that are also admitted by the default Ingress
Controller. This is because the default Ingress Controller has no selectors and
admits all routes by default" (4.22, "Sharding the default Ingress
Controller").

This page **accepts that** and leaves the default router alone. Step 8 shows
what the default router's copy means. To stop it, the default router would need
a `routeSelector` such as `matchExpressions: [{key: ingress-shard, operator:
DoesNotExist}]`. That is a change to the router carrying the console and OAuth,
so it is the cluster owner's decision, and it is not made here.

### Step 7 — from the laptop

The laptop does not route to the CRC network, `192.168.127.0/24`. CRC's network
proxy, gvproxy, carries the laptop's connections into it. It already forwards
`:80` and `:443` to the node, which is the default router, plus the API server
and ssh. Its API, on a unix socket, adds more. Forward a laptop port to the
shard's HTTPS port; the laptop's `:443` is taken, so this uses `20443`:

```console
$ curl -s --unix-socket ~/.crc/sockets/crc-http.sock -X POST -d '{"local":"127.0.0.1:20443","remote":"192.168.127.130:443","protocol":"tcp"}' -w '%{http_code}\n' http://crc/network/services/forwarder/expose
$ curl -s --unix-socket ~/.crc/sockets/crc-http.sock http://crc/network/services/forwarder/all | python3 -c 'import json, sys; [print(f["local"], "->", f["remote"]) for f in json.load(sys.stdin)]'
```

(Once [#15](https://github.com/ephico2real2/envoy-tutorial/issues/15) is merged,
this is `../../_shared/crc-forward.sh ensure 127.0.0.1:20443 192.168.127.130:443`.)

The name: CRC writes every Route's host into the laptop's `/etc/hosts` as
`127.0.0.1`, if it ends in `.crc.testing` or `.apps-crc.testing`. This is done by
CRC's `routes-controller` pod in `openshift-ingress` and its admin helper. So the
browser finds `canary.apps-metallb.crc.testing`, and port `20443` takes it to the
shard:

```console
$ grep -c 'canary.apps-metallb.crc.testing' /etc/hosts
$ oc get secret enterprise-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > enterprise-root-ca.pem
$ curl -sS --cacert enterprise-root-ca.pem --resolve canary.apps-metallb.crc.testing:20443:127.0.0.1 https://canary.apps-metallb.crc.testing:20443/ -w ' -> %{http_code}\n'
$ openssl s_client -connect 127.0.0.1:20443 -servername canary.apps-metallb.crc.testing </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
```

**What to look for:**

- `200` from the echo app, with `"host": "canary.apps-metallb.crc.testing:20443"`.
  The router matches a host with a port: its map lines end in `(:[0-9]+)?`.
- The certificate checked against `enterprise-ca`'s root.
- The subject `*.apps-metallb.crc.testing`: the shard's own certificate from step 4.

`--resolve` makes the command work whether or not `/etc/hosts` has the name.

### Step 8 — the default router's copy

The laptop's `:443` goes to the default router. Send it the shard's name:

```console
$ curl -sk --resolve canary.apps-metallb.crc.testing:443:127.0.0.1 https://canary.apps-metallb.crc.testing/ -o /dev/null -w '%{http_code}\n'
$ openssl s_client -connect 127.0.0.1:443 -servername canary.apps-metallb.crc.testing </dev/null 2>/dev/null | openssl x509 -noout -subject
```

**What to look for:**

- The default router serves the Route too (step 6). A host that no router admits
  gets `503` there.
- It serves it with **its** certificate, `*.apps-crc.testing`, which does not
  name this host. So a client that checks names refuses it; that is why this
  command needs `-k`.
- Inside the cluster no name leads there: `*.apps-metallb.crc.testing` does not
  resolve in a pod (`NXDOMAIN`).

### Step 9 — nothing else moved

The default router's Routes, from the laptop:

```console
$ for h in console-openshift-console oauth-openshift keycloak kiosk-modernize-demo; do printf '%-28s %s\n' "$h" "$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' https://$h.apps-crc.testing/)"; done
$ openssl s_client -connect ldaps-ldap-testing.apps-crc.testing:443 -servername ldaps-ldap-testing.apps-crc.testing </dev/null 2>/dev/null | openssl x509 -noout -subject
$ oc get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}{end}'
```

**What to look for:**

- Before this page, measured on 2026-09-27: console `200`, oauth `403`, keycloak
  `302`, kiosk `200`, and `ldaps` presenting `CN=openldap-service.ldap-testing.svc`.
- The `mongot-pool` addresses are those of step 1. The one new line is
  `router-metallb` from `ingress-shard-pool`.

### Step 10 — the address survives the operator

The operator re-creates its Service if it is deleted. The new Service carries the
same label, so the pool gives it the same address:

```console
$ oc delete svc router-metallb -n openshift-ingress
$ for i in $(seq 1 60); do ip=$(oc get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); [ "$ip" = 192.168.127.130 ] && break; sleep 2; done; oc get svc router-metallb -n openshift-ingress -o jsonpath='{.metadata.creationTimestamp}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}'
```

The ingress operator puts back only the Service annotations it manages, a fixed
list for AWS, GCP, IBM and kube-proxy (`load_balancer_service.go`,
`managedLBServiceAnnotations`, `loadBalancerServiceChanged`: "Preserve most
fields and annotations"). A pool annotation added by hand would survive its
reconcile, but not this delete. The pool's selector survives both.

### Step 11 — check yourself

```console
$ ./run.sh verify
```

## The options

**`IngressController`** (`operator.openshift.io/v1`):

| Field | Default | What it does |
|---|---|---|
| `domain` | the cluster's apps domain | the domain the router serves; a shard needs its own |
| `endpointPublishingStrategy.type` | `LoadBalancerService` on AWS, Azure, GCP, IBM Cloud and Alibaba Cloud; `HostNetwork` on every other platform, `None` (CRC) included | how clients reach the router: node ports, a `LoadBalancer` Service, a `NodePort` Service, or `Private`. It cannot be changed after creation |
| `…loadBalancer.scope` | — (required) | `External` or `Internal`: on a cloud, an internet-facing or an internal load balancer. On `None` and `BareMetal` the operator adds nothing to the Service for either (`InternalLBAnnotations`, `load_balancer_service.go`) |
| `…loadBalancer.dnsManagementPolicy` | — (required) | `Managed` makes a wildcard record in the cloud's DNS zone; `Unmanaged` leaves DNS to you |
| `routeSelector` / `namespaceSelector` | none: every Route | which Routes the router admits |
| `defaultCertificate.name` | a wildcard the operator generates, signed by its own CA | a Secret in `openshift-ingress` with `tls.crt` and `tls.key`, served for every Route without a certificate of its own |
| `replicas` | 1 on a `SingleReplica` topology (CRC), 2 on `HighlyAvailable` | router pods |

**`IPAddressPool`** (`metallb.io/v1beta1`):

| Field | Default | What it does |
|---|---|---|
| `addresses` | — | ranges or CIDRs; no two pools may overlap (the webhook refuses it) |
| `autoAssign` | `true` | whether a Service that names no pool may get an address from it |
| `serviceAllocation.namespaces`, `.namespaceSelectors`, `.serviceSelectors` | none: any Service | which Services the pool is for |
| `serviceAllocation.priority` | none | when several pools select a Service, lower wins |

## What production does differently

| Here (CRC) | Production |
|---|---|
| a gvproxy forward from `127.0.0.1:20443` | none: the address is on a network the clients route to |
| `/etc/hosts`, written by CRC for each Route | a DNS wildcard record, `*.apps-metallb.<domain>` → the shard's address |
| one address, one replica | more replicas on several nodes; MetalLB L2 moves the address to another node if one fails |
| the default router keeps the shard's Routes too | often a `routeSelector` on the default router as well, decided with whoever owns the platform's Routes |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| `admission webhook "ipaddresspoolvalidationwebhook.metallb.io" denied the request: CIDR … overlaps with already defined CIDR` | the address is in another pool (measured with `.120`) | pick an address outside every pool |
| `router-metallb` stays `<pending>`, the IngressController not `Available` | no pool gives it an address: a selecting pool with `autoAssign: false` is skipped (`allocator.go`, `pinnedPoolsForService`) | `autoAssign: true` on the selecting pool |
| `503` on `https://canary.apps-metallb.crc.testing/` | port 443 is the default router, and it does not have the Route | use port `20443` (step 7); check the Route's `status.ingress` (step 6) |
| `Failed to connect … port 20443` | no forward | step 7, or `./run.sh deploy` |
| gvproxy answers the forward with an error | another program listens on the port | `lsof -nP -iTCP:20443 -sTCP:LISTEN`; pick another port |

## Permanent lab

On the operator's CRC the shard stays: module 20's Route lives on it. Argo CD's
Application `ingress-shard`
([`../../argocd/ingress-shard.yaml`](../../argocd/ingress-shard.yaml)) keeps this
folder's `manifests/` and the echo app as they are on `main`. Like the others it
has automated sync with `automated.enabled`, `ServerSideApply`, `ServerSideDiff`
and no resources-finalizer.

| What | Made by | Kept by | Why |
|---|---|---|---|
| pool and L2 advertisement, the certificate, `IngressController metallb`, namespace `ingress-shard`, Route `canary`, the echo app | `manifests/`, `../../_shared/echo-app.yaml` | Argo CD | manifests |
| Deployment and Service `router-metallb` | the ingress operator | the ingress operator | made from the IngressController |
| the laptop's forward `127.0.0.1:20443 → 192.168.127.130:443` | `./run.sh deploy` | nobody: `run.sh` only | it lives in CRC's gvproxy, not in the cluster, and ends when the CRC VM stops. After `crc start`, run `./run.sh deploy` again |
| `/etc/hosts` lines for the Route hosts | CRC's `routes-controller` | CRC | CRC's own |

`./run.sh clean` pauses the Application before it deletes anything. `./run.sh
deploy` resumes it at its end. `./run.sh pause` and `./run.sh resume` work as in
module 16's [Permanent lab](../../16-keycloak/README.md#permanent-lab).

## Clean up

A deliberate reset only: module 20 needs the shard. Pause Argo CD first, then
remove what this page added, in reverse:

<!-- walkthrough: skip -->
```console
$ ./run.sh pause
$ curl -s --unix-socket ~/.crc/sockets/crc-http.sock -X POST -d '{"local":"127.0.0.1:20443","protocol":"tcp"}' -w '%{http_code}\n' http://crc/network/services/forwarder/unexpose
$ oc delete -f manifests/40-canary.yaml --wait=false
$ oc delete -f manifests/30-ingresscontroller.yaml
$ oc wait svc/router-metallb -n openshift-ingress --for=delete --timeout=120s
$ oc delete -f manifests/20-certificate.yaml
$ oc delete secret router-metallb-default-cert -n openshift-ingress
$ oc delete -f manifests/10-pool.yaml
$ rm -f enterprise-root-ca.pem
```

The default router, `mongot-pool`, `mongot-l2` and CRC's own forwards are not
touched.

## The shortcut

- `./run.sh deploy` does steps 3 to 7 and resumes Argo CD's Application if there
  is one.
- `./run.sh verify` is step 11: the address and its pool, which routers admit
  what, the laptop's way in, the default router's copy, and the default router's
  Routes.
- `./run.sh clean` is the clean-up, with the Application paused first.

## References

- [OpenShift 4.22 — Ingress and load balancing](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/ingress_and_load_balancing/index):
  - "Ingress sharding";
  - "Sharding the default Ingress Controller";
  - "Load balancing with MetalLB", "Configuring MetalLB address pools".
- `cluster-ingress-operator` at the commit in 4.22.7,
  [`load_balancer_service.go`](https://github.com/openshift/cluster-ingress-operator/blob/e26c93f0ffdee3272b8fc74e7f1486be25f5d59c/pkg/operator/controller/ingress/load_balancer_service.go)
  and [`status.go`](https://github.com/openshift/cluster-ingress-operator/blob/e26c93f0ffdee3272b8fc74e7f1486be25f5d59c/pkg/operator/controller/ingress/status.go).
- `openshift/metallb` release-4.22,
  [`internal/allocator/allocator.go`](https://github.com/openshift/metallb/blob/42b0bfe05fecebde1cf1ed6ef0640c35bb3cb3e7/internal/allocator/allocator.go).
- CRC [`routes-controller`](https://github.com/crc-org/routes-controller/blob/8bd46c59f96cf334c689856f1adddc248d544ffb/pkg/routes-handler/routes-handler.go)
  and [`admin-helper` hosts filter](https://github.com/crc-org/admin-helper/blob/c95d01e82bcfe22db5095018eb57f4d692cfa55a/pkg/hosts/hosts.go).
