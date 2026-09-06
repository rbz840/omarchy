#!/bin/bash
# tests/check-pkg-availability.sh — verify every package listed in
# build/packages/*.packages exists in the Arch Linux ARM repositories.
#
# Method: download the pacman database tarballs (core.db, extra.db, alarm.db,
# aur.db) from the ALARM mirror and read each package's real %NAME%.
# NOTE: ALARM's layout is http://mirror.archlinuxarm.org/$arch/$repo/
# (NOT the x86 /$repo/os/$arch layout, and there are no browsable listings).
#
# Run on any machine with network access + python3 (or inside a container).
# Exit 0 = all packages found. Exit 1 = at least one is missing everywhere.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PKGS_DIR="$REPO_ROOT/build/packages"
MIRROR="${ALARM_MIRROR:-http://mirror.archlinuxarm.org}"
ARCH="${ARCH:-aarch64}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'pass' >/dev/null 2>&1; then
    PY="$(command -v "$cand")"
    break
  fi
done
[[ -n "$PY" ]] || fail "a working python3/python is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

# 1. Download repo DBs --------------------------------------------------------
log "Downloading ALARM $ARCH repo databases from $MIRROR ..."
for repo in core extra alarm aur; do
  url="$MIRROR/$ARCH/$repo/$repo.db"
  curl -fsSL --retry 3 -o "$WORK/$repo.db" "$url" || fail "cannot fetch $url"
  log "  $repo.db: $(wc -c < "$WORK/$repo.db") bytes"
done

# 2. Extract package names + test the lists ----------------------------------
"$PY" - "$WORK" "$PKGS_DIR" <<'EOF'
import json, re, sys, tarfile

work, pkgs_dir = sys.argv[1], sys.argv[2]

names = {}
for repo in ("core", "extra", "alarm", "aur"):
    with tarfile.open(f"{work}/{repo}.db", "r:gz") as tf:
        pkgs = set()
        for m in tf.getmembers():
            if m.name.endswith("/desc"):
                content = tf.extractfile(m).read().decode("utf-8", "replace").splitlines()
                for i, line in enumerate(content):
                    if line.strip() == "%NAME%" and i + 1 < len(content):
                        pkgs.add(content[i + 1].strip())
                        break
        names[repo] = pkgs
allrepos = {p for r in names.values() for p in r}
print(f"Index: {len(names['core'])}+{len(names['extra'])}+{len(names['alarm'])}+{len(names['aur'])} packages")

def read_list(path):
    out = []
    for line in open(path, encoding="utf-8"):
        line = re.sub(r"\s+", "", line.split("#")[0])
        if line:
            out.append(line)
    return out

missing = []
total = 0
for fname in ("omarchy-pi5-base.packages", "omarchy-pi5-other.packages"):
    pkgs = read_list(f"{pkgs_dir}/{fname}")
    total += len(pkgs)
    bad = [p for p in pkgs if p not in allrepos]
    status = "OK " if not bad else "FAIL"
    print(f"[{status}] {fname}: {len(pkgs)} entries, {len(bad)} missing")
    missing += [(fname, m) for m in bad]

if missing:
    print("\nNOT FOUND in any ALARM repo:")
    for fname, m in missing:
        print(f"  - {m}  ({fname})")
    print("\nFix: correct the name, move the package to build/packages/aur.txt,")
    print("or add it to build/packages/drop.txt with a reason.")
    sys.exit(1)

print(f"\nAll {total} repo-list packages found in ALARM repositories.")
EOF
