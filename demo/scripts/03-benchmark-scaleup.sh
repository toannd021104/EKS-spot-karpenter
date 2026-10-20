#!/usr/bin/env bash
# 03-benchmark-scaleup.sh: time node scale-up per scaler with the 'inflate' workload (design 3.2, 7.4).
# Runs between 02 PHASE=platform and 02 PHASE=apps: the pools must be empty and no Boutique pod may exist.
# Required env: CLUSTER_NAME, EXPECTED_AWS_ACCOUNT_ID, KUBE_CONTEXT (= CLUSTER_NAME).
# Optional: SCALERS (default ca,karpenter,automode), REPS 1-10 (default 3; plus one cold rep=0), REPLICAS 1-4 (default 4),
#           PREFLIGHT_ONLY=1 (check the state and stop), DRY_RUN=1.
# Every timestamp except the scale-down timer comes from API-server objects. Timeouts are recorded as outcome=timeout,
# never as a made-up number. Rows are written to results/scaleup-<scaler>.csv with kind=observed.
# Exit codes: 0 ok, 2 guard / capacity formula, 3 tool, 5 bad state / timeout / isolation violation, 6 call failed.
set -euo pipefail
IFS=$'\n\t'
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

validate_scalers
validate_int REPLICAS 1 4 4
validate_int REPS 1 10 3
init_script 03-benchmark-scaleup 1 0
require_demo_cluster

readonly SCALEUP_TIMEOUT_S=600
readonly SCALEDOWN_TIMEOUT_S=900
RUN_ID="bench-$(date -u +%Y%m%dT%H%M%SZ)"
problems=0
isolation_violation=0
scaledown_failed=0
scaling_started=0

preflight() {
  local s n pods spot
  for s in "${SCALERS_ARR[@]}"; do check_capacity_formula "$s"; done
  spot=$(get_spot_quota)
  ((3 * POOL_VCPU_LIMIT <= spot)) || die 2 "3 pools x $POOL_VCPU_LIMIT vCPU exceeds the Spot quota ($spot)."
  for s in "${SCALERS_ARR[@]}"; do
    n=$(kc get nodes -l "scaler=$s" -o json | jq '.items | length')
    ((n == 0)) || die 5 "Pool $s has $n node(s). Run 02-deploy-apps.sh with PHASE=apps-down and wait until the pool is empty."
    pods=$(kc get pods -A -o json | jq --arg s "$s" '
      [.items[] | select((.spec.nodeSelector.scaler // "") == $s)
       | select((.metadata.labels["app.kubernetes.io/name"] // "") != "inflate")] | length')
    ((pods == 0)) || die 5 "$pods pod(s) other than inflate target pool $s (Boutique present?). Run 02-deploy-apps.sh with PHASE=apps-down."
  done
  if ! gate_coexistence "${SCALERS_ARR[@]}"; then
    two_cluster_fallback_hint
    exit 5
  fi
}

cleanup() {
  local s
  if ((scaling_started)) && ! is_dry; then
    for s in "${SCALERS_ARR[@]}"; do
      kc scale deployment/inflate -n "scaletest-$s" --replicas=0 >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

diff_s() { # diff_s FROM TO (ISO-8601) -> integer seconds, empty if either is empty
  if [[ -z "$1" || -z "$2" ]]; then
    printf ''
    return 0
  fi
  printf '%s' "$(($(epoch_of "$2") - $(epoch_of "$1")))"
}

pool_node_count() { kc get nodes -l "scaler=$1" -o json | jq '.items | length'; }

run_rep() { # run_rep SCALER REP
  local s=$1 rep=$2 ns="scaletest-$1" t0="" pods_json nodes_json start now
  local node_ready="" first_run="" all_run="" running created types caps zones ami pid
  local outcome=ok notes="" other y foreign=0 down_start scaledown=""

  run_mut kc scale deployment/inflate -n "$ns" --replicas="$REPLICAS"
  start=$(date +%s)
  while :; do
    pods_json=$(kc get pods -n "$ns" -l app.kubernetes.io/name=inflate -o json)
    if [[ -z "$t0" ]]; then
      t0=$(jq -r '[.items[].metadata.creationTimestamp] | sort | first // empty' <<<"$pods_json")
    fi
    if [[ -n "$t0" ]]; then
      nodes_json=$(kc get nodes -l "scaler=$s" -o json)
      node_ready=$(jq -r --arg t "$t0" '
        [.items[] | select(.metadata.creationTimestamp >= $t)
         | .status.conditions[]? | select(.type == "Ready" and .status == "True") | .lastTransitionTime]
        | sort | first // empty' <<<"$nodes_json")
      running=$(jq '[.items[] | select(.status.phase == "Running")] | length' <<<"$pods_json")
      if ((running >= REPLICAS)); then
        first_run=$(jq -r '[.items[].status.containerStatuses[]?.state.running.startedAt // empty] | sort | first // empty' <<<"$pods_json")
        all_run=$(jq -r '[.items[].status.containerStatuses[]?.state.running.startedAt // empty] | sort | last // empty' <<<"$pods_json")
        break
      fi
    fi
    now=$(date +%s)
    if ((now - start >= SCALEUP_TIMEOUT_S)); then
      outcome=timeout
      notes="no all-running within ${SCALEUP_TIMEOUT_S}s; check Spot/On-Demand quota and NodeClaim/ASG events"
      [[ -n "$node_ready" ]] || notes="no node created within ${SCALEUP_TIMEOUT_S}s; check quota, ICE, NodeClaim/ASG events"
      warn "Pool $s rep $rep: $notes"
      break
    fi
    sleep 1
  done

  # nodes created in this pool, types, zones, AMI (read-only EC2 lookup)
  nodes_json=$(kc get nodes -l "scaler=$s" -o json)
  created=$(jq --arg t "${t0:-9999}" '[.items[] | select(.metadata.creationTimestamp >= $t)] | length' <<<"$nodes_json")
  types=$(jq -r --arg t "${t0:-9999}" '[.items[] | select(.metadata.creationTimestamp >= $t) | .metadata.labels["node.kubernetes.io/instance-type"] // empty] | unique | join(";")' <<<"$nodes_json")
  caps=$(jq -r --arg t "${t0:-9999}" '[.items[] | select(.metadata.creationTimestamp >= $t) | (.metadata.labels["karpenter.sh/capacity-type"] // .metadata.labels["eks.amazonaws.com/capacityType"] // empty)] | unique | join(";")' <<<"$nodes_json")
  zones=$(jq -r --arg t "${t0:-9999}" '[.items[] | select(.metadata.creationTimestamp >= $t) | .metadata.labels["topology.kubernetes.io/zone"] // empty] | unique | join(";")' <<<"$nodes_json")
  pid=$(jq -r --arg t "${t0:-9999}" '[.items[] | select(.metadata.creationTimestamp >= $t) | .spec.providerID // empty] | first // empty' <<<"$nodes_json")
  ami=""
  if [[ -n "$pid" ]]; then
    ami=$(aws ec2 describe-instances --instance-ids "${pid##*/}" --region "$AWS_REGION" \
      --query 'Reservations[].Instances[].ImageId' --output text 2>/dev/null || true)
  fi

  # gate (c): no node may have been created in the OTHER pools during this rep
  for y in "${ALL_SCALERS_ARR[@]}"; do
    if [[ "$y" == "$s" ]]; then continue; fi
    other=$(kc get nodes -l "scaler=$y" -o json | jq --arg t "${t0:-9999}" '[.items[] | select(.metadata.creationTimestamp >= $t)] | length')
    foreign=$((foreign + other))
  done
  if ((foreign > 0)); then
    outcome=isolation_violation
    notes="$foreign node(s) created in other pools during the rep"
    isolation_violation=1
  fi

  # scale down and time the return to 0 nodes (laptop clock for both ends)
  run_mut kc scale deployment/inflate -n "$ns" --replicas=0
  down_start=$(date +%s)
  pool_empty() { [[ "$(pool_node_count "$s")" == 0 ]]; }
  if poll_until "$SCALEDOWN_TIMEOUT_S" 2 "pool $s back to 0 nodes" pool_empty; then
    scaledown=$(($(date +%s) - down_start))
  else
    notes="${notes:+$notes; }scaledown_timeout"
    problems=1
  fi

  ensure_csv "$RESULTS_DIR/scaleup-$s.csv" scaleup.csv
  csv_row "$RUN_ID" "$s" "$rep" "$REPLICAS" "$t0" "$node_ready" "$first_run" "$all_run" \
    "$(diff_s "$t0" "$node_ready")" "$(diff_s "$t0" "$first_run")" "$(diff_s "$t0" "$all_run")" \
    "$created" "$types" "$caps" "$zones" "$ami" "$scaledown" "$outcome" "$notes" observed \
    >>"$RESULTS_DIR/scaleup-$s.csv"
  info "Pool $s rep $rep: outcome=$outcome node_provision_s=$(diff_s "$t0" "$node_ready") all_pods_running_s=$(diff_s "$t0" "$all_run")"
  if [[ "$outcome" != ok ]]; then problems=1; fi
  if [[ -z "$scaledown" ]]; then scaledown_failed=1; fi
}

preflight
if [[ "${PREFLIGHT_ONLY:-0}" == 1 ]]; then
  info "PREFLIGHT_ONLY: state is clean, nothing was scaled."
  exit 0
fi
if is_dry; then
  info "DRY_RUN: preflight passed; the measurement itself is skipped."
  exit 0
fi

print_cost_warning
scaling_started=1
info "Benchmark $RUN_ID: scalers=${SCALERS_ARR[*]} reps=$REPS (+ cold rep=0) replicas=$REPLICAS. Expected 45-60 min for all three."
for s in "${SCALERS_ARR[@]}"; do
  rep=0
  while ((rep <= REPS)); do
    scaledown_failed=0
    run_rep "$s" "$rep"
    if ((scaledown_failed)); then
      warn "Pool $s did not return to 0 nodes: stopping its reps."
      break
    fi
    rep=$((rep + 1))
  done
done

print_cost_warning
if ((isolation_violation)); then
  two_cluster_fallback_hint
  die 5 "Isolation violation recorded (outcome=isolation_violation)."
fi
((problems == 0)) || die 5 "At least one rep timed out or did not scale down: see the outcome/notes columns."
info "Done: results/scaleup-<scaler>.csv. Next: fill_results.py, then 02-deploy-apps.sh with PHASE=apps."
