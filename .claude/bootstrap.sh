#!/usr/bin/env bash
# SessionStart bootstrap: make sure ./mxcli exists, then warm the dev loop for
# every Mendix app in this repo.
#
# Layout: each app lives in its own subfolder (App/App.mpr, and any siblings),
# which is what `mxcli new <Name>` produces when run from the repo root. This
# script discovers them rather than hardcoding one path, so adding a second app
# needs no edit here.
#
# The mxcli binary is gitignored (84 MB), so a fresh clone has no binary and the
# stock hook's `test -x ./mxcli` guard would silently no-op. This script fetches
# it first. See FINDINGS.md finding 4.
#
# Pin a specific release by setting MXCLI_RELEASE, e.g. MXCLI_RELEASE=v0.1.0.
set -u

cd "$(dirname "$0")/.." || exit 0

MXCLI_RELEASE="${MXCLI_RELEASE:-nightly}"

if [ ! -x ./mxcli ]; then
  case "$(uname -s)" in
    Linux)  os=linux  ;;
    Darwin) os=darwin ;;
    *)      echo "bootstrap: unsupported OS $(uname -s), skipping" >&2; exit 0 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) echo "bootstrap: unsupported arch $(uname -m), skipping" >&2; exit 0 ;;
  esac

  url="https://github.com/mendixlabs/mxcli/releases/download/${MXCLI_RELEASE}/mxcli-${os}-${arch}"
  echo "bootstrap: downloading mxcli (${MXCLI_RELEASE}, ${os}/${arch})..."
  if ! curl -fsSL -o ./mxcli.tmp "$url"; then
    echo "bootstrap: failed to download $url" >&2
    rm -f ./mxcli.tmp
    exit 0
  fi
  chmod +x ./mxcli.tmp && mv ./mxcli.tmp ./mxcli
fi

# Warm caches (MxBuild + runtime), start Postgres, create each app's database.
# Non-fatal: a session should still start if this fails.
shopt -s nullglob
found=0
for mpr in */*.mpr *.mpr; do
  case "$mpr" in *.mpr.bak|*.mpr.lock) continue ;; esac
  found=1
  echo "bootstrap: warming $mpr"
  ./mxcli run --local --setup --ensure-db -p "$mpr" || true
done
[ "$found" = 1 ] || echo "bootstrap: no .mpr found, nothing to warm" >&2
