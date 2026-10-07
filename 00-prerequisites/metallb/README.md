# MetalLB on CRC — the install, step by step

A Service of type `LoadBalancer` needs something to give it an address. A cloud
has its load balancers for that; on bare metal, and on CRC, it is **MetalLB**.
The concepts are in [MetalLB on OpenShift, and on
CRC](../README.md#metallb-on-openshift-and-on-crc); this page walks the install
itself, object by object.

MetalLB on the operator's CRC was installed on **2026-09-24** by the
`mongodb-poc` project, from its `manifests/05-metallb-olm.yaml` and
`06-metallb-config.yaml`. The [`manifests/`](manifests/) here are those objects.
Since then `mongodb-poc`, the Gateways of modules 12 to 15, 17 and 19, and the
[ingress shard](../ingress-shard/README.md) all use it.

So this page **installs nothing on that cluster**. Each step that creates
something runs as `oc apply --dry-run=server`: the API server checks the
manifest against what is there and saves nothing. It says `unchanged` when the
cluster already matches the fields being applied. The remaining commands do
not persist cluster changes. This walk does not run `../check.sh`: that script
creates a test pod and deletes its test namespace.

## What you'll learn

- how the MetalLB Operator comes from Red Hat's catalog through OLM, and why its
  `OperatorGroup` selects all namespaces (`spec: {}` here);
- what the one `MetalLB` resource starts: a controller that hands out
  addresses, and a speaker on each node that announces them;
- why the pool on CRC is `192.168.127.100` to `.120`, with `autoAssign: false`,
  announced on `br-ex`;
- how to tell that a Service got an address, and that a node announces it;
- how the laptop uses gvproxy forwards to reach these addresses.

## Before you start

- Module [`00`](../README.md)'s steps 1 to 3: `oc` logged in as a cluster admin.
- OpenShift 4.22 with the `redhat-operators` catalog. Everything here was run on
  OpenShift Local (CRC) 4.22.7, one node, on 2026-09-28.
- Work from this folder: `cd 00-prerequisites/metallb`. About 5 minutes.
- **On a cluster that already has MetalLB, change nothing.** It is shared: a
  conflicting install, a pool change or deleting `MetalLB` can disrupt its
  consumers. On a CRC cluster **without** MetalLB, drop `--dry-run=server`
  from steps 2, 4 and 6, in order, waiting in steps 3 and 4 before proceeding.
  These are real cluster writes, including the operator's reconciliation.
  Check step 5 before applying the pool: reserve its addresses, ensure they
  are unused, and adapt the range and interface if your CRC network differs.
  Avoiding `.1`, `.2` and `.254` alone is not proof the other addresses are free.
- **Fresh-cluster output differs.** These manifests install MetalLB and one
  pool/advertisement; they create no application, `LoadBalancer` Service,
  ingress shard or laptop forward. Step 6 initially has just `mongot-pool`
  with 0 assigned and 21 available addresses if no other consumer requests
  one. Step 7 may list no Services or announcements; skip its speaker-log
  filter and the `mongodb-poc` diagnostic if those consumers do not exist.
  Step 8's `.102` timeout then says nothing about announcement or routing;
  skip that request until an actual consumer is running. Deploy a linked
  Gateway module or the ingress shard separately for an end-to-end test.
  The `stable` channel follows the catalog, so a later install can use a
  different CSV; read its install modes and status rather than expecting the
  recorded name or timings.

## The picture

<!-- markdownlint-disable MD033 -->
<img alt="MetalLB on CRC, snapshot from 2026-09-28. The catalog offers metallb-operator on channel stable with AllNamespaces support only. Namespace metallb-system holds OperatorGroup metallb-operator with an empty spec and status.namespaces containing the empty string, and Subscription metallb-operator-sub. The CSV reached Succeeded 48 seconds after its first recorded Pending condition. The MetalLB resource metallb starts the controller and speaker. FRR is configured as an additional routing provider; this diagram does not attribute the network change to a particular writer. The controller allocates addresses from IPAddressPool mongot-pool, 192.168.127.100 through 192.168.127.120, with autoAssign false. L2Advertisement mongot-l2 configures the speaker to announce that pool on br-ex. The node&#x27;s gateway annotation records br-ex as 192.168.127.2/24; .1 resolves as gateway.crc.testing and .254 as host.crc.testing. Four Services hold addresses: .100 for mongodb-poc, .101 for module 17 and .102 for module 19 from mongot-pool, and .130 for the ingress shard from ingress-shard-pool. ServiceL2Status records crc and br-ex for .101, .102 and .130; no record is shown for .100, whose EndpointSlices are not included in this snapshot. The laptop&#x27;s route lookup for .102 chooses en0 via 192.168.166.1, and direct curl timed out. Existing gvproxy forwards map 127.0.0.1:19080 to .102:80 and 127.0.0.1:20443 to .130:443. Arrows show install order, configuration inputs and the forwarded traffic path." src="../../docs/diagrams/metallb/metallb.light.png">
<!-- markdownlint-enable MD033 -->

*The install in order, on the right: the Subscription and an `OperatorGroup`
with `spec: {}` install the operator, and the `MetalLB` resource starts the
controller and the speaker. The controller gives each `LoadBalancer` Service an
address from an eligible pool; the speaker reports announcements on `br-ex`.
On the left are the laptop's existing gvproxy forwards. Grey arrows show
install order or configuration inputs; teal shows traffic and ARP.*

## Walkthrough

### Step 1 — the operator in the catalog

```console
$ oc get packagemanifest metallb-operator -n openshift-marketplace
NAME               CATALOG             AGE
metallb-operator   Red Hat Operators   60d
$ oc get packagemanifest metallb-operator -n openshift-marketplace -o jsonpath='catalog={.status.catalogSource}  defaultChannel={.status.defaultChannel}{"\n"}{range .status.channels[*]}channel {.name}: {.currentCSV}{"\n"}{end}'
catalog=redhat-operators  defaultChannel=stable
channel stable: metallb-operator.v4.22.0-202609151747
$ oc get packagemanifest metallb-operator -n openshift-marketplace -o jsonpath='{range .status.channels[?(@.name=="stable")].currentCSVDesc.installModes[*]}{.type}={.supported}{"\n"}{end}'
OwnNamespace=false
SingleNamespace=false
MultiNamespace=false
AllNamespaces=true
```

**What just happened:**

- The operator is in the `redhat-operators` catalog, with one channel,
  `stable`. Its current version (a *CSV*, ClusterServiceVersion) is the one the
  Subscription in step 2 installs.
- Its **install modes**: `AllNamespaces` only. That decides the
  `OperatorGroup` in step 2.

### Step 2 — namespace, OperatorGroup, Subscription

[`manifests/10-olm.yaml`](manifests/10-olm.yaml) holds three objects:

| Object | Here | Why |
|---|---|---|
| `Namespace` | `metallb-system` | where Red Hat's docs install the operator from the CLI ("It is recommended that when using the CLI you install the Operator in the metallb-system namespace") |
| `OperatorGroup` | `metallb-operator`, `spec: {}` | tells OLM which namespaces the operator may watch. An empty spec means **all of them**, the one mode this operator supports (step 1) |
| `Subscription` | `metallb-operator-sub`: package `metallb-operator`, channel `stable`, source `redhat-operators` in `openshift-marketplace`, `installPlanApproval: Automatic` | installs the channel's current CSV, and later versions without a manual approval |

> **The gotcha.** Many operators are installed with an `OperatorGroup` that
> names its own namespace (`targetNamespaces: [metallb-system]`). This one
> refuses it. **From the source, not reproduced in this walk:** the CSV ends
> `Failed`, reason `UnsupportedOperatorGroup`, message
> `OwnNamespace InstallModeType not supported, cannot configure to watch own
> namespace`. That is the check in operator-framework's
> `InstallModeSet.Supports`: one target namespace equal to the operator's own
> needs `OwnNamespace`, which step 1 shows is `false`. `mongodb-poc` recorded the
> failure (`DEPLOYMENT.md`, §3); it was not reproduced here, as it would mean
> changing the shared installation. For a fresh install, use `spec: {}`
> (omitting `spec` also selects all namespaces). Repairing an existing group
> requires removing its namespace selectors; applying an empty spec alone does
> not necessarily remove fields owned by another writer.

```console
$ oc apply --dry-run=server -f manifests/10-olm.yaml
namespace/metallb-system unchanged (server dry run)
operatorgroup.operators.coreos.com/metallb-operator unchanged (server dry run)
subscription.operators.coreos.com/metallb-operator-sub unchanged (server dry run)
$ oc get operatorgroup metallb-operator -n metallb-system -o jsonpath='spec={.spec}  namespaces={.status.namespaces}{"\n"}'
spec={"upgradeStrategy":"Default"}  namespaces=[""]
$ oc get subscription metallb-operator-sub -n metallb-system -o jsonpath='channel={.spec.channel}  source={.spec.source}  approval={.spec.installPlanApproval}{"\n"}state={.status.state}  installedCSV={.status.installedCSV}{"\n"}'
channel=stable  source=redhat-operators  approval=Automatic
state=AtLatestKnown  installedCSV=metallb-operator.v4.22.0-202609151747
$ oc get namespace metallb-system -o jsonpath='{.metadata.labels}{"\n"}'
{"kubernetes.io/metadata.name":"metallb-system","pod-security.kubernetes.io/audit":"privileged","pod-security.kubernetes.io/audit-version":"latest","pod-security.kubernetes.io/warn":"privileged","pod-security.kubernetes.io/warn-version":"latest"}
$ oc get namespace metallb-system --show-managed-fields -o jsonpath='{range .metadata.managedFields[*]}{.manager}  {.operation}  {.time}{"\n"}{end}'
cluster-policy-controller  Apply  2026-09-24T02:41:13Z
pod-security-admission-label-synchronization-controller  Apply  2026-09-24T02:51:55Z
kubectl-client-side-apply  Update  2026-09-24T02:41:13Z
```

On a cluster without MetalLB, drop `--dry-run=server`: the first command then
prints `created` for each new object; an existing namespace may print
`unchanged` or `configured`. Status fields populate asynchronously, so the
following reads may initially be empty; step 3 waits for installation.

**What just happened:**

- `unchanged (server dry run)`: applying these manifest fields would make no
  changes, and nothing was written. The live objects can have additional
  defaulted fields, labels and status.
- The OperatorGroup's `namespaces=[""]`: the empty string is Kubernetes'
  "all namespaces". The live spec also shows `upgradeStrategy: Default`.
- `AtLatestKnown`: the Subscription runs the newest CSV its channel offers.
- The namespace's `pod-security.kubernetes.io` labels (`audit` and `warn`,
  `privileged`) are not in the manifest. The manager list includes OpenShift's
  `pod-security-admission-label-synchronization-controller`, consistent with
  SCC-based label synchronization. This projection does not include `fieldsV1`,
  so it does not prove which manager owns each label. The speaker's
  `privileged` SCC is shown directly in step 4.

### Step 3 — wait for the operator

```console
$ oc get installplan -n metallb-system
NAME            CSV                                     APPROVAL    APPROVED
install-frssh   metallb-operator.v4.22.0-202609151747   Automatic   true
$ (csv=; for i in $(seq 1 60); do csv=$(oc get subscription metallb-operator-sub -n metallb-system -o jsonpath='{.status.installedCSV}') || exit; [ -n "$csv" ] && break; sleep 5; done; if [ -z "$csv" ]; then echo 'Timed out waiting for Subscription installedCSV; inspect the Subscription and InstallPlan.' >&2; exit 1; fi; oc wait csv/"$csv" -n metallb-system --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s)
clusterserviceversion.operators.coreos.com/metallb-operator.v4.22.0-202609151747 condition met
$ oc get csv -n metallb-system "$(oc get subscription metallb-operator-sub -n metallb-system -o jsonpath='{.status.installedCSV}')" -o jsonpath='{range .status.conditions[*]}{.lastTransitionTime}  {.phase}  {.reason}{"\n"}{end}'
2026-09-24T02:51:50Z  Pending  RequirementsUnknown
2026-09-24T02:51:50Z  Pending  RequirementsNotMet
2026-09-24T02:51:57Z  InstallReady  AllRequirementsMet
2026-09-24T02:51:58Z  Installing  InstallSucceeded
2026-09-24T02:51:58Z  Installing  InstallWaiting
2026-09-24T02:52:13Z  Pending  NeedsReinstall
2026-09-24T02:52:13Z  InstallReady  AllRequirementsMet
2026-09-24T02:52:13Z  Installing  InstallSucceeded
2026-09-24T02:52:13Z  Installing  InstallWaiting
2026-09-24T02:52:38Z  Succeeded  InstallSucceeded
2026-09-26T14:33:38Z  Failed  ComponentUnhealthy
2026-09-26T14:33:43Z  Pending  NeedsReinstall
2026-09-26T14:33:44Z  InstallReady  AllRequirementsMet
2026-09-26T14:33:45Z  Installing  InstallSucceeded
2026-09-26T14:33:45Z  Installing  InstallWaiting
2026-09-26T14:34:11Z  Succeeded  InstallSucceeded
$ oc api-resources --api-group=metallb.io
NAME                  SHORTNAMES   APIVERSION           NAMESPACED   KIND
bfdprofiles                        metallb.io/v1beta1   true         BFDProfile
bgpadvertisements                  metallb.io/v1beta1   true         BGPAdvertisement
bgppeers                           metallb.io/v1beta2   true         BGPPeer
communities                        metallb.io/v1beta1   true         Community
configurationstates                metallb.io/v1beta1   true         ConfigurationState
ipaddresspools                     metallb.io/v1beta1   true         IPAddressPool
l2advertisements                   metallb.io/v1beta1   true         L2Advertisement
metallbs                           metallb.io/v1beta1   true         MetalLB
servicebgpstatuses                 metallb.io/v1beta1   true         ServiceBGPStatus
servicel2statuses                  metallb.io/v1beta1   true         ServiceL2Status
```

**What just happened:**

- OLM made an **InstallPlan** for the CSV, approved by itself
  (`installPlanApproval: Automatic`).
- The loop waits until the Subscription names its CSV, then `oc wait` until
  that CSV is `Succeeded`: the operator runs. It stops on a failed read or
  reports a timeout if no CSV name appears; do not continue on either failure.
- The CSV keeps its phases. On 2026-09-24 it went from `Pending` at 02:51:50Z
  to `Succeeded` at 02:52:38Z, 48 s. On 2026-09-26,
  `Failed  ComponentUnhealthy` is followed by reinstall conditions and
  `Succeeded` 33 s later. These conditions do not establish why the component
  became unhealthy; a VM restart is not demonstrated by this output.
- The operator brought MetalLB's resource types. Steps 4 to 7 use five of them:
  `MetalLB`, `IPAddressPool`, `L2Advertisement`, `ConfigurationState` and
  `ServiceL2Status`.

### Step 4 — start MetalLB

The operator deploys MetalLB's controller and speaker when a `MetalLB` resource
exists.
[`manifests/20-metallb.yaml`](manifests/20-metallb.yaml) is one, named
`metallb`, with an empty spec:

```console
$ oc apply --dry-run=server -f manifests/20-metallb.yaml
metallb.metallb.io/metallb unchanged (server dry run)
$ oc wait metallb/metallb -n metallb-system --for=condition=Available --timeout=300s
metallb.metallb.io/metallb condition met
$ oc get deployment,daemonset -n metallb-system
NAME                                                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/controller                            1/1     1            1           4d7h
deployment.apps/metallb-operator-controller-manager   1/1     1            1           4d7h
deployment.apps/metallb-operator-webhook-server       1/1     1            1           4d7h

NAME                     DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
daemonset.apps/speaker   1         1         1       1            1           kubernetes.io/os=linux   4d7h
$ oc get pods -n metallb-system -o wide
NAME                                                   READY   STATUS    RESTARTS      AGE    IP               NODE   NOMINATED NODE   READINESS GATES
controller-5b5b99b4cc-9j2hv                            2/2     Running   2             4d7h   10.217.1.2       crc    <none>           <none>
metallb-operator-controller-manager-69d46f4f5f-pvkpk   1/1     Running   5 (18h ago)   4d7h   10.217.1.0       crc    <none>           <none>
metallb-operator-webhook-server-75c9c5658d-k5xhs       1/1     Running   1             4d7h   10.217.1.1       crc    <none>           <none>
speaker-mmqqm                                          2/2     Running   2             4d7h   192.168.126.11   crc    <none>           <none>
$ oc get pods -n metallb-system -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name,HOSTNETWORK:.spec.hostNetwork,SCC:.metadata.annotations.openshift\.io/scc'
POD                                                    CONTAINERS                   HOSTNETWORK   SCC
controller-5b5b99b4cc-9j2hv                            controller,kube-rbac-proxy   <none>        restricted-v2
metallb-operator-controller-manager-69d46f4f5f-pvkpk   manager                      <none>        restricted-v2
metallb-operator-webhook-server-75c9c5658d-k5xhs       webhook-server               <none>        restricted-v2
speaker-mmqqm                                          speaker,kube-rbac-proxy      true          privileged
```

On a cluster without MetalLB, drop `--dry-run=server`: it prints
`metallb.metallb.io/metallb created`.

**What just happened:** four pods, two from OLM and two from the `MetalLB`
resource.

| Pod | Made by | What it does |
|---|---|---|
| `metallb-operator-controller-manager` | the CSV | the operator: turns the `MetalLB` resource into the two below |
| `metallb-operator-webhook-server` | the CSV | checks MetalLB objects before they are saved: it refuses, for example, two pools that overlap |
| `controller` | `MetalLB metallb` | **hands out addresses**: gives a `LoadBalancer` Service an address from a pool, and writes it to the Service's status |
| `speaker` (DaemonSet) | `MetalLB metallb` | **announces them**: one pod per node, on the node's own network (its IP is the node's, `192.168.126.11`). In layer 2 it answers ARP for an address from one node, so traffic for it arrives there |

`2/2` for the controller and the speaker: each has a `kube-rbac-proxy` beside
it, for metrics. One node, so one speaker. The speaker is the one pod on the
host's network, under the `privileged` SCC; the others run as `restricted-v2`.
`oc wait` waited for the condition `Available` that the operator sets on the
`MetalLB` resource.

**FRR-K8s** is also present. The network configuration names FRR as an
additional routing provider, and its pods are running. The layer 2
advertisement in this guide does not configure a BGP peer:

```console
$ oc get network.operator.openshift.io cluster -o jsonpath='{.spec.additionalRoutingCapabilities}{"\n"}'
{"providers":["FRR"]}
$ oc get metallb metallb -n metallb-system -o jsonpath='MetalLB metallb created            {.metadata.creationTimestamp}{"\n"}'; oc get network.operator.openshift.io cluster --show-managed-fields -o jsonpath='{range .metadata.managedFields[?(@.manager=="manager")]}network cluster, field manager {.manager}  {.time}{"\n"}{end}'; oc get namespace openshift-frr-k8s -o jsonpath='namespace openshift-frr-k8s created  {.metadata.creationTimestamp}{"\n"}'
MetalLB metallb created            2026-09-24T02:52:55Z
network cluster, field manager manager  2026-09-24T02:52:55Z
namespace openshift-frr-k8s created  2026-09-24T02:53:46Z
$ oc auth can-i update networks.operator.openshift.io --as="system:serviceaccount:metallb-system:$(oc get deployment metallb-operator-controller-manager -n metallb-system -o jsonpath='{.spec.template.spec.serviceAccountName}')"
Warning: resource 'networks' is not namespace scoped in group 'operator.openshift.io'

yes
$ oc get pods -n openshift-frr-k8s
NAME                                     READY   STATUS    RESTARTS   AGE
frr-k8s-statuscleaner-5f6876957b-kps5s   1/1     Running   1          4d7h
frr-k8s-t8kmw                            7/7     Running   7          4d7h
```

The network object's `manager` entry has the same timestamp as creation of
`MetalLB metallb`. The FRR namespace was created 51 s later, and the
operator's service account is allowed to update the network configuration.
Those facts are consistent with operator-driven enablement, but the projection
does not identify the fields owned by `manager`. A field-manager name matching
a container name is not proof of identity. This output alone establishes
configuration and timing, not which controller changed the field or owns the
FRR workloads.

### Step 5 — where the addresses can live

MetalLB in layer 2 needs addresses on a network the node is on. The CRC VM's
node has its interface on the CRC network, `br-ex`:

```console
$ oc get node crc -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/l3-gateway-config}{"\n"}'
{"default":{"mode":"shared","bridge-id":"br-ex","interface-id":"br-ex_crc","mac-address":"5a:94:ef:e4:0c:ee","ip-addresses":["192.168.127.2/24"],"ip-address":"192.168.127.2/24","next-hops":["192.168.127.1"],"next-hop":"192.168.127.1","node-port-enable":"true","vlan-id":"0"}}
$ ssh -i ~/.crc/machines/crc/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR core@127.0.0.1 'getent hosts gateway.crc.testing host.crc.testing'
192.168.127.1   gateway.crc.testing
192.168.127.254 host.crc.testing
```

**What just happened:**

- The node's gateway bridge is `br-ex`, with `192.168.127.2/24`, and its next
  hop is `192.168.127.1`. That is OVN-Kubernetes' record of the node, on the
  Node object.
- The host-network speaker has pod IP `192.168.126.11` (step 4), different
  from the gateway bridge's address. The listed L2Advertisements and
  ServiceL2Statuses identify `br-ex` as the announcement interface (steps 6–7).
- Inside the VM (through CRC's own ssh forward, `127.0.0.1:2222`), gvproxy's
  DNS names two more addresses on that network: `.1`, the gateway, which is
  gvproxy itself, and `.254`, `host.crc.testing`, the laptop as the VM reaches
  it.

So a pool on CRC lies in `192.168.127.0/24` and avoids `.1`, `.2` and `.254`.

### Step 6 — the pool and its layer 2 advertisement

[`manifests/30-pool.yaml`](manifests/30-pool.yaml):

| Object | Field | Here | Why |
|---|---|---|---|
| `IPAddressPool mongot-pool` | `addresses` | `192.168.127.100-192.168.127.120` | 21 addresses on the CRC network, clear of `.1`, `.2` and `.254` (step 5) |
| | `autoAssign` | `false` | disables automatic selection of this pool. A Service can still request it by `metallb.io/address-pool` (or the deprecated `metallb.universe.tf/address-pool`), or request a specific address within it using `metallb.io/loadBalancerIPs` (or deprecated `spec.loadBalancerIP`). It is not an access-control boundary |
| `L2Advertisement mongot-l2` | `ipAddressPools` | `mongot-pool` | which pool it announces |
| | `interfaces` | `br-ex` | the speaker answers ARP there only. Without the field it answers on every interface of the node (`AllInterfaces`, MetalLB's `config.go`) |

```console
$ oc apply --dry-run=server -f manifests/30-pool.yaml
ipaddresspool.metallb.io/mongot-pool unchanged (server dry run)
l2advertisement.metallb.io/mongot-l2 unchanged (server dry run)
$ oc get ipaddresspool -n metallb-system -o custom-columns='NAME:.metadata.name,ADDRESSES:.spec.addresses,AUTOASSIGN:.spec.autoAssign,ASSIGNED:.status.assignedIPv4,AVAILABLE:.status.availableIPv4'
NAME                 ADDRESSES                           AUTOASSIGN   ASSIGNED   AVAILABLE
ingress-shard-pool   [192.168.127.130/32]                true         1          0
mongot-pool          [192.168.127.100-192.168.127.120]   false        3          18
$ oc get l2advertisement -n metallb-system
NAME               IPADDRESSPOOLS           IPADDRESSPOOL SELECTORS   INTERFACES
ingress-shard-l2   ["ingress-shard-pool"]                             ["br-ex"]
mongot-l2          ["mongot-pool"]                                    ["br-ex"]
$ oc get configurationstate -n metallb-system
NAME          RESULT   ERRORSUMMARY   AGE
controller    Valid                   4d7h
speaker-crc   Valid                   4d7h
```

On a cluster without MetalLB, drop `--dry-run=server`: it prints `created`
twice.

**What just happened:**

- `mongot-pool` has 3 of its 21 addresses assigned, 18 free.
- `ingress-shard-pool` and `ingress-shard-l2` are not from this page: the
  [ingress shard](../ingress-shard/README.md#step-3--a-pool-for-the-shard) adds
  them, one address, `192.168.127.130`, for its router alone. A second pool is
  how a new consumer gets its own address without touching `mongot-pool`.
- `ConfigurationState` is MetalLB's own verdict on these objects: the controller
  and the speaker on node `crc` both read them as `Valid`.

### Step 7 — a Service with an address

```console
$ oc get svc -A --field-selector spec.type=LoadBalancer -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip,ASKED FOR:.metadata.annotations.metallb\.universe\.tf/address-pool,ALLOCATED FROM:.metadata.annotations.metallb\.io/ip-allocated-from-pool'
NAMESPACE              NAME                         EXTERNAL-IP       ASKED FOR     ALLOCATED FROM
envoy-gateway-system   envoy-envoy-17-eg-0d84cb63   192.168.127.101   mongot-pool   mongot-pool
envoy-gateway-system   envoy-envoy-19-eg-413e95da   192.168.127.102   mongot-pool   mongot-pool
mongodb-poc            mongot-grpc-lb               192.168.127.100   mongot-pool   mongot-pool
openshift-ingress      router-metallb               192.168.127.130   <none>        ingress-shard-pool
$ oc get servicel2status -n metallb-system -o custom-columns='SERVICE NAMESPACE:.status.serviceNamespace,SERVICE:.status.serviceName,NODE:.status.node,INTERFACES:.status.interfaces[*].name'
SERVICE NAMESPACE      SERVICE                      NODE   INTERFACES
envoy-gateway-system   envoy-envoy-17-eg-0d84cb63   crc    br-ex
envoy-gateway-system   envoy-envoy-19-eg-413e95da   crc    br-ex
openshift-ingress      router-metallb               crc    br-ex
$ oc logs ds/speaker -c speaker -n metallb-system | grep '"event":"serviceAnnounced"' | tail -3
{"caller":"main.go:481","event":"serviceAnnounced","ips":["192.168.127.102"],"level":"info","msg":"service has IP, announcing","pool":"mongot-pool","protocol":"layer2","ts":"2026-09-28T09:40:29Z"}
{"caller":"main.go:481","event":"serviceAnnounced","ips":["192.168.127.102"],"level":"info","msg":"service has IP, announcing","pool":"mongot-pool","protocol":"layer2","ts":"2026-09-28T09:40:31Z"}
{"caller":"main.go:481","event":"serviceAnnounced","ips":["192.168.127.102"],"level":"info","msg":"service has IP, announcing","pool":"mongot-pool","protocol":"layer2","ts":"2026-09-28T09:40:40Z"}
$ oc get nodes -l node.kubernetes.io/exclude-from-external-load-balancers
No resources found
```

**What just happened:**

- Four `LoadBalancer` Services, four addresses:

  | Address | Service | Who |
  |---|---|---|
  | `.100` | `mongodb-poc/mongot-grpc-lb` | `mongodb-poc` |
  | `.101` | `envoy-gateway-system/envoy-envoy-17-eg-…` | module 17's Gateway |
  | `.102` | `envoy-gateway-system/envoy-envoy-19-eg-…` | module 19's Gateway |
  | `.130` | `openshift-ingress/router-metallb` | the ingress shard's router |

- **Asked for**: the first three name `mongot-pool` in the older annotation.
  The Gateways get it from their GatewayClass `eg`, whose `EnvoyProxy
  openshift-scc` is module 12's
  ([`20-envoyproxy.yaml`](../../12-gateway-api/manifests/20-envoyproxy.yaml)).
  The controller's `valueForAnnotation` emits a `deprecatedAnnotation` warning
  for the old key (from `controller/service.go`, not captured here); new
  Services should use `metallb.io/address-pool`. `router-metallb` names no pool: its pool selects it
  by label ([ingress shard, step 3](../ingress-shard/README.md#step-3--a-pool-for-the-shard)).
- **Allocated from**: the controller writes the pool it used in
  `metallb.io/ip-allocated-from-pool`.
- **Announced**: a `ServiceL2Status` is the speaker's record that it announces
  a Service, from which node and on which interface: `crc`, `br-ex`. The log
  lines are the same event, as it happens.
- **An address is not an announcement.** `.100` is allocated but has no
  `ServiceL2Status` in this snapshot. That alone does not establish the cause.
  The EndpointSlices behind `mongot-grpc-lb` were not included in the output
  above, so absence of backend pods is not demonstrated here.
  **From the source at `42b0bfe`:** `ShouldAnnounce` returns `notOwner` when
  `activeEndpointExists` is false. Its `EndpointCanServe` helper accepts
  `ready=true`, an unset `ready`, or `serving=true` even if `ready=false`. With
  `externalTrafficPolicy: Local`, the elected node also needs such an endpoint
  on that node. An eligible endpoint is necessary, but advertisement selection,
  node eligibility, election and interface availability must also pass.
  No eligible endpoints would explain `.100`; verify before attributing the
  missing announcement to that cause:

  ```bash
  oc get endpointslices.discovery.k8s.io -n mongodb-poc -l kubernetes.io/service-name=mongot-grpc-lb -o yaml
  ```

  This read-only diagnostic has no recorded output in this walk. Check every
  slice's `endpoints[].conditions` and, for local traffic policy, `nodeName`.
- No node carries `node.kubernetes.io/exclude-from-external-load-balancers`.
  The source excludes labelled nodes unless the speaker is started with
  `--ignore-exclude-lb` (Troubleshooting); the failure was not induced here.

### Step 8 — from the laptop

In this snapshot, the laptop sends traffic for `192.168.127.102` to its
own default gateway. Module 19's Gateway at that address has an announcement
status (step 7), yet the direct request times out:

```console
$ route -n get 192.168.127.102 | grep -E 'gateway|interface'
    gateway: 192.168.166.1
  interface: en0
```

<!-- walkthrough: expect-exit 28 -->
```console
$ curl -sS --max-time 3 -o /dev/null http://192.168.127.102/
curl: (28) Connection timed out after 3003 milliseconds
```

CRC's network proxy, gvproxy, is the way in. It forwards a few laptop ports
into the CRC network by itself, and
[`../../_shared/crc-forward.sh`](../../_shared/crc-forward.sh) asks it for
more:

```console
$ ../../_shared/crc-forward.sh list
/Users/olasumbo/.crc/machines/crc/docker.sock -> ssh-tunnel://core@192.168.127.2:22/run/podman/podman.sock?key=%2FUsers%2Folasumbo%2F.crc%2Fmachines%2Fcrc%2Fid_ed25519
127.0.0.1:19080 -> 192.168.127.102:80
127.0.0.1:20443 -> 192.168.127.130:443
127.0.0.1:2222 -> 192.168.127.2:22
127.0.0.1:6443 -> 192.168.127.2:6443
:443 -> 192.168.127.2:443
:80 -> 192.168.127.2:80
```

**What to look for:**

- The route goes to the laptop's own network (`en0` and its gateway, here
  `192.168.166.1`), not to CRC: `curl` times out (exit `28`).
- `127.0.0.1:19080 -> 192.168.127.102:80` and `127.0.0.1:20443 ->
  192.168.127.130:443` are the forwards module 19 and the ingress shard added
  to reach their MetalLB addresses. The others are CRC's own.
- The [ingress shard, step 8](../ingress-shard/README.md#step-8--from-the-laptop)
  adds one and gets `200` through it. Where the clients are on the network, or
  route to it, no forward is needed.

`.102` was used here, not `.100`: `.100` has no announcement status (step 7), so a timeout
there could come from the missing announcement as well as from the routing.

### Step 9 — check yourself

```console
$ oc diff -f manifests/ && echo 'the cluster matches manifests/'
the cluster matches manifests/
```

**What to look for:** `oc diff` finds no changes to apply from
[`manifests/`](manifests/). It uses server-side dry-run and does not persist
changes. Exit 0 means no differences, 1 means differences, and a higher value
means an error. Steps 3, 4, 6 and 7 check the operator, workloads, configuration
and existing announcements. This is not an end-to-end test with a new backend.

## The options

**`MetalLB`** (`metallb.io/v1beta1`), one per cluster:

| Field | Default | What it does |
|---|---|---|
| `nodeSelector` | none: every Linux node | which nodes run a speaker. Only those announce addresses |
| `speakerTolerations`, `controllerTolerations` | not set in this CR | configure additional tolerations for tainted nodes; this does not mean the generated pods have no built-in tolerations |
| `logLevel` | `info` | the controller's and speaker's log level |

**`IPAddressPool`** (`metallb.io/v1beta1`):

| Field | Default | What it does |
|---|---|---|
| `addresses` | — | ranges (`a-b`) or CIDRs; pools may not overlap (the webhook refuses it) |
| `autoAssign` | `true` | whether MetalLB may choose this pool automatically; explicit pool or IP requests can still use it when `false` |
| `serviceAllocation` | none | which Services the pool is for, by namespace or label (the ingress shard uses it) |

**`L2Advertisement`** (`metallb.io/v1beta1`):

| Field | Default | What it does |
|---|---|---|
| `ipAddressPools`, `ipAddressPoolSelectors` | none: every pool | which pools it announces |
| `interfaces` | none: every interface | where the speaker answers ARP |
| `nodeSelectors` | none: every node | which nodes may announce |

## What production does differently

| Here (CRC) | Production |
|---|---|
| layer 2: one node answers ARP for each address, and all its traffic enters there | often **BGP**: the speakers peer with the network's routers (`BGPPeer`, `BGPAdvertisement`, through FRR-K8s), which spread traffic over several nodes. Layer 2 stays the simple choice where there are no BGP routers; Red Hat's docs name its limits: one node's bandwidth, and failover that "depends on cooperation from the clients" |
| the pool is on gvproxy's private network; the laptop needs a forward (step 8) | a pool from the network team, **routable** from the clients, so no forward |
| `autoAssign: false` on `mongot-pool`; its three listed consumers name it | often `autoAssign: true` on a default pool, plus pools kept for some teams with `serviceAllocation` (namespaces, labels, `priority`) |
| one node, one speaker | a speaker on each node that should announce (`nodeSelector`), so an address moves to another node if one fails |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| the CSV `Failed`, reason `UnsupportedOperatorGroup`, `OwnNamespace InstallModeType not supported, cannot configure to watch own namespace` (`oc get csv -n metallb-system -o jsonpath='{.items[*].status.reason}'`) | the `OperatorGroup` targets only its own namespace; this operator supports `AllNamespaces` only (step 1). From the source, not reproduced here | use an all-namespace group on a fresh install (step 2); repair of a shared group is outside this read-only walk |
| no `metallb-operator` in `oc get packagemanifest -n openshift-marketplace` | the `redhat-operators` catalog is off or unreachable | `oc get catalogsource -n openshift-marketplace`; on a disconnected cluster, mirror it |
| no `controller` or `speaker` pods, but the CSV is `Succeeded` | no `MetalLB` resource | step 4 |
| a Service stays `<pending>` in `EXTERNAL-IP`; `oc describe svc` shows `AllocationFailed … no available IPs` | no pool may give it an address. An ordinary new Service that requests neither a pool nor an IP, and does not match `ingress-shard-pool`'s selectors, has no eligible automatic pool here. A matching Service can use that pool if it has capacity (`allocator.go`, `Allocate`, `pinnedPoolsForService`). From the source, not measured here | add `metallb.io/address-pool: mongot-pool` to the Service, or give it a pool of its own |
| the Service has an address, but nothing answers, even from the CRC network | not announced: no `ServiceL2Status` for it. Possible causes include no eligible endpoint (source behavior in step 7), or no `L2Advertisement` covers its pool, or the node is excluded (next row) | start the backend pods; check `oc get l2advertisement -n metallb-system` |
| a node never announces anything | it carries the label `node.kubernetes.io/exclude-from-external-load-balancers`, which `speakersForPool` honours unless `--ignore-exclude-lb` is enabled (from the source, not measured here). Inspect the speaker's arguments before ruling out that override | inspect the label with the read-only command in step 7; deciding whether to remove it is a separate cluster administration change |
| `the interfaces specified by LB IP … doesn't exist in assigned node` in the Service's events | the `L2Advertisement` names an interface the node does not have | `br-ex` on CRC (step 5) |
| `admission webhook "ipaddresspoolvalidationwebhook.metallb.io" denied the request: CIDR … overlaps with already defined CIDR` | the new pool overlaps an existing one | pick addresses outside every pool (step 6) |
| `curl: (28) Connection timed out` to a MetalLB address from the laptop | the laptop does not route to the CRC network (step 8) | a gvproxy forward: [ingress shard, step 8](../ingress-shard/README.md#step-8--from-the-laptop) |

## Clean up

The dry-run walk has nothing to clean up. If you removed `--dry-run=server`
for a fresh install, it created persistent shared infrastructure; leave it
in place for the later modules. Do not remove MetalLB while Services depend
on it: their load-balancer connectivity depends on its controller and speaker.

## References

- [OpenShift 4.22 — Networking Operators](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/networking_operators/index):
  "About MetalLB and the MetalLB Operator" (layer 2 concepts and limits),
  "Installing the MetalLB Operator" ("Install from the software catalog using
  the CLI", "Start MetalLB on your cluster").
- [OpenShift 4.22 — Ingress and load balancing](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html-single/ingress_and_load_balancing/index):
  "Load balancing with MetalLB", "Configuring MetalLB address pools".
- MetalLB upstream: [metallb.io](https://metallb.io/) — "Concepts", "Layer 2
  mode", "Configuration".
- Source behavior below is checked against `openshift/metallb` at
  `42b0bfe05fecebde1cf1ed6ef0640c35bb3cb3e7`, the source revision supplied for
  this operator build; the startup log containing the revision is not pasted here:
  [`speaker/layer2_controller.go`](https://github.com/openshift/metallb/blob/42b0bfe05fecebde1cf1ed6ef0640c35bb3cb3e7/speaker/layer2_controller.go),
  [`internal/allocator/allocator.go`](https://github.com/openshift/metallb/blob/42b0bfe05fecebde1cf1ed6ef0640c35bb3cb3e7/internal/allocator/allocator.go),
  [`internal/config/config.go`](https://github.com/openshift/metallb/blob/42b0bfe05fecebde1cf1ed6ef0640c35bb3cb3e7/internal/config/config.go),
  [`internal/k8s/epslices/endpoint_slices.go`](https://github.com/openshift/metallb/blob/42b0bfe05fecebde1cf1ed6ef0640c35bb3cb3e7/internal/k8s/epslices/endpoint_slices.go),
  [`controller/service.go`](https://github.com/openshift/metallb/blob/42b0bfe05fecebde1cf1ed6ef0640c35bb3cb3e7/controller/service.go).
- operator-framework/api v0.45.0,
  [`InstallModeSet.Supports`](https://github.com/operator-framework/api/blob/v0.45.0/pkg/operators/v1alpha1/clusterserviceversion.go).

## Diagram sources

The figure is rendered from [`docs/diagrams/metallb/source.html`](../../docs/diagrams/metallb/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with [diagram-kit](https://github.com/ephico2real2/diagram-kit) (MPL-2.0), which writes a PNG only when the page
passes its checks (the install is in the [root README](../../README.md#tooling)):

```bash
# from the repository root
diagram-render docs/diagrams/metallb/source.html docs/diagrams/metallb metallb
```
