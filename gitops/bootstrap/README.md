# Argo CD bootstrap

Argo CD itself is the one thing that cannot be managed by Argo CD, so it is
installed once with Helm. Everything after that is declarative.

```bash
# 1. Point kubectl at the cluster
az aks get-credentials -g rg-shiftboard-dev -n aks-shiftboard-dev --overwrite-existing

# 2. Install Argo CD
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 7.7.11 \
  -f values-argocd.yaml \
  --wait

# 3. Hand it the root application. From here on, Git is the source of truth
#    and nothing is ever applied by hand again.
kubectl apply -f root-app.yaml

# 4. Initial admin password (delete the secret once you have SSO working)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## Why app-of-apps

`root-app.yaml` is a single Application that points at `gitops/apps/<env>`.
That directory contains Applications for the platform components and the
three services. The effect:

- One `kubectl apply` bootstraps an entire environment.
- Adding a component is a pull request, not a cluster operation.
- Sync waves give a deterministic install order, which matters because
  External Secrets must exist before a workload references a SecretStore,
  and the Prometheus CRDs must exist before any chart creates a
  ServiceMonitor.

## Sync waves

| Wave | Contents | Why it must come first |
|------|----------|------------------------|
| -2 | Namespaces | Everything else lands inside them |
| -1 | CRDs: external-secrets, prometheus-operator, KEDA | A chart referencing a CRD that does not exist fails to sync |
| 0  | Platform: ingress-nginx, cert-manager, ESO, kube-prometheus-stack | Workloads depend on these |
| 1  | ClusterSecretStore, ClusterIssuer | Need ESO and cert-manager running |
| 2  | shift-api (its PreSync hook migrates the schema) | Schema before consumers |
| 3  | roster-worker, web | Depend on the API and the schema |
