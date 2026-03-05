#!/usr/bin/env bash
# test.sh — Parallel integration test suite with live table display
# Runs download.sh in CLI mode for all market/dtype combos, validates output CSVs.
# Tests run in parallel (up to MAX_PARALLEL) with a live-updating status table.
#
# Usage: ./test.sh
set -uo pipefail

cd "$(dirname "$0")"

MAX_PARALLEL=${MAX_PARALLEL:-5}

# ============================================================================
# TUI Setup
# ============================================================================

if command -v tput >/dev/null 2>&1 && [ -t 2 ]; then
    BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
    GREEN=$(tput setaf 2); CYAN=$(tput setaf 6)
    YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
    WHITE=$(tput setaf 7)
    HIDE_CURSOR=$(tput civis 2>/dev/null || true)
    SHOW_CURSOR=$(tput cnorm 2>/dev/null || true)
else
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
    GREEN=$'\e[32m'; CYAN=$'\e[36m'
    YELLOW=$'\e[33m'; RED=$'\e[31m'
    WHITE=$'\e[37m'
    HIDE_CURSOR=$'\e[?25l'
    SHOW_CURSOR=$'\e[?25h'
fi

RESULTS_DIR=$(mktemp -d /tmp/binance_test_results.XXXXXX)

cleanup() {
    trap - EXIT INT TERM
    printf '%s' "$SHOW_CURSOR" >&2
    jobs -p 2>/dev/null | xargs kill 2>/dev/null
    sleep 0.2
    jobs -p 2>/dev/null | xargs kill -9 2>/dev/null
    wait 2>/dev/null
    rm -rf "$RESULTS_DIR"
    exit
}
trap cleanup EXIT INT TERM
printf '%s' "$HIDE_CURSOR" >&2

# Use project cache (shared, persistent) and per-test output dirs under ./tests
mkdir -p ./caches ./tests

# ============================================================================
# Test Registry (indexed arrays, Bash 3.2 compatible)
# ============================================================================

# Date ranges
KS=2025-01-01  KE=2025-03-02  KROWS=61
DS=2025-01-01  DE=2025-01-02
FS=2025-01-01  FE=2025-02-28
BS=2023-05-16  BE=2023-05-16
LS=2024-06-15  LE=2024-06-16
OS=2023-07-10  OE=2023-07-11

i=0

# Spot
T_MARKET[$i]="spot";  T_DTYPE[$i]="klines";     T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="1d"; T_START[$i]="$KS"; T_END[$i]="$KE"; T_INTSEC[$i]=86400; T_EXPROWS[$i]=$KROWS; i=$((i+1))
T_MARKET[$i]="spot";  T_DTYPE[$i]="trades";      T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="";   T_START[$i]="$DS"; T_END[$i]="$DE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="spot";  T_DTYPE[$i]="aggTrades";   T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="";   T_START[$i]="$DS"; T_END[$i]="$DE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
# USD-M
T_MARKET[$i]="usdm";  T_DTYPE[$i]="klines";              T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="1d"; T_START[$i]="$KS"; T_END[$i]="$KE"; T_INTSEC[$i]=86400; T_EXPROWS[$i]=$KROWS; i=$((i+1))
T_MARKET[$i]="usdm";  T_DTYPE[$i]="trades";               T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="";   T_START[$i]="$DS"; T_END[$i]="$DE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="usdm";  T_DTYPE[$i]="aggTrades";            T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="";   T_START[$i]="$DS"; T_END[$i]="$DE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="usdm";  T_DTYPE[$i]="bookTicker";           T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="";   T_START[$i]="$BS"; T_END[$i]="$BE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="usdm";  T_DTYPE[$i]="fundingRate";          T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="";   T_START[$i]="$FS"; T_END[$i]="$FE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="usdm";  T_DTYPE[$i]="markPriceKlines";     T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="1d"; T_START[$i]="$KS"; T_END[$i]="$KE"; T_INTSEC[$i]=86400; T_EXPROWS[$i]=$KROWS; i=$((i+1))
T_MARKET[$i]="usdm";  T_DTYPE[$i]="indexPriceKlines";    T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="1d"; T_START[$i]="$KS"; T_END[$i]="$KE"; T_INTSEC[$i]=86400; T_EXPROWS[$i]=$KROWS; i=$((i+1))
T_MARKET[$i]="usdm";  T_DTYPE[$i]="premiumIndexKlines";  T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="1d"; T_START[$i]="$KS"; T_END[$i]="$KE"; T_INTSEC[$i]=86400; T_EXPROWS[$i]=$KROWS; i=$((i+1))
# COIN-M
T_MARKET[$i]="coinm";  T_DTYPE[$i]="klines";              T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="1d"; T_START[$i]="$KS"; T_END[$i]="$KE"; T_INTSEC[$i]=86400; T_EXPROWS[$i]=$KROWS; i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="trades";               T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="";   T_START[$i]="$DS"; T_END[$i]="$DE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="aggTrades";            T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="";   T_START[$i]="$DS"; T_END[$i]="$DE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="bookTicker";           T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="";   T_START[$i]="2023-05-20"; T_END[$i]="2023-05-20"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="fundingRate";          T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="";   T_START[$i]="$FS"; T_END[$i]="$FE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="markPriceKlines";     T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="1d"; T_START[$i]="$KS"; T_END[$i]="$KE"; T_INTSEC[$i]=86400; T_EXPROWS[$i]=$KROWS; i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="indexPriceKlines";    T_SYMBOL[$i]="BTCUSD";      T_INT[$i]="1d"; T_START[$i]="$KS"; T_END[$i]="$KE"; T_INTSEC[$i]=86400; T_EXPROWS[$i]=$KROWS; i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="premiumIndexKlines";  T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="1d"; T_START[$i]="$KS"; T_END[$i]="$KE"; T_INTSEC[$i]=86400; T_EXPROWS[$i]=$KROWS; i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="bookDepth";            T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="";   T_START[$i]="$DS"; T_END[$i]="$DE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="liquidationSnapshot"; T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="";   T_START[$i]="$LS"; T_END[$i]="$LE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="coinm";  T_DTYPE[$i]="metrics";              T_SYMBOL[$i]="BTCUSD_PERP"; T_INT[$i]="";   T_START[$i]="$DS"; T_END[$i]="$DE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
# Option
T_MARKET[$i]="option"; T_DTYPE[$i]="BVOLIndex";           T_SYMBOL[$i]="BTCBVOLUSDT"; T_INT[$i]="";   T_START[$i]="$DS"; T_END[$i]="$DE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))
T_MARKET[$i]="option"; T_DTYPE[$i]="EOHSummary";          T_SYMBOL[$i]="BTCUSDT";     T_INT[$i]="";   T_START[$i]="$OS"; T_END[$i]="$OE"; T_INTSEC[$i]=0;     T_EXPROWS[$i]=0;      i=$((i+1))

TOTAL=$i

# Runtime state arrays
n=0
while [ $n -lt "$TOTAL" ]; do
    T_STATUS[$n]="WAIT"
    T_ROWS[$n]=""
    T_COLS[$n]=""
    T_SIZE[$n]=""
    T_DETAIL[$n]=""
    T_PID[$n]=""
    n=$((n+1))
done

PASS=0; FAIL=0; SKIP=0; DONE=0; TOTAL_BYTES=0

# ============================================================================
# Drawing
# ============================================================================

# Repeat a character N times
rep_char() {
    local ch="$1" count="$2" s="" j=0
    while [ $j -lt "$count" ]; do s="${s}${ch}"; j=$((j+1)); done
    printf '%s' "$s"
}

# Right-pad a string to exact width (truncate if over)
pad_r() {
    local str="$1" width="$2"
    local len=${#str}
    if [ $len -ge "$width" ]; then
        printf '%s' "${str:0:$width}"
    else
        printf '%s%*s' "$str" $((width - len)) ""
    fi
}

# Left-pad a string to exact width (truncate if over)
pad_l() {
    local str="$1" width="$2"
    local len=${#str}
    if [ $len -ge "$width" ]; then
        printf '%s' "${str:0:$width}"
    else
        printf '%*s%s' $((width - len)) "" "$str"
    fi
}

# Format bytes as human-readable size (B, KB, MB, GB)
human_size() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        printf '%d.%dG' $((bytes / 1073741824)) $(( (bytes % 1073741824) * 10 / 1073741824 ))
    elif [ "$bytes" -ge 1048576 ]; then
        printf '%d.%dM' $((bytes / 1048576)) $(( (bytes % 1048576) * 10 / 1048576 ))
    elif [ "$bytes" -ge 1024 ]; then
        printf '%d.%dK' $((bytes / 1024)) $(( (bytes % 1024) * 10 / 1024 ))
    else
        printf '%dB' "$bytes"
    fi
}

HEADER_LINES=9   # title box (3) + blank + counters + progress bar + blank + table header + table sep
FOOTER_LINES=1   # table bottom border
TABLE_LINES=$((HEADER_LINES + TOTAL + FOOTER_LINES))

FIRST_DRAW=1

draw_table() {
    # Move cursor up to redraw (skip on first draw)
    if [ "$FIRST_DRAW" -eq 1 ]; then
        FIRST_DRAW=0
    else
        local u=0
        while [ $u -lt "$TABLE_LINES" ]; do
            printf '\e[A' >&2
            u=$((u+1))
        done
    fi

    # ── Title + counters + progress ──
    local pct=0
    [ "$TOTAL" -gt 0 ] && pct=$((DONE * 100 / TOTAL))

    local bar_w=30
    local filled=0
    [ "$TOTAL" -gt 0 ] && filled=$((DONE * bar_w / TOTAL))
    local empty=$((bar_w - filled))
    local bar_fill bar_empty
    bar_fill=$(rep_char '#' "$filled")
    bar_empty=$(rep_char '-' "$empty")

    local fail_c="$DIM" skip_c="$DIM"
    [ "$FAIL" -gt 0 ] && fail_c="$RED$BOLD"
    [ "$SKIP" -gt 0 ] && skip_c="$YELLOW$BOLD"

    local title="Integration Test Suite"
    local tlen=${#title}
    local tpad=4
    local tinner=$((tlen + tpad * 2))
    local tbar=""
    local ti=0
    while [ $ti -lt "$tinner" ]; do tbar="${tbar}═"; ti=$((ti+1)); done
    local tspc=""
    ti=0
    while [ $ti -lt "$tpad" ]; do tspc="${tspc} "; ti=$((ti+1)); done
    printf '\e[K %s%s╔%s╗%s\n' "$CYAN" "$BOLD" "$tbar" "$RESET" >&2
    printf '\e[K %s%s║%s%s%s║%s\n' "$CYAN" "$BOLD" "$tspc" "$title" "$tspc" "$RESET" >&2
    printf '\e[K %s%s╚%s╝%s\n' "$CYAN" "$BOLD" "$tbar" "$RESET" >&2
    printf '\e[K\n' >&2
    local total_h
    total_h=$(human_size "$TOTAL_BYTES")
    printf '\e[K %s%s%d pass%s  %s%d fail%s  %s%d skip%s  %s%s%s\n' \
        "$GREEN" "$BOLD" "$PASS" "$RESET" \
        "$fail_c" "$FAIL" "$RESET" \
        "$skip_c" "$SKIP" "$RESET" \
        "$DIM" "$total_h" "$RESET" >&2
    printf '\e[K %s%s%s%s%s  %3d%%  %d/%d\n' \
        "$GREEN" "$bar_fill" "$DIM" "$bar_empty" "$RESET" \
        "$pct" "$DONE" "$TOTAL" >&2

    # ── Table header ──
    local hsep
    hsep="+----+--------+--------+----------------------+-------------+----+------------+------------+---------+------+--------+"
    printf '\e[K\n' >&2
    printf '\e[K %s\n' "$hsep" >&2
    printf '\e[K | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$(pad_r '#' 2)" "$(pad_r 'Status' 6)" "$(pad_r 'Market' 6)" \
        "$(pad_r 'Data Type' 20)" "$(pad_r 'Symbol' 11)" "$(pad_r 'TF' 2)" \
        "$(pad_r 'Start' 10)" "$(pad_r 'End' 10)" \
        "$(pad_l 'Rows' 7)" "$(pad_r 'Cols' 4)" "$(pad_l 'Size' 6)" >&2

    # ── Test rows ──
    local r=0
    while [ $r -lt "$TOTAL" ]; do
        local num=$((r + 1))
        local status="${T_STATUS[$r]}"
        local market="${T_MARKET[$r]}"
        local dtype="${T_DTYPE[$r]}"
        local symbol="${T_SYMBOL[$r]}"
        local tf="${T_INT[$r]}"
        local start="${T_START[$r]}"
        local end="${T_END[$r]}"
        local rows="${T_ROWS[$r]}"
        local cols="${T_COLS[$r]}"
        local size_bytes="${T_SIZE[$r]}"
        local size_h=""
        [ -n "$size_bytes" ] && [ "$size_bytes" -gt 0 ] 2>/dev/null && size_h=$(human_size "$size_bytes")

        # Status icon with color
        local st_plain st_fmt
        case "$status" in
            WAIT) st_plain="..";   st_fmt="${DIM}..${RESET}"   ;;
            RUN)  st_plain=">>";   st_fmt="${CYAN}${BOLD}>>${RESET}"   ;;
            PASS) st_plain="PASS"; st_fmt="${GREEN}${BOLD}PASS${RESET}" ;;
            FAIL) st_plain="FAIL"; st_fmt="${RED}${BOLD}FAIL${RESET}"   ;;
            SKIP) st_plain="SKIP"; st_fmt="${YELLOW}${BOLD}SKIP${RESET}" ;;
        esac

        # Pad fields
        local num_s market_s dtype_s symbol_s tf_s start_s end_s rows_s cols_s size_s
        num_s=$(pad_r "$num" 2)
        market_s=$(pad_r "$market" 6)
        dtype_s=$(pad_r "$dtype" 20)
        symbol_s=$(pad_r "$symbol" 11)
        tf_s=$(pad_r "$tf" 2)
        start_s=$(pad_r "$start" 10)
        end_s=$(pad_r "$end" 10)
        rows_s=$(pad_l "$rows" 7)
        cols_s=$(pad_l "$cols" 4)
        size_s=$(pad_l "$size_h" 6)

        # Status needs special handling for color codes — pad the plain version
        local st_pad=$((6 - ${#st_plain}))
        local st_suffix=""
        local sp=0
        while [ $sp -lt "$st_pad" ]; do st_suffix="${st_suffix} "; sp=$((sp+1)); done

        printf '\e[K | %s | %s%s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
            "$num_s" "$st_fmt" "$st_suffix" "$market_s" "$dtype_s" \
            "$symbol_s" "$tf_s" "$start_s" "$end_s" "$rows_s" "$cols_s" "$size_s" >&2

        r=$((r+1))
    done

    # ── Bottom border ──
    printf '\e[K %s\n' "$hsep" >&2
}

# ============================================================================
# Worker Function
# ============================================================================

run_worker() {
    trap - EXIT              # Don't inherit parent's cleanup trap
    trap 'exit 130' INT TERM  # Exit silently on interrupt

    local idx="$1"
    local outdir="./tests/$((idx + 1))"
    mkdir -p "$outdir"

    local market="${T_MARKET[$idx]}"
    local dtype="${T_DTYPE[$idx]}"
    local symbol="${T_SYMBOL[$idx]}"
    local interval="${T_INT[$idx]}"
    local start="${T_START[$idx]}"
    local end="${T_END[$idx]}"
    local interval_sec="${T_INTSEC[$idx]}"
    local exp_rows="${T_EXPROWS[$idx]}"

    # Determine expected output filename
    local outname
    case "$dtype" in
        klines) outname="${symbol}-klines-${interval}-${start}_${end}.csv" ;;
        markPriceKlines|indexPriceKlines|premiumIndexKlines)
            outname="${symbol}-${dtype}-${interval}-${start}_${end}.csv" ;;
        *) outname="${symbol}-${dtype}-${start}_${end}.csv" ;;
    esac

    local file="$outdir/$outname"

    # Skip download+merge if output CSV already exists from a previous run
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        rm -f "$RESULTS_DIR/$idx"
        local cli_interval="${interval:--}"
        if ! ./download.sh \
            "$market" "$dtype" "$symbol" "$cli_interval" "$start" "$end" none \
            --output_dir "$outdir" --silent; then
            echo "SKIP:0:0:0:download failed" > "$RESULTS_DIR/$idx"
            return
        fi
    fi

    # Validate output
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        echo "SKIP:0:0:0:no output" > "$RESULTS_DIR/$idx"
        return
    fi

    local total_lines header_cols data_rows
    total_lines=$(wc -l < "$file" | tr -d ' ')
    data_rows=$((total_lines - 1))
    header_cols=$(head -1 "$file" | awk -F, '{print NF}')

    # 1) Column count consistency
    local bad
    bad=$(awk -F, -v h="$header_cols" 'NR==1{next} NR>5001{exit} NF!=h{c++} END{print c+0}' "$file")
    if [ "$bad" -gt 0 ]; then
        local fsize
        fsize=$(wc -c < "$file" | tr -d ' ')
        echo "FAIL:${data_rows}:${header_cols}:${fsize}:${bad} rows wrong col count" > "$RESULTS_DIR/$idx"
        return
    fi

    # 2) Row count (klines only)
    if [ "$exp_rows" -gt 0 ] && [ "$data_rows" -ne "$exp_rows" ]; then
        local fsize
        fsize=$(wc -c < "$file" | tr -d ' ')
        echo "FAIL:${data_rows}:${header_cols}:${fsize}:expected ${exp_rows} rows" > "$RESULTS_DIR/$idx"
        return
    fi

    # 3) Timestamp spacing (klines only)
    if [ "$interval_sec" -gt 0 ] && [ "$data_rows" -gt 1 ]; then
        local errs
        errs=$(tail -n +2 "$file" | perl -F, -lane '
            use POSIX qw(mktime);
            my $t;
            if ($F[0] =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/) {
                $t = POSIX::mktime($6,$5,$4,$3,$2-1,$1-1900);
            } elsif ($F[0] =~ /^\d{10,}$/) {
                $t = $F[0] > 9_999_999_999_999
                    ? int($F[0] / 1_000_000)
                    : int($F[0] / 1_000);
            }
            if (defined $t) {
                $bad++ if defined $prev && ($t-$prev) != '"$interval_sec"';
                $prev = $t;
            }
            END { print $bad+0 }
        ')
        if [ "$errs" -gt 0 ]; then
            local fsize
        fsize=$(wc -c < "$file" | tr -d ' ')
        echo "FAIL:${data_rows}:${header_cols}:${fsize}:${errs} timestamp errors" > "$RESULTS_DIR/$idx"
            return
        fi
    fi

    local fsize
    fsize=$(wc -c < "$file" | tr -d ' ')
    echo "PASS:${data_rows}:${header_cols}:${fsize}:" > "$RESULTS_DIR/$idx"
}

# ============================================================================
# Main Loop
# ============================================================================

printf '\n' >&2
draw_table

while [ "$DONE" -lt "$TOTAL" ]; do
    # Launch new workers if slots available
    local_running=0
    r=0
    while [ $r -lt "$TOTAL" ]; do
        [ "${T_STATUS[$r]}" = "RUN" ] && local_running=$((local_running + 1))
        r=$((r+1))
    done

    r=0
    while [ $r -lt "$TOTAL" ] && [ "$local_running" -lt "$MAX_PARALLEL" ]; do
        if [ "${T_STATUS[$r]}" = "WAIT" ]; then
            T_STATUS[$r]="RUN"
            run_worker "$r" &
            T_PID[$r]=$!
            local_running=$((local_running + 1))
        fi
        r=$((r+1))
    done

    # Poll running tests for results
    r=0
    while [ $r -lt "$TOTAL" ]; do
        if [ "${T_STATUS[$r]}" = "RUN" ]; then
            if [ -f "$RESULTS_DIR/$r" ]; then
                # Parse result: STATUS:ROWS:COLS:SIZE:DETAIL
                _line=$(cat "$RESULTS_DIR/$r")
                _status="${_line%%:*}"
                _line="${_line#*:}"
                _rows="${_line%%:*}"
                _line="${_line#*:}"
                _cols="${_line%%:*}"
                _line="${_line#*:}"
                _size="${_line%%:*}"

                T_STATUS[$r]="$_status"
                T_ROWS[$r]="$_rows"
                T_COLS[$r]="$_cols"
                T_SIZE[$r]="$_size"
                [ "$_size" -gt 0 ] 2>/dev/null && TOTAL_BYTES=$((TOTAL_BYTES + _size))

                case "$_status" in
                    PASS) PASS=$((PASS+1)) ;;
                    FAIL) FAIL=$((FAIL+1)) ;;
                    SKIP) SKIP=$((SKIP+1)) ;;
                esac

                DONE=$((DONE+1))

                # Reap the background process
                wait "${T_PID[$r]}" 2>/dev/null || true

            elif ! kill -0 "${T_PID[$r]}" 2>/dev/null; then
                # Process died without writing result
                T_STATUS[$r]="SKIP"
                T_DETAIL[$r]="unexpected exit"
                SKIP=$((SKIP+1))
                DONE=$((DONE+1))
                wait "${T_PID[$r]}" 2>/dev/null || true
            fi
        fi
        r=$((r+1))
    done

    draw_table
    sleep 0.3
done

# Final redraw
draw_table

# Summary line
_total_h=$(human_size "$TOTAL_BYTES")
printf ' %sDone.%s  Total data: %s' "$BOLD" "$RESET" "$_total_h" >&2
if [ "$FAIL" -gt 0 ]; then
    printf '  %s%d failed.%s' "$RED$BOLD" "$FAIL" "$RESET" >&2
fi
printf '\n\n' >&2

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
