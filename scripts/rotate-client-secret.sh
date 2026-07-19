#!/usr/bin/env bash
# Creates OR rotates the OIDC client secret shared by Keycloak's `openshift`
# client and OpenShift's OAuth server.
#
# The value is generated in memory and written ONLY to the two Kubernetes
# Secrets that need it — it never touches a file, a ConfigMap, or your shell
# history. Run this once at install time and again whenever your rotation
# policy (or a suspected exposure) demands it.
set -euo pipefail

if ! command -v oc >/dev/null; then
    echo "error: oc not found" >&2
    exit 1
fi
oc whoami >/dev/null 2>&1 || { echo "error: not logged into the cluster (oc whoami failed)" >&2; exit 1; }

SECRET_VALUE="$(openssl rand -hex 32)"

# Keycloak side: consumed as the OIDC_CLIENT_SECRET env var, which Keycloak
# substitutes into the realm's client definition at import time.
oc create secret generic keycloak-oidc-client \
    --namespace=keycloak \
    --from-literal=clientSecret="${SECRET_VALUE}" \
    --dry-run=client -o yaml | oc apply -f -

# OpenShift side: referenced by the OAuth CR's clientSecret.
oc create secret generic keycloak-teleport-client-secret \
    --namespace=openshift-config \
    --from-literal=clientSecret="${SECRET_VALUE}" \
    --dry-run=client -o yaml | oc apply -f -

unset SECRET_VALUE
echo "client secret set in keycloak/keycloak-oidc-client and openshift-config/keycloak-teleport-client-secret"

# Keycloak only reads the env at import time, so restart it if it's running.
if oc get deployment/keycloak -n keycloak >/dev/null 2>&1; then
    oc rollout restart deployment/keycloak -n keycloak
    oc rollout status deployment/keycloak -n keycloak --timeout=180s
    echo "keycloak restarted with the new secret"
else
    echo "keycloak not deployed yet — it will pick the secret up at first start"
fi
# The OAuth server watches its Secret and reloads automatically; a login
# attempted during the Keycloak restart window may fail once — just retry.
