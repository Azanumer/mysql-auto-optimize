#!/usr/bin/env bash
# mysql-auto-optimize — OPTIMIZE TABLE only the tables that actually need it.
#
# InnoDB tables accumulate free space (Data_free) after deletes and updates.
# OPTIMIZE TABLE rebuilds the table, but rebuilding everything on a schedule
# wastes I/O and locks. This script finds only the tables whose free space
# passes both thresholds and optimizes just those.
#
# Credentials: reads ~/.my.cnf by default (mysql CLI default), or use
# --host/--user/--password/--socket. Never pass a password on the command
# line in production — prefer ~/.my.cnf or the MYSQL_PWD env var.
#
# Usage:
#   optimize-tables.sh --database wordpress [--min-free-mb 10] [--min-free-pct 10]
#   optimize-tables.sh --all --dry-run
#   optimize-tables.sh --all --json --exclude 'wp_options,wp_posts'
#
# Exit codes: 0 = ok (or nothing to do), 1 = usage/connection error,
#             2 = at least one OPTIMIZE failed.

set -euo pipefail

PROG="$(basename "$0")"

DATABASE=""
ALL=0
MIN_FREE_MB=10
MIN_FREE_PCT=10
DRY_RUN=0
JSON=0
QUIET=0
EXCLUDE=""
MYSQL_ARGS=()

usage() {
    cat <<EOF
Usage: $PROG --database NAME | --all [options]

Options:
  --database NAME     Optimize tables in one database (repeatable).
  --all               Optimize tables in every non-system database.
  --min-free-mb N     Minimum Data_free in MB to consider a table (default: 10).
  --min-free-pct N    Minimum Data_free as % of (data + index) size (default: 10).
  --exclude LIST      Comma-separated db.table names to skip.
  --dry-run           List what would be optimized, change nothing.
  --json              Machine-readable output.
  --quiet             Only print errors.
  --host HOST --user USER --password PASS --socket PATH
                      Passed through to the mysql client.
  -h, --help          Show this help.
EOF
    exit "${1:-0}"
}

log() {
    if [ "$QUIET" -eq 0 ]; then
        printf '%s\n' "$*"
    fi
}

err() {
    printf '%s: %s\n' "$PROG" "$*" >&2
}

# --- argument parsing -------------------------------------------------------
DATABASES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --database)  [ $# -ge 2 ] || { err "--database needs a value"; exit 1; }; DATABASES+=("$2"); shift 2;;
        --database=*) DATABASES+=("${1#--database=}"); shift;;
        --all)       ALL=1; shift;;
        --min-free-mb)   [ $# -ge 2 ] || { err "--min-free-mb needs a value"; exit 1; }; MIN_FREE_MB="$2"; shift 2;;
        --min-free-mb=*) MIN_FREE_MB="${1#--min-free-mb=}"; shift;;
        --min-free-pct)  [ $# -ge 2 ] || { err "--min-free-pct needs a value"; exit 1; }; MIN_FREE_PCT="$2"; shift 2;;
        --min-free-pct=*) MIN_FREE_PCT="${1#--min-free-pct=}"; shift;;
        --exclude)   [ $# -ge 2 ] || { err "--exclude needs a value"; exit 1; }; EXCLUDE="$2"; shift 2;;
        --exclude=*) EXCLUDE="${1#--exclude=}"; shift;;
        --dry-run)   DRY_RUN=1; shift;;
        --json)      JSON=1; shift;;
        --quiet)     QUIET=1; shift;;
        --host)      [ $# -ge 2 ] || { err "--host needs a value"; exit 1; }; MYSQL_ARGS+=(--host "$2"); shift 2;;
        --host=*)    MYSQL_ARGS+=(--host "${1#--host=}"); shift;;
        --user)      [ $# -ge 2 ] || { err "--user needs a value"; exit 1; }; MYSQL_ARGS+=(--user "$2"); shift 2;;
        --user=*)    MYSQL_ARGS+=(--user "${1#--user=}"); shift;;
        --password)  [ $# -ge 2 ] || { err "--password needs a value"; exit 1; }; MYSQL_ARGS+=(--password="$2"); shift 2;;
        --password=*) MYSQL_ARGS+=(--password="${1#--password=}"); shift;;
        --socket)    [ $# -ge 2 ] || { err "--socket needs a value"; exit 1; }; MYSQL_ARGS+=(--socket "$2"); shift 2;;
        --socket=*)  MYSQL_ARGS+=(--socket "${1#--socket=}"); shift;;
        -h|--help)   usage 0;;
        *)           err "unknown option: $1"; usage 1;;
    esac
done

case "$MIN_FREE_MB" in ''|*[!0-9]*) err "--min-free-mb must be a non-negative integer"; exit 1;; esac
case "$MIN_FREE_PCT" in ''|*[!0-9]*) err "--min-free-pct must be a non-negative integer"; exit 1;; esac
if [ "$ALL" -eq 0 ] && [ "${#DATABASES[@]}" -eq 0 ]; then
    err "specify --database NAME (repeatable) or --all"
    usage 1
fi
if [ "$ALL" -eq 1 ] && [ "${#DATABASES[@]}" -gt 0 ]; then
    err "--all and --database cannot be combined"
    exit 1
fi

# --- candidate selection ----------------------------------------------------
# One query: tables whose free space is both >= N MB and >= P% of their size.
# System schemas are always excluded; user exclusions are applied in bash
# (safer than interpolating a list into SQL).
read -r -d '' QUERY <<'SQL' || true
SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME), DATA_FREE
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema','sys')
  AND ENGINE IN ('InnoDB','MyISAM')
  AND DATA_FREE >= %d * 1024 * 1024
  AND DATA_FREE * 100 >= %d * (DATA_LENGTH + INDEX_LENGTH)
SQL

if [ "$ALL" -eq 1 ]; then
    DB_FILTER=""
else
    # Build a safe IN (...) list from validated identifiers.
    IN_LIST=""
    for db in "${DATABASES[@]}"; do
        case "$db" in
            *\'*|*\"*|*\`*|*\;*|*\\*) err "invalid database name: $db"; exit 1;;
        esac
        [ -n "$IN_LIST" ] && IN_LIST="$IN_LIST,"
        IN_LIST="$IN_LIST'$db'"
    done
    DB_FILTER=" AND TABLE_SCHEMA IN ($IN_LIST)"
fi

SQL_QUERY="$(printf "$QUERY" "$MIN_FREE_MB" "$MIN_FREE_PCT")$DB_FILTER ORDER BY DATA_FREE DESC;"

if ! CANDIDATES="$(mysql "${MYSQL_ARGS[@]}" -N -B -e "$SQL_QUERY" 2>/tmp/mysql-auto-optimize.err)"; then
    err "could not query information_schema:"
    sed 's/^/  /' /tmp/mysql-auto-optimize.err >&2
    rm -f /tmp/mysql-auto-optimize.err
    exit 1
fi
rm -f /tmp/mysql-auto-optimize.err

# --- apply exclusions -------------------------------------------------------
is_excluded() {
    local target="$1"
    [ -z "$EXCLUDE" ] && return 1
    local IFS=',' item
    for item in $EXCLUDE; do
        [ "$item" = "$target" ] && return 0
    done
    return 1
}

# --- run --------------------------------------------------------------------
OPTIMIZED=0
FAILED=0
SKIPPED=0
declare -a RESULTS=()

while IFS=$'\t' read -r table free_bytes; do
    [ -z "$table" ] && continue
    if is_excluded "$table"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        RESULTS+=("{\"table\":\"$table\",\"data_free_bytes\":$free_bytes,\"action\":\"would_optimize\"}")
        log "would optimize $table (Data_free: $((free_bytes / 1024 / 1024)) MB)"
        OPTIMIZED=$((OPTIMIZED + 1))
        continue
    fi
    # Quote db and table separately; both come from information_schema, so
    # backtick-escaping is sufficient.
    db="${table%%.*}"; tbl="${table#*.}"
    if mysql "${MYSQL_ARGS[@]}" -N -B -e "OPTIMIZE TABLE \`$db\`.\`$tbl\`;" >/dev/null 2>/tmp/mysql-auto-optimize.err; then
        RESULTS+=("{\"table\":\"$table\",\"data_free_bytes\":$free_bytes,\"action\":\"optimized\"}")
        log "optimized $table (freed ~$((free_bytes / 1024 / 1024)) MB)"
        OPTIMIZED=$((OPTIMIZED + 1))
    else
        RESULTS+=("{\"table\":\"$table\",\"data_free_bytes\":$free_bytes,\"action\":\"failed\"}")
        err "OPTIMIZE failed for $table:"
        sed 's/^/  /' /tmp/mysql-auto-optimize.err >&2
        FAILED=$((FAILED + 1))
    fi
    rm -f /tmp/mysql-auto-optimize.err
done <<< "$CANDIDATES"

# --- report -----------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
    printf '{"optimized":%d,"failed":%d,"skipped":%d,"dry_run":%s,"tables":[' \
        "$OPTIMIZED" "$FAILED" "$SKIPPED" "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)"
    first=1
    for r in "${RESULTS[@]}"; do
        [ "$first" -eq 1 ] && first=0 || printf ','
        printf '%s' "$r"
    done
    printf ']}\n'
else
    log "done: $OPTIMIZED optimized, $FAILED failed, $SKIPPED skipped."
fi

[ "$FAILED" -gt 0 ] && exit 2
exit 0
