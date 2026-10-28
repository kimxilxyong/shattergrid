#!/bin/bash

# Run script for Godot Solar System Demo with voxel support
# This script sets LD_PRELOAD to work around libstdc++ compatibility issues
# and runs the project with Godot 4.4+

# Path to the correct libstdc++ that has GLIBCXX_3.4.32
LIBSTDCXX="/usr/lib/libstdc++.so.6.0.36"

# Check if libstdc++ exists
if [ ! -f "$LIBSTDCXX" ]; then
    echo "Error: Required libstdc++ not found at $LIBSTDCXX"
    echo "Please install a compatible version of libstdc++ with GLIBCXX_3.4.32 support"
    exit 1
fi

# Check if Godot exists
GODOT="/usr/bin/godot"
if [ ! -x "$GODOT" ]; then
    echo "Error: Godot not found at $GODOT"
    exit 1
fi

# Run Godot with LD_PRELOAD
echo "Starting Solar System Demo..."
echo "Using LD_PRELOAD=$LIBSTDCXX"
echo "Running Godot from: $GODOT"
echo ""

LD_PRELOAD="$LIBSTDCXX" "$GODOT" -e --path "$(dirname "$0")"
