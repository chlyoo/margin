#!/bin/bash
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
bundle="$(dirname "$native_dir")/build/Margin.app"
if [[ ! -x "$bundle/Contents/MacOS/Margin" ]]; then
  bash "$native_dir/build.sh"
fi
open "$bundle"
