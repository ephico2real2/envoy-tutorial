# argocd — the Keycloak offering, kept as declared

Modules 16, 17 and 18 are not only lessons: on the operator's CRC they are a
**standing Keycloak offering** that other work depends on
([#9](https://github.com/ephico2real2/envoy-tutorial/issues/9)). `./run.sh` in
each module builds it and checks it; the Argo CD **Applications** here keep
it as git declares it — with module 19's shop, the first application integrated
with it. One per module, in OpenShift GitOps' instance
`openshift-gitops`, each on the `main` branch of this repository and on the
**same files** that module's `./run.sh deploy` applies:

| Application | Source | Keeps |
|---|---|---|
| [`16-keycloak`](16-keycloak.yaml) | `16-keycloak/manifests` | namespace `keycloak`, the operator's `Subscription`, PostgreSQL, the certificate, the `Keycloak` resource, its Route, realm import `tutorial`, the `BackendTLSPolicy` every Gateway reaches `keycloak-service` with |
| [`17-keycloak-jwt`](17-keycloak-jwt.yaml) | `17-keycloak-jwt/manifests`, and `_shared/echo-app.yaml` into `envoy-17` | namespace `envoy-17`, Gateway `eg`, its routes and SecurityPolicies, the `ReferenceGrant` in `keycloak`, the echo app |
| [`18-keycloak-ldap`](18-keycloak-ldap.yaml) | `18-keycloak-ldap/manifests` | the LDAP bind password's Secret, realm import `corp` (not Secret `shop-kiosk-client`, which `run.sh` generates) |
| [`19-shop-gateway`](19-shop-gateway.yaml) | `19-shop-gateway/manifests`, and `_shared/echo-app.yaml` into `envoy-19` | namespace `envoy-19`, Gateway `eg`, the shop (vendored from `envoy-grpc-modernization`), its NetworkPolicies, route and `SecurityPolicy`, the `ReferenceGrant` in `keycloak` (not the client Secret, which `run.sh` copies), the echo app behind `/whoami` — an integration of the offering (module 16's index) |

Beside the Keycloak offering, one more Application keeps a piece of platform that
module 20 builds on
([#17](https://github.com/ephico2real2/envoy-tutorial/issues/17)). It follows the
same pattern:

| Application | Source | Keeps |
|---|---|---|
| [`ingress-shard`](ingress-shard.yaml) | `00-prerequisites/ingress-shard/manifests`, and `_shared/echo-app.yaml` into `ingress-shard` | pool `ingress-shard-pool` and `L2Advertisement ingress-shard-l2` in `metallb-system`; the shard's certificate in `openshift-ingress`; `IngressController metallb`; namespace `ingress-shard` (`Prune=false`, as `keycloak`) with Route `canary` and the echo app |

The laptop's forward to the shard's address is not in the cluster, so it stays
`run.sh`'s ([its Permanent lab](../00-prerequisites/ingress-shard/README.md#permanent-lab)).
Measured after #17 merged (`main` at `9d9c029`), on the lab `./run.sh deploy`
had built: `Synced/Healthy` 10 s after `oc apply -f argocd/ingress-shard.yaml`;
every object's UID unchanged — adopted, not re-created; over 3 minutes, 0 of 36
samples off `Synced/Healthy`, and one sync operation. The default
`IngressController`, whose route selector the shard's `run.sh` sets, is not
tracked: it carries no `tracking-id` and is not among the Application's resources
(read again 2026-09-27 during #15).

Argo CD applies these files and puts back whatever differs from them — a deleted
object, an edited field. It does **not** run `run.sh`: what `deploy` does by hand
— approving the operator's InstallPlan, the `nonroot-v2` grant, copying Keycloak's
CA, fetching and checking the directory's root — stays `run.sh`'s, each with its
reason in the module's "Permanent lab" section
([16](../16-keycloak/README.md#permanent-lab), [17](../17-keycloak-jwt/README.md#permanent-lab),
[18](../18-keycloak-ldap/README.md#permanent-lab), [19](../19-shop-gateway/README.md#permanent-lab)).

## Putting them on a cluster

`run.sh` first: it does the steps no manifest can, and each module's `verify`
must pass. Then the Applications:

```bash
16-keycloak/run.sh deploy && 18-keycloak-ldap/run.sh deploy && 17-keycloak-jwt/run.sh deploy && 19-shop-gateway/run.sh deploy
oc apply -f argocd/
```

The first sync applies the files as they are — the objects already match them —
and adds Argo CD's tracking annotation to each: no pod restarted and no import
ran again (measured: the same pod UIDs in `keycloak` and `envoy-17`, and the
same two import Jobs, before and after). `oc diff -f` of every file each
Application keeps is empty afterwards (measured, all 14).

## Is it healthy?

```console
$ oc get applications.argoproj.io 16-keycloak 17-keycloak-jwt 18-keycloak-ldap -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTOMATED:.spec.syncPolicy.automated.enabled
NAME               SYNC     HEALTH    AUTOMATED
16-keycloak        Synced   Healthy   true
17-keycloak-jwt    Synced   Healthy   true
18-keycloak-ldap   Synced   Healthy   true
```

`Synced`: the cluster matches git. `Healthy`: Argo CD's health checks pass —
among them the operator's `Subscription`, which says `Progressing` while a new
operator version waits for its manual approval (argo-cd v3.4.7,
`resource_customizations/operators.coreos.com/Subscription/health.lua`). The lab
itself is healthy when each module's `./run.sh verify` passes.

## How fast it puts a change back

Measured on this CRC (Argo CD v3.4.7, OpenShift GitOps 1.21.4):

| Change | Back after |
|---|---|
| ConfigMap `echo-src` deleted, 1 min 37 s after the previous repair | 0.7 s |
| `KeycloakRealmImport corp` deleted, 2 min 14 s after the previous repair | 0.7 s — its new Job logged `Realm 'corp' already exists. Import skipped` |
| ConfigMap `echo-src` deleted 4 min 19 s after the previous repair (made when `./run.sh deploy` resumed the Application) | 41 s — 300 s after that repair |
| ConfigMap `echo-src` deleted right after that | 300 s |
| a label of Service `echo` changed, after a run of repairs | 3 min 12 s — 300 s after the previous repair |

Argo CD spaces out repairs of the same git revision: after each one it waits
longer before the next — 2 s, 6 s, 18 s, 54 s, 162 s, then 300 s at most, counted
from the previous repair (the controller's defaults,
`--self-heal-backoff-timeout-seconds 2`, `--self-heal-backoff-factor 3`,
`--self-heal-backoff-cap-seconds 300`; the count lives in the last operation,
`controller/appcontroller.go`). A repair applies only the objects that differ.

## Pause and resume

Because it puts things back, Argo CD would undo a walkthrough step that changes
an object on purpose (module 17's step 7, module 18's step 13) and a clean-up as
it happens. Each module's `run.sh` has two more commands, from
[`../_shared/argocd.sh`](../_shared/argocd.sh):

- **`./run.sh pause`** sets the Application's `spec.syncPolicy.automated.enabled`
  to `false`, asks Argo CD to compare again, and returns only once the
  controller has done so and no sync operation is pending or running: turning
  automated sync off stops new syncs, not one under way, which could re-create
  what a clean deletes next. Five minutes at most; then it fails, and a clean
  stops before it deletes anything. Argo CD still compares — the Application
  says `OutOfSync` once something differs — but changes nothing. Measured:
  paused, a deleted `echo-src` stayed deleted for 3 min 43 s, through a full
  reconciliation. Pausing does not stop someone syncing by hand.
- **`./run.sh resume`** sets it back to `true`, asks Argo CD to compare again —
  a refused request fails — and waits until it says `Synced`: up to ten
  minutes, because a repair can start 300 s after the previous one and then
  needs its own time. A status it cannot read fails too; `Synced` with another
  health (a waiting operator upgrade) passes at the deadline, with a note.
  Measured: `echo-src` was back in the second `resume` was run, and `resume`
  returned 5 s later.
- **`./run.sh clean`** pauses before it deletes anything (module 16's pauses 16,
  17, 18 and 19: the other three keep objects in `keycloak`; module 18's pauses 18
  and 19, whose shop signs in on realm `corp`). Measured with module 17, before
  #15: for 4 minutes after its clean, namespace `envoy-17` stayed gone and the
  Application said `OutOfSync` / `Missing`. Since #15 module 17's clean removes
  namespace `envoy-17` and its `ReferenceGrant` only: module 16's `BackendTLSPolicy
  keycloak-service` and ConfigMap `keycloak-ca` stay, because every Gateway that
  calls Keycloak shares them. Each clean fails, with the step's own error, when a
  deletion fails; an object already gone counts as deleted.
- **`./run.sh deploy`** resumes its Application at the end, once the lab is up.

Why this switch: `automated.enabled` exists for it (`oc explain
application.spec.syncPolicy.automated.enabled`: "Enable allows apps to explicitly
control automated sync") and keeps every other setting; removing `automated`
would lose `prune` and `selfHeal`, to be written back by hand. The annotation
`argocd.argoproj.io/skip-reconcile` makes the controller skip the Application
altogether (`controller/appcontroller.go`, `canProcessApp`), so its status would
no longer show what differs. The `argocd`
CLI is not installed here (`which argocd`: not found); `oc patch` is all it takes.
`oc apply -f argocd/` resumes too: the files say `enabled: true`.

## Moving an object from one Application to another

Argo CD here tracks what it keeps by an **annotation**, not a label: `argocd-cm`
says `application.resourceTrackingMethod: annotation`, and each kept object
carries `argocd.argoproj.io/tracking-id: <application>:<group>/<kind>:<namespace>/<name>`
(no `app.kubernetes.io/instance` label — measured on the `BackendTLSPolicy` below).
An Application's own objects are the live ones whose annotation names it, plus the
ones its git files declare (gitops-engine, `pkg/cache/cluster.go`,
`GetManagedLiveObjs`; argo-cd v3.4.7, `controller/cache/cache.go`); what it owns
and git no longer declares, it **prunes** (`prune: true`). An object git declares
for an Application while another's annotation is on it gets a
`SharedResourceWarning` (`controller/state.go`), and a sync of the declaring
Application writes its own annotation over another Application's (measured at
#15's merge, below).

So when a file moves from one module's `manifests/` to another's — the
`BackendTLSPolicy` `keycloak/keycloak-service`, from 17 to 16 (#15) — the old
Application must not look before the new one has taken it: seeing its annotation
and no file, it deletes the object. The order, around the merge:

1. `17-keycloak-jwt/run.sh pause` — the old owner makes no change.
2. Merge.
3. Let `16-keycloak` compare and sync (`16-keycloak/run.sh resume` asks for it and
   waits for `Synced/Healthy`) until the object's `tracking-id` names
   `16-keycloak`.
4. `17-keycloak-jwt/run.sh resume` — the annotation is not 17's any more: nothing
   to prune.
5. The object's `uid` is the one recorded before step 1: it was never deleted.

**Measured at #15's merge (`1abee92`, 2026-09-27):**
- **Before step 1:** uid `0590bf8a-…`, tracking-id `17-keycloak-jwt:…`.
- **After step 3:** tracking-id `16-keycloak:gateway.networking.k8s.io/BackendTLSPolicy:keycloak/keycloak-service`, the same uid; 16 lists the object Synced.
- **After step 4:** still the same uid and still tracked by 16.
- **Afterwards:** `verify` passed for 16, 17, 18 and 19.

The steps and output are on #15.

## How these differ from the cluster's other Applications

They follow `group-sync`'s pattern — project `default`, a public GitHub
repository, `targetRevision: main`, automated sync with `prune` and `selfHeal`,
`retry` with back-off — with these differences, each for a reason:

- **No `resources-finalizer.argocd.argoproj.io`, and no automated prune of
  namespace `keycloak`.** With the finalizer, deleting the Application deletes
  every object it keeps — for `16-keycloak`, namespace `keycloak` and with it
  the database's claim, which must never be removed. Without it, deleting an
  Application leaves the lab running. That does not cover automated prune: were
  a later commit on `main` to drop or rename the Namespace document,
  `prune: true` would delete the namespace, and the claim with it. So the
  Namespace carries `argocd.argoproj.io/sync-options: Prune=false`
  ([sync options](https://argo-cd.readthedocs.io/en/release-3.4/user-guide/sync-options/#no-prune-resources));
  `./run.sh clean --delete-data` is the one way to remove it. The annotation is
  in `16-keycloak/manifests/10-operator.yaml`, so it reaches the cluster when
  that change is merged to `main`; until then `oc diff` of that file shows
  exactly that one added line (measured).
- **`ServerSideApply=true`**, and the annotation
  `argocd.argoproj.io/compare-options: ServerSideDiff=true`. Measured without
  server-side diff: 16 and 17 stayed `OutOfSync` after their first sync —
  StatefulSet `postgres`, both HTTPRoutes, both SecurityPolicies — and Argo CD
  synced them three times in 27 seconds. The API server adds defaults the
  files do not state (an HTTPRoute's `backendRefs[].weight: 1`, a SecurityPolicy's
  `remoteJWKS.cacheDuration`, a StatefulSet's `volumeClaimTemplates` status); a
  server-side dry run puts them on both sides. With both on: `Synced` at once.
- **One side effect of server-side apply:** an object Argo CD applies loses
  kubectl's `last-applied-configuration` annotation. kubectl's own server-side
  apply moves the fields of `kubectl-client-side-apply` to the applying field
  manager, which does not declare that annotation (k8s.io/kubectl v0.34,
  `pkg/cmd/apply/apply.go`, `migrateToSSAIfNecessary`); measured, and the sync
  option `ClientSideApplyMigration=false` did not prevent it. The next `oc apply`
  of such an object prints `Warning: resource … is missing the
  kubectl.kubernetes.io/last-applied-configuration annotation … will be patched
  automatically` and adds it back. Harmless, and `oc diff` is empty either way.
  It happens to every object after `./run.sh clean` and `./run.sh deploy`:
  `deploy` creates them paused, without Argo CD's tracking annotation, so the
  resume at its end syncs each once to add it (measured with module 17).
- **No `CreateNamespace`:** the namespaces are in the manifests, so each has one
  owner; `18-keycloak-ldap` adds to `16-keycloak`'s `keycloak` and fails to sync
  if it is missing — it needs module 16.
- **`SkipDryRunOnMissingResource=true`** on 16 and 18: `Keycloak` and
  `KeycloakRealmImport` exist only once the operator is installed.
- **`automated.enabled: true`** is written out: it is the switch `pause` and
  `resume` turn.

## Not measured yet

- Whether the lab comes back by itself after `crc stop` and `crc start` — on hold
  (the operator, 2026-09-27: "Dont stop crc now").
- A forced renewal of `keycloak-tls` and of the directory's certificate, with Argo
  CD on.

Both are open in [#9](https://github.com/ephico2real2/envoy-tutorial/issues/9).
