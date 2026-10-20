#!/usr/bin/env bash
# 03-benchmark-scaleup.sh preflight (design AC14): stub kubectl / aws output only, PREFLIGHT_ONLY=1 so nothing is scaled.
#  exit 5: the pool has nodes, or a pod other than inflate targets the pool (Boutique present), or the coexistence gate fails
#  exit 2: REPLICAS violates the capacity formula (or is out of range), or the Spot quota is too small
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib_sandbox.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_sandbox.sh"

make_sandbox
trap cleanup_sandbox EXIT

ENV_OK=("CLUSTER_NAME=finops-spot-demo" "EXPECTED_AWS_ACCOUNT_ID=${SYNTH_ACCOUNT}" "KUBE_CONTEXT=finops-spot-demo" "PREFLIGHT_ONLY=1")
rc_of() {
  local rc=0
  run_script 03-benchmark-scaleup.sh "$@" || rc=$?
  printf '%s' "$rc"
}
no_scale() { if grep -qE 'scale deployment' "$STUB_LOG"; then bad "$1: something was scaled"; else ok "$1: nothing was scaled"; fi; }

echo "== clean state passes"
assert_eq "empty pools, no Boutique, formula ok -> 0" 0 "$(rc_of "${ENV_OK[@]}" SCALERS=ca)"
no_scale "clean state"
assert_eq "all three scalers, gate unchanged -> 0" 0 "$(rc_of "${ENV_OK[@]}")"
printf '{"items":[{"metadata":{"name":"inflate-1","namespace":"scaletest-ca","labels":{"app.kubernetes.io/name":"inflate"}},"spec":{"nodeSelector":{"scaler":"ca"}}}]}' >"$SB/data/pods.json"
assert_eq "an inflate pod alone does not block the preflight -> 0" 0 "$(rc_of "${ENV_OK[@]}" SCALERS=ca)"
printf '{"items":[]}' >"$SB/data/pods.json"

echo "== pool has nodes -> 5"
printf '{"items":[{"metadata":{"name":"ip-10-60-1-1","creationTimestamp":"2000-01-01T00:00:00Z"}}]}' >"$SB/data/nodes.json"
assert_eq "pool with a node -> 5" 5 "$(rc_of "${ENV_OK[@]}" SCALERS=ca)"
no_scale "pool with a node"
printf '{"items":[]}' >"$SB/data/nodes.json"

echo "== Boutique pods present -> 5"
printf '{"items":[{"metadata":{"name":"frontend-1","namespace":"boutique-ca","labels":{"app.kubernetes.io/name":"frontend"}},"spec":{"nodeSelector":{"scaler":"ca"}}}]}' >"$SB/data/pods.json"
assert_eq "Boutique pod with nodeSelector scaler=ca -> 5" 5 "$(rc_of "${ENV_OK[@]}" SCALERS=ca)"
no_scale "Boutique present"
printf '{"items":[]}' >"$SB/data/pods.json"

echo "== capacity formula / ranges -> 2"
assert_eq "REPLICAS=5 (range 1-4) -> 2" 2 "$(rc_of "${ENV_OK[@]}" SCALERS=ca REPLICAS=5)"
assert_eq "REPLICAS=0 -> 2" 2 "$(rc_of "${ENV_OK[@]}" SCALERS=ca REPLICAS=0)"
assert_eq "REPLICAS=abc -> 2" 2 "$(rc_of "${ENV_OK[@]}" SCALERS=ca REPLICAS=abc)"
assert_eq "CA pool max 3 nodes with REPLICAS=4 -> 2" 2 "$(rc_of "${ENV_OK[@]}" SCALERS=ca REPLICAS=4 CA_MAX_SIZE=3)"
assert_eq "CA pool max 3 nodes with REPLICAS=3 -> 0" 0 "$(rc_of "${ENV_OK[@]}" SCALERS=ca REPLICAS=3 CA_MAX_SIZE=3)"
assert_eq "Spot quota 16 < 3 pools x 8 vCPU -> 2" 2 "$(rc_of "${ENV_OK[@]}" SCALERS=ca STUB_SPOT_QUOTA=16.0)"
assert_eq "SCALERS with an unknown name -> 2" 2 "$(rc_of "${ENV_OK[@]}" SCALERS=ca,gke)"
assert_eq "REPS=11 -> 2" 2 "$(rc_of "${ENV_OK[@]}" REPS=11)"
no_scale "formula violations"

echo "== coexistence gate (a): shared CRD changed since the platform phase -> 5"
printf '{"nodepools.karpenter.sh":"11","nodeclaims.karpenter.sh":"99"}' >"$SB/demo/.kube/crd-resourceversions-finops-spot-demo.json"
assert_eq "CRD resourceVersion drift -> 5" 5 "$(rc_of "${ENV_OK[@]}" SCALERS=karpenter,automode)"
rm -f "$SB/demo/.kube/crd-resourceversions-finops-spot-demo.json"
assert_eq "no recorded CRD versions (platform phase not run) -> 5" 5 "$(rc_of "${ENV_OK[@]}" SCALERS=karpenter,automode)"
no_scale "gate failures"

finish
