#!/bin/bash

SCRIPT_VERSION="0.3.1"
GIT_REPO="Mate-Panel/wg-mate-script"
SCRIPT_URL="https://raw.githubusercontent.com/${GIT_REPO}/main/install.sh"
SCRIPT_API_URL="https://api.github.com/repos/${GIT_REPO}/contents/install.sh?ref=main"

APP_NAME="wg-mate"
APP_DIR="/opt/wg-mate"
ENV_FILE="$APP_DIR/.env"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
STATE_FILE="$APP_DIR/.wgmate_install_state"
COMPOSE_PROJECT="wg-mate"
SHORTCUT="/usr/local/bin/wg-mate"
WEB_IMAGE="ghcr.io/mate-panel/wg-mate-web"
API_IMAGE="ghcr.io/mate-panel/wg-mate-api"
DB_IMAGE="postgres:16-alpine"
DOCKER_SOCK="/var/run/docker.sock"
DOCKER_HUB_MIRRORS="docker.arvancloud.ir hub.hamdocker.ir"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
LICENSE_PUBKEY="ksB0JTWOEQj2bZlG5s9zKeEfoqDo9nmf/a0JWOjuau4="

DEFAULT_WEB_PORT="3000"
DEFAULT_API_PORT="52653"
DEFAULT_DB_PORT="5433"
DEFAULT_TZ="Asia/Tehran"

IMAGE_TAG="latest"
WEB_PORT="$DEFAULT_WEB_PORT"
API_PORT="$DEFAULT_API_PORT"
DB_PORT="$DEFAULT_DB_PORT"
TZ_VALUE="$DEFAULT_TZ"
ADMIN_USERNAME=""
ADMIN_PASSWORD=""

ARG_CHANNEL=""  ARG_VERSION=""  ARG_ADMIN=""    ARG_PASSWORD=""
ARG_WEB_PORT="" ARG_API_PORT="" ARG_DB_PORT=""  ARG_TZ=""
ARG_SERVICE=""  ARG_FILE=""     ARG_YES="0"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none

if [ -t 1 ]; then
    IS_TTY=1
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1;97m'
    C_DIM=$'\033[90m'
    C_ACCENT=$'\033[96m'
    C_OK=$'\033[92m'
    C_WARN=$'\033[93m'
    C_BAD=$'\033[91m'
    C_KEY=$'\033[95m'
else
    IS_TTY=0
    C_RESET="" C_BOLD="" C_DIM="" C_ACCENT="" C_OK="" C_WARN="" C_BAD="" C_KEY=""
fi

RULE="──────────────────────────────────────────"
SPINNER=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

rule()  { printf '  %s%s%s\n' "$C_DIM" "$RULE" "$C_RESET"; }
title() { printf '\n  %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; rule; }
ok()    { printf '  %s✔%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn()  { printf '  %s!%s %s%s%s\n' "$C_WARN" "$C_RESET" "$C_WARN" "$*" "$C_RESET"; }
fail()  { printf '  %s✘%s %s%s%s\n' "$C_BAD" "$C_RESET" "$C_BAD" "$*" "$C_RESET"; }
info()  { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
kv()    { printf '  %s%-9s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }
dot()   { printf '%s●%s %s' "$1" "$C_RESET" "$2"; }

fmt_secs() {
    if [ "$1" -lt 60 ]; then
        printf -v "$2" '%ds' "$1"
    else
        printf -v "$2" '%dm%02ds' $(($1 / 60)) $(($1 % 60))
    fi
}

fmt_mb() {
    local tenths=$(( $1 * 10 / 1048576 ))
    printf -v "$2" '%d.%d MB' $((tenths / 10)) $((tenths % 10))
}

now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [ -n "$t" ]; then
        t="${t/[.,]/}"
        printf -v "$1" '%s' "$((10#$t / 1000))"
    else
        printf -v "$1" '%s' "$(( $(date +%s) * 1000 ))"
    fi
}

ask() {
    local label="$1" def="$2" reply=""
    if [ -n "$def" ]; then
        printf '  %-9s %s[%s]%s: ' "$label" "$C_DIM" "$def" "$C_RESET" >&2
    else
        printf '  %-9s: ' "$label" >&2
    fi
    read -r reply || reply=""
    printf '%s' "${reply:-$def}"
}

ask_secret() {
    local label="$1" hint="$2" reply=""
    if [ -n "$hint" ]; then
        printf '  %-9s %s[%s]%s: ' "$label" "$C_DIM" "$hint" "$C_RESET" >&2
    else
        printf '  %-9s: ' "$label" >&2
    fi
    read -r -s reply || reply=""
    echo >&2
    printf '%s' "${reply//[$'\r\n']/}"
}

confirm() {
    local question="$1" def="${2:-N}" hint="[y/N]" reply=""
    [ "$ARG_YES" = "1" ] && return 0
    case "$def" in [Yy]*) hint="[Y/n]" ;; esac
    if [ ! -t 0 ]; then
        case "$def" in [Yy]*) return 0 ;; *) return 1 ;; esac
    fi
    printf '  %s %s%s%s ' "$question" "$C_DIM" "$hint" "$C_RESET" >&2
    read -r reply || reply=""
    case "${reply:-$def}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

STEP_PID=""

kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill_tree "$child"
    done
    kill "$1" 2>/dev/null
}

on_interrupt() {
    if [ -n "$STEP_PID" ]; then
        kill_tree "$STEP_PID"
        wait "$STEP_PID" 2>/dev/null
    fi
    printf '\r\033[K'
    tput cnorm 2>/dev/null
    fail "Interrupted"
    exit 130
}

step_note() { printf '%s' "$*" > "$NOTE_FILE" 2>/dev/null; }

step() {
    local label="$1" start=$SECONDS i=0 rc note took
    shift
    : > "$NOTE_FILE"
    printf '\n### %s  %s\n' "$(date '+%F %T')" "$label" >> "$LOG_FILE"
    "$@" >> "$LOG_FILE" 2>&1 &
    STEP_PID=$!
    trap on_interrupt INT TERM
    if [ "$IS_TTY" = "1" ]; then
        tput civis 2>/dev/null
        while kill -0 "$STEP_PID" 2>/dev/null; do
            note="$(cat "$NOTE_FILE" 2>/dev/null)"
            fmt_secs $((SECONDS - start)) took
            printf '\r\033[K  %s%s%s %-16s %s%s%s%s' "$C_ACCENT" "${SPINNER[i]}" "$C_RESET" "$label" \
                "$C_DIM" "$took" "${note:+ · $note}" "$C_RESET"
            i=$(( (i + 1) % ${#SPINNER[@]} ))
            sleep 0.15
        done
        tput cnorm 2>/dev/null
    fi
    wait "$STEP_PID"
    rc=$?
    STEP_PID=""
    trap - INT TERM
    fmt_secs $((SECONDS - start)) took
    if [ "$rc" -eq 0 ]; then
        printf '\r\033[K  %s✔%s %-16s %s%s%s\n' "$C_OK" "$C_RESET" "$label" "$C_DIM" "$took" "$C_RESET"
    else
        printf '\r\033[K  %s✘%s %-16s %s%s%s\n' "$C_BAD" "$C_RESET" "$label" "$C_DIM" "$took" "$C_RESET"
    fi
    return "$rc"
}

show_log_tail() {
    echo ""
    tail -n 12 "$LOG_FILE" 2>/dev/null | sed "s/^/    ${C_DIM}/; s/\$/${C_RESET}/"
    echo ""
    info "Full log: $LOG_FILE"
}

have() { command -v "$1" >/dev/null 2>&1; }

rand_hex() {
    if have openssl; then
        openssl rand -hex "$1"
    else
        head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
json_quote()  { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

is_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

strip_v() { printf '%s' "${1#v}"; }

version_ge() {
    local a b
    a="$(strip_v "$1")"; b="$(strip_v "$2")"
    [ "$a" = "$b" ] && return 0
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
}

cache_fresh() {
    [ -s "$1" ] || return 1
    [ $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )) -lt "${2:-3600}" ]
}

dns_works() {
    getent hosts github.com >/dev/null 2>&1 || getent hosts ghcr.io >/dev/null 2>&1
}

ensure_dns() {
    local resolv="/etc/resolv.conf" d ifc
    dns_works && return 0
    if [ -L "$resolv" ]; then
        rm -f "$resolv"
    elif [ -f "$resolv" ] && [ ! -f "${resolv}.wgmate.bak" ]; then
        cp -a "$resolv" "${resolv}.wgmate.bak"
    fi
    for d in "${DNS_SERVERS[@]}"; do echo "nameserver $d"; done > "$resolv"
    if have resolvectl; then
        ifc="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
        [ -n "$ifc" ] && resolvectl dns "$ifc" "${DNS_SERVERS[@]}" 2>/dev/null
    fi
    sleep 1
    dns_works
}

net_works() {
    curl -fsSL --max-time 8 -o /dev/null "https://github.com" 2>/dev/null \
        || curl -fsSL --max-time 8 -o /dev/null "https://ghcr.io" 2>/dev/null
}

ensure_connectivity() {
    net_works && return 0
    ensure_dns
    net_works
}

detect_os() {
    OS_ID=""; OS_CODENAME=""; OS_PRETTY=""; OS_ID_LIKE=""
    [ -f /etc/os-release ] || return 1
    IFS=$'\n' read -r -d '' OS_ID OS_CODENAME OS_PRETTY OS_ID_LIKE < <(
        . /etc/os-release
        printf '%s\n%s\n%s\n%s\n\0' "${ID:-}" "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" "${PRETTY_NAME:-}" "${ID_LIKE:-}"
    )
    return 0
}

is_private_ip() {
    case "$1" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|169.254.*|""|*:*) return 0 ;;
        *) return 1 ;;
    esac
}

server_ip() {
    local ip
    if cache_fresh "$IP_CACHE"; then
        cat "$IP_CACHE"
        return 0
    fi
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
    if is_private_ip "$ip"; then
        ip="$(curl -4 -fsSL --max-time 3 https://ifconfig.me 2>/dev/null || curl -4 -fsSL --max-time 3 https://api.ipify.org 2>/dev/null)"
        [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    ip="${ip:-SERVER}"
    printf '%s' "$ip" > "$IP_CACHE"
    printf '%s' "$ip"
}

panel_url() { printf 'http://%s:%s' "$(server_ip)" "$WEB_PORT"; }

port_pid() {
    have ss || return 0
    ss -Hltnp 2>/dev/null | grep -E "[:.]$1[[:space:]]" | head -1 | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
}

port_in_use() {
    if have ss; then
        ss -Hltn 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
    elif have netstat; then
        netstat -ltn 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
    else
        return 1
    fi
}

pid_container() {
    local id
    [ -n "$1" ] && [ -r "/proc/$1/cgroup" ] || return 0
    id="$(grep -oE '[0-9a-f]{64}' "/proc/$1/cgroup" 2>/dev/null | head -1)"
    [ -n "$id" ] || return 0
    docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||'
}

port_owner() {
    local pid container name
    pid="$(port_pid "$1")"
    [ -n "$pid" ] || return 0
    container="$(pid_container "$pid")"
    if [ -n "$container" ]; then
        printf 'container %s' "$container"
        return 0
    fi
    name="$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')"
    printf '%s (pid %s)' "${name:-a process}" "$pid"
}

our_container_on_port() {
    case "$(pid_container "$(port_pid "$1")")" in
        "${COMPOSE_PROJECT}-"*) return 0 ;;
        *) return 1 ;;
    esac
}

port_taken() { port_in_use "$1" && ! our_container_on_port "$1"; }

free_port_from() {
    local p="$1" limit=$(( $1 + 40 ))
    while [ "$p" -le "$limit" ]; do
        port_in_use "$p" || { printf '%s' "$p"; return 0; }
        p=$((p + 1))
    done
    printf '%s' "$1"
}

env_get() {
    local line value=""
    [ -f "$ENV_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line =~ ^[[:space:]]*$1=(.*)$ ]] || continue
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
    local tmp
    [ -f "$ENV_FILE" ] || return 0
    tmp="$(mktemp)" || return 1
    grep -v "^[[:space:]]*$1=" "$ENV_FILE" > "$tmp"
    if [ -s "$tmp" ] && [ -n "$(tail -c1 "$tmp")" ]; then
        printf '\n' >> "$tmp"
    fi
    printf '%s=%s\n' "$1" "$(shell_quote "$2")" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
    chmod 600 "$ENV_FILE"
}

env_unset() {
    local tmp
    [ -f "$ENV_FILE" ] || return 0
    grep -q "^[[:space:]]*$1=" "$ENV_FILE" || return 0
    tmp="$(mktemp)" || return 1
    grep -v "^[[:space:]]*$1=" "$ENV_FILE" > "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
    chmod 600 "$ENV_FILE"
}

env_default() {
    [ -n "$(env_get "$1")" ] || env_set "$1" "$2"
}

installed() { [ -f "$COMPOSE_FILE" ] && [ -f "$ENV_FILE" ]; }

load_config() {
    local v
    v="$(env_get WEB_PORT)"; is_port "$v" && WEB_PORT="$v"
    v="$(env_get API_PORT)"; is_port "$v" && API_PORT="$v"
    v="$(env_get DB_PORT)";  is_port "$v" && DB_PORT="$v"
    v="$(env_get TZ)";       [ -n "$v" ] && TZ_VALUE="$v"
    v="$(env_get WG_MATE_CHANNEL)"; IMAGE_TAG="${v:-latest}"
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

channel_name() {
    case "${1:-latest}" in
        latest) printf 'stable' ;;
        dev) printf 'beta' ;;
        *) printf '%s' "$1" ;;
    esac
}

state_set() {
    mkdir -p "$APP_DIR"
    [ -f "$STATE_FILE" ] || { : > "$STATE_FILE"; chmod 600 "$STATE_FILE"; }
    sed -i "/^$1=/d" "$STATE_FILE"
    printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"
}

state_get() {
    [ -f "$STATE_FILE" ] || return 0
    grep -E "^$1=" "$STATE_FILE" | tail -1 | cut -d= -f2-
}

phase_done() { [ -f "$STATE_FILE" ] && grep -qxF "PHASE:$1" "$STATE_FILE"; }

mark_phase() { phase_done "$1" || echo "PHASE:$1" >> "$STATE_FILE"; }

has_resumable_state() {
    [ -f "$STATE_FILE" ] || return 1
    grep -qE '^(PHASE:|STARTED=)' "$STATE_FILE" && ! phase_done COMPLETE
}

state_clear() { rm -f "$STATE_FILE"; }

docker_ready() { have docker && docker info >/dev/null 2>&1; }

compose() {
    local args=(-p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE")
    [ -f "$ENV_FILE" ] && args+=(--env-file "$ENV_FILE")
    if docker compose version >/dev/null 2>&1; then
        docker compose "${args[@]}" "$@"
    elif have docker-compose; then
        docker-compose "${args[@]}" "$@"
    else
        echo "docker compose plugin not found" >&2
        return 1
    fi
}

container_counts() {
    local up total
    up="$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null | wc -l)"
    total="$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null | wc -l)"
    printf '%s %s' "$((up))" "$((total))"
}

containers_exist() {
    docker_ready && [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" 2>/dev/null)" ]
}

db_volume_exists() { docker volume inspect "${COMPOSE_PROJECT}_pg_data" >/dev/null 2>&1; }

api_health() { curl -fsS --max-time 3 "http://127.0.0.1:${API_PORT}/health" 2>/dev/null; }

wait_api_healthy() {
    local waited=0
    while [ "$waited" -lt "$1" ]; do
        api_health >/dev/null && return 0
        sleep 2
        waited=$((waited + 2))
    done
    api_health >/dev/null
}

panel_version() {
    local v
    v="$(api_health | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)"
    if [ -z "$v" ]; then
        v="$(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
            --filter "label=com.docker.compose.service=api" --format '{{.Image}}' 2>/dev/null | head -1)"
        v="${v:+${v##*:}}"
        case "$v" in v[0-9]*) ;; *) v="" ;; esac
    fi
    printf '%s' "$v"
}

latest_panel_version() {
    local repo token v
    if cache_fresh "$LATEST_CACHE"; then
        cat "$LATEST_CACHE"
        return 0
    fi
    repo="${API_IMAGE#ghcr.io/}"
    token="$(curl -fsSL --max-time 4 "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" 2>/dev/null \
        | grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4)"
    [ -n "$token" ] || return 1
    v="$(curl -fsSL --max-time 5 -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/${repo}/tags/list" 2>/dev/null \
        | tr ',' '\n' | grep -oE '"v[0-9]+(\.[0-9]+)*"' | tr -d '"' | sort -V | tail -1)"
    [ -n "$v" ] || return 1
    printf '%s' "$v" > "$LATEST_CACHE"
    printf '%s' "$v"
}

db_user() { local v; v="$(env_get POSTGRES_USER)"; printf '%s' "${v:-wgmate}"; }
db_name() { local v; v="$(env_get POSTGRES_DB)"; printf '%s' "${v:-wgmate}"; }

database_url() {
    printf 'postgres://%s:%s@127.0.0.1:%s/%s?sslmode=disable' \
        "$(db_user)" "$(env_get POSTGRES_PASSWORD)" "$DB_PORT" "$(db_name)"
}

psql_do() {
    compose exec -T db psql -v ON_ERROR_STOP=1 -U "$(db_user)" -d "$(db_name)" -tAc "$1"
}

foreign_stacks() {
    docker_ready || return 0
    docker ps -a --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Image}}\t{{.Status}}' 2>/dev/null \
        | awk -F'\t' -v proj="$COMPOSE_PROJECT" '$2 != proj && ($3 ~ /wg-?mate/ || $3 ~ /wgpanel/) { print $1"\t"$3"\t"$4 }'
}

remove_foreign_stacks() {
    foreign_stacks | cut -f1 | xargs -r docker rm -f
}

apt_recover() {
    local i=0
    have apt-get || return 0
    while have fuser && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && [ "$i" -lt 60 ]; do
        sleep 2
        i=$((i + 1))
    done
    systemctl stop unattended-upgrades >/dev/null 2>&1
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
    dpkg --configure -a
    apt-get -f install -y -o DPkg::Lock::Timeout=180
    return 0
}

setup_docker_repo() {
    local distro="ubuntu" codename arch
    detect_os
    case "$OS_ID" in
        ubuntu|debian) distro="$OS_ID" ;;
        *) case "$OS_ID_LIKE" in *ubuntu*) distro="ubuntu" ;; *debian*) distro="debian" ;; esac ;;
    esac
    codename="${OS_CODENAME:-$(lsb_release -cs 2>/dev/null || echo stable)}"
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
    if have apt-get; then
        apt-get install -y -o DPkg::Lock::Timeout=180 docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif have dnf; then
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    elif have yum; then
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        echo "unsupported distribution - install docker manually, then run again"
        return 1
    fi
}

install_docker_from_distro() {
    have apt-get || return 1
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update -y -o DPkg::Lock::Timeout=180
    apt-get install -y -o DPkg::Lock::Timeout=180 docker.io docker-compose-v2
}

enable_docker() {
    local i=0
    systemctl enable --now docker >/dev/null 2>&1
    while [ "$i" -lt 15 ]; do
        docker info >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    docker info >/dev/null 2>&1
}

load_kernel_modules() {
    have modprobe || return 0
    modprobe wireguard || echo "wireguard kernel module unavailable (install linux-headers for this kernel)"
    modprobe tun
    return 0
}

setup_docker() {
    if ! { have docker && docker compose version >/dev/null 2>&1; }; then
        step_note "waiting for apt"
        apt_recover
        if have apt-get; then
            step_note "prerequisites"
            apt-get install -y -o DPkg::Lock::Timeout=180 ca-certificates curl gnupg || return 1
            step_note "docker repository"
            setup_docker_repo || echo "docker repository unavailable - using the distribution packages"
        fi
        step_note "docker engine"
        if ! install_docker_engine; then
            step_note "distribution packages"
            install_docker_from_distro || return 1
        fi
    fi
    step_note "starting docker"
    enable_docker || return 1
    load_kernel_modules
}

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
if [ -f "$DATA/ssl.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$DATA/ssl.env"
  set +a
fi
INTERNAL_PORT="${PANEL_INTERNAL_PORT:-}"
if ! [[ "${INTERNAL_PORT:-}" =~ ^[0-9]+$ ]] || [ "${INTERNAL_PORT:-0}" -lt 1 ] || [ "${INTERNAL_PORT:-0}" -gt 65535 ]; then
  INTERNAL_PORT="$(grep -oE '"internalPort"[[:space:]]*:[[:space:]]*[0-9]+' "$DATA/panel-net.json" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || true)"
fi
if ! [[ "${INTERNAL_PORT:-}" =~ ^[0-9]+$ ]] || [ "${INTERNAL_PORT:-0}" -lt 1 ] || [ "${INTERNAL_PORT:-0}" -gt 65535 ]; then
  INTERNAL_PORT=3000
fi
WEBROOT="$DATA/acme-webroot"
CHALLENGES="$DATA/acme-challenge.txt"
PREFIX="wg-mate-ssl-"
ACME_PREFIX="wg-mate-acme-"
LOG="${PANEL_SSL_LOG:-/var/log/wg-mate-panel-ssl.log}"
ACME_HTTP_PORTS="${PANEL_ACME_HTTP_PORTS:-80,8080,8081,8880}"
ACME_PORT_FILE="$DATA/acme-http-port.txt"

log() { echo "$(date -Is) $*" >>"$LOG" 2>/dev/null || true; }
install -d -o root -g adm -m 755 /var/log/nginx 2>/dev/null || true

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

port_is_nginx() {
  local owner
  owner="$(port_owner "$1")"
  [ -n "$owner" ] || return 1
  case "$owner" in *nginx*) return 0 ;; esac
  case "$owner" in *users:*) return 1 ;; esac
  return 0
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
      if port_is_nginx "$hp"; then ok=1; break; fi
      sleep 0.25
    done
    if [ "$ok" -ne 1 ]; then
      log "HTTPS :${hp} is not served by nginx after reload (owner: $(port_owner "$hp")) — rolling back"
      rollback
      exit 1
    fi
  done
fi

if [ -n "$(echo "$want" | tr -d '[:space:]')" ] && command -v curl >/dev/null 2>&1; then
  upstream_ok=0
  for _ in 1 2 3; do
    if curl -fsS --max-time 3 "http://127.0.0.1:${INTERNAL_PORT}/healthz" >/dev/null 2>&1; then
      upstream_ok=1
      break
    fi
    sleep 1
  done
  if [ "$upstream_ok" -ne 1 ]; then
    log "WARNING: upstream 127.0.0.1:${INTERNAL_PORT} does not answer /healthz — TLS vhosts are live but every request will 502 (owner: $(port_owner "$INTERNAL_PORT")); check WEB_PORT in .env and internalPort in $DATA/panel-net.json"
  fi
fi

log "applied vhosts — tls:${want:- none} ports:${https_ports_used:- none} internal:${INTERNAL_PORT} challenge:${challenging:- none} acme-http:${ACME_PORTS:- none}"
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
LOG="${PANEL_NET_LOG:-/var/log/wg-mate-panel-net.log}"

log() { echo "$(date -Is) $*" >>"$LOG" 2>/dev/null || true; }
install -d -o root -g adm -m 755 /var/log/nginx 2>/dev/null || true

[ -f "$INTENT" ] || { log "no intent file at $INTENT"; exit 0; }
[ -f "$VHOST" ] || { log "vhost $VHOST missing"; exit 0; }

INTERNAL_PORT="$(grep -oE '"internalPort"[[:space:]]*:[[:space:]]*[0-9]+' "$INTENT" | grep -oE '[0-9]+$' | head -1 || true)"
if ! [[ "${INTERNAL_PORT:-}" =~ ^[0-9]+$ ]] || [ "$INTERNAL_PORT" -lt 1 ] || [ "$INTERNAL_PORT" -gt 65535 ]; then
  INTERNAL_PORT="${PANEL_INTERNAL_PORT:-3000}"
fi

port="$(grep -oE '"panelPort"[[:space:]]*:[[:space:]]*[0-9]+' "$INTENT" | grep -oE '[0-9]+$' | head -1 || true)"
[ -n "${port:-}" ] || { log "no panelPort in $INTENT"; exit 0; }

if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
  log "invalid port '$port' — ignoring"; exit 0
fi
if [ "$port" -eq "$INTERNAL_PORT" ]; then
  log "port $port collides with internal web port — ignoring"; exit 0
fi
case "$port" in
  22|25|53|465|587|993|995|3306|5432|5433|6379|8081|9443|52653)
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

    local xray_helpers=0 xray_restart=0
    if ! systemctl cat xray.service >/dev/null 2>&1 && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q xray; then
        cat > "/etc/systemd/system/xray.service" <<'WGMATE_XRAY_SERVICE_EOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target docker.service
ConditionPathExists=|/opt/wg-mate/data/xray/xray
ConditionPathExists=|/usr/local/bin/xray

[Service]
User=root
Environment=XRAY_LOCATION_ASSET=/opt/wg-mate/data/xray
ExecStart=/bin/sh -c 'B=/opt/wg-mate/data/xray/xray; [ -x "$$B" ] || B=/usr/local/bin/xray; exec "$$B" run -config /opt/wg-mate/data/xray/config.json'
Restart=on-failure
RestartSec=3
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
WGMATE_XRAY_SERVICE_EOF

        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable xray >/dev/null 2>&1
    fi
    if systemctl cat xray.service >/dev/null 2>&1; then
        xray_helpers=1
        mkdir -p /etc/systemd/system/xray.service.d
        cat > "/etc/systemd/system/xray.service.d/20-wg-mate-panel-config.conf.new" <<'WGMATE_XRAY_DROPIN_EOF'
[Service]
User=root
Environment=XRAY_LOCATION_ASSET=/opt/wg-mate/data/xray
ExecStart=
ExecStart=/bin/sh -c 'B=/opt/wg-mate/data/xray/xray; [ -x "$$B" ] || B=/usr/local/bin/xray; exec "$$B" run -config /opt/wg-mate/data/xray/config.json'
WGMATE_XRAY_DROPIN_EOF

        if cmp -s "/etc/systemd/system/xray.service.d/20-wg-mate-panel-config.conf.new" "/etc/systemd/system/xray.service.d/20-wg-mate-panel-config.conf"; then
            rm -f "/etc/systemd/system/xray.service.d/20-wg-mate-panel-config.conf.new"
        else
            mv -f "/etc/systemd/system/xray.service.d/20-wg-mate-panel-config.conf.new" "/etc/systemd/system/xray.service.d/20-wg-mate-panel-config.conf"
            xray_restart=1
        fi
        cat > "/etc/systemd/system/xray-panel-reload.path" <<'WGMATE_XRAY_PANEL_RELOAD_PATH_EOF'
[Unit]
Description=Watch the panel Xray config and binary

[Path]
PathChanged=/opt/wg-mate/data/xray/config.json
PathChanged=/opt/wg-mate/data/xray/xray
Unit=xray-panel-reload.service

[Install]
WantedBy=multi-user.target
WGMATE_XRAY_PANEL_RELOAD_PATH_EOF

        cat > "/etc/systemd/system/xray-panel-reload.service" <<'WGMATE_XRAY_PANEL_RELOAD_SERVICE_EOF'
[Unit]
Description=Restart Xray after the panel rewrites its config or binary

[Service]
Type=oneshot
Environment=XRAY_LOCATION_ASSET=/opt/wg-mate/data/xray
ExecStart=/bin/sh -c 'B=/opt/wg-mate/data/xray/xray; [ -x "$$B" ] || B=/usr/local/bin/xray; "$$B" run -test -config /opt/wg-mate/data/xray/config.json >/dev/null 2>&1 && systemctl restart xray'
WGMATE_XRAY_PANEL_RELOAD_SERVICE_EOF

        cat > "/etc/systemd/system/xray-log-export.service" <<'WGMATE_XRAY_LOG_EXPORT_SERVICE_EOF'
[Unit]
Description=Copy the Xray journal into the panel data folder
After=xray.service

[Service]
ExecStart=/bin/sh -c 'exec journalctl -u xray -f -n 0 -o short-iso >> /opt/wg-mate/data/xray/xray.log'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
WGMATE_XRAY_LOG_EXPORT_SERVICE_EOF

    fi
    if [ -e /etc/nginx/sites-enabled/default ] && ss -lntpH 'sport = :80' 2>/dev/null | grep -qv nginx; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now nginx >/dev/null 2>&1
    systemctl enable --now wg-mate-panel-ssl.path wg-mate-panel-net.path >/dev/null 2>&1
    systemctl start wg-mate-panel-ssl.service wg-mate-panel-net.service >/dev/null 2>&1
    if [ "$xray_helpers" = 1 ]; then
        systemctl enable xray-panel-reload.path xray-log-export.service >/dev/null 2>&1
        systemctl restart xray-panel-reload.path xray-log-export.service >/dev/null 2>&1
        [ "$xray_restart" = 1 ] && systemctl restart xray >/dev/null 2>&1
    fi
    return 0
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

CLR=""
[ "$IS_TTY" = "1" ] && CLR=$'\r\033[K'
TERM_COLS=80
PULL_ERROR=""
PULL_BYTES=0
PULL_UPTODATE=0
PULL_LINES=0
PULL_UPDATED=0

image_label() {
    case "$1" in
        "$API_IMAGE"*) printf 'api' ;;
        "$WEB_IMAGE"*) printf 'web' ;;
        *) printf 'db' ;;
    esac
}

image_present() { docker image inspect "$1" >/dev/null 2>&1; }

is_hub_image() {
    case "$1" in
        *.*/*|localhost/*) return 1 ;;
        *) return 0 ;;
    esac
}

registry_of() {
    if is_hub_image "$1"; then printf 'docker.io'; else printf '%s' "${1%%/*}"; fi
}

hub_mirror_refs() {
    local path="$1" m
    case "$1" in */*) ;; *) path="library/$1" ;; esac
    for m in $DOCKER_HUB_MIRRORS; do
        printf '%s/%s\n' "$m" "$path"
    done
}

pull_error_is_fatal() {
    grep -qiE 'manifest unknown|not found|repository does not exist|unauthorized|denied' <<<"$1"
}

draw_pull_progress() {
    local cur="$1" tot="$2" done_layers="$3" layers="$4" speed="$5"
    local pct=0 width=20 filled i bar="" cur_txt tot_txt speed_txt eta_txt text
    [ "$IS_TTY" = "1" ] || return 0
    if [ "$layers" -eq 0 ]; then
        printf '%s       %sconnecting to %s…%s' "$CLR" "$C_DIM" "$PULL_REGISTRY" "$C_RESET"
        return 0
    fi
    if [ "$tot" -eq 0 ]; then
        printf '%s       %s%d/%d layers · starting…%s' "$CLR" "$C_DIM" "$done_layers" "$layers" "$C_RESET"
        return 0
    fi
    [ "$tot" -gt 0 ] && pct=$(( cur * 100 / tot ))
    [ "$pct" -gt 100 ] && pct=100
    fmt_mb "$cur" cur_txt
    fmt_mb "$tot" tot_txt
    if [ "$tot" -gt 0 ] && [ "$cur" -ge "$tot" ] && [ "$done_layers" -lt "$layers" ]; then
        text="${tot_txt} · extracting ${done_layers}/${layers} layers"
    else
        text="${cur_txt} / ${tot_txt} · ${done_layers}/${layers} layers"
        if [ "$speed" -gt 0 ]; then
            fmt_mb "$speed" speed_txt
            text="${text} · ${speed_txt}/s"
            if [ "$tot" -gt "$cur" ]; then
                fmt_secs $(( (tot - cur) / speed )) eta_txt
                text="${text} · ${eta_txt} left"
            fi
        fi
    fi
    if [ "$TERM_COLS" -ge 100 ]; then
        filled=$(( pct * width / 100 ))
        for ((i = 0; i < width; i++)); do
            if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
        done
        printf '%s       %s%s%s%s%s %s%3d%%%s  %s%s%s' "$CLR" "$C_ACCENT" "${bar:0:filled}" "$C_DIM" "${bar:filled}" "$C_RESET" \
            "$C_ACCENT" "$pct" "$C_RESET" "$C_DIM" "$text" "$C_RESET"
    else
        printf '%s       %s%3d%%%s  %s%s%s' "$CLR" "$C_ACCENT" "$pct" "$C_RESET" "$C_DIM" "$text" "$C_RESET"
    fi
}

pull_one() {
    local ref="$1" name tag line st id cur tot err="" finished=0 k out rc
    local now last_draw=0 last_t last_bytes=0 speed=0 sum_cur=0 sum_tot=0 n=0 n_done=0
    local re_status='"status":"([^"]*)"' re_id='"id":"([^"]*)"' re_cur='"current":([0-9]+)'
    local re_tot='"total":([0-9]+)' re_err='"error":"(([^"\\]|\\.)*)"' re_msg='^\{"message":"(([^"\\]|\\.)*)"'
    local -A ltot=() lcur=() lstate=()
    PULL_ERROR=""
    PULL_BYTES=0
    PULL_UPTODATE=0
    PULL_REGISTRY="$(registry_of "$ref")"

    if [ ! -S "$DOCKER_SOCK" ]; then
        out="$(docker pull "$ref" 2>&1)"
        rc=$?
        printf '%s\n' "$out" >> "$LOG_FILE"
        if [ "$rc" -eq 0 ]; then
            grep -q 'Image is up to date' <<<"$out" && PULL_UPTODATE=1
            return 0
        fi
        PULL_ERROR="$(tail -n1 <<<"$out")"
        pull_error_is_fatal "$PULL_ERROR" && return 2
        return 1
    fi

    name="${ref%:*}"
    tag="${ref##*:}"
    now_ms last_t
    draw_pull_progress 0 0 0 0 0
    while IFS= read -r line; do
        st=""; id=""; cur=""; tot=""
        if [[ $line =~ $re_err ]] || [[ $line =~ $re_msg ]]; then
            err="${BASH_REMATCH[1]//\\\"/\"}"
            printf '%s\n' "$line" >> "$LOG_FILE"
            continue
        fi
        [[ $line =~ $re_status ]] && st="${BASH_REMATCH[1]}"
        [[ $line =~ $re_id ]] && id="${BASH_REMATCH[1]}"
        case "$st" in
            Downloading|Extracting) ;;
            *) printf '%s\n' "$line" >> "$LOG_FILE" ;;
        esac
        case "$st" in
            "Status: Image is up to date"*) PULL_UPTODATE=1; finished=1; continue ;;
            "Status: Downloaded newer image"*) finished=1; continue ;;
        esac
        [[ $id =~ ^[0-9a-f]{12}$ ]] || continue
        [[ $line =~ $re_cur ]] && cur="${BASH_REMATCH[1]}"
        [[ $line =~ $re_tot ]] && tot="${BASH_REMATCH[1]}"
        case "$st" in
            "Pulling fs layer"|Waiting) lstate[$id]="wait"; lcur[$id]=0 ;;
            Downloading) lstate[$id]="download"; lcur[$id]="${cur:-0}"; [ -n "$tot" ] && ltot[$id]="$tot" ;;
            "Verifying Checksum"|"Download complete") lstate[$id]="download"; lcur[$id]="${ltot[$id]:-0}" ;;
            Extracting) lstate[$id]="extract"; lcur[$id]="${ltot[$id]:-0}" ;;
            "Pull complete") lstate[$id]="done"; lcur[$id]="${ltot[$id]:-0}" ;;
            "Already exists") lstate[$id]=cached ;;
        esac
        now_ms now
        [ $((now - last_draw)) -ge 200 ] || continue
        sum_cur=0; sum_tot=0; n=0; n_done=0
        for k in "${!lstate[@]}"; do
            n=$((n + 1))
            case "${lstate[$k]}" in done|cached) n_done=$((n_done + 1)) ;; esac
            [ "${lstate[$k]}" = "cached" ] && continue
            sum_cur=$((sum_cur + ${lcur[$k]:-0}))
            sum_tot=$((sum_tot + ${ltot[$k]:-0}))
        done
        if [ $((now - last_t)) -ge 1000 ]; then
            speed=$(( (sum_cur - last_bytes) * 1000 / (now - last_t) ))
            [ "$speed" -lt 0 ] && speed=0
            last_t="$now"
            last_bytes="$sum_cur"
        fi
        draw_pull_progress "$sum_cur" "$sum_tot" "$n_done" "$n" "$speed"
        last_draw="$now"
    done < <(curl -sN --unix-socket "$DOCKER_SOCK" --connect-timeout 10 --speed-time 120 --speed-limit 1 \
                -X POST "http://localhost/images/create?fromImage=${name}&tag=${tag}" 2>>"$LOG_FILE")

    for k in "${!lstate[@]}"; do
        [ "${lstate[$k]}" = "cached" ] || PULL_BYTES=$((PULL_BYTES + ${ltot[$k]:-0}))
    done
    [ "$finished" -eq 1 ] && return 0
    PULL_ERROR="${err:-the download stopped before it finished}"
    pull_error_is_fatal "$PULL_ERROR" && return 2
    return 1
}

pull_warn() {
    local reason="${2##*: }"
    printf '%s       %s!%s %s%s: %s%s%s\n' "$CLR" "$C_WARN" "$C_RESET" "$C_WARN" "$1" "${reason:0:70}" "$C_RESET" "$3"
}

remote_digest() {
    [ -S "$DOCKER_SOCK" ] || return 0
    curl -s --max-time 20 --unix-socket "$DOCKER_SOCK" "http://localhost/distribution/$1/json" 2>/dev/null \
        | grep -oE '"digest":"sha256:[0-9a-f]+"' | head -1 | cut -d'"' -f4
}

image_has_digest() {
    docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$1" 2>/dev/null | grep -q "@$2\$"
}

pull_image() {
    local ref="$1" label start=$SECONDS attempt rc=1 mref warns=0 took size via="" line digest
    label="$(image_label "$ref")"
    if [ "$IS_TTY" = "1" ]; then
        printf '    %s⠿%s %s%-3s%s  %s\n' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$label" "$C_RESET" "$ref"
        printf '%s       %schecking for a new version…%s' "$CLR" "$C_DIM" "$C_RESET"
    fi
    digest="$(remote_digest "$ref")"
    if [ -n "$digest" ] && image_has_digest "$ref" "$digest"; then
        echo "$ref is already at $digest - skipped" >> "$LOG_FILE"
        line="${C_OK}✔${C_RESET} ${C_BOLD}$(printf '%-3s' "$label")${C_RESET}  ${ref}  ${C_DIM}already the latest${C_RESET}"
        if [ "$IS_TTY" = "1" ]; then
            printf '%s\033[1A\r\033[K    %s\n' "$CLR" "$line"
        else
            printf '    %s\n' "$line"
        fi
        PULL_LINES=1
        return 0
    fi
    for attempt in 1 2 3; do
        pull_one "$ref"
        rc=$?
        [ "$rc" -eq 0 ] && break
        pull_warn "$(registry_of "$ref")" "$PULL_ERROR" "  ${C_DIM}attempt ${attempt}/3${C_RESET}"
        warns=$((warns + 1))
        [ "$rc" -eq 2 ] && break
        [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
    done
    if [ "$rc" -eq 1 ] && is_hub_image "$ref"; then
        for mref in $(hub_mirror_refs "$ref"); do
            printf '%s       %s→%s trying mirror %s%s%s\n' "$CLR" "$C_ACCENT" "$C_RESET" "$C_KEY" "${mref%%/*}" "$C_RESET"
            warns=$((warns + 1))
            if pull_one "$mref" && docker tag "$mref" "$ref" >>"$LOG_FILE" 2>&1; then
                rc=0
                via=" · via ${mref%%/*}"
                break
            fi
            pull_warn "${mref%%/*}" "$PULL_ERROR" ""
            warns=$((warns + 1))
        done
    fi
    fmt_secs $((SECONDS - start)) took
    if [ "$rc" -eq 0 ]; then
        [ "$PULL_UPTODATE" = "1" ] || PULL_UPDATED=$((PULL_UPDATED + 1))
        if [ "$PULL_BYTES" -eq 0 ]; then size="up to date"; else fmt_mb "$PULL_BYTES" size; fi
        line="${C_OK}✔${C_RESET} ${C_BOLD}$(printf '%-3s' "$label")${C_RESET}  ${ref}  ${C_DIM}${size} · ${took}${via}${C_RESET}"
    elif image_present "$ref"; then
        rc=0
        line="${C_WARN}!${C_RESET} ${C_BOLD}$(printf '%-3s' "$label")${C_RESET}  ${ref}  ${C_WARN}registry unreachable · using the copy on this server${C_RESET}"
    else
        line="${C_BAD}✘${C_RESET} ${C_BOLD}$(printf '%-3s' "$label")${C_RESET}  ${ref}  ${C_BAD}not downloaded${C_RESET}"
    fi
    if [ "$IS_TTY" = "1" ]; then
        printf '%s\033[%dA\r\033[K    %s\n' "$CLR" $((warns + 1)) "$line"
        [ "$warns" -gt 0 ] && printf '\033[%dB' "$warns"
    else
        printf '    %s\n' "$line"
    fi
    PULL_LINES=$((warns + 1))
    return "$rc"
}

pull_images() {
    local refs=("${API_IMAGE}:${IMAGE_TAG}" "${WEB_IMAGE}:${IMAGE_TAG}" "$DB_IMAGE")
    local ref start=$SECONDS good=0 lines=0 took mark result
    PULL_UPDATED=0
    TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
    printf '\n### %s  Images\n' "$(date '+%F %T')" >> "$LOG_FILE"
    printf '  %s⠿%s %-16s %s%s%s\n' "$C_ACCENT" "$C_RESET" "Images" "$C_DIM" "$(channel_name "$IMAGE_TAG")" "$C_RESET"
    for ref in "${refs[@]}"; do
        pull_image "$ref" && good=$((good + 1))
        lines=$((lines + PULL_LINES))
    done
    fmt_secs $((SECONDS - start)) took
    mark="${C_OK}✔${C_RESET}"
    [ "$good" -eq "${#refs[@]}" ] || mark="${C_BAD}✘${C_RESET}"
    if [ "$good" -ne "${#refs[@]}" ]; then
        result="${good}/${#refs[@]} ready"
    elif [ "$PULL_UPDATED" -eq 0 ]; then
        result="no new versions"
    else
        result="${PULL_UPDATED} updated"
    fi
    if [ "$IS_TTY" = "1" ]; then
        printf '\033[%dA\r\033[K  %s %-16s %s%s · %s%s\n' $((lines + 1)) "$mark" "Images" "$C_DIM" "$result" "$took" "$C_RESET"
        printf '\033[%dB' "$lines"
    else
        printf '  %s %-16s %s · %s\n' "$mark" "Images" "$result" "$took"
    fi
    [ "$good" -eq "${#refs[@]}" ]
}

write_compose() {
    cat > "$COMPOSE_FILE" <<EOF
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
    init: true
    restart: unless-stopped
    network_mode: host
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
      - /etc/wireguard:/etc/wireguard
      - /etc/amnezia:/etc/amnezia
      - ./data/panel:/data/panel
      - /etc/machine-id:/host/etc/machine-id:ro
      - /sys/devices/virtual/dmi:/host/sys/devices/virtual/dmi:ro
    depends_on:
      db:
        condition: service_healthy

  node:
    image: ${API_IMAGE}:${IMAGE_TAG}
    init: true
    restart: unless-stopped
    network_mode: host
    privileged: true
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      TZ: \${TZ:-${DEFAULT_TZ}}
      WG_AGENT_PANEL: 127.0.0.1:9443
    volumes:
      - wg_data:/data
      - ./data/xray:/data/xray
      - ./data/openvpn:/etc/openvpn
      - /etc/wireguard:/etc/wireguard
      - /etc/amnezia:/etc/amnezia
      - /lib/modules:/lib/modules:ro
      - /var/run/docker.sock:/var/run/docker.sock
    command:
      - /bin/sh
      - -c
      - until [ -s /data/agent-local/node-id ]; do sleep 2; done; I=\$\$(cat /data/agent-local/node-id); D=/data/agent-local/\$\$I; B=\$\$D/wg-mate-agent; [ -x \$\$B ] || B=/app/wg-mate-agent; exec env WG_AGENT_SERVER_ID=\$\$I WG_AGENT_CA=\$\$D/ca.crt WG_AGENT_CERT=\$\$D/node.crt WG_AGENT_KEY=\$\$D/node.key \$\$B

  xray:
    image: ${API_IMAGE}:${IMAGE_TAG}
    init: true
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      TZ: \${TZ:-${DEFAULT_TZ}}
      XRAY_LOCATION_ASSET: /etc/xray
    volumes:
      - ./data/xray:/etc/xray
    command:
      - /bin/sh
      - -c
      - |
        X=/etc/xray
        state() { stat -c %s%Y \$\$X/config.json \$\$X/xray \$\$X/geoip.dat \$\$X/geosite.dat 2>/dev/null; }
        while :; do
          if [ ! -s \$\$X/config.json ]; then sleep 2; continue; fi
          B=/usr/local/bin/xray
          [ -x \$\$X/xray ] && B=\$\$X/xray
          S=\$\$(state)
          \$\$B run -config \$\$X/config.json & P=\$\$!
          while kill -0 \$\$P 2>/dev/null && [ "\$\$(state)" = "\$\$S" ]; do sleep 2; done
          kill \$\$P 2>/dev/null
          wait \$\$P 2>/dev/null
          sleep 1
        done

  web:
    image: ${WEB_IMAGE}:${IMAGE_TAG}
    restart: unless-stopped
    network_mode: host
    environment:
      TZ: \${TZ:-${DEFAULT_TZ}}
      NODE_ENV: production
      PORT: \${WEB_PORT:-${DEFAULT_WEB_PORT}}
      HOSTNAME: "0.0.0.0"
      WG_SETTINGS_FILE: /panel/panel-net.json
    volumes:
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
    local pg_pass auth_secret
    pg_pass="$(env_get POSTGRES_PASSWORD)"
    auth_secret="$(env_get AUTH_SECRET)"
    if [ -n "$pg_pass" ] && db_volume_exists; then
        echo "kept the existing database password - data preserved"
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
}

migrate_env() {
    local key legacy url
    [ -f "$ENV_FILE" ] || return 0
    grep -q $'\r' "$ENV_FILE" && sed -i 's/\r$//' "$ENV_FILE"
    if [ -s "$ENV_FILE" ] && [ -n "$(tail -c1 "$ENV_FILE")" ]; then
        printf '\n' >> "$ENV_FILE"
    fi
    for key in WG_MATE_VERSION ADMIN_USERNAME ADMIN_PASSWORD; do
        env_unset "$key"
    done
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
        [ "$(env_get DATABASE_URL)" = "$url" ] || env_set DATABASE_URL "$url"
    fi
    chmod 600 "$ENV_FILE"
}

write_bootstrap_admin() {
    mkdir -p "$APP_DIR/data/panel"
    printf '{"username":"%s","password":"%s"}\n' \
        "$(json_quote "$ADMIN_USERNAME")" "$(json_quote "$ADMIN_PASSWORD")" > "$APP_DIR/data/panel/bootstrap-admin.json"
    chmod 600 "$APP_DIR/data/panel/bootstrap-admin.json"
}

clear_bootstrap_admin() { rm -f "$APP_DIR/data/panel/bootstrap-admin.json"; }

persist_installer() {
    local src="${BASH_SOURCE[0]}" target="$APP_DIR/install.sh"
    mkdir -p "$APP_DIR"
    if [ -n "$src" ] && [ -f "$src" ] && [ -r "$src" ]; then
        [ "$(readlink -f "$src")" = "$(readlink -f "$target" 2>/dev/null)" ] || cp -f "$src" "$target"
        chmod 755 "$target"
        return 0
    fi
    if fetch_installer "${target}.tmp" 20; then
        mv -f "${target}.tmp" "$target"
        chmod 755 "$target"
        return 0
    fi
    rm -f "${target}.tmp"
    echo "could not save a local copy of the installer to ${target}"
    return 1
}

install_shortcut() {
    [ -d "$(dirname "$SHORTCUT")" ] || return 0
    rm -f "$SHORTCUT"
    cat > "$SHORTCUT" <<EOF
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
    chmod 755 "$SHORTCUT"
}

install_command() {
    persist_installer && install_shortcut
    return 0
}

write_config() {
    mkdir -p "$APP_DIR/data/xray" "$APP_DIR/data/openvpn" "$APP_DIR/data/panel" "$APP_DIR/backups" || return 1
    write_env || return 1
    migrate_env
    write_compose || return 1
    write_bootstrap_admin || return 1
    install_command
}

helpers_hash() { declare -f install_host_helpers | md5sum | cut -d' ' -f1; }

helpers_current() {
    have nginx && [ -f /etc/systemd/system/wg-mate-panel-ssl.path ] \
        && [ "$(cat "$APP_DIR/.host_helpers" 2>/dev/null)" = "$(helpers_hash)" ]
}

setup_host_helpers() {
    install_host_helpers || return 1
    helpers_hash > "$APP_DIR/.host_helpers"
}

skipped() {
    printf '  %s✔%s %-16s %s%s%s\n' "$C_OK" "$C_RESET" "$1" "$C_DIM" "$2" "$C_RESET"
}

refresh_config() {
    write_compose || return 1
    install_command
}

running_from_repo() {
    local dir
    [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ] || return 1
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 1
    [ -d "$dir/.git" ] || [ -d "$dir/../.git" ]
}

valid_installer() {
    [ -s "$1" ] && head -n1 "$1" | grep -q '^#!/bin/bash' && grep -q 'process_arguments' "$1" && bash -n "$1" 2>/dev/null
}

download_to() {
    local out="$1" url="$2" timeout="$3" code
    shift 3
    rm -f "$out"
    code="$(curl -sSL --connect-timeout 10 --max-time "$timeout" --retry 2 --retry-delay 1 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$@" -w '%{http_code}' -o "$out" "$url" 2>/dev/null)"
    [ "${WG_MATE_DEBUG:-0}" = "1" ] && echo "  fetch ${url%%\?*} -> HTTP ${code:-none}" >&2
    [ "$code" = "200" ] && [ -s "$out" ] && return 0
    rm -f "$out"
    wget -q --timeout="$timeout" --tries=2 --no-cache -O "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
    rm -f "$out"
    return 1
}

fetch_installer() {
    local out="$1" timeout="${2:-15}"
    if download_to "$out" "$SCRIPT_API_URL" "$timeout" -H 'Accept: application/vnd.github.raw'; then
        sed -i 's/\r$//' "$out"
        valid_installer "$out" && return 0
    fi
    if download_to "$out" "$SCRIPT_URL" "$timeout"; then
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
    local head="" url
    for url in "$SCRIPT_API_URL" "$SCRIPT_URL"; do
        head="$(curl -fsSL --connect-timeout 6 --max-time "${1:-10}" -r 0-399 \
            -H 'Cache-Control: no-cache' -H 'Accept: application/vnd.github.raw' "$url" 2>/dev/null)"
        head="$(printf '%s\n' "$head" | grep -m1 '^SCRIPT_VERSION=' | cut -d= -f2- | tr -d "'\"\r")"
        [ -n "$head" ] && { printf '%s' "$head"; return 0; }
    done
    return 1
}

link_command() {
    local master="$APP_DIR/install.sh"
    [ -f "$master" ] || return 0
    chmod +x "$master"
    if [ -f "$SHORTCUT" ] && [ ! -L "$SHORTCUT" ] && grep -qxF "SCRIPT=\"${master}\"" "$SHORTCUT" 2>/dev/null; then
        chmod +x "$SHORTCUT"
        return 0
    fi
    if [ "$(readlink -f "$SHORTCUT" 2>/dev/null)" != "$(readlink -f "$master")" ]; then
        rm -f "$SHORTCUT"
        ln -sf "$master" "$SHORTCUT"
    fi
}

self_update() {
    local master="$APP_DIR/install.sh" tmp="$RUNTIME_DIR/update.sh" self="${BASH_SOURCE[0]}"
    local remote remote_hash remote_version self_hash="" master_hash="" master_version=""
    [ "${WG_MATE_NO_SELF_UPDATE:-0}" = "1" ] && return 0
    [ "${WG_MATE_SELF_UPDATED:-0}" = "1" ] && return 0
    running_from_repo && return 0
    dns_works || ensure_dns >/dev/null 2>&1

    remote="$(remote_installer_version 8)"
    if [ -n "$remote" ] && [ "$remote" = "$SCRIPT_VERSION" ] && [ "$(installer_version_of "$master")" = "$SCRIPT_VERSION" ]; then
        link_command
        return 0
    fi
    if ! fetch_installer "$tmp" 30; then
        info "Could not check GitHub for a newer script - running v${SCRIPT_VERSION}."
        link_command
        return 0
    fi
    remote_version="$(installer_version_of "$tmp")"
    if [ -n "$remote_version" ] && ! version_ge "$remote_version" "$SCRIPT_VERSION"; then
        rm -f "$tmp"
        return 0
    fi
    remote_hash="$(md5sum "$tmp" | awk '{print $1}')"
    [ -f "$self" ] && self_hash="$(md5sum "$self" | awk '{print $1}')"
    if [ -f "$master" ]; then
        master_hash="$(md5sum "$master" | awk '{print $1}')"
        master_version="$(installer_version_of "$master")"
    fi
    if [ "$master_hash" = "$remote_hash" ] && [ "$self_hash" = "$remote_hash" ]; then
        rm -f "$tmp"
        link_command
        return 0
    fi
    if [ -n "$master_version" ] && [ -n "$remote_version" ] && [ "$master_version" != "$remote_version" ] \
        && version_ge "$master_version" "$remote_version"; then
        :
    elif [ "$master_hash" != "$remote_hash" ]; then
        mkdir -p "$APP_DIR"
        install -m 0755 "$tmp" "$master" 2>/dev/null || { cp -f "$tmp" "$master"; chmod +x "$master"; }
    fi
    rm -f "$tmp"
    link_command
    master_hash="$(md5sum "$master" 2>/dev/null | awk '{print $1}')"
    [ -n "$self_hash" ] && [ "$self_hash" = "$master_hash" ] && return 0
    master_version="$(installer_version_of "$master")"
    if [ "$master_version" != "$SCRIPT_VERSION" ]; then
        printf '  %s↑%s wg-mate script v%s → v%s\n' "$C_ACCENT" "$C_RESET" "$SCRIPT_VERSION" "$master_version"
    fi
    export WG_MATE_SELF_UPDATED=1
    exec bash "$master" "$@"
}

is_our_installer() {
    [ -f "$1" ] && [ -r "$1" ] || return 1
    grep -q '^APP_NAME="wg-mate"' "$1" && grep -q '^process_arguments' "$1"
}

remove_installer_copies() {
    local f real seen=""
    for f in "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)" "${APP_DIR}/install.sh" /root/install.sh /root/wg-mate.sh \
             /tmp/install.sh "${PWD}/install.sh" "${HOME:-/root}/install.sh"; do
        [ -n "$f" ] || continue
        real="$(readlink -f "$f" 2>/dev/null)"
        [ -n "$real" ] || continue
        case " ${seen} " in *" ${real} "*) continue ;; esac
        seen="${seen} ${real}"
        is_our_installer "$real" && rm -f "$real"
    done
    return 0
}

require_installed() {
    if ! installed; then
        fail "${APP_NAME} is not installed. Run: wg-mate install"
        return 1
    fi
    if ! docker_ready; then
        fail "Docker is not running. Try: systemctl start docker"
        return 1
    fi
    load_config
}

PANEL_STATE="none"
PANEL_UP=0
PANEL_TOTAL=0

read_panel_state() {
    PANEL_UP=0
    PANEL_TOTAL=0
    if ! installed; then PANEL_STATE="none"; return 0; fi
    if ! docker_ready; then PANEL_STATE="nodocker"; return 0; fi
    read -r PANEL_UP PANEL_TOTAL <<<"$(container_counts)"
    if [ "$PANEL_TOTAL" -gt 0 ] && [ "$PANEL_UP" -eq "$PANEL_TOTAL" ]; then
        PANEL_STATE="running"
    elif [ "$PANEL_UP" -gt 0 ]; then
        PANEL_STATE="degraded"
    else
        PANEL_STATE="stopped"
    fi
}

print_header() {
    local pv latest="" state_txt url_color="$C_ACCENT"
    read_panel_state
    printf '\n  %swg-mate%s  %sv%s%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$SCRIPT_VERSION" "$C_RESET"
    rule
    case "$PANEL_STATE" in
        none)
            detect_os
            kv "Panel" "$(dot "$C_BAD" "${C_BAD}not installed${C_RESET}")"
            kv "Server" "${OS_PRETTY:-Linux} ${C_DIM}·${C_RESET} $(server_ip)"
            return 0
            ;;
        nodocker)
            load_config
            kv "Panel" "$(dot "$C_BAD" "${C_BAD}docker is not running${C_RESET}")"
            return 0
            ;;
    esac
    load_config
    pv="$(panel_version)"
    [ -s "$LATEST_CACHE" ] && latest="$(cat "$LATEST_CACHE")"
    case "$PANEL_STATE" in
        running)  state_txt="$(dot "$C_OK" "${C_OK}running${C_RESET}")" ;;
        degraded) state_txt="$(dot "$C_WARN" "${C_WARN}degraded${C_RESET} ${C_DIM}${PANEL_UP}/${PANEL_TOTAL} up${C_RESET}")" ;;
        *)        state_txt="$(dot "$C_BAD" "${C_BAD}stopped${C_RESET}")"; url_color="$C_DIM" ;;
    esac
    [ -n "$pv" ] && state_txt="${state_txt}  ${pv}"
    [ "$IMAGE_TAG" = "latest" ] || state_txt="${state_txt} ${C_DIM}($(channel_name "$IMAGE_TAG"))${C_RESET}"
    if [ -n "$pv" ] && [ -n "$latest" ] && ! version_ge "$pv" "$latest"; then
        state_txt="${state_txt}  ${C_WARN}↑ ${latest}${C_RESET}"
    fi
    kv "Panel" "$state_txt"
    kv "URL" "${url_color}$(panel_url)${C_RESET}"
}

preflight() {
    local fatal=0 arch mem disk mem_txt
    detect_os
    arch="$(uname -m)"
    mem="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"; mem="${mem:-0}"
    disk="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"; disk="${disk:-0}"
    printf -v mem_txt '%d.%d GB' $((mem / 1024)) $((mem * 10 / 1024 % 10))
    printf '  %s✔%s %-16s %s%s · %s · %s RAM · %d GB free%s\n' "$C_OK" "$C_RESET" "System" \
        "$C_DIM" "${OS_PRETTY:-Linux}" "$arch" "$mem_txt" $((disk / 1024)) "$C_RESET"
    if ! have apt-get && ! have dnf && ! have yum; then
        fail "No supported package manager (apt, dnf or yum) was found."
        fatal=1
    fi
    if [ "$disk" -lt 3072 ]; then
        fail "Only ${disk} MB of disk is free; at least 3 GB is needed."
        fatal=1
    fi
    case "$OS_ID" in ubuntu|debian) ;; *) warn "Untested system - Ubuntu or Debian is recommended." ;; esac
    case "$arch" in x86_64|amd64|aarch64|arm64) ;; *) warn "Untested CPU architecture: ${arch}." ;; esac
    [ "$mem" -ge 900 ] || warn "Low memory (${mem} MB) - the database may struggle."
    if ! lsmod 2>/dev/null | grep -q '^wireguard' && ! modinfo wireguard >/dev/null 2>&1; then
        warn "WireGuard kernel module is missing - install linux-headers for this kernel."
    fi
    [ "$fatal" -eq 0 ] || return 1
    if ! step "Network" ensure_connectivity; then
        fail "Cannot reach GitHub or GHCR - check this server's internet and DNS."
        return 1
    fi
}

offer_foreign_cleanup() {
    local rows name image status
    rows="$(foreign_stacks)"
    [ -n "$rows" ] || return 0
    warn "Containers from another ${APP_NAME} install are on this server:"
    while IFS=$'\t' read -r name image status; do
        [ -n "$name" ] && printf '      %s%-22s%s %s%s  %s%s\n' "$C_BOLD" "$name" "$C_RESET" "$C_DIM" "$image" "$status" "$C_RESET"
    done <<<"$rows"
    if confirm "Remove them? Their volumes are kept." Y; then
        step "Remove old stack" remove_foreign_stacks || show_log_tail
    else
        warn "Kept - expect port conflicts."
    fi
}

ask_web_port() {
    local port="$1" owner alt
    while true; do
        port="$(ask "Web port" "$port")"
        if ! is_port "$port"; then
            warn "Not a valid port: ${port}" >&2
            port="$1"
            continue
        fi
        if port_taken "$port"; then
            owner="$(port_owner "$port")"
            alt="$(free_port_from $((port + 1)))"
            warn "Port ${port} is used by ${owner:-another program}." >&2
            if confirm "Use ${alt} instead?" Y; then
                port="$alt"
            else
                continue
            fi
        fi
        printf '%s' "$port"
        return 0
    done
}

ask_password() {
    local first second
    while true; do
        first="$(ask_secret "Password" "random")"
        if [ -z "$first" ]; then
            rand_hex 6
            return 0
        fi
        if [ "${#first}" -lt 6 ]; then
            warn "Use at least 6 characters, or press Enter for a random one." >&2
            continue
        fi
        second="$(ask_secret "Repeat" "")"
        if [ "$first" = "$second" ]; then
            printf '%s' "$first"
            return 0
        fi
        warn "The passwords do not match." >&2
    done
}

collect_install_input() {
    local stored interactive=0
    [ -t 0 ] && interactive=1
    load_config

    stored="$(state_get CHANNEL)"
    if [ -n "$stored" ]; then
        IMAGE_TAG="$stored"
    elif [ -n "${ARG_VERSION}${ARG_CHANNEL}" ]; then
        IMAGE_TAG="$(normalize_channel "${ARG_VERSION:-$ARG_CHANNEL}")" || {
            fail "Unknown channel or version: ${ARG_VERSION:-$ARG_CHANNEL} (use stable, beta or vX.Y.Z)"
            return 1
        }
    else
        IMAGE_TAG="latest"
    fi
    [ -n "$ARG_TZ" ] && TZ_VALUE="$ARG_TZ"

    [ "$interactive" -eq 1 ] && [ -z "$(state_get WEB_PORT)" ] && echo ""
    stored="$(state_get WEB_PORT)"
    if [ -n "$stored" ]; then
        WEB_PORT="$stored"
    elif [ -n "$ARG_WEB_PORT" ]; then
        WEB_PORT="$ARG_WEB_PORT"
    elif [ "$interactive" -eq 1 ]; then
        WEB_PORT="$(ask_web_port "$WEB_PORT")"
    elif port_taken "$WEB_PORT"; then
        WEB_PORT="$(free_port_from "$WEB_PORT")"
    fi
    is_port "$WEB_PORT" || { fail "Invalid web port: ${WEB_PORT}"; return 1; }

    stored="$(state_get API_PORT)"
    if [ -n "$stored" ]; then API_PORT="$stored"
    elif [ -n "$ARG_API_PORT" ]; then API_PORT="$ARG_API_PORT"
    elif port_taken "$API_PORT"; then API_PORT="$(free_port_from "$API_PORT")"
    fi
    stored="$(state_get DB_PORT)"
    if [ -n "$stored" ]; then DB_PORT="$stored"
    elif [ -n "$ARG_DB_PORT" ]; then DB_PORT="$ARG_DB_PORT"
    elif port_taken "$DB_PORT"; then DB_PORT="$(free_port_from "$DB_PORT")"
    fi
    is_port "$API_PORT" || { fail "Invalid API port: ${API_PORT}"; return 1; }
    is_port "$DB_PORT" || { fail "Invalid database port: ${DB_PORT}"; return 1; }

    ADMIN_USERNAME="$(state_get ADMIN_USERNAME)"
    ADMIN_PASSWORD="$(state_get ADMIN_PASSWORD)"
    if [ -z "$ADMIN_USERNAME" ] || [ -z "$ADMIN_PASSWORD" ]; then
        if [ -n "$ARG_ADMIN" ]; then
            ADMIN_USERNAME="$ARG_ADMIN"
        elif [ "$interactive" -eq 1 ]; then
            ADMIN_USERNAME="$(ask "Username" "admin")"
        fi
        ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
        if [ -n "$ARG_PASSWORD" ]; then
            ADMIN_PASSWORD="$ARG_PASSWORD"
        elif [ "$interactive" -eq 1 ]; then
            ADMIN_PASSWORD="$(ask_password)"
        else
            ADMIN_PASSWORD="$(rand_hex 6)"
        fi
    fi

    printf '\n  %s→%s %s · %s:%s · %s\n' "$C_ACCENT" "$C_RESET" "$(channel_name "$IMAGE_TAG")" \
        "$(server_ip)" "$WEB_PORT" "$ADMIN_USERNAME"
    if ! confirm "Continue?" Y; then
        info "Cancelled - nothing was changed."
        return 1
    fi
    state_set CHANNEL "$IMAGE_TAG"
    state_set WEB_PORT "$WEB_PORT"
    state_set API_PORT "$API_PORT"
    state_set DB_PORT "$DB_PORT"
    state_set ADMIN_USERNAME "$ADMIN_USERNAME"
    state_set ADMIN_PASSWORD "$ADMIN_PASSWORD"
    state_set STARTED 1
    echo ""
}

install_failed() {
    show_log_tail
    info "Fix the problem and run 'wg-mate install' again - finished steps are skipped."
}

redeploy() {
    load_config
    echo ""
    step "Start services" compose up -d || { show_log_tail; return 1; }
    step "Wait for API" wait_api_healthy 60 || warn "The API is not answering yet - check: wg-mate logs"
    echo ""
    kv "URL" "${C_ACCENT}$(panel_url)${C_RESET}"
}

cmd_install() {
    local start=$SECONDS took last
    title "Install ${APP_NAME}"
    if installed && ! has_resumable_state; then
        if containers_exist; then
            ok "${APP_NAME} is already installed in ${APP_DIR}."
            info "Use Update to upgrade it, or Uninstall to start over."
            return 0
        fi
        warn "The config in ${APP_DIR} exists but its containers are gone."
        if confirm "Redeploy with the existing config and data?" Y; then
            redeploy
            return $?
        fi
        confirm "Discard the config and install fresh?" N || return 0
        if db_volume_exists; then
            warn "The old database cannot be opened with new credentials."
            if ! confirm "Delete the old database too?" N; then
                info "Cancelled - nothing was changed."
                return 0
            fi
            docker volume rm "${COMPOSE_PROJECT}_pg_data" >/dev/null 2>&1
        fi
        rm -f "$COMPOSE_FILE" "$ENV_FILE"
    fi
    if has_resumable_state; then
        last="$(grep '^PHASE:' "$STATE_FILE" | tail -1 | cut -d: -f2)"
        warn "An unfinished install was found${last:+ (last finished step: ${last})}."
        confirm "Resume it?" Y || state_clear
    fi

    : > "$LOG_FILE"
    preflight || return 1
    offer_foreign_cleanup
    collect_install_input || return 1

    if ! phase_done DOCKER; then
        step "Docker" setup_docker || { install_failed; return 1; }
        mark_phase DOCKER
    fi
    if ! phase_done CONFIG; then
        step "Write config" write_config || { install_failed; return 1; }
        step "Host helpers" setup_host_helpers \
            || warn "The nginx helpers failed - the SSL page will not be able to issue certificates."
        mark_phase CONFIG
    fi
    if ! phase_done IMAGES; then
        pull_images || { install_failed; return 1; }
        mark_phase IMAGES
    fi
    if ! phase_done START; then
        step "Start services" compose up -d || { install_failed; return 1; }
        step "Wait for API" wait_api_healthy 60 || warn "The API is not answering yet - check: wg-mate logs api"
        clear_bootstrap_admin
        mark_phase START
    fi
    state_clear

    fmt_secs $((SECONDS - start)) took
    printf '\n  %sDone%s %sin %s%s\n\n' "$C_OK" "$C_RESET" "$C_DIM" "$took" "$C_RESET"
    kv "URL" "${C_ACCENT}$(panel_url)${C_RESET}"
    kv "Username" "${C_BOLD}${ADMIN_USERNAME}${C_RESET}"
    kv "Password" "${C_BOLD}${ADMIN_PASSWORD}${C_RESET}"
    echo ""
    info "Open the panel, log in and activate your license."
    info "Run 'wg-mate' anytime to manage the panel."
}

cmd_update() {
    local current pv latest want start took new_pv state_txt config_before config_changed=0 done_title
    require_installed || return 1
    current="$IMAGE_TAG"
    pv="$(panel_version)"
    latest="$(latest_panel_version)"
    title "Update panel"
    kv "Installed" "${pv:-unknown} ${C_DIM}($(channel_name "$current"))${C_RESET}"
    kv "Latest" "${latest:-unknown}"
    if [ -n "${ARG_VERSION}${ARG_CHANNEL}" ]; then
        IMAGE_TAG="$(normalize_channel "${ARG_VERSION:-$ARG_CHANNEL}")" || {
            fail "Unknown channel or version: ${ARG_VERSION:-$ARG_CHANNEL} (use stable, beta or vX.Y.Z)"
            return 1
        }
    elif [ -t 0 ]; then
        echo ""
        info "Channel: stable, beta, or an exact version like v0.2.4"
        while true; do
            want="$(ask "Channel" "stable")"
            IMAGE_TAG="$(normalize_channel "$want")" && break
            warn "Unknown channel: ${want}" >&2
        done
        if ! confirm "Update now?" Y; then
            info "Cancelled - nothing was changed."
            return 0
        fi
    else
        IMAGE_TAG="latest"
    fi
    : > "$LOG_FILE"
    echo ""
    start=$SECONDS
    config_before="$(cat "$COMPOSE_FILE" "$ENV_FILE" 2>/dev/null | md5sum)"
    env_set WG_MATE_CHANNEL "$IMAGE_TAG"
    migrate_env
    step "Config" refresh_config || { show_log_tail; return 1; }
    if [ "$(cat "$COMPOSE_FILE" "$ENV_FILE" 2>/dev/null | md5sum)" != "$config_before" ]; then
        config_changed=1
    fi
    if helpers_current; then
        skipped "Host helpers" "already up to date"
    else
        step "Host helpers" setup_host_helpers \
            || warn "The nginx helpers failed - the SSL page will not be able to issue certificates."
    fi
    if ! pull_images; then
        show_log_tail
        fail "Check that $(channel_name "$IMAGE_TAG") exists and that this server can reach ghcr.io and Docker Hub."
        return 1
    fi
    read_panel_state
    if [ "$config_changed" = "1" ] || [ "$PULL_UPDATED" -gt 0 ] || [ "$PANEL_STATE" != "running" ]; then
        step "Apply changes" compose up -d --no-deps db web api || { show_log_tail; return 1; }
        step "VPN services" compose up -d --no-recreate || { show_log_tail; return 1; }
        step "Wait for API" wait_api_healthy 60 || warn "The API is not answering yet - check: wg-mate logs api"
        done_title="Updated"
    else
        skipped "Services" "nothing changed - kept running"
        done_title="Already up to date"
    fi

    fmt_secs $((SECONDS - start)) took
    new_pv="$(panel_version)"
    read_panel_state
    case "$PANEL_STATE" in
        running) state_txt="$(dot "$C_OK" "${C_OK}running${C_RESET}") ${C_DIM}${PANEL_UP}/${PANEL_TOTAL} up${C_RESET}" ;;
        degraded) state_txt="$(dot "$C_WARN" "${C_WARN}degraded${C_RESET}") ${C_DIM}${PANEL_UP}/${PANEL_TOTAL} up${C_RESET}" ;;
        *) state_txt="$(dot "$C_BAD" "${C_BAD}not running${C_RESET}")" ;;
    esac
    printf '\n  %s%s%s %sin %s%s\n\n' "$C_OK" "$done_title" "$C_RESET" "$C_DIM" "$took" "$C_RESET"
    if [ -n "$pv" ] && [ "$pv" != "$new_pv" ]; then
        kv "Version" "${C_BOLD}${new_pv:-unknown}${C_RESET} ${C_DIM}(was ${pv})${C_RESET}"
    else
        kv "Version" "${C_BOLD}${new_pv:-unknown}${C_RESET}"
    fi
    kv "Channel" "$(channel_name "$IMAGE_TAG")"
    kv "Status" "$state_txt"
    kv "URL" "${C_ACCENT}$(panel_url)${C_RESET}"
}

cmd_start() {
    if ! installed; then
        fail "${APP_NAME} is not installed. Run: wg-mate install"
        return 1
    fi
    if ! docker_ready; then
        step "Start docker" enable_docker || { fail "Docker would not start - check: systemctl status docker"; return 1; }
    fi
    load_config
    step "Start services" compose up -d || { show_log_tail; return 1; }
    step "Wait for API" wait_api_healthy 60 || warn "The API is not answering yet - check: wg-mate logs api"
}

cmd_stop() {
    require_installed || return 1
    step "Stop services" compose stop || { show_log_tail; return 1; }
    info "Your data is kept in ${APP_DIR}."
}

cmd_restart() {
    local svc="${ARG_SERVICE:-panel}"
    require_installed || return 1
    case "$svc" in
        panel)
            step "Restart panel" compose up -d --force-recreate --no-deps web api || { show_log_tail; return 1; }
            step "VPN services" compose up -d --no-recreate || { show_log_tail; return 1; } ;;
        all)
            step "Restart services" compose up -d --force-recreate || { show_log_tail; return 1; } ;;
        web|api|db|node|xray)
            step "Restart ${svc}" compose up -d --force-recreate --no-deps "$svc" || { show_log_tail; return 1; } ;;
        *) fail "Unknown service: ${svc} (use all, web, api, db, node or xray)"; return 1 ;;
    esac
    step "Wait for API" wait_api_healthy 60 || warn "The API is not answering yet - check: wg-mate logs api"
}

cmd_logs() {
    local svc="$ARG_SERVICE"
    require_installed || return 1
    if [ -z "$svc" ] && [ -t 0 ]; then
        info "Which service: all, web, api, db, node or xray"
        svc="$(ask "Service" "all")"
    fi
    case "$svc" in
        ""|all) svc="" ;;
        web|api|db|node|xray) ;;
        *) fail "Unknown service: ${svc} (use web, api, db, node or xray)"; return 1 ;;
    esac
    info "Following logs - press Ctrl+C to stop."
    echo ""
    trap ':' INT
    compose logs -f --tail=200 ${svc:+"$svc"}
    trap - INT
    echo ""
}

cmd_login() {
    local rows user pass
    require_installed || return 1
    title "Login info"
    kv "URL" "${C_ACCENT}$(panel_url)${C_RESET}"
    rows="$(psql_do "SELECT username || chr(9) || COALESCE(password, '') FROM admins ORDER BY 1" 2>/dev/null)"
    if [ -z "$rows" ]; then
        warn "No admin account was found in the database."
        info "Create one from inside the panel, or reinstall to seed a new admin."
        return 0
    fi
    while IFS=$'\t' read -r user pass; do
        [ -n "$user" ] || continue
        kv "Username" "${C_BOLD}${user}${C_RESET}"
        case "$pass" in
            ""|\$2a\$*|\$2b\$*|\$2y\$*|\$argon2*|\$pbkdf2*|\$scrypt*)
                kv "Password" "${C_DIM}stored as a hash - change it from inside the panel${C_RESET}" ;;
            *)
                kv "Password" "${C_BOLD}${pass}${C_RESET}" ;;
        esac
    done <<<"$rows"
}

dump_database() {
    compose exec -T db pg_dump -U "$(db_user)" -d "$(db_name)" > "$1"
}

make_archive() {
    local archive="$1" sql="$2" args
    args=(-czf "$archive" -C "$(dirname "$sql")" "$(basename "$sql")" -C "$APP_DIR" .env docker-compose.yml data)
    [ -d /etc/wireguard ] && args+=(-C / etc/wireguard)
    tar "${args[@]}"
}

restore_database() {
    local sql="$1" user db
    user="$(db_user)"
    db="$(db_name)"
    compose stop api web
    compose up -d db
    sleep 3
    compose exec -T db psql -U "$user" -d postgres -c "DROP DATABASE IF EXISTS ${db}"
    compose exec -T db psql -U "$user" -d postgres -c "CREATE DATABASE ${db}"
    compose exec -T db psql -q -U "$user" -d "$db" < "$sql"
}

restore_wireguard() {
    local src="$1" iface="$2"
    mkdir -p /etc/wireguard && chmod 700 /etc/wireguard || return 1
    cp -a "${src}/." /etc/wireguard/ || return 1
    chmod 600 /etc/wireguard/*.conf 2>/dev/null
    wg-quick down "$iface" >/dev/null 2>&1
    systemctl reset-failed "wg-quick@${iface}" >/dev/null 2>&1
    systemctl start "wg-quick@${iface}" >/dev/null 2>&1 || wg-quick up "$iface" >/dev/null 2>&1
    return 0
}

cmd_backup() {
    local dir="$APP_DIR/backups" stamp sql archive
    require_installed || return 1
    mkdir -p "$dir"
    stamp="$(date +%Y%m%d-%H%M%S)"
    sql="${dir}/db-${stamp}.sql"
    archive="${dir}/wg-mate-${stamp}.tar.gz"
    : > "$LOG_FILE"
    if ! step "Dump database" dump_database "$sql"; then
        rm -f "$sql"
        show_log_tail
        fail "The database dump failed - is the panel running?"
        return 1
    fi
    if ! step "Create archive" make_archive "$archive" "$sql"; then
        rm -f "$sql" "$archive"
        show_log_tail
        return 1
    fi
    rm -f "$sql"
    chmod 600 "$archive"
    echo ""
    kv "Archive" "${C_ACCENT}${archive}${C_RESET}"
    kv "Size" "$(du -h "$archive" | cut -f1)"
    kv "Download" "${C_DIM}scp root@$(server_ip):${archive} .${C_RESET}"
}

cmd_restore() {
    local archive="$ARG_FILE" dir="$APP_DIR/backups" tmp sql="" pick i=1 f iface
    local files=()
    require_installed || return 1
    if [ -z "$archive" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] && files+=("$f")
        done < <(ls -1t "$dir"/*.tar.gz 2>/dev/null)
        if [ "${#files[@]}" -eq 0 ]; then
            fail "No backups found in ${dir}."
            return 1
        fi
        title "Restore a backup"
        for f in "${files[@]}"; do
            printf '  %s%d)%s %s  %s%s%s\n' "$C_KEY" "$i" "$C_RESET" "$(basename "$f")" "$C_DIM" "$(du -h "$f" | cut -f1)" "$C_RESET"
            i=$((i + 1))
        done
        printf '  %s0)%s Back\n' "$C_KEY" "$C_RESET"
        pick="$(ask "Backup" "1")"
        [ "$pick" = "0" ] && return 0
        if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#files[@]}" ]; then
            fail "Choose one of the numbers above."
            return 1
        fi
        archive="${files[$((pick - 1))]}"
    fi
    if [ ! -f "$archive" ]; then
        fail "No such backup: ${archive}"
        return 1
    fi
    warn "This replaces the current database and panel data."
    if ! confirm "Restore $(basename "$archive")?" N; then
        info "Cancelled - nothing was changed."
        return 0
    fi
    tmp="$(mktemp -d)" || return 1
    : > "$LOG_FILE"
    echo ""
    if ! step "Unpack archive" tar -xzf "$archive" -C "$tmp"; then
        show_log_tail
        rm -rf "$tmp"
        return 1
    fi
    for f in "$tmp"/db-*.sql; do
        [ -f "$f" ] && { sql="$f"; break; }
    done
    if [ -n "$sql" ]; then
        if ! step "Restore database" restore_database "$sql"; then
            show_log_tail
            rm -rf "$tmp"
            return 1
        fi
    else
        warn "This archive has no database dump - restoring files only."
    fi
    if [ -d "$tmp/data" ]; then
        step "Restore files" cp -a "${tmp}/data/." "${APP_DIR}/data/" || show_log_tail
    fi
    if [ -d "$tmp/etc/wireguard" ]; then
        iface="$(env_get WG_INTERFACE)"
        step "Restore WireGuard" restore_wireguard "$tmp/etc/wireguard" "${iface:-wg0}" || show_log_tail
    fi
    rm -rf "$tmp"
    step "Restart services" compose up -d --force-recreate || { show_log_tail; return 1; }
    step "Wait for API" wait_api_healthy 60 || warn "The API is not answering yet - check: wg-mate logs api"
}

cmd_status() {
    local svc st p label owner kernel dver mem_t mem_u
    print_header
    [ "$PANEL_STATE" = "none" ] && return 0
    if [ "$PANEL_STATE" != "nodocker" ]; then
        title "Services"
        while IFS=$'\t' read -r svc st; do
            [ -n "$svc" ] || continue
            case "$st" in
                Up*) kv "$svc" "$(dot "$C_OK" "$st")" ;;
                *)   kv "$svc" "$(dot "$C_BAD" "${C_BAD}${st}${C_RESET}")" ;;
            esac
        done < <(docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
                    --format '{{.Label "com.docker.compose.service"}}\t{{.Status}}' 2>/dev/null)
        title "Ports"
        for p in "${WEB_PORT}:web" "${API_PORT}:api" "${DB_PORT}:db"; do
            label="${p#*:}"
            p="${p%%:*}"
            if ! port_in_use "$p"; then
                kv "$p" "$(dot "$C_WARN" "${C_WARN}nothing listening${C_RESET} ${C_DIM}(${label})${C_RESET}")"
            elif our_container_on_port "$p"; then
                kv "$p" "$(dot "$C_OK" "${label}")"
            else
                owner="$(port_owner "$p")"
                kv "$p" "$(dot "$C_BAD" "${C_BAD}held by ${owner:-another program}${C_RESET}")"
            fi
        done
    fi
    detect_os
    kernel="$(uname -r)"
    dver="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    mem_t="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
    mem_u="$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')"
    title "Server"
    kv "System" "${OS_PRETTY:-Linux} ${C_DIM}· ${kernel}${C_RESET}"
    kv "Docker" "${dver:-not running}"
    kv "Address" "$(server_ip)"
    kv "Memory" "${mem_u:-?} / ${mem_t:-?} MB"
    kv "Disk" "$(df -h "$APP_DIR" 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}')"
    kv "Load" "$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null) ${C_DIM}($(nproc 2>/dev/null) cores)${C_RESET}"
    kv "Uptime" "$(uptime -p 2>/dev/null | sed 's/^up //')"
}

check() {
    if [ "$1" = "ok" ]; then
        printf '  %s✔%s %-14s %s%s%s\n' "$C_OK" "$C_RESET" "$2" "$C_DIM" "$3" "$C_RESET"
    elif [ "$1" = "warn" ]; then
        printf '  %s!%s %-14s %s%s%s\n' "$C_WARN" "$C_RESET" "$2" "$C_WARN" "$3" "$C_RESET"
    else
        printf '  %s✘%s %-14s %s%s%s\n' "$C_BAD" "$C_RESET" "$2" "$C_BAD" "$3" "$C_RESET"
    fi
}

cmd_doctor() {
    local missing="" key url_port up total rows
    title "Doctor"
    if docker_ready; then
        check ok "Docker" "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    else
        check bad "Docker" "not installed or not running"
        return 1
    fi
    if installed; then
        check ok "Install dir" "$APP_DIR"
    else
        check bad "Install dir" "missing docker-compose.yml or .env in ${APP_DIR}"
        return 1
    fi
    load_config
    if grep -q $'\r' "$ENV_FILE"; then
        check warn ".env format" "Windows line endings - run Update to fix"
    elif [ -n "$(tail -c1 "$ENV_FILE")" ]; then
        check warn ".env format" "missing trailing newline"
    else
        check ok ".env format" "clean"
    fi
    for key in DATABASE_URL AUTH_SECRET POSTGRES_PASSWORD WEB_PORT; do
        [ -n "$(env_get "$key")" ] || missing="${missing} ${key}"
    done
    if [ -n "$missing" ]; then check bad ".env keys" "missing:${missing}"; else check ok ".env keys" "complete"; fi
    url_port="$(env_get DATABASE_URL | sed -n 's|.*127.0.0.1:\([0-9]*\)/.*|\1|p')"
    if [ -n "$url_port" ] && [ "$url_port" != "$DB_PORT" ]; then
        check bad "Database URL" "points at ${url_port} but the database listens on ${DB_PORT}"
    else
        check ok "Database URL" "port ${DB_PORT}"
    fi
    read -r up total <<<"$(container_counts)"
    if [ "$up" -eq 0 ]; then
        check bad "Containers" "none running - start them from the menu"
    elif [ "$up" -ne "$total" ]; then
        check warn "Containers" "${up}/${total} up"
    else
        check ok "Containers" "${up}/${total} up"
    fi
    if api_health >/dev/null; then
        check ok "API" "healthy · $(panel_version)"
    else
        check bad "API" "no answer on 127.0.0.1:${API_PORT}"
    fi
    rows="$(foreign_stacks)"
    if [ -n "$rows" ]; then
        check warn "Other installs" "$(printf '%s' "$rows" | cut -f1 | tr '\n' ' ')"
    else
        check ok "Other installs" "none"
    fi
    check ok "Disk free" "$(df -h "$APP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
    check ok "Channel" "$(channel_name "$IMAGE_TAG")"
}

cmd_uninstall() {
    local iface f nginx_touched=0
    title "Uninstall ${APP_NAME}"
    info "This permanently deletes:"
    info "  - the web, api and database containers and their images"
    info "  - the database and all panel data"
    info "  - ${APP_DIR} (configs, certificates, openvpn, xray, backups)"
    info "  - the nginx sites and helper services created by ${APP_NAME}"
    info "  - the wg-mate command and this script"
    echo ""
    if ! confirm "Delete everything permanently?" N; then
        info "Cancelled - nothing was removed."
        return 0
    fi
    iface="$(env_get WG_INTERFACE)"
    iface="${iface:-wg0}"
    : > "$LOG_FILE"
    echo ""
    if installed && docker_ready; then
        step "Remove containers" compose down -v --remove-orphans --rmi all || show_log_tail
    fi
    if docker_ready; then
        step "Remove leftovers" remove_docker_leftovers || show_log_tail
    fi
    step "Remove helpers" purge_host_helpers || show_log_tail
    for f in /etc/nginx/sites-enabled/wg-mate /etc/nginx/sites-available/wg-mate \
             /etc/nginx/sites-enabled/wg-mate-ssl-* /etc/nginx/sites-available/wg-mate-ssl-* \
             /etc/nginx/sites-enabled/wg-mate-acme-* /etc/nginx/sites-available/wg-mate-acme-*; do
        [ -e "$f" ] || continue
        rm -f "$f"
        nginx_touched=1
    done
    if [ "$nginx_touched" = "1" ]; then
        if have nginx && nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1
            ok "nginx sites removed"
        else
            warn "nginx config is invalid after cleanup - check: nginx -t"
        fi
    fi
    if have ip && ip link show "$iface" >/dev/null 2>&1 && confirm "Also delete the WireGuard interface ${iface}?" Y; then
        wg-quick down "$iface" >/dev/null 2>&1 || ip link del "$iface" >/dev/null 2>&1
        systemctl disable --now "wg-quick@${iface}" >/dev/null 2>&1
        rm -f "/etc/wireguard/${iface}.conf"
        ok "Interface ${iface} removed"
    fi
    state_clear
    rm -rf "$APP_DIR"
    remove_installer_copies
    hash -r 2>/dev/null
    echo ""
    ok "${APP_NAME} was removed completely."
    info "Install again any time:"
    info "  bash -c \"\$(curl -fsSL ${SCRIPT_URL})\" -- install"
    echo ""
    exit 0
}

remove_docker_leftovers() {
    docker rm -f "${COMPOSE_PROJECT}-db-1" "${COMPOSE_PROJECT}-api-1" "${COMPOSE_PROJECT}-web-1"
    docker volume rm -f "${COMPOSE_PROJECT}_pg_data" "${COMPOSE_PROJECT}_wg_data"
    docker network rm "${COMPOSE_PROJECT}_default"
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '/(wg-mate-web|wg-mate-api):' | xargs -r docker rmi -f
    return 0
}

cmd_selfupdate() {
    local tmp target="$APP_DIR/install.sh" remote_version
    if running_from_repo; then
        warn "Running from a git checkout - not overwriting ${BASH_SOURCE[0]}."
        return 0
    fi
    tmp="$(mktemp)"
    : > "$LOG_FILE"
    if ! step "Download script" fetch_installer "$tmp" 20; then
        rm -f "$tmp"
        fail "Could not download a valid script - check this server's internet."
        return 1
    fi
    remote_version="$(installer_version_of "$tmp")"
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        ok "Already up to date (v${SCRIPT_VERSION})."
        return 0
    fi
    mkdir -p "$APP_DIR"
    chmod 755 "$tmp"
    mv -f "$tmp" "$target" || { rm -f "$tmp"; fail "Could not write ${target}."; return 1; }
    install_shortcut
    ok "Script updated: v${SCRIPT_VERSION} → v${remote_version:-newer}. Run wg-mate again to use it."
}

menu_backup() {
    local choice
    printf '\n  %s1)%s Create a backup\n  %s2)%s Restore a backup\n  %s0)%s Back\n' \
        "$C_KEY" "$C_RESET" "$C_KEY" "$C_RESET" "$C_KEY" "$C_RESET"
    printf '\n  %s❯%s ' "$C_ACCENT" "$C_RESET"
    read -r choice || return 0
    case "$choice" in
        1) echo ""; cmd_backup ;;
        2) cmd_restore ;;
    esac
}

show_menu() {
    local labels actions choice i
    if ! cache_fresh "$LATEST_CACHE"; then
        ( latest_panel_version >/dev/null 2>&1 & )
    fi
    while true; do
        clear 2>/dev/null
        print_header
        labels=()
        actions=()
        case "$PANEL_STATE" in
            none)
                labels+=("Install"); actions+=(cmd_install) ;;
            running|degraded)
                labels+=("Update panel" "Restart" "Stop" "Logs" "Login info" "Backup / Restore" "Uninstall")
                actions+=(cmd_update cmd_restart cmd_stop cmd_logs cmd_login menu_backup cmd_uninstall) ;;
            *)
                labels+=("Update panel" "Start" "Logs" "Login info" "Backup / Restore" "Uninstall")
                actions+=(cmd_update cmd_start cmd_logs cmd_login menu_backup cmd_uninstall) ;;
        esac
        echo ""
        for i in "${!labels[@]}"; do
            printf '  %s%d)%s %s\n' "$C_KEY" $((i + 1)) "$C_RESET" "${labels[i]}"
        done
        printf '  %s0)%s Exit\n' "$C_KEY" "$C_RESET"
        printf '\n  %s❯%s ' "$C_ACCENT" "$C_RESET"
        read -r choice || { echo ""; exit 0; }
        case "$choice" in
            0|q|exit) exit 0 ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#actions[@]}" ]; then
            echo ""
            "${actions[$((choice - 1))]}"
            printf '\n  %sPress Enter to return to the menu…%s ' "$C_DIM" "$C_RESET"
            read -r _ || exit 0
        else
            warn "Choose one of the numbers above."
            sleep 1
        fi
    done
}

print_usage() {
    cat <<USAGE

  wg-mate v${SCRIPT_VERSION} - install and manage the wg-mate panel

  Usage: wg-mate [command] [options]

  Commands:
    install       Install the panel
    update        Update the panel (keeps the current channel unless told otherwise)
    start         Start the services
    stop          Stop the services (data is kept)
    restart       Restart the panel (web, api) without dropping VPN clients
    logs          Follow the logs
    login         Show the panel URL and admin accounts
    status        Services, ports and server details
    backup        Archive the database and config
    restore       Restore a backup archive
    doctor        Find common problems
    selfupdate    Download the newest version of this script
    uninstall     Delete the panel and everything it created
    (none)        Open the menu

  Options:
    --channel <name>   stable or beta
    --version <tag>    Exact panel version, e.g. v0.2.4
    --admin <user>     Admin username for install
    --password <pass>  Admin password for install
    --web-port <port>  Panel web port (default ${DEFAULT_WEB_PORT})
    --api-port <port>  API port (default ${DEFAULT_API_PORT})
    --db-port <port>   Database port (default ${DEFAULT_DB_PORT})
    --tz <zone>        Timezone (default ${DEFAULT_TZ})
    --service <name>   logs: web, api, db, node or xray; restart: all or one service
    --file <path>      Backup archive for restore
    -y, --yes          Answer yes to every question
    -h, --help         Show this help

  Examples:
    wg-mate install --admin admin --password secret123 --web-port 3000
    wg-mate update --channel beta
    wg-mate logs --service api
    wg-mate restore --file /opt/wg-mate/backups/wg-mate-20260101-120000.tar.gz

USAGE
}

process_arguments() {
    local cmd="menu"
    case "$1" in
        install|update|status|logs|start|stop|restart|doctor|backup|restore|menu) cmd="$1"; shift ;;
        upgrade) cmd="update"; shift ;;
        ps) cmd="status"; shift ;;
        login|credentials) cmd="login"; shift ;;
        uninstall|purge|destroy|remove) cmd="uninstall"; shift ;;
        selfupdate|self-update|update-script) cmd="selfupdate"; shift ;;
        -h|--help|help) print_usage; exit 0 ;;
        -v|version) printf '%s v%s\n' "$APP_NAME" "$SCRIPT_VERSION"; exit 0 ;;
        ""|-*) ;;
        *) fail "Unknown command: $1"; print_usage; exit 1 ;;
    esac

    while [ $# -gt 0 ]; do
        case "$1" in
            --channel|--version|--admin|--password|--web-port|--api-port|--db-port|--tz|--service|--file)
                if [ $# -lt 2 ]; then
                    fail "Missing value for $1"
                    exit 1
                fi ;;
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
            *) fail "Unknown option: $1"; print_usage; exit 1 ;;
        esac
    done

    case "$cmd" in
        install)    cmd_install ;;
        update)     cmd_update ;;
        start)      cmd_start ;;
        stop)       cmd_stop ;;
        restart)    cmd_restart ;;
        logs)       cmd_logs ;;
        login)      cmd_login ;;
        status)     cmd_status ;;
        backup)     cmd_backup ;;
        restore)    cmd_restore ;;
        doctor)     cmd_doctor ;;
        selfupdate) cmd_selfupdate ;;
        uninstall)  cmd_uninstall ;;
        menu)
            if [ -t 0 ]; then show_menu; else print_usage; fi ;;
    esac
}

if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root (sudo bash install.sh)." >&2
    exit 1
fi

RUNTIME_DIR="/run/wg-mate"
mkdir -p "$RUNTIME_DIR" 2>/dev/null || { RUNTIME_DIR="/var/tmp/wg-mate"; mkdir -p "$RUNTIME_DIR"; }
chmod 700 "$RUNTIME_DIR"
LOG_FILE="$RUNTIME_DIR/wg-mate.log"
NOTE_FILE="$RUNTIME_DIR/step-note"
IP_CACHE="$RUNTIME_DIR/server_ip"
LATEST_CACHE="$RUNTIME_DIR/latest_panel"
touch "$LOG_FILE"
trap 'rc=$?; [ "$IS_TTY" = "1" ] && tput cnorm 2>/dev/null; exit $rc' EXIT

self_update "$@"
process_arguments "$@"
