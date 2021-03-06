#!/bin/bash

set -exo pipefail

if [[ -z "$ROOT" ]]; then
    echo "\$ROOT not set"
    exit 1
fi

# sqlite3
git clone --depth 1 -b sqlite_src --single-branch https://github.com/joakim-brannstrom/dextool.git sqlite_src
