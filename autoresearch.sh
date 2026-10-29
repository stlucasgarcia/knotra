#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec mix run bench/observability_bench.exs
