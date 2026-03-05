# Binance Public Data Downloader

Interactive Binance public data downloader. Single bash script that downloads from [data.binance.vision](https://data.binance.vision/) via a step-by-step TUI.

## Getting Started

```bash
git clone https://github.com/gcoban/binance-public-data-downloader.git
cd binance-public-data-downloader
./download.sh
ls ./downloads/   # merged CSV files are saved here
```

That's it. The script walks you through each step: pick a market, choose a data type, select trading pairs, set your date range, and start downloading. You can optionally convert Unix epoch timestamps to human-readable UTC (`YYYY-MM-DD HH:MM:SS`). No configuration or API keys needed.

## How It Works

1. **Select parameters** — pick a market, data type, trading pairs, intervals, and date range
2. **Smart date splitting** — uses monthly archives for complete months, daily for partial months at range edges (12 requests/year instead of 365)
3. **Parallel downloads** — up to 5 concurrent downloads with retry logic and SHA-256 checksum verification; archives are cached in `./caches/` and reused across runs
4. **Merge & convert** — extracts CSVs, concatenates in date order, optionally converts timestamps to human-readable UTC, writes final output with header row

## CLI Reference

```bash
./download.sh <market> <dtype> <symbols> <timeframe> <start_date> <end_date> <ts_convert> [--output_dir <path>] [--silent]
```

### Parameters

**`market`** — one of: `spot`, `usdm`, `coinm`, `option`

**`dtype`** — data type (depends on market):

| Market | Valid data types |
|--------|-----------------|
| `spot` | `klines`, `trades`, `aggTrades` |
| `usdm` | `klines`, `trades`, `aggTrades`, `bookTicker`, `fundingRate`, `markPriceKlines`, `indexPriceKlines`, `premiumIndexKlines` |
| `coinm` | `klines`, `trades`, `aggTrades`, `bookTicker`, `fundingRate`, `markPriceKlines`, `indexPriceKlines`, `premiumIndexKlines`, `bookDepth`, `liquidationSnapshot`, `metrics` |
| `option` | `BVOLIndex`, `EOHSummary` |

**`symbols`** — one or more trading pair symbols, comma-separated, no spaces:
- Spot / USD-M: `BTCUSDT`, `ETHUSDT`, `BTCUSDT,ETHUSDT`
- COIN-M: `BTCUSD_PERP`, `ETHUSD_PERP`, `BTCUSD_PERP,ETHUSD_PERP`
- Options: `BTCBVOLUSDT` (BVOLIndex), `BTCUSDT` (EOHSummary)

**`timeframe`** — kline timeframe or `-` for non-kline data types:
- **Requires timeframe:** `klines`, `markPriceKlines`, `indexPriceKlines`, `premiumIndexKlines`
  - Valid values: `1s` `1m` `3m` `5m` `15m` `30m` `1h` `2h` `4h` `6h` `8h` `12h` `1d` `3d` `1w` `1mo`
- **Use `-`:** `trades`, `aggTrades`, `bookTicker`, `fundingRate`, `bookDepth`, `liquidationSnapshot`, `metrics`, `BVOLIndex`, `EOHSummary`

**`start_date`** / **`end_date`** — date range in `YYYY-MM-DD` format (e.g. `2025-01-01`)

**`ts_convert`** — timestamp conversion: `all`, `none`, or comma-separated column names (e.g. `open_time,close_time`):

| Data type | Timestamp columns |
|-----------|-------------------|
| `klines`, `markPriceKlines`, `indexPriceKlines`, `premiumIndexKlines` | `open_time`, `close_time` |
| `trades` | `time` |
| `aggTrades` | `transact_time` |
| `bookTicker` | `transaction_time`, `event_time` |
| `fundingRate`, `BVOLIndex` | `calc_time` |
| `liquidationSnapshot` | `time` |

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--output_dir <path>` | `./downloads` | Output directory for merged CSV files |
| `--silent`, `-s` | | Suppress all progress output |

### Examples

```bash
# Convert all timestamp columns
./download.sh spot klines BTCUSDT 1h 2025-01-10 2025-01-12 all

# No timestamp conversion
./download.sh spot trades BTCUSDT - 2025-01-10 2025-01-10 none

# Convert only specific columns
./download.sh spot klines BTCUSDT 1h 2025-01-10 2025-01-12 open_time

# Multiple symbols
./download.sh spot klines BTCUSDT,ETHUSDT 1h 2025-01-10 2025-01-12 all

# USD-M futures funding rate
./download.sh usdm fundingRate BTCUSDT - 2024-12-01 2024-12-31 all

# COIN-M futures perpetuals
./download.sh coinm klines BTCUSD_PERP,ETHUSD_PERP 1h 2025-01-10 2025-01-12 none

# Options BVOLIndex
./download.sh option BVOLIndex BTCBVOLUSDT - 2025-01-01 2025-01-02 all

# Custom output directory
./download.sh spot klines BTCUSDT 1h 2025-01-10 2025-01-12 all --output_dir /data/binance

# Silent mode (no progress output)
./download.sh spot klines BTCUSDT 1d 2025-01-01 2025-01-31 none --silent
```

### Output

Files are saved to `./downloads/` (or the specified `output_dir`):

```
{SYMBOL}-{DTYPE}-{INTERVAL}-{START}_{END}.csv     # kline types
{SYMBOL}-{DTYPE}-{START}_{END}.csv                 # non-kline types
```

## Directory Structure

| Directory | Purpose | Persistent |
|-----------|---------|------------|
| `./downloads/` | Merged output CSV files | Yes (created on each run) |
| `./caches/` | Downloaded .zip archives, organized by market/dtype/symbol | Yes (never deleted, reused across runs) |
| `./tests/` | Test output CSVs, one subdirectory per test case | Yes (reused for fast consecutive test runs) |

## Platform

macOS (Bash 3.2+, BSD date) and Linux (GNU date). Windows requires WSL.

## Dependencies

`curl`, `unzip`, `perl`, `shasum` or `sha256sum`

## Testing

```bash
./test.sh
```

Runs 24 test cases in parallel (up to 5 concurrent) across all markets and data types. Each test downloads data via CLI mode and validates the output CSV: column count consistency, row count (for klines), and timestamp spacing.

Results are displayed in a live-updating table:

```
 ╔══════════════════════════════╗
 ║    Integration Test Suite    ║
 ╚══════════════════════════════╝

 24 pass  0 fail  0 skip  1.5G
 ##############################  100%  24/24

 +----+--------+--------+----------------------+-------------+----+------------+------------+---------+------+--------+
 | #  | Status | Market | Data Type            | Symbol      | TF | Start      | End        |    Rows | Cols |   Size |
 | 1  | PASS   | spot   | klines               | BTCUSDT     | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |  10.4K |
 | 2  | PASS   | spot   | trades               | BTCUSDT     |    | 2025-01-01 | 2025-01-02 | 5085635 |    7 | 368.9M |
 | 3  | PASS   | spot   | aggTrades            | BTCUSDT     |    | 2025-01-01 | 2025-01-02 | 1952650 |    8 | 161.0M |
 | 4  | PASS   | usdm   | klines               | BTCUSDT     | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |   7.9K |
 | 5  | PASS   | usdm   | trades               | BTCUSDT     |    | 2025-01-01 | 2025-01-02 | 5290247 |    6 | 269.5M |
 | 6  | PASS   | usdm   | aggTrades            | BTCUSDT     |    | 2025-01-01 | 2025-01-02 | 2231859 |    7 | 141.3M |
 | 7  | PASS   | usdm   | bookTicker           | BTCUSDT     |    | 2023-05-16 | 2023-05-16 | 4494018 |    7 | 406.0M |
 | 8  | PASS   | usdm   | fundingRate          | BTCUSDT     |    | 2025-01-01 | 2025-02-28 |     177 |    3 |   4.7K |
 | 9  | PASS   | usdm   | markPriceKlines      | BTCUSDT     | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |   6.0K |
 | 10 | PASS   | usdm   | indexPriceKlines     | BTCUSDT     | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |   6.3K |
 | 11 | PASS   | usdm   | premiumIndexKlines   | BTCUSDT     | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |   5.4K |
 | 12 | PASS   | coinm  | klines               | BTCUSD_PERP | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |   7.0K |
 | 13 | PASS   | coinm  | trades               | BTCUSD_PERP |    | 2025-01-01 | 2025-01-02 |  530726 |    6 |  26.9M |
 | 14 | PASS   | coinm  | aggTrades            | BTCUSD_PERP |    | 2025-01-01 | 2025-01-02 |  273105 |    7 |  16.2M |
 | 15 | PASS   | coinm  | bookTicker           | BTCUSD_PERP |    | 2023-05-20 | 2023-05-20 | 2004857 |    7 | 188.9M |
 | 16 | PASS   | coinm  | fundingRate          | BTCUSD_PERP |    | 2025-01-01 | 2025-02-28 |     173 |    3 |   4.6K |
 | 17 | PASS   | coinm  | markPriceKlines      | BTCUSD_PERP | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |   6.1K |
 | 18 | PASS   | coinm  | indexPriceKlines     | BTCUSD      | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |   6.3K |
 | 19 | PASS   | coinm  | premiumIndexKlines   | BTCUSD_PERP | 1d | 2025-01-01 | 2025-03-02 |      61 |   12 |   5.5K |
 | 20 | PASS   | coinm  | bookDepth            | BTCUSD_PERP |    | 2025-01-01 | 2025-01-02 |   57600 |    4 |   2.9M |
 | 21 | PASS   | coinm  | liquidationSnapshot  | BTCUSD_PERP |    | 2024-06-15 | 2024-06-16 |      48 |   10 |   2.9K |
 | 22 | PASS   | coinm  | metrics              | BTCUSD_PERP |    | 2025-01-01 | 2025-01-02 |     576 |    8 |  44.6K |
 | 23 | PASS   | option | BVOLIndex            | BTCBVOLUSDT |    | 2025-01-01 | 2025-01-02 |  172789 |    5 |   7.7M |
 | 24 | PASS   | option | EOHSummary           | BTCUSDT     |    | 2023-07-10 | 2023-07-11 |   11680 |   26 |   3.0M |
 +----+--------+--------+----------------------+-------------+----+------------+------------+---------+------+--------+
 Done.  Total data: 1.5G
```

**Caching:** Test results are cached in `./tests/` and `./caches/`. Consecutive runs skip downloads and merging, only re-validating output CSVs. Delete `./tests/` to force re-merge from cached archives. Delete `./caches/` to force full re-download.

## Issues

Report bugs and feature requests at [github.com/gcoban/binance-public-data-downloader/issues](https://github.com/gcoban/binance-public-data-downloader/issues)

## Sources

- [data.binance.vision](https://data.binance.vision/)
- [binance/binance-public-data GitHub](https://github.com/binance/binance-public-data)
