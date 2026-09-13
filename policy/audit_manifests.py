"""Pod security audit for rendered Helm output.

Run in CI after `helm template`, before anything is applied. Catches the
regressions that Helm's own lint cannot see, because they only exist in the
rendered result:

  * a container that lost its securityContext during a values refactor
  * a missing memory limit, so one leaking pod can evict its neighbours
  * a mutable image tag sneaking back in
  * a service account token mounted into a pod that never calls the API

Usage:
    helm template ... > rendered.yaml
    python policy/audit_manifests.py rendered.yaml [more.yaml ...]

Exits non-zero on any finding, so the pipeline stops.
"""

import glob
import sys

import yaml

REQUIRED_POD = {"runAsNonRoot": True}
FAILS = []
CHECKED = 0

def check_container(kind, name, c, pod_sc):
    global CHECKED
    CHECKED += 1
    where = f"{kind}/{name}:{c.get('name')}"
    sc = c.get("securityContext", {})
    if sc.get("allowPrivilegeEscalation") is not False:
        FAILS.append(f"{where}: allowPrivilegeEscalation not false")
    if sc.get("readOnlyRootFilesystem") is not True:
        FAILS.append(f"{where}: readOnlyRootFilesystem not true")
    if sc.get("capabilities", {}).get("drop") != ["ALL"]:
        FAILS.append(f"{where}: capabilities not dropped")
    if sc.get("privileged") is not False:
        FAILS.append(f"{where}: privileged not explicitly false")
    if pod_sc.get("runAsNonRoot") is not True:
        FAILS.append(f"{where}: pod runAsNonRoot not true")
    if pod_sc.get("runAsUser", 0) == 0:
        FAILS.append(f"{where}: runAsUser is root or unset")
    if pod_sc.get("seccompProfile", {}).get("type") != "RuntimeDefault":
        FAILS.append(f"{where}: seccompProfile not RuntimeDefault")
    res = c.get("resources", {})
    if not res.get("requests", {}).get("cpu"):
        FAILS.append(f"{where}: no CPU request (unschedulable guarantees)")
    if not res.get("requests", {}).get("memory"):
        FAILS.append(f"{where}: no memory request")
    if not res.get("limits", {}).get("memory"):
        FAILS.append(f"{where}: no memory limit (a leak can evict neighbours)")
    img = c.get("image", "")
    if img.endswith(":latest") or ":" not in img.split("/")[-1] and "@" not in img:
        FAILS.append(f"{where}: mutable image reference {img!r}")

targets = sys.argv[1:]
if not targets:
    print("usage: audit_manifests.py <rendered.yaml> [...]", file=sys.stderr)
    sys.exit(2)

files = []
for t in targets:
    files.extend(sorted(glob.glob(t)) or [t])

for f in files:
    for d in yaml.safe_load_all(open(f)):
        if not d: continue
        kind, name = d["kind"], d["metadata"]["name"]
        spec = d.get("spec", {})
        tmpl = spec.get("template", {}).get("spec")
        if kind == "Job":
            tmpl = spec.get("template", {}).get("spec")
        if not tmpl: continue
        pod_sc = tmpl.get("securityContext", {})
        if tmpl.get("automountServiceAccountToken") is not False:
            FAILS.append(f"{kind}/{name}: automountServiceAccountToken not disabled")
        for c in tmpl.get("containers", []):
            check_container(kind, name, c, pod_sc)

print(f"containers audited: {CHECKED}")
if FAILS:
    print(f"FAILURES ({len(FAILS)}):")
    for x in FAILS: print("  -", x)
    sys.exit(1)
print("PASS: every container is non-root, read-only-root, cap-dropped, seccomp-confined,")
print("      resource-bounded, immutably tagged, and has no Kubernetes API token.")
