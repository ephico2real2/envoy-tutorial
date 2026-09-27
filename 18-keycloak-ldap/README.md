# 18 — a realm federated from the cluster's LDAP

Module 16's realm `tutorial` has its users written in a file. Real organisations
keep their people in a **directory** — LDAP, or Active Directory — and every
system that needs to know who someone is asks the directory. This module gives
Keycloak a second realm, **`corp`**, whose users and groups come from the
OpenLDAP directory already running on this cluster (`ldap-testing`, the one
OpenShift's own `ldap-local` login uses):

- over the directory's **public** LDAPS name, `ldaps-ldap-testing.apps-crc.testing:443`
  — the way an identity provider outside the cluster reaches a corporate directory;
- trusting only the **CA that signed the directory's certificate**, fetched from
  the wire and checked against a copy you already trust — the production way;
- letting in only members of the **enterprise login gate**, and turning one LDAP
  group into the Keycloak role `admin`.

Everything is declared in two Kubernetes resources — module 16's `Keycloak`, and a
`KeycloakRealmImport` here. Nothing is clicked in the admin console.

## What you'll learn

- how to fetch a server's CA from the TLS handshake, why that alone proves
  nothing, and how to check it against the PKI owner's copy before trusting it
- how Keycloak federates LDAP: the provider, its attribute mappers, a group
  mapper, and a Secret placeholder that keeps the bind password out of the realm
  file (this lab commits its published test password too, marked LAB ONLY)
- how to decide who may log in — every person in the directory, or only the
  members of a gate group — and why the gate is the enterprise choice

## Before you start

- Module [`16`](../16-keycloak/README.md)'s Keycloak lab is **running**
  (`../16-keycloak/run.sh verify` passes).
- The directory in `ldap-testing` has its public LDAPS endpoint and the Keycloak
  bind account (group-sync-operator-helm-chart, `setup-local-ldap-testing`,
  section "Public LDAPS endpoint").
- **OpenSSL 3** on your laptop. macOS's `/usr/bin/openssl` is LibreSSL 3.3.6,
  which has no `-noservername` and no `-verify_hostname` (measured) — two of the
  steps below need them: `brew install openssl`.
- Work from this folder: `cd 18-keycloak-ldap`.
- This module works in the namespace **`keycloak`**, reads `ldap-testing` and
  `openshift-config`, and takes about 20 minutes. It restarts Keycloak once. On
  the operator's CRC it is **permanent**, kept by Argo CD: see
  [Permanent lab](#permanent-lab) before you change anything by hand there.

## The picture

<!-- markdownlint-disable MD033 -->
<img alt="A login in realm corp. A person, for example sarah.jones, sends a user name and password through client shop-cli to Keycloak (keycloak-0, realm corp), which a KeycloakRealmImport corp created once, with the LDAP provider, its mappers, the group-to-role mapping and the bind password from Secret keycloak-ldap-bind. Keycloak trusts the directory&#x27;s root CA from Secret ldap-root-ca, declared as an optional truststore in module 16&#x27;s Keycloak resource; the root was fetched from the route with openssl, and its SHA-256 fingerprint 0E:1F:4B:E3:...:A7:0E:14:26 matched openshift-config/ca-config-map before it was stored; a new Secret restarts Keycloak after about 45 seconds. Keycloak connects to ldaps://ldaps-ldap-testing.apps-crc.testing:443 with that name as SNI, checks the certificate&#x27;s CA and name, binds as keycloak-bind-serviceid and searches through the gate. The OpenShift router&#x27;s passthrough Route ldaps forwards the connection to OpenLDAP on 636, whose certificate from LDAP Enterprise Root CA names the public host and the Service. Keycloak then binds as the person to check the password, and reads the groups whose member is the person. Of the directory&#x27;s 11 people, the gate app-ssb-autobahnusers holds 9; bob.wilson and charlie.brown are outside it. Members of app-ocp-rbac-ocp-keycloak-admin - john.doe, alice.cooper, sarah.jones, shop.bob - get the realm role admin, and the token comes back with issuer .../realms/corp. Refusals: a root not yet trusted gives SSLHandshakeFailed, PKIX path building failed; a name not in the certificate gives No subject alternative DNS name; a person outside the gate gets invalid_grant, user_not_found. Keycloak never writes to the directory." src="../docs/diagrams/18-keycloak-ldap/federation.light.png">
<!-- markdownlint-enable MD033 -->

## Walkthrough

### Step 1 — Keycloak, and the directory's public name

```console
$ oc get keycloak keycloak -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
True
$ oc get route ldaps -n ldap-testing -o jsonpath='{.spec.host}  {.spec.tls.termination}  {.spec.port.targetPort}{"\n"}'
ldaps-ldap-testing.apps-crc.testing  passthrough  ldaps
```

**What just happened:** Keycloak is up, and the directory has a **passthrough**
Route on 443 (module 08): the router does not decrypt it, so a client talks TLS
to slapd itself and sees slapd's own certificate. LDAP needs that — once a router
terminates TLS it speaks HTTP, and an LDAP bind gets `HTTP/1.1 400 Bad request`
(measured in the chart repository).

### Step 2 — realm `corp`

[`manifests/10-bind-secret.yaml`](manifests/10-bind-secret.yaml) is the password
of the bind account Keycloak searches the directory with —
`cn=keycloak-bind-serviceid`, which may read `ou=People` and `ou=Groups` and
nothing else. [`manifests/20-realm.yaml`](manifests/20-realm.yaml) is the realm:

| In the realm | Here |
|---|---|
| an **LDAP provider** | `ldaps://ldaps-ldap-testing.apps-crc.testing:443`, users under `ou=People` one level down, `inetOrgPerson`, user name `uid`, identity `entryUUID`, `READ_ONLY`, users imported when they log in |
| the **login gate** | `customUserSearchFilter: (memberOf=cn=app-ssb-autobahnusers,ou=Groups,dc=ephico2real,dc=com)` — step 8 |
| **attribute mappers** | user name ← `uid`, email ← `mail`, first name ← `cn`, last name ← `sn` |
| a **group mapper** | the groups `(cn=app-ocp-rbac-ocp-*)` under `ou=Groups`, read from each group's `member`, flat, read-only |
| realm role **`admin`** | and the group `app-ocp-rbac-ocp-keycloak-admin` that grants it — step 10 |
| clients | `shop-api` (the audience) and `shop-cli` (password grant), as in `tutorial` |

The realm file names the bind password only as `${LDAP_BIND_PASSWORD}`; the
import's `placeholders` field fills it from the Secret, inside the import Job.

```console
$ oc apply -f manifests/10-bind-secret.yaml -f manifests/20-realm.yaml
secret/keycloak-ldap-bind created
keycloakrealmimport.k8s.keycloak.org/corp created
$ oc wait keycloakrealmimport/corp -n keycloak --for=condition=Done --timeout=300s
keycloakrealmimport.k8s.keycloak.org/corp condition met
$ oc get keycloakrealmimport corp -n keycloak -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
Done=True
Started=False
HasErrors=False
```

### Step 3 — Keycloak cannot reach it yet

[`admin.sh`](admin.sh) asks Keycloak's admin REST API, as module 16's lab admin,
to run the LDAP provider's own checks — the admin console's **Test connection**
and **Test authentication** buttons — with the bind password Keycloak stored:

```console
$ ./admin.sh test-ldap connection
{"errorMessage":"SSLHandshakeFailed"}
HTTP 400
$ oc logs keycloak-0 -n keycloak | grep 'Caused by: sun.security.validator.ValidatorException' | tail -n 1
Caused by: sun.security.validator.ValidatorException: PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target
```

**What just happened:** the TLS handshake failed — **`PKIX path building
failed`**: Keycloak's Java runtime found no CA it trusts behind the directory's
certificate. That certificate is signed by the directory's own CA, `LDAP
Enterprise Root CA`, which no public trust store contains. Keycloak must be told
to trust it — and first, you must be sure which CA that is.

### Step 4 — the chain the directory sends

Ask the directory for its certificates, the way Keycloak connects — with the
public name as **SNI**, the name the router routes a passthrough connection by:

```console
$ openssl s_client -showcerts -servername ldaps-ldap-testing.apps-crc.testing -connect ldaps-ldap-testing.apps-crc.testing:443 </dev/null 2>/dev/null | grep -E '^ *[0-9]+ s:|^ +i:'
 0 s:CN=openldap-service.ldap-testing.svc
   i:O=Enterprise IT, OU=Directory Services, CN=LDAP Enterprise Root CA
 1 s:O=Enterprise IT, OU=Directory Services, CN=LDAP Enterprise Root CA
   i:O=Enterprise IT, OU=Directory Services, CN=LDAP Enterprise Root CA
$ openssl s_client -noservername -connect ldaps-ldap-testing.apps-crc.testing:443 </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
subject=CN=*.apps-crc.testing
issuer=CN=ingress-operator@1785325954
```

**What just happened:** with SNI, slapd answered with two certificates: its own
(`0`, the **leaf**) and the CA that signed it (`1`) — whose subject and issuer
are the same: it signed itself, it is the **root**. Without SNI the router
cannot tell where the connection goes and answers with its own wildcard
certificate — which is why every client of this endpoint must send SNI. Keep each
certificate in a file, and pick the self-signed one:

```console
$ openssl s_client -showcerts -servername ldaps-ldap-testing.apps-crc.testing -connect ldaps-ldap-testing.apps-crc.testing:443 </dev/null 2>/dev/null | awk '/-----BEGIN CERTIFICATE-----/{n++; f=1} f{print > ("chain-" n ".pem")} /-----END CERTIFICATE-----/{f=0}'
$ for f in chain-*.pem; do if [ "$(openssl x509 -in "$f" -noout -subject | sed 's/^subject=//')" = "$(openssl x509 -in "$f" -noout -issuer | sed 's/^issuer=//')" ]; then cp "$f" ldap-root-ca.pem; echo "$f: self-signed - the root"; else echo "$f: signed by its issuer"; fi; done
chain-1.pem: signed by its issuer
chain-2.pem: self-signed - the root
```

### Step 5 — check it against a copy you already trust

A root taken from a handshake proves only that **someone** sent it: whoever
answered on that name could have sent their own. Compare it with the copy the
PKI owner published through another channel — here
`openshift-config/ca-config-map`, the CA OpenShift's `ldap-local` login already
trusts for this directory:

```console
$ openssl x509 -in ldap-root-ca.pem -noout -subject -enddate -fingerprint -sha256
subject=O=Enterprise IT, OU=Directory Services, CN=LDAP Enterprise Root CA
notAfter=Sep 16 00:41:10 2036 GMT
sha256 Fingerprint=0E:1F:4B:E3:E3:05:86:8C:85:3B:FA:63:6E:B2:EB:8D:BC:06:1A:96:13:37:54:66:D2:5F:AD:46:A7:0E:14:26
$ oc extract configmap/ca-config-map -n openshift-config --keys=ca.crt --to=- 2>/dev/null | openssl x509 -noout -subject -fingerprint -sha256
subject=O=Enterprise IT, OU=Directory Services, CN=LDAP Enterprise Root CA
sha256 Fingerprint=0E:1F:4B:E3:E3:05:86:8C:85:3B:FA:63:6E:B2:EB:8D:BC:06:1A:96:13:37:54:66:D2:5F:AD:46:A7:0E:14:26
$ wire=$(openssl x509 -in ldap-root-ca.pem -noout -fingerprint -sha256); owner=$(oc extract configmap/ca-config-map -n openshift-config --keys=ca.crt --to=- 2>/dev/null | openssl x509 -noout -fingerprint -sha256); if [ -n "$wire" ] && [ "$wire" = "$owner" ]; then echo "match - trust it"; else echo "MISMATCH or unreadable - stop: trust nothing"; false; fi
match - trust it
$ openssl s_client -connect ldaps-ldap-testing.apps-crc.testing:443 -servername ldaps-ldap-testing.apps-crc.testing -CAfile ldap-root-ca.pem -verify_hostname ldaps-ldap-testing.apps-crc.testing -verify_return_error </dev/null 2>&1 | grep 'Verify return code'
Verify return code: 0 (ok)
```

**What just happened:** the two SHA-256 fingerprints are the same — the root
the directory sent **is** the PKI owner's. Only now is it safe to trust. The
comparison also refuses two **empty** fingerprints: a file or a ConfigMap that
cannot be read gives no fingerprint, and two blanks are equal strings. The last
command checks the whole thing the way Keycloak will: the chain up to this root,
**and** the name `ldaps-ldap-testing.apps-crc.testing` in the certificate.
`./run.sh deploy` makes the same comparison and **stops**, trusting nothing, on a
mismatch or an unreadable fingerprint. If a server sends only its leaf there is no root to take: use the PKI
owner's copy directly.

### Step 6 — trust it

Keycloak reads extra CAs from its **truststores**. Module 16's `Keycloak`
resource already declares one, `ldap-root-ca`, from a Secret of the same name —
`optional: true`, so module 16 runs without it:

```console
$ oc get keycloak keycloak -n keycloak -o jsonpath='{.spec.truststores}{"\n"}'
{"ldap-root-ca":{"secret":{"name":"ldap-root-ca","optional":true}}}
```

It lives in module 16's file, not here, because a resource has **one owner**: if
this module patched module 16's `Keycloak`, the next `oc apply` of module 16 would
take the truststore away again. (Ran module 16 before this field existed? Apply
its `manifests/40-keycloak.yaml` again.) Now create the Secret, and wait: the
operator notices the new Secret and **restarts Keycloak** — about 45 seconds
later, measured — and the new Keycloak loads the root. Wait for exactly that,
with no clock involved. The kubelet puts a Secret's data in a **versioned**
directory, `..<date>.<n>`, and links the file to it; new data, new directory.
Keycloak's start-up log names the versioned path it read. So the root is loaded
when the Secret's certificate is the one mounted in the pod **and** the log names
the directory the file links to now. The log line alone is no proof: a Keycloak
started before the change names the same file, in an older directory. The wait
gives up after five minutes, and then says the root is **not** trusted:

```console
$ oc create secret generic ldap-root-ca -n keycloak --from-file=ldap-root-ca.pem
secret/ldap-root-ca created
$ loaded=no; for i in $(seq 1 60); do secret=$(oc get secret ldap-root-ca -n keycloak -o jsonpath='{.data.ldap-root-ca\.pem}' | base64 -d | openssl x509 -noout -fingerprint -sha256 2>/dev/null); mounted=$(oc exec -n keycloak keycloak-0 -- cat /opt/keycloak/conf/truststores/secret-ldap-root-ca/ldap-root-ca.pem 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null); logged=$(oc logs keycloak-0 -n keycloak 2>/dev/null | grep TruststoreBuilder | grep -o 'secret-ldap-root-ca/\.\.20[^/]*' | tail -n 1); linked=$(oc exec -n keycloak keycloak-0 -- readlink -f /opt/keycloak/conf/truststores/secret-ldap-root-ca/ldap-root-ca.pem 2>/dev/null | grep -o 'secret-ldap-root-ca/\.\.20[^/]*'); [ -n "$secret" ] && [ "$secret" = "$mounted" ] && [ -n "$logged" ] && [ "$logged" = "$linked" ] && { loaded=yes; break; }; sleep 5; done; [ "$loaded" = yes ] && oc wait pod/keycloak-0 -n keycloak --for=condition=Ready --timeout=300s || { echo "Keycloak has not loaded the Secret's root, or is not Ready - the root is NOT trusted"; false; }
pod/keycloak-0 condition met
$ oc logs keycloak-0 -n keycloak | grep TruststoreBuilder | grep -o 'secret-ldap-root-ca/\.\.20[^/]*' | tail -n 1; oc exec -n keycloak keycloak-0 -- readlink -f /opt/keycloak/conf/truststores/secret-ldap-root-ca/ldap-root-ca.pem
secret-ldap-root-ca/..2026_09_27_04_50_12.2373335208
/opt/keycloak/conf/truststores/secret-ldap-root-ca/..2026_09_27_04_50_12.2373335208/ldap-root-ca.pem
$ oc get pod keycloak-0 -n keycloak -o jsonpath='{.spec.containers[0].volumeMounts[?(@.name=="truststore-secret-ldap-root-ca")].mountPath}{"\n"}'
/opt/keycloak/conf/truststores/secret-ldap-root-ca
$ oc logs keycloak-0 -n keycloak | grep TruststoreBuilder | grep -o 'Found the following truststore files.*'
Found the following truststore files in the truststore paths [/var/run/secrets/kubernetes.io/serviceaccount/ca.crt, /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt, /opt/keycloak/bin/../conf/truststores/secret-ldap-root-ca/ldap-root-ca.pem, /opt/keycloak/bin/../conf/truststores/secret-ldap-root-ca/..data/ldap-root-ca.pem, /opt/keycloak/bin/../conf/truststores/secret-ldap-root-ca/..2026_09_27_04_50_12.2373335208/ldap-root-ca.pem]
```

**What just happened:** the operator restarted Keycloak with the Secret mounted
under `conf/truststores/`, and at start-up Keycloak added every file there to the
certificates it trusts, beside the service account's `ca.crt` and
`service-ca.crt` it lists first. The directory its log names,
`..2026_09_27_00_58_42.1229303664`, is the one the file links to now. A change
of only the Secret's metadata (an annotation) makes no new directory — measured:
after one at 01:12:48, the file still linked to this one — so it needs no
restart. `./run.sh deploy` and `verify` use the same test.

### Step 7 — now it connects

```console
$ ./admin.sh test-ldap connection
HTTP 204
$ ./admin.sh test-ldap authentication
HTTP 204
```

**What just happened:** `204` twice. **Test connection** opened TLS to
`ldaps-ldap-testing.apps-crc.testing:443` and checked the certificate — chain and
name. **Test authentication** also **bound** as `keycloak-bind-serviceid`, with
the password the import placed in the provider. Trust the second more than the
first — **Test connection** only opens the connection, and passes where no LDAP
server answers at all:

```console
$ ./admin.sh test-ldap connection ldap://ldaps-ldap-testing.apps-crc.testing:443
HTTP 204
$ ./admin.sh test-ldap authentication ldap://ldaps-ldap-testing.apps-crc.testing:443
{"errorMessage":"CommunicationError"}
HTTP 400
```

Plain `ldap://` to a port that speaks only TLS: "connected", yet no bind can work.

### Step 8 — two ways to decide who may log in

The directory holds eleven people — module 17's two shop users, `shop.alice` and
`shop.bob`, among them (the chart's `ldap-shop-users.ldif`). Who may log in to
`corp` is one line in the realm file, the LDAP provider's `customUserSearchFilter`:

| | Open | **Gated — used here** |
|---|---|---|
| who may log in | every person under `ou=People` | only members of `app-ssb-autobahnusers` |
| configured by | no `customUserSearchFilter` | `customUserSearchFilter: ["(memberOf=cn=app-ssb-autobahnusers,ou=Groups,dc=ephico2real,dc=com)"]` |
| who appears in `corp` | anyone who logs in or is listed — one user listing imported every person, all 9 the directory then held (measured on a throwaway realm, #7) | only gate members: the filter applies to every lookup and listing |
| roles | the `ocp` groups (step 10) | the same |
| fits | a directory that holds only this application's people | a corporate directory |

This module uses the **gate**, because that is what an enterprise needs:
access is granted by **membership**, reviewed in **one place** — the gate
group — and the **same** for every system that trusts the directory. OpenShift's
own `ldap-local` login uses this very gate (its URL ends
`(&(uid=*)(memberOf=cn=app-ssb-autobahnusers,ou=Groups,dc=ephico2real,dc=com))`).
The filter needs `memberOf`, and this directory keeps `memberOf` only for
`groupOfUniqueNames` groups — which `app-ssb-autobahnusers` is. List the users, as
the admin console's **Users** page does:

```console
$ ./admin.sh GET /admin/realms/corp/users/count; echo
0
$ ./admin.sh GET '/admin/realms/corp/users?briefRepresentation=true&max=100' | python3 -c 'import json,sys; print(sorted(u["username"] for u in json.load(sys.stdin)))'
['alice.cooper', 'dana.lee', 'jane.smith', 'jeff', 'john.doe', 'lateef.o', 'sarah.jones', 'shop.alice', 'shop.bob']
$ ./admin.sh GET /admin/realms/corp/users/count; echo
9
```

**What just happened:** `corp` held nobody — users are imported when they are
looked up. The listing searched the directory **through the gate** and imported
the gate's members; `bob.wilson` and `charlie.brown`, in the directory but not in
the gate, are not there.

### Step 9 — a token for a directory user

[`token.sh`](token.sh) asks `corp` for a token as module 17's `token.sh` asks
`tutorial` — the form on standard input, never on the `oc exec` command line. The
passwords are the directory's published lab values. **sarah.jones**:

```console
$ ./token.sh sarah.jones | python3 -c 'import base64,json,sys; p = sys.stdin.read().strip().split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); [print(" ", k, c.get(k)) for k in ("iss", "aud", "azp", "preferred_username", "given_name", "family_name", "email")]; print("  roles", sorted(c["realm_access"]["roles"]))'
  iss https://keycloak.apps-crc.testing/realms/corp
  aud ['shop-api', 'account']
  azp shop-cli
  preferred_username sarah.jones
  given_name Sarah Jones
  family_name Jones
  email sarah.jones@ephico2real.com
  roles ['admin', 'default-roles-corp', 'offline_access', 'uma_authorization']
```

**What just happened:** Keycloak found sarah through the gate, checked her
password by **binding to the directory as her** — Keycloak never sees an LDAP
password hash — and issued a token from **`corp`**: her name, email and
`admin`, all from LDAP. The other roles, and `account` in `aud`, are what
Keycloak gives a realm's new users (`default-roles-corp`); `tutorial`'s users,
created by its import with their roles listed, carry none of them (module 16,
step 10). **lateef.o**,
in the gate but not in the admin group:

```console
$ ./token.sh lateef.o | python3 -c 'import base64,json,sys; p = sys.stdin.read().strip().split(".")[1]; c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))); print(c["preferred_username"], sorted(c["realm_access"]["roles"]))'
lateef.o ['default-roles-corp', 'offline_access', 'uma_authorization']
```

And **bob.wilson**, in the directory, outside the gate:

<!-- walkthrough: expect-exit 1 -->
```console
$ ./token.sh bob.wilson
no token: {'error': 'invalid_grant', 'error_description': 'Invalid user credentials'}
```

```console
$ oc logs keycloak-0 -n keycloak | grep LOGIN_ERROR | grep 'username="bob.wilson"' | tail -n 1 | grep -o 'realmName=.*clientId="[^"]*"\|error="[^"]*"\|username="[^"]*"'
realmName="corp", clientId="shop-cli"
error="user_not_found"
username="bob.wilson"
$ ./admin.sh GET '/admin/realms/corp/users?username=bob.wilson&exact=true'; echo
[]
```

**What just happened:** the caller gets the same answer as for a wrong password —
Keycloak does not say which it was. Its log does: **`user_not_found`**. The
search went through the gate, and bob is not a member.

### Step 10 — an LDAP group becomes a role

```console
$ ./admin.sh GET '/admin/realms/corp/groups?briefRepresentation=false' | python3 -c 'import json,sys; [print(g["name"], g["realmRoles"]) for g in json.load(sys.stdin)]'
app-ocp-rbac-ocp-keycloak-admin ['admin']
app-ocp-rbac-ocp-ns-audit []
```

**What just happened:** the realm file declares the group
`app-ocp-rbac-ocp-keycloak-admin` with the role `admin`, and nothing else about
it. When the group mapper met the LDAP group of that name, it **adopted** the
declared group instead of creating another — so its LDAP members get `admin`:
**the directory decides who is in the group, the realm file decides what the
group may do.** Other `ocp` groups appear as their members log in, with no role;
groups outside `(cn=app-ocp-rbac-ocp-*)` never appear. Membership is read from
each group's `member` attribute, because this directory writes `memberOf` only
for `groupOfUniqueNames`, and the `ocp` groups are `groupOfNames`.

### Step 11 — the name and the CA must both match

For LDAP, Keycloak always checks that the certificate **names the host it
dialled**: its truststore guide says LDAP "secure connections … require strict
hostname checking", whatever `tls-hostname-verifier` says. The in-cluster Service name works too — the
certificate names it, for OpenShift's `ldap-local` and group sync:

```console
$ ./admin.sh test-ldap connection ldaps://openldap-service.ldap-testing.svc.cluster.local:636
HTTP 204
```

A name that reaches the same server but is **not** in the certificate — the
short Service name — is refused:

```console
$ ./admin.sh test-ldap connection ldaps://openldap-service.ldap-testing:636
{"errorMessage":"SSLHandshakeFailed"}
HTTP 400
$ oc logs keycloak-0 -n keycloak | grep 'Caused by: java.security.cert.CertificateException' | tail -n 1
Caused by: java.security.cert.CertificateException: No subject alternative DNS name matching openldap-service.ldap-testing found.
```

And a server whose certificate comes from **another CA** — Keycloak's own, from
module 16's `enterprise-ca`, which Keycloak's truststore does not hold — is
refused as in step 3:

```console
$ ./admin.sh test-ldap connection ldaps://keycloak.apps-crc.testing:443
{"errorMessage":"SSLHandshakeFailed"}
HTTP 400
$ oc logs keycloak-0 -n keycloak | grep 'Caused by: sun.security.validator.ValidatorException' | tail -n 1
Caused by: sun.security.validator.ValidatorException: PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target
```

**What just happened:** the admin API reports every TLS failure as the same
`SSLHandshakeFailed`; Keycloak's log says which check failed — **`No subject
alternative DNS name matching`** for the name, **`PKIX path building failed`**
for the CA. This module uses the public name although the Service name works: it
is the address an identity provider **outside** the cluster would use, so the
realm file works unchanged wherever Keycloak runs.

### Step 12 — what the directory saw

slapd logs every connection and operation. One login of sarah.jones, now that she
is in `corp` — the binds of the bind account and of sarah, and the searches, from
the second before the login on (the first `sleep` keeps earlier steps' lookups
out of that window):

```console
$ sleep 2; T=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1; ./token.sh sarah.jones >/dev/null; sleep 2; oc logs -n ldap-testing deploy/openldap-server -c openldap --since-time="$T" | grep -E 'BIND dn="(cn=keycloak-bind-serviceid|uid=sarah.jones)[^"]*" mech|SRCH base="ou=People|SRCH base="ou=Groups' | sed -E 's/^[0-9a-f]+ //; s/(filter=".{60}).*/\1.../'
conn=10454 op=0 BIND dn="cn=keycloak-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" mech=SIMPLE ssf=0
conn=10454 op=1 SRCH base="ou=People,dc=ephico2real,dc=com" scope=1 deref=3 filter="(&(entryUUID=499e85a4-480f-1041-84a7-371855b7826b)(memberOf=...
conn=10455 op=0 BIND dn="uid=sarah.jones,ou=People,dc=ephico2real,dc=com" mech=SIMPLE ssf=0
```

**What just happened:** Keycloak opened a connection, **bound as the bind
account**, looked sarah up — by her `entryUUID`, through the gate — and then
bound **as sarah** on a second connection: that bind is the password check. Each
of the bind account's connections carries its bind and **one** search (`op=0`,
`op=1`), then is closed. Keycloak 26.7.0's release notes
list a fix, #50201, "LDAP user federation re-binds the service account on every
operation since 26.6.0 (connection pool not reused)"; this Keycloak is
`26.6.7.redhat-00003`, its connection pooling is on (the default, `true`), and
measured here the bind account binds once **per search**, on a new connection
each time: 1 bind for a returning user's login, 2 for a first login (the user
search and the group search). The pool is not reused — the behaviour that fix
describes. It costs one TLS handshake and one bind per operation; it is not an
error.

### Step 13 — changing `corp`

An import only **creates** a realm. Measured, one change at a time:

| What you do | What happens |
|---|---|
| apply a changed `20-realm.yaml` while `corp` exists | nothing — no new Job, the realm keeps its old settings |
| delete the realm only | nothing — the import still says `Done=True`, and does not run again (watched for 4 minutes) |
| delete and re-apply the import while `corp` exists | a new Job, which logs `Realm 'corp' already exists. Import skipped` — and the import still says `Done=True` |
| **delete the realm, then delete and re-apply the import** | a new Job creates `corp` from the file |

So a change is: change the file, delete the realm, delete the import, apply —
and on the permanent lab, `./run.sh pause` first: Argo CD would undo each step
([Permanent lab](#permanent-lab)).
`./run.sh deploy` repairs the second row by itself: when realm `corp` is missing
and its import is not, it deletes the import and applies it again — and it only
reports success once the realm exists.
Here with a token lifespan of 600 s instead of 300 — first applied the wrong way:

```console
$ sed 's/accessTokenLifespan: 300/accessTokenLifespan: 600/' manifests/20-realm.yaml | oc apply -f -
keycloakrealmimport.k8s.keycloak.org/corp configured
$ sleep 30; ./admin.sh GET /admin/realms/corp | python3 -c 'import json,sys; print("accessTokenLifespan", json.load(sys.stdin)["accessTokenLifespan"])'
accessTokenLifespan 300
$ ./admin.sh DELETE /admin/realms/corp
deleted /admin/realms/corp
$ oc delete keycloakrealmimport corp -n keycloak
keycloakrealmimport.k8s.keycloak.org "corp" deleted from keycloak namespace
$ sed 's/accessTokenLifespan: 300/accessTokenLifespan: 600/' manifests/20-realm.yaml | oc apply -f -
keycloakrealmimport.k8s.keycloak.org/corp created
$ oc wait keycloakrealmimport/corp -n keycloak --for=condition=Done --timeout=300s
keycloakrealmimport.k8s.keycloak.org/corp condition met
$ ./admin.sh GET /admin/realms/corp | python3 -c 'import json,sys; print("accessTokenLifespan", json.load(sys.stdin)["accessTokenLifespan"])'
accessTokenLifespan 600
```

Put the file's value back the same way:

```console
$ ./admin.sh DELETE /admin/realms/corp
deleted /admin/realms/corp
$ oc delete keycloakrealmimport corp -n keycloak
keycloakrealmimport.k8s.keycloak.org "corp" deleted from keycloak namespace
$ oc apply -f manifests/20-realm.yaml
keycloakrealmimport.k8s.keycloak.org/corp created
$ oc wait keycloakrealmimport/corp -n keycloak --for=condition=Done --timeout=300s
keycloakrealmimport.k8s.keycloak.org/corp condition met
$ ./admin.sh GET /admin/realms/corp | python3 -c 'import json,sys; print("accessTokenLifespan", json.load(sys.stdin)["accessTokenLifespan"])'
accessTokenLifespan 300
```

**What just happened:** deleting the realm deleted everything Keycloak held for
it — the imported users, their sessions. That is safe here because nothing in
`corp` is kept only in Keycloak: its people and groups come back from the
directory as they log in. A realm whose users live in Keycloak would lose them.

The rebuilt realm also has **new signing keys**, so anything that caches `corp`'s
public keys rejects its tokens until that cache expires. Module 17's Gateway
keeps them for `cache_duration: 300s` (its step 4): measured on this lab after a
rebuild at 04:51:17Z, its `corp` checks answered `Jwks doesn't have key to match
kid or alg from Jwt -> 401` until 04:54:49Z and passed again at 04:55:24Z — about
four minutes. The `tutorial` realm's tokens were unaffected throughout.

### Step 14 — check yourself

```console
$ ./run.sh verify

1. the directory's root, checked and trusted
  ✓ Secret ldap-root-ca holds the PKI owner's root
  ✓ Keycloak declares the truststore (module 16's resource)
  ✓ ...the operator mounts it into keycloak-0
  ✓ ...and Keycloak loaded the Secret's current data at start-up

2. realm corp and its LDAP provider
  ✓ realm import Done
  ✓ realm corp exists
  ✓ provider: test connection
  ✓ provider: test authentication (the bind account)

3. who gets a corp token
  ✓ sarah.jones (gate member): issued by corp
  ✓ sarah.jones: for shop-api (aud)
  ✓ sarah.jones: role admin, from her LDAP group
  ✓ lateef.o (gate member): a token
  ✓ lateef.o: no admin (not in keycloak-admin)
  ✓ bob.wilson (outside the gate): no token
  ✓ ...because Keycloak does not find him
  ✓ charlie.brown (outside the gate): no token
  ✓ ...because Keycloak does not find him
  ✓ corp's users are exactly the gate's members in the directory

4. the name and the CA must both match
  ✓ the in-cluster Service name: its certificate names it too
  ✓ a name the certificate lacks -> refused
  ✓ a certificate from another CA -> refused

all checks passed
```

## The options

**The LDAP provider** (`components` → `org.keycloak.storage.UserStorageProvider`)

| Field | Here | What it does | When to change it |
|---|---|---|---|
| `connectionUrl` | `ldaps://ldaps-ldap-testing.apps-crc.testing:443` | where the directory is; `ldaps://` is TLS from the first byte | another directory, or `ldap://` + `startTls` |
| `useTruststoreSpi` | `always` | check the certificate against Keycloak's truststore. Measured: `never` passes too on this Keycloak, whose truststore is also its JVM's default | leave it |
| `bindDn`, `bindCredential` | the bind account, from a placeholder | who Keycloak searches as | a least-privilege account per application |
| `usersDn`, `searchScope` | `ou=People`, `1` (one level) | where people are; `2` searches the whole subtree | people in nested OUs |
| `userObjectClasses` | `inetOrgPerson` | what counts as a person | `person`, `user` (AD) |
| `usernameLDAPAttribute`, `rdnLDAPAttribute` | `uid` | the login name | `sAMAccountName` (AD) |
| `uuidLDAPAttribute` | `entryUUID` | the identity that survives a rename | `objectGUID` (AD) |
| `customUserSearchFilter` | the gate (step 8) | ANDed into every user search | none for the open configuration |
| `editMode` | `READ_ONLY` | Keycloak never writes to the directory | `WRITABLE` only if Keycloak should change LDAP |
| `importEnabled` | `true` | copy users into Keycloak's database, linked to LDAP | `false` to look them up on every request |
| `fullSyncPeriod`, `changedSyncPeriod` | `-1` | no periodic sync: users are imported as they are looked up | a sync interval, in seconds |
| `connectionPooling` | not set (`true`) | reuse connections — measured not to be reused (step 12) | — |

**The group mapper** (`subComponents`, `group-ldap-mapper`)

| Field | Here | What it does |
|---|---|---|
| `groups.dn` | `ou=Groups,dc=ephico2real,dc=com` | where groups are |
| `groups.ldap.filter` | `(cn=app-ocp-rbac-ocp-*)` | which groups enter the realm |
| `group.object.classes`, `membership.ldap.attribute`, `membership.attribute.type` | `groupOfNames`, `member`, `DN` | how a group lists its members |
| `user.roles.retrieve.strategy` | `LOAD_GROUPS_BY_MEMBER_ATTRIBUTE` | find a user's groups by searching groups' `member`, not the user's `memberOf` |
| `preserve.group.inheritance` | `false` | flat groups — no nesting |
| `mode` | `READ_ONLY` | memberships are read, never written |

**The Keycloak resource** (module 16) — `spec.truststores.<name>.secret{name, optional}`,
or `.configMap{…}`: every file in it is mounted under
`/opt/keycloak/conf/truststores/secret-<name>/` and trusted from the next start.

**The realm import** — `spec.placeholders.<NAME>.secret{name, key}`: `${NAME}` in
the realm is replaced with the Secret's value inside the import Job.

## What production does differently

| Here (lab) | Production |
|---|---|
| the bind password in a Secret written in git | a Secret from a vault; rotated |
| the root's fingerprint compared by a script | the same comparison, against the PKI team's published fingerprint |
| the password grant (`shop-cli`) | the authorization-code flow with PKCE, through Keycloak's login page |
| a directory on the same cluster, reached through its Route | the corporate directory, reached by its DNS name — the realm file is the same |
| the realm replaced by deleting and re-importing it | the same for directory-backed settings; anything kept only in Keycloak needs a migration plan |

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| `Jwks doesn't have key to match kid or alg from Jwt` at module 17's Gateway for `corp` tokens | realm `corp` was rebuilt (step 13) and has new signing keys; the Gateway still holds the old ones for up to `cache_duration: 300s` | wait — measured about four minutes after a rebuild; nothing to change |
| `SSLHandshakeFailed`; the log says `PKIX path building failed` | Keycloak does not trust the certificate's CA — no Secret `ldap-root-ca`, or Keycloak has not restarted since it was created | steps 5–6; the restart comes about 45 s after the Secret (measured) |
| `SSLHandshakeFailed`; the log says `No subject alternative DNS name matching` | the URL's host is not in the certificate | use a name the certificate carries (step 11) |
| the router's `*.apps-crc.testing` certificate instead of slapd's | the client sent no SNI | send it: `openssl s_client -servername …` |
| Test connection `204`, Test authentication `CommunicationError` | no LDAP server answered — wrong scheme or port | `ldaps://` on 443, or on 636 in the cluster |
| `invalid_grant`, `Invalid user credentials`; the log says `user_not_found` | the person is not in the gate, or not under `ou=People` | add them to `app-ssb-autobahnusers` in the directory |
| an edited `20-realm.yaml`, applied, changes nothing | an import only creates | step 13 |
| the import says `Done=True`, the realm is unchanged, its Job logs `Import skipped` | the realm already existed when the Job ran | delete the realm first (step 13) |
| `zsh: no matches found: chain-*.pem` | step 4's `for` loop ran before the `awk` that writes the files | run the `awk` command first |
| `unknown option -noservername` / `-verify_hostname` | macOS LibreSSL | OpenSSL 3 (`brew install openssl`) |

## Console screenshots

To be added after the operator signs in to the admin console (read-only
captures, zoomed, checked with `tooling/screenshot/verify.py`):

- Realm list: `corp` beside `tutorial` — the `KeycloakRealmImport` created it.
- User federation → `ldap`: connection URL `ldaps://ldaps-ldap-testing.apps-crc.testing:443`,
  edit mode `READ_ONLY`; **Test connection** and **Test authentication** succeed.
- Mappers → the group mapper with filter `(cn=app-ocp-rbac-ocp-*)`.
- Groups: the `ocp` groups.
- Users: only gate members — not the whole directory.
- `sarah.jones`: her groups and her role mapping (`admin`).
- Realm roles: `admin`.
- Optional: `sarah.jones` signing in to her account console.

## Permanent lab

On the operator's CRC realm `corp` stays: it is the Keycloak offering's
directory-backed realm (module 16, [Permanent lab](../16-keycloak/README.md#permanent-lab)).
Argo CD's Application `18-keycloak-ldap`
([`../argocd/18-keycloak-ldap.yaml`](../argocd/18-keycloak-ldap.yaml)) keeps this
module's `manifests/` as they are on the `main` branch — the bind password's
Secret and the realm import:

<!-- walkthrough: skip -->
```console
$ oc get applications.argoproj.io 18-keycloak-ldap -n openshift-gitops -o jsonpath='{range .status.resources[*]}{.kind}/{.name}  {.status}{"\n"}{end}'
Secret/keycloak-ldap-bind  Synced
KeycloakRealmImport/corp  Synced
```

(This block needs the Application, so the walkthrough runner skips it; it was
run as written.)

### What `./run.sh deploy` makes, and who keeps it

| What | Made by | Kept by | Why |
|---|---|---|---|
| Secret `keycloak-ldap-bind`, `KeycloakRealmImport corp` | `manifests/` | Argo CD | manifests. Measured: a deleted import was back in 0.7 s, and its new Job logged `Realm 'corp' already exists. Import skipped` |
| realm `corp` itself, in Keycloak's database | the import's Job, once | nobody | an import only creates. A deleted realm is not imported again while its import says `Done` (step 13), and Argo CD sees nothing to repair: the import is unchanged. `./run.sh deploy` repairs it — it pauses the Application, deletes the import and applies it again (measured with Argo CD on: realm deleted, `deploy` brought it back and resumed the Application, `Synced/Healthy`) |
| **Secret `ldap-root-ca`** — the directory's root CA, fetched from the wire and checked (steps 4 to 6) | `./run.sh deploy` | nobody — `run.sh` only | [below](#why-the-directorys-root-is-not-in-git) |
| the truststore entry that mounts it | module 16's `Keycloak` resource | Argo CD, `16-keycloak` | one owner (step 6) |
| Keycloak's restart after the Secret changes | the Keycloak operator | — | about 45 s after the change (step 6) |
| pod `client` in `keycloak` | module 16 (step 6) or `./run.sh verify` | nobody | a test tool |

### Why the directory's root is not in git

The root is a **public** certificate — nothing in it is secret — so git could hold
it, as a Secret manifest beside the realm import, and Argo CD would put it back if
it were deleted. It stays out, for two reasons:

- **It belongs to one cluster.** The chart that builds the directory makes a new
  self-signed root on every cluster it runs on (group-sync-operator-helm-chart,
  `setup-local-ldap-testing/15-bootstrap-cert-manager-ca.sh`:
  `ClusterIssuer/ldap-selfsigned-bootstrap` → `Certificate/ldap-enterprise-root-ca`).
  The root in step 5, `0E:1F:4B:E3:…:A7:0E:14:26`, is this CRC's. In this
  module's `manifests/` — the files every reader applies — it would be wrong on
  every other cluster, and Argo CD would enforce a wrong root here too the day the
  directory's CA is rebuilt.
- **Trusting it takes the out-of-band check, and `run.sh` makes it every time.**
  `./run.sh deploy` fetches the root, compares it with the PKI owner's copy
  (`openshift-config/ca-config-map`), stops on a mismatch, and writes the Secret
  only when it changed (which restarts Keycloak). A new root — this one expires on
  2036-09-16 — is one `./run.sh deploy`, checked, with no commit. In git, the
  check would move to whoever reviews the commit, and each cluster would need a
  copy of its own.

What it costs: nothing puts back a **deleted** `ldap-root-ca` by itself. Keycloak
restarts without it — 5 s after the delete, measured (Clean up) — and LDAP logins
fail; `./run.sh verify` fails on "Secret ldap-root-ca holds the PKI owner's root",
and `./run.sh deploy` restores it, checked.

### Walkthroughs, experiments and clean

Step 13 changes the realm import on purpose — a changed file, then the import
deleted and applied again. With Argo CD on, the file's change is undone, and a
deleted import is created again from `main` before you apply yours: pause this
module's Application first, and resume it after — `./run.sh pause`,
`./run.sh resume`, as in module 16's [Permanent lab](../16-keycloak/README.md#permanent-lab).
`./run.sh clean` pauses it for you, and `./run.sh deploy` resumes it at its end.

## Clean up

Leave `corp` in place if you go on: module 17's Gateway accepts its tokens beside
realm `tutorial`'s (module 17, steps 8 to 10).
On the permanent lab a clean-up is a deliberate reset: pause Argo CD first
(`./run.sh pause`), or it puts the import and the bind Secret back as you delete
them. To remove what this module added — the realm, its import, the two Secrets.
Module 16's `Keycloak` keeps its `truststores` entry: it is optional. But the
Secret it names is gone, so the operator **restarts Keycloak** — measured: it
stopped `keycloak-0` 5 seconds after the delete, and the new Keycloak trusts the
directory no longer. Until the new one is Ready, Keycloak answers nobody, so wait
for it: the last command below waits for a new pod, then for Ready — five minutes
at most, each — as `./run.sh clean` does:

<!-- walkthrough: skip -->
```console
$ ./admin.sh DELETE /admin/realms/corp
$ oc delete keycloakrealmimport corp -n keycloak
$ oc delete -f manifests/10-bind-secret.yaml
$ rm -f chain-1.pem chain-2.pem ldap-root-ca.pem
$ old=$(oc get pod keycloak-0 -n keycloak -o jsonpath='{.metadata.uid}'); new=$old; oc delete secret ldap-root-ca -n keycloak && for i in $(seq 1 60); do new=$(oc get pod keycloak-0 -n keycloak -o jsonpath='{.metadata.uid}'); [ -n "$new" ] && [ "$new" != "$old" ] && break; sleep 5; done; [ -n "$new" ] && [ "$new" != "$old" ] && oc wait pod/keycloak-0 -n keycloak --for=condition=Ready --timeout=300s && oc wait keycloak/keycloak -n keycloak --for=condition=Ready --timeout=300s || { echo "Keycloak has not restarted and become Ready - oc get pod keycloak-0 -n keycloak"; false; }
```

## The shortcut

`./run.sh deploy` does steps 4 to 6 and 2 — fetch, check (and stop on a
mismatch), trust, import — and resumes Argo CD's Application if there is one;
`./run.sh verify` is step 14; `./run.sh clean` is the clean-up, with the
Application paused first; `./run.sh pause` and `./run.sh resume` are the
[Permanent lab](#permanent-lab)'s.

## References

- [Keycloak — configuring trusted certificates](https://www.keycloak.org/server/keycloak-truststore)
- [Keycloak Operator — advanced configuration (truststores)](https://www.keycloak.org/operator/advanced-configuration)
- [Keycloak Operator — realm import](https://www.keycloak.org/operator/realm-import)
- [Red Hat build of Keycloak 26.6 — Server Administration Guide: LDAP and Active Directory](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/server_administration_guide/index)
- [Keycloak 26.7.0 release notes](https://www.keycloak.org/2026/07/keycloak-2670-released)
- [OpenShift — route types (passthrough)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.8/html/networking/configuring-routes)
- [RFC 4513 — LDAP authentication methods and security mechanisms](https://www.rfc-editor.org/rfc/rfc4513)

## Diagram sources

The figure is rendered from [`docs/diagrams/18-keycloak-ldap/source.html`](../docs/diagrams/18-keycloak-ldap/source.html)
(inline SVG, light and dark). Change the page and re-render the PNGs together,
with the `/visual` skill's `render.py`.
