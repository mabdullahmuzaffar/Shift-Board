#!/usr/bin/env bash
# Rewrites the REPLACED_BY_PIPELINE placeholders in gitops/apps/<env>/ from
# Terraform outputs.
#
# Why this exists: hand-copying a managed identity client id into a values
# file is the single most common way to break workload identity, and the
# failure mode is an opaque AADSTS700213 hours later. Deriving them from
# `terraform output` means the values can never drift from the infrastructure
# that was actually applied.
#
# Usage:  ./scripts/render-values.sh dev <acr-login-server> <image-tag>

set -euo pipefail

ENV="${1:?usage: render-values.sh <env> <acr-login-server> <image-tag>}"
ACR="${2:?missing acr login server}"
TAG="${3:?missing image tag}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/infra/envs/${ENV}"
GITOPS_DIR="${REPO_ROOT}/gitops/apps/${ENV}"

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v terraform >/dev/null || { echo "terraform is required"; exit 1; }

echo "Reading Terraform outputs from ${TF_DIR}"
VALUES_JSON="$(terraform -chdir="${TF_DIR}" output -json helm_values)"

get() { echo "${VALUES_JSON}" | jq -r ".$1"; }

SQL_HOST="$(get sqlServerFqdn)"
SB_NS="$(get serviceBusNamespace)"
KV_URI="$(get keyVaultUri)"
API_CLIENT_ID="$(get shiftApiClientId)"
WORKER_CLIENT_ID="$(get rosterWorkerClientId)"
ESO_CLIENT_ID="$(get externalSecretsClientId)"

# Fail loudly rather than writing an empty string into a values file.
for pair in "SQL_HOST=${SQL_HOST}" "SB_NS=${SB_NS}" "KV_URI=${KV_URI}" \
            "API_CLIENT_ID=${API_CLIENT_ID}" "WORKER_CLIENT_ID=${WORKER_CLIENT_ID}" \
            "ESO_CLIENT_ID=${ESO_CLIENT_ID}"; do
  name="${pair%%=*}"; value="${pair#*=}"
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    echo "ERROR: Terraform output for ${name} is empty. Has 'terraform apply' completed?" >&2
    exit 1
  fi
done

echo "  ACR              ${ACR}"
echo "  image tag        ${TAG}"
echo "  SQL host         ${SQL_HOST}"
echo "  Service Bus      ${SB_NS}"
echo "  Key Vault        ${KV_URI}"

render() {
  local file="$1" repo="$2" client_id="$3"
  echo "Rendering ${file}"
  # Placeholder-only substitution: running this twice is a no-op, and it
  # cannot silently corrupt a value someone has since edited by hand.
  sed -i.bak \
    -e "0,/repository: REPLACED_BY_PIPELINE/s||repository: ${repo}|" \
    -e "0,/tag: REPLACED_BY_PIPELINE/s||tag: ${TAG}|" \
    -e "0,/clientId: REPLACED_BY_PIPELINE/s||clientId: ${client_id}|" \
    -e "s|host: REPLACED_BY_PIPELINE|host: ${SQL_HOST}|" \
    -e "s|namespace: REPLACED_BY_PIPELINE|namespace: ${SB_NS}|" \
    "${file}"
  rm -f "${file}.bak"
}

render "${GITOPS_DIR}/values-shift-api.yaml"     "${ACR}/shiftboard/shift-api"     "${API_CLIENT_ID}"
render "${GITOPS_DIR}/values-roster-worker.yaml" "${ACR}/shiftboard/roster-worker" "${WORKER_CLIENT_ID}"
render "${GITOPS_DIR}/values-web.yaml"           "${ACR}/shiftboard/web"           ""

# Platform manifests carry their own placeholders.
sed -i.bak "s|vaultUrl: \"REPLACED_BY_PIPELINE\"|vaultUrl: \"${KV_URI}\"|" "${GITOPS_DIR}/20-secretstore.yaml"
sed -i.bak "s|azure.workload.identity/client-id: \"REPLACED_BY_PIPELINE\"|azure.workload.identity/client-id: \"${ESO_CLIENT_ID}\"|" "${GITOPS_DIR}/12-platform-external-secrets.yaml"
rm -f "${GITOPS_DIR}"/*.bak

echo
if grep -rn "REPLACED_BY_PIPELINE" "${GITOPS_DIR}" 2>/dev/null; then
  echo "WARNING: placeholders above are still unset. KEDA and web clientId are"
  echo "expected to remain if you are not using them; anything else is a bug."
else
  echo "All placeholders resolved."
fi

echo
echo "Next: commit and push. Argo CD deploys from Git, not from your laptop."
echo "  git add gitops/apps/${ENV} && git commit -m 'deploy ${TAG} to ${ENV}' && git push"
