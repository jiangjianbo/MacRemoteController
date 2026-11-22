#!/usr/bin/env bash
exec bash "$(cd "$(dirname "$0")" && pwd)/scripts/e2e.sh" "$@"
