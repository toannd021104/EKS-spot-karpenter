#!/usr/bin/env bash
# 02-deploy-apps.sh: install platform pieces and the Boutique releases on the demo cluster.
# Required env: CLUSTER_NAME, EXPECTED_AWS_ACCOUNT_ID, KUBE_CONTEXT (= CLUSTER_NAME), PHASE.
#   PHASE=platform   Cluster Autoscaler, Karpenter, NodePools/NodeClasses, Prometheus, OpenCost, inflate at 0 replicas.
#                    Leaves NO Boutique pod and all pools at 0 nodes (03 needs exactly that).
#   PHASE=apps       three Boutique releases + probe + isolation assertion (first cold scale-up happens here).
#   PHASE=apps-down  uninstall the Boutique releases and the probe so the pools drain to 0 again.
# Optional: SCALERS (default ca,karpenter,automode), DRY_RUN=1. Every step is idempotent: re-running is safe.
# Exit codes: 0 ok, 2 guard, 3 tool, 5 timeout / bad state / coexistence gate failed, 6 Helm or call failed.
set -euo pipefail
IFS=$'\n\t'
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PHASE=${PHASE:-}
case "$PHASE" in
  platform | apps | apps-down) ;;
  *) die 2 "PHASE=platform|apps|apps-down is required (no default)." ;;
esac

init_script 02-deploy-apps 1 0
validate_scalers
need_tool envsubst
require_demo_cluster

readonly CA_CHART_VERSION=9.59.0
readonly KARPENTER_CHART_VERSION=1.14.2
readonly OPENCOST_CHART_VERSION=2.5.33
readonly PROMETHEUS_CHART_VERSION=29.37.0
platform_marker="$STATE_DIR/platform-done-$CLUSTER_NAME"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# helm_release NAMESPACE ARGS...: on failure show the namespace events and exit 6
helm_release() {
  local ns=$1
  shift
  if ! run_mut hc upgrade --install "$@" --namespace "$ns" --create-namespace; then
    warn "Helm release failed in namespace $ns. Recent events:"
    kc get events -n "$ns" --sort-by=.lastTimestamp 2>&1 | tail -n 20 >&2 || true
    die 6 "Helm failed in $ns (nothing was rolled back; re-run is safe)."
  fi
}

# apply_rendered FILE: dry run first, then apply. A file that also creates its Namespace cannot be validated server-side
# (the namespace does not exist yet), so it gets a client-side dry run instead.
apply_rendered() {
  if grep -q '^kind: Namespace' "$1"; then
    kc apply --dry-run=client -f "$1" >/dev/null || die 6 "Client-side dry run failed for $1."
  else
    kc apply --dry-run=server -f "$1" >/dev/null || die 6 "Server-side dry run failed for $1."
  fi
  run_mut kc apply -f "$1"
}

render_to() { # render_to SRC DEST VAR...
  local src=$1 dest=$2
  shift 2
  render_tpl "$src" "$@" >"$dest"
}

nodes_ready_count() {
  kc get nodes -l role=system -o json |
    jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length'
}

platform_preflight() {
  local addon status n asg
  n=$(nodes_ready_count)
  ((n >= 2)) || die 5 "Fewer than 2 system nodes are Ready (found $n)."
  for addon in vpc-cni coredns kube-proxy eks-pod-identity-agent; do
    status=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon" --region "$AWS_REGION" \
      --query addon.status --output text) || die 6 "describe-addon $addon failed."
    [[ "$status" == ACTIVE ]] || die 5 "EKS add-on $addon is $status, not ACTIVE."
  done
  if has_scaler ca; then
    asg=$(tf_out ca_asg_name)
    aws autoscaling describe-tags --region "$AWS_REGION" \
      --filters "Name=tag-key,Values=k8s.io/cluster-autoscaler/${CLUSTER_NAME}" \
      --query 'Tags[].ResourceId' --output text | grep -qF -- "$asg" ||
      die 5 "Cluster Autoscaler discovery tag is missing on ASG $asg. Fix: aws_autoscaling_group_tag in Terraform, or pass --nodes explicitly."
  fi
  if has_scaler automode; then
    # Auto Mode owns the shared CRDs; they must exist before Karpenter is installed.
    kc get crd nodepools.karpenter.sh nodeclaims.karpenter.sh >/dev/null ||
      die 5 "Shared CRDs nodepools/nodeclaims.karpenter.sh are absent: Auto Mode must be enabled before the Karpenter install."
  fi
}

platform() {
  local before after queue karp_role am_role
  platform_preflight
  export CLUSTER_NAME AWS_REGION

  if has_scaler karpenter && has_scaler automode; then before=$(crd_versions); fi

  if has_scaler ca; then
    info "Cluster Autoscaler $CA_CHART_VERSION"
    render_to "$K8S_DIR/cluster-autoscaler/values.yaml.tpl" "$tmp_dir/ca-values.yaml" CLUSTER_NAME AWS_REGION
    helm_release kube-system cluster-autoscaler cluster-autoscaler \
      --repo https://kubernetes.github.io/autoscaler --version "$CA_CHART_VERSION" \
      -f "$tmp_dir/ca-values.yaml" --wait --timeout 10m
  fi

  if has_scaler karpenter; then
    info "Karpenter $KARPENTER_CHART_VERSION (no --force, no --replace, no CRD overrides)"
    queue=$(tf_out karpenter_queue_name)
    helm_release kube-system karpenter oci://public.ecr.aws/karpenter/karpenter \
      --version "$KARPENTER_CHART_VERSION" -f "$K8S_DIR/karpenter/values.yaml" \
      --set "settings.clusterName=$CLUSTER_NAME" --set "settings.interruptionQueue=$queue" \
      --set "controller.env[0].name=AWS_REGION" --set "controller.env[0].value=$AWS_REGION" \
      --wait --timeout 10m
  fi

  if has_scaler karpenter && has_scaler automode; then
    after=$(crd_versions)
    if [[ "$before" != "$after" ]]; then
      warn "Gate (a) failed: shared CRDs changed during the Karpenter install."
      two_cluster_fallback_hint
      exit 5
    fi
    mkdir -p "$STATE_DIR"
    if ! is_dry; then printf '%s' "$after" >"$(crd_state_file)"; fi
  fi

  if has_scaler karpenter; then
    karp_role=$(tf_out karpenter_node_role_name)
    export KARPENTER_NODE_ROLE="$karp_role"
    render_to "$K8S_DIR/karpenter/ec2nodeclass.yaml.tpl" "$tmp_dir/ec2nodeclass.yaml" CLUSTER_NAME KARPENTER_NODE_ROLE
    render_to "$K8S_DIR/karpenter/nodepool.yaml.tpl" "$tmp_dir/nodepool-karpenter.yaml" CLUSTER_NAME
    apply_rendered "$tmp_dir/ec2nodeclass.yaml"
    apply_rendered "$tmp_dir/nodepool-karpenter.yaml"
  fi
  if has_scaler automode; then
    am_role=$(tf_out automode_node_role_name)
    export AUTOMODE_NODE_ROLE="$am_role"
    render_to "$K8S_DIR/automode/nodeclass.yaml.tpl" "$tmp_dir/nodeclass-automode.yaml" CLUSTER_NAME AUTOMODE_NODE_ROLE
    render_to "$K8S_DIR/automode/nodepool.yaml.tpl" "$tmp_dir/nodepool-automode.yaml" CLUSTER_NAME
    apply_rendered "$tmp_dir/nodeclass-automode.yaml"
    apply_rendered "$tmp_dir/nodepool-automode.yaml"
  fi

  gate_ok() { gate_coexistence "${SCALERS_ARR[@]}"; }
  if ! poll_until 300 5 "NodePools/NodeClass Ready (gate b)" gate_ok; then
    two_cluster_fallback_hint
    exit 5
  fi

  info "Prometheus $PROMETHEUS_CHART_VERSION + OpenCost $OPENCOST_CHART_VERSION"
  helm_release prometheus-system prometheus prometheus \
    --repo https://prometheus-community.github.io/helm-charts --version "$PROMETHEUS_CHART_VERSION" \
    -f "$OPENCOST_DIR/prometheus-values.yaml" -f "$OPENCOST_DIR/extraScrapeConfigs.yaml" --wait --timeout 10m
  helm_release opencost opencost opencost \
    --repo https://opencost.github.io/opencost-helm-chart --version "$OPENCOST_CHART_VERSION" \
    -f "$OPENCOST_DIR/opencost-values.yaml" --wait --timeout 10m

  local s
  for s in "${SCALERS_ARR[@]}"; do
    SCALER="$s" render_tpl "$K8S_DIR/benchmark/scaletest/inflate.yaml.tpl" SCALER >"$tmp_dir/inflate-$s.yaml"
    apply_rendered "$tmp_dir/inflate-$s.yaml"
  done

  if ! is_dry; then : >"$platform_marker"; fi
  print_cost_warning
  info "Platform ready. No Boutique pod exists and all pools are at 0 nodes: run 03-benchmark-scaleup.sh next, then PHASE=apps."
}

assert_isolation() { # every pod must land on its own scaler pool
  local bad
  bad=$(kc get pods -A -o json | jq -r '
    .items[] | select(.metadata.namespace | test("^(boutique|scaletest)-"))
    | select((.spec.nodeSelector.scaler // "") == "") | "\(.metadata.namespace)/\(.metadata.name)"')
  [[ -z "$bad" ]] || die 5 "Pods without a scaler nodeSelector: $bad"
  bad=$(kc get nodes -o json | jq -r '
    .items[] | select((.metadata.labels.scaler // "") == "" and (.metadata.labels.role // "") == "") | .metadata.name')
  [[ -z "$bad" ]] || die 5 "Nodes with neither scaler nor role label: $bad"
}

apps() {
  local s
  [[ -f "$platform_marker" ]] || is_dry || die 5 "Platform phase has not completed: run PHASE=platform first."
  for s in "${SCALERS_ARR[@]}"; do
    info "Boutique release boutique-$s (cold scale-up of pool $s happens now)"
    helm_release "boutique-$s" "boutique-$s" "$K8S_DIR/boutique" \
      -f "$K8S_DIR/boutique/values-common.yaml" -f "$K8S_DIR/boutique/values-$s.yaml" --wait --timeout 10m
    run_mut kc label namespace "boutique-$s" "finops.demo/scaler=$s" --overwrite
  done
  apply_rendered "$K8S_DIR/benchmark/probe/probe.yaml.tpl"
  if ! is_dry; then assert_isolation; fi
  print_cost_warning
  info "Apps ready. Let them run for the cost window (30-60 min) before 04-cost-report.sh; chaos: 05-chaos-node-down.sh."
}

apps_down() {
  local s
  for s in "${SCALERS_ARR[@]}"; do
    run_mut hc uninstall "boutique-$s" --namespace "boutique-$s" --ignore-not-found
  done
  run_mut kc delete -f "$K8S_DIR/benchmark/probe/probe.yaml.tpl" --ignore-not-found
  info "Boutique and probe removed; the pools drain to 0 nodes within a few minutes. Then 03 can be re-run."
}

case "$PHASE" in
  platform) platform ;;
  apps) apps ;;
  apps-down) apps_down ;;
  *) die 2 "Unknown PHASE" ;;
esac
