#!/bin/bash

SCRIPT_VERSION="0.2"
GIT_REPO="Mate-Panel/wg-mate-script"
SCRIPT_URL="https://raw.githubusercontent.com/${GIT_REPO}/main/install.sh"
SCRIPT_API_URL="https://api.github.com/repos/${GIT_REPO}/contents/install.sh?ref=main"

if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m[ERROR]\033[0m Please run this script as \033[1mroot\033[0m."
    exit 1
fi

RUNTIME_DIR="/run/wg-mate"
if ! mkdir -p "$RUNTIME_DIR" 2>/dev/null; then
    RUNTIME_DIR="/var/tmp/wg-mate"
    mkdir -p "$RUNTIME_DIR" 2>/dev/null
fi
chmod 700 "$RUNTIME_DIR" 2>/dev/null
INSTALL_LOG="$RUNTIME_DIR/install.log"

trap 'tput cnorm 2>/dev/null' EXIT

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none

ETA_REMAINING=0
STEP_NO=0
STEP_TOTAL=0

_fmt_secs() {
    local __var=$1 s=$2
    [ "$s" -lt 0 ] && s=0
    if [ "$s" -lt 60 ]; then
        printf -v "$__var" '%ds' "$s"
    else
        printf -v "$__var" '%dm%02ds' $((s / 60)) $((s % 60))
    fi
}

_now_secs() {
    if [ -n "${EPOCHSECONDS:-}" ]; then
        printf -v "$1" '%s' "$EPOCHSECONDS"
    else
        printf -v "$1" '%s' "$(date +%s)"
    fi
}

_bar() {
    local __var=$1 pct=$2 width=${3:-14} filled i out=""
    [ "$pct" -gt 100 ] && pct=100; [ "$pct" -lt 0 ] && pct=0
    filled=$(( pct * width / 100 ))
    for ((i = 0; i < width; i++)); do
        if [ "$i" -lt "$filled" ]; then out+="█"; else out+="░"; fi
    done
    printf -v "$__var" '%s' "$out"
}

_step_eta() {
    case "$1" in
        "Preparing package manager"*)        echo 5   ;;
        "Installing prerequisites"*)         echo 25  ;;
        "Adding Docker repository"*)         echo 20  ;;
        "Updating package lists"*)           echo 45  ;;
        "Installing Docker Engine"*)         echo 120 ;;
        "Installing Docker from the distribution"*) echo 90 ;;
        "Enabling & starting Docker"*)       echo 10  ;;
        "Loading kernel modules"*)           echo 5   ;;
        "Removing containers from another"*) echo 10  ;;
        "Creating directories"*)             echo 3   ;;
        "Writing environment file"*)         echo 3   ;;
        "Writing compose file"*)             echo 3   ;;
        "Installing host helpers"*)          echo 35  ;;
        "Installing the wg-mate command"*)   echo 4   ;;
        "Pulling images"*)                   echo 180 ;;
        "Starting containers"*)              echo 30  ;;
        "Recreating containers"*)            echo 30  ;;
        "Stopping containers"*)              echo 12  ;;
        "Waiting for the API"*)              echo 45  ;;
        "Dumping the database"*)             echo 20  ;;
        "Creating the archive"*)             echo 12  ;;
        "Restoring the database"*)           echo 30  ;;
        "Restoring panel data"*)             echo 6   ;;
        "Removing containers"*)              echo 25  ;;
        "Removing images & volumes"*)        echo 25  ;;
        "Removing host helpers"*)            echo 6   ;;
        *)                                   echo 8   ;;
    esac
}

plan_eta() {
    STEP_TOTAL=0; ETA_REMAINING=0; STEP_NO=0
    if ! phase_done DOCKER; then
        if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
            STEP_TOTAL=$((STEP_TOTAL + 2)); ETA_REMAINING=$((ETA_REMAINING + 15))
        else
            STEP_TOTAL=$((STEP_TOTAL + 6)); ETA_REMAINING=$((ETA_REMAINING + 200))
        fi
    fi
    phase_done CONFIG || { STEP_TOTAL=$((STEP_TOTAL + 5)); ETA_REMAINING=$((ETA_REMAINING + 48));  }
    phase_done IMAGES || { STEP_TOTAL=$((STEP_TOTAL + 1)); ETA_REMAINING=$((ETA_REMAINING + 180)); }
    phase_done START  || { STEP_TOTAL=$((STEP_TOTAL + 2)); ETA_REMAINING=$((ETA_REMAINING + 75));  }
}

print_header() {
    echo ""
    echo -e "\033[1;34m╭────────────────────────────────────────────────╮\033[0m"
    printf  "\033[1;34m│\033[0m \033[1;36m%-46s\033[0m \033[1;34m│\033[0m\n" "$1"
    echo -e "\033[1;34m╰────────────────────────────────────────────────╯\033[0m"
}

RUN_STEP_PID=""

_kill_tree() {
    local parent="$1" child
    for child in $(pgrep -P "$parent" 2>/dev/null); do
        _kill_tree "$child"
    done
    kill "$parent" 2>/dev/null
}

_run_step_abort() {
    tput cnorm 2>/dev/null
    if [ -n "$RUN_STEP_PID" ]; then
        _kill_tree "$RUN_STEP_PID"
        sleep 0.3
        kill -9 "$RUN_STEP_PID" 2>/dev/null
        wait "$RUN_STEP_PID" 2>/dev/null
        RUN_STEP_PID=""
    fi
    printf "\r\033[K \033[1;31m✘\033[0m interrupted\n"
    exit 130
}

run_step() {
    local msg="$1"
    local cmd="$2"
    local eta="${3:-$(_step_eta "$msg")}"
    [ "$eta" -lt 1 ] && eta=1
    STEP_NO=$((STEP_NO + 1))
    local counter="$STEP_NO"
    [ "$STEP_TOTAL" -gt 0 ] && counter="$STEP_NO/$STEP_TOTAL"
    : > "$INSTALL_LOG"
    local start; _now_secs start
    { eval "$cmd"; } >> "$INSTALL_LOG" 2>&1 &
    local pid=$!
    RUN_STEP_PID="$pid"
    trap _run_step_abort INT TERM
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local n=${#frames[@]}
    local i=0 now el pct left orem lefttxt otxt bar eltxt tmptxt
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        _now_secs now
        el=$(( now - start ))
        pct=$(( el * 100 / eta ))
        [ "$pct" -gt 95 ] && pct=95
        left=$(( eta - el ))
        if [ "$left" -gt 0 ]; then
            _fmt_secs tmptxt "$left"; lefttxt="~${tmptxt} left"
        else
            lefttxt="finishing…"
        fi
        otxt=""
        if [ "$ETA_REMAINING" -gt 0 ]; then
            orem=$(( ETA_REMAINING - el )); [ "$orem" -lt 0 ] && orem=0
            _fmt_secs tmptxt "$orem"
            otxt=" \033[0;37m· total ~${tmptxt}\033[0m"
        fi
        _bar bar "$pct" 14
        _fmt_secs eltxt "$el"
        printf "\r\033[K \033[1;33m%s\033[0m \033[0;37m[%s]\033[0m %s  \033[1;36m▕%s▏\033[0m \033[0;37m%s · %s\033[0m%b" \
            "${frames[$i]}" "$counter" "$msg" "$bar" "$eltxt" "$lefttxt" "$otxt"
        i=$(( (i + 1) % n ))
        sleep 0.2
    done
    wait "$pid"
    local rc=$?
    RUN_STEP_PID=""
    trap - INT TERM
    _now_secs now
    el=$(( now - start ))
    tput cnorm 2>/dev/null
    if [ "$ETA_REMAINING" -gt 0 ]; then
        ETA_REMAINING=$(( ETA_REMAINING - eta )); [ "$ETA_REMAINING" -lt 0 ] && ETA_REMAINING=0
    fi
    _fmt_secs eltxt "$el"
    if [ "$rc" -eq 0 ]; then
        printf "\r\033[K \033[1;32m✔\033[0m \033[0;37m[%s]\033[0m %s \033[0;37m(%s)\033[0m\n" "$counter" "$msg" "$eltxt"
    else
        printf "\r\033[K \033[1;31m✘\033[0m \033[0;37m[%s]\033[0m %s \033[0;37m(%s)\033[0m\n" "$counter" "$msg" "$eltxt"
    fi
    return "$rc"
}

show_step_error() {
    echo -e "\033[1;31m──────────────── Error details ─────────────────\033[0m"
    tail -n 20 "$INSTALL_LOG" 2>/dev/null
    echo -e "\033[1;31m─────────────────────────────────────────────────\033[0m"
}

C_BORDER=$'\033[1;36m'; C_TITLE=$'\033[1;37m'; C_DIM=$'\033[0;37m'
C_KEY=$'\033[1;33m';    C_TXT=$'\033[0;37m';   C_OK=$'\033[1;32m'
C_BAD=$'\033[1;31m';    C_WARN=$'\033[1;33m';  C_PROMPT=$'\033[1;36m'
CR=$'\033[0m'
UI_W=52

_repeat() { local ch="$1" n="$2" out="" i; for ((i=0;i<n;i++)); do out+="$ch"; done; printf '%s' "$out"; }
RULE_LINE="$(_repeat "─" "$UI_W")"
DRULE_LINE="$(_repeat "━" "$UI_W")"
_rule()   { printf "  ${C_BORDER}%s${CR}\n" "$RULE_LINE"; }
_drule()  { printf "  ${C_BORDER}%s${CR}\n" "$DRULE_LINE"; }
banner()  {
    echo
    _drule
    printf "  ${C_OK}▌${CR} ${C_TITLE}WG-MATE${CR}  ${C_DIM}— WireGuard / OpenVPN${CR}  ${C_DIM}v${SCRIPT_VERSION}${CR}\n"
    _drule
}
_mi()     {
    local n="$1" pad
    pad=$(( 3 - ${#n} ))
    [ "$pad" -lt 1 ] && pad=1
    printf "    ${C_KEY}[%s]${CR}%*s${C_TXT}%b${CR}\n" "$n" "$pad" "" "$2"
}

RESOLV="/etc/resolv.conf"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9")

dns_works() {
    getent hosts github.com >/dev/null 2>&1 && return 0
    getent hosts ghcr.io    >/dev/null 2>&1 && return 0
    return 1
}

ensure_dns() {
    dns_works && return 0
    echo -e "  ${C_WARN}!${CR} ${C_WARN}DNS resolution failed - configuring public DNS...${CR}"
    if [ -L "$RESOLV" ]; then
        rm -f "$RESOLV" 2>/dev/null
    elif [ -f "$RESOLV" ] && [ ! -f "${RESOLV}.wgmate.bak" ]; then
        cp -a "$RESOLV" "${RESOLV}.wgmate.bak" 2>/dev/null
    fi
    { local d; for d in "${DNS_SERVERS[@]}"; do echo "nameserver $d"; done; } > "$RESOLV" 2>/dev/null
    if command -v resolvectl >/dev/null 2>&1; then
        local ifc; ifc=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
        [ -n "$ifc" ] && resolvectl dns "$ifc" "${DNS_SERVERS[@]}" 2>/dev/null || true
    fi
    sleep 1
    dns_works && { echo -e "  ${C_OK}●${CR} ${C_OK}DNS is now working.${CR}"; return 0; }
    echo -e "  ${C_BAD}●${CR} ${C_BAD}DNS still failing after applying public resolvers.${CR}"
    return 1
}

_link_wgmate() {
    local master="$1" link="$2"
    chmod +x "$master" 2>/dev/null
    if [ -f "$link" ] && [ ! -L "$link" ] && grep -qxF "SCRIPT=\"${master}\"" "$link" 2>/dev/null; then
        chmod +x "$link" 2>/dev/null
        return 0
    fi
    if [ ! -e "$link" ] || [ "$(readlink -f "$link" 2>/dev/null)" != "$(readlink -f "$master" 2>/dev/null)" ]; then
        rm -f "$link" 2>/dev/null
        ln -sf "$master" "$link"
    fi
    chmod +x "$link" 2>/dev/null
}

running_from_repo() {
    local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" dir=""
    [ -n "$src" ] && [ -f "$src" ] || return 1
    dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd)" || return 1
    [ -d "$dir/.git" ] || [ -d "$dir/../.git" ]
}

strip_v() { printf '%s' "${1#v}"; }

version_ge() {
    local a b
    a="$(strip_v "$1")"; b="$(strip_v "$2")"
    [ "$a" = "$b" ] && return 0
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
}

valid_installer() {
    local f="$1"
    [ -s "$f" ] || return 1
    head -n1 "$f" | grep -q '^#!/bin/bash' || return 1
    grep -q 'process_arguments' "$f" || return 1
    bash -n "$f" 2>/dev/null || return 1
    return 0
}

download_to() {
    local out="$1" url="$2" timeout="$3" code
    shift 3
    rm -f "$out"
    code=$(curl -sSL --connect-timeout 10 --max-time "$timeout" --retry 2 --retry-delay 1 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$@" -w '%{http_code}' -o "$out" "$url" 2>/dev/null)
    if [ "${WG_MATE_DEBUG:-0}" = "1" ]; then
        echo "  fetch ${url%%\?*} -> HTTP ${code:-none} ($(stat -c %s "$out" 2>/dev/null || echo 0) bytes)" >&2
    fi
    [ "$code" = "200" ] && [ -s "$out" ] && return 0
    rm -f "$out"
    wget -q --timeout="$timeout" --tries=2 --no-cache --no-cookies -O "$out" "$url" 2>/dev/null \
        && [ -s "$out" ] && return 0
    rm -f "$out"
    return 1
}

fetch_installer() {
    local out="$1" url="${2:-$SCRIPT_URL}" timeout="${3:-15}"
    if download_to "$out" "$SCRIPT_API_URL" "$timeout" -H 'Accept: application/vnd.github.raw'; then
        sed -i 's/\r$//' "$out"
        valid_installer "$out" && return 0
    fi
    if download_to "$out" "$url" "$timeout"; then
        sed -i 's/\r$//' "$out"
        valid_installer "$out" && return 0
    fi
    rm -f "$out"
    return 1
}

installer_version_of() {
    grep -m1 '^SCRIPT_VERSION=' "$1" 2>/dev/null | cut -d= -f2- | tr -d "'\"\r"
}

remote_installer_version() {
    local head="" version="" timeout="${1:-12}"
    head="$(curl -fsSL --connect-timeout 8 --max-time "$timeout" -r 0-399 \
        -H 'Cache-Control: no-cache' -H 'Accept: application/vnd.github.raw' \
        "$SCRIPT_API_URL" 2>/dev/null)"
    version="$(printf '%s\n' "$head" | grep -m1 '^SCRIPT_VERSION=' | cut -d= -f2- | tr -d "'\"\r")"
    if [ -z "$version" ]; then
        head="$(curl -fsSL --connect-timeout 8 --max-time "$timeout" -r 0-399 \
            -H 'Cache-Control: no-cache' "$SCRIPT_URL" 2>/dev/null)"
        version="$(printf '%s\n' "$head" | grep -m1 '^SCRIPT_VERSION=' | cut -d= -f2- | tr -d "'\"\r")"
    fi
    [ -n "$version" ] || return 1
    printf '%s' "$version"
}

function self_update_script() {
    local MASTER_PATH="/opt/wg-mate/install.sh"
    local BIN_LINK="/usr/local/bin/wg-mate"
    local TEMP_FILE="${RUNTIME_DIR}/update.sh"
    local SELF="${BASH_SOURCE[0]}"

    if [ "${WG_MATE_NO_SELF_UPDATE:-0}" = "1" ]; then
        echo -e "\e[33mSelf-update is disabled by WG_MATE_NO_SELF_UPDATE.\033[0m"
        return 0
    fi
    [ "${WG_MATE_SELF_UPDATED:-0}" = "1" ] && return 0
    if running_from_repo; then
        echo -e "\e[33mRunning from a git checkout (${SELF}) - self-update skipped.\033[0m"
        return 0
    fi

    ensure_dns >/dev/null 2>&1

    echo -e "\e[33mChecking for the latest script version...\033[0m"
    local QUICK_REMOTE
    QUICK_REMOTE="$(remote_installer_version)"
    if [ -n "$QUICK_REMOTE" ] && [ "$QUICK_REMOTE" = "$SCRIPT_VERSION" ] && [ -f "$MASTER_PATH" ] \
        && [ "$(installer_version_of "$MASTER_PATH")" = "$SCRIPT_VERSION" ]; then
        _link_wgmate "$MASTER_PATH" "$BIN_LINK"
        echo -e "\e[32mScript is up to date (v${SCRIPT_VERSION}).\033[0m"
        return 0
    fi
    if [ -z "$QUICK_REMOTE" ]; then
        echo -e "\e[33mQuick version check timed out - downloading the full script...\033[0m"
    elif version_ge "$SCRIPT_VERSION" "$QUICK_REMOTE"; then
        echo -e "\e[33mGitHub still has v${QUICK_REMOTE}, this script is v${SCRIPT_VERSION} - verifying...\033[0m"
    else
        echo -e "\e[32mNew version available: v${QUICK_REMOTE} - downloading...\033[0m"
    fi
    if ! fetch_installer "$TEMP_FILE" "$SCRIPT_URL" 30; then
        echo -e "\e[91mWarning: could not fetch a valid update from GitHub. Using current version.\033[0m"
        echo -e "\e[90m  tried ${SCRIPT_API_URL%%\?*} and ${SCRIPT_URL}\033[0m"
        echo -e "\e[90m  re-run with WG_MATE_DEBUG=1 to see the HTTP status.\033[0m"
        rm -f "$TEMP_FILE"
        [ -f "$MASTER_PATH" ] && _link_wgmate "$MASTER_PATH" "$BIN_LINK"
        return 0
    fi

    local REMOTE_HASH MASTER_HASH SELF_HASH REMOTE_VERSION MASTER_VERSION
    REMOTE_HASH=$(md5sum "$TEMP_FILE" | awk '{print $1}')
    REMOTE_VERSION=$(installer_version_of "$TEMP_FILE")
    [ -f "$SELF" ] && SELF_HASH=$(md5sum "$SELF" | awk '{print $1}')
    if [ -f "$MASTER_PATH" ]; then
        MASTER_HASH=$(md5sum "$MASTER_PATH" | awk '{print $1}')
        MASTER_VERSION=$(installer_version_of "$MASTER_PATH")
    fi

    if [ "$MASTER_HASH" = "$REMOTE_HASH" ] && [ "$SELF_HASH" = "$REMOTE_HASH" ]; then
        rm -f "$TEMP_FILE"
        _link_wgmate "$MASTER_PATH" "$BIN_LINK"
        echo -e "\e[32mScript is up to date (v${SCRIPT_VERSION}).\033[0m"
        return 0
    fi

    if [ -n "$MASTER_VERSION" ] && [ -n "$REMOTE_VERSION" ] \
        && [ "$MASTER_VERSION" != "$REMOTE_VERSION" ] \
        && version_ge "$MASTER_VERSION" "$REMOTE_VERSION"; then
        echo -e "\e[33mDownload is older (v${REMOTE_VERSION}) than the installed script (v${MASTER_VERSION}) - keeping the installed one.\033[0m"
    elif [ "$MASTER_HASH" != "$REMOTE_HASH" ]; then
        if [ -z "$MASTER_HASH" ]; then
            echo -e "\e[32mInstalling script to the system...\033[0m"
        else
            echo -e "\e[32mNew version found: ${MASTER_VERSION:-unknown} -> ${REMOTE_VERSION:-newer} - updating...\033[0m"
        fi
        mkdir -p "$(dirname "$MASTER_PATH")" 2>/dev/null
        install -m 0755 "$TEMP_FILE" "$MASTER_PATH" 2>/dev/null \
            || { cp -f "$TEMP_FILE" "$MASTER_PATH"; chmod +x "$MASTER_PATH"; }
    fi

    rm -f "$TEMP_FILE"
    _link_wgmate "$MASTER_PATH" "$BIN_LINK"
    MASTER_HASH=$(md5sum "$MASTER_PATH" 2>/dev/null | awk '{print $1}')
    if [ -n "$SELF_HASH" ] && [ "$SELF_HASH" = "$MASTER_HASH" ]; then
        echo -e "\e[32mScript is up to date (v${SCRIPT_VERSION}).\033[0m"
        return 0
    fi
    echo -e "\e[32mRestarting with v$(installer_version_of "$MASTER_PATH")...\033[0m"
    sleep 1
    export WG_MATE_SELF_UPDATED=1
    exec bash "$MASTER_PATH" "$@"
}
self_update_script "$@"

APP_NAME="wg-mate"
APP_DIR="/opt/wg-mate"
COMPOSE_PROJECT="wg-mate"
WEB_IMAGE="ghcr.io/mate-panel/wg-mate-web"
API_IMAGE="ghcr.io/mate-panel/wg-mate-api"
DB_IMAGE="postgres:16-alpine"
SHORTCUT="/usr/local/bin/wg-mate"
LATEST_CACHE="$RUNTIME_DIR/latest_panel"
INSTALLER_CACHE="$RUNTIME_DIR/latest_installer"
IP_CACHE="$RUNTIME_DIR/server_ip"
CACHE_TTL_HIT=3600
CACHE_TTL_MISS=600
MENU_CACHE_DIR=""

DEFAULT_WEB_PORT="3000"
DEFAULT_API_PORT="52653"
DEFAULT_DB_PORT="5433"
DEFAULT_TZ="Asia/Tehran"
LICENSE_PUBKEY="ksB0JTWOEQj2bZlG5s9zKeEfoqDo9nmf/a0JWOjuau4="

IMAGE_TAG="latest"
WEB_PORT="$DEFAULT_WEB_PORT"
API_PORT="$DEFAULT_API_PORT"
DB_PORT="$DEFAULT_DB_PORT"
TZ_VALUE="$DEFAULT_TZ"
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
SHOW_CREDENTIALS=0

STATE_DIR="/opt/wg-mate"
STATE_FILE="$STATE_DIR/.wgmate_install_state"

state_init() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    if [ ! -f "$STATE_FILE" ]; then
        : > "$STATE_FILE"
        chmod 600 "$STATE_FILE" 2>/dev/null
    fi
}

state_set() {
    state_init
    sed -i "/^$1=/d" "$STATE_FILE" 2>/dev/null
    printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"
}

state_get() {
    [ -f "$STATE_FILE" ] || return 0
    grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

phase_done() {
    [ -f "$STATE_FILE" ] && grep -qxF "PHASE:$1" "$STATE_FILE" 2>/dev/null
}

mark_phase() {
    state_init
    grep -qxF "PHASE:$1" "$STATE_FILE" 2>/dev/null || echo "PHASE:$1" >> "$STATE_FILE"
}

has_resumable_state() {
    [ -f "$STATE_FILE" ] || return 1
    { grep -q '^PHASE:' "$STATE_FILE" 2>/dev/null || grep -q '^STARTED=' "$STATE_FILE" 2>/dev/null; } \
        && ! phase_done COMPLETE
}

state_clear() { rm -f "$STATE_FILE" 2>/dev/null; }

install_pause() {
    local where="$1"
    echo ""
    echo -e "  ${C_WARN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
    echo -e "  ${C_WARN}● Installation paused${CR} ${C_DIM}(${where})${CR}"
    echo -e "  ${C_DIM}This is usually caused by the server losing internet or a network error.${CR}"
    echo ""
    echo -e "  ${C_TXT}Completed steps are saved. Just run it again:${CR}"
    echo -e "      ${C_KEY}wg-mate install${CR}"
    echo -e "  ${C_DIM}It resumes from this step; values you already entered (ports/admin/...) will not be asked again.${CR}"
    echo -e "  ${C_WARN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
    echo ""
    exit 1
}

_dot() {
    case "$1" in
        ok)   printf "${C_OK}●${CR}"  ;;
        bad)  printf "${C_BAD}●${CR}" ;;
        warn) printf "${C_WARN}●${CR}";;
        *)    printf "${C_DIM}●${CR}" ;;
    esac
}

_sec() { printf "\n  ${C_KEY}▌${CR} ${C_TITLE}%s${CR}\n" "$1"; _rule; }
_kv()  { printf "    ${C_DIM}%-11s${CR}${C_BORDER}:${CR} %b${CR}\n" "$1" "$2"; }

_ok()   { printf "    ${C_OK}✔${CR} ${C_TXT}%b${CR}\n" "$*"; }
_warn() { printf "    ${C_WARN}!${CR} ${C_WARN}%b${CR}\n" "$*"; }
_bad()  { printf "    ${C_BAD}●${CR} ${C_BAD}%b${CR}\n" "$*"; }
_info() { printf "    ${C_DIM}→ %b${CR}\n" "$*"; }

_back_to_menu() {
    echo ""
    [ -t 0 ] || return 0
    printf "  ${C_PROMPT}❯${CR} Press Enter to return to the menu... "
    read -r _ || return 0
    return 0
}

_ask() {
    local prompt="$1" def="${2:-}" out=""
    if [ -n "$def" ]; then
        printf "  ${C_PROMPT}❯${CR} %s ${C_DIM}[%s]${CR}: " "$prompt" "$def" >&2
        read -r out
        printf '%s' "${out:-$def}"
    else
        printf "  ${C_PROMPT}❯${CR} %s: " "$prompt" >&2
        read -r out
        printf '%s' "$out"
    fi
}

_ask_secret() {
    local prompt="$1" out=""
    printf "  ${C_PROMPT}❯${CR} %s: " "$prompt" >&2
    read -r -s out
    echo >&2
    printf '%s' "$out"
}

_ask_password_confirm() {
    local prompt="$1" p1="" p2=""
    while true; do
        p1="$(_ask_secret "$prompt")"
        p1="${p1//[$'\r\n']/}"
        if [ "${#p1}" -lt 6 ]; then
            _warn "Password must be at least 6 characters." >&2
            continue
        fi
        p2="$(_ask_secret "Confirm password")"
        p2="${p2//[$'\r\n']/}"
        if [ "$p1" = "$p2" ]; then
            printf '%s' "$p1"
            return 0
        fi
        _warn "Passwords do not match - try again." >&2
    done
}

_confirm() {
    local prompt="$1" def="${2:-N}" ans=""
    [ "$ARG_YES" = "1" ] && return 0
    if [ ! -t 0 ]; then
        case "$def" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
    fi
    printf "  ${C_PROMPT}❯${CR} %s ${C_DIM}[y/N]${CR}: " "$prompt" >&2
    read -r ans
    [ -z "$ans" ] && ans="$def"
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

have() { command -v "$1" >/dev/null 2>&1; }

rand_hex() {
    local n="${1:-16}"
    if have openssl; then
        openssl rand -hex "$n"
    elif [ -r /dev/urandom ]; then
        head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'
    else
        date +%s%N | sha256sum | head -c "$((n * 2))"
    fi
}

shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
json_quote()  { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
sql_quote()   { printf '%s' "$1" | sed "s/'/''/g"; }

is_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

ENV_FILE="${APP_DIR}/.env"

env_get() {
    local key="$1" line value=""
    [ -f "$ENV_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line == *"${key}="* ]] || continue
        [[ $line =~ ^[[:space:]]*${key}=(.*)$ ]] || continue
        value="${BASH_REMATCH[1]}"
        break
    done < "$ENV_FILE"
    value="${value%$'\r'}"
    case "$value" in
        "'"*"'") value="${value#\'}"; value="${value%\'}" ;;
        '"'*'"') value="${value#\"}"; value="${value%\"}" ;;
    esac
    printf '%s' "$value"
}

env_set() {
    local key="$1" value="$2" file tmp
    file="$ENV_FILE"
    [ -f "$file" ] || return 0
    tmp="$(mktemp)" || return 1
    grep -v "^[[:space:]]*${key}=" "$file" > "$tmp" 2>/dev/null
    if [ -s "$tmp" ] && [ -n "$(tail -c1 "$tmp")" ]; then
        printf '\n' >> "$tmp"
    fi
    printf '%s=%s\n' "$key" "$(shell_quote "$value")" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    chmod 600 "$file"
}

env_unset() {
    local key="$1" file tmp
    file="$ENV_FILE"
    [ -f "$file" ] || return 0
    grep -q "^[[:space:]]*${key}=" "$file" 2>/dev/null || return 0
    tmp="$(mktemp)" || return 1
    grep -v "^[[:space:]]*${key}=" "$file" > "$tmp" 2>/dev/null
    cat "$tmp" > "$file"
    rm -f "$tmp"
    chmod 600 "$file"
}

env_default() {
    local key="$1" value="$2"
    [ -n "$(env_get "$key")" ] && return 0
    env_set "$key" "$value"
}

installed() {
    [ -f "$APP_DIR/docker-compose.yml" ] && [ -f "$ENV_FILE" ]
}

menu_cache_begin() {
    menu_cache_end
    MENU_CACHE_DIR="$(mktemp -d 2>/dev/null)"
}

menu_cache_end() {
    [ -n "$MENU_CACHE_DIR" ] && rm -rf "$MENU_CACHE_DIR" 2>/dev/null
    MENU_CACHE_DIR=""
}

menu_cache() {
    local key="$1"; shift
    local f rc
    if [ -z "$MENU_CACHE_DIR" ] || [ ! -d "$MENU_CACHE_DIR" ]; then
        "$@"
        return $?
    fi
    f="${MENU_CACHE_DIR}/${key}"
    if [ ! -f "$f.rc" ]; then
        "$@" > "$f.out" 2>/dev/null
        printf '%s' "$?" > "$f.rc"
    fi
    cat "$f.out" 2>/dev/null
    rc="$(cat "$f.rc" 2>/dev/null)"
    return "${rc:-1}"
}

_docker_ready() {
    have docker && docker info >/dev/null 2>&1
}

docker_ready() {
    menu_cache docker_ready _docker_ready
}

compose() {
    local args=(-p "$COMPOSE_PROJECT" -f "$APP_DIR/docker-compose.yml")
    if [ -f "$ENV_FILE" ]; then
        args+=(--env-file "$ENV_FILE")
    fi
    if docker compose version >/dev/null 2>&1; then
        docker compose "${args[@]}" "$@"
    elif have docker-compose; then
        docker-compose "${args[@]}" "$@"
    else
        echo "docker compose plugin not found" >&2
        return 1
    fi
}

port_pid() {
    local p="$1" line=""
    have ss || return 0
    line="$(ss -Hltnp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | head -1)"
    [ -n "$line" ] || return 0
    printf '%s' "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
}

port_in_use() {
    local p="$1"
    if have ss; then
        ss -Hltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && return 0
    elif have netstat; then
        netstat -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && return 0
    fi
    return 1
}

pid_container() {
    local pid="$1" id=""
    [ -n "$pid" ] || return 0
    [ -r "/proc/${pid}/cgroup" ] || return 0
    id="$(grep -oE '[0-9a-f]{64}' "/proc/${pid}/cgroup" 2>/dev/null | head -1)"
    [ -n "$id" ] || return 0
    docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||'
}

port_owner() {
    local p="$1" pid name container
    pid="$(port_pid "$p")"
    [ -n "$pid" ] || return 0
    container="$(pid_container "$pid")"
    if [ -n "$container" ]; then
        printf 'container %s' "$container"
        return 0
    fi
    name="$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')"
    printf '%s (pid %s)' "${name:-process}" "$pid"
}

our_container_on_port() {
    local p="$1" pid container
    pid="$(port_pid "$p")"
    [ -n "$pid" ] || return 1
    container="$(pid_container "$pid")"
    case "$container" in
        "${COMPOSE_PROJECT}-"*) return 0 ;;
        *) return 1 ;;
    esac
}

free_port_from() {
    local p="$1" limit=$(( $1 + 40 ))
    while [ "$p" -le "$limit" ]; do
        if ! port_in_use "$p"; then
            printf '%s' "$p"
            return 0
        fi
        p=$((p + 1))
    done
    printf '%s' "$1"
}

ask_port() {
    local label="$1" current="$2" chosen="" owner="" suggestion=""
    while true; do
        chosen="$(_ask "$label" "$current")"
        if ! is_port "$chosen"; then
            _warn "Not a valid port: ${chosen}" >&2
            continue
        fi
        if port_in_use "$chosen" && ! our_container_on_port "$chosen"; then
            owner="$(port_owner "$chosen")"
            suggestion="$(free_port_from $((chosen + 1)))"
            _warn "Port ${chosen} is taken by ${owner:-another process}." >&2
            if _confirm "Use ${suggestion} instead?" "Y"; then
                printf '%s' "$suggestion"
                return 0
            fi
            continue
        fi
        printf '%s' "$chosen"
        return 0
    done
}

foreign_stacks() {
    docker_ready || return 0
    docker ps -a --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Image}}\t{{.Status}}' 2>/dev/null \
        | awk -F'\t' -v proj="$COMPOSE_PROJECT" \
            '$2 != proj && ($3 ~ /wg-?mate/ || $3 ~ /wgpanel/) { print $1"\t"$3"\t"$4 }'
}

container_counts() {
    menu_cache container_counts _container_counts
}

_container_counts() {
    local up total
    up="$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null | wc -l | tr -d ' ')"
    total="$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null | wc -l | tr -d ' ')"
    printf '%s %s' "${up:-0}" "${total:-0}"
}

_api_health() {
    curl -fsS --max-time 3 "http://127.0.0.1:${API_PORT}/health" 2>/dev/null
}

api_health() {
    menu_cache "api_health_${API_PORT}" _api_health
}

wait_api_healthy() {
    local waited=0 max="${1:-45}"
    while [ "$waited" -lt "$max" ]; do
        _api_health >/dev/null 2>&1 && return 0
        sleep 2
        waited=$((waited + 2))
    done
    _api_health >/dev/null 2>&1
}

panel_version() {
    local body v img
    body="$(api_health)"
    if [ -n "$body" ]; then
        v="$(printf '%s' "$body" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    fi
    img="$(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
        --filter "label=com.docker.compose.service=api" --format '{{.Image}}' 2>/dev/null | head -1)"
    printf '%s' "${img:+${img##*:}}"
}

cache_fresh() {
    local f="$1" max="${2:-$CACHE_TTL_HIT}"
    [ -f "$f" ] || return 1
    [ -s "$f" ] || max="$CACHE_TTL_MISS"
    [ $(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) )) -lt "$max" ]
}

ghcr_token() {
    local repo="$1"
    curl -fsSL --max-time 4 "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" 2>/dev/null \
        | grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4
}

panel_tags() {
    local repo token body
    repo="${API_IMAGE#ghcr.io/}"
    token="$(ghcr_token "$repo")"
    [ -n "$token" ] || return 1
    body="$(curl -fsSL --max-time 5 -H "Authorization: Bearer ${token}" \
        "https://ghcr.io/v2/${repo}/tags/list" 2>/dev/null)"
    [ -n "$body" ] || return 1
    printf '%s' "$body" | tr ',' '\n' | grep -oE '"v[0-9]+(\.[0-9]+)*"' | tr -d '"'
}

get_latest_version() {
    if cache_fresh "$LATEST_CACHE"; then
        cat "$LATEST_CACHE"
        return 0
    fi
    local v
    v="$(panel_tags | sort -V | tail -1)"
    printf '%s' "$v" > "$LATEST_CACHE"
    printf '%s' "$v"
}

get_latest_installer_version() {
    if cache_fresh "$INSTALLER_CACHE"; then
        cat "$INSTALLER_CACHE"
        return 0
    fi
    local v
    v="$(remote_installer_version)"
    printf '%s' "$v" > "$INSTALLER_CACHE"
    printf '%s' "$v"
}


list_tags_desc() {
    local tags
    tags="$(panel_tags)"
    [ -z "$tags" ] && return 1
    printf '%s\n' "$tags" | sort -Vr
}

is_private_ip() {
    case "$1" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|169.254.*|"") return 0 ;;
        *:*) return 0 ;;
        *) return 1 ;;
    esac
}

get_server_ip() {
    if [ -f "$IP_CACHE" ] && [ $(( $(date +%s) - $(stat -c %Y "$IP_CACHE" 2>/dev/null || echo 0) )) -lt 3600 ]; then
        cat "$IP_CACHE"
        return 0
    fi
    local ip
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    if is_private_ip "$ip"; then
        ip=$(curl -4 -fsSL --max-time 3 https://ifconfig.me 2>/dev/null)
        [ -z "$ip" ] && ip=$(curl -4 -fsSL --max-time 3 https://api.ipify.org 2>/dev/null)
        [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -n "$ip" ] || ip=""
    fi
    [ -z "$ip" ] && ip="SERVER"
    echo "$ip" > "$IP_CACHE"
    echo "$ip"
}

panel_url() { printf 'http://%s:%s' "$(get_server_ip)" "$WEB_PORT"; }

apt_recover() {
    have apt-get || return 0
    local i=0
    while have fuser && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && [ "$i" -lt 60 ]; do
        sleep 2
        i=$((i + 1))
    done
    systemctl stop unattended-upgrades >/dev/null 2>&1
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null
    dpkg --configure -a 2>/dev/null
    apt-get -f install -y -o DPkg::Lock::Timeout=180 2>/dev/null
    return 0
}

detect_os() {
    OS_ID=""; OS_VERSION_ID=""; OS_CODENAME=""; OS_PRETTY=""; OS_ID_LIKE=""
    [ -f /etc/os-release ] || return 1
    IFS=$'\n' read -r -d '' OS_ID OS_VERSION_ID OS_CODENAME OS_PRETTY OS_ID_LIKE < <(
        . /etc/os-release
        printf '%s\n%s\n%s\n%s\n%s\n\0' "${ID:-}" "${VERSION_ID:-}" \
            "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" "${PRETTY_NAME:-}" "${ID_LIKE:-}"
    )
    return 0
}

docker_repo_distro() {
    detect_os
    case "${OS_ID_LIKE:-${OS_ID:-ubuntu}}" in
        *debian*) printf 'debian' ;;
        *) printf 'ubuntu' ;;
    esac
}

setup_docker_repo() {
    local distro codename arch
    distro="$(docker_repo_distro)"
    detect_os
    codename="$OS_CODENAME"
    [ -n "$codename" ] || codename="$(lsb_release -cs 2>/dev/null || echo stable)"
    arch="$(dpkg --print-architecture)"
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc || return 1
        chmod a+r /etc/apt/keyrings/docker.asc
    fi
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y -o DPkg::Lock::Timeout=180
}

install_docker_engine() {
    if have docker && docker compose version >/dev/null 2>&1; then
        return 0
    fi
    if have apt-get; then
        apt-get install -y -o DPkg::Lock::Timeout=180 docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif have dnf; then
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null
        dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    elif have yum; then
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        echo "unsupported distribution - install docker manually, then re-run" >&2
        return 1
    fi
}

install_docker_fallback() {
    have apt-get || return 1
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update -y -o DPkg::Lock::Timeout=180
    apt-get install -y -o DPkg::Lock::Timeout=180 docker.io docker-compose-v2
}

enable_docker() {
    systemctl enable --now docker >/dev/null 2>&1
    local i=0
    while [ "$i" -lt 15 ]; do
        docker info >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    docker info >/dev/null 2>&1
}

ensure_kernel_mods() {
    have modprobe || return 0
    modprobe wireguard 2>/dev/null || echo "wireguard kernel module unavailable (install linux-headers for this kernel)"
    modprobe tun 2>/dev/null
    return 0
}

remove_foreign_stacks() {
    local rows name image status
    local names=()
    rows="$(foreign_stacks)"
    [ -n "$rows" ] || return 0
    while IFS=$'\t' read -r name image status; do
        [ -n "$name" ] || continue
        names+=("$name")
    done <<<"$rows"
    [ "${#names[@]}" -gt 0 ] || return 0
    docker rm -f "${names[@]}" >/dev/null 2>&1
    return 0
}

normalize_channel() {
    case "$1" in
        stable|latest|release|auto) printf 'latest' ;;
        beta|dev|test|nightly|main) printf 'dev' ;;
        v[0-9]*.[0-9]*.[0-9]*) printf '%s' "$1" ;;
        [0-9]*.[0-9]*.[0-9]*) printf 'v%s' "$1" ;;
        *) return 1 ;;
    esac
}

channel_label() {
    case "${1:-latest}" in
        ''|latest) printf 'stable' ;;
        dev) printf 'beta' ;;
        *) printf 'pinned %s' "$1" ;;
    esac
}

load_channel() {
    local v
    v="$(env_get WG_MATE_CHANNEL)"
    IMAGE_TAG="${v:-latest}"
}

load_ports() {
    local v
    v="$(env_get WEB_PORT)"; is_port "$v" && WEB_PORT="$v"
    v="$(env_get API_PORT)"; is_port "$v" && API_PORT="$v"
    v="$(env_get DB_PORT)";  is_port "$v" && DB_PORT="$v"
    v="$(env_get TZ)";       [ -n "$v" ] && TZ_VALUE="$v"
    return 0
}

choose_channel() {
    local current="${1:-latest}"

    if [ -n "$ARG_VERSION" ]; then
        IMAGE_TAG="$(normalize_channel "$ARG_VERSION")" || {
            _bad "Invalid version: ${ARG_VERSION} (expected vX.Y.Z)"
            return 1
        }
        return 0
    fi
    if [ -n "$ARG_CHANNEL" ]; then
        IMAGE_TAG="$(normalize_channel "$ARG_CHANNEL")" || {
            _bad "Unknown channel: ${ARG_CHANNEL} (stable | beta | vX.Y.Z)"
            return 1
        }
        return 0
    fi

    _sec "Select channel"
    _mi "1" "Stable"
    _mi "2" "Beta"
    _mi "3" "Pinned"
    _mi "0" "Back to menu"
    echo ""
    printf "  ${C_PROMPT}❯${CR} Select ${C_DIM}[0-3]${CR}: "
    local S; read -r S
    case "$S" in
        0) return 2 ;;
        ""|1) IMAGE_TAG="latest"; return 0 ;;
        2) IMAGE_TAG="dev"; return 0 ;;
        3)
            local want
            case "$current" in
                latest|dev) want="$(_ask "Version (e.g. v0.2.4)" "")" ;;
                *) want="$(_ask "Version (e.g. v0.2.4)" "$current")" ;;
            esac
            IMAGE_TAG="$(normalize_channel "$want")" || {
                _bad "Invalid version: ${want}"
                return 1
            }
            return 0 ;;
        *) _bad "Invalid selection."; return 1 ;;
    esac
}

containers_exist() {
    docker_ready || return 1
    [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null)" ]
}

db_volume_exists() {
    docker volume inspect "${COMPOSE_PROJECT}_pg_data" >/dev/null 2>&1
}

database_url() {
    local user pass db
    user="$(env_get POSTGRES_USER)"; user="${user:-wgmate}"
    pass="$(env_get POSTGRES_PASSWORD)"
    db="$(env_get POSTGRES_DB)"; db="${db:-wgmate}"
    printf 'postgres://%s:%s@127.0.0.1:%s/%s?sslmode=disable' "$user" "$pass" "$DB_PORT" "$db"
}

psql_do() {
    local user db
    user="$(env_get POSTGRES_USER)"; user="${user:-wgmate}"
    db="$(env_get POSTGRES_DB)"; db="${db:-wgmate}"
    compose exec -T db psql -v ON_ERROR_STOP=1 -U "$user" -d "$db" -tAc "$1"
}

backup_dir() { printf '%s/backups' "$APP_DIR"; }

install_host_helpers() {
    local sslsh="$APP_DIR/scripts/panel-ssl-apply.sh"
    local netsh="$APP_DIR/scripts/panel-net-apply.sh"
    if ! have nginx; then
        have apt-get || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=180 nginx >/dev/null 2>&1 || return 1
    fi
    mkdir -p "$APP_DIR/scripts"
    cat > "$sslsh" <<'WGMATE_PANEL_SSL_APPLY_SH_EOF'
#!/usr/bin/env bash
# Turns ssl-vhosts.json into host nginx TLS vhosts (panel + sub domains).
# Each cert entry may specify httpsPort (443, 4443, 9990, …). ACME HTTP-01
# still needs public :80. Triggered by wg-mate-panel-ssl.path.
set -euo pipefail

DATA="${PANEL_DATA_DIR:-/opt/wg-mate/data/panel}"
MANIFEST="$DATA/ssl-vhosts.json"
CERTS="$DATA/certs"
NGINX_AVAIL="${NGINX_AVAIL:-/etc/nginx/sites-available}"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/sites-enabled}"
INTERNAL_PORT="${PANEL_INTERNAL_PORT:-3000}"
if [ -f "$DATA/ssl.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$DATA/ssl.env"
  set +a
fi
WEBROOT="$DATA/acme-webroot"
CHALLENGES="$DATA/acme-challenge.txt"
PREFIX="wg-mate-ssl-"
ACME_PREFIX="wg-mate-acme-"
LOG="${PANEL_SSL_LOG:-/var/log/wg-mate-panel-ssl.log}"
ACME_HTTP_PORTS="${PANEL_ACME_HTTP_PORTS:-80,8080,8081,8880}"
ACME_PORT_FILE="$DATA/acme-http-port.txt"

log() { echo "$(date -Is) $*" >>"$LOG" 2>/dev/null || true; }

ensure_traversable() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    chmod a+x "$d" 2>/dev/null || true
    d="$(dirname "$d")"
  done
}

port_owner() {
  local p="$1" out=""
  out="$(ss -lntpH "sport = :$p" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    out="$(ss -lntp 2>/dev/null | awk -v pat=":$p$" '$4 ~ pat' || true)"
  fi
  printf '%s' "$out" | tr -s ' '
}

port_usable() {
  local owner
  owner="$(port_owner "$1")"
  [ -n "$owner" ] || return 0
  case "$owner" in *nginx*) return 0 ;; esac
  return 1
}

pick_acme_ports() {
  local p out=""
  IFS=',' read -r -a _cand <<< "$ACME_HTTP_PORTS"
  for p in "${_cand[@]}"; do
    p="$(echo "$p" | tr -d '[:space:]')"
    [ -n "$p" ] || continue
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || continue
    case "$p" in 22|25|53) continue ;; esac
    if port_usable "$p"; then
      out="$out $p"
    else
      log "ACME port $p is taken by: $(port_owner "$p")"
    fi
  done
  printf '%s' "${out# }"
}

acme_listen_lines() {
  local lines="" p
  for p in $ACME_PORTS; do
    lines="${lines}    listen ${p};
    listen [::]:${p};
"
  done
  printf '%s' "$lines"
}

acme_server_block() {
  local domain="$1" fallback="$2" lines
  lines="$(acme_listen_lines)"
  [ -n "$lines" ] || return 0
  printf 'server {\n%s\n    server_name %s;\n    location /.well-known/acme-challenge/ { root %s; }\n%s\n}\n' \
    "$lines" "$domain" "$WEBROOT" "$fallback"
}

[ -f "$MANIFEST" ] || { log "no manifest at $MANIFEST"; exit 0; }

chmod 755 "$DATA" 2>/dev/null || true
mkdir -p "$WEBROOT" "$CERTS"
ensure_traversable "$WEBROOT"
chmod -R a+rX "$WEBROOT" 2>/dev/null || true
chmod 755 "$CERTS" 2>/dev/null || true
find "$CERTS" -type d -exec chmod 755 {} \; 2>/dev/null || true
find "$CERTS" -name 'fullchain.pem' -exec chmod 644 {} \; 2>/dev/null || true
find "$CERTS" -name 'privkey.pem' -exec chmod 640 {} \; 2>/dev/null || true
if getent group www-data >/dev/null 2>&1; then
  find "$CERTS" -name 'privkey.pem' -exec chgrp www-data {} \; 2>/dev/null || true
fi

ACME_PORTS="$(pick_acme_ports)"
printf '%s\n' "$(echo "$ACME_PORTS" | tr ' ' ',')" >"$ACME_PORT_FILE"
chmod 644 "$ACME_PORT_FILE" 2>/dev/null || true
if [ -z "$ACME_PORTS" ]; then
  log "no usable ACME HTTP port among [$ACME_HTTP_PORTS] — challenge vhosts disabled"
else
  case " $ACME_PORTS " in
    *" 80 "*) log "ACME HTTP-01 will use port 80 (plus: ${ACME_PORTS#80})" ;;
    *) log "port 80 is busy — ACME challenge vhost falls back to [$ACME_PORTS]; Let's Encrypt still validates on public :80" ;;
  esac
fi

TMP="$(mktemp -d)"
cp -a "$NGINX_AVAIL/${PREFIX}"* "$NGINX_AVAIL/${ACME_PREFIX}"* "$TMP/" 2>/dev/null || true

want=""
https_ports_used=""

# Emit one vhost per hostname. Panel+sub may share a domain (and port); ports
# are unioned into a single TLS server block.
while IFS='|' read -r d ports || [ -n "${d:-}" ]; do
  [ -n "${d:-}" ] || continue
  [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || { log "skip invalid domain '$d'"; continue; }

  cert="$CERTS/$d/fullchain.pem"; key="$CERTS/$d/privkey.pem"
  [ -s "$cert" ] && [ -s "$key" ] || { log "missing cert files for $d"; continue; }

  listen_tls=""
  primary_port=""
  for https_port in $ports; do
    [[ "$https_port" =~ ^[0-9]+$ ]] || continue
    [ "$https_port" -ge 1 ] && [ "$https_port" -le 65535 ] || continue
    listen_tls="${listen_tls}    listen ${https_port} ssl;
    listen [::]:${https_port} ssl;
"
    https_ports_used="$https_ports_used $https_port"
    [ -n "$primary_port" ] || primary_port="$https_port"
  done
  [ -n "$listen_tls" ] || { log "no valid https ports for $d"; continue; }

  redir_host="\$host"
  case " $ports " in
    *" 443 "*) ;;
    *) [ -n "$primary_port" ] && [ "$primary_port" != "443" ] && redir_host="\$host:${primary_port}" ;;
  esac

  want="$want $d"

  acme_block="$(acme_server_block "$d" "    location / { return 301 https://${redir_host}\$request_uri; }")"

  cat >"$NGINX_AVAIL/${PREFIX}${d}" <<EOF
${acme_block}
server {
${listen_tls}    server_name ${d};
    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
    client_max_body_size 128m;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    location / {
        proxy_pass         http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   X-Forwarded-Host \$http_host;
        proxy_cache_bypass \$http_upgrade;
        proxy_request_buffering off;
    }
}
EOF
  ln -sf "$NGINX_AVAIL/${PREFIX}${d}" "$NGINX_ENABLED/${PREFIX}${d}"
done < <(python3 - "$MANIFEST" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
by_domain = {}
for c in data.get("certs") or []:
    d = (c.get("domain") or "").strip()
    if not d:
        continue
    p = c.get("httpsPort") or 4443
    try:
        p = int(p)
    except Exception:
        p = 4443
    ports = by_domain.setdefault(d, [])
    if p not in ports:
        ports.append(p)
for d, ports in by_domain.items():
    print(d + "|" + " ".join(str(p) for p in ports))
PY
)

challenging=""
if [ -f "$CHALLENGES" ]; then
  while IFS= read -r d || [ -n "$d" ]; do
    d="$(echo "$d" | tr -d '[:space:]')"
    [ -n "$d" ] || continue
    [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || continue
    case " $want " in *" $d "*) continue ;; esac
    if [ -z "$ACME_PORTS" ]; then
      log "no free HTTP port for the ACME challenge of $d — skipping challenge vhost"
      continue
    fi
    challenging="$challenging $d"
    acme_server_block "$d" "    location / { return 404; }" >"$NGINX_AVAIL/${ACME_PREFIX}${d}"
    ln -sf "$NGINX_AVAIL/${ACME_PREFIX}${d}" "$NGINX_ENABLED/${ACME_PREFIX}${d}"
  done < "$CHALLENGES"
fi

for f in "$NGINX_ENABLED/${PREFIX}"* "$NGINX_AVAIL/${PREFIX}"*; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"; dom="${base#$PREFIX}"
  case " $want " in *" $dom "*) : ;; *) rm -f "$f"; log "removed stale vhost $base" ;; esac
done
for f in "$NGINX_ENABLED/${ACME_PREFIX}"* "$NGINX_AVAIL/${ACME_PREFIX}"*; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"; dom="${base#$ACME_PREFIX}"
  case " $challenging " in *" $dom "*) : ;; *) rm -f "$f"; log "removed challenge vhost $base" ;; esac
done

rollback() {
  rm -f "$NGINX_ENABLED/${PREFIX}"* "$NGINX_AVAIL/${PREFIX}"* "$NGINX_ENABLED/${ACME_PREFIX}"* "$NGINX_AVAIL/${ACME_PREFIX}"*
  if compgen -G "$TMP/*" >/dev/null; then
    cp -a "$TMP/"* "$NGINX_AVAIL/" 2>/dev/null || true
    for f in "$NGINX_AVAIL/${PREFIX}"* "$NGINX_AVAIL/${ACME_PREFIX}"*; do
      [ -e "$f" ] && ln -sf "$f" "$NGINX_ENABLED/$(basename "$f")"
    done
  fi
  systemctl reload nginx >>"$LOG" 2>&1 || true
  rm -rf "$TMP"
}

if ! nginx -t >>"$LOG" 2>&1; then
  rollback
  log "nginx -t FAILED — rolled back vhosts"
  exit 1
fi
if ! systemctl reload nginx >>"$LOG" 2>&1; then
  rollback
  log "nginx reload FAILED — rolled back vhosts"
  exit 1
fi

# Confirm each distinct HTTPS port is listening when we have TLS vhosts.
if [ -n "$(echo "$want" | tr -d '[:space:]')" ]; then
  seen_ports=" "
  for hp in $https_ports_used; do
    case "$seen_ports" in *" $hp "*) continue ;; esac
    seen_ports="${seen_ports}${hp} "
    ok=0
    for _ in 1 2 3 4 5 6 7 8; do
      if ss -lnt 2>/dev/null | grep -qE ":${hp}\\b"; then ok=1; break; fi
      sleep 0.25
    done
    if [ "$ok" -ne 1 ]; then
      log "HTTPS :${hp} not listening after reload — rolling back (is the port free?)"
      rollback
      exit 1
    fi
  done
fi

log "applied vhosts — tls:${want:- none} ports:${https_ports_used:- none} challenge:${challenging:- none} acme-http:${ACME_PORTS:- none}"
rm -rf "$TMP"
WGMATE_PANEL_SSL_APPLY_SH_EOF

    cat > "$netsh" <<'WGMATE_PANEL_NET_APPLY_SH_EOF'
#!/usr/bin/env bash
# Applies the panel's chosen PUBLIC port to the host nginx vhost, safely.
# Triggered by the wg-mate-panel-net.path systemd unit whenever the api writes
# /opt/wg-mate/data/panel/panel-net.json. Validates with `nginx -t` and rolls
# back on any failure, so a bad value can never take the panel (or other sites)
# down. The firewall is left untouched unless ufw is active.
set -euo pipefail

INTENT="${PANEL_NET_FILE:-/opt/wg-mate/data/panel/panel-net.json}"
VHOST="${PANEL_VHOST:-/etc/nginx/sites-available/wg-mate}"
INTERNAL_PORT="${PANEL_INTERNAL_PORT:-3000}"
LOG="${PANEL_NET_LOG:-/var/log/wg-mate-panel-net.log}"

log() { echo "$(date -Is) $*" >>"$LOG" 2>/dev/null || true; }

[ -f "$INTENT" ] || { log "no intent file at $INTENT"; exit 0; }
[ -f "$VHOST" ] || { log "vhost $VHOST missing"; exit 0; }

port="$(grep -oE '"panelPort"[[:space:]]*:[[:space:]]*[0-9]+' "$INTENT" | grep -oE '[0-9]+$' | head -1 || true)"
[ -n "${port:-}" ] || { log "no panelPort in $INTENT"; exit 0; }

if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
  log "invalid port '$port' — ignoring"; exit 0
fi
if [ "$port" -eq "$INTERNAL_PORT" ]; then
  log "port $port collides with internal web port — ignoring"; exit 0
fi
case "$port" in
  22|25|53|465|587|993|995|3000|3306|5432|5433|6379|8081|9443|52653)
    log "port $port is reserved — ignoring"; exit 0 ;;
esac

https_ports=""
if [ -f "${PANEL_DATA_DIR:-/opt/wg-mate/data/panel}/ssl.env" ]; then
  https="$(grep -E '^PANEL_HTTPS_PORT=' "${PANEL_DATA_DIR:-/opt/wg-mate/data/panel}/ssl.env" | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)"
  [ -n "$https" ] && https_ports="$https_ports $https"
fi
if [ -f "${PANEL_DATA_DIR:-/opt/wg-mate/data/panel}/ssl-vhosts.json" ]; then
  while IFS= read -r hp; do
    [ -n "$hp" ] && https_ports="$https_ports $hp"
  done < <(python3 - "${PANEL_DATA_DIR:-/opt/wg-mate/data/panel}/ssl-vhosts.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(0)
for c in data.get("certs") or []:
    try:
        print(int(c.get("httpsPort") or 0))
    except Exception:
        pass
PY
)
fi
for hp in $https_ports; do
  if [ "$port" = "$hp" ]; then
    log "port $port is the SSL HTTPS port — applying HTTP on 80 instead"
    port=80
    break
  fi
done

cur="$(grep -oE 'listen[[:space:]]+[0-9]+' "$VHOST" | grep -oE '[0-9]+' | head -1 || true)"
if [ "$cur" = "$port" ]; then
  log "public port already $port — nothing to do"; exit 0
fi

BAK="$VHOST.bak.panel-net"
cp -a "$VHOST" "$BAK"
# Rewrite ONLY the current panel-port listen lines, so a `listen 80;` redirect or
# any other block in the same file is never touched.
sed -i -E "s/listen[[:space:]]+${cur};/listen $port;/; s/listen[[:space:]]+\[::\]:${cur};/listen [::]:$port;/" "$VHOST"

if nginx -t >>"$LOG" 2>&1 && systemctl reload nginx >>"$LOG" 2>&1; then
  log "applied public port $port (was ${cur:-unknown})"
  # Best-effort firewall: only if ufw is active.
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$port"/tcp >>"$LOG" 2>&1 || true
    [ -n "${cur:-}" ] && [ "$cur" != "$port" ] && ufw delete allow "$cur"/tcp >>"$LOG" 2>&1 || true
  fi
else
  cp -a "$BAK" "$VHOST"
  systemctl reload nginx >>"$LOG" 2>&1 || true
  log "nginx validation/reload FAILED — reverted to ${cur:-previous}"
  exit 1
fi
WGMATE_PANEL_NET_APPLY_SH_EOF

    chmod 755 "$sslsh" "$netsh"
    cat > "/etc/systemd/system/wg-mate-panel-ssl.service" <<'WGMATE_WG_MATE_PANEL_SSL_SERVICE_EOF'
[Unit]
Description=Apply wg-mate SSL certificates to nginx
After=nginx.service

[Service]
Type=oneshot
# Optional overrides in /opt/wg-mate/data/panel/ssl.env, e.g.:
#   PANEL_HTTPS_PORT=4443          # default; never use 443 (often x-ui/xray)
#   PANEL_ACME_HTTP_PORTS=80,8080  # LE needs :80
#   PANEL_HTTPS_CANDIDATES=4443,8443,9444,10443
EnvironmentFile=-/opt/wg-mate/data/panel/ssl.env
ExecStart=/opt/wg-mate/scripts/panel-ssl-apply.sh
WGMATE_WG_MATE_PANEL_SSL_SERVICE_EOF

    cat > "/etc/systemd/system/wg-mate-panel-ssl.path" <<'WGMATE_WG_MATE_PANEL_SSL_PATH_EOF'
[Unit]
Description=Watch wg-mate SSL artifacts and apply TLS/ACME vhosts to nginx

[Path]
PathModified=/opt/wg-mate/data/panel/ssl-vhosts.json
PathModified=/opt/wg-mate/data/panel/acme-challenge.txt
Unit=wg-mate-panel-ssl.service

[Install]
WantedBy=multi-user.target
WGMATE_WG_MATE_PANEL_SSL_PATH_EOF

    cat > "/etc/systemd/system/wg-mate-panel-net.service" <<'WGMATE_WG_MATE_PANEL_NET_SERVICE_EOF'
[Unit]
Description=Apply wg-mate panel public port to nginx
After=nginx.service

[Service]
Type=oneshot
ExecStart=/opt/wg-mate/scripts/panel-net-apply.sh
WGMATE_WG_MATE_PANEL_NET_SERVICE_EOF

    cat > "/etc/systemd/system/wg-mate-panel-net.path" <<'WGMATE_WG_MATE_PANEL_NET_PATH_EOF'
[Unit]
Description=Watch wg-mate panel-net.json and apply the public port to nginx

[Path]
PathModified=/opt/wg-mate/data/panel/panel-net.json
Unit=wg-mate-panel-net.service

[Install]
WantedBy=multi-user.target
WGMATE_WG_MATE_PANEL_NET_PATH_EOF

    if [ -e /etc/nginx/sites-enabled/default ] && ss -lntpH 'sport = :80' 2>/dev/null | grep -qv nginx; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now nginx >/dev/null 2>&1
    systemctl enable --now wg-mate-panel-ssl.path wg-mate-panel-net.path >/dev/null 2>&1
    systemctl start wg-mate-panel-ssl.service wg-mate-panel-net.service >/dev/null 2>&1
    return 0
}

create_directories() {
    mkdir -p "$APP_DIR/data/xray" "$APP_DIR/data/openvpn" "$APP_DIR/data/panel" "$(backup_dir)"
}

write_compose() {
    cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  db:
    image: ${DB_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER:-wgmate}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-wgmate}
      POSTGRES_DB: \${POSTGRES_DB:-wgmate}
    ports:
      - "127.0.0.1:\${DB_PORT:-${DEFAULT_DB_PORT}}:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER:-wgmate} -d \${POSTGRES_DB:-wgmate}"]
      interval: 5s
      timeout: 5s
      retries: 10

  api:
    image: ${API_IMAGE}:${IMAGE_TAG}
    restart: unless-stopped
    network_mode: host
    privileged: true
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      TZ: \${TZ:-${DEFAULT_TZ}}
      WG_API_ADDR: ":\${API_PORT:-${DEFAULT_API_PORT}}"
      WG_DATA_DIR: /data
      DATABASE_URL: \${DATABASE_URL}
      AUTH_SECRET: \${AUTH_SECRET:-auto}
      WG_MANAGE: \${WG_MANAGE:-true}
      WG_INTERFACE: \${WG_INTERFACE:-wg0}
      WG_ADDRESS: \${WG_ADDRESS:-10.8.0.1/24}
      WG_LISTEN_PORT: \${WG_LISTEN_PORT:-51820}
      WG_DNS: \${WG_DNS:-1.1.1.1, 8.8.8.8}
      WG_CLIENT_ALLOWED_IPS: \${WG_CLIENT_ALLOWED_IPS:-0.0.0.0/0, ::/0}
      WG_AGENT_ENABLED: \${WG_AGENT_ENABLED:-true}
      WG_AGENT_ADDR: \${WG_AGENT_ADDR:-:9443}
      WG_AGENT_PUBLIC: \${WG_AGENT_PUBLIC:-}
      WG_AGENT_BINARY: /app/wg-mate-agent
      WG_HOST_ROOT: /host
      LICENSE_REQUIRE_SIG: \${LICENSE_REQUIRE_SIG:-1}
      LICENSE_VERIFY_PUBKEY: \${LICENSE_VERIFY_PUBKEY:-${LICENSE_PUBKEY}}
      LICENSE_HMAC_SECRET: \${LICENSE_HMAC_SECRET:-}
      LICENSE_TLS_PINS: \${LICENSE_TLS_PINS:-}
    volumes:
      - wg_data:/data
      - ./data/xray:/data/xray
      - ./data/openvpn:/etc/openvpn
      - ./data/panel:/data/panel
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/machine-id:/host/etc/machine-id:ro
      - /sys/devices/virtual/dmi:/host/sys/devices/virtual/dmi:ro
    depends_on:
      db:
        condition: service_healthy

  web:
    image: ${WEB_IMAGE}:${IMAGE_TAG}
    restart: unless-stopped
    network_mode: host
    environment:
      TZ: \${TZ:-${DEFAULT_TZ}}
      NODE_ENV: production
      PORT: \${WEB_PORT:-${DEFAULT_WEB_PORT}}
      HOSTNAME: "0.0.0.0"
      DOCKER_SOCK: /var/run/docker.sock
      WG_SETTINGS_FILE: /panel/panel-net.json
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./data/panel:/panel:ro
    depends_on:
      api:
        condition: service_started

volumes:
  wg_data:
  pg_data:
EOF
}

write_env() {
    local pg_pass auth_secret keep_db=0
    pg_pass="$(env_get POSTGRES_PASSWORD)"
    auth_secret="$(env_get AUTH_SECRET)"

    if [ -n "$pg_pass" ] && db_volume_exists; then
        keep_db=1
    else
        pg_pass="$(rand_hex 12)"
    fi
    [ -n "$auth_secret" ] || auth_secret="$(rand_hex 32)"

    cat > "$ENV_FILE" <<EOF
TZ=$(shell_quote "$TZ_VALUE")

AUTH_SECRET=$(shell_quote "$auth_secret")

POSTGRES_USER='wgmate'
POSTGRES_PASSWORD=$(shell_quote "$pg_pass")
POSTGRES_DB='wgmate'

WEB_PORT=$(shell_quote "$WEB_PORT")
API_PORT=$(shell_quote "$API_PORT")
DB_PORT=$(shell_quote "$DB_PORT")

WG_MANAGE=true
WG_LISTEN_PORT=51820
WG_AGENT_ENABLED=true
WG_AGENT_ADDR=':9443'

WG_MATE_CHANNEL=$(shell_quote "$IMAGE_TAG")

LICENSE_REQUIRE_SIG=1
LICENSE_VERIFY_PUBKEY=$(shell_quote "$LICENSE_PUBKEY")
EOF
    chmod 600 "$ENV_FILE"
    env_set DATABASE_URL "$(database_url)"
    [ "$keep_db" -eq 1 ] && echo "kept the existing database password - data preserved"
    return 0
}

migrate_env() {
    local file url key
    file="$ENV_FILE"
    [ -f "$file" ] || return 0

    if grep -q $'\r' "$file" 2>/dev/null; then
        sed -i 's/\r$//' "$file"
    fi
    if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then
        printf '\n' >> "$file"
    fi

    for key in WG_MATE_VERSION ADMIN_USERNAME ADMIN_PASSWORD; do
        env_unset "$key"
    done

    local legacy
    legacy="$(env_get POSTGRES_PORT)"
    if is_port "$legacy"; then
        DB_PORT="$legacy"
        env_set DB_PORT "$legacy"
    fi
    env_unset POSTGRES_PORT

    env_default WEB_PORT "$WEB_PORT"
    env_default API_PORT "$API_PORT"
    env_default DB_PORT "$DB_PORT"
    env_default TZ "$TZ_VALUE"
    env_default WG_MATE_CHANNEL "$IMAGE_TAG"
    env_default LICENSE_REQUIRE_SIG "1"
    env_default LICENSE_VERIFY_PUBKEY "$LICENSE_PUBKEY"
    [ -n "$(env_get AUTH_SECRET)" ] || env_set AUTH_SECRET "$(rand_hex 32)"

    if [ -n "$(env_get POSTGRES_PASSWORD)" ]; then
        url="$(database_url)"
        if [ "$(env_get DATABASE_URL)" != "$url" ]; then
            env_set DATABASE_URL "$url"
        fi
    fi

    chmod 600 "$file"
    return 0
}

bootstrap_admin_file() { printf '%s/data/panel/bootstrap-admin.json' "$APP_DIR"; }

clear_bootstrap_admin() {
    local f
    f="$(bootstrap_admin_file)"
    [ -f "$f" ] || return 0
    rm -f "$f" 2>/dev/null
    return 0
}

write_bootstrap_admin() {
    local dir="$APP_DIR/data/panel"
    mkdir -p "$dir"
    printf '{"username":"%s","password":"%s"}\n' \
        "$(json_quote "$ADMIN_USERNAME")" "$(json_quote "$ADMIN_PASSWORD")" \
        > "$dir/bootstrap-admin.json"
    chmod 600 "$dir/bootstrap-admin.json"
}

persist_installer() {
    local src="${BASH_SOURCE[0]}" target="$APP_DIR/install.sh"
    mkdir -p "$APP_DIR"
    if [ -n "$src" ] && [ -f "$src" ] && [ -r "$src" ]; then
        if [ "$(readlink -f "$src")" != "$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")" ]; then
            cp -f "$src" "$target"
        fi
        chmod 755 "$target"
        return 0
    fi
    if curl -fsSL --max-time 20 "$SCRIPT_URL" -o "${target}.tmp" 2>/dev/null \
       && head -1 "${target}.tmp" | grep -q '^#!'; then
        mv -f "${target}.tmp" "$target"
        chmod 755 "$target"
        return 0
    fi
    rm -f "${target}.tmp"
    echo "could not save a local copy of the installer to ${target}" >&2
    return 1
}

install_shortcut() {
    local dir
    dir="$(dirname "$SHORTCUT")"
    [ -d "$dir" ] || return 0
    if [ ! -w "$dir" ] && [ ! -w "$SHORTCUT" ]; then
        return 0
    fi
    rm -f "$SHORTCUT" 2>/dev/null
    cat > "$SHORTCUT" 2>/dev/null <<EOF
#!/usr/bin/env bash
SCRIPT="${APP_DIR}/install.sh"
if [ ! -f "\$SCRIPT" ]; then
  echo "${APP_NAME} is not installed (missing \$SCRIPT)" >&2
  exit 1
fi
if [ "\$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  exec sudo bash "\$SCRIPT" "\$@"
fi
exec bash "\$SCRIPT" "\$@"
EOF
    chmod 755 "$SHORTCUT" 2>/dev/null
    return 0
}

install_command() {
    persist_installer && install_shortcut
}

is_our_installer() {
    local f="$1"
    [ -f "$f" ] && [ -r "$f" ] || return 1
    grep -q '^APP_NAME="wg-mate"' "$f" 2>/dev/null || return 1
    grep -q '^process_arguments' "$f" 2>/dev/null || return 1
    return 0
}

remove_installer_copies() {
    local src f real seen=""
    src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
    for f in "$src" "${APP_DIR}/install.sh" /root/install.sh /root/wg-mate.sh \
             /tmp/install.sh "${PWD}/install.sh" "${HOME:-/root}/install.sh"; do
        [ -n "$f" ] || continue
        real="$(readlink -f "$f" 2>/dev/null)"
        [ -n "$real" ] || continue
        case " ${seen} " in *" ${real} "*) continue ;; esac
        seen="${seen} ${real}"
        is_our_installer "$real" || continue
        rm -f "$real"
    done
    return 0
}

version_section() {
    local latest_inst latest_panel pv
    latest_inst="$(get_latest_installer_version)"
    _sec "Version"
    if [ -z "$latest_inst" ]; then
        _kv "Installer" "$(_dot ok) ${C_OK}${SCRIPT_VERSION}${CR} ${C_DIM}(latest unknown)${CR}"
    elif version_ge "$SCRIPT_VERSION" "$latest_inst"; then
        _kv "Installer" "$(_dot ok) ${C_OK}${SCRIPT_VERSION}${CR} ${C_DIM}(up to date)${CR}"
    else
        _kv "Installer" "$(_dot warn) ${C_WARN}${SCRIPT_VERSION}${CR} ${C_WARN}(${latest_inst} available)${CR}"
    fi
    if installed; then
        load_ports
        load_channel
        pv="$(panel_version)"
        latest_panel="$(get_latest_version)"
        if [ -n "$pv" ] && [ -n "$latest_panel" ] && ! version_ge "$pv" "$latest_panel"; then
            _kv "Panel" "$(_dot warn) ${C_WARN}${pv}${CR} ${C_WARN}(${latest_panel} available)${CR}"
        elif [ -n "$pv" ]; then
            _kv "Panel" "$(_dot ok) ${C_OK}${pv}${CR}"
        else
            _kv "Panel" "$(_dot warn) ${C_WARN}unknown${CR}"
        fi
        _kv "Channel" "${C_DIM}$(channel_label "$IMAGE_TAG")${CR}"
    else
        _kv "Panel" "$(_dot bad) ${C_BAD}not installed${CR}"
        _kv "Channel" "${C_DIM}-${CR}"
    fi
}

panel_section() {
    _sec "Panel Status"
    if ! docker_ready; then
        _kv "State" "$(_dot bad) ${C_BAD}docker unavailable${CR}"
        _kv "Next" "${C_DIM}choose 1 to install${CR}"
        return 0
    fi
    if ! installed; then
        _kv "State" "$(_dot warn) ${C_WARN}not installed${CR}"
        _kv "Next" "${C_DIM}choose 1 to install${CR}"
        return 0
    fi
    local up total
    read -r up total <<<"$(container_counts)"
    if [ "${up:-0}" -gt 0 ] && [ "${up:-0}" -eq "${total:-0}" ]; then
        _kv "State" "$(_dot ok) ${C_OK}running${CR}"
    elif [ "${up:-0}" -gt 0 ]; then
        _kv "State" "$(_dot warn) ${C_WARN}degraded${CR}"
    else
        _kv "State" "$(_dot bad) ${C_BAD}stopped${CR}"
    fi
    _kv "Containers" "${C_DIM}${up}/${total} up${CR}"
    _kv "URL" "${C_KEY}$(panel_url)${CR}"
    if api_health >/dev/null 2>&1; then
        _kv "API" "$(_dot ok) ${C_OK}healthy${CR} ${C_DIM}(127.0.0.1:${API_PORT})${CR}"
    else
        _kv "API" "$(_dot bad) ${C_BAD}no response on 127.0.0.1:${API_PORT}${CR}"
    fi
    _kv "Directory" "${C_DIM}${APP_DIR}${CR}"
}

services_section() {
    installed || return 0
    docker_ready || return 0
    _sec "Services"
    local svc st found=0
    while IFS=$'\t' read -r svc st; do
        [ -n "$svc" ] || continue
        found=1
        case "$st" in
            Up*) _kv "$svc" "$(_dot ok) ${C_OK}${st}${CR}" ;;
            *)   _kv "$svc" "$(_dot bad) ${C_BAD}${st}${CR}" ;;
        esac
    done < <(docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
                --format '{{.Label "com.docker.compose.service"}}\t{{.Status}}' 2>/dev/null)
    [ "$found" -eq 1 ] || _kv "Containers" "$(_dot bad) ${C_BAD}none created${CR}"
    local p label owner
    for p in "${WEB_PORT}:web" "${API_PORT}:api" "${DB_PORT}:db"; do
        label="${p#*:}"
        p="${p%%:*}"
        if ! port_in_use "$p"; then
            _kv "Port ${p}" "$(_dot warn) ${C_WARN}nothing listening${CR} ${C_DIM}(${label})${CR}"
        elif our_container_on_port "$p"; then
            _kv "Port ${p}" "$(_dot ok) ${C_OK}ours${CR} ${C_DIM}(${label})${CR}"
        else
            owner="$(port_owner "$p")"
            _kv "Port ${p}" "$(_dot bad) ${C_BAD}held by ${owner:-another process}${CR}"
        fi
    done
}

system_section() {
    local os kernel dver ip wg
    detect_os
    os="${OS_PRETTY:-unknown}"
    kernel=$(uname -r)
    if have docker; then
        dver=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
        [ -z "$dver" ] && dver="installed (daemon down)"
    else
        dver="not installed"
    fi
    ip=$(get_server_ip)
    if lsmod 2>/dev/null | grep -q '^wireguard' || modinfo wireguard >/dev/null 2>&1; then
        wg="available"
    else
        wg="missing"
    fi
    _sec "System"
    _kv "OS" "${C_DIM}${os}${CR}"
    _kv "Kernel" "${C_DIM}${kernel}${CR}"
    if have docker && docker_ready; then
        _kv "Docker" "$(_dot ok) ${C_OK}${dver}${CR}"
    else
        _kv "Docker" "$(_dot bad) ${C_BAD}${dver}${CR}"
    fi
    if [ "$wg" = "available" ]; then
        _kv "WireGuard" "$(_dot ok) ${C_OK}kernel module ready${CR}"
    else
        _kv "WireGuard" "$(_dot warn) ${C_WARN}kernel module missing${CR}"
    fi
    _kv "Server IP" "${C_DIM}${ip}${CR}"
}

resources_section() {
    local mem_t mem_u mem_p disk load cores up
    mem_t=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    mem_u=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
    if [ -n "$mem_t" ] && [ "$mem_t" -gt 0 ] 2>/dev/null; then mem_p=$(( mem_u * 100 / mem_t )); else mem_p=0; fi
    disk=$(df -h "$APP_DIR" 2>/dev/null | awk 'NR==2{print $3" / "$2"  ("$5")"}')
    [ -z "$disk" ] && disk=$(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2"  ("$5")"}')
    load=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
    cores=$(nproc 2>/dev/null)
    up=$(uptime -p 2>/dev/null | sed 's/^up //')
    [ -z "$up" ] && up="n/a"
    _sec "Resources"
    _kv "RAM" "${C_DIM}${mem_u}MB / ${mem_t}MB  (${mem_p}%)${CR}"
    _kv "Disk" "${C_DIM}${disk}${CR}"
    _kv "CPU load" "${C_DIM}${load}  (${cores} cores)${CR}"
    _kv "Uptime" "${C_DIM}${up}${CR}"
}

prefetch_menu_data() {
    local pids=()
    if ! cache_fresh "$INSTALLER_CACHE"; then
        get_latest_installer_version >/dev/null 2>&1 &
        pids+=($!)
    fi
    if ! cache_fresh "$IP_CACHE"; then
        get_server_ip >/dev/null 2>&1 &
        pids+=($!)
    fi
    if installed && ! cache_fresh "$LATEST_CACHE"; then
        get_latest_version >/dev/null 2>&1 &
        pids+=($!)
    fi
    [ "${#pids[@]}" -gt 0 ] && wait "${pids[@]}" 2>/dev/null
    return 0
}

function show_logo() {
    clear 2>/dev/null
    banner
}

net_works() {
    curl -fsSL --max-time 8 -o /dev/null "https://github.com" 2>/dev/null && return 0
    curl -fsSL --max-time 8 -o /dev/null "https://ghcr.io" 2>/dev/null && return 0
    return 1
}

ensure_connectivity() {
    net_works && return 0
    ensure_dns >/dev/null 2>&1
    net_works
}

precheck_fresh_server() {
    local rows name image status
    rows="$(foreign_stacks)"
    [ -n "$rows" ] || return 0
    _sec "Existing containers"
    _warn "Containers from another ${APP_NAME} install are present:"
    while IFS=$'\t' read -r name image status; do
        [ -n "$name" ] || continue
        printf "      ${C_TITLE}%-22s${CR} ${C_DIM}%s  %s${CR}\n" "$name" "$image" "$status"
    done <<<"$rows"
    _info "They can hold the panel port and keep this install from starting."
    echo ""
    if _confirm "Remove these containers? (volumes are kept)" "Y"; then
        run_step "Removing containers from another install" "remove_foreign_stacks" || show_step_error
    else
        _warn "Kept - expect port conflicts."
    fi
    return 0
}

preflight() {
    local ok=1
    _sec "Pre-flight checks"

    if have apt-get || have dnf || have yum; then
        _kv "Package mgr" "$(_dot ok) ${C_OK}detected${CR}"
    else
        _kv "Package mgr" "$(_dot bad) ${C_BAD}apt/dnf/yum not found${CR}"; ok=0
    fi

    detect_os
    case "$OS_ID" in
        ubuntu|debian) _kv "OS" "$(_dot ok) ${C_OK}${OS_PRETTY}${CR}" ;;
        "")            _kv "OS" "$(_dot warn) ${C_WARN}unknown (untested)${CR}" ;;
        *)             _kv "OS" "$(_dot warn) ${C_WARN}${OS_PRETTY} (untested; Ubuntu/Debian recommended)${CR}" ;;
    esac

    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64|aarch64|arm64) _kv "Arch" "$(_dot ok) ${C_OK}${arch}${CR}" ;;
        *) _kv "Arch" "$(_dot warn) ${C_WARN}${arch} (untested)${CR}" ;;
    esac

    local free_mb; free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    if [ "${free_mb:-0}" -ge 3072 ]; then
        _kv "Disk free" "$(_dot ok) ${C_OK}${free_mb} MB${CR}"
    else
        _kv "Disk free" "$(_dot bad) ${C_BAD}${free_mb:-0} MB (need >= 3072 MB)${CR}"; ok=0
    fi

    local mem; mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    if [ "${mem:-0}" -ge 900 ]; then
        _kv "RAM" "$(_dot ok) ${C_OK}${mem} MB${CR}"
    else
        _kv "RAM" "$(_dot warn) ${C_WARN}${mem:-0} MB (low; postgres may struggle)${CR}"
    fi

    if lsmod 2>/dev/null | grep -q '^wireguard' || modinfo wireguard >/dev/null 2>&1; then
        _kv "WireGuard" "$(_dot ok) ${C_OK}kernel module available${CR}"
    else
        _kv "WireGuard" "$(_dot warn) ${C_WARN}kernel module missing (install linux-headers)${CR}"
    fi

    if ensure_connectivity; then
        _kv "Network" "$(_dot ok) ${C_OK}online${CR}"
    else
        _kv "Network" "$(_dot bad) ${C_BAD}offline (cannot reach GitHub/GHCR)${CR}"; ok=0
    fi

    if [ "$ok" -ne 1 ]; then
        echo ""
        _bad "Pre-flight checks failed. Aborting to avoid a broken install."
        return 1
    fi
    return 0
}

print_summary() {
    _sec "Done"
    _kv "Panel" "${C_KEY}$(panel_url)${CR}"
    _kv "Version" "${C_DIM}$(panel_version)${CR}"
    _kv "Channel" "${C_DIM}$(channel_label "$IMAGE_TAG")${CR}"
    _kv "Directory" "${C_DIM}${APP_DIR}${CR}"
    if [ "$SHOW_CREDENTIALS" = "1" ] && [ -n "$ADMIN_USERNAME" ]; then
        _kv "Username" "${C_OK}${ADMIN_USERNAME}${CR}"
        _kv "Password" "${C_OK}${ADMIN_PASSWORD}${CR}"
    fi
    echo ""
    printf "    ${C_DIM}Open the panel → log in → activate your license.${CR}\n"
    printf "    ${C_DIM}Manage it any time with the ${CR}${C_KEY}wg-mate${CR}${C_DIM} command.${CR}\n"
}

gather_install_input() {
    local stored rc

    stored="$(state_get CHANNEL)"
    if [ -n "$stored" ]; then
        IMAGE_TAG="$stored"
    else
        choose_channel "latest"
        rc=$?
        [ "$rc" -eq 2 ] && return 2
        [ "$rc" -ne 0 ] && return 1
        state_set CHANNEL "$IMAGE_TAG"
    fi

    load_ports

    stored="$(state_get WEB_PORT)"
    if [ -n "$ARG_WEB_PORT" ]; then
        WEB_PORT="$ARG_WEB_PORT"
    elif [ -n "$stored" ]; then
        WEB_PORT="$stored"
    else
        _sec "Ports"
        WEB_PORT="$(ask_port "Panel web port" "$WEB_PORT")"
    fi
    is_port "$WEB_PORT" || { _bad "Invalid web port: ${WEB_PORT}"; return 1; }

    stored="$(state_get API_PORT)"
    if [ -n "$ARG_API_PORT" ]; then
        API_PORT="$ARG_API_PORT"
    elif [ -n "$stored" ]; then
        API_PORT="$stored"
    elif port_in_use "$API_PORT" && ! our_container_on_port "$API_PORT"; then
        API_PORT="$(free_port_from "$API_PORT")"
    fi

    stored="$(state_get DB_PORT)"
    if [ -n "$ARG_DB_PORT" ]; then
        DB_PORT="$ARG_DB_PORT"
    elif [ -n "$stored" ]; then
        DB_PORT="$stored"
    elif port_in_use "$DB_PORT" && ! our_container_on_port "$DB_PORT"; then
        DB_PORT="$(free_port_from "$DB_PORT")"
    fi

    [ -n "$ARG_TZ" ] && TZ_VALUE="$ARG_TZ"

    state_set WEB_PORT "$WEB_PORT"
    state_set API_PORT "$API_PORT"
    state_set DB_PORT "$DB_PORT"

    _kv "Web port" "${C_KEY}${WEB_PORT}${CR}"
    _kv "API port" "${C_DIM}${API_PORT}${CR}"
    _kv "DB port" "${C_DIM}${DB_PORT}${CR}"

    ADMIN_USERNAME="$(state_get ADMIN_USERNAME)"
    ADMIN_PASSWORD="$(state_get ADMIN_PASSWORD)"
    if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_PASSWORD" ]; then
        _sec "Admin account"
        if [ -n "$ARG_ADMIN" ]; then
            ADMIN_USERNAME="$ARG_ADMIN"
        elif [ -t 0 ]; then
            ADMIN_USERNAME="$(_ask "Username" "admin")"
        else
            ADMIN_USERNAME="admin"
        fi
        [ -n "$ADMIN_USERNAME" ] || ADMIN_USERNAME="admin"
        if [ -n "$ARG_PASSWORD" ]; then
            ADMIN_PASSWORD="$ARG_PASSWORD"
        elif [ -t 0 ]; then
            ADMIN_PASSWORD="$(_ask_password_confirm "Password")"
        else
            ADMIN_PASSWORD="$(rand_hex 6)"
        fi
        state_set ADMIN_USERNAME "$ADMIN_USERNAME"
        state_set ADMIN_PASSWORD "$ADMIN_PASSWORD"
    fi
    SHOW_CREDENTIALS=1
    return 0
}

function install_panel() {
    if installed && ! has_resumable_state && containers_exist; then
        clear 2>/dev/null
        banner
        _sec "Install blocked"
        _bad "${APP_NAME} is already installed and deployed on this server."
        printf "    ${C_DIM}Path:${CR} %s\n" "$APP_DIR"
        echo ""
        printf "    ${C_DIM}To upgrade, use option ${CR}${C_KEY}2 (Update)${CR}${C_DIM}.${CR}\n"
        printf "    ${C_DIM}To start over, purge it with option ${CR}${C_KEY}9 (Delete panel)${CR}${C_DIM}.${CR}\n"
        _back_to_menu
        return 1
    fi

    if installed && ! has_resumable_state; then
        clear 2>/dev/null
        banner
        _sec "Existing configuration"
        _warn "The containers are gone but the config in ${APP_DIR} is still here."
        _info "Stopped containers from an earlier install are left behind."
        echo ""
        _mi "1" "Redeploy with the existing config and data"
        _mi "2" "Discard the config and install fresh"
        _mi "0" "Back to menu"
        echo ""
        printf "  ${C_PROMPT}❯${CR} Your choice ${C_DIM}[0-2]${CR}: "
        local _redeploy_choice; read -r _redeploy_choice
        case "$_redeploy_choice" in
            2)
                if db_volume_exists; then
                    _warn "The database volume still holds the old data and its old password."
                    _info "A fresh install generates new credentials and will not be able to open it."
                    if ! _confirm "Delete the database volume too?" "N"; then
                        _info "Cancelled - use option 9 (Delete panel) for a clean slate."
                        _back_to_menu
                        return 1
                    fi
                    docker volume rm "${COMPOSE_PROJECT}_pg_data" >/dev/null 2>&1
                fi
                rm -f "$APP_DIR/docker-compose.yml" "$ENV_FILE"
                echo -e "  ${C_DIM}Starting from scratch...${CR}"
                sleep 1
                ;;
            0) return 0 ;;
            *)
                clear 2>/dev/null
                banner
                _sec "Redeploy"
                if ! docker_ready; then
                    _bad "Cannot reach the docker daemon. Try: systemctl start docker"
                    _back_to_menu
                    return 1
                fi
                load_ports
                load_channel
                STEP_TOTAL=2; STEP_NO=0; ETA_REMAINING=0
                run_step "Starting containers" "compose up -d" || { show_step_error; _back_to_menu; return 1; }
                run_step "Waiting for the API to become healthy" "wait_api_healthy 45" || _warn "API not healthy yet."
                print_summary
                _back_to_menu
                return 0
                ;;
        esac
    fi

    if has_resumable_state; then
        clear 2>/dev/null
        banner
        _sec "Resume install"
        local _last
        _last="$(grep '^PHASE:' "$STATE_FILE" 2>/dev/null | tail -1 | cut -d: -f2)"
        [ -z "$_last" ] && _last="none"
        _warn "An unfinished installation was found."
        printf "    ${C_DIM}Last completed step:${CR} ${C_KEY}%s${CR}\n" "$_last"
        echo ""
        _mi "1" "Resume from where it stopped"
        _mi "2" "Start fresh from the beginning"
        _mi "0" "Back to menu"
        echo ""
        printf "  ${C_PROMPT}❯${CR} Your choice: "
        local _resume_choice; read -r _resume_choice
        case "$_resume_choice" in
            2) state_clear; echo -e "  ${C_DIM}Starting from scratch...${CR}"; sleep 1 ;;
            0) return 0 ;;
            *) echo -e "  ${C_OK}●${CR} ${C_OK}Resuming installation from the last step...${CR}"; sleep 1 ;;
        esac
    fi

    state_init
    state_set STARTED 1
    plan_eta

    clear 2>/dev/null
    banner
    if ! preflight; then
        _back_to_menu
        return 1
    fi
    precheck_fresh_server

    gather_install_input
    local rc=$?
    if [ "$rc" -eq 2 ]; then return 0; fi
    if [ "$rc" -ne 0 ]; then sleep 2; return 1; fi

    if ! phase_done DOCKER; then
        print_header "Installing Docker"

        if have docker && docker compose version >/dev/null 2>&1; then
            _ok "Docker and the compose plugin are already installed."
        else
            run_step "Preparing package manager (clearing stale apt locks)" "apt_recover" \
                || { show_step_error; install_pause "Preparing package manager"; }

            if have apt-get; then
                run_step "Installing prerequisites (curl, ca-certificates, gnupg)" \
                    "apt-get install -y -o DPkg::Lock::Timeout=180 ca-certificates curl gnupg" \
                    || { show_step_error; install_pause "Installing prerequisites"; }

                if ! run_step "Adding Docker repository" "setup_docker_repo"; then
                    show_step_error
                    _warn "Docker repository unavailable - falling back to the distribution packages."
                fi
            fi

            if ! run_step "Installing Docker Engine" "install_docker_engine"; then
                show_step_error
                if ! run_step "Installing Docker from the distribution packages" "install_docker_fallback"; then
                    show_step_error
                    install_pause "Installing Docker Engine"
                fi
            fi
        fi

        run_step "Enabling & starting Docker" "enable_docker" \
            || { show_step_error; install_pause "Enabling & starting Docker"; }

        run_step "Loading kernel modules (wireguard, tun)" "ensure_kernel_mods"

        mark_phase DOCKER
    fi

    if ! phase_done CONFIG; then
        print_header "Writing Configuration"

        run_step "Creating directories" "create_directories" \
            || { show_step_error; install_pause "Creating directories"; }

        run_step "Writing environment file" "write_env" \
            || { show_step_error; install_pause "Writing environment file"; }

        migrate_env

        run_step "Writing compose file" "write_compose" \
            || { show_step_error; install_pause "Writing compose file"; }

        run_step "Installing host helpers (nginx + ACME watchers)" "install_host_helpers" \
            || _warn "Could not install the nginx host helpers - the SSL page will not be able to issue certificates."

        write_bootstrap_admin

        run_step "Installing the wg-mate command" "install_command" \
            || _warn "Could not install the ${APP_NAME} command in ${SHORTCUT}."

        mark_phase CONFIG
    fi

    if ! phase_done IMAGES; then
        print_header "Downloading Images"
        run_step "Pulling images ($(channel_label "$IMAGE_TAG"))" "compose pull" \
            || { show_step_error; install_pause "Pulling images"; }
        mark_phase IMAGES
    fi

    if ! phase_done START; then
        print_header "Starting The Panel"
        run_step "Starting containers" "compose up -d" \
            || { show_step_error; install_pause "Starting containers"; }
        run_step "Waiting for the API to become healthy" "wait_api_healthy 45" \
            || _warn "The API did not become healthy in time - check: ${APP_NAME} logs api"
        clear_bootstrap_admin
        mark_phase START
    fi

    mark_phase COMPLETE
    state_clear
    print_summary
    _back_to_menu
}

function update_panel() {
    clear 2>/dev/null
    banner
    _sec "Update panel"
    if ! installed; then
        _bad "${APP_NAME} is not installed. Use option 1 (Install) first."
        _back_to_menu
        return 1
    fi
    if ! docker_ready; then
        _bad "Cannot reach the docker daemon. Try: systemctl start docker"
        _back_to_menu
        return 1
    fi

    load_ports
    load_channel
    local current="$IMAGE_TAG"
    _kv "Current" "${C_DIM}$(channel_label "$current")${CR}"

    if [ -n "$ARG_CHANNEL" ] || [ -n "$ARG_VERSION" ]; then
        choose_channel "$current" || { _back_to_menu; return 1; }
    elif [ -t 0 ]; then
        choose_channel "$current"
        local rc=$?
        [ "$rc" -eq 2 ] && return 0
        [ "$rc" -ne 0 ] && { _back_to_menu; return 1; }
    fi

    STEP_TOTAL=5; STEP_NO=0; ETA_REMAINING=0
    print_header "Updating ${APP_NAME}"

    env_set WG_MATE_CHANNEL "$IMAGE_TAG"
    migrate_env

    run_step "Writing compose file" "write_compose" \
        || { show_step_error; _back_to_menu; return 1; }

    run_step "Installing host helpers (nginx + ACME watchers)" "install_host_helpers" \
        || _warn "Could not install the nginx host helpers - the SSL page will not be able to issue certificates."

    run_step "Installing the wg-mate command" "install_command" \
        || _warn "Could not refresh the ${APP_NAME} command."

    if ! run_step "Pulling images ($(channel_label "$IMAGE_TAG"))" "compose pull"; then
        show_step_error
        _bad "Could not pull ${IMAGE_TAG} - check that this tag exists, then retry."
        _back_to_menu
        return 1
    fi

    run_step "Recreating containers" "compose up -d" \
        || { show_step_error; _back_to_menu; return 1; }

    wait_api_healthy 45 || _warn "The API did not become healthy in time."
    print_summary
    _back_to_menu
}

function update_script() {
    clear 2>/dev/null
    banner
    _sec "Installer update"

    local tmp remote_version src target
    src="${BASH_SOURCE[0]}"
    target="$APP_DIR/install.sh"
    [ -d "$APP_DIR" ] || target="$src"

    if running_from_repo; then
        _warn "Running from a git checkout - refusing to overwrite ${src}."
        _back_to_menu
        return 0
    fi

    _kv "Source" "${C_DIM}${SCRIPT_URL}${CR}"
    _kv "Current" "${C_DIM}${SCRIPT_VERSION}${CR}"
    _kv "Target" "${C_DIM}${target}${CR}"

    tmp="$(mktemp)"
    STEP_TOTAL=1; STEP_NO=0; ETA_REMAINING=0
    if ! run_step "Downloading the newest installer" "fetch_installer '${tmp}' '${SCRIPT_URL}' 20"; then
        show_step_error
        rm -f "$tmp"
        _bad "Could not download a valid installer - check this server's internet access."
        _back_to_menu
        return 1
    fi

    remote_version="$(installer_version_of "$tmp")"
    if [ -f "$src" ] && cmp -s "$tmp" "$src"; then
        rm -f "$tmp"
        _ok "Already up to date (v${SCRIPT_VERSION})."
        _back_to_menu
        return 0
    fi

    chmod 755 "$tmp"
    if ! mv -f "$tmp" "$target" 2>/dev/null; then
        rm -f "$tmp"
        _bad "Could not write ${target}."
        _back_to_menu
        return 1
    fi
    install_shortcut
    _ok "Installer ${SCRIPT_VERSION} → ${remote_version:-newer}."
    _info "Run ${APP_NAME} again to use it."
    _back_to_menu
}

function service_action() {
    local action="$1"
    clear 2>/dev/null
    banner
    _sec "Service: ${action}"
    if ! installed; then
        _bad "${APP_NAME} is not installed."
        _back_to_menu
        return 1
    fi
    if ! docker_ready; then
        _bad "Cannot reach the docker daemon. Try: systemctl start docker"
        _back_to_menu
        return 1
    fi
    load_ports
    load_channel
    STEP_TOTAL=0; STEP_NO=0; ETA_REMAINING=0
    case "$action" in
        start)
            run_step "Starting containers" "compose up -d" || { show_step_error; _back_to_menu; return 1; }
            run_step "Waiting for the API to become healthy" "wait_api_healthy 45" || _warn "API not healthy yet."
            ;;
        stop)
            run_step "Stopping containers" "compose stop" || { show_step_error; _back_to_menu; return 1; }
            _info "Data is kept in ${APP_DIR}."
            ;;
        restart)
            run_step "Recreating containers" "compose up -d --force-recreate" || { show_step_error; _back_to_menu; return 1; }
            run_step "Waiting for the API to become healthy" "wait_api_healthy 45" || _warn "API not healthy yet."
            ;;
    esac
    _ok "Done."
    _back_to_menu
}

function show_status() {
    clear 2>/dev/null
    banner
    if ! installed; then
        _sec "Panel Status"
        _bad "${APP_NAME} is not installed."
        _back_to_menu
        return 1
    fi
    load_ports
    load_channel
    menu_cache_begin
    prefetch_menu_data
    version_section
    panel_section
    services_section
    _sec "Containers"
    if docker_ready; then
        compose ps 2>/dev/null | sed 's/^/    /'
    else
        _bad "Cannot reach the docker daemon."
    fi
    system_section
    resources_section
    menu_cache_end
    _back_to_menu
}

function show_logs() {
    clear 2>/dev/null
    banner
    _sec "Logs"
    if ! installed; then
        _bad "${APP_NAME} is not installed."
        _back_to_menu
        return 1
    fi
    if ! docker_ready; then
        _bad "Cannot reach the docker daemon."
        _back_to_menu
        return 1
    fi
    local svc="$ARG_SERVICE"
    if [ -z "$svc" ] && [ -t 0 ]; then
        _mi "1" "All services"
        _mi "2" "web"
        _mi "3" "api"
        _mi "4" "db"
        _mi "0" "Back to menu"
        echo ""
        printf "  ${C_PROMPT}❯${CR} Select ${C_DIM}[0-4]${CR}: "
        local S; read -r S
        case "$S" in
            0) return 0 ;;
            2) svc="web" ;;
            3) svc="api" ;;
            4) svc="db" ;;
            *) svc="" ;;
        esac
    fi
    _info "Press Ctrl+C to stop following."
    echo ""
    if [ -n "$svc" ]; then
        compose logs -f --tail=200 "$svc"
    else
        compose logs -f --tail=200
    fi
    _back_to_menu
}

function show_login_info() {
    clear 2>/dev/null
    banner
    _sec "Login info"
    if ! installed; then
        _bad "${APP_NAME} is not installed."
        _back_to_menu
        return 1
    fi
    if ! docker_ready; then
        _bad "Cannot reach the docker daemon."
        _back_to_menu
        return 1
    fi
    load_ports

    local rows user pass found=0
    _kv "URL" "${C_KEY}$(panel_url)${CR}"
    rows="$(psql_do "SELECT username || chr(9) || COALESCE(password, '') FROM admins ORDER BY 1" 2>/dev/null)"
    if [ -z "$rows" ]; then
        _warn "No admin account found in the database."
        _info "Set one from inside the panel, or reinstall to seed a new admin."
        _back_to_menu
        return 0
    fi
    while IFS=$'\t' read -r user pass; do
        [ -n "$user" ] || continue
        found=1
        _rule
        _kv "Username" "${C_KEY}${user}${CR}"
        case "$pass" in
            ""|\$2a\$*|\$2b\$*|\$2y\$*|\$argon2*|\$pbkdf2*|\$scrypt*)
                _kv "Password" "${C_DIM}stored as a hash - change it from inside the panel${CR}" ;;
            *)
                _kv "Password" "${C_KEY}${pass}${CR}" ;;
        esac
    done <<< "$rows"
    [ "$found" -eq 1 ] || _warn "Could not read the admin table."
    _back_to_menu
}

function backup_panel() {
    clear 2>/dev/null
    banner
    _sec "Backup Database"
    if ! installed; then
        _bad "${APP_NAME} is not installed."
        _back_to_menu
        return 1
    fi
    if ! docker_ready; then
        _bad "Cannot reach the docker daemon."
        _back_to_menu
        return 1
    fi
    load_ports

    local dir stamp sql archive user db
    dir="$(backup_dir)"
    mkdir -p "$dir"
    stamp="$(date +%Y%m%d-%H%M%S)"
    sql="${dir}/db-${stamp}.sql"
    archive="${dir}/wg-mate-${stamp}.tar.gz"
    user="$(env_get POSTGRES_USER)"; user="${user:-wgmate}"
    db="$(env_get POSTGRES_DB)"; db="${db:-wgmate}"

    STEP_TOTAL=2; STEP_NO=0; ETA_REMAINING=0
    if ! run_step "Dumping the database" "compose exec -T db pg_dump -U '${user}' -d '${db}' > '${sql}'"; then
        show_step_error
        rm -f "$sql"
        _bad "pg_dump failed - is the database running?"
        _back_to_menu
        return 1
    fi

    if ! run_step "Creating the archive" "tar -czf '${archive}' -C '${dir}' '$(basename "$sql")' -C '${APP_DIR}' .env docker-compose.yml data"; then
        show_step_error
        rm -f "$sql"
        _back_to_menu
        return 1
    fi
    rm -f "$sql"
    chmod 600 "$archive"

    _sec "Done"
    _kv "Archive" "${C_KEY}${archive}${CR}"
    _kv "Size" "${C_DIM}$(du -h "$archive" | cut -f1)${CR}"
    _kv "Copy" "${C_DIM}scp root@$(get_server_ip):${archive} .${CR}"
    _back_to_menu
}

function restore_panel() {
    clear 2>/dev/null
    banner
    _sec "Restore backup"
    if ! installed; then
        _bad "${APP_NAME} is not installed."
        _back_to_menu
        return 1
    fi
    if ! docker_ready; then
        _bad "Cannot reach the docker daemon."
        _back_to_menu
        return 1
    fi
    load_ports

    local archive="$ARG_FILE" dir tmp sql user db pick i f
    local files=()
    dir="$(backup_dir)"

    if [ -z "$archive" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] && files+=("$f")
        done < <(
            for f in "$dir"/*.tar.gz; do
                [ -f "$f" ] || continue
                printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || echo 0)" "$f"
            done | sort -rn | cut -f2-
        )
        if [ "${#files[@]}" -eq 0 ]; then
            _bad "No backups found in ${dir}."
            _back_to_menu
            return 1
        fi
        i=1
        for f in "${files[@]}"; do
            _mi "$i" "$(basename "$f")  ${C_DIM}$(du -h "$f" | cut -f1)${CR}"
            i=$((i + 1))
        done
        _mi "0" "Back to menu"
        echo ""
        printf "  ${C_PROMPT}❯${CR} Select backup ${C_DIM}[default: 1]${CR}: "
        read -r pick
        [ -z "$pick" ] && pick=1
        [ "$pick" = "0" ] && return 0
        if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#files[@]}" ]; then
            _bad "Invalid selection."
            _back_to_menu
            return 1
        fi
        archive="${files[$((pick - 1))]}"
    fi
    if [ ! -f "$archive" ]; then
        _bad "No such backup: ${archive}"
        _back_to_menu
        return 1
    fi

    echo ""
    _warn "This replaces the current database and panel data."
    if ! _confirm "Restore from $(basename "$archive")?" "N"; then
        _info "Cancelled."
        _back_to_menu
        return 0
    fi

    tmp="$(mktemp -d)" || { _bad "Could not create a temporary directory."; _back_to_menu; return 1; }
    tar -xzf "$archive" -C "$tmp"
    sql=""
    for f in "$tmp"/db-*.sql; do
        [ -f "$f" ] && { sql="$f"; break; }
    done
    user="$(env_get POSTGRES_USER)"; user="${user:-wgmate}"
    db="$(env_get POSTGRES_DB)"; db="${db:-wgmate}"

    STEP_TOTAL=3; STEP_NO=0; ETA_REMAINING=0
    print_header "Restoring ${APP_NAME}"

    if [ -n "$sql" ]; then
        compose up -d db >/dev/null 2>&1
        sleep 3
        if ! run_step "Restoring the database" \
            "compose exec -T db psql -U '${user}' -d postgres -c 'DROP DATABASE IF EXISTS ${db}' >/dev/null 2>&1; \
             compose exec -T db psql -U '${user}' -d postgres -c 'CREATE DATABASE ${db}' >/dev/null 2>&1; \
             compose exec -T db psql -q -U '${user}' -d '${db}' < '${sql}'"; then
            show_step_error
            rm -rf "$tmp"
            _back_to_menu
            return 1
        fi
    else
        _warn "This archive has no database dump - restoring files only."
    fi

    if [ -d "$tmp/data" ]; then
        run_step "Restoring panel data" "cp -a '${tmp}/data/.' '${APP_DIR}/data/'" || show_step_error
    fi
    rm -rf "$tmp"

    run_step "Recreating containers" "compose up -d --force-recreate" || show_step_error
    wait_api_healthy 45 || _warn "API not healthy yet."
    _ok "Restore complete."
    _back_to_menu
}

function doctor_panel() {
    clear 2>/dev/null
    banner
    _sec "Doctor"

    if docker_ready; then
        _kv "Docker" "$(_dot ok) ${C_OK}$(docker version --format '{{.Server.Version}}' 2>/dev/null)${CR}"
    else
        _kv "Docker" "$(_dot bad) ${C_BAD}not installed or not running${CR}"
        _back_to_menu
        return 1
    fi

    if installed; then
        _kv "Install dir" "$(_dot ok) ${C_OK}${APP_DIR}${CR}"
    else
        _kv "Install dir" "$(_dot bad) ${C_BAD}missing compose file or .env${CR}"
        _back_to_menu
        return 1
    fi

    load_ports
    load_channel

    local file missing="" key url_port up total free rows name image status
    file="$ENV_FILE"
    if grep -q $'\r' "$file" 2>/dev/null; then
        _kv ".env format" "$(_dot warn) ${C_WARN}CRLF line endings - fix with an update${CR}"
    elif [ -n "$(tail -c1 "$file")" ]; then
        _kv ".env format" "$(_dot warn) ${C_WARN}missing trailing newline${CR}"
    else
        _kv ".env format" "$(_dot ok) ${C_OK}clean${CR}"
    fi

    for key in DATABASE_URL AUTH_SECRET POSTGRES_PASSWORD WEB_PORT; do
        [ -n "$(env_get "$key")" ] || missing="${missing} ${key}"
    done
    if [ -n "$missing" ]; then
        _kv ".env keys" "$(_dot bad) ${C_BAD}missing:${missing}${CR}"
    else
        _kv ".env keys" "$(_dot ok) ${C_OK}complete${CR}"
    fi

    url_port="$(env_get DATABASE_URL | sed -n 's|.*127.0.0.1:\([0-9]*\)/.*|\1|p')"
    if [ -n "$url_port" ] && [ "$url_port" != "$DB_PORT" ]; then
        _kv "Database URL" "$(_dot bad) ${C_BAD}points at ${url_port} but db listens on ${DB_PORT}${CR}"
    else
        _kv "Database URL" "$(_dot ok) ${C_OK}port ${DB_PORT}${CR}"
    fi

    read -r up total <<<"$(container_counts)"
    if [ "${up:-0}" -eq 0 ]; then
        _kv "Containers" "$(_dot bad) ${C_BAD}none running - start them from the menu${CR}"
    elif [ "$up" -ne "$total" ]; then
        _kv "Containers" "$(_dot warn) ${C_WARN}${up}/${total} up${CR}"
    else
        _kv "Containers" "$(_dot ok) ${C_OK}${up}/${total} up${CR}"
    fi

    if api_health >/dev/null 2>&1; then
        _kv "API health" "$(_dot ok) ${C_OK}$(panel_version)${CR}"
    else
        _kv "API health" "$(_dot bad) ${C_BAD}no response on 127.0.0.1:${API_PORT}${CR}"
    fi

    rows="$(foreign_stacks)"
    if [ -n "$rows" ]; then
        _kv "Foreign stacks" "$(_dot warn) ${C_WARN}another install is present${CR}"
        while IFS=$'\t' read -r name image status; do
            [ -n "$name" ] || continue
            printf "      ${C_DIM}%-22s %s  %s${CR}\n" "$name" "$image" "$status"
        done <<<"$rows"
    else
        _kv "Foreign stacks" "$(_dot ok) ${C_OK}none${CR}"
    fi

    free="$(df -h "$APP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
    _kv "Disk free" "${C_DIM}${free:-unknown}${CR}"
    _kv "Channel" "${C_DIM}$(channel_label "$IMAGE_TAG")${CR}"

    services_section
    _back_to_menu
}

function purge_panel() {
    clear 2>/dev/null
    banner
    _sec "Delete panel"
    printf "    ${C_DIM}This permanently deletes:${CR}\n"
    printf "      ${C_DIM}- containers, networks and images (web / api / postgres)${CR}\n"
    printf "      ${C_DIM}- docker volumes: the database and all panel data${CR}\n"
    printf "      ${C_DIM}- %s (configs, certificates, openvpn, xray, backups)${CR}\n" "$APP_DIR"
    printf "      ${C_DIM}- host helper units and nginx vhosts created by %s${CR}\n" "$APP_NAME"
    printf "      ${C_DIM}- the %s command and this installer script itself${CR}\n" "$APP_NAME"
    echo ""

    local iface unit f nginx_touched=0
    if ! _confirm "Delete everything permanently?" "N"; then
        _info "Cancelled - nothing was removed."
        _back_to_menu
        return 0
    fi

    iface="$(env_get WG_INTERFACE)"
    iface="${iface:-wg0}"

    STEP_TOTAL=3; STEP_NO=0; ETA_REMAINING=0
    print_header "Purging ${APP_NAME}"

    if installed && docker_ready; then
        run_step "Removing containers" \
            "compose down -v --remove-orphans --rmi all || compose down -v --remove-orphans" || show_step_error
    fi

    if docker_ready; then
        run_step "Removing images & volumes" \
            "docker rm -f '${COMPOSE_PROJECT}-db-1' '${COMPOSE_PROJECT}-api-1' '${COMPOSE_PROJECT}-web-1' >/dev/null 2>&1; \
             docker volume rm -f '${COMPOSE_PROJECT}_pg_data' '${COMPOSE_PROJECT}_wg_data' >/dev/null 2>&1; \
             docker network rm '${COMPOSE_PROJECT}_default' >/dev/null 2>&1; \
             docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '/(wg-mate-web|wg-mate-api):' | xargs -r docker rmi -f >/dev/null 2>&1; \
             true" || show_step_error
    fi

    run_step "Removing host helpers" "purge_host_helpers" || show_step_error

    for f in /etc/nginx/sites-enabled/wg-mate /etc/nginx/sites-available/wg-mate \
             /etc/nginx/sites-enabled/wg-mate-ssl-* /etc/nginx/sites-available/wg-mate-ssl-* \
             /etc/nginx/sites-enabled/wg-mate-acme-* /etc/nginx/sites-available/wg-mate-acme-*; do
        [ -e "$f" ] || continue
        rm -f "$f"
        nginx_touched=1
    done
    if [ "$nginx_touched" = "1" ]; then
        _ok "nginx vhosts removed."
        if have nginx && nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1
        else
            _warn "nginx config invalid after cleanup - check: nginx -t"
        fi
    fi

    if have ip && ip link show "$iface" >/dev/null 2>&1; then
        if _confirm "Also delete the WireGuard interface ${iface}?" "Y"; then
            if have wg-quick; then
                wg-quick down "$iface" >/dev/null 2>&1 || ip link del "$iface" >/dev/null 2>&1
            else
                ip link del "$iface" >/dev/null 2>&1
            fi
            _ok "Interface ${iface} removed."
        fi
    fi

    state_clear
    rm -rf "$APP_DIR"
    _ok "Removed ${APP_DIR}."
    remove_installer_copies
    hash -r 2>/dev/null

    _sec "Done"
    printf "    ${C_OK}${APP_NAME} completely removed.${CR}\n"
    printf "    ${C_DIM}Reinstall any time:${CR}\n"
    printf "      ${C_KEY}bash -c \"\$(curl -fsSL ${SCRIPT_URL})\" -- install${CR}\n"
    echo ""
    exit 0
}

purge_host_helpers() {
    local unit
    for unit in wg-mate-panel-ssl.path wg-mate-panel-ssl.service \
                wg-mate-panel-net.path wg-mate-panel-net.service; do
        systemctl disable --now "$unit" >/dev/null 2>&1
        rm -f "/etc/systemd/system/${unit}"
    done
    systemctl daemon-reload >/dev/null 2>&1
    rm -f "$SHORTCUT" /var/log/wg-mate-panel-ssl.log /var/log/wg-mate-panel-net.log
    return 0
}

function show_menu() {
    if [ ! -t 0 ]; then
        return 0
    fi
    local option
    while true; do
        show_logo
        if installed; then
            printf "    ${C_DIM}%s${CR}\n" "$APP_DIR"
        else
            printf "    ${C_WARN}not installed${CR} ${C_DIM}- choose 1 to install${CR}\n"
        fi
        _sec "Menu"
        _mi "1"  "Install panel"
        _mi "2"  "Update panel"
        _mi "3"  "Panel status"
        _mi "4"  "Show logs"
        _mi "5"  "Start services"
        _mi "6"  "Stop services"
        _mi "7"  "Restart services"
        _mi "8"  "Login info"
        _mi "9"  "Delete panel"
        _mi "10" "Help & Parameters"
        _mi "0"  "Exit"
        _rule
        echo ""
        printf  "  ${C_PROMPT}❯${CR} Select an option ${C_DIM}[0-10]${CR}: "
        read -r option || { echo ""; exit 0; }
        case $option in
            1)  install_panel ;;
            2)  update_panel ;;
            3)  show_status ;;
            4)  show_logs ;;
            5)  service_action start ;;
            6)  service_action stop ;;
            7)  service_action restart ;;
            8)  show_login_info ;;
            9)  purge_panel ;;
            10) show_help_screen ;;
            0)  echo -e "\n${C_OK}Exiting...${CR}"; exit 0 ;;
            *)  echo -e "\n${C_BAD}Invalid option. Please try again.${CR}"; sleep 1 ;;
        esac
    done
}

function show_help_screen() {
    clear 2>/dev/null
    banner

    _sec "Commands"
    _kv "install" "${C_DIM}Install the panel${CR}"
    _kv "update" "${C_DIM}Update the panel (choose channel / version)${CR}"
    _kv "status" "${C_DIM}Containers, ports and version${CR}"
    _kv "logs" "${C_DIM}Follow logs (web | api | db)${CR}"
    _kv "start" "${C_DIM}Start the services${CR}"
    _kv "stop" "${C_DIM}Stop the services (data is kept)${CR}"
    _kv "restart" "${C_DIM}Recreate and restart the services${CR}"
    _kv "doctor" "${C_DIM}Diagnose a broken install${CR}"
    _kv "selfupdate" "${C_DIM}Force-refresh this script from GitHub${CR}"
    _kv "backup" "${C_DIM}Database + config archive${CR}"
    _kv "restore" "${C_DIM}Restore from a backup archive${CR}"
    _kv "login" "${C_DIM}Show the panel URL and admin credentials${CR}"
    _kv "purge" "${C_DIM}Delete the panel and every trace of it${CR}"
    _kv "menu" "${C_DIM}Open this interactive panel (default)${CR}"

    _sec "Install parameters"
    _kv "--admin" "${C_DIM}Admin username${CR}"
    _kv "--password" "${C_DIM}Admin password${CR}"
    _kv "--web-port" "${C_DIM}Panel web port (default ${DEFAULT_WEB_PORT})${CR}"
    _kv "--api-port" "${C_DIM}API port (default ${DEFAULT_API_PORT})${CR}"
    _kv "--db-port" "${C_DIM}Database port (default ${DEFAULT_DB_PORT})${CR}"
    _kv "--tz" "${C_DIM}Timezone (default ${DEFAULT_TZ})${CR}"

    _sec "Source parameters"
    _kv "--channel" "${C_DIM}stable | beta${CR}"
    _kv "--version" "${C_DIM}Pin one exact version (e.g. v0.2.4)${CR}"
    _kv "--service" "${C_DIM}Service for logs: web | api | db${CR}"
    _kv "--file" "${C_DIM}Backup archive used by restore${CR}"
    _kv "-y, --yes" "${C_DIM}Answer yes to confirmations${CR}"
    _kv "-h, --help" "${C_DIM}Show CLI help and exit${CR}"

    _sec "Channels"
    _kv "stable" "${C_DIM}${WEB_IMAGE}:latest${CR}"
    _kv "beta" "${C_DIM}${WEB_IMAGE}:dev${CR}"
    _kv "vX.Y.Z" "${C_DIM}pin one exact version, e.g. v0.2.4${CR}"

    _sec "Examples"
    printf "    ${C_KEY}wg-mate install --channel stable${CR}\n"
    printf "    ${C_KEY}wg-mate install --admin admin --password secret123 \\\\${CR}\n"
    printf "    ${C_DIM}            --web-port 3000 --version v0.2.4${CR}\n"
    printf "    ${C_KEY}wg-mate update --channel beta${CR}\n"
    printf "    ${C_KEY}wg-mate logs --service api${CR}\n"
    printf "    ${C_KEY}wg-mate backup${CR}\n"
    printf "    ${C_KEY}wg-mate restore --file /opt/wg-mate/backups/wg-mate-20260101-120000.tar.gz${CR}\n"

    echo ""
    _rule
    _back_to_menu
}

ARG_CHANNEL=""   ARG_VERSION=""   ARG_ADMIN=""     ARG_PASSWORD=""
ARG_WEB_PORT=""  ARG_API_PORT=""  ARG_DB_PORT=""   ARG_TZ=""
ARG_SERVICE=""   ARG_FILE=""      ARG_YES="0"

print_usage() {
    cat <<USAGE

  wg-mate - management script (installer v${SCRIPT_VERSION})

  Usage:
    wg-mate [command] [options]

  Commands:
    install            Install the panel
    update             Update the panel
    status             Containers, ports and version
    logs               Follow the logs
    start              Start the services
    stop               Stop the services (data is kept)
    restart            Recreate and restart the services
    login              Show the panel URL and admin credentials
    doctor             Diagnose a broken install
    selfupdate         Force-refresh this script from GitHub
    backup             Database + config archive
    restore            Restore from a backup archive
    purge              Delete the panel and every trace of it
    menu               Show interactive menu (default)

  Options:
    --channel <name>   Update channel: stable | beta
    --version <tag>    Pin one exact version (e.g. v0.2.4)
    --admin <user>     Admin username
    --password <pass>  Admin password
    --web-port <port>  Panel web port (default ${DEFAULT_WEB_PORT})
    --api-port <port>  API port (default ${DEFAULT_API_PORT})
    --db-port <port>   Database port (default ${DEFAULT_DB_PORT})
    --tz <zone>        Timezone (default ${DEFAULT_TZ})
    --service <name>   Service for logs: web | api | db
    --file <path>      Backup archive used by restore
    -y, --yes          Answer yes to confirmations
    -h, --help         Show this help and exit

  Examples:
    wg-mate install --channel stable
    wg-mate install --admin admin --password secret123 --web-port 3000
    wg-mate update --version v0.2.4
    wg-mate logs --service api
    wg-mate restore --file /opt/wg-mate/backups/wg-mate-20260101-120000.tar.gz

USAGE
}

process_arguments() {
    local cmd="menu"
    case "$1" in
        install|update|status|logs|start|stop|restart|doctor|backup|restore|purge|menu)
            cmd="$1"; shift ;;
        selfupdate|self-update|update-script) cmd="selfupdate"; shift ;;
        upgrade)        cmd="update"; shift ;;
        ps)             cmd="status"; shift ;;
        destroy)        cmd="purge"; shift ;;
        login|credentials) cmd="login"; shift ;;
        -h|--help|help) print_usage; exit 0 ;;
        version|--version|-v) printf '%s installer v%s\n' "$APP_NAME" "$SCRIPT_VERSION"; exit 0 ;;
        "") cmd="menu" ;;
        --*) cmd="menu" ;;
        *) cmd="menu" ;;
    esac

    while [ $# -gt 0 ]; do
        case "$1" in
            --channel|--version|--admin|--password|--web-port|--api-port|--db-port|--tz|--service|--file)
                if [ $# -lt 2 ]; then
                    echo -e "\e[91mMissing value for $1\033[0m"
                    print_usage
                    exit 1
                fi
                ;;
        esac
        case "$1" in
            --channel)  ARG_CHANNEL="$2";  shift 2 ;;
            --version)  ARG_VERSION="$2";  shift 2 ;;
            --admin)    ARG_ADMIN="$2";    shift 2 ;;
            --password) ARG_PASSWORD="$2"; shift 2 ;;
            --web-port) ARG_WEB_PORT="$2"; shift 2 ;;
            --api-port) ARG_API_PORT="$2"; shift 2 ;;
            --db-port)  ARG_DB_PORT="$2";  shift 2 ;;
            --tz)       ARG_TZ="$2";       shift 2 ;;
            --service)  ARG_SERVICE="$2";  shift 2 ;;
            --file)     ARG_FILE="$2";     shift 2 ;;
            -y|--yes)   ARG_YES="1";       shift ;;
            -h|--help)  print_usage; exit 0 ;;
            *) echo -e "\e[91mUnknown option: $1\033[0m"; print_usage; exit 1 ;;
        esac
    done

    case "$cmd" in
        install)  install_panel ;;
        update)   update_panel ;;
        status)   show_status ;;
        logs)     show_logs ;;
        start)    service_action start ;;
        stop)     service_action stop ;;
        restart)  service_action restart ;;
        login)    show_login_info ;;
        doctor)   doctor_panel ;;
        selfupdate) update_script ;;
        backup)   backup_panel ;;
        restore)  restore_panel ;;
        purge)    purge_panel ;;
        menu|*)   show_menu; return 0 ;;
    esac
    show_menu
}
process_arguments "$@"
