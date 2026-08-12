#!/usr/bin/env bash

set -euo pipefail

ENV_FILE="${1:?usage: find-placeholders.sh ENV_FILE}"

awk '
  function closing_quote(value, quote, i, slash_count, j) {
    for (i = 2; i <= length(value); i++) {
      if (substr(value, i, 1) != quote) {
        continue
      }
      if (quote == sprintf("%c", 39)) {
        return i
      }
      slash_count = 0
      for (j = i - 1; j >= 1 && substr(value, j, 1) == "\\"; j--) {
        slash_count++
      }
      if (slash_count % 2 == 0) {
        return i
      }
    }
    return 0
  }

  { value = "" }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
    value = $0
    sub(/^[^=]*=[[:space:]]*/, "", value)
    quote = substr(value, 1, 1)
    if (quote == "\"" || quote == sprintf("%c", 39)) {
      end = closing_quote(value, quote)
      if (end > 0) {
        value = substr(value, 1, end)
      }
    } else {
      sub(/[[:space:]]+#.*/, "", value)
    }
  }
  index(value, "__GENERATE_AT_INSTALL__") {
    print FNR ":" $0
    found = 1
  }
  END { exit found ? 0 : 1 }
' "$ENV_FILE"
