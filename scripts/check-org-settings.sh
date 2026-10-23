#!/usr/bin/env bash
# Read-only check of the organization settings against the tech guidelines.
# Usage: scripts/check-org-settings.sh
# The script checks only the organization moia-oss. It refuses any other name.
# The script only reads data. It never changes a setting.
# The token needs the scope read:org.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

ORG=moia-oss
if [ $# -gt 0 ] && [ "$1" != "$ORG" ]; then
  echo "Error: this script checks only the organization $ORG." >&2
  exit 2
fi
require_gh
echo "Organization checks for $ORG (read only)"
echo

# --- Plan ---------------------------------------------------------------
plan=$(gh_val "orgs/$ORG" --jq '.plan.name' 2>/dev/null)
info "Plan: ${plan:-unknown}. Organization rulesets need GitHub Team, so set the branch protection for each repository."

# --- Default code security configuration for new repositories -----------
echo
echo "Code security configuration (default for new public repositories)"
cfg() {
  gh_val "orgs/$ORG/code-security/configurations/defaults" \
    --jq "[.[] | select(.default_for_new_repos == \"public\" or .default_for_new_repos == \"all\")][0].configuration.$1 // empty" 2>/dev/null
}
name=$(cfg name)
if [ -n "$name" ]; then info "Default configuration: $name"; fi
check_eq fail "Dependabot alerts" "$(cfg dependabot_alerts)" enabled
# The configuration can say "not_set" while the older organization setting for
# new repositories is on. The older setting also applies, so read both.
sec_updates=$(cfg dependabot_security_updates)
if [ "$sec_updates" != "enabled" ] \
  && [ "$(gh_val "orgs/$ORG" --jq '.dependabot_security_updates_enabled_for_new_repositories')" = "true" ]; then
  sec_updates=enabled
  info "Dependabot security updates: not set in the configuration. The organization setting for new repositories is on."
fi
check_eq fail "Dependabot security updates" "$sec_updates" enabled
check_eq fail "Secret scanning" "$(cfg secret_scanning)" enabled
check_eq fail "Secret push protection" "$(cfg secret_scanning_push_protection)" enabled
check_eq warn "Code scanning default setup" "$(cfg code_scanning_default_setup)" enabled
check_eq warn "Repository owners cannot change the configuration" "$(cfg enforcement)" enforced

# --- GitHub Actions ------------------------------------------------------
echo
echo "GitHub Actions"
check_eq fail "Fork pull request approval" \
  "$(gh_val "orgs/$ORG/actions/permissions/fork-pr-contributor-approval" --jq '.approval_policy' 2>/dev/null)" \
  all_external_contributors \
  "check Org Settings > Actions > General"
check_eq warn "Default GITHUB_TOKEN permissions" \
  "$(gh_val "orgs/$ORG/actions/permissions/workflow" --jq '.default_workflow_permissions' 2>/dev/null)" \
  read
check_eq warn "Actions must be pinned to a full commit hash" \
  "$(gh_val "orgs/$ORG/actions/permissions" --jq '.sha_pinning_required' 2>/dev/null)" \
  true \
  "optional hardening"

# --- Rulesets ------------------------------------------------------------
echo
echo "Rulesets"
count=$(gh_val "orgs/$ORG/rulesets" --jq 'length' 2>/dev/null)
info "Organization rulesets found: ${count:-unknown}"

summary
