#!/usr/bin/env bash
# lint.sh: static checks for the whole demo package. Never calls AWS or a cluster.
# Uses: docker (shellcheck, kubeconform images), terraform, helm, envsubst, grep, deck/.venv (yamllint).
# Runs every check, prints PASS/FAIL per check and exits 1 if any failed (3 if a required tool is missing).
# shellcheck disable=SC2016 # grep/envsubst patterns containing $ are literal on purpose
set -uo pipefail
IFS=$'\n\t'

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEMO_ROOT=$(dirname "$SCRIPTS_DIR")
PROJECT_ROOT=$(dirname "$DEMO_ROOT")
SHELLCHECK_IMAGE=koalaman/shellcheck:v0.10.0
KUBECONFORM_IMAGE=ghcr.io/yannh/kubeconform:v0.6.7
YAMLLINT="$PROJECT_ROOT/deck/.venv/bin/yamllint"
FAILED=0
WARNINGS=0
TMP=$(mktemp -d)
cleanup() {
  rm -rf "$TMP"
  rm -rf "$DEMO_ROOT/terraform/.terraform" # AC13: never leave provider downloads behind (the lock file stays)
}
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1" >&2
  FAILED=$((FAILED + 1))
}
warn() {
  printf 'WARN  %s\n' "$1" >&2
  WARNINGS=$((WARNINGS + 1))
}
need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing tool: %s\n' "$1" >&2
    exit 3
  }
}
need terraform
need helm
need envsubst
need grep
need docker

# ---------------------------------------------------------------- 1. shellcheck (Docker, pinned tag)
mapfile -t SH_FILES < <(cd "$DEMO_ROOT" && ls scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh)
if docker run --rm -v "$DEMO_ROOT:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" -x "${SH_FILES[@]}"; then
  pass "shellcheck ($SHELLCHECK_IMAGE): 0 findings on ${#SH_FILES[@]} files"
else
  fail "shellcheck reported findings"
fi

# ---------------------------------------------------------------- 2. terraform
if terraform -chdir="$DEMO_ROOT/terraform" fmt -check -recursive >/dev/null; then pass "terraform fmt -check"; else fail "terraform fmt -check"; fi
if terraform -chdir="$DEMO_ROOT/terraform" init -backend=false -input=false >"$TMP/tf-init.log" 2>&1; then
  pass "terraform init -backend=false"
  if terraform -chdir="$DEMO_ROOT/terraform" validate >"$TMP/tf-validate.log" 2>&1; then pass "terraform validate"; else
    cat "$TMP/tf-validate.log" >&2
    fail "terraform validate"
  fi
  if terraform -chdir="$DEMO_ROOT/terraform" test >"$TMP/tf-test.log" 2>&1; then pass "terraform test ($(tail -n 1 "$TMP/tf-test.log"))"; else
    tail -n 30 "$TMP/tf-test.log" >&2
    fail "terraform test"
  fi
else
  tail -n 20 "$TMP/tf-init.log" >&2
  fail "terraform init -backend=false"
fi

# ---------------------------------------------------------------- 3. helm lint / template per scaler + envsubst of the .tpl files
CHART="$DEMO_ROOT/k8s/boutique"
mkdir -p "$TMP/render"
for s in ca karpenter automode; do
  if helm lint "$CHART" -f "$CHART/values-common.yaml" -f "$CHART/values-$s.yaml" >/dev/null 2>&1; then pass "helm lint ($s)"; else fail "helm lint ($s)"; fi
  if helm template "boutique-$s" "$CHART" -f "$CHART/values-common.yaml" -f "$CHART/values-$s.yaml" >"$TMP/render/boutique-$s.yaml" 2>"$TMP/helm-$s.err"; then
    pass "helm template ($s)"
  else
    cat "$TMP/helm-$s.err" >&2
    fail "helm template ($s)"
  fi
  SCALER=$s envsubst '${SCALER}' <"$DEMO_ROOT/k8s/scaletest/inflate.yaml.tpl" >"$TMP/render/inflate-$s.yaml"
done
export CLUSTER_NAME=finops-spot-demo AWS_REGION=ap-southeast-1 KARPENTER_NODE_ROLE=dummy-karpenter-node AUTOMODE_NODE_ROLE=dummy-automode-node
envsubst '${CLUSTER_NAME} ${KARPENTER_NODE_ROLE}' <"$DEMO_ROOT/k8s/karpenter/ec2nodeclass.yaml.tpl" >"$TMP/render/ec2nodeclass.yaml"
envsubst '${CLUSTER_NAME}' <"$DEMO_ROOT/k8s/karpenter/nodepool.yaml.tpl" >"$TMP/render/nodepool-karpenter.yaml"
envsubst '${CLUSTER_NAME} ${AUTOMODE_NODE_ROLE}' <"$DEMO_ROOT/k8s/automode/nodeclass.yaml.tpl" >"$TMP/render/nodeclass-automode.yaml"
envsubst '${CLUSTER_NAME}' <"$DEMO_ROOT/k8s/automode/nodepool.yaml.tpl" >"$TMP/render/nodepool-automode.yaml"
mkdir -p "$TMP/values"
envsubst '${CLUSTER_NAME} ${AWS_REGION}' <"$DEMO_ROOT/k8s/cluster-autoscaler/values.yaml.tpl" >"$TMP/values/ca-values.yaml"
cp "$DEMO_ROOT/k8s/probe/probe.yaml.tpl" "$TMP/render/probe.yaml"

# leftover variables after substitution would mean a template needs a variable the scripts do not export
if grep -nE '\$\{[A-Z_]+\}' "$TMP"/render/*.yaml "$TMP"/values/*.yaml >"$TMP/unsubstituted.txt"; then
  cat "$TMP/unsubstituted.txt" >&2
  fail "templates still contain \${VAR} after envsubst"
else pass "templates fully substituted by the variable lists used in 02-deploy-apps.sh"; fi

# ---------------------------------------------------------------- 4. yamllint (venv) on values/manifests
if [[ -x "$YAMLLINT" ]]; then
  YL_CFG='{extends: relaxed, rules: {line-length: disable, comments: disable, comments-indentation: disable, indentation: {spaces: consistent}}}'
  mapfile -t YAML_FILES < <(cd "$DEMO_ROOT" && ls k8s/*/values*.yaml k8s/boutique/Chart.yaml opencost/*.yaml)
  if (cd "$DEMO_ROOT" && "$YAMLLINT" -d "$YL_CFG" "${YAML_FILES[@]}" "$TMP"/render/*.yaml "$TMP"/values/*.yaml) >"$TMP/yamllint.log" 2>&1; then
    pass "yamllint (values, rendered manifests)"
  else
    sed "s#$TMP/##" "$TMP/yamllint.log" >&2
    fail "yamllint"
  fi
else
  fail "yamllint missing: run deck/.venv/bin/pip install -r deck/requirements.txt"
fi

# ---------------------------------------------------------------- 5. kubeconform (Docker, pinned tag)
if docker run --rm -v "$TMP/render:/data:ro" "$KUBECONFORM_IMAGE" -ignore-missing-schemas -summary /data >"$TMP/kubeconform.log" 2>&1; then
  pass "kubeconform ($KUBECONFORM_IMAGE): $(tail -n 1 "$TMP/kubeconform.log")"
else
  cat "$TMP/kubeconform.log" >&2
  fail "kubeconform"
fi

# ---------------------------------------------------------------- 6. secrets / account ids (AC10); only synthetic 00000000000N allowed
SEARCH_DIRS=("$DEMO_ROOT" "$PROJECT_ROOT/deck")
[[ -f "$PROJECT_ROOT/README.md" ]] && SEARCH_DIRS+=("$PROJECT_ROOT/README.md")
GREP_EXCL=(--exclude-dir=.venv --exclude-dir=.terraform --exclude-dir=__pycache__ --exclude-dir=preview --exclude=.terraform.lock.hcl)
if grep -rIEn "${GREP_EXCL[@]}" '(^|[^0-9])[0-9]{12}([^0-9]|$)' "${SEARCH_DIRS[@]}" | grep -vE '0{11}[0-9]|sha256:' >"$TMP/acct.txt"; then
  cat "$TMP/acct.txt" >&2
  fail "12-digit number that is not a synthetic account id (AC10)"
else pass "no real-looking AWS account id (AC10)"; fi
if grep -rIE "${GREP_EXCL[@]}" 'AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|EC) PRIVATE' "${SEARCH_DIRS[@]}" >"$TMP/keys.txt"; then
  cat "$TMP/keys.txt" >&2
  fail "key material pattern found"
else pass "no access keys or private keys"; fi

# ---------------------------------------------------------------- 7. kubectl / helm only inside lib/common.sh
if grep -nE '(^|[^[:alnum:]_./-])(kubectl|helm) ' "$DEMO_ROOT"/scripts/0*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' >"$TMP/direct.txt"; then
  cat "$TMP/direct.txt" >&2
  fail "kubectl/helm used outside lib/common.sh (use kc()/hc())"
else pass "kubectl/helm only inside lib/common.sh (scripts use kc()/hc())"; fi

# ---------------------------------------------------------------- 8. aws subcommand allow-list (design 19)
ALLOWED='^(sts get-caller-identity|service-quotas get-service-quota|pricing get-products|ec2 describe-[a-z-]+|ec2 terminate-instances|ec2 create-tags|ec2 delete-tags|eks describe-[a-z-]+|eks update-kubeconfig|autoscaling describe-[a-z-]+|elbv2 describe-[a-z-]+|resourcegroupstaggingapi get-resources|fis start-experiment)$'
bad_aws=0
while IFS= read -r sub; do
  if ! [[ "$sub" =~ $ALLOWED ]]; then
    printf '  not allowed: aws %s\n' "$sub" >&2
    bad_aws=1
  fi
done < <(grep -hE "(^|[^[:alnum:]_./-])aws [a-z0-9-]+ [a-z0-9-]+" "$DEMO_ROOT"/scripts/0*.sh "$DEMO_ROOT"/scripts/lib/common.sh | grep -vE '^[[:space:]]*#' |
  grep -oE 'aws [a-z0-9-]+ [a-z0-9-]+' | sed 's/^aws //' | sort -u)
if ((bad_aws)); then fail "aws subcommand outside the documented allow-list"; else pass "only documented aws subcommands (read-only plus the 05/01 mutations)"; fi

# ---------------------------------------------------------------- 9. placeholders that must be resolved
if grep -rn 'REPLACE_WITH_DIGEST' "$DEMO_ROOT/k8s" >/dev/null 2>&1; then warn "REPLACE_WITH_DIGEST placeholder present in k8s manifests"; else pass "no unresolved digest placeholder"; fi

printf '\n%d check(s) failed, %d warning(s)\n' "$FAILED" "$WARNINGS"
[[ "$FAILED" -eq 0 ]]
