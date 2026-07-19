#!/usr/bin/env bash
# Renders the hostname-bearing templates into rendered/ using demo.env.
# demo.env contains NO secrets — only hostnames. The OIDC client secret is
# handled by scripts/rotate-client-secret.sh (straight into k8s Secrets) and
# the Teleport SAML certificate by scripts/sync-saml-cert.sh; Keycloak itself
# resolves both into the realm at import time via ${VAR} env substitution.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if [[ ! -f demo.env ]]; then
    echo "error: demo.env not found — copy demo.env.example to demo.env and fill it in" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1091
source demo.env
set +a

for var in KC_ROUTE_HOST OAUTH_HOST CONSOLE_HOST TELEPORT_PROXY; do
    if [[ -z "${!var:-}" ]]; then
        echo "error: ${var} is empty — set it in demo.env" >&2
        exit 1
    fi
done

if ! command -v envsubst >/dev/null; then
    echo "error: envsubst not found (macOS: brew install gettext)" >&2
    exit 1
fi

# Only substitute OUR variables — the realm JSON is NOT rendered at all (its
# ${VAR} placeholders are resolved by Keycloak from the pod environment).
VARS='$KC_ROUTE_HOST $OAUTH_HOST $CONSOLE_HOST $TELEPORT_PROXY'

rm -rf rendered
mkdir -p rendered/keycloak rendered/teleport rendered/openshift

for f in keycloak/10-sso-config.yaml \
         keycloak/40-route.yaml \
         teleport/saml-idp-service-provider.yaml \
         openshift/30-oauth-cluster.yaml; do
    envsubst "${VARS}" < "${f}" > "rendered/${f}"
done

# Static manifests, copied so `oc apply -f rendered/keycloak/` gets everything
cp keycloak/00-namespace.yaml keycloak/20-deployment.yaml keycloak/30-service.yaml rendered/keycloak/
cp openshift/40-rbac-group-bindings.yaml rendered/openshift/

echo "rendered/ is ready (hostnames only — no secrets involved):"
find rendered -type f | sort