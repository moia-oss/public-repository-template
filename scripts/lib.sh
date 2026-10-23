#!/usr/bin/env bash
# Shared helpers for the read-only compliance checks.
# Source this file. Do not run it.
#
# Read-only rule: every call to GitHub goes through `gh_get`.
# `gh_get` refuses each option that sets a method, a field, or a request body.

FAILS=0
WARNS=0
PASSES=0

pass() { PASSES=$((PASSES + 1)); printf '[PASS] %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '[FAIL] %s\n' "$*"; }
warn() { WARNS=$((WARNS + 1)); printf '[WARN] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
unverified() { WARNS=$((WARNS + 1)); printf '[WARN] Could not read: %s\n' "$*"; }

require_gh() {
  command -v gh >/dev/null 2>&1 || { echo "Error: the gh CLI is not installed." >&2; exit 2; }
  gh auth status >/dev/null 2>&1 || { echo "Error: run 'gh auth login' first." >&2; exit 2; }
}

# Call the GitHub API with the GET method only.
gh_get() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -X*|-f*|-F*|--method|--method=*|--field|--field=*|--raw-field|--raw-field=*|--input|--input=*)
        echo "Error: gh_get is read only. It refuses the option '$arg'." >&2
        exit 2
        ;;
    esac
  done
  gh api "$@"
}

# Like gh_get, but print nothing when the call fails.
# `gh` prints the error body on stdout. This function keeps it out of the values.
gh_val() {
  local out
  out=$(gh_get "$@" 2>/dev/null) || return 0
  printf '%s' "$out"
}

# check_eq <fail|warn> <label> <actual> <expected> [hint]
# An empty or null value means that the script could not read the setting.
check_eq() {
  local severity=$1 label=$2 actual=$3 expected=$4 hint=${5:-}
  if [ -z "$actual" ] || [ "$actual" = "null" ]; then
    unverified "$label${hint:+ ($hint)}"
  elif [ "$actual" = "$expected" ]; then
    pass "$label: $actual"
  elif [ "$severity" = "warn" ]; then
    warn "$label: expected '$expected', found '$actual'${hint:+. $hint}"
  else
    fail "$label: expected '$expected', found '$actual'${hint:+. $hint}"
  fi
}

summary() {
  printf '\nSummary: %d passed, %d warnings, %d failed\n' "$PASSES" "$WARNS" "$FAILS"
  if [ "$FAILS" -gt 0 ]; then
    echo "Result: NOT compliant"
    exit 1
  elif [ "$WARNS" -gt 0 ]; then
    echo "Result: compliant, but review the warnings"
  else
    echo "Result: compliant"
  fi
  exit 0
}
