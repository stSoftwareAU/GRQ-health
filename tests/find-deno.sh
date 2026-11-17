#!/bin/bash
# Resolve the Deno binary used by the JS-backed tests (Issue #198).
#
# Resolution order:
#   1. $DENO, if the caller already set it (explicit override)
#   2. `deno` on PATH (e.g. /usr/local/bin/deno in the Vibe Coder container)
#   3. $HOME/.deno/bin/deno, where the official installer puts it
#
# Sourced by every test that needs Deno. Fails loud with one clear message when
# nothing usable resolves, instead of letting each test die on a bare
# "No such file or directory" from the shell.

if [ -z "${DENO:-}" ]; then
    DENO="$(command -v deno 2>/dev/null || true)"
    if [ -z "$DENO" ]; then
        DENO="$HOME/.deno/bin/deno"
    fi
fi

if [ ! -x "$DENO" ]; then
    echo "  FAIL: deno not found (looked at \$DENO, PATH, and $HOME/.deno/bin/deno)." >&2
    echo "        Install Deno (https://deno.land), add it to PATH, or set DENO=/path/to/deno." >&2
    exit 1
fi

export DENO
