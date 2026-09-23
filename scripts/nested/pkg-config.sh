#!/usr/bin/env bash
# FindPkgConfig retains system -L flags and can otherwise select installed
# libraries ahead of our newer private copies when combining dependencies.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
result=$(/usr/bin/pkg-config "$@")
for arg in "$@"; do
    if [[ $arg == --libs || $arg == --libs-only-L ]]; then
        printf '%s ' "-L$root/.nested/prefix/lib"
        break
    fi
done
printf '%s\n' "$result"
