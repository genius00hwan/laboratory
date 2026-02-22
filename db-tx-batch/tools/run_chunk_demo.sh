#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep `run_chunk_demo.sh` safe by default:
# - The original version used `settings.sql` and TRUNCATE on real `orders` (destructive on large runs).
# - This version runs the same concept on `bench_orders` only.

bash "${here}/tools/run_chunk_demo_bench.sh" "${1:-10000}"
