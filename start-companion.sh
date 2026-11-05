#!/bin/sh
set -eu
COMPANION_PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPANION_PYTHON="$COMPANION_PROJECT_DIR/.venv-companion/bin/python"
if [ ! -x "$COMPANION_PYTHON" ]; then
    echo "Create the project environment first:" >&2
    echo "python3 -m venv .venv-companion" >&2
    echo ".venv-companion/bin/python -m pip install -r requirements-companion.txt" >&2
    exit 1
fi
if [ "$#" -eq 0 ]; then
    set -- serve
fi
exec "$COMPANION_PYTHON" "$COMPANION_PROJECT_DIR/companion.py" "$@"
