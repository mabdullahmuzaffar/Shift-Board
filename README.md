# ShiftBoard

Workforce shift scheduling for multi-site operators, built as a production-style
Azure Kubernetes platform.

Three services, provisioned by Terraform, deployed by Argo CD, secured with
workload identity so that **no password, connection string or client secret
exists anywhere in the cluster, the images, or Git**.

---

## What this actually is

A retail or healthcare operator with many sites needs to publish staff shifts,
let workers claim open ones, and catch scheduling problems before they become
payroll or compliance problems. Three rules matter: nobody double-booked,
everyone gets their contractual rest between shifts, and nobody exceeds their
weekly hours.

Conflict detection is pushed to an async worker on purpose. It keeps the write
path fast, and it makes the expensive rule evaluation independently retryable —
which is the architectural decision the whole event-driven half of this project
exists to demonstrate.

| Service | Stack | Job |
|---|---|---|
| `shift-api` | Python 3.12, FastAPI, SQLAlchemy | REST API, publishes domain events |
| `roster-worker` | Python 3.12, Service Bus SDK | Consumes events, runs conflict rules |
| `web` | React 18, TypeScript, Vite, nginx | Operations console |

---

## Architecture

```
                        Internet
                            │
                   ┌────────▼─────────┐
                   │  Front Door+WAF  │  (prod only)
                   └────────┬─────────┘
                            │
                   ┌────────▼─────────┐
                   │  ingress-nginx   │  TLS via cert-manager
                   └────────┬─────────┘
                            │
   ┌────────────────────────▼──────────────────────────────┐
   │  AKS  (Azure CNI Overlay + Calico NetworkPolicy)      │
   │                                                        │
   │   ┌────────┐   /api    ┌───────────┐                  │
   │   │  web   │──proxy───▶│ shift-api │                  │
   │   │ nginx  │           └─────┬─────┘                  │
   │   └────────┘                 │ publish                │
   │                              │                        │
   │                     ┌────────▼────────┐               │
   │                     │  roster-worker  │◀──consume──┐  │
   │                     └────────┬────────┘            │  │
   └──────────────────────────────┼─────────────────────┼──┘
                                  │                     │
       ┌──────────────────────────┼─────────────────────┼───────┐
       │  Azure (private endpoints, no public exposure)         │
       │                          │                     │       │
       │   ┌──────────┐   ┌───────▼──────┐   ┌──────────┴────┐  │
       │   │ Key Vault│   │  Azure SQL   │   │  Service Bus  │  │
       │   └──────────┘   └──────────────┘   └───────────────┘  │
       └────────────────────────────────────────────────────────┘

  Auth for every arrow into Azure:  Workload Identity (federated OIDC)
  Nothing above holds a password.
```

**The trust chain**, which is the single most important thing to understand
here:

```
ServiceAccount token (projected into pod, 1h TTL, audience-scoped)
   └─▶ Federated credential on a User-Assigned Managed Identity
          (subject = system:serviceaccount:<namespace>:<name>, matched exactly)
             └─▶ Entra ID access token
                    └─▶ Azure SQL / Service Bus / Key Vault
```

Move a pod to another namespace and its access silently stops working. That is
the intended blast-radius control, not a bug.

---

## Repository layout

| Path | Contains |
|---|---|
| `services/shift-api/` | FastAPI app, Alembic migrations, tests |
| `services/roster-worker/` | Consumer loop, conflict rule engine, tests |
| `services/web/` | React console, nginx config, tests |
| `infra/bootstrap/` | One-time: Terraform state storage account |
| `infra/modules/` | 10 reusable modules (network, aks, sql, identity, …) |
| `infra/envs/dev/` | Dev composition + scoped Checkov exemptions |
| `infra/envs/prod/` | Prod composition, full security baseline |
| `charts/` | Three Helm charts |
| `gitops/bootstrap/` | Argo CD install values + root application |
| `gitops/apps/dev/` | App-of-apps: platform + services, with sync waves |
| `policy/audit_manifests.py` | Pod-security gate that runs on rendered output |
| `scripts/` | Preflight check, values renderer, DB grant script |
| `Makefile` | Every CI command, runnable locally |

---

## Prerequisites

| Tool | Minimum | Check |
|---|---|---|
| Azure CLI | 2.60 | `az version` |
| Terraform | 1.9 | `terraform version` |
| kubectl | 1.30 | `kubectl version --client` |
| Helm | 3.14 | `helm version` |
| Docker | 24 | `docker version` |
| Python | 3.12 | `python3 --version` |
| Node | 20 | `node --version` |
| jq | any | `jq --version` |

**Azure permissions: you need Owner or User Access Administrator on the
subscription.** Contributor alone is not enough. This project creates role
assignments (AcrPull, Key Vault Secrets User, Service Bus Data Sender and
Receiver), and Contributor cannot create those — the apply will fail partway
through with `AuthorizationFailed`, leaving half an environment behind.

Run `./scripts/preflight.sh` before anything else. It checks tooling, your
Azure session, your role assignments, resource provider registration, vCPU
quota, and the Entra groups.

---

## Cost

This is real money. Read this before applying.

| Environment | Rough monthly | Main drivers |
|---|---|---|
| **dev** | **$90–160** | AKS Free tier, Spot nodes, SQL serverless (auto-pauses) |
| **prod** | **$800–1,300** | AKS Standard, 3 zones, on-demand D4s_v5, SQL GP_Gen5_2, ACR Premium, Service Bus Premium, Front Door |

Dev sets a $150 consumption budget by default with alerts at 80% actual and
100% forecast. **An idle AKS cluster still bills.** Run `make tf-destroy` when
you finish a session; the whole environment rebuilds in about 25 minutes.

---

## Step-by-step build

### Phase 0 — Verify locally (no Azure, no cost)

| # | Command | Expect |
|---|---|---|
| 0.1 | `./scripts/preflight.sh` | All checks pass |
| 0.2 | `cd services/shift-api && pip install -r requirements-dev.txt && python -m pytest` | 17 passed, ≥80% coverage |
| 0.3 | `cd services/roster-worker && pip install -r requirements-dev.txt && python -m pytest` | 44 passed, ≥75% coverage |
| 0.4 | `cd services/web && npm ci && npm run test && npx tsc -b` | 13 passed, no type errors |
| 0.5 | `make lint` | Clean |
| 0.6 | `make audit` | "PASS: every container is non-root…" |
| 0.7 | `cd infra/envs/dev && checkov -d .` | 0 failed |

If any of these fail, stop. They will not get easier once cloud resources exist.

### Phase 1 — Terraform state backend (once per subscription)

| # | Action | Command |
|---|---|---|
| 1.1 | Sign in | `az login && az account set -s <subscription-id>` |
| 1.2 | Create the Entra groups | `az ad group create --display-name "ShiftBoard AKS Admins" --mail-nickname ShiftBoardAKSAdmins` (repeat for `ShiftBoard SQL Admins`) |
| 1.3 | Add yourself | `az ad group member add --group "ShiftBoard AKS Admins" --member-id $(az ad signed-in-user show --query id -o tsv)` |
| 1.4 | Configure | `cd infra/bootstrap && cp terraform.tfvars.example terraform.tfvars` then edit — **`storage_account_name` must be globally unique** |
| 1.5 | Apply | `terraform init && terraform apply` |
| 1.6 | Note the output | `backend_config` — you need it in the next step |

### Phase 2 — Provision dev infrastructure (~25 min)

| # | Action | Command / note |
|---|---|---|
| 2.1 | Point the backend at your storage account | Edit `storage_account_name` in `infra/envs/dev/versions.tf` |
| 2.2 | Configure | `cd infra/envs/dev && cp terraform.tfvars.example terraform.tfvars` |
| 2.3 | Set `name_suffix` | **Change this.** ACR, Key Vault, SQL and Service Bus names are globally unique across all of Azure |
| 2.4 | Fill in tenant, subscription, group object ids | `az ad group show --group "ShiftBoard AKS Admins" --query id -o tsv` |
| 2.5 | Init | `make tf-init ENV=dev` |
| 2.6 | Plan and **read it** | `make tf-plan ENV=dev` — expect ~55 resources |
| 2.7 | Apply | `make tf-apply ENV=dev` (AKS alone takes 10–15 min) |
| 2.8 | Save outputs | `terraform output -json helm_values` |

### Phase 3 — Grant the database users

Terraform cannot do this. Contained database users live *inside* the database,
not in the Azure control plane, so they need a T-SQL connection.

| # | Action | Command |
|---|---|---|
| 3.1 | Get kubeconfig | `make creds ENV=dev` |
| 3.2 | Edit the script | `scripts/grant-db-access.sql` — identity names must match `id-shiftboard-dev-*` |
| 3.3 | Run from inside the VNet | `kubectl -n shiftboard run sqlcmd --rm -it --restart=Never --image=mcr.microsoft.com/mssql-tools18/sqlcmd -- /opt/mssql-tools18/bin/sqlcmd -S <fqdn> -d shiftboard -G -C -i grant-db-access.sql` |
| 3.4 | Verify | The script's final `SELECT` lists both identities and their roles |

The SQL server has **no public endpoint**, which is why this runs from a pod.
In dev you may temporarily open the firewall to your IP instead — revert it
afterwards.

### Phase 4 — Build and push images

| # | Action | Command |
|---|---|---|
| 4.1 | Get the ACR host | `export ACR=$(terraform -chdir=infra/envs/dev output -raw acr_login_server)` |
| 4.2 | Tag from Git | `export TAG=$(git rev-parse --short HEAD)` |
| 4.3 | Build and push | `make push ACR=$ACR TAG=$TAG` |
| 4.4 | Scan, fail on HIGH/CRITICAL | `make scan TAG=$TAG` |
| 4.5 | Confirm | `az acr repository list --name ${ACR%%.*} -o table` |

Never tag `latest`. The Helm charts refuse to render without an explicit tag or
digest, because a rollback to a mutable tag is not a rollback.

### Phase 5 — Install Argo CD

| # | Action | Command |
|---|---|---|
| 5.1 | Add the repo | `helm repo add argo https://argoproj.github.io/argo-helm && helm repo update` |
| 5.2 | Install | `helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version 7.7.11 -f gitops/bootstrap/values-argocd.yaml --wait` |
| 5.3 | Get the password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| 5.4 | Open the UI | `kubectl -n argocd port-forward svc/argocd-server 8080:443` |

### Phase 6 — Wire values and deploy

| # | Action | Command |
|---|---|---|
| 6.1 | Fork and update the repo URL | Replace `YOUR_ORG` in `gitops/bootstrap/root-app.yaml` and `gitops/apps/dev/3*.yaml` |
| 6.2 | Render values from Terraform | `make values ENV=dev ACR=$ACR TAG=$TAG` |
| 6.3 | Confirm no placeholders remain | `grep -rn REPLACED_BY_PIPELINE gitops/apps/dev` |
| 6.4 | Commit and push | Argo CD deploys from **Git**, not your laptop |
| 6.5 | Apply the root app | `kubectl apply -f gitops/bootstrap/root-app.yaml` |
| 6.6 | Watch it converge | `kubectl -n argocd get applications -w` |

Sync waves run in order: namespaces → CRDs → platform → SecretStore and
ClusterIssuer → `shift-api` (its PreSync hook migrates the schema) →
`roster-worker` and `web`.

### Phase 7 — Verify it works

| # | Check | Command | Healthy |
|---|---|---|---|
| 7.1 | Pods | `kubectl -n shiftboard get pods` | All `Running`, none restarting |
| 7.2 | Migration ran | `kubectl -n shiftboard get jobs` | `…-migrate-1` shows `1/1` |
| 7.3 | API ready | `kubectl -n shiftboard port-forward svc/shiftboard-shift-api 8000:8000` then `curl localhost:8000/readyz` | `{"status":"ok","checks":{"database":"ok"}}` |
| 7.4 | **Worker consuming** | `curl localhost:9102 \| grep roster_worker_consumer_up` | `1` — a running pod is not the same as a working consumer |
| 7.5 | End-to-end | Create a site, a worker, two overlapping shifts, claim both | Second claim produces a conflict row |
| 7.6 | Console | `kubectl -n shiftboard port-forward svc/shiftboard-web 8080:80` | Coverage meter renders |

### Phase 8 — Tear down

| # | Action | Command |
|---|---|---|
| 8.1 | Remove Argo CD apps first | `kubectl delete -f gitops/bootstrap/root-app.yaml` |
| 8.2 | Wait for the LoadBalancer to go | Otherwise Terraform leaves an orphaned public IP that keeps billing |
| 8.3 | Destroy | `make tf-destroy ENV=dev` |
| 8.4 | Confirm | `az group list -o table` |

---

## Troubleshooting

| Symptom | Almost always | Fix |
|---|---|---|
| `AADSTS700213` / `CredentialUnavailableError` | Federated credential subject mismatch | The SA annotation `azure.workload.identity/client-id`, the pod label `azure.workload.identity/use=true`, and the federated subject `system:serviceaccount:<ns>:<name>` must all agree |
| Pods stuck `Pending` in dev | Spot node taint | Ensure the `kubernetes.azure.com/scalesetpriority` toleration is in the values overlay |
| `Login failed for user '<token-identified principal>'` | Phase 3 skipped | Run `grant-db-access.sql` |
| Argo CD: "app path outside root" | Value file escaping the chart dir | Already fixed with the multi-source `$values` pattern — don't revert it |
| nginx exits immediately | `shiftApiHost` wrong | It resolves the upstream at startup; must be `shiftboard-shift-api` |
| `terraform destroy` hangs on the VNet | Orphaned LoadBalancer | Delete the Argo CD apps first (step 8.1) |
| Everything times out, DNS fails | NetworkPolicy with no DNS egress rule | The single most common first-NetworkPolicy mistake |

---

## What is deliberately *not* here

Honest scope boundaries, so a reviewer knows these were decisions:

- **No progressive delivery.** Rolling updates only. Canary with automated
  analysis and rollback is roadmap project 8.
- **No image signing or SBOM.** Trivy gates the pipeline; Cosign, Syft and
  Kyverno admission control are roadmap project 9.
- **No multi-region.** Single region. DR is roadmap project 10.
- **No disk encryption set.** Needs a Key Vault key with its own rotation and
  RBAC lifecycle — that belongs to a platform landing zone, project 7.
- **Duplicated ORM models** between the two services. A shared package would
  couple their release cycles; the trade-off is recorded rather than hidden.

---

## Verification status:

Everything below was run, not assumed.

| Check | Result |
|---|---|
| `shift-api` tests | 17 passed, 82% coverage (gate 80%) |
| `roster-worker` tests | 44 passed, 79% coverage (gate 75%) |
| `web` tests | 13 passed, `tsc -b` clean, production build succeeds |
| Ruff, all Python | Clean |
| Terraform fmt | Canonical across all modules and envs |
| Checkov `envs/prod` | 59 passed, 0 failed, 18 reasoned skips |
| Checkov `envs/dev` | 57 passed, 0 failed (dev-scoped exemptions) |
| `helm lint` | 3/3 charts pass |
| `helm template` | 24 manifests, all valid YAML |
| Pod security audit | 4/4 containers pass; gate verified against injected violations |
| GitOps manifests | 23 documents, all valid YAML |

**Not verified here:** `terraform validate` requires provider schemas from the
registry, which was unreachable in the build environment. HCL parses and is
statically scanned, but a wrong argument name would still slip through. Run
`make tf-init && terraform -chdir=infra/envs/dev validate` as your first real
check.

---

## Licence

MIT.
