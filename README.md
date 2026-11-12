# MySQL Auto Optimize

OPTIMIZE only the tables that actually need it. InnoDB tables accumulate free space (`Data_free`) after deletes and updates; rebuilding every table on a schedule wastes I/O and locks. This script finds the tables whose free space passes **both** thresholds and optimizes just those.

## Usage

```bash
# One database, defaults: >= 10 MB free and >= 10% of table size
./optimize-tables.sh --database wordpress

# Every non-system database, preview only
./optimize-tables.sh --all --dry-run

# Stricter thresholds, skip two tables, machine-readable output
./optimize-tables.sh --all --min-free-mb 50 --min-free-pct 20 \
  --exclude 'wp_options,wp_posts' --json
```

## Options

| Option | Description |
| --- | --- |
| `--database NAME` | Optimize tables in one database (repeatable). |
| `--all` | Optimize tables in every non-system database. |
| `--min-free-mb N` | Minimum `Data_free` in MB (default 10). |
| `--min-free-pct N` | Minimum `Data_free` as % of (data + index) size (default 10). |
| `--exclude LIST` | Comma-separated `db.table` names to skip. |
| `--dry-run` | List what would be optimized, change nothing. |
| `--json` | Machine-readable output. |
| `--quiet` | Only print errors. |
| `--host/--user/--password/--socket` | Passed through to the `mysql` client. |

## Exit codes

- `0` — ok, or nothing to do.
- `1` — usage or connection error.
- `2` — at least one OPTIMIZE failed.

## Credentials

Reads `~/.my.cnf` by default (the `mysql` client's default). Prefer that over `--password` on the command line, or use the `MYSQL_PWD` environment variable.

## Scheduling

```cron
# Weekly on Sundays at 03:30, email only on failure
30 3 * * 0 /path/to/optimize-tables.sh --all --quiet || mail -s "MySQL optimize failed" admin@example.com
```
