#!/usr/bin/env bash
# Checks the things that cause the most confusing failures LATER if they are
# wrong NOW. Run before `terraform apply`.

set -uo pipefail
FAIL=0

ok()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL=1; }
warn() { printf "  \033[33mWARN\033[0m  %s\n" "$1"; }

echo "Tooling"
for t in az terraform kubectl helm jq docker; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t $(command -v $t)"; else bad "$t not found"; fi
done

echo
echo "Azure session"
if az account show >/dev/null 2>&1; then
  SUB=$(az account show --query name -o tsv)
  SUBID=$(az account show --query id -o tsv)
  ok "signed in to: ${SUB} (${SUBID})"
else
  bad "not signed in. Run: az login"
fi

echo
echo "Permissions"
if az account show >/dev/null 2>&1; then
  UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null || echo "")
  SUBID=$(az account show --query id -o tsv)
  if [[ -n "$UPN" ]]; then
    ok "identity: ${UPN}"
    ROLES=$(az role assignment list --assignee "$UPN" --scope "/subscriptions/${SUBID}" --query "[].roleDefinitionName" -o tsv 2>/dev/null || echo "")
    if echo "$ROLES" | grep -qE "Owner|User Access Administrator"; then
      ok "can create role assignments (found: $(echo $ROLES | tr '\n' ' '))"
    else
      bad "needs Owner or User Access Administrator on the subscription."
      echo "        This project creates role assignments (AcrPull, Key Vault Secrets User,"
      echo "        Service Bus Data Sender/Receiver). Contributor alone is NOT enough and"
      echo "        the apply will fail partway through with AuthorizationFailed."
    fi
  else
    warn "running as a service principal; cannot verify roles automatically"
  fi
fi

echo
echo "Resource providers"
for p in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.Sql \
         Microsoft.KeyVault Microsoft.ServiceBus Microsoft.OperationalInsights \
         Microsoft.Network Microsoft.ManagedIdentity; do
  STATE=$(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null || echo "Unknown")
  if [[ "$STATE" == "Registered" ]]; then ok "$p"
  else bad "$p is ${STATE}. Run: az provider register -n $p --wait"; fi
done

echo
echo "Quota"
if az account show >/dev/null 2>&1; then
  LOC="${LOCATION:-westeurope}"
  DSV5=$(az vm list-usage -l "$LOC" --query "[?contains(localName,'Standard DSv5 Family')].{c:currentValue,l:limit}" -o tsv 2>/dev/null | head -1)
  if [[ -n "$DSV5" ]]; then
    CUR=$(echo "$DSV5" | cut -f1); LIM=$(echo "$DSV5" | cut -f2)
    AVAIL=$((LIM - CUR))
    if (( AVAIL >= 8 )); then ok "DSv5 vCPU available in ${LOC}: ${AVAIL} (need ~8)"
    else bad "only ${AVAIL} DSv5 vCPUs free in ${LOC}; dev needs ~8. Request a quota increase or change location."; fi
  else
    warn "could not read DSv5 quota for ${LOC}"
  fi
fi

echo
echo "Entra groups (needed for AKS admin and SQL admin)"
for g in "ShiftBoard AKS Admins" "ShiftBoard SQL Admins"; do
  ID=$(az ad group show --group "$g" --query id -o tsv 2>/dev/null || echo "")
  if [[ -n "$ID" ]]; then ok "$g -> $ID"
  else warn "$g does not exist yet. Create it: az ad group create --display-name \"$g\" --mail-nickname \"$(echo $g | tr -d ' ')\""; fi
done

echo
if (( FAIL )); then
  echo "Preflight FAILED. Fix the items above before running terraform apply."
  exit 1
fi
echo "Preflight passed."
