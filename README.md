# OpenShift Console SSO with your Teleport identity

Log into the RedHat OpenShift web console (and `oc login --web`) as your
**Teleport** user, with your Teleport **roles** deciding what you can do in the
cluster. One browser click takes you from the console's login page through
Teleport and back — no kubeadmin password, no separate OpenShift account.

```
you → OpenShift Console → OpenShift OAuth server → Keycloak → Teleport → done
                          (speaks OIDC)            (translates)  (speaks SAML)
```

## Why is Keycloak in the middle?

Short version: **OpenShift and Teleport don't speak a common login protocol**,
so something has to translate. That's the entire job Keycloak does here.

The longer version:

- The OpenShift console doesn't authenticate users itself — it hands you to the
  cluster's built-in **OAuth server**, which supports a fixed list of identity
  provider types: htpasswd, LDAP, GitHub, GitLab, Google, Keystone,
  request-header, basic-auth, and **OpenID Connect (OIDC)**. Notably absent:
  SAML, and any kind of "trust a JWT header" option.
- **Teleport can act as an identity provider, but only over SAML** (the
  Enterprise "Teleport as a SAML IdP" feature). Teleport has no OIDC provider
  for third-party apps.
- So: OpenShift's best option is OIDC, Teleport's only option is SAML, and
  **Keycloak brokers between them** — it logs you in via Teleport (SAML),
  then presents you to OpenShift as an OIDC user. Your Teleport roles ride
  along the whole way and become OpenShift groups.

Jargon decoder (one-liners):

| Term | Meaning |
|---|---|
| **IdP** (identity provider) | The system that says who you are (here: Teleport) |
| **SAML** | An XML-based single-sign-on protocol; Teleport's IdP speaks it |
| **OIDC** (OpenID Connect) | A JSON/OAuth2-based single-sign-on protocol; OpenShift consumes it |
| **Broker / bridge** | A service that logs in against one protocol and serves the other (here: Keycloak) |
| **ACS URL** | "Assertion Consumer Service" — the SAML callback URL where Teleport sends the signed login response |

### Why not something simpler?

| Option | Why it doesn't work |
|---|---|
| Teleport app-access JWT (the Grafana pattern) | The console has no equivalent of Grafana's `auth.jwt` — it only trusts its OAuth server. The Teleport JWT's issuer/audience are also fixed values OpenShift's OIDC validation would reject. |
| OpenShift's request-header identity provider | Requires the authenticating proxy to present an mTLS client certificate signed by a CA you give the OAuth server. Teleport app access can't present one. |
| Teleport as OIDC provider directly | Doesn't exist — Teleport's IdP is SAML-only (verified against current Teleport source). |
| Dex instead of Keycloak | Dex's SAML connector is officially unmaintained and flagged by the Dex project as "likely vulnerable to authentication bypass". Keycloak's SAML brokering is fully maintained. |

### What you end up with

- Keycloak runs **inside the OpenShift cluster** as a single small pod. Its
  entire configuration is one JSON file in this repo — no database, nothing to
  back up. If the pod restarts, the config re-imports itself.
- Your **Teleport roles become OpenShift groups**, re-synced on every login:

  | Teleport role | OpenShift group | ClusterRole granted |
  |---|---|---|
  | `full-access` | `full-access` | `cluster-admin` (everything) |
  | `editor` | `editor` | `edit` (change most things) |
  | `access` | `access` | `view` (read-only) |

  (These are example role names — edit `openshift/40-rbac-group-bindings.yaml`
  to match the Teleport roles in your cluster.)

  Because group names are just Teleport role names, a role you receive through
  a Teleport **Access Request** shows up as a new OpenShift group the next time
  you log in — just-in-time elevation, visible in the console.
- `kubeadmin` keeps working the whole time. Nothing here is one-way; see
  [Teardown](#teardown--rollback).

## Prerequisites

- A **Teleport Enterprise** cluster (the SAML IdP is an Enterprise feature) and
  a user with permission to manage `saml_idp_service_provider` resources
  (e.g. the `editor` role). `tsh`/`tctl` installed locally.
- Admin access to the OpenShift cluster (`oc` logged in as kubeadmin or
  equivalent).
- `envsubst` (macOS: `brew install gettext`), `curl`, `python3`, `jq` optional.

## Step-by-step deployment

Every step is one action: the command, what it does, and a ✓ check before
moving on. Run everything from the repo root.

### Step 1 — Fill in your settings

```bash
cp demo.env.example demo.env
```

Edit `demo.env`: set your Keycloak hostname (any name under the cluster's
`*.apps...` wildcard domain), your OAuth route host, your Teleport proxy, and
generate the two secrets (commands are in the file's comments). Leave
`TELEPORT_SAML_CERT_B64` empty for now — that's Step 2.

### Step 2 — Export Teleport's SAML signing certificate

Keycloak must verify that login responses really came from your Teleport
cluster, so it needs Teleport's SAML signing certificate baked into its config.

```bash
tsh login --proxy=<your-teleport-proxy>
tctl auth export --type saml-idp | openssl x509 -inform DER | grep -v CERTIFICATE | tr -d '\n'
```

(`tctl` exports the certificate in binary DER form — with a trailing newline
byte that Keycloak's strict parser rejects as "extra data at the end". Piping
through `openssl x509` re-encodes exactly one clean certificate; stripping the
PEM header/footer leaves the bare base64 Keycloak's `signingCertificate` field
expects.)

Paste the output (one long base64 line) into `TELEPORT_SAML_CERT_B64` in
`demo.env`.

> ✓ **Check:** the value is a single line of base64 starting with `MII`, with
> no line breaks.

### Step 3 — Render the manifests

```bash
scripts/render.sh
```

This substitutes your `demo.env` values into every template and writes the
results to `rendered/` (gitignored — it contains your secrets).

> ✓ **Check:** the script prints the list of rendered files and exits 0.

### Step 4 — Deploy Keycloak

```bash
oc apply -f rendered/keycloak/
```

Creates the `keycloak` namespace, the realm-config ConfigMap, the admin
password Secret, the Deployment, a Service, and a TLS Route. First start takes
~1 minute (realm import).

> ✓ **Check:** the pod is Ready and the OIDC discovery document advertises
> exactly the issuer OpenShift will be told to expect:
>
> ```bash
> oc get pods -n keycloak
> curl -sk https://<KC_ROUTE_HOST>/realms/teleport/.well-known/openid-configuration | jq -r .issuer
> # → https://<KC_ROUTE_HOST>/realms/teleport   (must match byte-for-byte)
> ```

### Step 5 — Register Keycloak with Teleport

Tell Teleport that Keycloak is allowed to request logins (in SAML terms:
register Keycloak as a *service provider* of Teleport's IdP).

```bash
# Optional dry-run: see exactly which SAML attributes your user will get
tctl idp saml test-attribute-mapping \
    --users <your-teleport-username> \
    --sp rendered/teleport/saml-idp-service-provider.yaml

tctl create -f rendered/teleport/saml-idp-service-provider.yaml
```

> ✓ **Check:** `tctl get saml_idp_service_provider/openshift-keycloak` shows
> the resource, and the test-attribute-mapping output includes your roles under
> `eduPersonAffiliation`.

### Step 6 — Test the Teleport↔Keycloak half on its own

Before touching OpenShift, prove the SAML half works. In a browser, open:

```
https://<KC_ROUTE_HOST>/realms/teleport/account
```

You should be redirected straight to Teleport (log in there if you don't have
an active session), then land back in Keycloak's account console — logged in,
with **no** "update account information" form in between.

> ✓ **Check:** the account console shows your Teleport username. Bonus check —
> confirm your roles arrived as a multi-valued attribute: log into the Keycloak
> admin console (`https://<KC_ROUTE_HOST>/admin/` — user `admin`, password from
> `demo.env`), switch to the **teleport** realm → Users → your user →
> Attributes → `teleport_roles` should list your Teleport roles.

### Step 7 — Point OpenShift's OAuth server at Keycloak

Three objects: the client secret, the CA bundle OpenShift should trust when it
calls Keycloak, and the OAuth configuration itself.

```bash
source demo.env

# 7a. The OIDC client secret (same value Keycloak has)
oc create secret generic keycloak-teleport-client-secret \
    --from-literal=clientSecret="${OIDC_CLIENT_SECRET}" -n openshift-config

# 7b. The CA that signs the Keycloak route's certificate (the ingress CA)
oc get cm default-ingress-cert -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' > ingress-ca.crt
oc create configmap keycloak-teleport-ca \
    --from-file=ca.crt=ingress-ca.crt -n openshift-config

# 7c. The OAuth config and the group→role bindings
oc apply -f rendered/openshift/30-oauth-cluster.yaml
oc apply -f rendered/openshift/40-rbac-group-bindings.yaml
```

The OAuth server pods roll automatically after 7c; give it 2–3 minutes.

> ✓ **Check:**
>
> ```bash
> oc get co authentication         # Available=True, Progressing settles to False
> oc get pods -n openshift-authentication   # fresh oauth-openshift pods Running
> ```

### Step 8 — Log in!

Open the console in a **private browser window** (so your kubeadmin session
doesn't interfere):

```
https://console-openshift-console.apps.<your-cluster-domain>/
```

Click **keycloak-teleport** on the login page. You'll bounce through Keycloak
(invisibly) to Teleport and back into the console — logged in as your Teleport
user.

> ✓ **Check** (as kubeadmin in your normal window):
>
> ```bash
> oc get users identities groups
> # your user exists; groups matching your Teleport roles exist and contain you
> oc get group full-access -o yaml
> # annotated with oauth.openshift.io/idp.keycloak-teleport: synced
> ```
>
> And in the private window's console: with `full-access` you're a cluster
> admin (Administration menu fully visible).

### Step 9 (optional) — The just-in-time access demo

1. In Teleport, request and assume an extra role (e.g. via an Access Request).
2. Close the private window (this drops the console *and* Keycloak sessions —
   important, see [Sessions](docs/troubleshooting.md#three-sessions)).
3. Log into the console again in a fresh private window.

> ✓ **Check:** `oc get groups` now shows the newly-granted role as a group, and
> the console reflects the elevated permissions. When the Access Request
> expires, the next login removes it again — group sync is per-login and
> two-way.

You can also verify everything at once with `scripts/verify.sh`.

## Day-2 management

**Add or change an access tier.** Edit
`openshift/40-rbac-group-bindings.yaml` — add a ClusterRoleBinding whose Group
name equals the Teleport role name — and `oc apply` it. No Keycloak or Teleport
changes; the role already flows through the `groups` claim.

**Rotate the OIDC client secret.** Generate a new value, update
`OIDC_CLIENT_SECRET` in `demo.env`, then re-render and apply both sides:

```bash
scripts/render.sh
oc apply -f rendered/keycloak/10-realm-configmap.yaml
oc rollout restart deployment/keycloak -n keycloak      # re-imports the realm
oc set data secret/keycloak-teleport-client-secret -n openshift-config \
    clientSecret="$(grep OIDC_CLIENT_SECRET demo.env | cut -d= -f2)"
```

**Rotate the Teleport SAML certificate** (after a Teleport CA rotation):
redo Step 2 (re-export into `demo.env`), then re-render, re-apply the realm
ConfigMap, and restart Keycloak as above.

**Upgrade Keycloak.** Bump the image tag in `keycloak/20-deployment.yaml`,
re-render, `oc apply -f rendered/keycloak/20-deployment.yaml`. State is
disposable; the realm re-imports on start.

**What a Keycloak restart loses (and doesn't).** Lost: Keycloak-local sessions
and the user entries it created (they're re-created at next login). Kept:
everything that matters — the whole configuration lives in the realm ConfigMap.
Nobody's access changes: identity lives in Teleport, permissions live in the
ClusterRoleBindings.

**Health check.** `scripts/verify.sh`, or manually: the discovery URL from
Step 4, `oc get co authentication`, `oc logs deployment/keycloak -n keycloak`,
`oc get users identities groups`.

**Prefix the group names (optional).** On a shared cluster you may not want
Teleport role names to collide with existing OpenShift groups. Give Teleport's
roles a prefix by asserting a custom attribute instead: in
`teleport/saml-idp-service-provider.yaml`, add an `attribute_mapping` entry
with a transformed value (Teleport supports predicate expressions over
`user.spec.roles`), point the Keycloak `teleport-roles` mapper at that
attribute, and use the prefixed names in the ClusterRoleBindings.

## Teardown / rollback

`kubeadmin` never stops working, so you can undo any single piece safely.

```bash
# Remove SSO from the login page (users/groups/identities remain until deleted)
oc patch oauth cluster --type json -p '[{"op": "remove", "path": "/spec/identityProviders"}]'

# Remove the RBAC bindings and the synced users/groups
oc delete -f rendered/openshift/40-rbac-group-bindings.yaml
oc delete user <your-user> ; oc delete identity --all ; oc delete group full-access editor access

# Remove Keycloak entirely
oc delete ns keycloak
oc delete secret keycloak-teleport-client-secret -n openshift-config
oc delete configmap keycloak-teleport-ca -n openshift-config

# Deregister Keycloak from Teleport
tctl rm saml_idp_service_provider/openshift-keycloak
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) — it covers the issuer
byte-match rule, certificate trust, the three-sessions gotcha that affects the
JIT demo, and what each failure mode looks like.

## Repo layout

```
demo.env.example                  # your settings + secrets (copy to demo.env)
scripts/render.sh                 # demo.env + templates → rendered/
scripts/verify.sh                 # end-to-end health checks
keycloak/                         # namespace, secret, deployment, service, route
keycloak/realm-teleport.json      # the entire Keycloak configuration
teleport/saml-idp-service-provider.yaml   # registers Keycloak with Teleport's SAML IdP
openshift/30-oauth-cluster.yaml   # the OAuth identity-provider config
openshift/40-rbac-group-bindings.yaml     # Teleport role → ClusterRole tiers
docs/troubleshooting.md
```
