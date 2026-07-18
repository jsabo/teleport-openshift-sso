# Troubleshooting

The login chain has three links — Teleport → Keycloak → OpenShift — and each
failure mode points at exactly one of them. Start by identifying *where* the
browser gets stuck.

## The issuer must match byte-for-byte

The single most common failure. OpenShift fetches
`https://<KC_ROUTE_HOST>/realms/teleport/.well-known/openid-configuration` and
compares the `issuer` field against `spec.identityProviders[].openID.issuer`
in the OAuth CR. Any difference — `http` vs `https`, a trailing slash, a
port — and logins fail (the OAuth pods log `oauth-server: issuer did not match`).

Both values derive from `KC_ROUTE_HOST` in `demo.env`, so they can only
diverge if one side was edited by hand or Keycloak's `KC_HOSTNAME` env var is
wrong. Check with:

```bash
curl -sk https://<KC_ROUTE_HOST>/realms/teleport/.well-known/openid-configuration | jq -r .issuer
oc get oauth cluster -o jsonpath='{.spec.identityProviders[0].openID.issuer}'
```

## Certificate trust (login page shows "authentication error")

The OAuth server validates Keycloak's route certificate against the
`keycloak-teleport-ca` ConfigMap. The walkthrough assumes the route uses the
router's default certificate, whose CA is in
`openshift-config-managed/default-ingress-cert`. If your cluster's router uses
a custom certificate, put *that* CA in the ConfigMap instead. Verify what's
actually being served:

```bash
echo | openssl s_client -connect <KC_ROUTE_HOST>:443 -servername <KC_ROUTE_HOST> 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

Errors appear in: `oc logs -n openshift-authentication deployment/oauth-openshift`.

## Three sessions

After a full login you hold **three separate sessions**: OpenShift (console),
Keycloak, and Teleport (web). Logging out of the console only ends the first
one. On your next login OpenShift sends you to Keycloak, which still has a
live session and silently issues a fresh token **without going back to
Teleport** — meaning your `teleport_roles` attribute (and therefore your
OpenShift groups) are *not* refreshed.

This matters for the just-in-time demo: to see a newly-granted Teleport role
appear, the Keycloak session must end so the SAML exchange re-runs. Easiest:
do console logins in a private window and close it between logins.
Alternatives: log out of the Keycloak account console too, or delete the
session in the Keycloak admin console (Sessions → sign out), or set the
`teleport` realm's SSO session idle timeout very low (e.g. 2 minutes) in
`realm-teleport.json` so Keycloak re-checks with Teleport on nearly every
login.

## Teleport says "You do not have access to this resource" at /enterprise/saml-idp/sso

Teleport authorizes *logging in through* the SAML IdP the same way it
authorizes managing it: the user needs a **version 8 role** whose `app_labels`
match the labels on the `saml_idp_service_provider` resource (this walkthrough
labels it `purpose: openshift-console-sso`). Two traps:

- A v7 role with `app_labels: {'*': '*'}` does **not** count — only v8 roles
  are consulted for SAML service providers. Check with
  `tctl get role/<name> --format=json | jq '.[0].version, .[0].spec.allow.app_labels'`.
- Role *membership* changes (adding a role to a user) only take effect on the
  user's **next login** — both for `tsh` (`tsh logout` then log in again) and
  for the web UI. Role *content* changes (editing allow rules inside a role
  the user already holds) apply to live sessions immediately.

Also remember SSO users' role lists are rewritten from the connector's
attribute mapping on every SSO login — grant SAML-IdP access through a role
the connector already maps (or add the mapping), not with a one-off
`tctl users update`.

## You see Teleport's login page mid-flow

Not an error. If you don't have an active Teleport web session, Teleport asks
you to log in (SSO/passkey) before it will assert your identity to Keycloak.
Log in and the flow continues automatically.

## A profile form appears after Teleport login ("update account information")

Keycloak's `VERIFY_PROFILE` required action fires when a required user-profile
field (by default: first name, last name) isn't supplied by the SAML
assertion — even when the first-login flow itself has no review step. The
realm JSON ships with `VERIFY_PROFILE` disabled for exactly this reason. If
the form still appears, check Realm settings → User profile for other required
fields, and either mark them optional or assert them from Teleport via
`attribute_mapping` in `teleport/saml-idp-service-provider.yaml`.

## OpenShift: `usernames that contain ":" must begin with "b64:"`

The `preferred_username` Keycloak sent contains a colon — usually a mangled
value from a Username Template Importer mapper, whose `${ATTRIBUTE.<name>}`
parser breaks on URN-style attribute names (`urn:oid:...` — the colons are
interpreted as template syntax). Don't use that mapper here at all: the
identity provider's `principalType: ATTRIBUTE` + `principalAttribute` already
set the username from the SAML `uid` attribute. A follow-on symptom of this
failure is `Code not valid` on retries — the browser re-submits an
authorization code that was already consumed by the first, failed attempt.

## Groups didn't appear / didn't update

1. Confirm the roles reached Keycloak: admin console → teleport realm → Users
   → your user → Attributes → `teleport_roles`. If stale, the SAML exchange
   didn't re-run — see [Three sessions](#three-sessions).
2. Confirm the claim reaches OpenShift: `oc get group <role-name> -o yaml` —
   synced groups carry the annotation
   `oauth.openshift.io/idp.keycloak-teleport`. Note OpenShift only
   adds/removes memberships in groups it manages via that annotation; it never
   touches manually-created groups.
3. Remember group *names* are Teleport role names — a typo in a
   ClusterRoleBinding's Group subject silently grants nothing.

## Keycloak pod won't become Ready

- `oc logs deployment/keycloak -n keycloak` — realm-import JSON errors are
  reported at startup with the offending line.
- A malformed `TELEPORT_SAML_CERT_B64` (stray newline, PEM header included)
  fails at import or at first SAML validation. It must be one bare base64 line.

## SAML response rejected by Keycloak

- "Invalid signature": the signing certificate doesn't match — re-export it
  (README Step 2), re-render, re-apply the ConfigMap, restart Keycloak. This
  happens after a Teleport CA rotation.
- Clock skew: SAML assertions are valid for a narrow window. Cluster nodes use
  chrony/NTP by default; check node time if you see NotBefore/NotOnOrAfter
  errors in Keycloak's log.

## Rollout after changing the OAuth CR seems stuck

`oc get co authentication` shows `Progressing=True` for 2–3 minutes while the
oauth-openshift pods restart — that's normal. If it goes `Degraded=True`, read
the operator's message: `oc get co authentication -o yaml | grep -A5 message`.
It names the exact misconfiguration (missing secret, bad CA, unreachable
issuer).
