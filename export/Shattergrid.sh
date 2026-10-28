#!/bin/sh
printf '\033c\033]0;%s\a' Shattergrid
base_path="$(dirname "$(realpath "$0")")"
"$base_path/Shattergrid.x86_64" "$@"
