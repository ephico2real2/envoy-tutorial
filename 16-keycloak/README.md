# 16 — a Keycloak lab: a real identity provider

Modules 06 and 14 checked JSON Web Tokens signed with a **shared secret** that
this repository prints in clear — enough to see the mechanics, and exactly what
production must never do. In production the tokens come from an **identity
provider**: a server that knows the users, checks their passwords, and signs
tokens with a **private key** it never shares. Anyone who wants to check a
token fetches the matching **public** keys from it.

This lab builds one, step by step: the **Red Hat build of Keycloak**, installed
by its operator from OpenShift's own catalog, with its own database, its own TLS
certificate, and a realm with users, roles and applications. Module 17 then puts
the Gateway in front of it.

## What you'll learn

- how an operator is installed on OpenShift — a `Subscription`, an
  `OperatorGroup`, and the **manual approval** of its `InstallPlan`
- what Keycloak needs around it: a PostgreSQL database, a TLS certificate, a
  hostname, a Route
- what a **realm** is: users, roles, and **clients** — the applications allowed
  to ask for tokens — imported as a Kubernetes resource
- how to get a token, and how to read one: issuer, audience, roles, lifetime —
  and where the keys to check it are published

## Before you start

- [`00-prerequisites`](../00-prerequisites/README.md) passes, including
  **cert-manager** and the `enterprise-ca` `ClusterIssuer` (module 08).
- **cluster-admin** rights: installing an operator is a cluster-level change.
- About 3.5 GiB of free memory (requests, measured): Keycloak 1 GiB, the operator
  450 MiB, PostgreSQL 128 MiB — and, while step 8's import runs, its Job 1.7 GiB.
- Work from this folder: `cd 16-keycloak`.
- This lab uses the namespace **`keycloak`** and takes about 20 minutes. Leave it
  running for module 17.

## The lab

<!-- markdownlint-disable MD033 -->
<img alt="The Keycloak lab in namespace keycloak. The rhbk-operator, installed from the redhat-operators catalog with a manually approved InstallPlan, runs the Keycloak server described by a Keycloak resource. Keycloak stores its data in a PostgreSQL StatefulSet with a 1 GiB volume claim, serves HTTPS with a cert-manager certificate from enterprise-ca, and is reached from outside through a passthrough Route at keycloak.apps-crc.testing and from inside at keycloak-service.keycloak.svc:8443. A KeycloakRealmImport creates the realm tutorial: roles reader and admin, users alice and bob, clients shop-api, shop-cli and orders-service. A client asks the token endpoint for a token, signed RS256 with a private key; the public keys are published at the realm's certs endpoint." src="../docs/diagrams/16-keycloak/lab.light.png">
<!-- markdownlint-enable MD033 -->

## Walkthrough

### Step 1 — find the operator

OpenShift ships a catalog of operators, `redhat-operators`. Ask it about
Keycloak's:

```console
$ oc get packagemanifest rhbk-operator -n openshift-marketplace -o jsonpath='{.status.catalogSource}  default channel: {.status.defaultChannel}{"\n"}'
redhat-operators  default channel: stable-v26.6
$ oc get packagemanifest rhbk-operator -n openshift-marketplace -o jsonpath='{range .status.channels[*]}{.name}  {.currentCSV}{"\n"}{end}'
stable-v22  rhbk-operator.v22.0.13-opr.1
stable-v22.0  rhbk-operator.v22.0.13-opr.1
stable-v24  rhbk-operator.v24.0.11-opr.1
stable-v24.0  rhbk-operator.v24.0.11-opr.1
stable-v26  rhbk-operator.v26.6.7-opr.1
stable-v26.0  rhbk-operator.v26.0.17-opr.1
stable-v26.2  rhbk-operator.v26.2.16-opr.1
stable-v26.4  rhbk-operator.v26.4.16-opr.1
stable-v26.6  rhbk-operator.v26.6.7-opr.1
```

**What just happened:** one **channel** per Keycloak line — `stable-v26.6` is the
default and the newest. A channel is a promise: the operator follows it for
updates, and never jumps to another line on its own.

### Step 2 — install it, and approve it

[`manifests/10-operator.yaml`](manifests/10-operator.yaml) creates the namespace,
an **`OperatorGroup`** — the operator may manage this namespace only — and a
**`Subscription`** to channel `stable-v26.6` with **`installPlanApproval:
Manual`**, as Red Hat's operator guide recommends: no version is installed, and
no upgrade happens, until someone approves it.

```console
$ oc apply -f manifests/10-operator.yaml
namespace/keycloak created
operatorgroup.operators.coreos.com/keycloak created
subscription.operators.coreos.com/rhbk-operator created
$ sleep 30; oc get installplan -n keycloak -o custom-columns=NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames,APPROVED:.spec.approved
NAME            CSV                             APPROVED
install-txlqv   [rhbk-operator.v26.6.7-opr.1]   false
```

**What just happened:** OLM — the Operator Lifecycle Manager — prepared an
**InstallPlan** for version 26.6.7, and it waits: `APPROVED false`. Approve it,
and wait for the operator:

```console
$ oc patch installplan "$(oc get subscription rhbk-operator -n keycloak -o jsonpath='{.status.installPlanRef.name}')" -n keycloak --type=merge -p '{"spec":{"approved":true}}'
installplan.operators.coreos.com/install-txlqv patched
$ for i in $(seq 1 60); do [ "$(oc get csv "$(oc get subscription rhbk-operator -n keycloak -o jsonpath='{.status.installedCSV}')" -n keycloak -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ] && break; sleep 5; done; oc get subscription rhbk-operator -n keycloak -o jsonpath='{.status.installedCSV}{"\n"}'
rhbk-operator.v26.6.7-opr.1
$ oc get pods -n keycloak
NAME                             READY   STATUS    RESTARTS   AGE
rhbk-operator-864584d99b-c44qv   1/1     Running   0          14s
$ oc api-resources --api-group=k8s.keycloak.org
NAME                   SHORTNAMES   APIVERSION                 NAMESPACED   KIND
keycloakrealmimports                k8s.keycloak.org/v2beta1   true         KeycloakRealmImport
keycloaks              kc           k8s.keycloak.org/v2beta1   true         Keycloak
```

**What just happened:** the operator runs, and brings two new kinds of resource:
**`Keycloak`** — a server — and **`KeycloakRealmImport`** — a realm to create in
it. Their API version is **`v2beta1`**; read it from `oc api-resources`, not from
an older example.

### Step 3 — a database

The operator does not provide Keycloak's database: "you need to provision it
yourself". [`manifests/20-postgres.yaml`](manifests/20-postgres.yaml) is a
**lab** PostgreSQL — one pod, a 1 GiB volume, and a password in a `Secret`
written in the file. It uses Red Hat's PostgreSQL 16 image, which runs as the
random UID OpenShift assigns:

```console
$ oc apply -f manifests/20-postgres.yaml
secret/keycloak-db created
service/postgres created
statefulset.apps/postgres created
$ oc rollout status statefulset/postgres -n keycloak --timeout=300s
Waiting for 1 pods to be ready...
partitioned roll out complete: 1 new pods have been updated...
$ oc get pvc -n keycloak
NAME              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                   VOLUMEATTRIBUTESCLASS   AGE
data-postgres-0   Bound    pvc-311fef4e-d4b3-4d22-8657-77591354dcfd   119Gi      RWO            crc-csi-hostpath-provisioner   <unset>                 11s
```

The claim asked for 1 GiB, and the capacity shown is 119Gi: CRC's storage
provisioner (a directory on the VM's disk) reports a capacity of its own instead
of the size requested — do not read it as the volume's size.

### Step 4 — a TLS certificate

Keycloak should speak HTTPS itself, with a certificate for both of the names it
will be reached by — the Route's, and the Service's, for callers inside the
cluster ([`manifests/30-certificate.yaml`](manifests/30-certificate.yaml)):

```console
$ oc apply -f manifests/30-certificate.yaml
certificate.cert-manager.io/keycloak-tls created
$ oc wait certificate/keycloak-tls -n keycloak --for=condition=Ready --timeout=120s
certificate.cert-manager.io/keycloak-tls condition met
$ oc get secret keycloak-tls -n keycloak -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -text | grep -E '^issuer=|Subject Alternative Name|DNS:'
issuer=O=Enterprise POC, CN=Enterprise Root CA
            X509v3 Subject Alternative Name: critical
                DNS:keycloak.apps-crc.testing, DNS:keycloak-service.keycloak.svc, DNS:keycloak-service.keycloak.svc.cluster.local
```

### Step 5 — the Keycloak server

[`manifests/40-keycloak.yaml`](manifests/40-keycloak.yaml): one instance, the
database from step 3, the certificate from step 4, and the public **hostname**
`https://keycloak.apps-crc.testing` — the name Keycloak writes into every token
it signs. Keycloak starts, connects to the database and creates its tables —
under half a minute here:

```console
$ oc apply -f manifests/40-keycloak.yaml
secret/keycloak-admin created
keycloak.k8s.keycloak.org/keycloak created
$ oc wait keycloak/keycloak -n keycloak --for=condition=Ready --timeout=600s
keycloak.k8s.keycloak.org/keycloak condition met
$ oc get pods,svc -n keycloak
NAME                                 READY   STATUS    RESTARTS   AGE
pod/keycloak-0                       1/1     Running   0          20s
pod/postgres-0                       1/1     Running   0          31s
pod/rhbk-operator-864584d99b-c44qv   1/1     Running   0          45s

NAME                         TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)             AGE
service/keycloak-discovery   ClusterIP   None           <none>        7800/TCP            20s
service/keycloak-service     ClusterIP   10.217.5.113   <none>        8443/TCP,9000/TCP   20s
service/postgres             ClusterIP   10.217.5.188   <none>        5432/TCP            31s
```

**What just happened:** the operator created a **StatefulSet** (`keycloak-0`) and
two Services: **`keycloak-service`** — HTTPS on 8443, and a management port,
9000 — and `keycloak-discovery`, which Keycloak instances use to find each other
when there are several.

### Step 6 — a way in

[`manifests/50-route.yaml`](manifests/50-route.yaml) is a **passthrough** Route
(module 08): the router forwards the TLS untouched, so callers see Keycloak's own
certificate. Test it from the `client` pod, trusting only the enterprise CA —
copy the CA into the pod first:

```console
$ oc apply -f manifests/50-route.yaml
route.route.openshift.io/keycloak created
$ oc apply -n keycloak -f ../_shared/client.yaml
pod/client created
$ oc wait -n keycloak --for=condition=Ready pod/client --timeout=120s
pod/client condition met
$ oc get secret keycloak-tls -n keycloak -o jsonpath='{.data.ca\.crt}' | base64 -d | oc exec -i -n keycloak client -- sh -c 'cat > /tmp/ca.crt'
$ oc exec -n keycloak client -- curl -s --cacert /tmp/ca.crt -o /dev/null -w '%{http_code}\n' https://keycloak.apps-crc.testing/realms/master
200
```

`200`: the Route, the certificate and the server all work. `master` is the realm
Keycloak always has — for administering Keycloak itself, not for applications.

### Step 7 — the admin console

Keycloak's first administrator comes from the Secret `keycloak-admin`, in
[`manifests/40-keycloak.yaml`](manifests/40-keycloak.yaml) — the `Keycloak`
resource names it under `bootstrapAdmin`. Like every credential in this lab, it
is a **published test value**:

| | |
|---|---|
| console | **https://keycloak.apps-crc.testing/admin/** |
| user name | `admin` |
| password | `lab-only-admin-password` |

The same two values, read back from the cluster:

```console
$ oc get secret keycloak-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d; echo
admin
$ oc get secret keycloak-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d; echo
lab-only-admin-password
```

Open the console in a browser and sign in with them. The browser will warn about
the certificate: it is signed by the enterprise CA, which your laptop does not
trust. Keycloak reads `bootstrapAdmin` only once, when it first creates its
database — change the Secret later and the admin's password stays what it was.
Without `bootstrapAdmin`, the operator makes a random temporary admin instead,
in the Secret `keycloak-initial-admin`.

Outside a lab, never publish an admin password: follow the operator guide —
create a named administrator, remove the bootstrap one, and turn on MFA. The rest
of this lab does not need the console — everything is in files.

### Step 8 — the realm

A **realm** is a separate world of users, roles and applications.
[`manifests/60-realm.yaml`](manifests/60-realm.yaml) creates **`tutorial`**:

| In the realm | Here | What it is |
|---|---|---|
| realm roles | `reader`, `admin` | what a caller may do — module 17 authorises on them |
| user `alice` | role `reader` | a person |
| user `bob` | roles `reader`, `admin` | a person with more rights |
| client `shop-api` | no grant of its own | the API the tokens are **for** — their audience, `aud` |
| client `shop-cli` | public, **password** grant | a tool a person uses. Lab only: OAuth 2.1 drops this grant — a real app sends the person to Keycloak's login page |
| client `orders-service` | confidential, **client credentials** | a service calling the API on its own behalf, with a secret |

The two clients that get tokens carry an **audience mapper**: their tokens say
`aud: shop-api`, so an API can refuse tokens that were meant for something else.
The passwords and the secret are **lab values**, written in clear so every step
can be repeated. Import it:

```console
$ oc apply -f manifests/60-realm.yaml
keycloakrealmimport.k8s.keycloak.org/tutorial created
$ oc wait keycloakrealmimport/tutorial -n keycloak --for=condition=Done --timeout=300s
keycloakrealmimport.k8s.keycloak.org/tutorial condition met
$ oc get keycloakrealmimport tutorial -n keycloak -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
Done=True
Started=False
HasErrors=False
```

**What just happened:** the operator ran the import as a one-off Job. An import
only **creates**: it never changes a realm that already exists, so editing the
file and applying it again does nothing to `tutorial`.

### Step 9 — where a token checker looks

Anything that checks this realm's tokens needs two facts. Keycloak publishes both
in its **discovery document**:

```console
$ oc exec -n keycloak client -- curl -s --cacert /tmp/ca.crt https://keycloak.apps-crc.testing/realms/tutorial/.well-known/openid-configuration | python3 -c 'import json,sys; d = json.load(sys.stdin); [print(k, d[k]) for k in ("issuer", "token_endpoint", "jwks_uri")]'
issuer https://keycloak.apps-crc.testing/realms/tutorial
token_endpoint https://keycloak.apps-crc.testing/realms/tutorial/protocol/openid-connect/token
jwks_uri https://keycloak.apps-crc.testing/realms/tutorial/protocol/openid-connect/certs
$ oc exec -n keycloak client -- curl -s --cacert /tmp/ca.crt https://keycloak.apps-crc.testing/realms/tutorial/protocol/openid-connect/certs | python3 -c 'import json,sys; [print(k["kid"], k["kty"], k["alg"], k["use"]) for k in json.load(sys.stdin)["keys"]]'
aXTYcJVckrLioYkR7tXcG0mmNlRsqywPuIJCztVYj48 RSA RS256 sig
IyhgBoC6XINttLqROnF2uITd_16MDLYq3hqK9fXCFQU RSA RSA-OAEP enc
```

**What just happened:**

- **`issuer`** — the exact string every token's `iss` claim carries: the
  `hostname` from step 5, plus `/realms/tutorial`.
- **`jwks_uri`** — the **public** keys, as a JSON Web Key Set. One is for
  signing (`use: sig`, `RS256`); the other (`enc`, `RSA-OAEP`) is for encrypting
  and plays no part here. Each has a key id, `kid`, which every token names in its
  header.

### Step 10 — get a token, and read it

As **alice**, through `shop-cli`, with the password grant. The token is three
base64 parts; the second is the **claims**:

```console
$ oc exec -n keycloak client -- curl -s --cacert /tmp/ca.crt -d grant_type=password -d client_id=shop-cli -d username=alice -d password=alice-lab-password https://keycloak.apps-crc.testing/realms/tutorial/protocol/openid-connect/token | python3 -c 'import base64,json,sys; t = json.load(sys.stdin)["access_token"]; part = lambda i: json.loads(base64.urlsafe_b64decode(t.split(".")[i] + "==")); h, c = part(0), part(1); print("header:", h["alg"], "kid", h["kid"]); [print(" ", k, c.get(k)) for k in ("iss", "aud", "azp", "preferred_username", "realm_access")]; print("  lives", c["exp"] - c["iat"], "s")'
header: RS256 kid aXTYcJVckrLioYkR7tXcG0mmNlRsqywPuIJCztVYj48
  iss https://keycloak.apps-crc.testing/realms/tutorial
  aud shop-api
  azp shop-cli
  preferred_username alice
  realm_access {'roles': ['reader']}
  lives 300 s
```

**What just happened:** a token **signed with `RS256`**, by the key whose `kid`
is in the JWKS from step 9. Its claims: **`iss`** — this realm; **`aud:
shop-api`** — the audience mapper at work; **`azp: shop-cli`** — the client that
asked; alice's **role**; and a lifetime of **300 s**, the realm's
`accessTokenLifespan`. Anyone can *read* these claims — they are base64, not
encrypted. What nobody can do without Keycloak's private key is *change* them:
the signature would no longer match.

A service, with no person involved — **client credentials**:

```console
$ oc exec -n keycloak client -- curl -s --cacert /tmp/ca.crt -d grant_type=client_credentials -d client_id=orders-service -d client_secret=orders-service-lab-secret https://keycloak.apps-crc.testing/realms/tutorial/protocol/openid-connect/token | python3 -c 'import base64,json,sys; t = json.load(sys.stdin)["access_token"]; c = json.loads(base64.urlsafe_b64decode(t.split(".")[1] + "==")); [print(" ", k, c.get(k)) for k in ("aud", "azp", "preferred_username", "realm_access")]'
  aud shop-api
  azp orders-service
  preferred_username service-account-orders-service
  realm_access {'roles': ['reader']}
```

The same audience, the service's own identity — `service-account-orders-service`
— and the role the realm gave it. And a wrong password gets no token at all:

```console
$ oc exec -n keycloak client -- curl -s --cacert /tmp/ca.crt -d grant_type=password -d client_id=shop-cli -d username=alice -d password=wrong https://keycloak.apps-crc.testing/realms/tutorial/protocol/openid-connect/token; echo
{"error":"invalid_grant","error_description":"Invalid user credentials"}
```

### Step 11 — check yourself

```console
$ ./run.sh verify

1. the operator and the server
  ✓ operator installed
  ✓ Keycloak Ready
  ✓ realm import Done

2. what a token checker needs: the issuer and the signing keys
  ✓ the discovery document names the issuer
  ✓ the JWKS has an RS256 signing key
  ✓ ...reachable at the Service too, for in-cluster callers

3. tokens
  ✓ alice: issued by the realm
  ✓ alice: for shop-api (aud)
  ✓ alice: role reader only
  ✓ bob: roles admin and reader
  ✓ orders-service: its own token
  ✓ orders-service: for shop-api (aud)
  ✓ a wrong password gets no token

all checks passed
```

## What production does differently

| Here (lab) | Production |
|---|---|
| one PostgreSQL pod, password in a file | a managed or replicated database; credentials from a vault |
| `instances: 1` | two or more, spread over nodes |
| users and secrets in a realm file | users from a directory (LDAP, AD) or self-registration; secrets never in git |
| the password grant (`shop-cli`) | the authorization-code flow with PKCE, through Keycloak's login page |
| a published admin password (`bootstrapAdmin`) | a named admin, MFA on, the bootstrap admin removed |
| a certificate from a lab CA | the organisation's CA, or a public one for public hostnames |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| the Subscription stays `UpgradePending`, no operator pod | the InstallPlan waits for approval | step 2's `oc patch installplan … approved: true` |
| several CSVs in `keycloak` | OLM copies the CSVs of cluster-wide operators into every namespace (`reason: Copied`) | read the one the Subscription installed: `status.installedCSV` |
| a password login says `Account is not fully set up` | Keycloak's user profile wants a first name, last name and email | give the user all three (the realm file does) |
| `invalid_grant`, `Invalid user credentials` | wrong user name or password | expected for a wrong password (step 10) |
| `unauthorized_client`, `Client not allowed for direct access grants` | the client does not allow the password grant — measured with `orders-service` | `directAccessGrantsEnabled: true` — and only in a lab |
| editing the realm file changes nothing | an import only creates a realm — measured: a changed token lifespan, re-applied, ran no new import and tokens kept the old lifespan | change it in the console, or delete the realm and import again |
| `curl: (60) SSL certificate problem` | the caller does not trust the enterprise CA | copy `ca.crt` as in step 6 |

## Clean up

Leave the lab running if you go on to module 17. To remove it — the server, the
database and its volume, and the operator. On CRC the database's volume outlives
its claim — the StorageClass keeps volumes (`reclaimPolicy: Retain`), and an
earlier clean-up left one behind, `Released`, data and all (measured) — so mark it
for deletion first:

<!-- walkthrough: skip -->
```console
$ oc patch pv "$(oc get pvc data-postgres-0 -n keycloak -o jsonpath='{.spec.volumeName}')" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
$ oc delete keycloakrealmimport tutorial -n keycloak
$ oc delete keycloak keycloak -n keycloak
$ oc delete subscription rhbk-operator -n keycloak
$ oc delete csv rhbk-operator.v26.6.7-opr.1 -n keycloak
$ oc delete namespace keycloak --wait=false
```

OLM leaves the operator's two CRDs, `keycloaks.k8s.keycloak.org` and
`keycloakrealmimports.k8s.keycloak.org`; delete them only if no other Keycloak
operator on the cluster uses them.

## The shortcut

`./run.sh deploy` does steps 2 to 8, approving the InstallPlan for you;
`./run.sh verify` is step 11; `./run.sh clean` is the clean-up.

## References

- [Red Hat build of Keycloak 26.6 — Operator Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/operator_guide/index)
- [Red Hat build of Keycloak 26.6 — Server Administration Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/server_administration_guide/index)
- [OpenShift — installing operators with OLM](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/operators/user-tasks)
- [OpenID Connect Discovery 1.0](https://openid.net/specs/openid-connect-discovery-1_0.html)
- [RFC 7517 — JSON Web Key](https://www.rfc-editor.org/rfc/rfc7517)
- [RFC 7519 — JSON Web Token](https://www.rfc-editor.org/rfc/rfc7519)

## Diagram sources

The figure is rendered from [`docs/diagrams/16-keycloak/source.html`](../docs/diagrams/16-keycloak/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
