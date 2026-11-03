#!/bin/bash
# Offline regression tests, one block per bug found in review (docs/iterations.md).
set -u
. "$(dirname "$0")/lib.sh"

# NEXT

echo "regress pass=$pass fail=$fail"; rm -rf "$TMP"; [ "$fail" = 0 ]
