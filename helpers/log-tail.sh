#!/bin/bash
# Log tail helpers (Issue #211). Sourced by run.sh.
#
# run.sh used to `cp` the whole host log (up to ~8 MB) into docs/<HOST>/ on
# every heartbeat, and git kept every version forever: ~865 MB of history for
# a 32 MB tree. Nobody needs the history of a log, and the dashboard only
# needs the recent end of it, so we publish a small bounded tail instead.
# The full log stays on the host under ~/logs/.
#
# Exposes:
#   grq_log_tail_bytes   — echoes the maximum number of bytes published
#                          (default 65536 = 64 KB). Override via
#                          GRQ_LOG_TAIL_BYTES; a non-numeric or zero value
#                          falls back to the default.
#   grq_copy_log_tail    — grq_copy_log_tail <src> <dest>
#                          Writes at most grq_log_tail_bytes of the end of
#                          <src> to <dest>. A log that already fits is copied
#                          verbatim. A truncated tail starts on a line
#                          boundary and is prefixed with a one-line marker so
#                          a reader knows earlier output was dropped. The
#                          write is atomic (temp file + mv). Returns non-zero
#                          when <src> is missing or the write fails; <dest>
#                          is then left untouched.

GRQ_LOG_TAIL_BYTES_DEFAULT=65536

grq_log_tail_bytes() {
    local bytes="${GRQ_LOG_TAIL_BYTES:-$GRQ_LOG_TAIL_BYTES_DEFAULT}"
    case "$bytes" in
        ''|*[!0-9]*) bytes="$GRQ_LOG_TAIL_BYTES_DEFAULT" ;;
    esac
    if [ "$bytes" -le 0 ]; then
        bytes="$GRQ_LOG_TAIL_BYTES_DEFAULT"
    fi
    echo "$bytes"
}

grq_copy_log_tail() {
    local src="$1"
    local dest="$2"

    if [ ! -f "$src" ]; then
        return 1
    fi

    local limit size tmp
    limit=$(grq_log_tail_bytes)
    size=$(wc -c < "$src" | tr -d '[:space:]')
    tmp="${dest}.tmp.$$"

    if [ "$size" -le "$limit" ]; then
        cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
    else
        {
            echo "[log truncated by run.sh: showing the last $((limit / 1024)) KB of $((size / 1024)) KB; the full log is on the host]"
            # tail -c usually lands mid-line (and possibly mid-UTF-8
            # character): drop that first partial line. A tail with no
            # newline at all (one enormous line) is kept as is.
            tail -c "$limit" "$src" | awk 'NR == 1 { first = $0; next } { print } END { if (NR == 1) print first }'
        } > "$tmp" || { rm -f "$tmp"; return 1; }
    fi

    mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}
