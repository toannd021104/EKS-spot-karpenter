#!/usr/bin/env bash
# Live node scale-up benchmark: EKS Auto Mode vs self-managed Karpenter.
#
#   scripts/live-bench.sh smoke            # 1 run (N=5) per scaler -> results/live/smoke.csv
#   scripts/live-bench.sh matrix           # 2 scalers x {5,15,30} x 3 reps, interleaved -> results/live/runs.csv
#   scripts/live-bench.sh single <automode|karpenter> <N> [rep]
#
# Timing: every timestamp is taken from the API server (1 s resolution).
# T0 = creationTimestamp of the first Pod of the run (server clock), so
# client/server clock skew does not enter the results. The client clock T0
# and an estimated skew are stored in the raw JSON for reference only.
set -euo pipefail

BENCH_REGION="${BENCH_REGION:-us-west-2}"
BENCH_CLUSTER="${BENCH_CLUSTER:-amazing-blues-outfit}"
BENCH_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CLUSTER_ARN="arn:aws:eks:${BENCH_REGION}:${BENCH_ACCOUNT}:cluster/${BENCH_CLUSTER}"
KCTX="${KCTX:-$CLUSTER_ARN}"
if [[ "$KCTX" != "$CLUSTER_ARN" ]]; then
  echo "Refusing to run: kubectl context must be the bench cluster ($CLUSTER_ARN)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/results/live}"
RAW="$OUT/raw"
PRICES="$OUT/pricing-us-west-2.json"
RUN_TIMEOUT="${RUN_TIMEOUT:-900}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-600}"
REPLICAS_LIST=(5 15 30)
REPS=3
mkdir -p "$RAW"

k() { kubectl --context "$KCTX" "$@"; }
now_ms() { date +%s%3N; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Estimated client->server clock offset in seconds (server minus client, +-1 s).
estimate_skew() {
  local before after name="skew-probe-$$" created mid
  before=$(date +%s)
  k create configmap "$name" -n default >/dev/null
  after=$(date +%s)
  created=$(k get configmap "$name" -n default -o jsonpath='{.metadata.creationTimestamp}')
  k delete configmap "$name" -n default >/dev/null
  mid=$(((before + after) / 2))
  echo $(($(date -u -d "$created" +%s) - mid))
}

pool_count() { # scaler -> number of NodeClaims + Nodes still present
  local a b
  a=$(k get nodeclaims -l "karpenter.sh/nodepool=bench-$1" -o name 2>/dev/null | wc -l)
  b=$(k get nodes -l "bench=$1" -o name 2>/dev/null | wc -l)
  echo $((a + b))
}

wait_empty() { # scaler
  local s=$1 start=$SECONDS
  while [[ "$(pool_count "$s")" != "0" ]]; do
    if ((SECONDS - start > DRAIN_TIMEOUT)); then
      log "ERROR: pool bench-$s not empty after ${DRAIN_TIMEOUT}s"
      return 1
    fi
    sleep 2
  done
  log "pool bench-$s empty after $((SECONDS - start))s"
}

had_run() { # scaler -> true if any earlier row exists (matrix or smoke)
  local f
  for f in "$OUT/runs.csv" "$OUT/smoke.csv"; do
    [[ -f "$f" ]] && grep -q "^$1," "$f" && return 0
  done
  return 1
}

run_one() { # scaler replicas rep csv
  local s=$1 n=$2 rep=$3 csv=$4 ns="bench-$1" cold=false status=ok note=""
  had_run "$s" || cold=true
  local tag rawfile
  tag="${s}-n${n}-r${rep}-$(date -u +%Y%m%dT%H%M%SZ)"
  rawfile="$RAW/$tag.json"

  k -n "$ns" scale deploy/inflate --replicas=0 >/dev/null
  wait_empty "$s"

  local skew t0_client
  skew=$(estimate_skew)
  log "RUN $s N=$n rep=$rep cold=$cold skew_est=${skew}s"
  t0_client=$(now_ms)
  k -n "$ns" scale deploy/inflate --replicas="$n" >/dev/null

  local start=$SECONDS ready=0
  while :; do
    ready=$(k -n "$ns" get deploy inflate -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    ready=${ready:-0}
    ((ready >= n)) && break
    if ((SECONDS - start > RUN_TIMEOUT)); then
      status=failed
      note="timeout after ${RUN_TIMEOUT}s with ${ready}/${n} Pods Ready"
      break
    fi
    sleep 1
  done
  log "  finished status=$status ready=$ready/$n in $((SECONDS - start))s (poll time)"

  local tmp
  tmp=$(mktemp -d)
  k -n "$ns" get pods -o json | jq 'del(.items[].metadata.managedFields)' >"$tmp/pods.json"
  k get nodes -l "bench=$s" -o json | jq 'del(.items[].metadata.managedFields)' >"$tmp/nodes.json"
  k get nodeclaims -l "karpenter.sh/nodepool=bench-$s" -o json | jq 'del(.items[].metadata.managedFields)' >"$tmp/claims.json"
  jq -n \
    --arg scaler "$s" --argjson replicas "$n" --argjson rep "$rep" --argjson cold "$cold" \
    --arg status "$status" --arg note "$note" --argjson t0 "$t0_client" --argjson skew "$skew" \
    --slurpfile pods "$tmp/pods.json" --slurpfile nodes "$tmp/nodes.json" --slurpfile nodeclaims "$tmp/claims.json" \
    '{scaler:$scaler,replicas:$replicas,rep:$rep,cold:$cold,status:$status,note:$note,
      t0_client_epoch_ms:$t0,clock_skew_server_minus_client_s:$skew,
      pods:$pods[0],nodes:$nodes[0],nodeclaims:$nodeclaims[0]}' >"$rawfile"
  rm -rf "$tmp"

  python3 "$ROOT/scripts/live_bench_metrics.py" "$rawfile" "$PRICES" "$csv" >&2

  k -n "$ns" scale deploy/inflate --replicas=0 >/dev/null
  wait_empty "$s"
}

order_for_rep() { # rep -> scaler order (alternates so neither always goes first)
  if ((($1 % 2) == 1)); then echo "automode karpenter"; else echo "karpenter automode"; fi
}

cmd=${1:-}
case "$cmd" in
  smoke)
    for s in automode karpenter; do run_one "$s" 5 0 "$OUT/smoke.csv"; done
    ;;
  matrix)
    for rep in $(seq 1 "$REPS"); do
      for n in "${REPLICAS_LIST[@]}"; do
        for s in $(order_for_rep "$rep"); do
          run_one "$s" "$n" "$rep" "$OUT/runs.csv"
        done
      done
    done
    ;;
  single)
    run_one "${2:?scaler}" "${3:?replicas}" "${4:-0}" "${CSV:-$OUT/extra.csv}"
    ;;
  *)
    echo "usage: $0 smoke | matrix | single <automode|karpenter> <N> [rep]" >&2
    exit 2
    ;;
esac
