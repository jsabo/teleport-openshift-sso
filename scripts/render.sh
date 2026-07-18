#!/usr/bin/env bash
# Renders every template into rendered/ using the values from demo.env.
# Idempotent — run it again after changing demo.env.
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

for var in KC_ROUTE_HOST OAUTH_HOST TELEPORT_PROXY OIDC_CLIENT_SECRET KC_ADMIN_PASSWORD TELEPORT_SAML_CERT_B64; do
    if [[ -z "${!var:-}" ]]; then
        echo "error: ${var} is empty — set it in demo.env" >&2
        exit 1
    fi
done

if ! command -v envsubst >/dev/null; then
    echo "error: envsubst not found (macOS: brew install gettext)" >&2
    exit 1
fi

# Only substitute OUR variables. The realm JSON contains Keycloak's own
# ${ATTRIBUTE...} templates, which must survive rendering untouched.
VARS='$KC_ROUTE_HOST $OAUTH_HOST $TELEPORT_PROXY $OIDC_CLIENT_SECRET $KC_ADMIN_PASSWORD $TELEPORT_SAML_CERT_B64'

rm -rf rendered
mkdir -p rendered/keycloak rendered/teleport rendered/openshift

# Templated manifests
for f in keycloak/05-admin-secret.yaml \
         keycloak/20-deployment.yaml \
         keycloak/40-route.yaml \
         teleport/saml-idp-service-provider.yaml \
         openshift/30-oauth-cluster.yaml; do
    envsubst "${VARS}" < "${f}" > "rendered/${f}"
done

# Static manifests, copied so `oc apply -f rendered/keycloak/` gets everything
cp keycloak/00-namespace.yaml keycloak/30-service.yaml rendered/keycloak/
cp openshift/40-rbac-group-bindings.yaml rendered/openshift/

# Realm JSON → ConfigMap. Rendered JSON goes to its own directory (NOT
# rendered/keycloak/ — `oc apply -f <dir>` would try to apply raw JSON as a
# k8s resource).
mkdir -p rendered/realm
envsubst "${VARS}" < keycloak/realm-teleport.json > rendered/realm/realm-teleport.json

OC="$(command -v oc || command -v kubectl || true)"
if [[ -z "${OC}" ]]; then
    echo "error: need oc (or kubectl) on PATH to generate the realm ConfigMap" >&2
    exit 1
fi
"${OC}" create configmap keycloak-realm-teleport \
    --namespace=keycloak \
    --from-file=realm-teleport.json=rendered/realm/realm-teleport.json \
    --dry-run=client -o yaml > rendered/keycloak/10-realm-configmap.yaml

echo "rendered/ is ready:"
find rendered -type f | sort
