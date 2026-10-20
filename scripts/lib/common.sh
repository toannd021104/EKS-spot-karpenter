#!/usr/bin/env bash
# lib/common.sh: sourced by 01..06. The single choke point for every safety rule.
#   - the only file allowed to contain a literal kubectl / helm invocation (lint.sh enforces this);
#   - never reads the ambient kubeconfig; only $REPO_ROOT/.kube/config (created by 01-up.sh);
#   - refuses any cluster/account that is not the demo one (allow-list) or that matches DENY_CONTEXT_REGEX.
# Exit codes: 0 ok, 2 guard refused, 3 missing tool/version, 4 user declined / no tty, 5 timeout or bad state,
# 6 AWS/Kubernetes call failed.
# shellcheck shell=bash
# shellcheck disable=SC2034 # globals below are consumed by the scripts that source this file

set -euo pipefail
set -o errtrace
IFS=$'\n\t'

# A stray kubectl/helm must never fall back to the default kubeconfig (rev2 #5).
unset KUBECONFIG
export KUBECONFIG=/dev/null
export AWS_PAGER=""

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS_DIR=$(dirname "$LIB_DIR")
REPO_ROOT=$(dirname "$SCRIPTS_DIR")
RESULTS_DIR="$REPO_ROOT/results"
TF_DIR="$REPO_ROOT/terraform"
K8S_DIR="$REPO_ROOT/kubernetes"
OPENCOST_DIR="$K8S_DIR/opencost"
STATE_DIR="$REPO_ROOT/.kube"
DEMO_KUBECONFIG="$STATE_DIR/config"
PRICING_FILE="$RESULTS_DIR/pricing-snapshot-ap-southeast-1.json"
LOG_DIR="$RESULTS_DIR/logs"

# Name-only deny list (second, independent safety net). The env var can only ADD patterns:
# whatever is exported in DENY_CONTEXT_REGEX is appended to the built-in default.
_DENY_DEFAULT='boutique-dev-eks|frt-outbound-proxy'
DENY_CONTEXT_REGEX="${_DENY_DEFAULT}${DENY_CONTEXT_REGEX:+|${DENY_CONTEXT_REGEX}}"

readonly CLUSTER_NAME_REGEX='^finops-spot-demo(-[a-z0-9-]{1,20})?$'
readonly POOL_VCPU_LIMIT=8
readonly ALL_SCALERS="ca karpenter automode"
readonly -a ALL_SCALERS_ARR=(ca karpenter automode)
SCRIPT_NAME=${SCRIPT_NAME:-common}
LOG_FILE=""
_DEMO_GUARD_OK=0

# ---------------------------------------------------------------- logging
log() {
  local lvl=$1
  shift
  local line
  line="[$lvl] $(date -u +%H:%M:%S) $*"
  printf '%s\n' "$line" >&2
  if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$line" >>"$LOG_FILE"; fi
  return 0
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
die() {
  local code=$1
  shift
  log ERROR "$*"
  exit "$code"
}
_on_err() {
  log ERROR "${SCRIPT_NAME}: command failed (status $1) at line $2"
}
trap '_on_err "$?" "$LINENO"' ERR

setup_logging() {
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/${SCRIPT_NAME}-$(date -u +%Y%m%dT%H%M%SZ).log"
  : >"$LOG_FILE"
}

# ---------------------------------------------------------------- input validation (pure bash, no tool call)
validate_env() {
  local need_ctx=${1:-0} v
  [[ -n "${CLUSTER_NAME:-}" ]] || die 2 "CLUSTER_NAME is required (no default)."
  [[ "$CLUSTER_NAME" =~ $CLUSTER_NAME_REGEX ]] || die 2 "CLUSTER_NAME does not match $CLUSTER_NAME_REGEX."
  [[ -n "${EXPECTED_AWS_ACCOUNT_ID:-}" ]] || die 2 "EXPECTED_AWS_ACCOUNT_ID is required (no default)."
  [[ "$EXPECTED_AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die 2 "EXPECTED_AWS_ACCOUNT_ID must be 12 digits."
  AWS_REGION=${AWS_REGION:-ap-southeast-1}
  [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || die 2 "AWS_REGION is malformed."
  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
  export CLUSTER_NAME EXPECTED_AWS_ACCOUNT_ID
  if [[ "$need_ctx" == 1 ]]; then
    [[ -n "${KUBE_CONTEXT:-}" ]] || die 2 "KUBE_CONTEXT is required for this script and must equal CLUSTER_NAME."
    for v in "$KUBE_CONTEXT" "$CLUSTER_NAME"; do
      if [[ "$v" =~ $DENY_CONTEXT_REGEX ]]; then die 2 "Refusing: name matches the deny list."; fi
    done
    [[ "$KUBE_CONTEXT" == "$CLUSTER_NAME" ]] || die 2 "KUBE_CONTEXT must equal CLUSTER_NAME."
    export KUBE_CONTEXT
  fi
}

validate_int() { # validate_int NAME MIN MAX DEFAULT
  local name=$1 min=$2 max=$3 def=$4 val
  val=${!name:-$def}
  [[ "$val" =~ ^[0-9]+$ ]] || die 2 "$name must be an integer, got '$val'."
  ((val >= min && val <= max)) || die 2 "$name must be between $min and $max, got $val."
  printf -v "$name" '%s' "$val"
  export "${name?}"
}

SCALERS_ARR=()
validate_scalers() {
  local s
  SCALERS=${SCALERS:-ca,karpenter,automode}
  IFS=, read -r -a SCALERS_ARR <<<"$SCALERS"
  [[ ${#SCALERS_ARR[@]} -gt 0 ]] || die 2 "SCALERS is empty."
  for s in "${SCALERS_ARR[@]}"; do
    [[ " $ALL_SCALERS " == *" $s "* ]] || die 2 "SCALERS contains '$s'; allowed: ca,karpenter,automode."
  done
}

has_scaler() { # has_scaler NAME: true when NAME is in SCALERS_ARR
  local x
  for x in "${SCALERS_ARR[@]}"; do
    if [[ "$x" == "$1" ]]; then return 0; fi
  done
  return 1
}

validate_mode() {
  MODE=${MODE:-terminate}
  case "$MODE" in terminate | fis | drain) ;; *) die 2 "MODE must be terminate|fis|drain." ;; esac
}

validate_window() {
  WINDOW=${WINDOW:-60m}
  [[ "$WINDOW" =~ ^[0-9]+(m|h|d)$ ]] || die 2 "WINDOW must match ^[0-9]+(m|h|d)\$ (e.g. 60m)."
}

window_hours() { # prints the window length in hours (decimal) for WINDOW
  local n=${WINDOW%[mhd]} u=${WINDOW: -1}
  case "$u" in
    m) awk -v n="$n" 'BEGIN{printf "%.6f", n/60}' ;;
    h) awk -v n="$n" 'BEGIN{printf "%.6f", n}' ;;
    d) awk -v n="$n" 'BEGIN{printf "%.6f", n*24}' ;;
  esac
}

validate_out_dir() {
  local resolved root
  OUT_DIR=${OUT_DIR:-$RESULTS_DIR}
  resolved=$(realpath -m "$OUT_DIR")
  root=$(realpath -m "$RESULTS_DIR")
  [[ "$resolved" == "$root" || "$resolved" == "$root"/* ]] || die 2 "OUT_DIR must be inside $RESULTS_DIR."
  OUT_DIR=$resolved
}

# Capacity formula: REPLICAS x 1 vCPU + steady_pool_vcpu <= pool_limit; steady is asserted 0 by the
# preflight (no node, no Boutique pod). CA additionally needs REPLICAS <= ca_max_size.
check_capacity_formula() { # check_capacity_formula SCALER
  local scaler=$1 steady=0 ca_max
  ((REPLICAS * 1 + steady <= POOL_VCPU_LIMIT)) || die 2 "Capacity formula violated: REPLICAS=$REPLICAS exceeds pool limit $POOL_VCPU_LIMIT vCPU."
  if [[ "$scaler" == ca ]]; then
    ca_max=${CA_MAX_SIZE:-$(tfvar_get ca_max_size 4)}
    ((REPLICAS <= ca_max)) || die 2 "Capacity formula violated: REPLICAS=$REPLICAS > ca_max_size=$ca_max (one 1-vCPU pod per 2-vCPU node)."
  fi
}

# ---------------------------------------------------------------- terraform helpers
tfvar_get() { # tfvar_get NAME DEFAULT: reads a simple key = "value" line from terraform.tfvars
  local name=$1 def=$2 v=""
  if [[ -r "$TF_DIR/terraform.tfvars" ]]; then
    v=$(sed -n -E "s/^${name}[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*/\1/p" "$TF_DIR/terraform.tfvars" | head -n 1)
    v=${v%"${v##*[![:space:]]}"}
  fi
  printf '%s' "${v:-$def}"
}
tf() { terraform -chdir="$TF_DIR" "$@"; }
tf_out() { tf output -raw "$1"; }

# ---------------------------------------------------------------- tools
need_tool() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die 3 "Missing tool: $t"
  done
}

check_kubectl_version() { # the demo cluster is 1.35: kubectl must be >= 1.34 (skew policy)
  local minor
  need_tool kubectl jq
  minor=$(kubectl version --client -o json | jq -r '.clientVersion.minor')
  minor=${minor//[!0-9]/}
  [[ -n "$minor" ]] || die 3 "Cannot read the kubectl client version."
  ((minor >= 34)) || die 3 "kubectl client 1.$minor is too old for a 1.35 cluster; install kubectl >= 1.34."
}

check_account() { # only after this passes may the other AWS API calls be made
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text) || die 6 "aws sts get-caller-identity failed."
  [[ "$acct" == "$EXPECTED_AWS_ACCOUNT_ID" ]] || die 2 "AWS credentials resolve to a different account than EXPECTED_AWS_ACCOUNT_ID."
}

check_tf_cluster_name() { # if terraform state exists it must belong to CLUSTER_NAME
  local state_name
  if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
    state_name=$(tf_out cluster_name 2>/dev/null || true)
    if [[ -n "$state_name" && "$state_name" != "$CLUSTER_NAME" ]]; then
      die 2 "CLUSTER_NAME differs from the cluster in the Terraform state."
    fi
  fi
}

# ---------------------------------------------------------------- dry run
is_dry() { [[ "${DRY_RUN:-0}" == 1 ]]; }
run_mut() { # run_mut CMD...: executes a mutating command unless DRY_RUN=1
  if is_dry; then
    log DRY "$(printf '%s ' "$@")"
    return 0
  fi
  "$@"
}

poll_until() { # poll_until TIMEOUT_S INTERVAL_S DESCRIPTION CMD...: 0 when CMD succeeds, 5 on timeout
  local timeout=$1 interval=$2 desc=$3 start now
  shift 3
  if is_dry; then
    log DRY "wait for: $desc"
    return 0
  fi
  start=$(date +%s)
  while ! "$@"; do
    now=$(date +%s)
    if ((now - start >= timeout)); then
      warn "Timeout after ${timeout}s waiting for: $desc"
      return 5
    fi
    sleep "$interval"
  done
}

# ---------------------------------------------------------------- confirmation (no env/flag bypass)
require_tty() {
  [[ -t 0 && -r /dev/tty ]] || die 4 "A terminal is required: typed confirmation cannot be automated (no env var or flag bypasses it)."
}
confirm_by_typing() { # confirm_by_typing EXPECTED_TEXT
  local expected=$1 answer=""
  require_tty
  printf 'Type "%s" and press Enter to continue: ' "$expected" >/dev/tty
  IFS= read -r answer </dev/tty || die 4 "No answer read from the terminal."
  [[ "$answer" == "$expected" ]] || die 4 "Confirmation text did not match; nothing was changed."
}

# ---------------------------------------------------------------- cost warning
print_cost_warning() {
  local nodes line
  if [[ ! -r "$PRICING_FILE" ]]; then
    warn "Pricing snapshot not found: cost warning unavailable. Remember to destroy the cluster (06-down.sh)."
    return 0
  fi
  nodes=$(tfvar_get system_desired_size 2)
  [[ "$nodes" =~ ^[0-9]+$ ]] || nodes=2
  while IFS= read -r line; do warn "$line"; done < <(
    jq -r --argjson n "$nodes" '
      ((.fixed.eks_control_plane_usd_per_hour + .fixed.nat_gateway_usd_per_hour + .fixed.public_ipv4_usd_per_hour
        + $n * .instances["t3.large"].on_demand_usd_per_hour) * 1000 | round / 1000) as $idle
      | "COST (ước tính theo giá list, \(.retrieved_utc)): idle ~$\($idle)/h (~$\($idle * 24 | round)/day), steady ~$\(.estimates.steady_usd_per_hour)/h, peak ~$\(.estimates.peak_usd_per_hour)/h (~$\(.estimates.peak_usd_per_hour * 24 | round)/day)."
      , "COST: a forgotten cluster costs ~$\($idle * 730 | round)/month idle. REMEMBER: ./06-down.sh"' "$PRICING_FILE"
  )
}

# ---------------------------------------------------------------- init
# init_script NAME NEEDS_CONTEXT(0|1) NEEDS_TTY(0|1)
# Order matters: pure-bash validation first (exit 2 with no tool call), tty check (exit 4), tools (3), account (2/6).
init_script() {
  SCRIPT_NAME=$1
  validate_env "$2"
  if [[ "$3" == 1 ]]; then require_tty; fi
  setup_logging
  need_tool aws jq
  check_account
  check_tf_cluster_name
  if [[ "$2" == 1 ]]; then check_kubectl_version; fi
  print_cost_warning
}

# ---------------------------------------------------------------- kubernetes wrappers (the only kubectl/helm calls)
kcfg() { kubectl --kubeconfig "$DEMO_KUBECONFIG" "$@"; } # config-only, never contacts a cluster
_need_guard() { [[ "$_DEMO_GUARD_OK" == 1 ]] || die 2 "Internal error: require_demo_cluster has not passed."; }
kc() {
  _need_guard
  kubectl --kubeconfig "$DEMO_KUBECONFIG" --context "$KUBE_CONTEXT" "$@"
}
hc() {
  _need_guard
  helm --kubeconfig "$DEMO_KUBECONFIG" --kube-context "$KUBE_CONTEXT" "$@"
}

require_demo_cluster() {
  local mode ctx_cluster server arn desc ep proj
  # (1) only the demo kubeconfig, mode 600
  [[ -f "$DEMO_KUBECONFIG" ]] || die 2 "Demo kubeconfig not found: run 01-up.sh first (it writes $DEMO_KUBECONFIG)."
  mode=$(stat -c '%a' "$DEMO_KUBECONFIG")
  [[ "$mode" == 600 ]] || die 2 "Demo kubeconfig must have mode 600 (found $mode)."
  # (2) the context exists in that file
  local cfg
  cfg=$(kcfg config view -o json) || die 6 "Cannot read the demo kubeconfig."
  ctx_cluster=$(jq -r --arg c "$KUBE_CONTEXT" '[.contexts[]? | select(.name == $c) | .context.cluster][0] // empty' <<<"$cfg")
  [[ -n "$ctx_cluster" ]] || die 2 "Context $KUBE_CONTEXT is not in the demo kubeconfig."
  server=$(jq -r --arg n "$ctx_cluster" '[.clusters[]? | select(.name == $n) | .cluster.server][0] // empty' <<<"$cfg")
  arn=$ctx_cluster
  # (3) positive allow-list: ARN must be this account + this cluster
  [[ "$arn" == *":${EXPECTED_AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}" ]] || die 2 "Context cluster is not :<expected account>:cluster/${CLUSTER_NAME}."
  # (4) name-only deny list
  if [[ "$KUBE_CONTEXT" =~ $DENY_CONTEXT_REGEX || "$arn" =~ $DENY_CONTEXT_REGEX ]]; then
    die 2 "Context or ARN matches the deny list."
  fi
  # (5) the cluster is tagged Project=finops-spot-demo and its endpoint equals the kubeconfig server
  desc=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.[endpoint,tags.Project]' --output text) || die 6 "aws eks describe-cluster failed."
  IFS=$'\t' read -r ep proj <<<"$desc"
  [[ "$proj" == "finops-spot-demo" ]] || die 2 "Cluster is not tagged Project=finops-spot-demo."
  [[ "$ep" == "$server" ]] || die 2 "Cluster endpoint differs from the kubeconfig server."
  _DEMO_GUARD_OK=1
}

# ---------------------------------------------------------------- shared helpers
render_tpl() { # render_tpl FILE VAR...: envsubst with an explicit variable list (no accidental expansion)
  local file=$1 vars="" v
  shift
  for v in "$@"; do vars+="\${$v} "; done
  envsubst "$vars" <"$file"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_of() { date -u -d "$1" +%s; }
csv_field() { local v=${1//,/;}; printf '%s' "${v//$'\n'/ }"; }
csv_row() { # csv_row FIELD...: joins with commas, sanitising commas and newlines in values
  local out="" f first=1
  for f in "$@"; do
    if ((first)); then first=0; else out+=","; fi
    out+=$(csv_field "$f")
  done
  printf '%s\n' "$out"
}
ensure_csv() { # ensure_csv FILE TEMPLATE: creates FILE from the header-only template when absent
  [[ -f "$1" ]] || cp "$RESULTS_DIR/templates/$2" "$1"
}

get_spot_quota() { # prints the integer Spot (standard) vCPU quota
  local q
  q=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-34B43A08 \
    --query Quota.Value --output text --region "$AWS_REGION") || die 6 "service-quotas call failed."
  printf '%s' "${q%.*}"
}

# Coexistence gate: (a) shared CRDs unchanged since 02 PHASE=platform, (b) pools Ready.
crd_versions() {
  kc get crd nodepools.karpenter.sh nodeclaims.karpenter.sh -o json |
    jq -S -c '[.items[] | {(.metadata.name): .metadata.resourceVersion}] | add'
}
crd_state_file() { printf '%s/crd-resourceversions-%s.json' "$STATE_DIR" "$CLUSTER_NAME"; }
_ready_true() { jq -e '[.status.conditions[]? | select(.type == "Ready") | .status] | first == "True"' >/dev/null; }
gate_coexistence() { # gate_coexistence SCALER...: returns 5 on failure (callers print the fallback)
  local s expected current list
  list=$(printf ' %s' "$@")
  list+=" "
  if [[ "$list" == *" karpenter "* && "$list" == *" automode "* ]]; then
    [[ -f "$(crd_state_file)" ]] || {
      warn "No recorded CRD resourceVersions: run 02-deploy-apps.sh with PHASE=platform first."
      return 5
    }
    expected=$(jq -S -c . "$(crd_state_file)")
    current=$(crd_versions)
    [[ "$expected" == "$current" ]] || {
      warn "Gate (a) failed: shared Karpenter CRDs changed since the platform phase."
      return 5
    }
  fi
  for s in "$@"; do
    case "$s" in
      karpenter) kc get nodepool karpenter -o json | _ready_true || {
        warn "Gate (b) failed: NodePool karpenter is not Ready."
        return 5
      } ;;
      automode)
        kc get nodepool automode -o json | _ready_true || {
          warn "Gate (b) failed: NodePool automode is not Ready."
          return 5
        }
        kc get nodeclasses.eks.amazonaws.com default-automode -o json | _ready_true || {
          warn "Gate (b) failed: Auto Mode NodeClass is not Ready."
          return 5
        }
        ;;
      *) ;;
    esac
  done
}
two_cluster_fallback_hint() {
  warn "FALLBACK: run Auto Mode in a second cluster (second Terraform workspace, cluster_name=finops-spot-demo-am,"
  warn "enabled_scalers=[\"automode\"]; first cluster [\"ca\",\"karpenter\"]). About +\$0.37/h. See docs/runbook.md."
}
