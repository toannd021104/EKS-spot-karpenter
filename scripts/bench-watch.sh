#!/usr/bin/env bash
# Terminal watcher used for the asciinema recording: scales the bench Deployment and
# prints one line per second (elapsed, nodes, Pods Running/Pending). No cluster ARN is printed.
#   scripts/bench-watch.sh <automode|karpenter> <N>
set -euo pipefail

BENCH_REGION="${BENCH_REGION:-us-west-2}"
BENCH_CLUSTER="${BENCH_CLUSTER:-amazing-blues-outfit}"
BENCH_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CLUSTER_ARN="arn:aws:eks:${BENCH_REGION}:${BENCH_ACCOUNT}:cluster/${BENCH_CLUSTER}"
KCTX="${KCTX:-$CLUSTER_ARN}"
[[ "$KCTX" == "$CLUSTER_ARN" ]] || { echo "wrong kubectl context" >&2; exit 1; }
scaler=${1:?scaler}
n=${2:?replicas}
ns="bench-$scaler"
# One API call per second; a pre-fetched token avoids the slow exec auth plugin on every call.
TOKEN=$(aws eks get-token --cluster-name amazing-blues-outfit --region us-west-2 --query status.token --output text)
k() { kubectl --context "$KCTX" --token="$TOKEN" "$@"; }

case "$scaler" in
  automode) title="EKS Auto Mode" ;;
  karpenter) title="Karpenter" ;;
  *) echo "scaler must be automode|karpenter" >&2; exit 2 ;;
esac

printf '\033[1m%s: scale 0 -> %s replicas (cluster us-west-2, On-Demand)\033[0m\n' "$title" "$n"
printf '$ kubectl scale deploy/inflate -n %s --replicas=%s\n' "$ns" "$n"
start=$(date +%s)
k -n "$ns" scale deploy/inflate --replicas="$n" >/dev/null
last_nodes=-1
while :; do
  el=$(($(date +%s) - start))
  snap=$(k get nodes,pods -A -o json)
  read -r nodes nready ready < <(jq -r --arg s "$scaler" --arg ns "$ns" '
    [(.items[] | select(.kind=="Node" and .metadata.labels.bench==$s)) ] as $n
    | [(.items[] | select(.kind=="Pod" and .metadata.namespace==$ns and (.status.conditions // [] | any(.type=="Ready" and .status=="True"))))] as $p
    | "\($n|length) \([$n[] | select(.status.conditions | any(.type=="Ready" and .status=="True"))]|length) \($p|length)"' <<<"$snap")
  pending=$((n - ready))
  printf 't+%02ds  nodes %d (Ready %d)   Pods Running %2d  Pending %2d\n' "$el" "$nodes" "$nready" "$ready" "$pending"
  if ((nodes != last_nodes && nodes > 0)); then
    jq -r --arg s "$scaler" '.items[] | select(.kind=="Node" and .metadata.labels.bench==$s)
      | "        + node \(.metadata.labels["node.kubernetes.io/instance-type"]) \(if (.status.conditions|any(.type=="Ready" and .status=="True")) then "Ready" else "NotReady" end)"' <<<"$snap"
    last_nodes=$nodes
  fi
  if ((ready >= n)); then
    printf '\033[1;32mAll %s Pods Ready after %ss\033[0m\n' "$n" "$el"
    break
  fi
  sleep 0.5
done
sleep 3
