# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

binance-public-data-downloader — interactive Binance public data downloader. Single bash script that downloads from `data.binance.vision` via a step-by-step TUI.

## Usage

```bash
./download.sh                                                  # interactive
./download.sh spot klines BTCUSDT 1h 2025-01-10 2025-01-12 all    # CLI mode
```

Interactive steps:

1. Market (Spot, USD-M Futures, COIN-M Futures, Option)
2. Data type (Klines, Trades, AggTrades, etc.)
3. Trading pairs (comma-separated text input)
4. Timeframes (multi-select, for interval-based types)
5. Start date
6. End date
7. Timestamp conversion (multi-select, none selected by default)
8. Summary + confirm → download → merge

CLI positional args: `market dtype symbols timeframe start_date end_date ts_convert [--output_dir <path>] [--silent]`
- `symbols`: comma-separated (e.g. `BTCUSDT,ETHUSDT`)
- `timeframe`: pass `-` for non-kline data types
- Dates: `YYYY-MM-DD`
- `ts_convert`: `all`, `none`, or comma-separated column names (e.g. `open_time,close_time`)
- `--output_dir <path>`: optional, defaults to `./downloads`
- `--silent` / `-s`: suppress all progress output

At any step, press **Esc** to return to the previous step.

Start/end dates default to earliest available (2017-08-17) and yesterday UTC if left empty.

## Platform

macOS and Linux. Windows requires WSL — native cmd/PowerShell cannot run the script (`/dev/tty`, `mkfifo`, `perl`, `tput`, `shasum` are unavailable).

## Data Source

**Base URL:** `https://data.binance.vision/data`

| Type | URL Pattern |
|------|-------------|
| Klines monthly | `.../spot/monthly/klines/{SYM}/{INT}/{SYM}-{INT}-YYYY-MM.zip` |
| Klines daily | `.../spot/daily/klines/{SYM}/{INT}/{SYM}-{INT}-YYYY-MM-DD.zip` |
| Checksum | Append `.CHECKSUM` to any `.zip` URL |

**Kline intervals:** `1s 1m 3m 5m 15m 30m 1h 2h 4h 6h 8h 12h 1d 3d 1w 1mo`

**Kline CSV columns:** open_time, open, high, low, close, volume, close_time, quote_volume, trades, taker_buy_base_volume, taker_buy_quote_volume, ignore

**Important:** SPOT data from 2025-01-01 uses microsecond timestamps (previously milliseconds). Daily data available next UTC day. Monthly data published first Monday of each month.

## Smart Monthly/Daily Split

Uses monthly archives wherever possible to minimize HTTP requests (12/year vs 365/year). Partial months at range boundaries use daily archives.

**Archive availability filters:**
- `fundingRate`: monthly archives only
- `bookTicker`, `bookDepth`, `liquidationSnapshot`, `metrics`: daily archives only
- `option` market: daily archives only

## Directory Structure

```
./download.sh                           ← main script
./test.sh                               ← parallel integration test suite
./downloads/{SYM}-{DTYPE}-{INT}-{START}_{END}.csv  ← merged output CSVs (kline types)
./downloads/{SYM}-{DTYPE}-{START}_{END}.csv        ← merged output CSVs (non-kline types)
./caches/{market}/{dtype}/{SYM}/{INT}/  ← cached .zip archives (persistent)
./tests/{N}/                            ← test output CSVs (one dir per test case)
```

Output CSVs have a header row. Timestamps are optionally converted to human-readable UTC (`YYYY-MM-DD HH:MM:SS`).

## Dev Conventions

- **Bash 3.2 compatible** — no associative arrays, no `readarray`, no `coproc`
- **BSD date** — use `date -u -j -v` for macOS, with GNU `date -u -d` fallback
- **All dates UTC** — Binance data uses UTC+0; `get_today`/`get_yesterday` use `-u` flag
- All TUI output goes to **stderr**; data/results go to **stdout**
- TUI widgets read keys from `/dev/tty` (works inside `$()` subshells)
- Arrow keys: both CSI (`ESC [ A`) and SS3 (`ESC O A`) sequences
- **Back navigation**: widgets return `__BACK__` sentinel on Esc; `run_interactive` uses a `while/case $step` loop (steps 1–8) and decrements step on `__BACK__`; previous selections are preserved when going back
- Progress tracking: **atomic append-only log** (no flock, works on macOS)
- Progress bar: blank buffer line maintained below it via `\n$UP` after first draw, so it never touches the terminal edge
- Multi-select state: `${var:offset:len}` substring expansion (no subprocess spawning)
- Dependencies: `curl`, `unzip`, `perl`, `shasum`/`sha256sum` — no `jq`

## Testing

```bash
./test.sh
```

24 parallel test cases across all markets and data types. Validates column counts, row counts, and timestamp spacing. Live-updating table shows status, rows, columns, and file sizes.

**Caching:** `./caches/` persists downloaded archives. `./tests/` persists output CSVs. Consecutive runs skip download+merge and only re-validate. Delete `./tests/` to force re-merge. Delete `./caches/` to force full re-download.

## Sources

- [data.binance.vision](https://data.binance.vision/)
- [binance/binance-public-data GitHub](https://github.com/binance/binance-public-data)
