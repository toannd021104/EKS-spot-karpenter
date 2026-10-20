#!/usr/bin/env bash
# 06-down.sh: DESTROY the demo cluster and everything the autoscalers created (design 7.7).
# Order matters: Karpenter / Auto Mode create EC2 outside Terraform, so they are drained first.
# Required env: CLUSTER_NAME, EXPECTED_AWS_ACCOUNT_ID, KUBE_CONTEXT (= CLUSTER_NAME).
# Needs a terminal: two typed confirmations read /dev/tty (exit 4 otherwise; no env var or flag bypasses them).
# Optional: DRY_RUN=1. Exit codes: 0 ok, 2 guard, 4 declined / no tty, 5 leftovers or timeout (terraform destroy is
# NOT run blindly), 6 call failed.
set -euo pipefail
IFS=$'\n\t'
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

init_script 06-down 1 1
need_tool terraform

tf_vars=(-var "expected_aws_account_id=${EXPECTED_AWS_ACCOUNT_ID}")
warn "DESTROY: this removes the EKS cluster '$CLUSTER_NAME', its VPC/NAT and every node the autoscalers created."
confirm_by_typing "$CLUSTER_NAME"

list_instances() { # instances of this cluster that still exist and are not part of a managed node group
  local out="" f
  for f in "Name=tag:eks:eks-cluster-name,Values=${CLUSTER_NAME}" "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned"; do
    out+=$(aws ec2 describe-instances --region "$AWS_REGION" \
      --filters "$f" "Name=instance-state-name,Values=pending,running,stopping,stopped" --output json |
      jq -r '.Reservations[].Instances[] | select(([.Tags[]? | select(.Key == "eks:nodegroup-name")] | length) == 0) | .InstanceId')
    out+=$'\n'
  done
  sort -u <<<"$out" | sed '/^$/d'
}

cluster_exists=1
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  cluster_exists=0
  warn "Cluster $CLUSTER_NAME does not exist (already gone?): skipping steps 2-5, terraform destroy still runs."
fi

if ((cluster_exists)) && [[ -f "$DEMO_KUBECONFIG" ]]; then
  require_demo_cluster
  # (2) workloads and load balancers
  for s in "${ALL_SCALERS_ARR[@]}"; do
    run_mut hc uninstall "boutique-$s" --namespace "boutique-$s" --ignore-not-found || true
    run_mut kc scale deployment/inflate -n "scaletest-$s" --replicas=0 || true
  done
  lbs=$(kc get svc -A -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"')
  while IFS=' ' read -r lb_ns lb_name; do
    [[ -n "${lb_ns:-}" ]] || continue
    run_mut kc delete svc -n "$lb_ns" "$lb_name"
  done <<<"$lbs"

  # (3) delete NodePools and wait until the instances they created are gone
  run_mut kc delete nodepool karpenter automode --ignore-not-found --wait=false || true
  claims_empty() { [[ "$(kc get nodeclaims -o json | jq '.items | length')" == 0 ]]; }
  poll_until 900 10 "NodeClaims removed" claims_empty || {
    warn "NodeClaims still present after 15 min:"
    kc get nodeclaims >&2 || true
    die 5 "Not running terraform destroy while autoscaler nodes exist."
  }
  instances_gone() { [[ -z "$(list_instances)" ]]; }
  poll_until 900 15 "autoscaler EC2 instances terminated" instances_gone || {
    warn "Instances still alive: $(list_instances | tr '\n' ' ')"
    die 5 "Not running terraform destroy while autoscaler instances exist."
  }

  # (4) in-cluster controllers
  for rel in "karpenter kube-system" "cluster-autoscaler kube-system" "opencost opencost" "prometheus prometheus-system"; do
    IFS=' ' read -r name ns <<<"$rel"
    run_mut hc uninstall "$name" --namespace "$ns" --ignore-not-found || true
  done

  # (5) no load balancer or available ENI may keep the VPC alive
  vpc_id=$(tf_out vpc_id 2>/dev/null || true)
  lb_arns=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancers[].LoadBalancerArn' --output text | tr '\t' '\n')
  mine=""
  if [[ -n "$lb_arns" ]]; then
    mine=$(xargs -n 20 aws elbv2 describe-tags --region "$AWS_REGION" --output json --resource-arns <<<"$lb_arns" |
      jq -r --arg k "kubernetes.io/cluster/${CLUSTER_NAME}" --arg e "$CLUSTER_NAME" '
        .TagDescriptions[] | select(any(.Tags[]?; .Key == $k or (.Key == "elbv2.k8s.aws/cluster" and .Value == $e))) | .ResourceArn')
  fi
  [[ -z "$mine" ]] || die 5 "Load balancers still tagged for this cluster: $mine"
  if [[ -n "$vpc_id" ]]; then
    enis=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=status,Values=available" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
    [[ -z "$enis" ]] || die 5 "Detached ENIs remain in the VPC: $enis (wait a few minutes or delete them), then re-run."
  fi
fi

# (6) terraform destroy with its own typed confirmation
confirm_by_typing "$CLUSTER_NAME"
tf init -input=false 2>&1 | tee -a "$LOG_FILE" >/dev/null || die 6 "terraform init failed; see $LOG_FILE."
if ! run_mut tf destroy -input=false -auto-approve "${tf_vars[@]}" 2>&1 | tee -a "$LOG_FILE" | tail -n 20 >&2; then
  die 6 "terraform destroy failed: re-run 06-down.sh (idempotent). Do not delete state by hand."
fi

# (7) leftover scan: custom tag AND the AWS-managed cluster tag (still finds nodes if custom tags failed to propagate)
left=$(aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" --tag-filters "Key=Project,Values=finops-spot-demo" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)
left+=$'\n'
left+=$(aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" --tag-filters "Key=eks:eks-cluster-name,Values=${CLUSTER_NAME}" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)
left+=$'\n'
left+=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:eks:eks-cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
left=$(tr '\t' '\n' <<<"$left" | sed '/^$/d' | sort -u)
if [[ -n "$left" ]]; then
  warn "Leftover resources (check the console, they may still bill):"
  printf '%s\n' "$left" >&2
  die 5 "Leftovers found after destroy."
fi

# (8) local state
rm -f "$DEMO_KUBECONFIG" "$STATE_DIR/platform-done-$CLUSTER_NAME" "$(crd_state_file)"
info "Destroyed. No tagged leftovers found."
