#!/bin/bash
set -euo pipefail

targets=("bed" "noz" "mcu")

for target in "${targets[@]}"; do
    echo "Building $target..."
    ./_build.sh "$target"
done

echo "All builds complete."
