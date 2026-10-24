#!/usr/bin/env bash
# Blocks a commit if any staged file contains a value from your real lab.
# Put your real public IPs, project ID, hostnames etc. in a LOCAL file
# (~/.hybrid-lab-denylist, one regex per line). That file never enters the repo,
# so the patterns themselves are never published.
set -euo pipefail

DENYLIST="${HYBRID_LAB_DENYLIST:-$HOME/.hybrid-lab-denylist}"

if [[ ! -s "$DENYLIST" ]]; then
  echo "check-sanitized: no denylist at $DENYLIST. Create it before committing." >&2
  exit 1
fi

status=0
for f in "$@"; do
  [[ -f "$f" ]] || continue
  if grep -nEf "$DENYLIST" -- "$f" >/dev/null 2>&1; then
    echo "BLOCKED: $f contains a real lab value (matched your denylist)." >&2
    status=1
  fi
done
exit "$status"
