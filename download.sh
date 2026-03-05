#!/usr/bin/env bash
# download.sh — Interactive Binance public data downloader
# Downloads from data.binance.vision with smart monthly/daily splitting
# Compatible with Bash 3.2+ (macOS default), BSD date, and GNU date

set -euo pipefail

# ============================================================================
# Section 1: Constants & Configuration
# ============================================================================

BASE_URL="https://data.binance.vision/data"
CACHE_DIR="./caches"
OUTPUT_DIR="./downloads"
MAX_PARALLEL=5
MAX_RETRIES=3

KLINE_INTERVALS="1s 1m 3m 5m 15m 30m 1h 2h 4h 6h 8h 12h 1d 3d 1w 1mo"

# ============================================================================
# Section 2: Color & TUI Primitives
# ============================================================================

# Colors (using tput for portability, fallback to raw codes)
if command -v tput >/dev/null 2>&1 && [ -t 2 ]; then
    BOLD=$(tput bold)
    DIM=$(tput dim)
    RESET=$(tput sgr0)
    GREEN=$(tput setaf 2)
    CYAN=$(tput setaf 6)
    YELLOW=$(tput setaf 3)
    RED=$(tput setaf 1)
    WHITE=$(tput setaf 7)
    UP=$(tput cuu1)
    CLEAR_LINE=$(tput el)
    HIDE_CURSOR=$(tput civis 2>/dev/null || true)
    SHOW_CURSOR=$(tput cnorm 2>/dev/null || true)
else
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    RESET=$'\e[0m'
    GREEN=$'\e[32m'
    CYAN=$'\e[36m'
    YELLOW=$'\e[33m'
    RED=$'\e[31m'
    WHITE=$'\e[37m'
    UP=$'\e[A'
    CLEAR_LINE=$'\e[K'
    HIDE_CURSOR=$'\e[?25l'
    SHOW_CURSOR=$'\e[?25h'
fi

# Read a single keypress from /dev/tty
# Returns: "up", "down", "space", "enter", "a", or the character
read_key() {
    local key
    IFS= read -rsn1 key </dev/tty 2>/dev/null || return 1
    if [ "$key" = $'\x1b' ]; then
        # Read next 2 chars to capture full escape sequence
        # Handles both CSI (ESC [ A) and SS3 (ESC O A) arrow sequences
        local seq
        IFS= read -rsn2 -t 1 seq </dev/tty 2>/dev/null || { echo "escape"; return; }
        case "$seq" in
            "[A"|"OA") echo "up"; return ;;
            "[B"|"OB") echo "down"; return ;;
            "[C"|"OC") echo "right"; return ;;
            "[D"|"OD") echo "left"; return ;;
        esac
        echo "escape"
        return
    fi
    case "$key" in
        "") echo "enter" ;;
        " ") echo "space" ;;
        *) echo "$key" ;;
    esac
}

# Move cursor up N lines on stderr
cursor_up() {
    local n=$1
    local i=0
    while [ $i -lt "$n" ]; do
        printf '%s' "$UP" >&2
        i=$((i + 1))
    done
}

# Clear N lines from current position downward on stderr
clear_lines() {
    local n=$1
    local i=0
    while [ $i -lt "$n" ]; do
        printf '%s%s\n' "$CLEAR_LINE" "" >&2
        i=$((i + 1))
    done
    cursor_up "$n"
}

# Character-by-character line reader with ESC support
# Usage: _read_line [initial_value]
# Outputs entered text to stdout, or "__BACK__" on ESC. Typed chars go to stderr.
_read_line() {
    local buf="${1:-}"
    local pos=${#buf}
    printf '%s' "$buf" >&2
    while true; do
        local key
        IFS= read -rsn1 key </dev/tty 2>/dev/null || return 1
        if [ "$key" = $'\x1b' ]; then
            local seq
            IFS= read -rsn2 -t 1 seq </dev/tty 2>/dev/null || {
                echo "__BACK__"
                return 0
            }
            case "$seq" in
                '[D'|'OD')  # Left arrow
                    if [ $pos -gt 0 ]; then
                        pos=$((pos - 1))
                        printf '\b' >&2
                    fi
                    ;;
                '[C'|'OC')  # Right arrow
                    if [ $pos -lt ${#buf} ]; then
                        printf '%s' "${buf:pos:1}" >&2
                        pos=$((pos + 1))
                    fi
                    ;;
            esac
            continue
        fi
        case "$key" in
            "")  # Enter
                echo "$buf"
                return 0
                ;;
            $'\x7f'|$'\x08')  # Backspace (DEL or BS)
                if [ $pos -gt 0 ]; then
                    buf="${buf:0:$((pos-1))}${buf:pos}"
                    pos=$((pos - 1))
                    local tail="${buf:pos}"
                    local back=$((${#tail} + 1))
                    printf '\b%s \033[%dD' "$tail" "$back" >&2
                fi
                ;;
            *)
                buf="${buf:0:pos}${key}${buf:pos}"
                pos=$((pos + 1))
                local tail="${buf:pos}"
                printf '%s' "${buf:$((pos-1))}" >&2
                if [ ${#tail} -gt 0 ]; then
                    printf '\033[%dD' "${#tail}" >&2
                fi
                ;;
        esac
    done
}

# ============================================================================
# Section 3: TUI Widgets
# ============================================================================

# single_select "prompt" "hint" option1 option2 ...
# Outputs selected value to stdout. All UI goes to stderr.
# Set _SS_INITIAL to a 0-based index before calling to pre-select an option.
single_select() {
    local prompt="$1"; shift
    local hint="$1"; shift
    local options=("$@")
    local count=${#options[@]}
    local selected=${_SS_INITIAL:-0}
    _SS_INITIAL=""
    if [ $selected -ge $count ]; then selected=0; fi
    local total_lines=$((count + 2))

    printf '%s' "$HIDE_CURSOR" >&2

    while true; do
        # Print header
        printf '%s%s%s' "$BOLD$CYAN" "$prompt" "$RESET" >&2
        if [ -n "$hint" ]; then
            printf '  %s%s%s' "$DIM" "$hint" "$RESET" >&2
        fi
        printf '\n' >&2

        # Print options
        local i=0
        while [ $i -lt $count ]; do
            if [ $i -eq $selected ]; then
                printf '  %s● %s%s\n' "$GREEN" "${options[$i]}" "$RESET" >&2
            else
                printf '  %s○ %s%s\n' "$DIM" "${options[$i]}" "$RESET" >&2
            fi
            i=$((i + 1))
        done
        printf '\n' >&2

        local key
        key=$(read_key)
        case "$key" in
            up)
                if [ $selected -gt 0 ]; then
                    selected=$((selected - 1))
                fi
                ;;
            down)
                if [ $selected -lt $((count - 1)) ]; then
                    selected=$((selected + 1))
                fi
                ;;
            enter)
                cursor_up "$total_lines"
                clear_lines "$total_lines"
                printf '%s' "$SHOW_CURSOR" >&2
                echo "${options[$selected]}"
                return 0
                ;;
            escape)
                cursor_up "$total_lines"
                clear_lines "$total_lines"
                printf '%s' "$SHOW_CURSOR" >&2
                echo "__BACK__"
                return 0
                ;;
        esac

        # Redraw: move cursor up and clear
        cursor_up "$total_lines"
        clear_lines "$total_lines"
    done
}

# multi_select "prompt" "hint" option1 option2 ...
# Outputs space-separated selected values to stdout
# Set _MS_INITIAL to a string of 0s/1s before calling to restore previous selection.
multi_select() {
    local prompt="$1"; shift
    local hint="$1"; shift
    local options=("$@")
    local count=${#options[@]}
    local cursor=0
    local total_lines=$((count + 3))

    # Track selected state with a simple string of 0s and 1s
    local selected=""
    if [ -n "${_MS_INITIAL:-}" ] && [ ${#_MS_INITIAL} -eq $count ]; then
        selected="$_MS_INITIAL"
    else
        local i=0
        while [ $i -lt $count ]; do
            selected="${selected}0"
            i=$((i + 1))
        done
    fi
    _MS_INITIAL=""

    printf '%s' "$HIDE_CURSOR" >&2

    while true; do
        # Header
        printf '%s%s%s' "$BOLD$CYAN" "$prompt" "$RESET" >&2
        if [ -n "$hint" ]; then
            printf '  %s%s%s' "$DIM" "$hint" "$RESET" >&2
        fi
        printf '\n' >&2

        # Options
        local i=0
        while [ $i -lt $count ]; do
            local check=" "
            if [ "${selected:$i:1}" = "1" ]; then
                check="${GREEN}✓${RESET}"
            fi

            if [ $i -eq $cursor ]; then
                printf '  %s> [%s] %s%s\n' "$WHITE$BOLD" "$check" "${options[$i]}" "$RESET" >&2
            else
                printf '    [%s] %s%s%s\n' "$check" "$DIM" "${options[$i]}" "$RESET" >&2
            fi
            i=$((i + 1))
        done

        printf '  %s(Space=toggle, a=all, Enter=confirm, Esc=back)%s\n' "$DIM" "$RESET" >&2
        printf '\n' >&2

        local key
        key=$(read_key)
        case "$key" in
            up)
                if [ $cursor -gt 0 ]; then
                    cursor=$((cursor - 1))
                fi
                ;;
            down)
                if [ $cursor -lt $((count - 1)) ]; then
                    cursor=$((cursor + 1))
                fi
                ;;
            space)
                # Toggle current item
                local before="${selected:0:$cursor}"
                local current="${selected:$cursor:1}"
                local after="${selected:$((cursor + 1))}"
                if [ "$current" = "0" ]; then
                    selected="${before}1${after}"
                else
                    selected="${before}0${after}"
                fi
                ;;
            a)
                # Toggle all
                local has_unselected=0
                local i=0
                while [ $i -lt $count ]; do
                    if [ "${selected:$i:1}" = "0" ]; then
                        has_unselected=1
                        break
                    fi
                    i=$((i + 1))
                done
                local new_selected=""
                local i=0
                if [ $has_unselected -eq 1 ]; then
                    while [ $i -lt $count ]; do
                        new_selected="${new_selected}1"
                        i=$((i + 1))
                    done
                else
                    while [ $i -lt $count ]; do
                        new_selected="${new_selected}0"
                        i=$((i + 1))
                    done
                fi
                selected="$new_selected"
                ;;
            escape)
                cursor_up "$total_lines"
                clear_lines "$total_lines"
                printf '%s' "$SHOW_CURSOR" >&2
                echo "__BACK__"
                return 0
                ;;
            enter)
                # Validate at least one selected
                local any_selected=0
                local i=0
                while [ $i -lt $count ]; do
                    if [ "${selected:$i:1}" = "1" ]; then
                        any_selected=1
                        break
                    fi
                    i=$((i + 1))
                done
                if [ $any_selected -eq 0 ] && [ "$allow_empty" != "1" ]; then
                    # Flash warning on the prompt line, then redraw
                    cursor_up "$total_lines"
                    printf '%s  %s⚠ Select at least one option%s' "$CLEAR_LINE" "$RED" "$RESET" >&2
                    sleep 0.8
                    printf '\r%s' "$CLEAR_LINE" >&2
                    clear_lines "$total_lines"
                    continue
                fi

                cursor_up "$total_lines"
                clear_lines "$total_lines"
                printf '%s' "$SHOW_CURSOR" >&2
                # Build result
                local result=""
                local i=0
                while [ $i -lt $count ]; do
                    if [ "${selected:$i:1}" = "1" ]; then
                        if [ -n "$result" ]; then
                            result="$result ${options[$i]}"
                        else
                            result="${options[$i]}"
                        fi
                    fi
                    i=$((i + 1))
                done
                echo "$result"
                return 0
                ;;
        esac

        cursor_up "$total_lines"
        clear_lines "$total_lines"
    done
}

# text_input "prompt" "hint" [initial_value]
# Reads a line of text with ESC=back support, outputs to stdout
text_input() {
    local prompt="$1"
    local hint="$2"
    local initial="${3:-}"

    printf '%s%s%s' "$BOLD$CYAN" "$prompt" "$RESET" >&2
    if [ -n "$hint" ]; then
        printf '  %s%s%s' "$DIM" "$hint" "$RESET" >&2
    fi
    printf '\n' >&2
    printf '  %s> %s' "$GREEN" "$RESET" >&2

    local value
    value=$(_read_line "$initial")

    if [ "$value" = "__BACK__" ]; then
        printf '\r%s' "$CLEAR_LINE" >&2
        cursor_up 1
        printf '%s' "$CLEAR_LINE" >&2
        echo "__BACK__"
        return 0
    fi

    printf '\n' >&2
    cursor_up 2
    clear_lines 2
    echo "$value"
}

# date_input "prompt" "hint" "default_value" "min_date_or_empty" [initial_value]
# Validates YYYY-MM-DD format, outputs to stdout
# If default_value is set and user presses Enter with empty input, returns default
date_input() {
    local prompt="$1"
    local hint="$2"
    local default_value="${3:-}"
    local min_date="${4:-}"
    local initial="${5:-}"
    local yesterday
    yesterday=$(get_yesterday)

    while true; do
        printf '%s%s%s' "$BOLD$CYAN" "$prompt" "$RESET" >&2
        if [ -n "$hint" ]; then
            printf '  %s%s%s' "$DIM" "$hint" "$RESET" >&2
        fi
        printf '\n' >&2
        printf '  %s> %s' "$GREEN" "$RESET" >&2

        local value
        value=$(_read_line "$initial")
        initial=""  # Only pre-fill on first iteration

        if [ "$value" = "__BACK__" ]; then
            printf '\r%s' "$CLEAR_LINE" >&2
            cursor_up 1
            printf '%s' "$CLEAR_LINE" >&2
            echo "__BACK__"
            return 0
        fi

        printf '\n' >&2

        # Strip whitespace
        value=$(echo "$value" | tr -d ' ')

        # Empty input → use default if available
        if [ -z "$value" ] && [ -n "$default_value" ]; then
            cursor_up 2
            clear_lines 2
            echo "$default_value"
            return 0
        fi

        # Validate format
        if ! echo "$value" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
            printf '  %s✗ Invalid format. Use YYYY-MM-DD%s\n\n' "$RED" "$RESET" >&2
            continue
        fi

        # Validate it's a real date
        if ! validate_date "$value"; then
            printf '  %s✗ Invalid date%s\n\n' "$RED" "$RESET" >&2
            continue
        fi

        # Check min date constraint
        if [ -n "$min_date" ] && [ "$(date_to_epoch "$value")" -lt "$(date_to_epoch "$min_date")" ]; then
            printf '  %s✗ Must be on or after %s%s\n\n' "$RED" "$min_date" "$RESET" >&2
            continue
        fi

        # Check max date (yesterday)
        if [ "$(date_to_epoch "$value")" -gt "$(date_to_epoch "$yesterday")" ]; then
            printf '  %s✗ Max date is %s (yesterday — today'\''s data isn'\''t available yet)%s\n\n' "$RED" "$yesterday" "$RESET" >&2
            continue
        fi

        cursor_up 2
        clear_lines 2
        echo "$value"
        return 0
    done
}

# ============================================================================
# Section 4: Date Utilities & Smart Split Algorithm
# ============================================================================

# Detect date command flavor
is_bsd_date() {
    date -j -f "%Y-%m-%d" "2024-01-01" "+%s" >/dev/null 2>&1
}

# Convert YYYY-MM-DD to epoch seconds
date_to_epoch() {
    local d="$1"
    if is_bsd_date; then
        date -j -f "%Y-%m-%d" "$d" "+%s" 2>/dev/null
    else
        date -d "$d" "+%s" 2>/dev/null
    fi
}

# Validate a YYYY-MM-DD string is a real date
validate_date() {
    local d="$1"
    date_to_epoch "$d" >/dev/null 2>&1
}

# Get yesterday's date as YYYY-MM-DD in UTC
# Binance data uses UTC+0 — daily data becomes available after the UTC day ends
get_yesterday() {
    if is_bsd_date; then
        date -u -j -v-1d "+%Y-%m-%d"
    else
        date -u -d "yesterday" "+%Y-%m-%d"
    fi
}

# Get today's date as YYYY-MM-DD in UTC
get_today() {
    date -u "+%Y-%m-%d"
}

# Get last day of month for YYYY-MM (pure bash, no subprocesses)
last_day_of_month() {
    local y=$((10#${1%%-*}))
    local m=$((10#${1##*-}))
    local days
    case $m in
        1|3|5|7|8|10|12) days=31 ;;
        4|6|9|11) days=30 ;;
        2)
            if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then
                days=29
            else
                days=28
            fi
            ;;
    esac
    printf '%s-%02d' "$1" "$days"
}

# Increment a YYYY-MM-DD date by one day (pure bash, no subprocesses)
next_day() {
    local y=$((10#${1%%-*}))
    local rest="${1#*-}"
    local m=$((10#${rest%%-*}))
    local d=$((10#${rest##*-}))
    d=$((d + 1))
    local max_d
    case $m in
        1|3|5|7|8|10|12) max_d=31 ;;
        4|6|9|11) max_d=30 ;;
        2)
            if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then
                max_d=29
            else
                max_d=28
            fi
            ;;
    esac
    if [ $d -gt $max_d ]; then
        d=1
        m=$((m + 1))
        if [ $m -gt 12 ]; then
            m=1
            y=$((y + 1))
        fi
    fi
    printf '%04d-%02d-%02d' "$y" "$m" "$d"
}

# Extract year from YYYY-MM-DD
year_of() { echo "${1%%-*}"; }

# Extract month from YYYY-MM-DD (zero-padded)
month_of() { echo "$1" | cut -d- -f2; }

# Extract day from YYYY-MM-DD (zero-padded)
day_of() { echo "$1" | cut -d- -f3; }

# Get YYYY-MM from YYYY-MM-DD
ym_of() { echo "$1" | cut -d- -f1-2; }

# Next month YYYY-MM from YYYY-MM
next_ym() {
    local ym="$1"
    local y="${ym%%-*}"
    local m="${ym##*-}"
    local nm=$((10#$m + 1))
    local ny=$((10#$y))
    if [ "$nm" -gt 12 ]; then
        nm=1
        ny=$((ny + 1))
    fi
    printf '%04d-%02d' "$ny" "$nm"
}

# Smart monthly/daily split algorithm (pure bash — no subprocess spawning)
# Output: lines of "monthly YYYY-MM" or "daily YYYY-MM-DD"
# Uses lexicographic string comparison on YYYY-MM-DD (works because ISO 8601 sorts correctly)
compute_date_splits() {
    local start_date="$1"
    local end_date="$2"

    local today
    today=$(get_today)
    local current_ym="${today%-*}"

    local start_ym="${start_date%-*}"       # YYYY-MM from start
    local start_day="${start_date##*-}"      # DD from start

    # Phase 1: Leading partial month (daily)
    if [ "$((10#$start_day))" -ne 1 ]; then
        local month_end
        month_end=$(last_day_of_month "$start_ym")
        local phase1_end="$month_end"
        # Clamp to end_date if month_end is past it
        if [ "$month_end" \> "$end_date" ]; then
            phase1_end="$end_date"
        fi

        local d="$start_date"
        while [ ! "$d" \> "$phase1_end" ]; do
            echo "daily $d"
            d=$(next_day "$d")
        done

        # If entire range was within this partial month, we're done
        if [ ! "$phase1_end" \< "$end_date" ]; then
            return
        fi

        start_ym=$(next_ym "$start_ym")
    fi

    # Phase 2: Complete months (monthly)
    local ym="$start_ym"
    while [ ! "${ym}-01" \> "$end_date" ]; do
        local month_last
        month_last=$(last_day_of_month "$ym")

        # Month qualifies if: (a) fully within range, (b) month has ended
        if [ ! "$month_last" \> "$end_date" ] && [ "$ym" \< "$current_ym" ]; then
            echo "monthly $ym"
            ym=$(next_ym "$ym")
        else
            break
        fi
    done

    # Phase 3: Trailing incomplete month (daily)
    local d="${ym}-01"
    while [ ! "$d" \> "$end_date" ]; do
        echo "daily $d"
        d=$(next_day "$d")
    done
}

# ============================================================================
# Section 5: URL Construction & Cache Paths
# ============================================================================

# Build download URL for an archive
archive_url() {
    local market="$1" freq="$2" symbol="$3" dtype="$4" interval="$5" date_part="$6"
    local mpath
    mpath=$(market_path "$market")
    case "$dtype" in
        klines)
            local filename="${symbol}-${interval}-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/klines/${symbol}/${interval}/${filename}"
            ;;
        trades)
            local filename="${symbol}-trades-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/trades/${symbol}/${filename}"
            ;;
        aggTrades)
            local filename="${symbol}-aggTrades-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/aggTrades/${symbol}/${filename}"
            ;;
        bookTicker)
            local filename="${symbol}-bookTicker-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/bookTicker/${symbol}/${filename}"
            ;;
        fundingRate)
            local filename="${symbol}-fundingRate-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/fundingRate/${symbol}/${filename}"
            ;;
        markPriceKlines)
            local filename="${symbol}-${interval}-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/markPriceKlines/${symbol}/${interval}/${filename}"
            ;;
        indexPriceKlines)
            local filename="${symbol}-${interval}-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/indexPriceKlines/${symbol}/${interval}/${filename}"
            ;;
        premiumIndexKlines)
            local filename="${symbol}-${interval}-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/premiumIndexKlines/${symbol}/${interval}/${filename}"
            ;;
        bookDepth)
            local filename="${symbol}-bookDepth-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/bookDepth/${symbol}/${filename}"
            ;;
        liquidationSnapshot)
            local filename="${symbol}-liquidationSnapshot-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/liquidationSnapshot/${symbol}/${filename}"
            ;;
        metrics)
            local filename="${symbol}-metrics-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/metrics/${symbol}/${filename}"
            ;;
        BVOLIndex)
            local filename="${symbol}-BVOLIndex-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/BVOLIndex/${symbol}/${filename}"
            ;;
        EOHSummary)
            local filename="${symbol}-EOHSummary-${date_part}.zip"
            echo "${BASE_URL}/${mpath}/${freq}/EOHSummary/${symbol}/${filename}"
            ;;
    esac
}

# Cache path for a zip file
# cache_path "spot" "klines" "BTCUSDT" "1h" "BTCUSDT-1h-2024-01.zip"
# cache_path "spot" "trades" "BTCUSDT" ""   "BTCUSDT-trades-2024-01.zip"
cache_path() {
    local market="$1" dtype="$2" symbol="$3" interval="$4" filename="$5"
    local mpath
    mpath=$(market_path "$market")
    if [ -n "$interval" ]; then
        echo "${CACHE_DIR}/${mpath}/${dtype}/${symbol}/${interval}/${filename}"
    else
        echo "${CACHE_DIR}/${mpath}/${dtype}/${symbol}/${filename}"
    fi
}

# Map market key to URL/cache path segment
market_path() {
    case "$1" in
        spot) echo "spot" ;;
        usdm)  echo "futures/um" ;;
        coinm)  echo "futures/cm" ;;
        option) echo "option" ;;
    esac
}

# Returns 0 if dtype uses an interval dimension, 1 otherwise
has_interval() {
    case "$1" in
        klines|markPriceKlines|indexPriceKlines|premiumIndexKlines) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================================
# Section 6: Download Engine
# ============================================================================

# Semaphore using a FIFO for parallel job control
FIFO_PATH=""

setup_semaphore() {
    local max="$1"
    FIFO_PATH=$(mktemp -u /tmp/binance_dl_fifo.XXXXXX)
    mkfifo "$FIFO_PATH"
    # Open FIFO for reading and writing on fd 3
    exec 3<>"$FIFO_PATH"
    # Fill semaphore with N tokens
    local i=0
    while [ $i -lt "$max" ]; do
        printf '\n' >&3
        i=$((i + 1))
    done
}

cleanup_semaphore() {
    if [ -n "$FIFO_PATH" ] && [ -p "$FIFO_PATH" ]; then
        { exec 3>&-; } 2>/dev/null || true
        rm -f "$FIFO_PATH"
    fi
}

# Download a single file with retries
# download_one URL DEST_PATH DISPLAY_NAME
# Returns 0 on success, 1 on 404, 2 on failure
download_one() {
    local url="$1"
    local dest="$2"
    local display_name="${3:-}"
    local attempt=0
    local backoff=2

    while [ $attempt -lt $MAX_RETRIES ]; do
        local http_code
        http_code=$(curl -sS -f -L -o "$dest" -w "%{http_code}" "$url" 2>/dev/null) || true

        if [ -f "$dest" ] && [ -s "$dest" ]; then
            return 0
        fi

        # Check if it was a 404
        if [ "$http_code" = "404" ] || [ "$http_code" = "403" ]; then
            rm -f "$dest"
            return 1
        fi

        attempt=$((attempt + 1))
        if [ $attempt -lt $MAX_RETRIES ]; then
            if [ -n "$display_name" ]; then
                show_progress "Retrying ${display_name} (${attempt}/${MAX_RETRIES}, HTTP ${http_code})"
            fi
            sleep $backoff
            backoff=$((backoff * 2))
        fi
    done

    rm -f "$dest"
    return 2
}

# Verify checksum of a downloaded zip
# verify_checksum ZIP_PATH CHECKSUM_URL
verify_checksum() {
    local zip_path="$1"
    local checksum_url="$2"
    local checksum_path="${zip_path}.CHECKSUM"

    # Download checksum file
    if ! curl -sS -f -L -o "$checksum_path" "$checksum_url" 2>/dev/null; then
        rm -f "$checksum_path"
        return 0  # No checksum available, consider OK
    fi

    # Verify
    local zip_dir zip_name
    zip_dir=$(dirname "$zip_path")
    zip_name=$(basename "$zip_path")

    local result=0
    if command -v shasum >/dev/null 2>&1; then
        (cd "$zip_dir" && shasum -a 256 -c "$zip_name.CHECKSUM" >/dev/null 2>&1) || result=1
    elif command -v sha256sum >/dev/null 2>&1; then
        (cd "$zip_dir" && sha256sum -c "$zip_name.CHECKSUM" >/dev/null 2>&1) || result=1
    fi

    rm -f "$checksum_path"
    return $result
}

# Progress tracking via append-only log (atomic on POSIX, no flock needed)
PROGRESS_LOG=""
PROGRESS_TOTAL=0

init_progress() {
    PROGRESS_TOTAL=$1
    PROGRESS_LOG=$(mktemp /tmp/binance_dl_log.XXXXXX)
    : > "$PROGRESS_LOG"
}

# Log a completed download — append is atomic for short lines on POSIX
# log_progress STATUS FILENAME [REASON]
log_progress() {
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$PROGRESS_LOG"
}

# Display progress bar with current activity
show_progress() {
    local activity="${1:-}"
    local completed
    completed=$(wc -l < "$PROGRESS_LOG" 2>/dev/null | tr -d ' ')
    completed=${completed:-0}

    local pct=0
    if [ "$PROGRESS_TOTAL" -gt 0 ]; then
        pct=$((completed * 100 / PROGRESS_TOTAL))
    fi

    # Build bar (width 20)
    local bar_width=20
    local filled=$((pct * bar_width / 100))
    local empty=$((bar_width - filled))
    local bar=""
    local i=0
    while [ $i -lt $filled ]; do bar="${bar}█"; i=$((i + 1)); done
    i=0
    while [ $i -lt $empty ]; do bar="${bar}░"; i=$((i + 1)); done

    local suffix=""
    if [ -n "$activity" ]; then
        suffix="  $activity"
    fi

    printf '\r  %s[%d/%d]%s %s %d%%%s%s%s%s' \
        "$CYAN" "$completed" "$PROGRESS_TOTAL" "$RESET" \
        "$bar" "$pct" \
        "$DIM" "$suffix" "$RESET" "$CLEAR_LINE" >&2
}

# Download worker for a single archive
# download_worker SYMBOL INTERVAL FREQ DATE_PART MARKET DTYPE
download_worker() {
    local symbol="$1" interval="$2" freq="$3" date_part="$4" market="$5" dtype="$6"

    local filename
    case "$dtype" in
        klines)    filename="${symbol}-${interval}-${date_part}.zip" ;;
        trades)    filename="${symbol}-trades-${date_part}.zip" ;;
        aggTrades) filename="${symbol}-aggTrades-${date_part}.zip" ;;
        bookTicker)  filename="${symbol}-bookTicker-${date_part}.zip" ;;
        fundingRate) filename="${symbol}-fundingRate-${date_part}.zip" ;;
        markPriceKlines)     filename="${symbol}-${interval}-${date_part}.zip" ;;
        indexPriceKlines)    filename="${symbol}-${interval}-${date_part}.zip" ;;
        premiumIndexKlines)  filename="${symbol}-${interval}-${date_part}.zip" ;;
        bookDepth)           filename="${symbol}-bookDepth-${date_part}.zip" ;;
        liquidationSnapshot) filename="${symbol}-liquidationSnapshot-${date_part}.zip" ;;
        metrics)             filename="${symbol}-metrics-${date_part}.zip" ;;
        BVOLIndex)           filename="${symbol}-BVOLIndex-${date_part}.zip" ;;
        EOHSummary)          filename="${symbol}-EOHSummary-${date_part}.zip" ;;
    esac

    local cpath
    cpath=$(cache_path "$market" "$dtype" "$symbol" "$interval" "$filename")
    local cdir
    cdir=$(dirname "$cpath")

    # Check cache
    if [ -f "$cpath" ] && [ -s "$cpath" ]; then
        log_progress "cached" "$filename"
        show_progress ""
        return 0
    fi

    mkdir -p "$cdir"

    local url
    url=$(archive_url "$market" "$freq" "$symbol" "$dtype" "$interval" "$date_part")
    local checksum_url="${url}.CHECKSUM"

    show_progress "$filename"

    # Download
    local dl_result=0
    download_one "$url" "$cpath" "$filename" || dl_result=$?

    if [ $dl_result -eq 0 ]; then
        # Verify checksum
        if ! verify_checksum "$cpath" "$checksum_url"; then
            show_progress "Retrying $filename (checksum failed)"
            rm -f "$cpath"
            local retry_result=0
            download_one "$url" "$cpath" "$filename" || retry_result=$?
            if [ $retry_result -eq 0 ] && verify_checksum "$cpath" "$checksum_url"; then
                log_progress "done" "$filename"
            else
                rm -f "$cpath"
                log_progress "failed" "$filename" "checksum mismatch after retry"
            fi
            show_progress ""
            return 0
        fi
        log_progress "done" "$filename"
    elif [ $dl_result -eq 1 ]; then
        log_progress "notfound" "$filename" "404 — data may not exist for this date"
    else
        log_progress "failed" "$filename" "download failed after $MAX_RETRIES attempts"
    fi
    show_progress ""
}

# Run all downloads in parallel
# run_downloads MARKET DTYPE SYMBOLS_ARRAY INTERVALS_ARRAY SPLITS_ARRAY
run_downloads() {
    local market="$1"; shift
    local dtype="$1"; shift
    local symbols_str="$1"; shift
    local intervals_str="$1"; shift
    local splits_str="$1"

    # For non-klines dtypes there is no interval dimension; sentinel ensures one
    # iteration per symbol so the loop structure stays uniform
    local _iter_intervals="${intervals_str:-__none__}"

    # Count total downloads
    local total=0
    local sym int split_line
    for sym in $symbols_str; do
        for int in $_iter_intervals; do
            local old_ifs="$IFS"
            IFS=$'\n'
            for split_line in $splits_str; do
                total=$((total + 1))
            done
            IFS="$old_ifs"
        done
    done

    if [ $total -eq 0 ]; then
        printf '  %sNo files to download.%s\n' "$YELLOW" "$RESET" >&2
        return 0
    fi

    printf '  %sDownloading %d archives...%s\n' "$BOLD$CYAN" "$total" "$RESET" >&2

    init_progress "$total"
    setup_semaphore "$MAX_PARALLEL"

    # Trap Ctrl+C
    trap 'printf "\n  %sInterrupted. Cleaning up...%s\n" "$RED" "$RESET" >&2; cleanup_semaphore; rm -f "$PROGRESS_LOG"; printf "%s" "$SHOW_CURSOR" >&2; jobs -p | xargs kill 2>/dev/null; wait 2>/dev/null; exit 130' INT TERM

    printf '%s' "$HIDE_CURSOR" >&2
    show_progress
    printf '\n%s' "$UP" >&2  # Create blank buffer line below progress bar, move back up

    for sym in $symbols_str; do
        for int in $_iter_intervals; do
            [ "$int" = "__none__" ] && int=""
            local old_ifs="$IFS"
            IFS=$'\n'
            for split_line in $splits_str; do
                IFS="$old_ifs"
                local freq date_part
                freq=$(echo "$split_line" | cut -d' ' -f1)
                date_part=$(echo "$split_line" | cut -d' ' -f2)

                # Acquire semaphore token
                read -r -u 3 _token

                (
                    download_worker "$sym" "$int" "$freq" "$date_part" "$market" "$dtype"
                    # Release semaphore token
                    printf '\n' >&3
                ) &
            done
            IFS="$old_ifs"
        done
    done

    # Wait for all background jobs
    wait 2>/dev/null || true

    printf '\n' >&2  # Move past the blank buffer line below progress bar
    printf '%s' "$SHOW_CURSOR" >&2

    # Parse log for detailed counts
    # Note: grep -c prints "0" and exits 1 when no matches — use || true to avoid
    # capturing the fallback "echo 0" alongside grep's own "0" output
    local done_count=0 cached_count=0 notfound_count=0 failed_count=0
    if [ -f "$PROGRESS_LOG" ]; then
        done_count=$(grep -c "^done	" "$PROGRESS_LOG" || true)
        cached_count=$(grep -c "^cached	" "$PROGRESS_LOG" || true)
        notfound_count=$(grep -c "^notfound	" "$PROGRESS_LOG" || true)
        failed_count=$(grep -c "^failed	" "$PROGRESS_LOG" || true)
        done_count=${done_count:-0}
        cached_count=${cached_count:-0}
        notfound_count=${notfound_count:-0}
        failed_count=${failed_count:-0}
    fi

    printf '  %s✓ Downloads complete:%s %d downloaded, %d already cached' \
        "$GREEN$BOLD" "$RESET" "$done_count" "$cached_count" >&2
    if [ "$notfound_count" -gt 0 ]; then
        printf ', %s%d not found%s' "$YELLOW" "$notfound_count" "$RESET" >&2
    fi
    if [ "$failed_count" -gt 0 ]; then
        printf ', %s%d failed%s' "$RED" "$failed_count" "$RESET" >&2
    fi
    printf '\n' >&2

    # Show not-found files
    if [ "$notfound_count" -gt 0 ]; then
        printf '\n  %sNot found (data may not exist for these dates):%s\n' "$YELLOW" "$RESET" >&2
        grep "^notfound	" "$PROGRESS_LOG" | while IFS=$'\t' read -r _ fname reason; do
            printf '    • %s\n' "$fname" >&2
        done
    fi

    # Show failed files
    if [ "$failed_count" -gt 0 ]; then
        printf '\n  %sFailed downloads:%s\n' "$RED" "$RESET" >&2
        grep "^failed	" "$PROGRESS_LOG" | while IFS=$'\t' read -r _ fname reason; do
            printf '    • %s — %s\n' "$fname" "$reason" >&2
        done
    fi

    printf '\n' >&2

    cleanup_semaphore
    rm -f "$PROGRESS_LOG"

    # Restore default trap
    trap - INT TERM
}

# ============================================================================
# Section 7: Merge Engine
# ============================================================================

# Merge cached zips into final output files
# merge_outputs MARKET DTYPE SYMBOLS_STR INTERVALS_STR START_DATE END_DATE SPLITS_STR
merge_outputs() {
    local market="$1" dtype="$2" symbols_str="$3" intervals_str="$4"
    local start_date="$5" end_date="$6" splits_str="$7"

    mkdir -p "$OUTPUT_DIR"

    # Dtype-specific metadata
    local header ts_cols
    case "$dtype" in
        klines)
            header="open_time,open,high,low,close,volume,close_time,quote_volume,trades,taker_buy_base_volume,taker_buy_quote_volume,ignore"
            ts_cols="0, 6"
            ;;
        trades)
            case "$market" in
                usdm)  header="id,price,qty,quoteQty,time,isBuyerMaker" ;;
                coinm) header="id,price,qty,base_qty,time,is_buyer_maker" ;;
                *)     header="id,price,qty,quoteQty,time,isBuyerMaker,isBestMatch" ;;
            esac
            ts_cols="4"
            ;;
        aggTrades)
            case "$market" in
                usdm)  header="agg_tradeId,price,qty,first_tradeId,last_tradeId,transact_time,is_buyer_maker" ;;
                coinm) header="agg_trade_id,price,quantity,first_trade_id,last_trade_id,transact_time,is_buyer_maker" ;;
                *)     header="agg_tradeId,price,qty,first_tradeId,last_tradeId,transact_time,is_buyer_maker,is_best_match" ;;
            esac
            ts_cols="5"
            ;;
        bookTicker)
            header="update_id,best_bid_price,best_bid_qty,best_ask_price,best_ask_qty,transaction_time,event_time"
            ts_cols="5, 6"
            ;;
        fundingRate)
            header="calc_time,funding_interval_hours,last_funding_rate"
            ts_cols="0"
            ;;
        markPriceKlines)
            if [ "$market" = "usdm" ]; then
                header="open_time,open,high,low,close,ignore,close_time,ignore,ignore,ignore,ignore,ignore"
            else
                header="open_time,open,high,low,close,volume,close_time,quote_volume,count,taker_buy_volume,taker_buy_quote_volume,ignore"
            fi
            ts_cols="0, 6"
            ;;
        indexPriceKlines)
            if [ "$market" = "usdm" ]; then
                header="open_time,open,high,low,close,ignore,close_time,ignore,ignore,ignore,ignore,ignore"
            else
                header="open_time,open,high,low,close,volume,close_time,quote_volume,count,taker_buy_volume,taker_buy_quote_volume,ignore"
            fi
            ts_cols="0, 6"
            ;;
        premiumIndexKlines)
            if [ "$market" = "usdm" ]; then
                header="open_time,open,high,low,close,ignore,close_time,ignore,ignore,ignore,ignore,ignore"
            else
                header="open_time,open,high,low,close,volume,close_time,quote_volume,count,taker_buy_volume,taker_buy_quote_volume,ignore"
            fi
            ts_cols="0, 6"
            ;;
        bookDepth)
            header="timestamp,percentage,depth,notional"
            ts_cols=""
            ;;
        liquidationSnapshot)
            header="time,side,order_type,time_in_force,original_quantity,price,average_price,order_status,last_fill_quantity,accumulated_fill_quantity"
            ts_cols="0"
            ;;
        metrics)
            header="create_time,symbol,sum_open_interest,sum_open_interest_value,count_toptrader_long_short_ratio,sum_toptrader_long_short_ratio,count_long_short_ratio,sum_taker_long_short_vol_ratio"
            ts_cols=""
            ;;
        BVOLIndex)
            header="calc_time,symbol,base_asset,quote_asset,index_value"
            ts_cols="0"
            ;;
        EOHSummary)
            header="date,hour,symbol,underlying,type,strike,open,high,low,close,volume_contracts,volume_usdt,best_bid_price,best_ask_price,best_bid_qty,best_ask_qty,best_buy_iv,best_sell_iv,mark_price,mark_iv,delta,gamma,vega,theta,openinterest_contracts,openinterest_usdt"
            ts_cols=""
            ;;
    esac

    # Sentinel ensures one iteration per symbol for no-interval dtypes
    local _iter_intervals="${intervals_str:-__none__}"

    # Count total output files for progress
    local total_outputs=0
    local sym int
    for sym in $symbols_str; do
        for int in $_iter_intervals; do
            total_outputs=$((total_outputs + 1))
        done
    done

    printf '  %sMerging cached archives into %d output file(s)...%s\n' "$BOLD$CYAN" "$total_outputs" "$RESET" >&2

    local file_count=0
    local current_output=0
    for sym in $symbols_str; do
        for int in $_iter_intervals; do
            [ "$int" = "__none__" ] && int=""
            current_output=$((current_output + 1))

            # Build output filename and display label
            local output_name label
            case "$dtype" in
                klines)          output_name="${sym}-klines-${int}-${start_date}_${end_date}.csv";                    label="${sym}-klines-${int}" ;;
                trades)          output_name="${sym}-trades-${start_date}_${end_date}.csv";                    label="${sym}" ;;
                aggTrades)       output_name="${sym}-aggTrades-${start_date}_${end_date}.csv";                 label="${sym}" ;;
                bookTicker)      output_name="${sym}-bookTicker-${start_date}_${end_date}.csv";                label="${sym}" ;;
                fundingRate)     output_name="${sym}-fundingRate-${start_date}_${end_date}.csv";               label="${sym}" ;;
                markPriceKlines)  output_name="${sym}-markPriceKlines-${int}-${start_date}_${end_date}.csv";   label="${sym}-markPriceKlines-${int}" ;;
                indexPriceKlines)   output_name="${sym}-indexPriceKlines-${int}-${start_date}_${end_date}.csv";   label="${sym}-indexPriceKlines-${int}" ;;
                premiumIndexKlines) output_name="${sym}-premiumIndexKlines-${int}-${start_date}_${end_date}.csv"; label="${sym}-premiumIndexKlines-${int}" ;;
                bookDepth)           output_name="${sym}-bookDepth-${start_date}_${end_date}.csv";           label="${sym}" ;;
                liquidationSnapshot) output_name="${sym}-liquidationSnapshot-${start_date}_${end_date}.csv"; label="${sym}" ;;
                metrics)             output_name="${sym}-metrics-${start_date}_${end_date}.csv";             label="${sym}" ;;
                BVOLIndex)           output_name="${sym}-BVOLIndex-${start_date}_${end_date}.csv";           label="${sym}" ;;
                EOHSummary)          output_name="${sym}-EOHSummary-${start_date}_${end_date}.csv";          label="${sym}" ;;
            esac
            local output_path="${OUTPUT_DIR}/${output_name}"
            local tmp_csv
            tmp_csv=$(mktemp /tmp/binance_merge_XXXXXX)

            # Count available archives for this combo
            local archive_count=0
            local old_ifs="$IFS"
            IFS=$'\n'
            for split_line in $splits_str; do
                IFS="$old_ifs"
                local freq date_part filename cpath
                freq=$(echo "$split_line" | cut -d' ' -f1)
                date_part=$(echo "$split_line" | cut -d' ' -f2)
                case "$dtype" in
                    klines)          filename="${sym}-${int}-${date_part}.zip" ;;
                    trades)          filename="${sym}-trades-${date_part}.zip" ;;
                    aggTrades)       filename="${sym}-aggTrades-${date_part}.zip" ;;
                    bookTicker)      filename="${sym}-bookTicker-${date_part}.zip" ;;
                    fundingRate)     filename="${sym}-fundingRate-${date_part}.zip" ;;
                    markPriceKlines)     filename="${sym}-${int}-${date_part}.zip" ;;
                    indexPriceKlines)    filename="${sym}-${int}-${date_part}.zip" ;;
                    premiumIndexKlines)  filename="${sym}-${int}-${date_part}.zip" ;;
                    bookDepth)           filename="${sym}-bookDepth-${date_part}.zip" ;;
                    liquidationSnapshot) filename="${sym}-liquidationSnapshot-${date_part}.zip" ;;
                    metrics)             filename="${sym}-metrics-${date_part}.zip" ;;
                    BVOLIndex)           filename="${sym}-BVOLIndex-${date_part}.zip" ;;
                    EOHSummary)          filename="${sym}-EOHSummary-${date_part}.zip" ;;
                esac
                cpath=$(cache_path "$market" "$dtype" "$sym" "$int" "$filename")
                if [ -f "$cpath" ] && [ -s "$cpath" ]; then
                    archive_count=$((archive_count + 1))
                fi
            done
            IFS="$old_ifs"

            printf '    %s[%d/%d]%s Extracting %s [%d archives]...' \
                "$CYAN" "$current_output" "$total_outputs" "$RESET" \
                "$label" "$archive_count" >&2

            # Collect all cached zips in date order and append to temp file
            local has_data=0
            local old_ifs="$IFS"
            IFS=$'\n'
            for split_line in $splits_str; do
                IFS="$old_ifs"
                local freq date_part filename cpath
                freq=$(echo "$split_line" | cut -d' ' -f1)
                date_part=$(echo "$split_line" | cut -d' ' -f2)
                case "$dtype" in
                    klines)          filename="${sym}-${int}-${date_part}.zip" ;;
                    trades)          filename="${sym}-trades-${date_part}.zip" ;;
                    aggTrades)       filename="${sym}-aggTrades-${date_part}.zip" ;;
                    bookTicker)      filename="${sym}-bookTicker-${date_part}.zip" ;;
                    fundingRate)     filename="${sym}-fundingRate-${date_part}.zip" ;;
                    markPriceKlines)     filename="${sym}-${int}-${date_part}.zip" ;;
                    indexPriceKlines)    filename="${sym}-${int}-${date_part}.zip" ;;
                    premiumIndexKlines)  filename="${sym}-${int}-${date_part}.zip" ;;
                    bookDepth)           filename="${sym}-bookDepth-${date_part}.zip" ;;
                    liquidationSnapshot) filename="${sym}-liquidationSnapshot-${date_part}.zip" ;;
                    metrics)             filename="${sym}-metrics-${date_part}.zip" ;;
                    BVOLIndex)           filename="${sym}-BVOLIndex-${date_part}.zip" ;;
                    EOHSummary)          filename="${sym}-EOHSummary-${date_part}.zip" ;;
                esac
                cpath=$(cache_path "$market" "$dtype" "$sym" "$int" "$filename")

                if [ -f "$cpath" ] && [ -s "$cpath" ]; then
                    local csv_name
                    csv_name=$(unzip -l "$cpath" 2>/dev/null | grep '\.csv$' | awk '{print $NF}' | head -1)
                    if [ -n "$csv_name" ]; then
                        unzip -p "$cpath" "$csv_name" 2>/dev/null | sed '1{/^[^0-9]/d;}' >> "$tmp_csv" || true
                        has_data=1
                    fi
                fi
            done
            IFS="$old_ifs"

            if [ $has_data -eq 1 ] && [ -s "$tmp_csv" ]; then
                printf '\r%s    %s[%d/%d]%s Converting timestamps %s...%s' \
                    "$CLEAR_LINE" "$CYAN" "$current_output" "$total_outputs" "$RESET" \
                    "$label" "$CLEAR_LINE" >&2

                # Write CSV header + convert unix timestamps to human-readable UTC
                rm -f "$output_path"
                {
                    echo "$header"
                    TS_COLS="$ts_cols" perl -MPOSIX=strftime -F, -lane '
                        my @cols = split /,\s*/, $ENV{TS_COLS};
                        for my $i (@cols) {
                            if (defined $F[$i] && $F[$i] =~ /^\d{10,}$/) {
                                my $epoch = $F[$i] > 9_999_999_999_999
                                    ? $F[$i] / 1_000_000
                                    : $F[$i] / 1_000;
                                $F[$i] = strftime("%Y-%m-%d %H:%M:%S", gmtime(int($epoch)));
                            }
                        }
                        print join(",", @F);
                    ' "$tmp_csv"
                } > "$output_path"

                local size
                size=$(du -h "$output_path" | cut -f1 | tr -d ' ')
                printf '\r%s    %s✓%s %s (%s)\n' "$CLEAR_LINE" "$GREEN" "$RESET" "$output_name" "$size" >&2
                file_count=$((file_count + 1))
            else
                printf '\r%s    %s⚠%s %s — no data found\n' "$CLEAR_LINE" "$YELLOW" "$RESET" "$label" >&2
            fi

            rm -f "$tmp_csv"
        done
    done

    printf '\n  %s✓ Created %d output file(s)%s\n' "$GREEN$BOLD" "$file_count" "$RESET" >&2
    printf '  %sLocation: %s/%s\n\n' "$WHITE" "$(cd "$OUTPUT_DIR" && pwd)" "$RESET" >&2
}

# ============================================================================
# Section 8: Flow Orchestration
# ============================================================================

# Build multi-select state string from previously selected values
# Usage: _build_ms_state "selected_vals" option1 option2 ...
_build_ms_state() {
    local prev="$1"; shift
    local state=""
    while [ $# -gt 0 ]; do
        local found=0 p
        for p in $prev; do
            [ "$p" = "$1" ] && { found=1; break; }
        done
        state="${state}${found}"
        shift
    done
    echo "$state"
}

run_interactive() {
    printf '\n%s  ╔══════════════════════════════════════════╗%s\n' "$CYAN$BOLD" "$RESET" >&2
    printf '%s  ║   Binance Public Data Downloader         ║%s\n' "$CYAN$BOLD" "$RESET" >&2
    printf '%s  ╚══════════════════════════════════════════╝%s\n\n' "$CYAN$BOLD" "$RESET" >&2

    local step=1
    local market="" dtype="" symbols_str="" intervals_str=""
    local start_date="" end_date="" splits_str=""
    local yesterday

    # Selection state preserved across back navigation
    local market_idx="" dtype_idx=""
    local symbols_raw_saved=""

    while true; do
        case $step in
        1)
            # ── Step 1: Select market ──
            _SS_INITIAL="$market_idx"
            local market_raw
            market_raw=$(single_select \
                "Step 1: Select market" \
                "↑↓=navigate, Enter=confirm, Esc=back" \
                "Spot" \
                "Futures (USD-M)" \
                "Futures (COIN-M)" \
                "Option")

            if [ "$market_raw" = "__BACK__" ]; then
                continue  # Already at step 1, stay here
            fi

            local prev_market="$market"
            case "$market_raw" in
                "Spot")             market="spot";  market_idx=0 ;;
                "Futures (USD-M)")  market="usdm";  market_idx=1 ;;
                "Futures (COIN-M)") market="coinm"; market_idx=2 ;;
                "Option")           market="option"; market_idx=3 ;;
            esac
            # Reset dtype selection when market changes
            if [ "$market" != "$prev_market" ]; then dtype_idx=""; fi
            step=2
            ;;

        2)
            # ── Step 2: Select data type ──
            _SS_INITIAL="$dtype_idx"
            local dtype_raw
            if [ "$market" = "spot" ]; then
                dtype_raw=$(single_select \
                    "Step 2: Select data type" \
                    "↑↓=navigate, Enter=confirm, Esc=back" \
                    "Klines (candlestick)" \
                    "Trades" \
                    "AggTrades")
            elif [ "$market" = "usdm" ]; then
                dtype_raw=$(single_select \
                    "Step 2: Select data type" \
                    "↑↓=navigate, Enter=confirm, Esc=back" \
                    "Klines" \
                    "AggTrades" \
                    "Trades" \
                    "bookTicker" \
                    "fundingRate" \
                    "markPriceKlines" \
                    "indexPriceKlines" \
                    "premiumIndexKlines")
            elif [ "$market" = "coinm" ]; then
                dtype_raw=$(single_select \
                    "Step 2: Select data type" \
                    "↑↓=navigate, Enter=confirm, Esc=back" \
                    "Klines" \
                    "AggTrades" \
                    "Trades" \
                    "bookTicker" \
                    "fundingRate" \
                    "markPriceKlines" \
                    "indexPriceKlines" \
                    "premiumIndexKlines" \
                    "bookDepth" \
                    "liquidationSnapshot" \
                    "metrics")
            else  # option
                dtype_raw=$(single_select \
                    "Step 2: Select data type" \
                    "↑↓=navigate, Enter=confirm, Esc=back" \
                    "BVOLIndex" \
                    "EOHSummary")
            fi

            if [ "$dtype_raw" = "__BACK__" ]; then
                step=1; continue
            fi

            case "$dtype_raw" in
                "Klines (candlestick)"|"Klines") dtype="klines"; dtype_idx=0 ;;
                "Trades")                        dtype="trades"; dtype_idx=1 ;;
                "AggTrades")                     dtype="aggTrades"; dtype_idx=2 ;;
                "bookTicker")                    dtype="bookTicker"; dtype_idx=3 ;;
                "fundingRate")                   dtype="fundingRate"; dtype_idx=4 ;;
                "markPriceKlines")               dtype="markPriceKlines"; dtype_idx=5 ;;
                "indexPriceKlines")              dtype="indexPriceKlines"; dtype_idx=6 ;;
                "premiumIndexKlines")            dtype="premiumIndexKlines"; dtype_idx=7 ;;
                "bookDepth")                     dtype="bookDepth"; dtype_idx=8 ;;
                "liquidationSnapshot")           dtype="liquidationSnapshot"; dtype_idx=9 ;;
                "metrics")                       dtype="metrics"; dtype_idx=10 ;;
                "BVOLIndex")                     dtype="BVOLIndex"; dtype_idx=0 ;;
                "EOHSummary")                    dtype="EOHSummary"; dtype_idx=1 ;;
                *)
                    printf '  %s⚠ %s is not yet implemented. Stay tuned!%s\n\n' "$YELLOW" "$dtype_raw" "$RESET" >&2
                    exit 0
                    ;;
            esac
            step=3
            ;;

        3)
            # ── Step 3: Enter trading pairs ──
            local symbols_raw
            symbols_raw=$(text_input \
                "Step 3: Enter trading pairs" \
                "Comma-separated, e.g. BTCUSDT, ETHUSDT (Esc=back)" \
                "$symbols_raw_saved")

            if [ "$symbols_raw" = "__BACK__" ]; then
                step=2; continue
            fi

            symbols_raw_saved="$symbols_raw"

            # Clean up: uppercase, strip spaces, split by comma
            symbols_str=$(echo "$symbols_raw" | tr '[:lower:]' '[:upper:]' | tr -d ' ' | tr ',' ' ')

            if [ -z "$symbols_str" ]; then
                printf '  %s✗ No symbols provided. Try again.%s\n' "$RED" "$RESET" >&2
                continue
            fi

            step=4
            ;;

        4)
            # ── Step 4: Select timeframes (interval-based dtypes only) ──
            if ! has_interval "$dtype"; then
                intervals_str=""
                step=5; continue
            fi
            if [ -n "$intervals_str" ]; then
                _MS_INITIAL=$(_build_ms_state "$intervals_str" $KLINE_INTERVALS)
            fi
            intervals_str=$(multi_select \
                "Step 4: Select timeframes" \
                "" \
                $KLINE_INTERVALS)

            if [ "$intervals_str" = "__BACK__" ]; then
                step=3; continue
            fi
            step=5
            ;;

        5)
            # ── Step 5: Start date ──
            yesterday=$(get_yesterday)
            local start_result
            start_result=$(date_input \
                "Step 5: Start date" \
                "YYYY-MM-DD, Enter=earliest (2017-08-17), Esc=back" \
                "2017-08-17" \
                "" \
                "$start_date")

            if [ "$start_result" = "__BACK__" ]; then
                if has_interval "$dtype"; then step=4; else step=3; fi
                continue
            fi
            start_date="$start_result"
            step=6
            ;;

        6)
            # ── Step 6: End date ──
            yesterday=$(get_yesterday)
            local end_result
            end_result=$(date_input \
                "Step 6: End date" \
                "YYYY-MM-DD, Enter=latest ($yesterday), Esc=back" \
                "$yesterday" \
                "$start_date" \
                "$end_date")

            if [ "$end_result" = "__BACK__" ]; then
                step=5; continue
            fi
            end_date="$end_result"
            step=7
            ;;

        7)
            # ── Compute date splits ──
            splits_str=$(compute_date_splits "$start_date" "$end_date")
            # Filter splits by archive availability
            case "$dtype" in
                fundingRate)
                    splits_str=$(printf '%s\n' "$splits_str" | grep "^monthly ") ;;
                bookDepth|liquidationSnapshot|metrics)
                    splits_str=$(printf '%s\n' "$splits_str" | grep "^daily ") ;;
            esac
            if [ "$market" = "option" ]; then
                splits_str=$(printf '%s\n' "$splits_str" | grep "^daily ")
            fi

            # Flush any stale keypresses from the terminal input buffer
            while read -rsn1 -t 0.01 _ </dev/tty 2>/dev/null; do :; done

            local monthly_count=0
            local daily_count=0
            local old_ifs="$IFS"
            IFS=$'\n'
            for line in $splits_str; do
                IFS="$old_ifs"
                local freq
                freq=$(echo "$line" | cut -d' ' -f1)
                if [ "$freq" = "monthly" ]; then
                    monthly_count=$((monthly_count + 1))
                else
                    daily_count=$((daily_count + 1))
                fi
            done
            IFS="$old_ifs"

            local archives_per_combo=$((monthly_count + daily_count))
            local sym_count=0
            for _ in $symbols_str; do sym_count=$((sym_count + 1)); done
            local int_count=0
            for _ in $intervals_str; do int_count=$((int_count + 1)); done
            [ "$int_count" -eq 0 ] && int_count=1  # no interval dimension for non-klines
            local total_archives=$((archives_per_combo * sym_count * int_count))
            local total_output=$((sym_count * int_count))

            # ── Summary + Confirm ──
            # Build value strings
            local s_market="$market"
            local s_dtype="$dtype"
            local s_pairs
            s_pairs=$(echo $symbols_str | tr ' ' ', ')
            local s_tf
            s_tf=$(echo $intervals_str | tr ' ' ', ')
            local s_range="$start_date -> $end_date"
            local s_dl
            case "$dtype" in
                fundingRate)
                    s_dl="$total_archives archives (monthly only)" ;;
                bookDepth|liquidationSnapshot|metrics)
                    s_dl="$total_archives archives (daily only)" ;;
                *)
                    if [ "$market" = "option" ]; then
                        s_dl="$total_archives archives (daily only)"
                    else
                        s_dl="$total_archives archives (${monthly_count} monthly + ${daily_count} daily)"
                    fi
                    ;;
            esac
            local s_out="$total_output merged file(s)"

            # Find max content width: "  Label:      Value  " (label=13 + value + 2 padding)
            local pad=15  # left label area width
            local rpad=2  # right padding before border
            local max_val=0
            local v
            if has_interval "$dtype"; then
                for v in "$s_market" "$s_dtype" "$s_pairs" "$s_tf" "$s_range" "$s_dl" "$s_out"; do
                    local len=${#v}
                    if [ "$len" -gt "$max_val" ]; then max_val=$len; fi
                done
            else
                for v in "$s_market" "$s_dtype" "$s_pairs" "$s_range" "$s_dl" "$s_out"; do
                    local len=${#v}
                    if [ "$len" -gt "$max_val" ]; then max_val=$len; fi
                done
            fi
            local inner=$((pad + max_val + rpad))
            # Minimum inner width
            if [ "$inner" -lt 40 ]; then inner=40; fi

            # Build horizontal lines
            local hline=""
            local i=0
            while [ $i -lt $((inner - 10)) ]; do hline="${hline}─"; i=$((i + 1)); done
            local bline=""
            i=0
            while [ $i -lt "$inner" ]; do bline="${bline}─"; i=$((i + 1)); done

            local w=$((inner - pad))  # value column width

            # Count summary box lines so we can erase on back
            local summary_lines=9  # header + 5 rows + footer + blank line
            if has_interval "$dtype"; then summary_lines=10; fi

            printf '%s  ┌─ Summary %s┐%s\n' "$BOLD" "$hline" "$RESET" >&2
            printf '%s  │%s  Market:      %s%-*s%s%s│%s\n' "$BOLD" "$RESET" "$WHITE" "$w" "$s_market" "$RESET" "$BOLD" "$RESET" >&2
            printf '%s  │%s  Data type:   %s%-*s%s%s│%s\n' "$BOLD" "$RESET" "$WHITE" "$w" "$s_dtype" "$RESET" "$BOLD" "$RESET" >&2
            printf '%s  │%s  Pairs:       %s%-*s%s%s│%s\n' "$BOLD" "$RESET" "$WHITE" "$w" "$s_pairs" "$RESET" "$BOLD" "$RESET" >&2
            if has_interval "$dtype"; then
                printf '%s  │%s  Timeframes:  %s%-*s%s%s│%s\n' "$BOLD" "$RESET" "$WHITE" "$w" "$s_tf" "$RESET" "$BOLD" "$RESET" >&2
            fi
            printf '%s  │%s  Range:       %s%-*s%s%s│%s\n' "$BOLD" "$RESET" "$WHITE" "$w" "$s_range" "$RESET" "$BOLD" "$RESET" >&2
            printf '%s  │%s  Downloads:   %s%-*s%s%s│%s\n' "$BOLD" "$RESET" "$WHITE" "$w" "$s_dl" "$RESET" "$BOLD" "$RESET" >&2
            printf '%s  │%s  Output:      %s%-*s%s%s│%s\n' "$BOLD" "$RESET" "$WHITE" "$w" "$s_out" "$RESET" "$BOLD" "$RESET" >&2
            printf '%s  └%s┘%s\n' "$BOLD" "$bline" "$RESET" >&2

            printf '\n' >&2
            _SS_INITIAL="0"
            local confirm
            confirm=$(single_select \
                "Proceed with download?" \
                "Esc=back" \
                "Yes, proceed" \
                "No, cancel")

            if [ "$confirm" = "__BACK__" ]; then
                cursor_up "$summary_lines"
                clear_lines "$summary_lines"
                step=6; continue
            fi

            if [ "$confirm" != "Yes, proceed" ]; then
                printf '  %sCancelled.%s\n\n' "$YELLOW" "$RESET" >&2
                exit 0
            fi

            break  # Confirmed — proceed to download
            ;;
        esac
    done

    # ── Download ──
    run_downloads "$market" "$dtype" "$symbols_str" "$intervals_str" "$splits_str"

    # ── Merge ──
    merge_outputs "$market" "$dtype" "$symbols_str" "$intervals_str" "$start_date" "$end_date" "$splits_str"
}

# ============================================================================
# Section 9: Main Entry Point
# ============================================================================

main() {
    # Check dependencies
    local missing=""
    for cmd in curl unzip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
        missing="$missing shasum/sha256sum"
    fi
    if [ -n "$missing" ]; then
        printf '%sError: Missing required dependencies:%s%s\n' "$RED" "$missing" "$RESET" >&2
        exit 1
    fi

    # Ensure terminal is available for interactive input
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        printf '%sError: Interactive terminal required. Run from a terminal emulator.%s\n' "$RED" "$RESET" >&2
        exit 1
    fi

    run_interactive
}

main "$@"
