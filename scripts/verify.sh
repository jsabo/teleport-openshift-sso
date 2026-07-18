#!/usr/bin/env bash
# Health checks for the Teleport → Keycloak → OpenShift SSO chain.
# Safe to run at any point during or after the walkthrough; later checks are
# skipped (not failed) if that part isn't deployed yet.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if [[ ! -f demo.env ]]; then
    echo "error: demo.env not found" >&2
    exit 1
fi
set -a
# shellcheck disable=SC1091
source demo.env
set +a

pass=0 fail=0
ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1"; fail=$((fail+1)); }
skip() { echo "  - $1 (skipped)"; }

echo "[1] Keycloak OIDC discovery"
issuer="$(curl -fsk "https://${KC_ROUTE_HOST}/realms/teleport/.well-known/openid-configuration" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])' 2>/dev/null)"
expected="https://${KC_ROUTE_HOST}/realms/teleport"
if [[ -z "${issuer}" ]]; then
    bad "discovery endpoint unreachable — is Keycloak deployed and the Route up?"
elif [[ "${issuer}" == "${expected}" ]]; then
    ok "issuer matches: ${issuer}"
else
    bad "issuer mismatch: got '${issuer}', want '${expected}' (check KC_HOSTNAME / OAuth CR issuer)"
fi

echo "[2] Keycloak route certificate chain"
if command -v openssl >/dev/null; then
    subject="$(echo | openssl s_client -connect "${KC_ROUTE_HOST}:443" -servername "${KC_ROUTE_HOST}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
    if [[ -n "${subject}" ]]; then
        ok "serving cert issuer: ${subject#issuer=}"
        echo "    (this issuer's CA must be in the keycloak-teleport-ca ConfigMap)"
    else
        bad "could not read the serving certificate"
    fi
else
    skip "openssl not found"
fi

echo "[3] OpenShift side (needs oc login)"
if command -v oc >/dev/null && oc whoami >/dev/null 2>&1; then
    if oc get ns keycloak >/dev/null 2>&1; then
        ready="$(oc get deploy keycloak -n keycloak -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
        [[ "${ready}" == "1" ]] && ok "keycloak pod ready" || bad "keycloak pod not ready"
    else
        skip "keycloak namespace not created yet"
    fi
    if oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null | grep -q keycloak-teleport; then
        ok "OAuth CR has the keycloak-teleport identity provider"
        auth_status="$(oc get co authentication -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' 2>/dev/null)"
        [[ "${auth_status}" == "True" ]] && ok "authentication cluster operator Available" || bad "authentication operator not Available yet (rollout can take a few minutes)"
    else
        skip "OAuth CR not configured yet"
    fi
    echo "  users/identities/groups created by SSO logins so far:"
    oc get users,identities,groups 2>/dev/null | sed 's/^/    /' || true
else
    skip "oc not logged in"
fi

echo
echo "${pass} passed, ${fail} failed"
exit $((fail > 0 ? 1 : 0))
