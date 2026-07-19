#!/usr/bin/env bash
# Exports Teleport's SAML IdP signing certificate (public key material) and
# stores it in the teleport-saml-cert ConfigMap that the Keycloak pod reads.
# Idempotent: only updates the ConfigMap and restarts Keycloak when the
# certificate actually changed.
#
# Run at install time and again after a Teleport CA rotation (the only event
# that changes this certificate). Requires an active tsh login to the
# Teleport cluster (tctl uses your current profile).
set -euo pipefail

for cmd in oc tctl openssl; do
    command -v "$cmd" >/dev/null || { echo "error: $cmd not found" >&2; exit 1; }
done
oc whoami >/dev/null 2>&1 || { echo "error: not logged into the cluster (oc whoami failed)" >&2; exit 1; }

# tctl exports binary DER (with a trailing newline Keycloak rejects);
# openssl re-encodes exactly one clean certificate, and stripping the PEM
# armor leaves the bare base64 Keycloak's signingCertificate field expects.
CERT="$(tctl auth export --type saml-idp | openssl x509 -inform DER | grep -v CERTIFICATE | tr -d '\n')"
case "${CERT}" in
    MII*) ;;
    *) echo "error: unexpected export format (want base64 starting with MII)" >&2; exit 1;;
esac

CURRENT="$(oc get configmap teleport-saml-cert -n keycloak -o jsonpath='{.data.TELEPORT_SAML_CERT_B64}' 2>/dev/null || true)"
if [[ "${CURRENT}" == "${CERT}" ]]; then
    echo "certificate unchanged — nothing to do"
    exit 0
fi

oc create configmap teleport-saml-cert \
    --namespace=keycloak \
    --from-literal=TELEPORT_SAML_CERT_B64="${CERT}" \
    --dry-run=client -o yaml | oc apply -f -
echo "teleport-saml-cert ConfigMap updated"

if oc get deployment/keycloak -n keycloak >/dev/null 2>&1; then
    oc rollout restart deployment/keycloak -n keycloak
    oc rollout status deployment/keycloak -n keycloak --timeout=180s
    echo "keycloak restarted with the new certificate"
else
    echo "keycloak not deployed yet — it will pick the certificate up at first start"
fi
