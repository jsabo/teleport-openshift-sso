# teleport-openshift-sso — Claude Context

Built and verified end-to-end in July 2026 against a self-managed OpenShift
4.21 cluster on AWS and a Teleport Enterprise Cloud tenant (v18.10). Final
acceptance: an SSO user logged into the console via Teleport with all of
their Teleport roles synced as annotated OpenShift groups and cluster-admin
granted through a group binding.

## Architecture and why it's shaped this way

```
Console → OAuth server (OAuth CR, type: OpenID) → Keycloak (SAML broker) → Teleport SAML IdP
```

Facts that forced this design (verified against Teleport source at the time,
v19.0.0-prealpha — re-verify before assuming they changed):

- **Teleport has no user-facing OIDC identity provider.** No authorization-code
  flow, no token endpoint, no RFD proposing one. The only OIDC issuers are
  machine federation (AWS integration, SPIFFE workload identity), `id_token`
  only. Teleport-as-IdP = **SAML only** (Enterprise, `/enterprise/saml-idp/*`
  on the proxy).
- **OpenShift's OAuth server does not support SAML** — OIDC is its best option.
  Hence a SAML→OIDC bridge is unavoidable.
- **The Grafana JWT pattern cannot work here**: the console only trusts its
  OAuth server, and the Teleport app JWT's `aud`/`iss` are hard-coded (app URI
  / cluster name) so OpenShift's OIDC validation would reject it anyway.
- **request-header IdP is not viable with Teleport app access**: the OAuth
  server requires an mTLS client certificate from the authenticating proxy
  (`ca` field, mandatory since OCP 4.1); Teleport app access can't present one.
- **Dex was rejected**: its SAML connector is officially unmaintained and
  flagged by the Dex project as "likely vulnerable to authentication bypass."
  Keycloak's SAML brokering is maintained.
- OAuth-CR OpenID IdP was chosen over OpenShift's external/direct OIDC (GA
  4.20+) because it keeps the built-in OAuth server: kubeadmin coexists,
  rollback is one patch.

Default Teleport SAML assertions: `uid` (urn:oid:0.9.2342.19200300.100.1.1) =
username, `eduPersonAffiliation` (urn:oid:1.3.6.1.4.1.5923.1.1.1.1) = role
names. `attribute_mapping` on the `saml_idp_service_provider` adds more (this
repo asserts mail = `user.metadata.name`).

## Hard-won gotchas (each cost real debugging time)

1. **`tctl auth export --type saml-idp` outputs binary DER with a trailing
   newline byte.** Raw `base64` of it makes Keycloak's cert parser fail at
   SAML-response verification with `IOException: extra data at the end`
   (surfacing as "We are sorry… internal server error" at the broker
   endpoint). Normalize: `tctl auth export --type saml-idp | openssl x509
   -inform DER | grep -v CERTIFICATE | tr -d '\n'`.

2. **SAML IdP RBAC needs a v8 role.** Both *managing* a
   `saml_idp_service_provider` and *logging in through it* are authorized via
   `app_labels` in **version 8 roles only** — a v7 role with wildcard
   app_labels is ignored for SAML SPs, and rule verbs alone (e.g. `editor`'s
   CRUD rule) aren't sufficient. Unlabeled SPs require a v8 wildcard. Symptom:
   "You do not have access to this resource" at `/enterprise/saml-idp/sso`.
   Fix: give every user who should log in a v8 role whose `app_labels` match
   the service provider's labels (wildcard works).

3. **Role-list changes need a fresh login; role-content changes don't.**
   Adding a role to a user only takes effect after full re-auth (`tsh logout`
   then passwordless login — a plain `tsh login` over a live session silently
   reuses the old cert; web sessions likewise). Editing the allow rules inside
   a role the user already holds applies to live sessions immediately. Also:
   SSO users' role lists are rewritten from the connector mapping on every SSO
   login — grant durable access via a role the connector already maps.

4. **Never use Keycloak's Username Template Importer with URN attribute
   names.** Its `${ATTRIBUTE.urn:oid:...}` parser treats the colons as
   template syntax and produced the literal username
   `oid:0.9.2342.19200300.100.1.1`, which OpenShift rejects (`usernames that
   contain ":" must begin with "b64:"`). The follow-on error is misleading:
   browser retries re-submit the already-consumed authorization code, so the
   OAuth log shows `Code not valid` — the real failure is one page earlier.
   The IdP config's `principalType: ATTRIBUTE` + `principalAttribute` sets the
   username correctly on its own; no mapper needed.

5. **Keycloak's VERIFY_PROFILE required action prompts for first/last name**
   on first broker login even when the first-login flow has no review step
   (default user profile marks them required). The realm JSON disables the
   required action outright.

6. **The OIDC issuer must match byte-for-byte** between Keycloak's discovery
   document (driven by `KC_HOSTNAME`) and the OAuth CR `issuer`. Both render
   from `KC_ROUTE_HOST` in demo.env — keep it that way.

7. **CA trust**: with an edge-terminated Route on the default router cert, the
   OAuth server's `ca` ConfigMap needs the bundle from
   `openshift-config-managed/default-ingress-cert` (contains leaf + the
   self-signed `ingress-operator@...` CA — the CA is what matters).

8. **Three sessions** (OpenShift, Keycloak, Teleport web). Console logout only
   ends the first; Keycloak silently re-issues tokens from its own session
   without re-running SAML, so **Teleport role changes don't propagate until
   the Keycloak session ends**. Exercise JIT elevation in a fresh private window.

9. **envsubst must get an explicit variable list** (`envsubst "$VARS"`) when
   rendering the realm JSON — otherwise it destroys Keycloak's own `${...}`
   template strings. render.sh does this; keep it if adding variables.

10. **Multi-valued SAML attribute → multi-valued user attribute → multivalued
    protocol mapper works** (was flagged as unverified during design; confirmed
    on Keycloak 26.7.0). The `groups` claim path needs no per-role Keycloak
    config — any Teleport role flows through, which is what makes JIT work.

11. **Keycloak's native realm-import `${VAR}` env substitution works on 26.7.0**
    (confirmed live: SAML descriptor entityID fully resolved). This is what
    keeps the OIDC client secret in a k8s Secret instead of the realm
    ConfigMap. Syntax is `${VAR}` — NOT `$(env:VAR)`, which belongs to the
    third-party keycloak-config-cli tool. The deployment's `KC_HOSTNAME` uses
    Kubernetes dependent-env expansion (`https://$(KC_ROUTE_HOST)`), which
    requires KC_ROUTE_HOST to be defined EARLIER in the same env array.

12. **Keycloak starts fine with no bootstrap admin** (omit `KC_BOOTSTRAP_ADMIN_*`
    entirely; confirmed on 26.7.0). The /admin console simply has no account.
    Temporary recovery when needed:
    `oc exec -it deployment/keycloak -n keycloak -- /opt/keycloak/bin/kc.sh bootstrap-admin user`
    (evaporates on restart — storage is ephemeral).

13. **Ephemeral Keycloak makes OIDC `sub` unstable** — it's the internal user
    UUID, re-minted on first login after every pod restart. OpenShift names
    identities `<idp>:<sub>` and the default `mappingMethod: claim` refuses to
    attach a new identity to an existing User ("Could not create user." at the
    callback). The OAuth CR must use `mappingMethod: add`. With a persistent
    KC database, subs are stable and `claim` works.

14. **The one secret that cannot be eliminated**: OpenShift's OAuth `OpenID`
    identity provider requires `clientSecret` — no PKCE, private_key_jwt,
    mTLS, or SPIFFE alternative exists (the 4.20+ external-OIDC mode still
    needs a console client secret). Minimized instead: generated in-memory by
    scripts/rotate-client-secret.sh, stored only in two k8s Secrets, never on
    disk or in a ConfigMap.

## Operational notes

- Keycloak runs `start-dev --import-realm`, single replica, no DB, **no admin
  account**. The realm ConfigMap (placeholders only) + env-injected
  Secrets/ConfigMaps are the entire config; restarts wipe local users/sessions
  and re-import. Realm changes = edit `keycloak/realm-teleport.json` →
  `oc create configmap keycloak-realm-teleport --from-file=... --dry-run=client -o yaml | oc apply -f -`
  → `oc rollout restart deployment/keycloak -n keycloak`.
- Credential posture: exactly ONE secret exists (the OIDC client secret), in
  two k8s Secrets, managed by `scripts/rotate-client-secret.sh` (create +
  rotate; value never touches disk). The SAML signing cert (public) lives in
  the `teleport-saml-cert` ConfigMap via `scripts/sync-saml-cert.sh`
  (idempotent; restarts KC only on change). `demo.env` holds hostnames only.
- `demo.env`, `rendered/`, `ingress-ca.crt` are gitignored (hygiene — none of
  them contain secrets anymore).
- `scripts/verify.sh` checks the full chain and is safe at any deployment stage.
- OpenShift group names are raw Teleport role names by design (the group
  visibly IS the Teleport role). On a shared cluster, check for collisions with
  pre-existing Group bindings before applying
  `openshift/40-rbac-group-bindings.yaml`, or prefix the group names (see the
  README's Day-2 section).
