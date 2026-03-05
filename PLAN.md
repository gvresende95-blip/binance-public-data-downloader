# Implementation Plan

Single bash script (`download.sh`) that interactively downloads historical market data from `data.binance.vision`. Plus a parallel integration test suite (`test.sh`).

## download.sh

**Architecture — 9 sections in one file:**

1. **Constants & Configuration** — base URL (`https://data.binance.vision/data`), cache dir (`./caches`), output dir (`./downloads`), kline intervals, concurrency limits
2. **Color & TUI Primitives** — tput colors with ANSI fallback, keypress reader (`read_key`), cursor helpers (`cursor_up`, `clear_lines`)
3. **TUI Widgets** — `single_select`, `multi_select`, `text_input`, `date_input` (all read from `/dev/tty`)
4. **Date Utilities** — BSD/GNU date abstraction, smart monthly/daily split (monthly archives where possible, daily for partial months at boundaries)
5. **URL Construction** — build download URLs and cache paths from market/dtype/symbol/interval
6. **Download Engine** — parallel downloads via FIFO semaphore (up to 5 concurrent), retries (up to 3), SHA-256 checksum verification, progress bar
7. **Merge Engine** — extract cached zips, optionally convert epoch timestamps to human-readable UTC, write CSV with header
8. **Interactive Flow** — step-by-step TUI: market → dtype → symbols → intervals → dates → timestamp conversion → confirm → download → merge
9. **Main Entry Point** — dependency check, TTY check, CLI arg detection, launch interactive or CLI flow

**Constraints:** Bash 3.2+ (macOS default), BSD date with GNU fallback, no jq, no associative arrays, no `readarray`, no `coproc`.

### Supported Markets & Data Types

| Market | Path | Data Types |
|--------|------|------------|
| Spot | `spot` | klines, trades, aggTrades |
| USD-M Futures | `futures/um` | klines, trades, aggTrades, bookTicker, fundingRate, markPriceKlines, indexPriceKlines, premiumIndexKlines |
| COIN-M Futures | `futures/cm` | klines, trades, aggTrades, bookTicker, fundingRate, markPriceKlines, indexPriceKlines, premiumIndexKlines, bookDepth, liquidationSnapshot, metrics |
| Options | `option` | BVOLIndex, EOHSummary |

**Kline intervals:** `1s 1m 3m 5m 15m 30m 1h 2h 4h 6h 8h 12h 1d 3d 1w 1mo`

### Archive Availability Filters

Not all data types have both monthly and daily archives. The date-splitting logic must enforce:

- `fundingRate`: monthly archives only (no daily)
- `bookTicker`, `bookDepth`, `liquidationSnapshot`, `metrics`: daily archives only (no monthly)
- `option` market (all types): daily archives only (no monthly)

### CSV Headers by Data Type

| Data Type | Columns |
|-----------|---------|
| Klines (all markets) | open_time, open, high, low, close, volume, close_time, quote_volume, trades, taker_buy_base_volume, taker_buy_quote_volume, ignore |
| Spot trades | id, price, qty, quoteQty, time, isBuyerMaker, isBestMatch |
| Spot aggTrades | agg_tradeId, price, qty, first_tradeId, last_tradeId, transact_time, is_buyer_maker, is_best_match |
| Futures trades | id, price, qty, quoteQty, time, isBuyerMaker |
| Futures aggTrades | agg_tradeId, price, qty, first_tradeId, last_tradeId, transact_time, is_buyer_maker |
| BVOLIndex | calc_time, symbol, base_asset, quote_asset, index_value |
| EOHSummary | date, hour, symbol, underlying, type, strike, open, high, low, close, ... |

### COIN-M Filename Differences

COIN-M `markPriceKlines`, `indexPriceKlines`, and `premiumIndexKlines` use different filename patterns than USD-M. The URL construction must handle this.

### Smart Monthly/Daily Split

Uses monthly archives wherever possible to minimize HTTP requests (12/year vs 365/year). Partial months at range boundaries use daily archives. Example: 2025-01-10 to 2025-03-15 → daily for Jan 10-31, monthly for Feb, daily for Mar 1-15.

### CLI Mode

Non-interactive interface for scripting:

```
./download.sh <market> <dtype> <symbols> <timeframe> <start_date> <end_date> <ts_convert> [--output_dir <path>] [--silent]
```

- Positional args: market (`spot`/`usdm`/`coinm`/`option`), dtype, symbols (comma-separated), timeframe (`-` for non-kline types), start_date, end_date, ts_convert (`all`, `none`, or column names)
- Options: `--output_dir <path>` (default: `./downloads`), `--silent` / `-s` (suppress progress output)
- If >= 7 args: skip TUI, run pipeline directly via `run_cli()`

### Output

```
./downloads/{SYM}-{DTYPE}-{INT}-{START}_{END}.csv     # kline types
./downloads/{SYM}-{DTYPE}-{START}_{END}.csv            # non-kline types
```

Merged CSV with header row. Timestamps are optionally converted to human-readable UTC (`YYYY-MM-DD HH:MM:SS`).

### Signal Handling

Ctrl+C cleanup uses `jobs -p | xargs kill` (not `kill 0`, which causes segfault by signaling the shell itself).

## test.sh

Parallel integration test suite with live-updating table display.

### Test Registry

24 test cases across all markets and data types, defined as parallel indexed arrays (Bash 3.2 compatible):

```bash
T_MARKET[i]  T_DTYPE[i]  T_SYMBOL[i]  T_INT[i]  T_START[i]  T_END[i]  T_INTSEC[i]  T_EXPROWS[i]
```

Runtime state arrays: `T_STATUS[i]`, `T_ROWS[i]`, `T_COLS[i]`, `T_SIZE[i]`, `T_PID[i]`

### Concurrency Model

- `MAX_PARALLEL=5` concurrent test workers
- Each worker is a background shell function that:
  1. Creates its own output dir: `./tests/{N}/`
  2. Runs `./download.sh ... none --output_dir "$outdir" --silent`
  3. Validates the output CSV
  4. Writes result to `$RESULTS_DIR/$idx` (format: `STATUS:ROWS:COLS:SIZE:DETAIL`)
- Main loop polls result files every 0.3s, redraws table, launches new workers as slots free up
- Workers clear parent's EXIT trap (`trap - EXIT`) to prevent premature cleanup of shared directories
- Workers trap INT/TERM to `exit 130` silently

### Live Table Display

```
 ╔══════════════════════════════╗
 ║    Integration Test Suite    ║
 ╚══════════════════════════════╝

 24 pass  0 fail  0 skip  1.5G
 ##############################  100%  24/24

 +----+--------+--------+----------------------+-------------+----+------------+------------+---------+------+--------+
 | #  | Status | Market | Data Type            | Symbol      | TF | Start      | End        |    Rows | Cols |   Size |
 +----+--------+--------+----------------------+-------------+----+------------+------------+---------+------+--------+
 | 1  | PASS   | spot   | klines               | BTCUSDT     | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |  10.4K |
 ...
 +----+--------+--------+----------------------+-------------+----+------------+------------+---------+------+--------+
 Done.  Total data: 1.5G
```

Status icons: `..` (dim/pending), `>>` (cyan/running), `PASS` (green), `FAIL` (red), `SKIP` (yellow)

Table redraws in-place using cursor-up escape codes (`\e[A`) with `\e[K` (clear to end of line) on every line.

### Validations per Output CSV

1. Header column count == data column count (checks first 5000 rows)
2. Row count matches expected (for klines: computed from date range)
3. First-column timestamp spacing is consistent (for klines: interval in seconds)

### Three-Tier Caching

1. **Fastest** — `./tests/{N}/` output CSV exists: skip download+merge, only re-validate
2. **Medium** — `./caches/` has zip archives: skip download, re-merge and validate
3. **Slowest** — first run: full download + merge + validate

Delete `./tests/` to force re-merge. Delete `./caches/` to force full re-download.

### Signal Handling

Cleanup function on EXIT/INT/TERM:
1. Restore cursor visibility
2. `jobs -p | xargs kill` to stop workers
3. Wait 0.2s, then `kill -9` any remaining
4. Clean up temp results dir (but preserve `./tests/` and `./caches/`)
