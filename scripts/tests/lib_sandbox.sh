#!/usr/bin/env bash
# Shared test helper: builds a throw-away copy of scripts/ under a temp dir and puts STUB aws / kubectl / helm /
# terraform on PATH. The PATH contains ONLY the stub dir and a dir of symlinks to harmless utilities, so a missing stub
# fails the test instead of falling through to a real binary. Nothing here talks to AWS or a cluster.
# shellcheck shell=bash
# shellcheck disable=SC2034 # SYNTH_OTHER_ACCOUNT and SB are used by the sourcing tests

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REAL_SCRIPTS_DIR=$(dirname "$TESTS_DIR")
REAL_REPO_ROOT=$(dirname "$REAL_SCRIPTS_DIR")

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1" >&2
}
assert_eq() { # assert_eq DESCRIPTION EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

SYNTH_ACCOUNT=000000000001
SYNTH_OTHER_ACCOUNT=000000000002

make_sandbox() {
  SB=$(mktemp -d)
  mkdir -p "$SB/scripts/lib" "$SB/results/templates" "$SB/.kube" "$SB/terraform" \
    "$SB/stub" "$SB/tools" "$SB/data"
  cp "$REAL_SCRIPTS_DIR"/lib/common.sh "$SB/scripts/lib/"
  cp "$REAL_SCRIPTS_DIR"/0*.sh "$SB/scripts/"
  cp "$REAL_REPO_ROOT"/results/pricing-snapshot-ap-southeast-1.json "$SB/results/"
  cp "$REAL_REPO_ROOT"/results/templates/*.csv "$SB/results/templates/"
  local t p
  for t in bash env dirname basename cat date jq sed grep awk tee sort head tail tr wc realpath mkdir chmod stat \
    sleep cut rm mktemp touch uniq cp seq xargs envsubst readlink ls; do
    p=$(command -v "$t") || {
      echo "test setup: missing utility $t" >&2
      exit 1
    }
    ln -s "$p" "$SB/tools/$t"
  done
  write_stubs
  STUB_LOG="$SB/calls.log"
  : >"$STUB_LOG"
  write_kubeconfig_json "arn:aws:eks:ap-southeast-1:${SYNTH_ACCOUNT}:cluster/finops-spot-demo" finops-spot-demo
  printf '{"items":[]}' >"$SB/data/nodes.json"
  printf '{"items":[]}' >"$SB/data/pods.json"
  printf '{"items":[{"metadata":{"name":"nodepools.karpenter.sh","resourceVersion":"11"}},{"metadata":{"name":"nodeclaims.karpenter.sh","resourceVersion":"12"}}]}' >"$SB/data/crd.json"
  printf '{"nodepools.karpenter.sh":"11","nodeclaims.karpenter.sh":"12"}' >"$SB/.kube/crd-resourceversions-finops-spot-demo.json"
  printf 'apiVersion: v1\nkind: Config\n' >"$SB/.kube/config"
  chmod 600 "$SB/.kube/config"
}

write_kubeconfig_json() { # write_kubeconfig_json CLUSTER_ARN CONTEXT_NAME
  jq -n --arg arn "$1" --arg ctx "$2" '{
    contexts: [{name: $ctx, context: {cluster: $arn}}],
    clusters: [{name: $arn, cluster: {server: "https://stub.example"}}]}' >"$SB/data/kubeconfig.json"
}

write_stubs() {
  cat >"$SB/stub/aws" <<'EOF'
#!/bin/bash
echo "aws $*" >> "$STUB_LOG"
args="$*"
case "$args" in
  *"sts get-caller-identity"*) echo "${STUB_ACCOUNT:-000000000001}" ;;
  *"service-quotas get-service-quota"*) echo "${STUB_SPOT_QUOTA:-32.0}" ;;
  *"eks describe-cluster-versions"*) echo "STANDARD_SUPPORT" ;;
  *"eks describe-cluster "*) printf '%s\t%s\n' "${STUB_ENDPOINT:-https://stub.example}" "${STUB_PROJECT_TAG:-finops-spot-demo}" ;;
  *"ec2 describe-instances"*) printf '%b' "${STUB_INSTANCES:-}" ;;
  *) : ;;
esac
EOF
  cat >"$SB/stub/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >> "$STUB_LOG"
args="$*"
case "$args" in
  *"version --client"*) echo "{\"clientVersion\":{\"major\":\"1\",\"minor\":\"${STUB_KUBECTL_MINOR:-34}\"}}" ;;
  *"config view"*) cat "$STUB_DATA/kubeconfig.json" ;;
  *"get crd"*) cat "$STUB_DATA/crd.json" ;;
  *"get nodepool"*|*"get nodeclasses"*) echo '{"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
  *"get nodes"*) cat "$STUB_DATA/nodes.json" ;;
  *"get pods"*) cat "$STUB_DATA/pods.json" ;;
  *) : ;;
esac
EOF
  cat >"$SB/stub/helm" <<'EOF'
#!/bin/bash
echo "helm $*" >> "$STUB_LOG"
EOF
  cat >"$SB/stub/terraform" <<'EOF'
#!/bin/bash
echo "terraform $*" >> "$STUB_LOG"
case "$*" in
  *"output -raw cluster_name"*) echo "finops-spot-demo" ;;
esac
EOF
  chmod +x "$SB"/stub/*
}

# run_script NAME [VAR=VALUE...]: runs a copied script with a clean environment and ONLY the stub PATH, stdin closed.
# Output goes to $SB/out.txt; the exit status is returned.
run_script() {
  local name=$1
  shift
  : >"$STUB_LOG"
  env -i "PATH=$SB/stub:$SB/tools" "HOME=$SB" "STUB_LOG=$STUB_LOG" "STUB_DATA=$SB/data" "$@" \
    "$SB/tools/bash" "$SB/scripts/$name" </dev/null >"$SB/out.txt" 2>&1
}

cleanup_sandbox() { [[ -n "${SB:-}" && -d "$SB" ]] && rm -rf "$SB"; }

finish() {
  printf '%s passed, %s failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
