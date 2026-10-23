#!/usr/bin/env bash
# Read-only check of a repository against the tech guidelines.
# Usage: scripts/check-repo-settings.sh [--template] [--local] [moia-oss/REPO]
# The script checks only repositories in the organization moia-oss.
#   --template  This repository is the template. Placeholders are expected.
#               The script also checks the template flag.
#   --local     Read the files from the working tree and not from the
#               default branch on GitHub. Use it before you merge.
#   OWNER/REPO  Default: the origin remote of the current repository.
# The script only reads data. It never changes a setting.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

TEMPLATE=0
LOCAL=0
REPO=""
for arg in "$@"; do
  case "$arg" in
    --template) TEMPLATE=1 ;;
    --local) LOCAL=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) REPO=$arg ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO=$(git -C "$here" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##')
fi
[ -n "$REPO" ] || { echo "Error: give moia-oss/REPO as an argument." >&2; exit 2; }
case "$REPO" in
  moia-oss/*) ;;
  *) echo "Error: this script checks only repositories in moia-oss. Found: $REPO" >&2; exit 2 ;;
esac
require_gh

if [ "$LOCAL" = 1 ]; then
  cd "$(git -C "$here" rev-parse --show-toplevel)" || exit 2
  source_label="working tree"
else
  source_label="default branch on GitHub"
fi
echo "Repository checks for $REPO (read only). Files are read from the $source_label."
echo

read_file() {
  if [ "$LOCAL" = 1 ]; then
    cat -- "$1" 2>/dev/null
  else
    gh_val -H "Accept: application/vnd.github.raw+json" "repos/$REPO/contents/$1" 2>/dev/null
  fi
}

list_dir() {
  if [ "$LOCAL" = 1 ]; then
    ls -1 -- "$1" 2>/dev/null
  else
    gh_val "repos/$REPO/contents/$1" --jq '.[].name' 2>/dev/null
  fi
}

meta() { gh_val "repos/$REPO" --jq "$1" 2>/dev/null; }

# --- Template contents ---------------------------------------------------
echo "Template contents"

license=$(read_file LICENSE)
if printf '%s\n' "$license" | grep -q 'Apache License' && printf '%s\n' "$license" | grep -q 'Version 2.0'; then
  pass "LICENSE is Apache 2.0"
else
  fail "LICENSE is missing or is not Apache 2.0"
fi

readme=$(read_file README.md)
if [ -z "$readme" ]; then
  fail "README.md is missing"
else
  for section in purpose usage contribution; do
    if printf '%s\n' "$readme" | grep -Eqi "^#+ .*$section"; then
      pass "README.md has a '$section' section"
    else
      fail "README.md has no '$section' section"
    fi
  done
fi

security=$(read_file SECURITY.md)
if [ -z "$security" ]; then
  fail "SECURITY.md is missing"
elif printf '%s\n' "$security" | grep -Eqi '[[:alnum:]._-]+@[[:alnum:].-]+|security/advisories'; then
  pass "SECURITY.md names a reporting channel"
else
  fail "SECURITY.md names no reporting channel"
fi

codeowners=""
for p in CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; do
  if c=$(read_file "$p") && [ -n "$c" ]; then codeowners=$c; break; fi
done
if printf '%s\n' "$codeowners" | grep -Eq '^[[:space:]]*[^#[:space:]]'; then
  pass "CODEOWNERS has an ownership rule"
else
  fail "CODEOWNERS is missing or has no ownership rule"
fi

placeholders=0
printf '%s\n%s\n' "$readme" "$codeowners" | grep -q 'REPLACE-WITH' && placeholders=1
if [ "$placeholders" = 1 ] && [ "$TEMPLATE" = 1 ]; then
  info "Placeholders found. This is expected in the template."
elif [ "$placeholders" = 1 ]; then
  fail "Placeholders (REPLACE-WITH) remain in README.md or CODEOWNERS"
else
  pass "No placeholders remain"
fi

dependabot=""
for p in .github/dependabot.yml .github/dependabot.yaml; do
  if c=$(read_file "$p") && [ -n "$c" ]; then dependabot=$c; break; fi
done
if [ -z "$dependabot" ]; then
  fail ".github/dependabot.yml is missing"
elif printf '%s\n' "$dependabot" | grep -Eq '^[[:space:]]*-[[:space:]]+package-ecosystem:'; then
  pass "dependabot.yml has an active ecosystem"
else
  fail "dependabot.yml has no active ecosystem"
fi

workflows=$(list_dir .github/workflows | grep -E '\.ya?ml$')
if [ -z "$workflows" ]; then
  fail "No CI workflow in .github/workflows"
else
  for wf in $workflows; do
    text=$(read_file ".github/workflows/$wf" | sed 's/#.*//')
    if printf '%s\n' "$text" | grep -q 'pull_request_target'; then
      fail "$wf uses pull_request_target. Make sure that it never runs code from a fork."
    else
      pass "$wf does not use pull_request_target"
    fi
    if printf '%s\n' "$text" | grep -q 'workflow_run'; then
      warn "$wf uses workflow_run. It runs in a privileged context. Review it."
    fi
    unpinned=$(printf '%s\n' "$text" | grep -E '^[[:space:]-]*uses:[[:space:]]' \
      | grep -Ev 'uses:[[:space:]]*\./' | grep -Ev '@[0-9a-f]{40}([[:space:]]|$)')
    if [ -n "$unpinned" ]; then
      warn "$wf has actions that are not pinned to a commit hash"
    fi
  done
fi

# --- Repository settings -------------------------------------------------
echo
echo "Repository settings"
check_eq warn "Visibility" "$(meta '.visibility')" public
check_eq fail "GitHub Pages is off" "$(meta '.has_pages')" false "policy: Pages needs a prior approval"
if [ "$TEMPLATE" = 1 ]; then
  check_eq fail "Repository is marked as a template" "$(meta '.is_template')" true
fi

echo
echo "Security baseline"
check_eq fail "Secret scanning" "$(meta '.security_and_analysis.secret_scanning.status')" enabled
check_eq fail "Secret push protection" "$(meta '.security_and_analysis.secret_scanning_push_protection.status')" enabled
check_eq fail "Dependabot security updates" "$(meta '.security_and_analysis.dependabot_security_updates.status')" enabled
if gh_get "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1; then
  pass "Dependabot alerts: enabled"
else
  fail "Dependabot alerts: disabled, or the token cannot read them"
fi
check_eq warn "Code scanning default setup" \
  "$(gh_val "repos/$REPO/code-scanning/default-setup" --jq '.state' 2>/dev/null)" configured
check_eq fail "Fork pull request approval" \
  "$(gh_val "repos/$REPO/actions/permissions/fork-pr-contributor-approval" --jq '.approval_policy' 2>/dev/null)" \
  all_external_contributors
check_eq warn "Default GITHUB_TOKEN permissions" \
  "$(gh_val "repos/$REPO/actions/permissions/workflow" --jq '.default_workflow_permissions' 2>/dev/null)" read

# --- Default branch protection -------------------------------------------
echo
branch=$(meta '.default_branch')
echo "Default branch protection (${branch:-unknown})"
protected=0; approvals=0; no_force=0; no_delete=0; has_status=0; no_bypass=1

# Classic branch protection
if [ -n "$branch" ] && gh_get "repos/$REPO/branches/$branch/protection" >/dev/null 2>&1; then
  protected=1
  p="repos/$REPO/branches/$branch/protection"
  n=$(gh_val "$p" --jq '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null)
  [ "${n:-0}" -gt "$approvals" ] && approvals=$n
  [ "$(gh_val "$p" --jq '.allow_force_pushes.enabled' 2>/dev/null)" = false ] && no_force=1
  [ "$(gh_val "$p" --jq '.allow_deletions.enabled' 2>/dev/null)" = false ] && no_delete=1
  n=$(gh_val "$p" --jq '((.required_status_checks.contexts // []) | length) + ((.required_status_checks.checks // []) | length)' 2>/dev/null)
  [ "${n:-0}" -gt 0 ] && has_status=1
  [ "$(gh_val "$p" --jq '.enforce_admins.enabled' 2>/dev/null)" = true ] || no_bypass=0
fi

# Rulesets that apply to the default branch
if [ -n "$branch" ]; then
  for id in $(gh_val "repos/$REPO/rulesets" --jq '.[] | select(.target == "branch" and .enforcement == "active") | .id' 2>/dev/null); do
    r="repos/$REPO/rulesets/$id"
    applies=$(gh_val "$r" --jq ".conditions.ref_name.include | map(select(. == \"~DEFAULT_BRANCH\" or . == \"~ALL\" or . == \"refs/heads/$branch\")) | length" 2>/dev/null)
    [ "${applies:-0}" -gt 0 ] || continue
    protected=1
    [ "$(gh_val "$r" --jq '.bypass_actors | length' 2>/dev/null)" = 0 ] || no_bypass=0
    types=" $(gh_val "$r" --jq '[.rules[].type] | join(" ")' 2>/dev/null) "
    case "$types" in *" non_fast_forward "*) no_force=1 ;; esac
    case "$types" in *" deletion "*) no_delete=1 ;; esac
    case "$types" in *" required_status_checks "*) has_status=1 ;; esac
    n=$(gh_val "$r" --jq '[.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count] | max // 0' 2>/dev/null)
    [ "${n:-0}" -gt "$approvals" ] && approvals=$n
  done
fi

if [ "$protected" = 0 ]; then
  fail "The default branch has no branch protection and no ruleset"
else
  if [ "$approvals" -ge 1 ]; then pass "At least one approval before a merge ($approvals)"; else fail "No approval is required before a merge"; fi
  if [ "$no_force" = 1 ]; then pass "Force push is blocked"; else fail "Force push is not blocked"; fi
  if [ "$no_delete" = 1 ]; then pass "Deletion is blocked"; else fail "Deletion is not blocked"; fi
  if [ "$has_status" = 1 ]; then pass "Required status checks are set"; else fail "No required status check"; fi
  if [ "$no_bypass" = 1 ]; then pass "No bypass permission"; else fail "A bypass permission exists (or admins can bypass)"; fi
fi

summary
