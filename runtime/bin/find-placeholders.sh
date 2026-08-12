#!/usr/bin/env bash

set -euo pipefail

ENV_FILE="${1:?usage: find-placeholders.sh ENV_FILE}"

awk '
  /^[[:space:]]*#/ { next }
  index($0, "__GENERATE_AT_INSTALL__") {
    print FNR ":" $0
    found = 1
  }
  END { exit found ? 0 : 1 }
' "$ENV_FILE"
