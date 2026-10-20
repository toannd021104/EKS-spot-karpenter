#!/usr/bin/env bash
# Chart assertions: helm lint + helm template (offline, no cluster) for each scaler, then checks on the render:
# no ECR URL, no Redis, no ExternalSecret, every Deployment has the scaler nodeSelector + toleration + label,
# 3 PDBs (services with replicas >= 2), cartservice has 1 replica and no PDB, scheduling.scaler is required.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib_sandbox.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_sandbox.sh"

CHART="$REAL_REPO_ROOT/kubernetes/boutique"
PY="$REAL_REPO_ROOT/presentation/.venv/bin/python"
[[ -x "$PY" ]] || PY=python3
command -v helm >/dev/null || {
  echo "helm is required" >&2
  exit 1
}
"$PY" -c 'import yaml' 2>/dev/null || {
  echo "PyYAML is required (presentation/.venv or system python3)" >&2
  exit 1
}

CHECK=$(mktemp)
trap 'rm -f "$CHECK"' EXIT
cat >"$CHECK" <<'PYEOF'
import re, sys, yaml
scaler = sys.argv[1]
text = sys.stdin.read()
docs = [d for d in yaml.safe_load_all(text) if d]
errors = []
if re.search(r"amazonaws|\.ecr\.", text, re.I):
    errors.append("ECR/amazonaws URL present")
if re.search(r"redis", text, re.I):
    errors.append("redis present")
if any(d.get("kind") == "ExternalSecret" for d in docs):
    errors.append("ExternalSecret present")
if any(d.get("kind") in ("Namespace", "NetworkPolicy") for d in docs):
    errors.append("Namespace/NetworkPolicy must not be templated")
deps = [d for d in docs if d.get("kind") == "Deployment"]
pdbs = [d for d in docs if d.get("kind") == "PodDisruptionBudget"]
if len(deps) != 10:
    errors.append(f"expected 10 Deployments, got {len(deps)}")
for d in deps:
    name = d["metadata"]["name"]
    pod = d["spec"]["template"]
    if pod["spec"].get("nodeSelector", {}).get("scaler") != scaler:
        errors.append(f"{name}: nodeSelector scaler != {scaler}")
    if not any(t.get("key") == "scaler" and t.get("value") == scaler and t.get("effect") == "NoSchedule" for t in pod["spec"].get("tolerations", [])):
        errors.append(f"{name}: missing toleration")
    if pod["metadata"]["labels"].get("scaler") != scaler:
        errors.append(f"{name}: missing pod label scaler")
    multi = d["spec"]["replicas"] >= 2
    spread = pod["spec"].get("topologySpreadConstraints", [])
    if multi and not any(c["topologyKey"] == "kubernetes.io/hostname" and c["whenUnsatisfiable"] == "DoNotSchedule" for c in spread):
        errors.append(f"{name}: replicas>=2 needs a hostname DoNotSchedule spread")
    if not multi and spread:
        errors.append(f"{name}: single replica must not carry a spread constraint")
    img = pod["spec"]["containers"][0]["image"]
    if not img.startswith("us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/"):
        errors.append(f"{name}: unexpected image {img}")
multi_names = sorted(d["metadata"]["name"] for d in deps if d["spec"]["replicas"] >= 2)
if len(pdbs) != 3 or len(multi_names) != 3:
    errors.append(f"expected 3 PDBs for 3 multi-replica services, got {len(pdbs)} PDBs / {multi_names}")
cart = [d for d in deps if d["metadata"]["name"].endswith("cartservice")]
if not cart or cart[0]["spec"]["replicas"] != 1:
    errors.append("cartservice must have 1 replica")
if any("cartservice" in p["metadata"]["name"] for p in pdbs):
    errors.append("cartservice must not have a PDB")
if any(e.get("name") == "REDIS_ADDR" for d in deps for c in d["spec"]["template"]["spec"]["containers"] for e in c.get("env", [])):
    errors.append("REDIS_ADDR must not be set")
if errors:
    print("\n".join(errors)); sys.exit(1)
PYEOF

for s in ca karpenter automode; do
  echo "== scaler $s"
  if helm lint "$CHART" -f "$CHART/values-common.yaml" -f "$CHART/values-$s.yaml" >/dev/null 2>&1; then ok "$s: helm lint"; else bad "$s: helm lint"; fi
  out=$(helm template "boutique-$s" "$CHART" -f "$CHART/values-common.yaml" -f "$CHART/values-$s.yaml" 2>&1)
  rc=$?
  assert_eq "$s: helm template succeeds" 0 "$rc"
  if msg=$(printf '%s\n' "$out" | "$PY" "$CHECK" "$s" 2>&1); then ok "$s: render assertions"; else bad "$s: render assertions: $msg"; fi
done

echo "== scheduling.scaler is mandatory"
if helm template x "$CHART" -f "$CHART/values-common.yaml" >/dev/null 2>&1; then bad "template without a scaler file must fail"; else ok "template without scheduling.scaler fails"; fi

finish
