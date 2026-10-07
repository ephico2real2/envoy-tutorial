# A second router on a MetalLB address — an IngressController shard

OpenShift's own router, the **default IngressController**, carries every Route on
this cluster except the ones this page moves to the shard: the console, OAuth,
Keycloak, the kiosk. On CRC it listens on the
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
- why a laptop running CRC needs a port forward to reach that address, and why a
  client that can route to the address does not.

## Before you start

- Module [`00`](../README.md)'s `check.sh` passes, including MetalLB and the
  `enterprise-ca` ClusterIssuer. How MetalLB was installed, and its pool
  `mongot-pool` (step 1): [`../metallb/`](../metallb/README.md).
- You are a cluster admin. This adds an `IngressController`, a MetalLB pool and
  a certificate in `openshift-ingress`, and changes the **default**
  IngressController (step 5).
- **Step 5 takes every Route down for about half a minute** (31 s, measured) on a
  single-node cluster: the console, OAuth logins, Keycloak, every app. Pick a
  moment when nobody depends on them. `./run.sh deploy` does the same the first
  time. The clean-up does not undo step 5, on purpose ([Clean up](#clean-up)
  says why).
- **OpenSSL 3** on your laptop (`brew install openssl`), as in module 18.
- Work from this folder: `cd 00-prerequisites/ingress-shard`.
- It uses the namespace **`ingress-shard`** for its canary Route and takes about
  10 minutes. On the operator's CRC it is **permanent**, kept by Argo CD: see
  [Permanent lab](#permanent-lab) before you change anything by hand there.

## The picture

<!-- markdownlint-disable MD033 -->
<img alt="The laptop reaches two routers through CRC&#x27;s network proxy, gvproxy, because it has no route to the CRC network 192.168.127.0/24. Port 443 is CRC&#x27;s own forward to 192.168.127.2, the node, where router-default of IngressController default listens on the node&#x27;s ports 80 and 443 (HostNetwork). 127.0.0.1:20443 is a forward that ./run.sh deploy adds through gvproxy&#x27;s forwarder API, to 192.168.127.130:443, which MetalLB announces at layer 2 on br-ex: the LoadBalancer Service of router-metallb, IngressController metallb, a pod on the pod network, domain apps-metallb.crc.testing. Beside each router, what configures it: on default, routeSelector ingress-shard DoesNotExist, set by ./run.sh deploy and not by Argo CD, kept by clean, and adding it took every Route down for 31 seconds, removing it later for 98 seconds; on metallb, IPAddressPool ingress-shard-pool with the single address 192.168.127.130/32, autoAssign true, and a serviceAllocation that selects, by label, LoadBalancer Services in openshift-ingress carrying the label the ingress operator puts on the router&#x27;s Service, owning-ingresscontroller metallb, plus L2Advertisement ingress-shard-l2 on br-ex; routeSelector ingress-shard: metallb; and Certificate router-metallb-default for *.apps-metallb.crc.testing from ClusterIssuer enterprise-ca, the router&#x27;s default certificate. router-default admits every Route without an ingress-shard label: 21 Routes, among them console 200, oauth 403, keycloak 302, kiosk 200 and ldaps by SNI. The canary&#x27;s host sent to port 443 gets 503: the default router has not admitted it, and its certificate is for *.apps-crc.testing. router-metallb admits only Routes labelled ingress-shard=metallb: Route canary in namespace ingress-shard, edge TLS, admitted by metallb only, to the echo app, which answers 200. The laptop finds canary.apps-metallb.crc.testing as 127.0.0.1 in /etc/hosts, written by CRC&#x27;s routes-controller for Route hosts ending in .crc.testing or .apps-crc.testing. All measured on CRC on 2026-09-27." src="../../docs/diagrams/ingress-shard/shard.light.png">
<!-- markdownlint-enable MD033 -->

*The laptop reaches the default router on CRC's `:443` and the shard on
`127.0.0.1:20443`, both through gvproxy. The label `ingress-shard=metallb` puts
a Route on the shard, at its MetalLB address, and takes it off the default
router. The grey boxes are the objects that configure the box they point at.*

## Walkthrough

### Step 1 — MetalLB, as it is

```console
$ oc get ipaddresspool,l2advertisement -n metallb-system
NAME                                   AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
ipaddresspool.metallb.io/mongot-pool   false         false             ["192.168.127.100-192.168.127.120"]

NAME                                   IPADDRESSPOOLS    IPADDRESSPOOL SELECTORS   INTERFACES
l2advertisement.metallb.io/mongot-l2   ["mongot-pool"]                             ["br-ex"]
$ oc get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}{end}'
envoy-gateway-system/envoy-envoy-17-eg-0d84cb63  192.168.127.101  mongot-pool
envoy-gateway-system/envoy-envoy-19-eg-413e95da  192.168.127.102  mongot-pool
mongodb-poc/mongot-grpc-lb  192.168.127.100  mongot-pool
```

**What just happened:** there is one pool, `mongot-pool`, holding
`192.168.127.100` to `.120`, with `autoAssign: false`. With that setting a
Service must explicitly request the pool by name, in the annotation
`metallb.io/address-pool` (or the older `metallb.universe.tf/…`), or request an
IP within it through `metallb.io/loadBalancerIPs` (or deprecated
`spec.loadBalancerIP`). The
Services listed asked for it: `mongodb-poc`'s and the Gateways of modules 17 and
19. `mongot-l2` advertises the pool at layer 2 on `br-ex`, the node's interface
on the CRC network: the node answers ARP for those addresses.

### Step 2 — the default router

```console
$ oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.endpointPublishingStrategy.type}  {.status.domain}  namespaceSelector={.spec.namespaceSelector}  routeSelector={.spec.routeSelector}{"\n"}'
HostNetwork  apps-crc.testing  namespaceSelector=  routeSelector={"matchExpressions":[{"key":"ingress-shard","operator":"DoesNotExist"}]}
$ oc get deploy router-default -n openshift-ingress -o jsonpath='replicas={.spec.replicas}  hostNetwork={.spec.template.spec.hostNetwork}  strategy={.spec.strategy.rollingUpdate}{"\n"}'
replicas=1  hostNetwork=true  strategy={"maxSurge":0,"maxUnavailable":"25%"}
```

**What just happened:**

- The default router listens on the node's own ports (`HostNetwork`), for
  `apps-crc.testing`.
- It already has a `routeSelector`, `ingress-shard DoesNotExist`: this page
  was walked on a cluster where step 5 had run before, and the clean-up leaves
  that field in place ([Clean up](#clean-up) says why). The default router
  admits every Route **without** an `ingress-shard` label, whatever the host's
  domain.
- On a cluster where this page never ran, the same command prints
  `routeSelector=` with nothing after it: **no selector**, so the default router
  admits every Route. Red Hat's docs: "there might be routes that are admitted to
  your new Ingress shard that are also admitted by the default Ingress
  Controller. This is because the default Ingress Controller has no selectors and
  admits all routes by default" (4.22, "Sharding the default Ingress
  Controller"). Step 5 adds the selector there, and does nothing where it is
  already this one.
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
| `autoAssign` | `true` | MetalLB tries a pool that selects a Service only when the pool may auto-assign, and never auto-assigns from a pool with `serviceAllocation` to a Service it does not select (`allocator.go`, `pinnedPoolsForService`, `Allocate`) |

The selection is by **label**, not by name. Any `LoadBalancer` Service in
`openshift-ingress` with that label is eligible for the address; `router-metallb`
is the only one there (step 10), and only someone who may create Services in
`openshift-ingress` could add another. An explicit pool or IP request must also
match `serviceAllocation`: at MetalLB commit `42b0bfe`, `AllocateFromPool` calls
`Assign`, which checks `isPoolCompatibleWithService`. Naming this pool does not
bypass its namespace and Service selectors.

`L2Advertisement ingress-shard-l2` advertises it on `br-ex`. `mongot-l2` names
only `mongot-pool`, and stays as it is.

```console
$ oc apply -f manifests/10-pool.yaml
ipaddresspool.metallb.io/ingress-shard-pool created
l2advertisement.metallb.io/ingress-shard-l2 created
$ oc get ipaddresspool -n metallb-system -o custom-columns=NAME:.metadata.name,ADDRESSES:.spec.addresses,AUTOASSIGN:.spec.autoAssign,ASSIGNED:.status.assignedIPv4
NAME                 ADDRESSES                           AUTOASSIGN   ASSIGNED
ingress-shard-pool   [192.168.127.130/32]                true         0
mongot-pool          [192.168.127.100-192.168.127.120]   false        3
```

### Step 4 — the shard's certificate

A router presents its **default certificate** for every Route that brings none
of its own. [`manifests/20-certificate.yaml`](manifests/20-certificate.yaml)
asks cert-manager for `*.apps-metallb.crc.testing` from `enterprise-ca`, in
`openshift-ingress`. That is the only namespace an `IngressController` reads it
from.

```console
$ oc apply -f manifests/20-certificate.yaml
certificate.cert-manager.io/router-metallb-default created
$ oc wait certificate/router-metallb-default -n openshift-ingress --for=condition=Ready --timeout=120s
certificate.cert-manager.io/router-metallb-default condition met
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
No resources found
       0
```

> **Outage.** Changing the default IngressController makes the ingress operator
> roll out a new `router-default`.
>
> - **Why it goes down:** here it is one pod on the node's own ports 80 and 443
>   (`HostNetwork`), and the rollout may not add a pod (`maxSurge: 0`, step 2).
>   So the old pod must stop, and free the ports, before the new one can bind
>   them. Until the new pod is ready, **no Route answers**: console, OAuth,
>   Keycloak, every app.
> - **Measured on CRC** (2026-09-27, probing every second): adding the selector
>   took console and Keycloak to `000` from 16:29:52 to 16:30:23 UTC, about
>   **31 seconds**. **Removing** it later (the incident in [Clean up](#clean-up))
>   rolled the same router out again, and it was down **98 seconds**
>   (16:38:08–16:39:46): the new pod waited 47 s to be scheduled
>   (`FailedScheduling … didn't have free ports`) until the old one let go of 80
>   and 443. That removal is one reason the clean-up leaves the field.
> - **It happens once.** The clean-up leaves the selector in place (below).

The selector, and a wait for the new router pod. The operator passes the
selector to the router as its `ROUTE_LABELS` variable, so the wait watches for
that value, then for the rollout:

```console
$ oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p '{"spec":{"routeSelector":{"matchExpressions":[{"key":"ingress-shard","operator":"DoesNotExist"}]}}}'
ingresscontroller.operator.openshift.io/default patched (no change)
$ for i in $(seq 1 60); do [ "$(oc get deploy router-default -n openshift-ingress -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROUTE_LABELS")].value}')" = '!ingress-shard' ] && break; sleep 2; done; oc rollout status deploy/router-default -n openshift-ingress --timeout=300s
deployment "router-default" successfully rolled out
$ oc get deploy router-default -n openshift-ingress -o jsonpath='ROUTE_LABELS={.spec.template.spec.containers[0].env[?(@.name=="ROUTE_LABELS")].value}  generation={.metadata.generation}{"\n"}'
ROUTE_LABELS=!ingress-shard  generation=4
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
- Patching again with the same selector rolls neither router and changes no
  router generation: measured, a second `./run.sh deploy` left `router-default`
  at generation 2, and later at 4 (after the incident in [Clean up](#clean-up)).
  `./run.sh deploy` does not patch at all when the selector is already this one.
- `./run.sh deploy` also refuses to add the selector while any Route already
  carries an `ingress-shard` label, and names them: the selector would take
  those Routes off the default router. The first command above is that check.

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
ingresscontroller.operator.openshift.io/metallb created
$ oc wait ingresscontroller/metallb -n openshift-ingress-operator --for=condition=Available --timeout=300s
ingresscontroller.operator.openshift.io/metallb condition met
$ oc get svc router-metallb -n openshift-ingress -o jsonpath='{.spec.type}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}'
LoadBalancer  192.168.127.130  ingress-shard-pool
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
namespace/ingress-shard created
route.route.openshift.io/canary created
$ oc apply -n ingress-shard -f ../../_shared/echo-app.yaml
configmap/echo-src created
service/echo created
deployment.apps/echo created
$ oc rollout status deploy/echo -n ingress-shard --timeout=180s
Waiting for deployment "echo" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "echo" rollout to finish: 1 of 2 updated replicas are available...
deployment "echo" successfully rolled out
$ oc get route canary -n ingress-shard -o jsonpath='{range .status.ingress[*]}{.routerName}  Admitted={.conditions[?(@.type=="Admitted")].status}  {.routerCanonicalHostname}{"\n"}{end}'
metallb  Admitted=True  router-metallb.apps-metallb.crc.testing
```

**What to look for:** one router, `metallb`. The shard admits the Route because
of its label, and the default router does not list it at all, because of
step 5. Without step 5 the Route would list `default` as well.

### Step 8 — from the laptop

The laptop does not route to the CRC network, `192.168.127.0/24`. CRC's network
proxy, gvproxy, carries the laptop's connections into it. It already forwards
`:80` and `:443` to the node, which is the default router, plus the API server
and ssh. Its API, on a unix socket, adds more;
[`../../_shared/crc-forward.sh`](../../_shared/crc-forward.sh) asks it (#15): it
checks nothing on the laptop listens on the port first, does nothing when the same
forward is there, refuses one that points elsewhere, and never touches CRC's own.
Forward a laptop port to the shard's HTTPS port; the laptop's `:443` is taken, so
this uses `20443`:

```console
$ ../../_shared/crc-forward.sh ensure 127.0.0.1:20443 192.168.127.130:443
127.0.0.1:20443 -> 192.168.127.130:443: forwarded
$ ../../_shared/crc-forward.sh list
/Users/olasumbo/.crc/machines/crc/docker.sock -> ssh-tunnel://core@192.168.127.2:22/run/podman/podman.sock?key=%2FUsers%2Folasumbo%2F.crc%2Fmachines%2Fcrc%2Fid_ed25519
127.0.0.1:19080 -> 192.168.127.102:80
127.0.0.1:20443 -> 192.168.127.130:443
127.0.0.1:2222 -> 192.168.127.2:22
127.0.0.1:6443 -> 192.168.127.2:6443
:443 -> 192.168.127.2:443
:80 -> 192.168.127.2:80
```

**The name.** CRC's `routes-controller` pod in `openshift-ingress` writes Route
hosts into the laptop's `/etc/hosts` as `127.0.0.1`, through CRC's admin helper,
for hosts ending in `.crc.testing` or `.apps-crc.testing`: the helper refuses
any other. That is one reason for this domain. Measured: the canary's
host appeared there, and a browser or `curl` finds it by name. Port `20443`
takes it to the shard:

```console
$ grep -o 'canary.apps-metallb.crc.testing' /etc/hosts
canary.apps-metallb.crc.testing
$ oc get secret enterprise-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > enterprise-root-ca.pem
$ for i in $(seq 1 30); do [ "$(curl -s -o /dev/null --max-time 5 --cacert enterprise-root-ca.pem -w '%{http_code}' https://canary.apps-metallb.crc.testing:20443/)" = 200 ] && break; sleep 2; done
$ curl -sS --cacert enterprise-root-ca.pem https://canary.apps-metallb.crc.testing:20443/ -w ' -> %{http_code}\n'
{
  "served_by": "echo-f8fc6d5c9-rmd9c",
  "method": "GET",
  "path": "/",
  "headers": {
    "user-agent": "curl/8.7.1",
    "accept": "*/*",
    "host": "canary.apps-metallb.crc.testing:20443",
    "x-forwarded-host": "canary.apps-metallb.crc.testing:20443",
    "x-forwarded-port": "443",
    "x-forwarded-proto": "https",
    "forwarded": "for=192.168.127.1;host=canary.apps-metallb.crc.testing:20443;proto=https",
    "x-forwarded-for": "192.168.127.1"
  }
} -> 200
$ openssl s_client -connect 127.0.0.1:20443 -servername canary.apps-metallb.crc.testing </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
subject=CN=*.apps-metallb.crc.testing
issuer=O=Enterprise POC, CN=Enterprise Root CA
```

The loop waits for the first `200`. A new router serves a Route a few seconds
after the Route's pods are ready; a request inside that gap gets the router's
`503` page (it happened on this page's first walk).

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
503
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
console-openshift-console    200
oauth-openshift              403
keycloak                     302
kiosk-modernize-demo         200
$ openssl s_client -connect ldaps-ldap-testing.apps-crc.testing:443 -servername ldaps-ldap-testing.apps-crc.testing </dev/null 2>/dev/null | openssl x509 -noout -subject
subject=CN=openldap-service.ldap-testing.svc
$ oc get routes -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}  {range .status.ingress[*]}{.routerName}={.conditions[?(@.type=="Admitted")].status} {end}{"\n"}{end}'
group-sync-dashboard/grafana-openshift-grafana  default=True 
group-sync-dashboard/group-sync-dashboard  default=True 
ingress-shard/canary  metallb=True 
keycloak/keycloak  default=True 
ldap-testing/ldap-route  default=True 
ldap-testing/ldaps  default=True 
ldap-testing/phpldapadmin-route  default=True 
modernize-demo/kiosk  default=True 
mongodb-poc/mongot-grpc  default=True 
mongodb-poc/mongot-gui  default=True 
openshift-authentication/oauth-openshift  default=True 
openshift-console/console  default=True 
openshift-console/downloads  default=True 
openshift-gitops/openshift-gitops-server  default=True 
openshift-image-registry/default-route  default=True 
openshift-ingress-canary/canary  default=True 
openshift-monitoring/alertmanager-main  default=True 
openshift-monitoring/prometheus-k8s  default=True 
openshift-monitoring/prometheus-k8s-federate  default=True 
openshift-monitoring/thanos-querier  default=True 
openshift-user-workload-monitoring/federate  default=True 
openshift-user-workload-monitoring/thanos-ruler  default=True 
$ oc get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}{end}'
envoy-gateway-system/envoy-envoy-17-eg-0d84cb63  192.168.127.101  mongot-pool
envoy-gateway-system/envoy-envoy-19-eg-413e95da  192.168.127.102  mongot-pool
mongodb-poc/mongot-grpc-lb  192.168.127.100  mongot-pool
openshift-ingress/router-metallb  192.168.127.130  ingress-shard-pool
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
service "router-metallb" deleted from openshift-ingress namespace
$ for i in $(seq 1 60); do ip=$(oc get svc router-metallb -n openshift-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); [ "$ip" = 192.168.127.130 ] && break; sleep 2; done; oc get svc router-metallb -n openshift-ingress -o jsonpath='{.metadata.creationTimestamp}  {.status.loadBalancer.ingress[0].ip}  {.metadata.annotations.metallb\.io/ip-allocated-from-pool}{"\n"}'
2026-09-27T20:50:44Z  192.168.127.130  ingress-shard-pool
```

The ingress operator puts back only the Service annotations it manages, a fixed
list for AWS, GCP, IBM and kube-proxy (`load_balancer_service.go`,
`managedLBServiceAnnotations`, `loadBalancerServiceChanged`: "Preserve most
fields and annotations"). A pool annotation added by hand would survive its
reconcile, but not this delete. The pool's selector survives both.

### Step 12 — check yourself

```console
$ ./run.sh verify

1. the address
  ✓ pool ingress-shard-pool holds 192.168.127.130 only
  ✓ ...autoAssign: true (MetalLB tries a selecting pool only then)
  ✓ ...for Services in openshift-ingress
  ✓ ...labelled owning-ingresscontroller=metallb
  ✓ L2Advertisement ingress-shard-l2 advertises ingress-shard-pool
  ✓ ...on br-ex
  ✓ IngressController metallb serves apps-metallb.crc.testing
  ✓ ...published as a LoadBalancerService
  ✓ ...with External scope
  ✓ ...and unmanaged DNS
  ✓ ...with one replica
  ✓ ...admitting Routes labelled ingress-shard=metallb
  ✓ ...with the default certificate router-metallb-default-cert
  ✓ IngressController metallb is Available
  ✓ ...and its load balancer is ready
  ✓ router-metallb has 192.168.127.130
  ✓ ...from ingress-shard-pool
  ✓ no other Service holds an address from ingress-shard-pool

2. which router admits what
  ✓ the default router ignores Routes labelled ingress-shard
  ✓ canary is admitted by the shard alone
  ✓ the shard admits only Routes labelled ingress-shard=metallb
  ✓ the default router admits no Route labelled ingress-shard
  ✓ every other Route is still admitted by the default router

3. from this machine
  ✓ 127.0.0.1:20443 forwards to 192.168.127.130:443
  ✓ https://canary.apps-metallb.crc.testing:20443/ at 127.0.0.1:20443 -> 200, the certificate checked against enterprise-ca
  ✓ ...answered by the echo app behind the canary Route
  ✓ ...with the shard's certificate
  ✓ on :443 the default router does not serve the canary

4. the default router's Routes still answer from this laptop
  ✓ console
  ✓ oauth
  ✓ keycloak
  ✓ kiosk
  ✓ ldaps (passthrough, by SNI)

all checks passed
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
| a gvproxy forward from `127.0.0.1:20443` | where the clients can route to the MetalLB address, no forward is needed |
| `/etc/hosts`, written by CRC for Route hosts ending in `.crc.testing` or `.apps-crc.testing` | a DNS wildcard record, `*.apps-metallb.<domain>` → the shard's address |
| one shard address, one replica | more replicas on several nodes; MetalLB layer 2 moves the address to another node if one fails |
| the default router's selector costs a ~31 s outage: one `HostNetwork` pod that must stop before its replacement can bind the ports | the default router runs a pod on each of several nodes, and the load balancer in front of them sends traffic to the ones still serving. Not measured here: this cluster has one node. The selector is still a change to the router that carries the console and OAuth, so it goes through that router's owner and a change window |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| console, OAuth, every Route answers `000` or refuses connections for about half a minute | the default router is rolling out after a change to its IngressController: step 5, or `./run.sh deploy` the first time on a cluster that has no selector yet. `./run.sh clean` does not change the default router | wait: `oc rollout status deploy/router-default -n openshift-ingress` |
| after someone removes the default router's `routeSelector`, every Route shows no `Admitted` status for minutes, `kube-apiserver` rolls out new revisions, and `oc get routes` fails with `the server doesn't have a resource type "routes"` | a missing selector is read as "select nothing" when the operator clears status ([Clean up](#clean-up)) | wait: the router re-admits every Route once its new pod runs, and the API servers settle (about four minutes, measured). Don't remove the field. To reset it, set an empty selector `{}`, which the same code reads as "every Route". That is from the source, not measured here |
| `IngressController default already has routeSelector … - left alone` from `./run.sh deploy` | someone gave the default router a selector of their own; `run.sh` does not merge selectors | decide with whoever set it; step 5's selector must be combined with theirs by hand |
| `not changing the default router: these Routes carry ingress-shard …` from `./run.sh deploy` | Routes already carry the label; the selector would take them off the default router | remove the label from each, or move them to the shard on purpose, then deploy again |
| a Route that should be on the default router stops answering after step 5 | it carries an `ingress-shard` label | remove the label, or move the Route to the shard's domain on purpose |
| `admission webhook "ipaddresspoolvalidationwebhook.metallb.io" denied the request: CIDR … overlaps with already defined CIDR` | the address is in another pool (measured with `.120`) | pick an address outside every pool |
| `router-metallb` stays `<pending>`, the IngressController not `Available` | no pool gives it an address: a selecting pool with `autoAssign: false` is skipped (`allocator.go`, `pinnedPoolsForService`) | `autoAssign: true` on the selecting pool |
| `503` on `https://canary.apps-metallb.crc.testing/` | port 443 is the default router, which ignores the shard's Routes (step 9) | use port `20443` (step 8) |
| `Failed to connect … port 20443` | no forward | step 8, or `./run.sh deploy` |
| `crc-forward.sh: port 20443 is taken on this laptop by …` | another program listens on the port (the helper checks with `lsof -nP -iTCP:20443 -sTCP:LISTEN` before it asks gvproxy) | stop it, or pick another port |
| `crc-forward.sh: 127.0.0.1:20443 already forwards to …` | a forward of the same port to another address — someone else's | remove it with `../../_shared/crc-forward.sh remove 127.0.0.1:20443 <that address>` if it is yours |

## Permanent lab

On the operator's CRC the shard stays: module 20's Route lives on it. Argo CD's
Application `ingress-shard`
([`../../argocd/ingress-shard.yaml`](../../argocd/ingress-shard.yaml)) keeps this
folder's `manifests/` and the echo app as they are on `main`. Like the others it
has automated sync with `automated.enabled`, `ServerSideApply`, `ServerSideDiff`
and no resources-finalizer.

| What | Made by | Kept by | Why |
|---|---|---|---|
| pool and L2 advertisement, the certificate, `IngressController metallb`, namespace `ingress-shard`, Route `canary`, the echo app | `manifests/`, `../../_shared/echo-app.yaml` | Argo CD | manifests. The namespace carries `argocd.argoproj.io/sync-options: Prune=false`, as module 16's `keycloak` does ([`argocd`](../../argocd/README.md)): were a later commit to drop or rename its document, automated prune would otherwise delete it and everything in it. `./run.sh clean` is the one way to remove it |
| **the default router's `routeSelector`** (step 5) | `./run.sh deploy` | nobody: `run.sh` only | the default IngressController is the platform's, not this lab's. An Application that owned it could prune it, which would delete the router every Route depends on, and would put its own copy of the object back over any other change to it. `run.sh` adds the one field, only if the router has no selector yet; `clean` leaves it ([Clean up](#clean-up) says why). `./run.sh verify` checks that it is there |
| Deployment and Service `router-metallb` | the ingress operator | the ingress operator | made from the IngressController |
| the laptop's forward `127.0.0.1:20443 → 192.168.127.130:443` | `./run.sh deploy` | nobody: `run.sh` only | it lives in CRC's gvproxy, not in the cluster, and ends when the CRC VM stops. After `crc start`, run `./run.sh deploy` again |
| `/etc/hosts` lines for Route hosts ending in `.crc.testing` or `.apps-crc.testing` | CRC's `routes-controller` | CRC | CRC's own |

`./run.sh clean` pauses the Application before it deletes anything, and
`./run.sh deploy` resumes it at its end. `./run.sh pause` and `./run.sh resume`
work as in module 16's [Permanent lab](../../16-keycloak/README.md#permanent-lab).

## Clean up

This is a deliberate reset only: module 20 needs the shard. Pause Argo CD first,
then remove what this page added, in reverse, **except the default router's
selector from step 5**.

> **Why the selector stays.** With no Route labelled `ingress-shard` it changes
> nothing. Removing it is what is unsafe:
>
> - When a router's selector changes, the ingress operator clears the `Admitted`
>   status of every Route the new selector no longer picks
>   (`clearRoutesNotAdmittedByIngress` in cluster-ingress-operator's
>   `router_status.go`).
> - It builds that selector with `LabelSelectorAsSelector`, which turns a
>   **missing** selector into `labels.Nothing()`: it matches no Route
>   (apimachinery `helpers.go`). The router itself treats "no selector" as "every
>   Route"; only this clean-up step reads it the other way.
> - So removing the field clears every Route on the default router. **Measured on
>   CRC (2026-09-27):** the operator logged `Routes Status Cleared: 21` of 21. The
>   image registry's Route lost its hostname, and that one change rolled out
>   `kube-apiserver` twice (revisions 9 and 10: away, and back) and restarted
>   `openshift-apiserver` twice. For about four minutes, `oc get routes` answered
>   `the server doesn't have a resource type "routes"`.
> - Adding the selector in step 5 cleared nothing (`Routes Status Cleared: 0`):
>   every existing Route still matches it.

<!-- walkthrough: skip -->
```console
$ ./run.sh pause
$ ../../_shared/crc-forward.sh remove 127.0.0.1:20443 192.168.127.130:443
$ oc delete -f manifests/40-canary.yaml --wait=false
$ oc delete -f manifests/30-ingresscontroller.yaml --wait=false
$ oc wait ingresscontroller/metallb -n openshift-ingress-operator --for=delete --timeout=180s
$ oc wait svc/router-metallb -n openshift-ingress --for=delete --timeout=180s
$ oc delete -f manifests/20-certificate.yaml
$ oc delete secret router-metallb-default-cert -n openshift-ingress
$ oc delete -f manifests/10-pool.yaml
$ oc wait ns/ingress-shard --for=delete --timeout=180s
$ rm -f enterprise-root-ca.pem
```

The forward goes only when it leads to `192.168.127.130:443`: `crc-forward.sh
remove` always takes the address a forward must lead to, leaves another forward
of the same port alone and fails — someone else's (measured: a hand-made `127.0.0.1:20443 →
192.168.127.102:80` stopped `./run.sh clean` before it deleted anything, exit 1,
and `./run.sh deploy` refused to replace it).
`./run.sh clean` does all of this, checks every step, and stops at the first
that fails, before it says the shard is gone. It removes the forward only when it
is this lab's, and fails otherwise. The default router, `mongot-pool`,
`mongot-l2` and CRC's own forwards are not touched, so there is no outage.

## The shortcut

- `./run.sh deploy` does steps 3 to 8 and resumes Argo CD's Application if there
  is one. It includes step 5's outage the first time; a second `deploy` rolls
  neither router and changes no router generation (measured).
- `./run.sh verify` is step 12. It checks:
  - the manifests' contract: the pool's `autoAssign` and `serviceAllocation`,
    the L2 advertisement's pool and interface, and the shard's domain,
    publishing strategy, `routeSelector` and default certificate;
  - the address and its pool;
  - the default router's selector;
  - which routers admit what: the canary on the shard alone, every other Route
    on the default router;
  - the laptop's way in;
  - `503` on `:443`;
  - the default router's Routes.
- `./run.sh clean` is the clean-up, with the Application paused first; every
  step is checked, and it waits until the IngressController, the Service and
  the namespace are gone. It leaves
  the default router's selector, so it causes no outage.

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

## Diagram sources

The figure is rendered from [`docs/diagrams/ingress-shard/source.html`](../../docs/diagrams/ingress-shard/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with [diagram-kit](https://github.com/ephico2real2/diagram-kit) (MPL-2.0), which writes a PNG only when the page
passes its checks (the install is in the [root README](../../README.md#tooling)):

```bash
# from the repository root
diagram-render docs/diagrams/ingress-shard/source.html docs/diagrams/ingress-shard shard
```
