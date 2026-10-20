#!/usr/bin/env bash
# Guard tests (design AC9): stub binaries only, no AWS, no cluster, no real account id.
#  - unset/invalid env exits 2 BEFORE any aws / kubectl / helm / terraform call
#  - the unrelated frt-outbound-proxy ARN (synthetic account 000000000002) is refused
#  - 01 and 06 exit 4 on a non-tty stdin before any terraform apply / destroy
#  - require_demo_cluster allow-list / deny-list / kubeconfig mode / tags / endpoint
# shellcheck disable=SC2016 # the bash -c driver strings are meant to be literal
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib_sandbox.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_sandbox.sh"

make_sandbox
trap cleanup_sandbox EXIT

ENV_OK=("CLUSTER_NAME=finops-spot-demo" "EXPECTED_AWS_ACCOUNT_ID=${SYNTH_ACCOUNT}" "KUBE_CONTEXT=finops-spot-demo")
SYNTH_ARN="arn:aws:eks:ap-southeast-2:${SYNTH_OTHER_ACCOUNT}:cluster/frt-outbound-proxy"
SCRIPTS=(01-up.sh 02-deploy-apps.sh 03-benchmark-scaleup.sh 04-cost-report.sh 05-chaos-node-down.sh 06-down.sh)

calls() { wc -l <"$STUB_LOG" | tr -d ' '; }
rc_of() { # rc_of NAME ENV... -> exit status of run_script
  local rc=0
  run_script "$@" || rc=$?
  printf '%s' "$rc"
}

echo "== env validation exits 2 before any tool call"
for s in "${SCRIPTS[@]}"; do
  assert_eq "$s without any env -> 2" 2 "$(rc_of "$s")"
  assert_eq "$s without any env -> no tool called" 0 "$(calls)"
  assert_eq "$s without EXPECTED_AWS_ACCOUNT_ID -> 2" 2 "$(rc_of "$s" CLUSTER_NAME=finops-spot-demo KUBE_CONTEXT=finops-spot-demo PHASE=platform)"
  assert_eq "$s without CLUSTER_NAME -> 2" 2 "$(rc_of "$s" EXPECTED_AWS_ACCOUNT_ID="$SYNTH_ACCOUNT" KUBE_CONTEXT=finops-spot-demo PHASE=platform)"
  assert_eq "$s with a foreign cluster name -> 2" 2 "$(rc_of "$s" CLUSTER_NAME=boutique-dev-eks EXPECTED_AWS_ACCOUNT_ID="$SYNTH_ACCOUNT" KUBE_CONTEXT=boutique-dev-eks PHASE=platform)"
  assert_eq "$s with a malformed account id -> 2" 2 "$(rc_of "$s" CLUSTER_NAME=finops-spot-demo EXPECTED_AWS_ACCOUNT_ID=12345 KUBE_CONTEXT=finops-spot-demo PHASE=platform)"
  assert_eq "$s malformed input -> no tool called" 0 "$(calls)"
done
for s in "${SCRIPTS[@]:1}"; do
  assert_eq "$s without KUBE_CONTEXT -> 2" 2 "$(rc_of "$s" CLUSTER_NAME=finops-spot-demo EXPECTED_AWS_ACCOUNT_ID="$SYNTH_ACCOUNT" PHASE=platform)"
  assert_eq "$s without KUBE_CONTEXT -> no tool called" 0 "$(calls)"
  assert_eq "$s with the synthetic frt-outbound-proxy ARN as context -> 2" 2 \
    "$(rc_of "$s" CLUSTER_NAME=finops-spot-demo EXPECTED_AWS_ACCOUNT_ID="$SYNTH_ACCOUNT" "KUBE_CONTEXT=$SYNTH_ARN" PHASE=platform)"
  assert_eq "$s with the synthetic ARN -> no tool called" 0 "$(calls)"
  assert_eq "$s with context boutique-dev-eks -> 2" 2 \
    "$(rc_of "$s" CLUSTER_NAME=finops-spot-demo EXPECTED_AWS_ACCOUNT_ID="$SYNTH_ACCOUNT" KUBE_CONTEXT=boutique-dev-eks PHASE=platform)"
  assert_eq "$s with a mismatching context -> 2" 2 \
    "$(rc_of "$s" CLUSTER_NAME=finops-spot-demo EXPECTED_AWS_ACCOUNT_ID="$SYNTH_ACCOUNT" KUBE_CONTEXT=finops-spot-demo-other PHASE=platform)"
done
assert_eq "02 without PHASE -> 2" 2 "$(rc_of 02-deploy-apps.sh "${ENV_OK[@]}")"
assert_eq "02 without PHASE -> no tool called" 0 "$(calls)"
assert_eq "02 with PHASE=bogus -> 2" 2 "$(rc_of 02-deploy-apps.sh "${ENV_OK[@]}" PHASE=bogus)"

echo "== DENY_CONTEXT_REGEX can only ADD patterns"
assert_eq "extra deny pattern refuses an otherwise valid context" 2 \
  "$(rc_of 02-deploy-apps.sh "${ENV_OK[@]}" PHASE=platform DENY_CONTEXT_REGEX=finops)"
assert_eq "extra deny pattern -> no tool called" 0 "$(calls)"

echo "== 01 and 06 exit 4 on a non-tty stdin, before any terraform apply/destroy"
for s in 01-up.sh 06-down.sh; do
  assert_eq "$s non-tty -> 4" 4 "$(rc_of "$s" "${ENV_OK[@]}")"
  assert_eq "$s non-tty -> no tool called" 0 "$(calls)"
  assert_eq "$s non-tty with CONFIRM/YES/FORCE env -> 4" 4 "$(rc_of "$s" "${ENV_OK[@]}" CONFIRM=finops-spot-demo YES=1 FORCE=1 ASSUME_YES=1 DRY_RUN=1)"
  if grep -qE 'terraform (apply|destroy)' "$STUB_LOG"; then bad "$s ran terraform apply/destroy"; else ok "$s never reached terraform apply/destroy"; fi
done

echo "== account / tool version checks (after env validation)"
assert_eq "02 with credentials of another account -> 2" 2 "$(rc_of 02-deploy-apps.sh "${ENV_OK[@]}" PHASE=platform STUB_ACCOUNT="$SYNTH_OTHER_ACCOUNT")"
if grep -qE '^(kubectl|helm|terraform) ' "$STUB_LOG"; then bad "wrong account: a kube/helm/terraform call happened"; else ok "wrong account: only aws sts was called"; fi
assert_eq "02 with kubectl 1.31 -> 3" 3 "$(rc_of 02-deploy-apps.sh "${ENV_OK[@]}" PHASE=platform STUB_KUBECTL_MINOR=31)"

echo "== require_demo_cluster (sourced, stubs only)"
guard_rc() { # guard_rc ENV... : sources common.sh and calls require_demo_cluster, then kc
  local rc=0
  : >"$STUB_LOG"
  env -i "PATH=$SB/stub:$SB/tools" "HOME=$SB" "STUB_LOG=$STUB_LOG" "STUB_DATA=$SB/data" \
    "CLUSTER_NAME=finops-spot-demo" "EXPECTED_AWS_ACCOUNT_ID=${SYNTH_ACCOUNT}" "KUBE_CONTEXT=finops-spot-demo" "$@" \
    "$SB/tools/bash" -c 'source "$1"; validate_env 1; require_demo_cluster; kc get nodes >/dev/null' _ "$SB/demo/scripts/lib/common.sh" \
    >"$SB/out.txt" 2>&1 || rc=$?
  printf '%s' "$rc"
}
assert_eq "valid demo cluster passes" 0 "$(guard_rc)"
if grep -q -- "--kubeconfig $SB/demo/.kube/config --context finops-spot-demo get nodes" "$STUB_LOG"; then ok "kc passes explicit --kubeconfig and --context"; else bad "kc did not pass --kubeconfig/--context"; fi

write_kubeconfig_json "$SYNTH_ARN" finops-spot-demo
assert_eq "context pointing at the synthetic frt-outbound-proxy ARN -> 2" 2 "$(guard_rc)"
write_kubeconfig_json "arn:aws:eks:ap-southeast-1:${SYNTH_OTHER_ACCOUNT}:cluster/finops-spot-demo" finops-spot-demo
assert_eq "right cluster name, other account -> 2" 2 "$(guard_rc)"
write_kubeconfig_json "arn:aws:eks:ap-southeast-1:${SYNTH_ACCOUNT}:cluster/finops-spot-demo" finops-spot-demo
assert_eq "restored valid kubeconfig passes again" 0 "$(guard_rc)"
chmod 644 "$SB/demo/.kube/config"
assert_eq "kubeconfig mode 644 -> 2" 2 "$(guard_rc)"
chmod 600 "$SB/demo/.kube/config"
assert_eq "cluster without the Project tag -> 2" 2 "$(guard_rc STUB_PROJECT_TAG=other)"
assert_eq "endpoint differs from kubeconfig server -> 2" 2 "$(guard_rc STUB_ENDPOINT=https://elsewhere.example)"
mv "$SB/demo/.kube/config" "$SB/demo/.kube/config.bak"
assert_eq "missing demo kubeconfig -> 2" 2 "$(guard_rc)"
mv "$SB/demo/.kube/config.bak" "$SB/demo/.kube/config"

rc=0
: >"$STUB_LOG"
env -i "PATH=$SB/stub:$SB/tools" "HOME=$SB" "STUB_LOG=$STUB_LOG" "STUB_DATA=$SB/data" "CLUSTER_NAME=finops-spot-demo" \
  "EXPECTED_AWS_ACCOUNT_ID=${SYNTH_ACCOUNT}" "KUBE_CONTEXT=finops-spot-demo" \
  "$SB/tools/bash" -c 'source "$1"; kc get nodes' _ "$SB/demo/scripts/lib/common.sh" >"$SB/out.txt" 2>&1 || rc=$?
assert_eq "kc before require_demo_cluster is refused (2)" 2 "$rc"
assert_eq "kc before the guard did not call kubectl" 0 "$(calls)"

out=$(env -i "PATH=$SB/stub:$SB/tools" "KUBECONFIG=$HOME/.kube/config" "$SB/tools/bash" -c 'source "$1"; printf "%s" "$KUBECONFIG"' _ "$SB/demo/scripts/lib/common.sh" 2>/dev/null)
assert_eq "common.sh forces KUBECONFIG=/dev/null" "/dev/null" "$out"

finish
