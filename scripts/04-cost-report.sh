#!/usr/bin/env bash
# 04-cost-report.sh: export OpenCost allocation per scaler + an independent list-price model (design 4.5, 7.5, 9).
# Every dollar figure is kind=estimate ("ước tính theo giá list"); nothing here is ever called measured.
# Run after 02 PHASE=apps once Boutique has been up for at least the window (30-60 min).
# Required env: CLUSTER_NAME, EXPECTED_AWS_ACCOUNT_ID, KUBE_CONTEXT (= CLUSTER_NAME).
# Optional: SCALERS, WINDOW (default 60m; ^[0-9]+(m|h|d)$), DRY_RUN=1.
# Writes results/cost-<scaler>.csv and results/cost-listmodel.csv. Exit 6 (no CSV) if OpenCost is unreachable or empty.
set -euo pipefail
IFS=$'\n\t'
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

validate_scalers
validate_window
init_script 04-cost-report 1 0
need_tool curl python3 awk
require_demo_cluster

RUN_ID="cost-$(date -u +%Y%m%dT%H%M%SZ)"
hours=$(window_hours)
minutes=$(awk -v h="$hours" 'BEGIN{printf "%d", h*60}')
((minutes >= 30)) || warn "Window is under 30 min: OpenCost scrapes every minute, short windows are unreliable."

if is_dry; then
  info "DRY_RUN: would port-forward svc/opencost 9003, query /allocation (window=$WINDOW) and write cost CSVs."
  exit 0
fi

pf_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
kc -n opencost port-forward svc/opencost "${pf_port}:9003" >/dev/null 2>&1 &
pf_pid=$!
trap 'kill "$pf_pid" 2>/dev/null || true' EXIT

# The OpenCost API call lives in one function: parameter names are "to verify at rehearsal" (design 4.5).
opencost_allocation() { # opencost_allocation AGGREGATE
  curl -fsS --max-time 60 --get "http://127.0.0.1:${pf_port}/allocation" \
    --data-urlencode "window=${WINDOW}" --data-urlencode "aggregate=$1" \
    --data-urlencode "accumulate=true" --data-urlencode "idle=true" --data-urlencode "shareIdle=true"
}

ready=0
for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${pf_port}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
((ready)) || die 6 "OpenCost API is unreachable through the port-forward. Check the opencost pod logs (kc -n opencost logs deploy/opencost)."

ns_json=$(opencost_allocation namespace) || die 6 "OpenCost /allocation (namespace) failed."
label_json=$(opencost_allocation "label:scaler") || label_json='{"data":[{}]}'

write_cost_rows() { # write_cost_rows SCALER
  local s=$1 ns="boutique-$1" alloc cost cpu ram per_hour monthly
  alloc=$(jq -c --arg n "$ns" '.data[0][$n] // empty' <<<"$ns_json")
  if [[ -z "$alloc" ]]; then
    warn "No OpenCost data for namespace $ns in window $WINDOW."
    return 1
  fi
  cost=$(jq -r '.totalCost // 0' <<<"$alloc")
  cpu=$(jq -r '.cpuCoreHours // 0' <<<"$alloc")
  ram=$(jq -r '((.ramByteHours // 0) / 1073741824)' <<<"$alloc")
  per_hour=$(awk -v c="$cost" -v h="$hours" 'BEGIN{printf "%.6f", c/h}')
  monthly=$(awk -v p="$per_hour" 'BEGIN{printf "%.2f", p*730}')
  ensure_csv "$RESULTS_DIR/cost-$s.csv" cost.csv
  csv_row "$RUN_ID" "$s" "$WINDOW" "$ns" "$cpu" "$ram" "$cost" "$per_hour" "$monthly" opencost_estimate true opencost_allocation_namespace estimate \
    >>"$RESULTS_DIR/cost-$s.csv"
  alloc=$(jq -c --arg n "$s" '.data[0][$n] // empty' <<<"$label_json")
  if [[ -n "$alloc" ]]; then
    cost=$(jq -r '.totalCost // 0' <<<"$alloc")
    per_hour=$(awk -v c="$cost" -v h="$hours" 'BEGIN{printf "%.6f", c/h}')
    monthly=$(awk -v p="$per_hour" 'BEGIN{printf "%.2f", p*730}')
    csv_row "$RUN_ID" "$s" "$WINDOW" "label:scaler=$s" "$(jq -r '.cpuCoreHours // 0' <<<"$alloc")" \
      "$(jq -r '((.ramByteHours // 0) / 1073741824)' <<<"$alloc")" "$cost" "$per_hour" "$monthly" opencost_estimate true opencost_allocation_label estimate \
      >>"$RESULTS_DIR/cost-$s.csv"
  fi
}

written=0
for s in "${SCALERS_ARR[@]}"; do
  if write_cost_rows "$s"; then written=$((written + 1)); fi
done
((written > 0)) || die 6 "OpenCost returned no data for any scaler. It can need up to a few hours for stable numbers: wait or widen WINDOW. No CSV was written."

# ---- independent list-price model: node-hours x snapshot price (or live Spot price), plus the Auto Mode fee
spot_price() { # spot_price TYPE -> average of the latest market prices (read-only EC2 call), empty if unavailable
  local prices
  prices=$(aws ec2 describe-spot-price-history --region "$AWS_REGION" --instance-types "$1" \
    --product-descriptions Linux/UNIX --start-time "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[].SpotPrice' --output text 2>/dev/null || true)
  [[ -n "$prices" ]] || return 0
  tr -s '[:space:]' '\n' <<<"$prices" | awk 'NF{s+=$1;n++} END{if(n) printf "%.5f", s/n}'
}

nodes_tsv=$(kc get nodes -o json | jq -r --argjson w "$hours" --argjson now "$(date +%s)" '
  .items[] | select((.metadata.labels.scaler // "") != "")
  | [.metadata.labels.scaler, (.metadata.labels["node.kubernetes.io/instance-type"] // "unknown"),
     ((.metadata.labels["karpenter.sh/capacity-type"] // .metadata.labels["eks.amazonaws.com/capacityType"] // "unknown") | ascii_downcase | sub("_"; "-")),
     ((($now - (.metadata.creationTimestamp | fromdateiso8601)) / 3600) as $age | (if $age > $w then $w else $age end))]
  | @tsv')
list_csv="$RESULTS_DIR/cost-listmodel.csv"
ensure_csv "$list_csv" cost-listmodel.csv
today=$(date -u +%Y-%m-%d)
retrieved=$(jq -r '.retrieved_utc' "$PRICING_FILE")
declare -A hours_by_key=()
while IFS=$'\t' read -r sc ty cap nh; do
  [[ -n "${sc:-}" ]] || continue
  if ! has_scaler "$sc"; then continue; fi
  key="$sc|$ty|$cap"
  hours_by_key[$key]=$(awk -v a="${hours_by_key[$key]:-0}" -v b="$nh" 'BEGIN{printf "%.4f", a+b}')
done <<<"$nodes_tsv"

for key in "${!hours_by_key[@]}"; do
  IFS='|' read -r sc ty cap <<<"$key"
  nh=${hours_by_key[$key]}
  od=$(jq -r --arg t "$ty" '.instances[$t].on_demand_usd_per_hour // empty' "$PRICING_FILE")
  price=""
  source_tag=list_snapshot
  price_date=$retrieved
  if [[ "$cap" == spot ]]; then
    price=$(spot_price "$ty")
    source_tag=spot_market_snapshot
    price_date=$today
    if [[ -z "$price" ]]; then
      price=$(jq -r --arg t "$ty" '(.instances[$t] | if .spot_usd_per_hour_min == null then empty else ((.spot_usd_per_hour_min + .spot_usd_per_hour_max) / 2) end) // empty' "$PRICING_FILE")
      price_date=$retrieved
    fi
  else
    price=$od
  fi
  cost=""
  fee=""
  if [[ -n "$price" ]]; then cost=$(awk -v p="$price" -v h="$nh" 'BEGIN{printf "%.6f", p*h}'); fi
  if [[ "$sc" == automode && -n "$od" ]]; then
    fee=$(jq -r --argjson od "$od" --argjson h "$nh" '.fixed.auto_mode_fee_fraction_of_on_demand * $od * $h' "$PRICING_FILE")
  fi
  [[ -n "$price" ]] || warn "No price known for $ty ($cap): cost left empty (never invented)."
  csv_row "$RUN_ID" "$sc" "$ty" "$cap" "$nh" "$price" "$source_tag" "$price_date" "$cost" "$fee" "ước tính theo giá list" estimate >>"$list_csv"
done

info "Wrote cost CSVs (run $RUN_ID, window $WINDOW). All figures are estimates at list prices; Spot is estimated (no data feed)."
info "Next: python3 scripts/fill_results.py"
