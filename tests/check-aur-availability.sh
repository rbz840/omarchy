#!/bin/bash
# tests/check-aur-availability.sh — verify every AUR candidate from
# build/packages/aur.txt exists in the AUR.
#
# Method: single batched request to the official AUR RPC API (type=info).
# (Web-scraping package pages hits HTTP 429 rate limits; the RPC does not.)
#
# Exit 0 = all found; exit 1 = at least one is missing from the AUR.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AUR_FILE="$REPO_ROOT/build/packages/aur.txt"

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }

PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'pass' >/dev/null 2>&1; then
    PY="$(command -v "$cand")"
    break
  fi
done
[[ -n "$PY" ]] || { echo "ERROR: a working python3/python is required" >&2; exit 1; }

# Read package names (strip comments, blank lines and inline whitespace).
# NOTE: tr -d '[:space:]' would be WRONG here — it also strips newlines and
# would fuse every name into a single token.
mapfile -t names < <(sed 's/#.*//' "$AUR_FILE" | tr -d ' \t' | sed '/^$/d')

if (( ${#names[@]} == 0 )); then
  echo "No AUR packages listed in $AUR_FILE"
  exit 0
fi

# Build the batched RPC query: ?v=5&type=info&arg[]=a&arg[]=b...
q=""
for n in "${names[@]}"; do q+="&arg[]=$n"; done
url="https://aur.archlinux.org/rpc/?v=5&type=info${q}"

# --globoff is mandatory: curl treats [] in arg[]=... as URL globbing,
# silently mangling the query (resultcount=0).
response=$(curl -g -fsSL --retry 3 --max-time 60 "$url") || {
  echo "ERROR: AUR RPC request failed" >&2
  exit 1
}

printf '%s' "$response" > /tmp/omarchy-aur-rpc.json
"$PY" - "$AUR_FILE" /tmp/omarchy-aur-rpc.json <<'EOF'
import json, sys

aur_file, rpc_file = sys.argv[1], sys.argv[2]

names = []
for line in open(aur_file, encoding="utf-8"):
    line = line.split("#")[0].strip()
    if line:
        names.append(line)

data = json.load(open(rpc_file, encoding="utf-8"))
found = {r["Name"] for r in data.get("results", [])}

print(f"AUR RPC: resultcount={data.get('resultcount')}, checked={len(names)}")
print()
missing = []
for n in names:
    if n in found:
        print(f"OK       {n}")
    else:
        print(f"MISSING  {n}")
        missing.append(n)

print()
print(f"Found: {len(names) - len(missing)} - Missing: {len(missing)}")
if missing:
    print()
    print("These AUR packages do not exist (or are renamed). Update build/packages/aur.txt")
    print("(e.g. use the -git variant) or move the entry to build/packages/drop.txt.")
    sys.exit(1)
EOF
