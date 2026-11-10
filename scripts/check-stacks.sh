#!/usr/bin/env bash
# Checks that the stack list in scripts/lib.sh (STACKS) matches the repo (part of make validate):
#   - every directory under stacks/ is listed, and every listed stack exists
#   - each stack reads (terraform_remote_state key "<stack>.tfstate") only stacks listed before it
#   - apply.yml's stack choices are "all" + STACKS (GitHub needs them spelled out)
#   - ci-runner's k8s_stacks default = the stacks with provider "kubernetes"
#   - every variable set in envs/examples/ still exists (CI does not plan the examples)
. "$(dirname "$0")/lib.sh" --account
cd "$ROOT_DIR"
fail=0
bad() { echo "check-stacks: $*" >&2; fail=1; }

for d in stacks/*/; do d="${d#stacks/}"; d="${d%/}"; in_list "$d" "${STACKS[@]}" || bad "stacks/$d is not in STACKS (scripts/lib.sh)"; done

seen=()
for s in "${STACKS[@]}"; do
  [[ -d "stacks/$s" ]] || { bad "STACKS lists '$s' but stacks/$s does not exist"; continue; }
  for dep in $(stack_upstreams "$s"); do
    in_list "$dep" "${seen[@]:-}" || bad "$s reads $dep's state, but $dep is not listed before $s in STACKS"
  done
  seen+=("$s")
done

choices="$(sed -nE 's/^ *options: \[(all, .*)\]$/\1/p' .github/workflows/apply.yml | head -1)"
want="all, $(printf '%s, ' "${STACKS[@]}" | sed 's/, $//')"
[[ "$choices" == "$want" ]] || bad "apply.yml stack options are [$choices], expected [$want]"

k8s=()
for s in "${STACKS[@]}"; do grep -q 'provider "kubernetes"' "stacks/$s"/*.tf 2>/dev/null && k8s+=("\"$s\""); done
default="$(sed -n '/variable "k8s_stacks"/,/^}/s/^ *default *= *\[\(.*\)\]$/\1/p' stacks/ci-runner/variables.tf)"
[[ "$default" == "$(printf '%s, ' "${k8s[@]}" | sed 's/, $//')" ]] || bad "ci-runner k8s_stacks default is [$default], stacks with provider \"kubernetes\": ${k8s[*]}"

for f in envs/examples/*/*.tfvars; do
  stack="$(basename "$f" .tfvars)"
  case "$stack" in
    common) declared=(stacks/*/variables.tf) ;;
    state) declared=(bootstrap/state/variables.tf) ;;
    *) declared=("stacks/$stack/variables.tf") ;;
  esac
  for var in $(sed -nE 's/^([a-z0-9_]+) *=.*/\1/p' "$f"); do
    grep -qsE "^variable \"$var\"" "${declared[@]}" || bad "$f sets $var, which ${declared[*]} does not declare"
  done
done

[[ "$fail" -eq 0 ]] && echo "check-stacks: ${STACKS[*]} - order, apply.yml choices, k8s_stacks and examples match"
exit "$fail"
