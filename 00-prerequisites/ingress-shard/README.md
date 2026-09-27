# A second router on a MetalLB address — an IngressController shard

> **Output blocks not pasted yet.** `./run.sh deploy` and `./run.sh verify` were
> walked on CRC on 2026-09-27; the measurements this page quotes come from that
> walk. The commands below are those steps, one by one. Their output is pasted by
> `python3 tooling/walkthrough/run.py 00-prerequisites/ingress-shard/README.md --update`,
> run from a clean shard (`./run.sh clean` first).

OpenShift's own router, the **default IngressController**, carries every Route on
this cluster: the console, OAuth, Keycloak, the kiosk. On CRC it listens on the
node's own ports 80 and 443 (`HostNetwork`).

This page adds a **second router**, a *shard*, which:

- serves only the Routes that ask for it, through a label;
- has **its own address**, `192.168.127.130`, which MetalLB gives it.

It also gives the default router one selector, so that it **stops serving** the
Routes meant for the shard. That change restarts the default router, and every
Route on the cluster is down for about half a minute: step 5 says why, and
when to do it.

Module 20 puts its Route here
([#16](https://github.com/ephico2real2/envoy-tutorial/issues/16)). Module 19 puts
its Gateway on a MetalLB address. The laptop reaches both the same way, through
CRC's network proxy.

## What you'll learn

- how an `IngressController` shard picks its Routes (`routeSelector`);
- why the default router admits those Routes too unless it is told not to, and
  what telling it costs on a single-node cluster;
- how a router published as a `LoadBalancerService` gets a MetalLB address. The
  address is chosen by a pool, so nothing has to be added to a Service the
  ingress operator owns;
- why a laptop running CRC needs a port forward to reach that address, and why
  bare metal does not.

## Before you start

- Module [`00`](../README.md)'s `check.sh` passes, including MetalLB and the
  `enterprise-ca` ClusterIssuer.
- You are a cluster admin. This adds an `IngressController`, a MetalLB pool and
  a certificate in `openshift-ingress`, and changes the **default**
  IngressController (step 5).
- **Step 5 takes every Route down for about 30 seconds** on a single-node
  cluster: the console, OAuth logins, Keycloak, every app. Pick a moment when
  nobody depends on them. `./run.sh deploy` does the same, and so does the
  clean-up when it reverses it.
- **OpenSSL 3** on your laptop (`brew install openssl`), as in module 18.
- Work from this folder: `cd 00-prerequisites/ingress-shard`.
- It uses the namespace **`ingress-shard`** for its canary Route and takes about
  10 minutes. On the operator's CRC it is **permanent**, kept by Argo CD: see
  [Permanent lab](#permanent-lab) before you change anything by hand there.

## The picture

<!-- Figure to come (the /visual skill): the laptop's 127.0.0.1:20443 and CRC's :443
     at the top; gvproxy; 192.168.127.130 (router-metallb, MetalLB L2 on br-ex) and
     192.168.127.2 (router-default, HostNetwork, routeSelector ingress-shard
     DoesNotExist) side by side; Route canary admitted by router-metallb only, 503
     on :443; the echo app at the bottom. -->

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
Services listed asked for it: `mongodb-poc`'s and the Gateways of modules 17 and
19. `mongot-l2` advertises the pool at layer 2 on `br-ex`, the node's interface
on the CRC network: the node answers ARP for those addresses.

### Step 2 — the default router

```console
$ oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.endpointPublishingStrategy.type}  {.status.domain}  namespaceSelector={.spec.namespaceSelector}  routeSelector={.spec.routeSelector}{"\n"}'
$ oc get deploy router-default -n openshift-ingress -o jsonpath='replicas={.spec.replicas}  hostNetwork={.spec.template.spec.hostNetwork}  strategy={.spec.strategy.rollingUpdate}{"\n"}'
```

**What just happened:**

- The default router listens on the node's own ports (`HostNetwork`), for
  `apps-crc.testing`.
- It has **no selector**, so it admits every Route in the cluster, whatever the
  host's domain. Red Hat's docs: "there might be routes that are admitted to your
  new Ingress shard that are also admitted by the default Ingress Controller.
  This is because the default Ingress Controller has no selectors and admits all
  routes by default" (4.22, "Sharding the default Ingress Controller").
- It runs **one** pod, and a rolling update may not add a pod
  (`maxSurge: 0`). Step 5 is where that matters.

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

### Step 5 — keep the default router off the shard's Routes

A shard Route admitted by both routers is served twice: by the shard on its
address, and by the default router on the node's `:443`, with the default
router's certificate, which is for another domain. The default router is told to
ignore every Route labelled `ingress-shard`, the label that the shard selects on
(step 6). This is done **before** the first such Route exists, so the default
router never admits it.

First, check that no existing Route carries the label. The selector drops
exactly those, so the answer must be `0`:

```console
$ oc get routes -A -l ingress-shard --no-headers | wc -l
```

> **Outage.** Changing the default IngressController makes the ingress operator
> roll out a new `router-default`.
>
> - **Why it goes down:** here it is one pod on the node's own ports 80 and 443
>   (`HostNetwork`), and the rollout may not add a pod (`maxSurge: 0`, step 2).
>   So the old pod must stop, and free the ports, before the new one can bind
>   them. Until the new pod is ready, **no Route answers**: console, OAuth,
>   Keycloak, every app.
> - **Measured on CRC** (2026-09-27, probing every second): console and Keycloak
>   answered `000` from 16:29:52 to 16:30:23 UTC, about **31 seconds**.
> - **The same happens again** when the clean-up removes the selector.

The selector, and a wait for the new router pod. The operator passes the
selector to the router as its `ROUTE_LABELS` variable, so the wait watches for
that value, then for the rollout:

```console
$ oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p '{"spec":{"routeSelector":{"matchExpressions":[{"key":"ingress-shard","operator":"DoesNotExist"}]}}}'
$ for i in $(seq 1 60); do [ "$(oc get deploy router-default -n openshift-ingress -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROUTE_LABELS")].value}')" = '!ingress-shard' ] && break; sleep 2; done; oc rollout status deploy/router-default -n openshift-ingress --timeout=300s
$ oc get deploy router-default -n openshift-ingress -o jsonpath='ROUTE_LABELS={.spec.template.spec.containers[0].env[?(@.name=="ROUTE_LABELS")].value}  generation={.metadata.generation}{"\n"}'
```

**What just happened:**

- The default router now admits only Routes **without** an `ingress-shard`
  label. `!ingress-shard` is the label-selector form of `DoesNotExist`.
- No Route had the label, so none left the default router. Step 10 checks that
  they all still answer.
- This is the change Red Hat's docs describe as "Sharding the default Ingress
  Controller". They also warn: "You must keep all of OpenShift Container
  Platform's administration routes on the same Ingress Controller". A selector
  that excludes only one label, which none of those Routes carry, does that.
- Patching again with the same selector changes nothing: measured, a second
  `./run.sh deploy` left `router-default` at generation 2, and nothing restarted.

### Step 6 — the shard

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

**What to look for:**

- The operator made Deployment and Service `router-metallb` in
  `openshift-ingress`.
- `Available` waits for both the router's Deployment and `LoadBalancerReady`,
  which means the Service has its address (`status.go`,
  `computeIngressAvailableCondition`).
- The Service shows `LoadBalancer  192.168.127.130  ingress-shard-pool`.
- This router is a new pod on the pod network, not on the node's ports, so
  nothing else restarts.

### Step 7 — a Route on the shard, and on the shard only

[`manifests/40-canary.yaml`](manifests/40-canary.yaml) holds namespace
`ingress-shard` and an edge Route `canary`, labelled `ingress-shard: metallb`,
host `canary.apps-metallb.crc.testing`, to the echo app:

```console
$ oc apply -f manifests/40-canary.yaml
$ oc apply -n ingress-shard -f ../../_shared/echo-app.yaml
$ oc rollout status deploy/echo -n ingress-shard --timeout=180s
$ oc get route canary -n ingress-shard -o jsonpath='{range .status.ingress[*]}{.routerName}  Admitted={.conditions[?(@.type=="Admitted")].status}  {.routerCanonicalHostname}{"\n"}{end}'
```

**What to look for:** one router, `metallb`. The shard admits the Route because
of its label, and the default router does not list it at all, because of
step 5. Without step 5 the Route would list `default` as well.

### Step 8 — from the laptop

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

**The name.** CRC's `routes-controller` pod in `openshift-ingress` writes every
Route's host into the laptop's `/etc/hosts` as `127.0.0.1`, through CRC's admin
helper. The helper accepts only hosts ending in `.crc.testing` or
`.apps-crc.testing`, which is one reason for this domain. Measured: the canary's
host appeared there, and a browser or `curl` finds it by name. Port `20443`
takes it to the shard:

```console
$ grep -o 'canary.apps-metallb.crc.testing' /etc/hosts
$ oc get secret enterprise-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > enterprise-root-ca.pem
$ curl -sS --cacert enterprise-root-ca.pem https://canary.apps-metallb.crc.testing:20443/ -w ' -> %{http_code}\n'
$ openssl s_client -connect 127.0.0.1:20443 -servername canary.apps-metallb.crc.testing </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
```

**What to look for:**

- `200` from the echo app, with `"host": "canary.apps-metallb.crc.testing:20443"`.
  The router matches a host with a port: its map lines end in `(:[0-9]+)?`.
- The certificate is checked against `enterprise-ca`'s root.
- The subject is `*.apps-metallb.crc.testing`: the shard's own certificate from
  step 4.

### Step 9 — the laptop's `:443` does not serve it

The laptop's `:443` goes to the default router. Send it the shard's name:

```console
$ curl -sk https://canary.apps-metallb.crc.testing/ -o /dev/null -w '%{http_code}\n'
```

**What to look for:** `503`, the default router's answer for a host it has not
admitted (step 5). `-k`, because the default router's certificate is for
`*.apps-crc.testing`. Inside the cluster no name leads to the default router
either: `*.apps-metallb.crc.testing` does not resolve in a pod (`NXDOMAIN`). From
the laptop, the shard's port `20443` is the only way to the canary.

### Step 10 — nothing else moved

The default router's Routes, from the laptop:

```console
$ for h in console-openshift-console oauth-openshift keycloak kiosk-modernize-demo; do printf '%-28s %s\n' "$h" "$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' https://$h.apps-crc.testing/)"; done
$ openssl s_client -connect ldaps-ldap-testing.apps-crc.testing:443 -servername ldaps-ldap-testing.apps-crc.testing </dev/null 2>/dev/null | openssl x509 -noout -subject
$ oc get routes -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}  {range .status.ingress[*]}{.routerName}={.conditions[?(@.type=="Admitted")].status} {end}{"\n"}{end}'
$ oc get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}{end}'
```

**What to look for:**

- The same answers as before this page, measured on 2026-09-27: console `200`,
  oauth `403`, keycloak `302`, kiosk `200`, and `ldaps` presenting
  `CN=openldap-service.ldap-testing.svc`.
- Every Route says `default=True`, except `ingress-shard/canary`, which says
  `metallb=True`.
- The `mongot-pool` addresses are those of step 1. The one new line is
  `router-metallb` from `ingress-shard-pool`.

### Step 11 — the address survives the operator

The operator re-creates its Service if it is deleted. The new Service carries the
same label, so the pool gives it the same address. Only the shard is affected:
the default router is not touched.

```console
$ oc delete svc router-metallb -n openshift-ingress
$ for i in $(seq 1 60); do ip=$(oc get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); [ "$ip" = 192.168.127.130 ] && break; sleep 2; done; oc get svc router-metallb -n openshift-ingress -o jsonpath='{.metadata.creationTimestamp}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}'
```

The ingress operator puts back only the Service annotations it manages, a fixed
list for AWS, GCP, IBM and kube-proxy (`load_balancer_service.go`,
`managedLBServiceAnnotations`, `loadBalancerServiceChanged`: "Preserve most
fields and annotations"). A pool annotation added by hand would survive its
reconcile, but not this delete. The pool's selector survives both.

### Step 12 — check yourself

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
| `routeSelector` / `namespaceSelector` | none: every Route | which Routes the router admits. On the shard: `matchLabels` to take its Routes; on the default router: `DoesNotExist` to leave them (step 5). Changing either rolls out that router |
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
| one shard address, one replica | more replicas on several nodes; MetalLB layer 2 moves the address to another node if one fails |
| the default router's selector costs a ~31 s outage: one `HostNetwork` pod that must stop before its replacement can bind the ports | the default router runs a pod on each of several nodes, and the load balancer in front of them sends traffic to the ones still serving. Not measured here: this cluster has one node. The selector is still a change to the router that carries the console and OAuth, so it goes through that router's owner and a change window |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| console, OAuth, every Route answers `000` or refuses connections for about half a minute | the default router is rolling out after a change to its IngressController: step 5, `./run.sh deploy` the first time, or the clean-up | wait: `oc rollout status deploy/router-default -n openshift-ingress` |
| `IngressController default already has routeSelector … - left alone` from `./run.sh deploy` | someone gave the default router a selector of their own; `run.sh` does not merge selectors | decide with whoever set it; step 5's selector must be combined with theirs by hand |
| a Route that should be on the default router stops answering after step 5 | it carries an `ingress-shard` label | remove the label, or move the Route to the shard's domain on purpose |
| `admission webhook "ipaddresspoolvalidationwebhook.metallb.io" denied the request: CIDR … overlaps with already defined CIDR` | the address is in another pool (measured with `.120`) | pick an address outside every pool |
| `router-metallb` stays `<pending>`, the IngressController not `Available` | no pool gives it an address: a selecting pool with `autoAssign: false` is skipped (`allocator.go`, `pinnedPoolsForService`) | `autoAssign: true` on the selecting pool |
| `503` on `https://canary.apps-metallb.crc.testing/` | port 443 is the default router, which ignores the shard's Routes (step 9) | use port `20443` (step 8) |
| `Failed to connect … port 20443` | no forward | step 8, or `./run.sh deploy` |
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
| **the default router's `routeSelector`** (step 5) | `./run.sh deploy` | nobody: `run.sh` only | the default IngressController is the platform's, not this lab's. An Application that owned it could prune it, which would delete the router every Route depends on, and would put its own copy of the object back over any other change to it. `run.sh` adds the one field, only if the router has no selector yet, and `clean` removes it only if it is still exactly this one. `./run.sh verify` checks that it is there |
| Deployment and Service `router-metallb` | the ingress operator | the ingress operator | made from the IngressController |
| the laptop's forward `127.0.0.1:20443 → 192.168.127.130:443` | `./run.sh deploy` | nobody: `run.sh` only | it lives in CRC's gvproxy, not in the cluster, and ends when the CRC VM stops. After `crc start`, run `./run.sh deploy` again |
| `/etc/hosts` lines for the Route hosts | CRC's `routes-controller` | CRC | CRC's own |

`./run.sh clean` pauses the Application before it deletes anything, and
`./run.sh deploy` resumes it at its end. `./run.sh pause` and `./run.sh resume`
work as in module 16's [Permanent lab](../../16-keycloak/README.md#permanent-lab).

## Clean up

This is a deliberate reset only: module 20 needs the shard. Pause Argo CD first,
then remove what this page added, in reverse. The canary goes **before** the
default router's selector does, so the default router never admits it.

> **Outage, again.** Removing the selector rolls out `router-default` the same way
> step 5 did: expect every Route to be down for about 30 seconds.

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
$ oc patch ingresscontroller default -n openshift-ingress-operator --type=json -p '[{"op":"remove","path":"/spec/routeSelector"}]'
$ for i in $(seq 1 60); do [ -z "$(oc get deploy router-default -n openshift-ingress -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROUTE_LABELS")].value}')" ] && break; sleep 2; done; oc rollout status deploy/router-default -n openshift-ingress --timeout=300s
$ rm -f enterprise-root-ca.pem
```

`./run.sh clean` does all of this. It removes the selector only when it is still
exactly step 5's, and leaves one set by someone else. `mongot-pool`,
`mongot-l2` and CRC's own forwards are not touched.

## The shortcut

- `./run.sh deploy` does steps 3 to 8 and resumes Argo CD's Application if there
  is one. It includes step 5's outage the first time; a second `deploy` leaves the
  default router alone (measured).
- `./run.sh verify` is step 12. It checks:
  - the address and its pool;
  - the default router's selector;
  - which routers admit what: the canary on the shard alone, every other Route
    on the default router;
  - the laptop's way in;
  - `503` on `:443`;
  - the default router's Routes.
- `./run.sh clean` is the clean-up, with the Application paused first, and step
  5's outage once more.

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
