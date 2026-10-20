#!/usr/bin/env bash
# 05-chaos-node-down.sh: remove ONE worker node per scaler and time the recovery (design 7.6).
# Runs with Boutique present (after 02 PHASE=apps). Hard cap: 1 victim per scaler per run.
# Required env: CLUSTER_NAME, EXPECTED_AWS_ACCOUNT_ID, KUBE_CONTEXT (= CLUSTER_NAME).
# Optional: SCALERS, MODE=terminate|fis|drain (default terminate), ALLOW_SINGLE_NODE=1, DRY_RUN=1.
# Documented AWS mutations (the only ones in this project outside Terraform): ec2 terminate-instances,
# ec2 create-tags / delete-tags (FisTarget on the victim), fis start-experiment. All are limited to an instance
# whose AWS-managed tag eks:eks-cluster-name equals CLUSTER_NAME.
# t_kill uses the laptop clock (UTC); other timestamps come from API objects (error about +-2 s, documented).
# probe_total / probe_failed are NOT computed here: fill_results.py derives them from the raw probe log slice.
# Exit codes: 0 ok, 2 guard (per scaler), 3 tool, 5 unhealthy baseline / timeout, 6 call failed.
set -euo pipefail
IFS=$'\n\t'
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

validate_scalers
validate_mode
init_script 05-chaos-node-down 1 0
require_demo_cluster

readonly RECOVERY_TIMEOUT_S=600
RUN_ID="chaos-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RESULTS_DIR/raw"
worst=0

fail_scaler() { # fail_scaler CODE MESSAGE: record the worst exit code and continue with the next scaler
  warn "$2"
  if (($1 > worst)); then worst=$1; fi
}

pick_victim() { # pick_victim SCALER -> "node count" ; most boutique-X pods, tie: a node hosting frontend
  kc get pods -n "boutique-$1" -o json | jq -r '
    [.items[] | select(.spec.nodeName != null) | {n: .spec.nodeName, f: ((.metadata.labels["app.kubernetes.io/name"] // "") == "frontend")}]
    | group_by(.n) | map({n: .[0].n, c: length, f: (map(.f) | any)})
    | sort_by([.c, .f]) | last // empty | "\(.n)\t\(.c)"'
}

all_available() { # every Deployment in boutique-X has availableReplicas == replicas
  kc get deploy -n "boutique-$1" -o json | jq -e 'all(.items[]; (.status.availableReplicas // 0) == .spec.replicas)' >/dev/null
}

chaos_one() { # chaos_one SCALER
  local s=$1 ns="boutique-$1" nodes_n victim_line victim count pid iid tag cap mode_used notes=""
  local t_kill t_kill_epoch replacement="" ready_utc="" ready_epoch recovery outcome=ok fis_id template
  local rescheduled hosts_cart rep probe_rel window_start window_end proj

  nodes_n=$(kc get nodes -l "scaler=$s" -o json | jq '.items | length')
  if ((nodes_n < 2)) && [[ "${ALLOW_SINGLE_NODE:-0}" != 1 ]]; then
    fail_scaler 2 "Pool $s has $nodes_n node(s); at least 2 required (ALLOW_SINGLE_NODE=1 overrides)."
    return 0
  fi
  victim_line=$(pick_victim "$s")
  [[ -n "$victim_line" ]] || {
    fail_scaler 5 "No Boutique pods found in $ns."
    return 0
  }
  IFS=$'\t' read -r victim count <<<"$victim_line"
  pid=$(kc get node "$victim" -o jsonpath='{.spec.providerID}')
  iid=${pid##*/}
  [[ "$iid" =~ ^i-[0-9a-f]+$ ]] || {
    fail_scaler 2 "Cannot derive an instance id for node $victim."
    return 0
  }
  # instance validation: AWS-managed tag, never the optional custom tag
  # shellcheck disable=SC2016 # JMESPath backticks are literal
  tag=$(aws ec2 describe-instances --instance-ids "$iid" --region "$AWS_REGION" \
    --query 'Reservations[].Instances[].Tags[?Key==`eks:eks-cluster-name`].Value | [0] | [0]' --output text) || tag=""
  if [[ "$tag" != "$CLUSTER_NAME" ]]; then
    fail_scaler 2 "Instance $iid lacks tag eks:eks-cluster-name=$CLUSTER_NAME: refusing to kill it."
    return 0
  fi
  # shellcheck disable=SC2016 # JMESPath backticks are literal
  proj=$(aws ec2 describe-instances --instance-ids "$iid" --region "$AWS_REGION" \
    --query 'Reservations[].Instances[].Tags[?Key==`Project`].Value | [0] | [0]' --output text 2>/dev/null || true)
  [[ "$proj" == "finops-spot-demo" ]] || warn "Instance $iid has no Project=finops-spot-demo tag (custom tag propagation?): WARN only."
  cap=$(kc get node "$victim" -o json | jq -r '.metadata.labels["karpenter.sh/capacity-type"] // .metadata.labels["eks.amazonaws.com/capacityType"] // "unknown"' | tr 'A-Z_' 'a-z-')
  hosts_cart=$(kc get pods -n "$ns" --field-selector "spec.nodeName=$victim" -o json |
    jq -r '[.items[] | select((.metadata.labels["app.kubernetes.io/name"] // "") == "cartservice")] | length')
  ((hosts_cart == 0)) || notes="victim hosted cartservice (in-memory carts lost, expected)"

  # baseline: the last 30 probe lines must all be 2xx
  if ! kc logs -n finops-probe deploy/probe -c "probe-$s" --tail=30 | awk '$2 !~ /^2[0-9][0-9]$/ {bad=1} {n++} END{exit (bad || n == 0)}'; then
    fail_scaler 5 "Unhealthy baseline for $s (non-2xx in the last 30 probe lines)."
    return 0
  fi

  mode_used=$MODE
  info "Pool $s: victim $victim ($iid, $cap, $count Boutique pods), mode=$mode_used"
  if [[ "$mode_used" == fis && "$cap" != spot ]]; then
    mode_used=terminate
    notes="${notes:+$notes; }fis_needs_spot_fell_back_to_terminate"
  fi

  t_kill=""
  case "$mode_used" in
    terminate)
      if run_mut aws ec2 terminate-instances --instance-ids "$iid" --region "$AWS_REGION" >/dev/null; then
        t_kill=$(now_utc)
      elif [[ "$s" == automode ]]; then
        warn "terminate-instances denied on the Auto Mode managed instance: falling back to drain (recorded)."
        mode_used=drain
        notes="${notes:+$notes; }terminate_denied"
      else
        fail_scaler 6 "terminate-instances failed for $iid."
        return 0
      fi
      ;;
    fis)
      template=$(tf output -json fis_template_ids | jq -r --arg s "$s" '.[$s] // empty')
      [[ -n "$template" ]] || {
        fail_scaler 6 "No FIS template for $s (enable_fis=false?)."
        return 0
      }
      run_mut aws ec2 create-tags --resources "$iid" --tags Key=FisTarget,Value=true --region "$AWS_REGION"
      fis_id=$(run_mut aws fis start-experiment --experiment-template-id "$template" --region "$AWS_REGION" --query experiment.id --output text) ||
        fail_scaler 6 "fis start-experiment failed."
      t_kill=$(now_utc)
      info "FIS experiment ${fis_id:-dry-run} started (2-minute warning, then interruption)."
      ;;
    *) ;;
  esac
  if [[ "$mode_used" == drain ]]; then
    run_mut kc drain "$victim" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
    run_mut kc delete node "$victim"
    t_kill=$(now_utc)
  fi
  [[ -n "$t_kill" ]] || {
    fail_scaler 6 "Kill step produced no t_kill for $s."
    return 0
  }
  t_kill_epoch=$(epoch_of "$t_kill")
  if is_dry; then
    info "DRY_RUN: nothing was killed; no timing and no CSV row are produced."
    return 0
  fi

  # wait for: replacement node Ready, no pod left on the victim, every Deployment available
  recovered() {
    replacement=$(kc get nodes -l "scaler=$s" -o json | jq -r --arg t "$t_kill" --arg v "$victim" '
      [.items[] | select(.metadata.name != $v and .metadata.creationTimestamp >= $t)
       | .status.conditions[]? | select(.type == "Ready" and .status == "True") | .lastTransitionTime] | sort | first // empty')
    [[ -n "$replacement" ]] || return 1
    local left
    left=$(kc get pods -n "$ns" --field-selector "spec.nodeName=$victim" -o json | jq '.items | length')
    ((left == 0)) || return 1
    all_available "$s"
  }
  if poll_until "$RECOVERY_TIMEOUT_S" 1 "boutique-$s recovered after losing $victim" recovered; then
    ready_utc=$(now_utc)
    ready_epoch=$(epoch_of "$ready_utc")
    recovery=$((ready_epoch - t_kill_epoch))
  else
    outcome=timeout
    recovery=""
    notes="${notes:+$notes; }no full recovery within ${RECOVERY_TIMEOUT_S}s"
    ready_epoch=$(date +%s)
  fi
  if [[ "$mode_used" == fis ]]; then
    run_mut aws ec2 delete-tags --resources "$iid" --tags Key=FisTarget --region "$AWS_REGION" || true
  fi

  # probe window = [t_kill, all_pods_ready + 30 s]; save the raw slice, counts are computed in fill_results.py
  window_start=$t_kill_epoch
  window_end=$((ready_epoch + 30))
  sleep 30
  probe_rel="raw/probe-$s-$RUN_ID.log"
  kc logs -n finops-probe deploy/probe -c "probe-$s" --since="$(($(date +%s) - t_kill_epoch + 10))s" >"$RESULTS_DIR/$probe_rel" ||
    fail_scaler 6 "Could not save the probe log for $s."
  rescheduled=$(kc get pods -n "$ns" -o json | jq --arg t "$t_kill" '[.items[] | select(.metadata.creationTimestamp > $t)] | length')

  ensure_csv "$RESULTS_DIR/chaos-$s.csv" chaos.csv
  rep=$(($(tail -n +2 "$RESULTS_DIR/chaos-$s.csv" | wc -l) + 1))
  csv_row "$RUN_ID" "$s" "$rep" "$mode_used" "$victim" "$iid" "$cap" "$t_kill" "$replacement" "${ready_utc}" "$recovery" \
    "$window_start" "$window_end" "$probe_rel" "$rescheduled" "$outcome" "$notes" observed >>"$RESULTS_DIR/chaos-$s.csv"
  info "Pool $s: outcome=$outcome recovery_s=${recovery:-n/a} mode=$mode_used"
  [[ "$outcome" == ok ]] || fail_scaler 5 "Pool $s timed out."
}

if is_dry; then
  warn "DRY_RUN: mutating commands are printed, not executed; recovery waits are skipped."
fi
print_cost_warning
for s in "${SCALERS_ARR[@]}"; do
  chaos_one "$s"
done
info "Chaos run $RUN_ID finished (mode differs across scalers? then slide 12 carries the footnote 'mode khác nhau')."
if ((worst != 0)); then exit "$worst"; fi
info "Next: python3 demo/scripts/fill_results.py"
