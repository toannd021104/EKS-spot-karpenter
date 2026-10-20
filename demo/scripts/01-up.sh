#!/usr/bin/env bash
# 01-up.sh: create the demo VPC + EKS cluster with Terraform (BILLABLE, about $0.38/h idle).
# Required env: CLUSTER_NAME, EXPECTED_AWS_ACCOUNT_ID. Optional: AWS_REGION (default ap-southeast-1), DRY_RUN=1.
# Needs a terminal: the typed confirmation reads /dev/tty and cannot be bypassed (exit 4 otherwise).
# Exit codes: 0 ok, 2 guard, 3 tool/version, 4 declined / no tty, 6 AWS or Terraform failure.
set -euo pipefail
IFS=$'\n\t'
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

init_script 01-up 0 1
need_tool terraform

# ---- preflight (read-only AWS calls only)
[[ -f "$TF_DIR/terraform.tfvars" ]] || die 2 "Missing $TF_DIR/terraform.tfvars (copy terraform.tfvars.example and edit)."

k8s_version=$(tfvar_get kubernetes_version 1.35)
support=$(aws eks describe-cluster-versions --cluster-versions "$k8s_version" --region "$AWS_REGION" \
  --query 'clusterVersions[0].status' --output text) || die 6 "aws eks describe-cluster-versions failed."
[[ "$support" == STANDARD_SUPPORT ]] || die 3 "Kubernetes $k8s_version is not in standard support (status: $support); extended support costs extra."

# Quotas are limits, not free headroom: subtract what the account already runs (the existing boutique-dev-eks
# cluster may live in the same account and region).
spot_quota=$(get_spot_quota)
in_use=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].[InstanceLifecycle,CpuOptions.CoreCount,CpuOptions.ThreadsPerCore]' --output text) ||
  die 6 "aws ec2 describe-instances failed."
spot_used=0
od_used=0
while IFS=$'\t' read -r lifecycle cores threads; do
  [[ -n "${cores:-}" ]] || continue
  vcpu=$((cores * threads))
  if [[ "$lifecycle" == spot ]]; then spot_used=$((spot_used + vcpu)); else od_used=$((od_used + vcpu)); fi
done <<<"$in_use"
od_quota=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query Quota.Value --output text --region "$AWS_REGION") || die 6 "service-quotas call failed."
od_quota=${od_quota%.*}
system_vcpu=$(($(tfvar_get system_desired_size 2) * 2))
spot_need=$((3 * POOL_VCPU_LIMIT))
info "Quotas: Spot $spot_quota (in use $spot_used, need up to $spot_need); On-Demand $od_quota (in use $od_used, system nodes need $system_vcpu)."
((spot_quota - spot_used >= spot_need)) || die 2 "Not enough free Spot vCPU quota (need $spot_need). Reduce enabled_scalers or free quota."
((od_quota - od_used >= system_vcpu)) || die 2 "Not enough free On-Demand vCPU quota for the system nodes."

tf fmt -check -recursive >/dev/null || die 2 "terraform fmt -check failed: run terraform fmt."

# ---- plan
tf_vars=(-var "expected_aws_account_id=${EXPECTED_AWS_ACCOUNT_ID}")
info "terraform init / plan (nothing is created yet)"
tf init -input=false 2>&1 | tee -a "$LOG_FILE" >/dev/null || die 6 "terraform init failed; see $LOG_FILE."
tf plan -input=false -out=tfplan "${tf_vars[@]}" 2>&1 | tee -a "$LOG_FILE" | tail -n 20 >&2 ||
  die 6 "terraform plan failed (last lines above); nothing was created."
tf show -no-color tfplan | grep -E '^Plan:' >&2 || true

print_cost_warning
warn "Expected time: about 15 min. Everything created is tagged Project=finops-spot-demo."
confirm_by_typing "$CLUSTER_NAME"

# ---- apply (plan file = exactly what was shown)
if ! run_mut tf apply -input=false tfplan 2>&1 | tee -a "$LOG_FILE" | tail -n 20 >&2; then
  die 6 "terraform apply failed. State is intact: re-run 01-up.sh (idempotent) or destroy with 06-down.sh. Never delete state by hand."
fi

# ---- demo-only kubeconfig (never the default one); only this local file is written
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
run_mut aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --kubeconfig "$DEMO_KUBECONFIG" --alias "$CLUSTER_NAME" >&2 || die 6 "aws eks update-kubeconfig failed."
if ! is_dry; then chmod 600 "$DEMO_KUBECONFIG"; fi

KUBE_CONTEXT="$CLUSTER_NAME"
export KUBE_CONTEXT
if ! is_dry; then
  require_demo_cluster
  system_wanted=$(tfvar_get system_desired_size 2)
  system_ready() {
    local n
    n=$(kc get nodes -l role=system -o json |
      jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
    ((n >= system_wanted))
  }
  poll_until 900 10 "system nodes Ready" system_ready || die 5 "System nodes not Ready after 15 min."
fi

print_cost_warning
info "Done. Next: 02-deploy-apps.sh with PHASE=platform (KUBE_CONTEXT=$CLUSTER_NAME). Destroy with 06-down.sh when finished."
