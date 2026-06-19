#!/bin/bash
set -euo pipefail

target="$1"

if [ -z "$target" ]; then
    echo "ERROR: No target specified. Usage: $0 <target>" >&2
    exit 1
fi

config_file=".config.$target"

if [ ! -f "$config_file" ]; then
    echo "ERROR: Config file '$config_file' not found" >&2
    exit 1
fi

cp "$config_file" .config
make olddefconfig
mkdir -p outfw
make clean
make
mv out/klipper.bin "outfw/${target}_klipper.bin"
echo "SUCCESS: Built outfw/${target}_klipper.bin"
