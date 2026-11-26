#!/usr/bin/env bash
# Replace the AWS account ID with <account-id> in every collected file, so results can be published.
#   AWS_PROFILE=... scripts/scrub.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
acct="$(aws sts get-caller-identity --query Account --output text)"
[[ "$acct" =~ ^[0-9]{12}$ ]] || { echo "could not read the account ID" >&2; exit 1; }
files="$(grep -rl "$acct" "$here/results" "$here/findings" 2>/dev/null || true)"
[ -z "$files" ] && { echo "clean"; exit 0; }
echo "$files" | while read -r f; do sed -i "s/$acct/<account-id>/g" "$f"; echo "scrubbed $f"; done
