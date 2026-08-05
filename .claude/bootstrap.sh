#!/usr/bin/env bash
# SessionStart bootstrap: make sure ./mxcli exists, then warm the dev loop.
#
# The mxcli binary is gitignored (88 MB), so a fresh clone has no binary and the
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

# Warm caches (MxBuild + runtime), start Postgres, create the app database.
# Non-fatal: a session should still start if this fails.
./mxcli run --local --setup --ensure-db -p App.mpr || true
