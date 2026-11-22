#!/bin/bash
# ═══════════════════════════════════════════════
#  WireGuard SAFE Manager — v5.4
#  Run without arguments for the menu, or: wg-manager help
# ═══════════════════════════════════════════════

# فایل‌هایی که میسازیم (لاگ، بکاپ، کانفیگ) فقط برای root قابل خوندن باشن
umask 077

VERSION="5.4"
BASE_DIR="/root/wg"
BACKUP_DIR="$BASE_DIR/backup"
LOG_FILE="/var/log/wg-manager.log"
INSTALL_PATH="/usr/local/bin/wg-manager"
SERVICE_FILE="/etc/systemd/system/wg-manager.service"
WATCHDOG_SERVICE="/etc/systemd/system/wg-manager-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/wg-manager-watchdog.timer"
# networkd موقع ری‌استارت (مثلاً آپدیت سیستم) rule هایی که خودش نساخته رو پاک میکنه
NETWORKD_DROPIN="/etc/systemd/networkd.conf.d/10-wg-manager.conf"
NETWORKD_HOOK="/etc/systemd/system/systemd-networkd.service.d/10-wg-manager.conf"
MIGRATION_MARK="$BASE_DIR/.migrated-v4"
MIGRATION_MARK_V5="$BASE_DIR/.migrated-v5"
RUN_DIR="/run/wg-manager"              # کپی‌های موقت کانفیگ برای wg-quick
PAUSE_FLAG="$RUN_DIR/paused"           # بعد از down-all → watchdog تونل‌ها رو بالا نمیاره (تا ریبوت یا up-all)
LOCK_FILE="/run/wg-manager.lock"
LOGROTATE_FILE="/etc/logrotate.d/wg-manager"
STATE_DIR="$BASE_DIR/.state"           # چیزهای کوچیک UI: آخرین بازدید، نتیجه آخرین تست هر تونل
# نسخه ساختار فایل‌ها. migration ها فقط با 'install' اجرا میشن (migrate_1 .. migrate_N)
SCHEMA_FILE="$BASE_DIR/.schema"
SCHEMA_VERSION=3
KEEPALIVE_DEFAULT=25     # اگه کانفیگ PersistentKeepalive نداشت، فقط توی کپی runtime
RESTART_BACKOFF=1800     # watchdog هر تونل رو حداکثر هر ۳۰ دقیقه یه بار کامل ری‌استارت میکنه
BACKUP_KEEP=10           # چند نسخه بکاپ از هر تونل توی $BACKUP_DIR نگه داشته بشه

# pref = 1000+table (endpoint) و 2000+table (fwmark)
# table باید زیر 1000 باشه تا pref ها تداخل نکنن و قبل از main (32766) بیان
TABLE_MIN=1
TABLE_MAX=999
HANDSHAKE_STALE=180      # ثانیه — handshake قدیمی‌تر از این قرمز نشون داده میشه

ASSUME_YES=0             # با -y همه سوال‌ها جواب پیش‌فرض می‌گیرن
VERBOSE=0
QUIET=0                  # -q: فقط مشکل‌ها چاپ میشن (برای watchdog)
DOC_FIX=0                # doctor --fix
JSON=0                   # status --json

# ── رنگ‌ها (فقط وقتی خروجی ترمینال باشه) ──────────
# با ۲۵۶ رنگ، رنگ‌ها روی هر تمی یکسان دیده میشن (تم‌هایی مثل Termius رنگ‌های پایه
# رو همه شبیه هم نشون میدن). متن معمولی هم رنگ ثابت (FG) داره، نه رنگ پیش‌فرض تم.
# DIM دیگه \033[2m نیست — توی خیلی از ترمینال‌ها تقریباً نامرئی میشد
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ] 2>/dev/null; then
        FG='\033[38;5;252m'      # متن معمولی: خاکستری روشن
        WHITE='\033[38;5;255m'   # اسم‌ها و عنوان‌ها
        DIM='\033[38;5;245m'     # توضیحات
        GRAY='\033[38;5;239m'    # خط‌ها
        GREEN='\033[38;5;114m'; RED='\033[38;5;203m'; YELLOW='\033[38;5;221m'
        CYAN='\033[38;5;117m';  BLUE='\033[38;5;111m'
    else
        FG=''; WHITE='\033[1;37m'; DIM='\033[0;37m'; GRAY='\033[0;90m'
        GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
        CYAN='\033[0;36m'; BLUE='\033[0;34m'
    fi
    BOLD='\033[1m'
    RESET='\033[0m'
    NC="${RESET}${FG}"           # بعد از هر رنگ، برگشت به رنگ متن معمولی
else
    FG=''; WHITE=''; DIM=''; GRAY=''; GREEN=''; RED=''; YELLOW=''; CYAN=''; BLUE=''
    BOLD=''; RESET=''; NC=''
fi

# ── helper های UI ───────────────────────────────
# خط جداکننده به عرض ترمینال (حداکثر ۷۸، روی گوشی کوتاه‌تر)
HR_LINE=""
hr() {
    local w c
    if [ -z "$HR_LINE" ] || [ "${HR_COLS:-}" != "$(term_cols)" ]; then
        HR_COLS=$(term_cols); w=$((HR_COLS - 4))
        [ "$w" -gt 78 ] && w=78
        [ "$w" -lt 20 ] && w=20
        HR_LINE=""
        for ((c = 0; c < w; c++)); do HR_LINE="$HR_LINE─"; done
    fi
    echo -e "  ${GRAY}${HR_LINE}${NC}"
}

# spinner برای جاهایی که چند ثانیه منتظر می‌مونیم (فقط روی ترمینال، نه watchdog)
SPIN_PID=""
spin_start() {
    [ -t 2 ] && [ "$QUIET" != 1 ] || return 0
    spin_stop
    (
        trap 'exit 0' TERM
        while :; do
            for f in ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏; do
                printf '\r  %b%s%b %s\033[K' "$CYAN" "$f" "$NC" "$1" >&2
                sleep 0.1
            done
        done
    ) &
    SPIN_PID=$!
}
spin_stop() {
    [ -n "$SPIN_PID" ] || return 0
    kill "$SPIN_PID" 2>/dev/null
    wait "$SPIN_PID" 2>/dev/null
    SPIN_PID=""
    printf '\r\033[K' >&2
}
header() { echo ""; echo -e "  ${WHITE}${BOLD}$1${NC}"; hr; echo ""; }
step()   { echo -e "  ${CYAN}→${NC} $1"; }
ok()     { echo -e "  ${GREEN}✓${NC} $1"; }
warn()   { echo -e "  ${YELLOW}!${NC} ${YELLOW}$1${NC}"; }
err()    { echo -e "  ${RED}✗${NC} ${RED}$1${NC}" >&2; }
note()   { echo -e "    ${DIM}$1${NC}"; }

# ── لاگ (بدون رنگ داخل فایل) ────────────────────
log_file() {
    local plain
    # %s (نه %b) تا بک‌اسلش داخل پیام تفسیر نشه؛ کدهای رنگ (خام یا \033) حذف میشن
    plain=$(printf '%s' "$*" | sed 's/\x1b\[[0-9;]*m//g; s/\\033\[[0-9;]*m//g')
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $plain" >> "$LOG_FILE"
}

# write_file <mode> <path> — محتوا از stdin. اتمیک: فایل موقت کنار مقصد + mv
# (فایل نیمه‌نوشته هیچ‌وقت جای فایل اصلی رو نمیگیره)
write_file() {
    local mode="$1" path="$2" tmp
    # پوشه‌ها با 755 (نه umask 077) — مثلاً networkd.conf.d باید برای کاربر
    # systemd-network قابل ورود باشه
    ( umask 022; mkdir -p "$(dirname "$path")" ) || return 1
    tmp=$(mktemp "$path.XXXXXX") || return 1
    if cat > "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$path"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# ── فایل‌های موقت و پاکسازی موقع خروج (حتی با Ctrl+C) ──
TMP_PATHS=()
V6_DEFAULT_TOGGLED=0     # tunnel_up موقتاً default.disable_ipv6 رو 0 کرده
cleanup() {
    spin_stop 2>/dev/null
    [ -n "$RESET" ] && [ -t 1 ] && [ "${BASHPID:-$$}" = "$$" ] && printf '%b' "$RESET"
    [ "$V6_DEFAULT_TOGGLED" = 1 ] && sysctl -qw net.ipv6.conf.default.disable_ipv6=1 2>/dev/null
    [ ${#TMP_PATHS[@]} -gt 0 ] && rm -rf "${TMP_PATHS[@]}"
}
trap cleanup EXIT
trap 'echo ""; exit 130' INT TERM

# new_tmp <var> [dir] — فایل (یا پوشه) موقت داخل $RUN_DIR (توی RAM، نه /tmp روی دیسک)
# که موقع خروج حتماً پاک میشه. کلید خصوصی هیچ‌وقت توی /tmp نمیره
new_tmp() {
    local __v="$1" __f
    mkdir -p "$RUN_DIR" && chmod 700 "$RUN_DIR" || return 1
    if [ "${2:-}" = dir ]; then __f=$(mktemp -d -p "$RUN_DIR") || return 1
    else __f=$(mktemp -p "$RUN_DIR") || return 1; fi
    TMP_PATHS+=("$__f")
    printf -v "$__v" '%s' "$__f"
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ── پرسیدن با پیش‌فرض و اعتبارسنجی ──────────────
# prompt <var> <text> [default] [validator]
# ورودی خالی: پیش‌فرض (اگه باشه) وگرنه لغو. ورودی نامعتبر: دوباره میپرسه
prompt() {
    local __var="$1" __text="$2" __def="${3:-}" __val="${4:-}" __in
    if [ "$ASSUME_YES" = 1 ] && [ -n "$__def" ]; then
        if [ -n "$__val" ] && ! "$__val" "$__def"; then return 1; fi
        printf -v "$__var" '%s' "$__def"
        return 0
    fi
    if [ ! -t 0 ]; then
        err "Input needed for '$__text' but stdin is not a terminal"
        return 1
    fi
    while true; do
        if [ -n "$__def" ]; then
            read -r -p "$(printf '  %b?%b %s %b[%s]%b: ' "$BLUE" "$NC" "$__text" "$DIM" "$__def" "$NC")" __in || return 1
        else
            read -r -p "$(printf '  %b?%b %s: ' "$BLUE" "$NC" "$__text")" __in || return 1
        fi
        __in=$(trim "$__in")
        if [ -z "$__in" ]; then
            if [ -n "$__def" ]; then
                __in="$__def"
            else
                warn "Cancelled"
                return 1
            fi
        fi
        if [ -n "$__val" ] && ! "$__val" "$__in"; then
            continue
        fi
        printf -v "$__var" '%s' "$__in"
        return 0
    done
}

# confirm <text> [y|n]
confirm() {
    local def="${2:-y}" hint ans
    [ "$ASSUME_YES" = 1 ] && return 0
    if [ ! -t 0 ]; then
        err "Confirmation needed (use -y to skip)"
        return 1
    fi
    [ "$def" = y ] && hint="Y/n" || hint="y/N"
    read -r -p "$(printf '  %b?%b %s [%s]: ' "$BLUE" "$NC" "$1" "$hint")" ans || return 1
    ans="${ans:-$def}"
    [[ "$ans" =~ ^[Yy] ]]
}

# ── پیش‌نیازها ──────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root"
        exit 1
    fi
}

check_deps() {
    local missing=() c
    for c in wg wg-quick ip iptables awk sed; do
        command -v "$c" &>/dev/null || missing+=("$c")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required tools: ${missing[*]}"
        note "Install with: apt install -y wireguard-tools iproute2 iptables"
        exit 1
    fi
}

# فقط چک میکنه کرنل IPv6 داره. disable_ipv6 ملاک نیست: روی سرورهایی مثل Hetzner
# all/default=1 هست ولی IPv6 روی کارت شبکه کار میکنه. IPv6 تونل موقع بالا اومدن
# فقط برای همون اینترفیس روشن میشه (tunnel_up)
has_ipv6() { [ -f /proc/net/if_inet6 ]; }

# ── قفل: دو نسخه همزمان (مثلاً watchdog و دستی) به هم نخورن ──
# lock [try] — با try اگه قفل گرفته بود فوراً برمیگرده
lock() {
    command -v flock &>/dev/null || return 0
    exec 9>"$LOCK_FILE" || return 0
    flock -n 9 && return 0
    [ "${1:-}" = try ] && return 1
    note "Waiting for another wg-manager to finish..."
    flock -w 60 9 || { err "Another wg-manager is still running"; return 1; }
}
unlock() { exec 9>&- 2>/dev/null; }
run_locked() { local rc; lock || return 1; "$@"; rc=$?; unlock; return $rc; }

# ── اعتبارسنجی ورودی‌ها ──────────────────────────
# اولین حرف نباید - یا . باشه (وگرنه ip/wg ممکنه به عنوان option بخونن)
NAME_RE='^[a-zA-Z0-9_][a-zA-Z0-9_=+.-]{0,14}$'
v_name() {
    if [[ ! "$1" =~ $NAME_RE ]]; then
        err "Invalid name '$1' (letters, digits, _ = + . - only, max 15 chars, must not start with - or .)"
        return 1
    fi
}

v_new_name() {
    v_name "$1" || return 1
    if [ -f "$(cfg_path "$1")" ]; then
        err "A tunnel named '$1' already exists"
        return 1
    fi
    if ip link show "$1" &>/dev/null; then
        err "A network interface named '$1' already exists on this server"
        return 1
    fi
}

# TABLE_SELF = اسم تونلی که داره ویرایش میشه (تا table خودش تکراری حساب نشه)
v_table() {
    local t="$1" owner
    if [[ ! "$t" =~ ^[0-9]+$ ]] || [ "$t" -lt $TABLE_MIN ] || [ "$t" -gt $TABLE_MAX ]; then
        err "Table ID must be a number between $TABLE_MIN and $TABLE_MAX"
        return 1
    fi
    if [ "$t" -ge 253 ] && [ "$t" -le 255 ]; then
        err "Table $t is reserved by the system (253=default, 254=main, 255=local)"
        return 1
    fi
    owner=$(table_owner "$t")
    if [ -n "$owner" ] && [ "$owner" != "${TABLE_SELF:-}" ]; then
        err "Table $t is already used by tunnel '$owner'"
        return 1
    fi
}

v_key() {
    if [[ ! "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        err "Invalid WireGuard key (expected 44 base64 characters ending in '=')"
        return 1
    fi
}

v_endpoint() {
    if [[ "$1" =~ ^(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+):([0-9]{1,5})$ ]] && [ "${BASH_REMATCH[2]}" -le 65535 ]; then
        return 0
    fi
    err "Invalid endpoint (expected IP:PORT, e.g. 1.2.3.4:51820)"
    return 1
}

v_address() {
    local a
    for a in ${1//,/ }; do
        if [[ ! "$a" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]]; then
            err "Invalid address '$a' (expected e.g. 10.0.0.2/32)"
            return 1
        fi
    done
}

v_menu_1_4() {
    [[ "$1" =~ ^[1-4]$ ]] || { err "Choose 1, 2, 3 or 4"; return 1; }
}

# ── فایل‌های کانفیگ ──────────────────────────────
cfg_path() { echo "$BASE_DIR/$1.conf"; }

list_tunnels() {
    local c n
    for c in "$BASE_DIR"/*.conf; do
        [ -f "$c" ] || continue
        n=$(basename "$c" .conf)
        [[ "$n" =~ $NAME_RE ]] && echo "$n"
    done
}

# متادیتای اسکریپت به شکل کامنت: # X-<Key> = <value>
meta_get() {
    [ -f "$1" ] || return 0
    sed -n "s/^#[[:space:]]*X-$2[[:space:]]*=[[:space:]]*//p" "$1" | head -1 | tr -d '[:space:]'
}

meta_set() {
    local cfg="$1" key="$2" val="$3"
    # کاراکترهای خاص sed (\ & |) escape بشن
    val=${val//\\/\\\\}; val=${val//&/\\&}; val=${val//|/\\|}
    if grep -q "^#[[:space:]]*X-$key[[:space:]]*=" "$cfg"; then
        sed -i "s|^#[[:space:]]*X-$key[[:space:]]*=.*|# X-$key = $val|" "$cfg"
    else
        sed -i "1i # X-$key = $val" "$cfg"
    fi
}

# همه مقدارهای یک کلید (بدون حساسیت به حروف بزرگ/کوچک)
conf_get_all() {
    awk -v k="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" '
        /^[ \t]*#/ { next }
        {
            i = index($0, "="); if (!i) next
            key = substr($0, 1, i - 1); gsub(/[ \t]/, "", key)
            if (tolower(key) == k) {
                v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v
            }
        }' "$1"
}
conf_get() { conf_get_all "$@" | head -1; }

table_owner() {
    local n
    for n in $(list_tunnels); do
        if [ "$(meta_get "$(cfg_path "$n")" Table-ID)" = "$1" ]; then
            echo "$n"
            return
        fi
    done
}

# اولین table آزاد از 100 به بعد. [exclude] = لیست " a b " که نباید انتخاب بشن (restore)
free_table() {
    local t ex="${1:- }"
    for ((t = 100; t <= TABLE_MAX; t++)); do
        [ "$t" -ge 253 ] && [ "$t" -le 255 ] && continue
        [[ "$ex" == *" $t "* ]] && continue
        [ -n "$(table_owner "$t")" ] && continue
        [ -n "$(ip route show table "$t" 2>/dev/null)" ] && continue
        echo "$t"
        return
    done
}

is_enabled() { [ "$(meta_get "$(cfg_path "$1")" Enabled)" != "no" ]; }
is_up()      { wg show "$1" &>/dev/null; }

# ── تمیز کردن کانفیگ ─────────────────────────────
# هر چیزی که میتونه routing یا DNS کل سرور رو عوض کنه حذف میشه.
# پیام‌ها توی SANITIZE_NOTES برمیگردن
sanitize_config() {
    local cfg="$1"
    SANITIZE_NOTES=()

    sed -i 's/\r$//; s/^[[:space:]]\+//' "$cfg"

    if grep -qiE '^DNS[[:space:]]*=' "$cfg"; then
        sed -i -E '/^[Dd][Nn][Ss][[:space:]]*=/d' "$cfg"
        SANITIZE_NOTES+=("Removed 'DNS =' (it would change the whole server's DNS)")
    fi
    if grep -qiE '^(Pre|Post)(Up|Down)[[:space:]]*=' "$cfg"; then
        sed -i -E '/^([Pp][Rr][Ee]|[Pp][Oo][Ss][Tt])([Uu][Pp]|[Dd][Oo][Ww][Nn])[[:space:]]*=/d' "$cfg"
        SANITIZE_NOTES+=("Removed PreUp/PostUp/PreDown/PostDown (kill-switch rules can lock out SSH)")
    fi
    if grep -qiE '^SaveConfig[[:space:]]*=' "$cfg"; then
        sed -i -E '/^[Ss][Aa][Vv][Ee][Cc][Oo][Nn][Ff][Ii][Gg][[:space:]]*=/d' "$cfg"
        SANITIZE_NOTES+=("Removed 'SaveConfig'")
    fi
    # FwMark روی UDP خود wg میشینه؛ اگه با mark یکی از تونل‌ها یکی باشه loop میشه
    if grep -qiE '^FwMark[[:space:]]*=' "$cfg"; then
        sed -i -E '/^[Ff][Ww][Mm][Aa][Rr][Kk][[:space:]]*=/d' "$cfg"
        SANITIZE_NOTES+=("Removed 'FwMark' (can loop the tunnel's own traffic)")
    fi
    if [ "$(grep -ciE '^Table[[:space:]]*=' "$cfg")" != "1" ] || \
       ! grep -qiE '^Table[[:space:]]*=[[:space:]]*off[[:space:]]*$' "$cfg"; then
        sed -i -E '/^[Tt][Aa][Bb][Ll][Ee][[:space:]]*=/d' "$cfg"
        sed -i -E '/^\[[Ii]nterface\]/a Table = off' "$cfg"
        SANITIZE_NOTES+=("Set 'Table = off' (keeps SSH and server traffic out of the tunnel)")
    fi
    # آدرس IPv6 دیگه از کانفیگ ذخیره‌شده پاک نمیشه — runtime_config رو ببین
    chmod 600 "$cfg"
}

# کپی موقت کانفیگ برای wg-quick → RT_CFG. فایل اصلی هیچ‌وقت موقع بالا آوردن عوض نمیشه
# (اگه برق وسط نوشتن بره، کانفیگ اصلی سالم میمونه). sanitize، keepalive و حذف IPv6
# (وقتی کرنل IPv6 نداره) فقط روی این کپی انجام میشن
runtime_config() {
    local name="$1" addrs kept a n
    RT_CFG="$RUN_DIR/$name.conf"
    mkdir -p "$RUN_DIR" && chmod 700 "$RUN_DIR" || return 1
    install -m 600 "$(cfg_path "$name")" "$RT_CFG" || return 1

    sanitize_config "$RT_CFG"
    for n in "${SANITIZE_NOTES[@]}"; do note "$name: $n (runtime only)"; done

    # keepalive باعث میشه handshake همیشه تازه بمونه → سلامت تونل قابل اعتماد چک میشه
    if ! grep -qiE '^PersistentKeepalive[[:space:]]*=' "$RT_CFG"; then
        sed -i -E "/^\[[Pp][Ee][Ee][Rr]\]/a PersistentKeepalive = $KEEPALIVE_DEFAULT" "$RT_CFG"
    fi

    has_ipv6 && return 0
    addrs=$(conf_get_all "$RT_CFG" Address | tr ',' '\n')
    echo "$addrs" | grep -q ':' || return 0
    kept=""
    while read -r a; do
        a=$(trim "$a")
        { [ -z "$a" ] || [[ "$a" == *:* ]]; } && continue
        kept="${kept:+$kept, }$a"
    done <<< "$addrs"
    sed -i -E '/^[Aa][Dd][Dd][Rr][Ee][Ss][Ss][[:space:]]*=/d' "$RT_CFG"
    [ -n "$kept" ] && sed -i -E "/^\[[Ii]nterface\]/a Address = $kept" "$RT_CFG"
    note "This server has no IPv6 — starting without the IPv6 address (saved config unchanged)"
}

# چک کردن اینکه کانفیگ کامله. چیزهای ناقص رو چاپ میکنه
check_config() {
    local cfg="$1" missing=() pk
    grep -qiE '^\[interface\]' "$cfg" || missing+=("[Interface] section")
    grep -qiE '^\[peer\]' "$cfg"      || missing+=("[Peer] section")
    pk=$(conf_get "$cfg" PrivateKey)
    [ -n "$pk" ]                                  || missing+=("PrivateKey")
    [ -n "$(conf_get "$cfg" Address)" ]           || missing+=("Address")
    [ -n "$(conf_get "$cfg" PublicKey)" ]         || missing+=("PublicKey")
    [ -n "$(conf_get "$cfg" Endpoint)" ]          || missing+=("Endpoint")
    if [ ${#missing[@]} -gt 0 ]; then
        err "Config is incomplete — missing: ${missing[*]}"
        return 1
    fi
    v_key "$pk" || return 1
}

# ── routing ─────────────────────────────────────
pref_endpoint() { echo $((1000 + $1)); }
pref_fwmark()   { echo $((2000 + $1)); }

# پاک کردن همه قانون‌های یک تونل (فقط همین تونل)
clear_routing() {
    local iface="$1" t="$2" pe pf fam
    pe=$(pref_endpoint "$t")
    pf=$(pref_fwmark "$t")
    for fam in -4 -6; do
        [ "$fam" = -6 ] && ! has_ipv6 && continue
        while ip $fam rule del pref "$pe" 2>/dev/null; do :; done
        while ip $fam rule del pref "$pf" 2>/dev/null; do :; done
        # باقی‌مانده نسخه‌های قدیمی که pref ثابت داشتن
        while ip $fam rule del fwmark "$t" table "$t" 2>/dev/null; do :; done
        ip $fam route flush table "$t" 2>/dev/null
    done
    while iptables -t nat -D POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null; do :; done
    if command -v ip6tables &>/dev/null; then
        while ip6tables -t nat -D POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null; do :; done
    fi
    ct_rules_del "$t"
    # leak counter عمداً پاک نمیشه: وقتی تونل پایینه هم باید بشمره (فقط delete پاکش میکنه)
}

# iptables و (اگه IPv6 هست) ip6tables — برای حلقه روی هر دو
ipt_cmds() {
    echo iptables
    has_ipv6 && command -v ip6tables &>/dev/null && echo ip6tables
}

# ── conntrack: mark تونل روی خود اتصال (ctmark) ──
# همه تونل‌ها یه آدرس دارن، پس اتصال‌ها رو فقط با mark میشه از هم جدا کرد.
# conntrack -m با ctmark کار میکنه (نه mark پکت)، پس mark پکت‌های Xray رو روی
# اتصال کپی میکنیم. اتصال‌هایی که موقع leak با IP سرور ساخته شدن هم تگ میخورن
ct_rules_add() {
    local t="$1" ipt
    for ipt in $(ipt_cmds); do
        $ipt -t mangle -C OUTPUT -m mark --mark "$t" -m comment --comment "wgm-ct-$t" -j CONNMARK --set-mark "$t" 2>/dev/null || \
            $ipt -t mangle -A OUTPUT -m mark --mark "$t" -m comment --comment "wgm-ct-$t" -j CONNMARK --set-mark "$t" 2>/dev/null
    done
}
ct_rules_del() {
    local t="$1" ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" &>/dev/null || continue
        while $ipt -t mangle -D OUTPUT -m mark --mark "$t" -m comment --comment "wgm-ct-$t" -j CONNMARK --set-mark "$t" 2>/dev/null; do :; done
    done
}

# فقط اتصال‌های همین تونل پاک میشن (نه کل سرور — backhaul و بقیه دست نمیخورن)
flush_conntrack_mark() {
    local t="$1"
    command -v conntrack &>/dev/null || return 0
    conntrack -D -m "$t" &>/dev/null                 # exit 1 = چیزی پیدا نشد، مشکلی نیست
    has_ipv6 && conntrack -D -f ipv6 -m "$t" &>/dev/null
    return 0
}

# ── شمارنده leak: هیچ چیزی رو بلاک نمیکنه، فقط میشمره ──
# پکتی که mark تونل رو داره ولی از اینترفیس خودش بیرون نمیره = از IP سرور رفته
LEAK_CHAIN="WGM-LEAK"
leak_rules_add() {
    local name="$1" t="$2" ipt
    for ipt in $(ipt_cmds); do
        $ipt -t mangle -N "$LEAK_CHAIN" 2>/dev/null
        $ipt -t mangle -C POSTROUTING -j "$LEAK_CHAIN" 2>/dev/null || \
            $ipt -t mangle -A POSTROUTING -j "$LEAK_CHAIN" 2>/dev/null
        # ترافیک به خود سرور (lo) leak نیست
        $ipt -t mangle -C "$LEAK_CHAIN" -o lo -j RETURN 2>/dev/null || \
            $ipt -t mangle -I "$LEAK_CHAIN" 1 -o lo -j RETURN 2>/dev/null
        $ipt -t mangle -C "$LEAK_CHAIN" -m mark --mark "$t" ! -o "$name" -m comment --comment "wgm-leak-$t" -j RETURN 2>/dev/null || \
            $ipt -t mangle -A "$LEAK_CHAIN" -m mark --mark "$t" ! -o "$name" -m comment --comment "wgm-leak-$t" -j RETURN 2>/dev/null
    done
}
leak_rules_del() {
    local name="$1" t="$2" ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" &>/dev/null || continue
        while $ipt -t mangle -D "$LEAK_CHAIN" -m mark --mark "$t" ! -o "$name" -m comment --comment "wgm-leak-$t" -j RETURN 2>/dev/null; do :; done
    done
    rm -f "$RUN_DIR/leak-$t"
}
# leak_read <mark> → LEAK_PKTS LEAK_BYTES (جمع IPv4+IPv6 از زمان بوت / ساخت rule)
leak_read() {
    local t="$1" ipt p b
    LEAK_PKTS=0; LEAK_BYTES=0
    for ipt in $(ipt_cmds); do
        read -r p b < <($ipt -t mangle -L "$LEAK_CHAIN" -vnx 2>/dev/null | \
            awk -v c="/* wgm-leak-$t */" 'index($0, c) { p += $1; b += $2 } END { print p + 0, b + 0 }')
        LEAK_PKTS=$((LEAK_PKTS + ${p:-0})); LEAK_BYTES=$((LEAK_BYTES + ${b:-0}))
    done
}
# leak_since_check <mark> [save] → LEAK_NEW_PKTS LEAK_NEW_BYTES از آخرین چک watchdog
leak_since_check() {
    local t="$1" f="$RUN_DIR/leak-$t" lp=0 lb=0
    leak_read "$t"
    read -r lp lb 2>/dev/null < "$f"
    [[ "$lp" =~ ^[0-9]+$ ]] && [[ "$lb" =~ ^[0-9]+$ ]] || { lp=0; lb=0; }
    [ "$LEAK_PKTS" -lt "$lp" ] && { lp=0; lb=0; }    # rule دوباره ساخته شده → شمارنده از صفر
    LEAK_NEW_PKTS=$((LEAK_PKTS - lp)); LEAK_NEW_BYTES=$((LEAK_BYTES - lb))
    if [ "${2:-}" = save ]; then
        mkdir -p "$RUN_DIR" && echo "$LEAK_PKTS $LEAK_BYTES" > "$f"
    fi
}

# IP واقعی endpoint از خود wg (اگه hostname بوده، resolve شده)
endpoint_ip() {
    local ep
    ep=$(wg show "$1" endpoints 2>/dev/null | awk 'NR==1 {print $2}')
    case "$ep" in
        ""|"(none)") ;;
        \[*)         ep="${ep#[}"; echo "${ep%%]*}" ;;
        *)           echo "${ep%:*}" ;;
    esac
}

# آیا خروجی ip route (از stdin) به اینترفیس $1 میره
has_dev() {
    awk -v d="$1" '{ for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) == d) f = 1 } END { exit !f }'
}

apply_routing() {
    local iface="$1" t="$2" pe pf ep_ip fam
    pe=$(pref_endpoint "$t")
    pf=$(pref_fwmark "$t")

    clear_routing "$iface" "$t"

    ep_ip=$(endpoint_ip "$iface")

    # ۱) endpoint exclusion — ترافیک خود تونل از main بره، وگرنه loop
    if [ -n "$ep_ip" ]; then
        [[ "$ep_ip" == *:* ]] && fam=-6 || fam=-4
        ip $fam rule add to "$ep_ip" lookup main pref "$pe" || return 1
        note "Loop prevention: $ep_ip → main (pref $pe)"
    else
        warn "Endpoint IP unknown — loop prevention skipped"
    fi

    # ۲) fwmark → table و default route
    ip -4 rule add fwmark "$t" table "$t" pref "$pf" || return 1
    ip -4 route replace default dev "$iface" scope global table "$t" || return 1
    iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE || return 1

    # جواب‌ها از اینترفیس تونل میان؛ rp_filter سخت‌گیر دورشون میریزه
    [ -w "/proc/sys/net/ipv4/conf/$iface/rp_filter" ] && echo 2 > "/proc/sys/net/ipv4/conf/$iface/rp_filter"
    # ip_forward لازم نیست: ترافیک Xray روی خود سرور ساخته میشه (forward نمیشه).
    # مقدار فعلیش دست نمیخوره چون شاید یه سرویس دیگه لازمش داشته باشه

    # ۳) IPv6: اگه تونل IPv6 داره از تونل، وگرنه بلاک (تا از IP سرور leak نشه)
    if has_ipv6; then
        ip -6 rule add fwmark "$t" table "$t" pref "$pf" 2>/dev/null || \
            warn "IPv6 rule for mark $t could not be added"
        if ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q inet6 && \
           ip -6 route replace default dev "$iface" table "$t" 2>/dev/null; then
            if command -v ip6tables &>/dev/null; then
                ip6tables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || \
                    ip6tables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
            fi
            note "IPv6: routed through tunnel"
        else
            # آدرس IPv6 نداره (یا route نشد) → بلاک، نه leak از IPv6 سرور
            ip -6 route replace unreachable default table "$t" 2>/dev/null
            note "IPv6: blocked for mark $t (tunnel has no IPv6)"
        fi
    fi

    ct_rules_add "$t"
    leak_rules_add "$iface" "$t"
    log_file "Routing: fwmark $t → $iface (pref $pf, endpoint ${ep_ip:-none})"
}

# چک routing یک تونل up. مشکل‌ها توی ROUTE_ISSUES
check_routing() {
    local name="$1" t="$2" pe pf ep_ip fam
    ROUTE_ISSUES=()
    ROUTE_NEED_RESTART=0     # 1 = فقط با ری‌استارت تونل درست میشه
    pe=$(pref_endpoint "$t")
    pf=$(pref_fwmark "$t")

    ip -4 rule show 2>/dev/null | grep -qE "^$pf:.*fwmark" \
        || ROUTE_ISSUES+=("rule 'fwmark $t → table $t' is missing — Xray exits via the server IP")
    ip -4 route show table "$t" default 2>/dev/null | has_dev "$name" \
        || ROUTE_ISSUES+=("default route in table $t is missing — Xray exits via the server IP")
    ep_ip=$(endpoint_ip "$name")
    if [ -n "$ep_ip" ]; then
        [[ "$ep_ip" == *:* ]] && fam=-6 || fam=-4
        ip $fam rule show 2>/dev/null | grep -E "^$pe:" | grep -qF " to $ep_ip " \
            || ROUTE_ISSUES+=("loop-prevention rule for endpoint $ep_ip is missing or outdated")
    fi
    iptables -t nat -C POSTROUTING -o "$name" -j MASQUERADE 2>/dev/null \
        || ROUTE_ISSUES+=("NAT (MASQUERADE) rule is missing")
    iptables -t mangle -C OUTPUT -m mark --mark "$t" -m comment --comment "wgm-ct-$t" -j CONNMARK --set-mark "$t" 2>/dev/null \
        || ROUTE_ISSUES+=("conntrack tagging rule for mark $t is missing")
    iptables -t mangle -C "$LEAK_CHAIN" -m mark --mark "$t" ! -o "$name" -m comment --comment "wgm-leak-$t" -j RETURN 2>/dev/null \
        || ROUTE_ISSUES+=("leak counter for mark $t is missing")
    if has_ipv6; then
        ip -6 rule show 2>/dev/null | grep -qE "^$pf:.*fwmark" \
            || ROUTE_ISSUES+=("IPv6 rule for mark $t is missing — IPv6 exits via the server IP")
        if conf_get_all "$(cfg_path "$name")" Address | grep -q ':'; then
            # مثلاً اگه چیزی دوباره 'sysctl --system' بزنه، all.disable_ipv6=1 آدرس تونل رو پاک میکنه
            if ! ip -6 addr show dev "$name" scope global 2>/dev/null | grep -q inet6; then
                ROUTE_ISSUES+=("IPv6 address is missing on $name — IPv6 through the tunnel does not work")
                ROUTE_NEED_RESTART=1
            elif ! ip -6 route show table "$t" default 2>/dev/null | has_dev "$name"; then
                ROUTE_ISSUES+=("IPv6 default route in table $t is missing")
            elif command -v ip6tables &>/dev/null && \
                 ! ip6tables -t nat -C POSTROUTING -o "$name" -j MASQUERADE 2>/dev/null; then
                ROUTE_ISSUES+=("IPv6 NAT (MASQUERADE) rule is missing")
            fi
        elif [ -z "$(ip -6 route show table "$t" 2>/dev/null)" ]; then
            ROUTE_ISSUES+=("IPv6 route in table $t is missing — IPv6 exits via the server IP")
        fi
    fi
    [ ${#ROUTE_ISSUES[@]} -eq 0 ]
}

# همه چی سر جاشه ولی یه rule دیگه (از یه برنامه دیگه) با اولویت بالاتر ترافیک رو میدزده؟
# جدا از check_routing چون با ری‌استارت تونل درست نمیشه
marked_route_ok() {
    local out
    ip -4 route get 1.1.1.1 mark "$2" 2>/dev/null | has_dev "$1" || return 1
    has_ipv6 || return 0
    out=$(ip -6 route get 2606:4700:4700::1111 mark "$2" 2>/dev/null)
    if conf_get_all "$(cfg_path "$1")" Address | grep -q ':'; then
        echo "$out" | has_dev "$1"
    else
        # تونل IPv6 نداره → باید بلاک باشه (unreachable)، نه اینکه از اینترفیس دیگه‌ای بره
        [ -z "$out" ] || [[ "$out" == unreachable* ]] || echo "$out" | has_dev lo
    fi
}

# برای جدول وضعیت: چیزهای اصلی که نبودنشون یعنی leak (IPv4 و IPv6)
routing_ok_quick() {
    local pf
    pf=$(pref_fwmark "$2")
    ip -4 rule show 2>/dev/null | grep -qE "^$pf:.*fwmark" && \
        ip -4 route show table "$2" default 2>/dev/null | has_dev "$1" || return 1
    if has_ipv6; then
        ip -6 rule show 2>/dev/null | grep -qE "^$pf:.*fwmark" && \
            [ -n "$(ip -6 route show table "$2" 2>/dev/null)" ] || return 1
    fi
    return 0
}

reapply_routing_all() {
    local n t
    for n in $(list_tunnels); do
        is_up "$n" || continue
        t=$(meta_get "$(cfg_path "$n")" Table-ID)
        [[ "$t" =~ ^[0-9]+$ ]] && apply_routing "$n" "$t" >/dev/null 2>&1
    done
}

# ── systemd-networkd ────────────────────────────
# networkd به‌طور پیش‌فرض (ManageForeign*=yes) هر بار که ری‌استارت میشه rule و
# route هایی که خودش نساخته رو پاک میکنه. unattended-upgrades هر چند هفته یه بار
# این کار رو میکنه → fwmark rule ها پاک میشن و Xray با IP خود سرور بیرون میره

# مقدار نهایی یک تنظیم networkd.conf (با در نظر گرفتن drop-in ها) → yes|no
networkd_setting() {
    local v
    v=$(systemd-analyze cat-config systemd/networkd.conf 2>/dev/null \
        | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | tail -1 \
        | tr -d '[:space:]' | tr 'A-Z' 'a-z')
    case "$v" in no|false|0|off) echo no ;; *) echo yes ;; esac
}

# none = networkd استفاده نمیشه | ok | unsafe = rule ها رو پاک میکنه
# pending = تنظیم نوشته شده ولی networkd هنوز ری‌استارت نشده
networkd_status() {
    local started changed ver
    if ! systemctl is-active --quiet systemd-networkd 2>/dev/null; then echo none; return; fi
    # ManageForeignRoutingPolicyRules از systemd 249 هست؛ قبلش فقط watchdog جبران میکنه
    ver=$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}')
    if [[ "$ver" =~ ^[0-9]+$ ]] && [ "$ver" -lt 249 ]; then echo old; return; fi
    if [ "$(networkd_setting ManageForeignRoutingPolicyRules)" != no ] || \
       [ "$(networkd_setting ManageForeignRoutes)" != no ]; then
        echo unsafe; return
    fi
    started=$(date -d "$(systemctl show systemd-networkd -p ExecMainStartTimestamp --value 2>/dev/null)" +%s 2>/dev/null)
    changed=$(stat -c %Y "$NETWORKD_DROPIN" 2>/dev/null)
    if [ -n "$started" ] && [ -n "$changed" ] && [ "$changed" -gt "$started" ]; then
        echo pending
    else
        echo ok
    fi
}

networkd_banner() {
    case "$(networkd_status)" in
        unsafe|pending)
            echo -e "  ${RED}! systemd-networkd can delete tunnel rules → Xray would exit via the server IP${NC}"
            echo -e "    ${DIM}Fix: wg-manager install   •   details: wg-manager doctor${NC}"
            ;;
    esac
}

# حتماً 644: networkd با کاربر systemd-network اجرا میشه و فایل 600 رو نمیتونه بخونه
# (و بی‌صدا تنظیم پیش‌فرض رو استفاده میکنه)
write_networkd_dropin() {
    write_file 644 "$NETWORKD_DROPIN" <<EOF
# Added by wg-manager: stop systemd-networkd from deleting the policy rules
# and routes that send Xray traffic into WireGuard (it does this on every
# restart, e.g. during system updates).
[Network]
ManageForeignRoutingPolicyRules=no
ManageForeignRoutes=no
EOF
}

# تنظیم networkd رو درست میکنه (با پرسیدن برای ری‌استارت). 0 = امن
ensure_networkd() {
    local st
    st=$(networkd_status)
    case "$st" in
        none) return 0 ;;
        ok)   ok "systemd-networkd: tunnel rules are protected"; return 0 ;;
        old)  note "systemd is older than v249 — the watchdog re-adds tunnel rules after each networkd restart"
              return 0 ;;
    esac
    echo ""
    warn "systemd-networkd deletes routing rules it did not create every time it restarts"
    note "System updates restart it every few weeks — then Xray exits via the server IP until a reboot."
    if [ "$st" = unsafe ]; then
        write_networkd_dropin || { err "Could not write $NETWORKD_DROPIN"; return 1; }
        ok "Wrote $NETWORKD_DROPIN"
    fi
    note "networkd has to restart once to load it (~1s; tunnel routing is re-applied right after)"
    if ! confirm "Restart systemd-networkd now?" y; then
        warn "Not active until networkd restarts or the server reboots (the watchdog covers it meanwhile)"
        return 1
    fi
    if ! systemctl restart systemd-networkd; then
        err "systemd-networkd failed to restart — check: systemctl status systemd-networkd"
        reapply_routing_all
        return 1
    fi
    sleep 2
    reapply_routing_all
    if [ "$(networkd_status)" = ok ]; then
        ok "systemd-networkd will no longer delete tunnel rules"
        log_file "networkd: foreign rule/route management disabled"
        return 0
    fi
    err "systemd-networkd still uses the old setting — check: systemd-analyze cat-config systemd/networkd.conf"
    return 1
}

# ── بالا/پایین آوردن تونل ────────────────────────
# فایل ذخیره‌شده فقط خونده میشه (sanitize فقط موقع add/edit و روی کپی runtime)
tunnel_up() {
    local name="$1" cfg t out rc
    cfg=$(cfg_path "$name")
    [ -f "$cfg" ] || { err "Config not found: $cfg"; return 1; }

    check_config "$cfg" || return 1

    t=$(meta_get "$cfg" Table-ID)
    if ! TABLE_SELF="$name" v_table "$t"; then
        note "Fix it with: wg-manager edit $name"
        return 1
    fi

    if ip link show "$name" &>/dev/null; then
        step "Restarting $name..."
        tunnel_stop "$name" >/dev/null
    else
        step "Starting $name..."
    fi

    runtime_config "$name" || { err "Could not prepare $RUN_DIR"; return 1; }

    # وقتی default.disable_ipv6=1 هست (مثل Hetzner)، اینترفیس جدید بدون IPv6 ساخته
    # میشه و wg-quick موقع اضافه کردن آدرس IPv6 خطا میده → فقط حین ساختن تونل 0 میشه
    # (اگه اسکریپت وسط کار kill بشه، trap خروج مقدار رو برمیگردونه)
    if conf_get_all "$RT_CFG" Address | grep -q ':' && \
       [ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" = 1 ]; then
        sysctl -qw net.ipv6.conf.default.disable_ipv6=0 && V6_DEFAULT_TOGGLED=1
    fi
    out=$(wg-quick up "$RT_CFG" 2>&1)
    rc=$?
    if [ "$V6_DEFAULT_TOGGLED" = 1 ]; then
        sysctl -qw net.ipv6.conf.default.disable_ipv6=1
        V6_DEFAULT_TOGGLED=0
    fi

    if [ $rc -ne 0 ]; then
        echo "$out" | tail -5 | sed 's/^/      /'
        err "wg-quick failed to start $name"
        log_file "$name: wg-quick up failed: $(echo "$out" | tail -1)"
        return 1
    fi

    if ! apply_routing "$name" "$t"; then
        err "Routing setup failed for $name — rolling back"
        tunnel_stop "$name" >/dev/null
        return 1
    fi

    ok "$name is up ${DIM}(table/mark $t)${NC}"
    log_file "$name up | table $t"
}

tunnel_stop() {
    local name="$1" cfg t
    cfg=$(cfg_path "$name")
    t=$(meta_get "$cfg" Table-ID)
    [[ "$t" =~ ^[0-9]+$ ]] && clear_routing "$name" "$t"

    # Table=off و بدون DNS/hook → پایین آوردن یعنی فقط حذف اینترفیس
    ip link show "$name" &>/dev/null && ip link del "$name" 2>/dev/null
    rm -f "$RUN_DIR/$name.conf"
    if ip link show "$name" &>/dev/null; then
        err "Could not bring down $name"
        return 1
    fi
    ok "$name is down"
    log_file "$name down"
}

# ── تست اتصال ────────────────────────────────────
fmt_age() {
    local s="$1"
    if   [ "$s" -lt 60 ];    then echo "${s}s"
    elif [ "$s" -lt 3600 ];  then echo "$((s / 60))m"
    elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h"
    else                          echo "$((s / 86400))d"
    fi
}

fmt_bytes() {
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec --suffix=B "$1"
    else
        echo "${1}B"
    fi
}

latest_handshake() { wg show "$1" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}'; }

# handshake تازه‌ست؟ اگه نه، ترافیک بفرست و تا ۸ ثانیه صبر کن (WireGuard هر ۵ ثانیه دوباره تلاش میکنه)
handshake_fresh() {
    local name="$1" hs i
    hs=$(latest_handshake "$name")
    if [ "${hs:-0}" -gt 0 ] && [ $(($(date +%s) - hs)) -le "$HANDSHAKE_STALE" ]; then return 0; fi
    ping -c 1 -W 2 -I "$name" 1.1.1.1 &>/dev/null
    for ((i = 0; i < 8; i++)); do
        hs=$(latest_handshake "$name")
        [ "${hs:-0}" -gt 0 ] && [ $(($(date +%s) - hs)) -le "$HANDSHAKE_STALE" ] && return 0
        sleep 1
    done
    return 1
}

# ── تست اتصال: دقیقاً از همون مسیری که Xray میره (socket با SO_MARK) ──
# (curl --interface برای IPv4 قانون‌های routing رو دور میزنه و برای IPv6 اصلاً کار
# نمیکنه — پس هیچ‌وقت leak رو نشون نمیداد)
# خروجی: ip country city mullvad(yes/no/?) src با tab؛ فیلد خالی = "-"
PY_EXIT='
import json, socket, ssl, sys
mark, fam = int(sys.argv[1]), sys.argv[2]
af = socket.AF_INET6 if fam == "6" else socket.AF_INET
def get(host, path):
    addr = socket.getaddrinfo(host, 443, af, socket.SOCK_STREAM)[0][4]
    s = socket.socket(af, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, 36, mark)          # 36 = SO_MARK
    s.settimeout(8)
    s.connect(addr)
    src = s.getsockname()[0]
    t = ssl.create_default_context().wrap_socket(s, server_hostname=host)
    t.sendall(("GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: wg-manager\r\n"
               "Accept: application/json\r\n\r\n" % (path, host)).encode())
    data = b""
    while True:
        chunk = t.recv(65536)
        if not chunk:
            break
        data += chunk
    t.close()
    return src, json.loads(data.split(b"\r\n\r\n", 1)[1].decode())
def f(v):
    v = str(v or "-").replace("\t", " ").strip()
    return v or "-"
try:
    try:
        src, j = get(("ipv6." if fam == "6" else "ipv4.") + "am.i.mullvad.net", "/json")
        mv = "yes" if j.get("mullvad_exit_ip") else "no"
    except Exception:
        src, j = get("ifconfig.co", "/json")
        mv = "?"
    print("\t".join([f(j.get("ip")), f(j.get("country")), f(j.get("city")), mv, f(src)]))
except Exception as e:
    print("ERR\t" + f(e)[:80])
'

# exit_lookup <mark> <4|6> → EX_IP EX_COUNTRY EX_CITY EX_MULLVAD EX_SRC / EX_ERR
exit_lookup() {
    local out
    EX_IP=""; EX_COUNTRY=""; EX_CITY=""; EX_MULLVAD=""; EX_SRC=""; EX_ERR=""
    if ! command -v python3 &>/dev/null; then EX_ERR="python3 is not installed"; return 1; fi
    out=$(timeout 25 python3 -I -c "$PY_EXIT" "$1" "$2" 2>/dev/null)
    if [ -z "$out" ] || [[ "$out" == ERR* ]]; then
        EX_ERR="${out#ERR$'\t'}"; EX_ERR="${EX_ERR:-no answer}"
        return 1
    fi
    IFS=$'\t' read -r EX_IP EX_COUNTRY EX_CITY EX_MULLVAD EX_SRC <<< "$out"
    [ "$EX_COUNTRY" = - ] && EX_COUNTRY=""
    [ "$EX_CITY" = - ] && EX_CITY=""
    [ -n "$EX_IP" ] && [ "$EX_IP" != - ]
}

# آدرس‌های خود سرور (اگه خروجی تست یکی از این‌ها باشه یعنی leak)
is_server_ip() {
    ip -o addr show scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }' | grep -qxF "$1"
}

# ping_stats <mark> <4|6> <target> → PING_AVG (ms) PING_LOSS (%)
ping_stats() {
    local out fam=-4
    [ "$2" = 6 ] && fam=-6
    PING_AVG=""; PING_LOSS=""
    out=$(ping "$fam" -c 5 -i 0.2 -W 2 -q -m "$1" "$3" 2>/dev/null)
    PING_LOSS=$(echo "$out" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
    PING_AVG=$(echo "$out" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
    [ -n "$PING_AVG" ]
}

# MTU: پکت با اندازه MTU اینترفیس با DF رد میشه؟ → MTU_IF MTU_OK(yes/no/unknown) MTU_MAX
mtu_ping() { ping -4 -c 2 -W 2 -q -M do -s $(($2 - 28)) -m "$1" 1.1.1.1 &>/dev/null; }
mtu_probe() {
    local t="$1" name="$2" full="${3:-}" lo hi mid
    MTU_OK="unknown"; MTU_MAX=""
    MTU_IF=$(cat "/sys/class/net/$name/mtu" 2>/dev/null)
    [[ "$MTU_IF" =~ ^[0-9]+$ ]] || return 1
    if mtu_ping "$t" "$MTU_IF"; then MTU_OK=yes; MTU_MAX=$MTU_IF; return 0; fi
    mtu_ping "$t" 1280 || return 1            # حتی پکت کوچیک رد نمیشه → ICMP بسته‌ست، قابل اندازه‌گیری نیست
    MTU_OK=no
    [ "$full" = full ] || return 0
    lo=1280; hi=$MTU_IF
    while [ $((hi - lo)) -gt 4 ]; do
        mid=$(((lo + hi) / 2))
        if mtu_ping "$t" "$mid"; then lo=$mid; else hi=$mid; fi
    done
    MTU_MAX=$lo
}

# with_spin <text> <cmd...> — توی تست کامل حین انتظار spinner نشون میده (نتیجه‌ها تو همین shell میمونن)
with_spin() {
    local txt="$1" rc
    shift
    [ "$TL_MODE" = full ] && spin_start "$txt"
    "$@"; rc=$?
    spin_stop
    return $rc
}

# tl <ok|warn|bad|info> <text> — فقط وقتی تست کامل (نه ردیف test all) چاپ میشه
tl() {
    [ "$TL_MODE" = full ] || return 0
    case "$1" in
        ok)   ok "$2" ;;
        warn) warn "$2" ;;
        bad)  err "$2" ;;
        *)    note "$2" ;;
    esac
}

# test_tunnel <name> [full|row] — نتیجه توی TR_* (برای test all)
test_tunnel_run() {
    local name="$1" t hs v6out fail=0 leak=0
    TL_MODE="${2:-full}"
    TR_EXIT4="-"; TR_LOC="-"; TR_V6="-"; TR_PING="-"; TR_MTU="-"; TR_RESULT=""
    t=$(tunnel_mark "$name")
    if ! is_up "$name"; then
        tl bad "$name is not up"
        TR_RESULT="DOWN"
        return 1
    fi
    [ "$TL_MODE" = full ] && step "Testing $name ${DIM}(mark $t — the same path Xray uses)${NC}"

    # ۱) handshake
    if ! with_spin "waiting for a handshake…" handshake_fresh "$name"; then
        tl bad "No handshake — the Mullvad server is not answering"
        tl info "Check: keys, Endpoint, account status, and that UDP to the endpoint is not blocked"
        TR_RESULT="NO-HANDSHAKE"
        return 1
    fi
    hs=$(latest_handshake "$name")
    tl ok "Handshake $(fmt_age $(($(date +%s) - hs))) ago"

    # ۲) routing مسیر mark
    if [[ "$t" =~ ^[0-9]+$ ]] && routing_ok_quick "$name" "$t" && marked_route_ok "$name" "$t"; then
        tl ok "Routing: mark $t → $name"
    else
        tl bad "Routing for mark $t is broken — Xray traffic exits via the server IP"
        tl info "Fix: wg-manager doctor --fix"
        leak=1
    fi

    # ۳) IPv4 خروجی
    if with_spin "checking the IPv4 exit IP…" exit_lookup "$t" 4; then
        TR_EXIT4="$EX_IP"
        TR_LOC="${EX_CITY:+$EX_CITY, }${EX_COUNTRY:--}"
        if is_server_ip "$EX_IP"; then
            tl bad "IPv4 exit is the SERVER's own IP ($EX_IP) — LEAK"
            leak=1
        elif [ "$EX_MULLVAD" = no ]; then
            tl warn "IPv4 exit $EX_IP ($TR_LOC) is not a Mullvad IP"
        else
            tl ok "IPv4 exit: ${BOLD}$EX_IP${NC} ${DIM}$TR_LOC${EX_MULLVAD:+$([ "$EX_MULLVAD" = yes ] && echo ' · Mullvad')}${NC}"
        fi
    else
        tl bad "IPv4: no internet through the tunnel ($EX_ERR)"
        fail=1
    fi
    if with_spin "ping…" ping_stats "$t" 4 1.1.1.1; then
        TR_PING="${PING_AVG%.*}ms"
        if [ "${PING_LOSS%.*}" -gt 0 ] 2>/dev/null; then
            tl warn "IPv4 ping: ${PING_AVG} ms, ${PING_LOSS}% loss"
        else
            tl ok "IPv4 ping: ${PING_AVG} ms, 0% loss"
        fi
    else
        tl info "IPv4 ping: no reply (ICMP may be blocked)"
    fi

    # ۴) IPv6
    if ! has_ipv6; then
        TR_V6="n/a"
    elif conf_get_all "$(cfg_path "$name")" Address | grep -q ':'; then
        if with_spin "checking the IPv6 exit IP…" exit_lookup "$t" 6; then
            if is_server_ip "$EX_IP"; then
                tl bad "IPv6 exit is the SERVER's own IP ($EX_IP) — LEAK"
                TR_V6="LEAK"; leak=1
            else
                tl ok "IPv6 exit: ${BOLD}$EX_IP${NC}"
                TR_V6="ok"
            fi
            ping_stats "$t" 6 2606:4700:4700::1111 && tl ok "IPv6 ping: ${PING_AVG} ms, ${PING_LOSS}% loss"
        else
            tl bad "IPv6: no internet through the tunnel ($EX_ERR)"
            tl info "Check AllowedIPs has ::/0; with Xray UseIPv6v4 these sites may fail"
            TR_V6="fail"; fail=1
        fi
    else
        # آدرس IPv6 نداره → باید بلاک باشه، نه leak از IPv6 سرور
        v6out=$(ip -6 route get 2606:4700:4700::1111 mark "$t" 2>/dev/null)
        if [ -z "$v6out" ] || [[ "$v6out" == unreachable* ]] || echo "$v6out" | has_dev lo; then
            tl info "IPv6: blocked for this mark (tunnel has no IPv6 address)"
            TR_V6="off"
        else
            tl bad "IPv6 with mark $t leaves via another interface — LEAK"
            TR_V6="LEAK"; leak=1
        fi
    fi

    # ۵) MTU
    if with_spin "measuring MTU…" mtu_probe "$t" "$name" "$([ "$TL_MODE" = full ] && echo full)"; then
        if [ "$MTU_OK" = yes ]; then
            tl ok "MTU $MTU_IF: full-size packets pass"
            TR_MTU="ok"
        else
            TR_MTU="low"
            if [ -n "$MTU_MAX" ]; then
                tl warn "MTU: $MTU_IF-byte packets don't pass; largest that works ≈ $MTU_MAX"
                tl info "Add 'MTU = $MTU_MAX' to [Interface] with: wg-manager edit $name"
            else
                tl warn "MTU: $MTU_IF-byte packets don't pass (run 'wg-manager test $name' for details)"
            fi
        fi
    else
        tl info "MTU: could not measure (ICMP blocked?)"
    fi

    # ۶) شمارنده leak (از زمان بوت)
    if [[ "$t" =~ ^[0-9]+$ ]]; then
        leak_read "$t"
        if [ "$LEAK_PKTS" -gt 0 ]; then
            tl info "Leak counter since boot: $LEAK_PKTS packets ($(fmt_bytes "$LEAK_BYTES")) left via the server IP (e.g. while the tunnel was down or restarting)"
        else
            tl ok "Leak counter since boot: 0 packets"
        fi
    fi

    if [ "$leak" = 1 ]; then TR_RESULT="LEAK"
    elif [ "$fail" = 1 ]; then TR_RESULT="FAIL"
    else TR_RESULT="OK"; fi
    if [ "$TL_MODE" = full ]; then
        case "$TR_RESULT" in
            OK)   ok "${BOLD}$name: all good${NC}" ;;
            LEAK) err "$name: traffic is leaking via the server IP" ;;
            *)    err "$name: problems found (see above)" ;;
        esac
    fi
    [ "$TR_RESULT" = OK ]
}

# نتیجه هر تست ذخیره میشه تا صفحه تونل نشون بده «آخرین تست کی و چی بود»
test_tunnel() {
    local rc
    test_tunnel_run "$@"
    rc=$?
    test_save "$1"
    return $rc
}
test_save() {   # فایل: epoch، نتیجه، IP خروجی، محل، ping (هر کدوم یه خط)
    [ -n "$TR_RESULT" ] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '%s\n%s\n%s\n%s\n%s\n' "$(date +%s)" "$TR_RESULT" "$TR_EXIT4" "$TR_LOC" "$TR_PING" \
        > "$STATE_DIR/test-$1" 2>/dev/null
    return 0
}
test_load() {   # test_load <name> → LT_TS LT_RESULT LT_EXIT LT_LOC LT_PING (LT_TS خالی = هیچ‌وقت)
    LT_TS=""; LT_RESULT=""; LT_EXIT=""; LT_LOC=""; LT_PING=""
    [ -f "$STATE_DIR/test-$1" ] || return 1
    { read -r LT_TS; read -r LT_RESULT; read -r LT_EXIT; read -r LT_LOC; read -r LT_PING; } \
        2>/dev/null < "$STATE_DIR/test-$1"
    [[ "$LT_TS" =~ ^[0-9]+$ ]] || { LT_TS=""; return 1; }
}

# test_all [names...] — بدون آرگومان: همه تونل‌های بالا
test_all() {
    local n names=() bad=0 c
    if [ $# -gt 0 ]; then names=("$@"); else
        for n in $(list_tunnels); do is_up "$n" && names+=("$n"); done
    fi
    if [ ${#names[@]} -eq 0 ]; then
        warn "No tunnels are up"
        return 1
    fi
    note "Testing ${#names[@]} tunnels through their marks (about 10s each)..."
    echo ""
    printf "  ${DIM}%-15s %-4s %-16s %-18s %-5s %-6s %-4s %s${NC}\n" \
        "NAME" "MARK" "IPv4 EXIT" "LOCATION" "IPv6" "PING" "MTU" "RESULT"
    for n in "${names[@]}"; do
        spin_start "testing $n…"
        test_tunnel "$n" row
        spin_stop
        case "$TR_RESULT" in OK) c="$GREEN" ;; *) c="$RED"; bad=$((bad + 1)) ;; esac
        [ ${#TR_LOC} -gt 18 ] && TR_LOC="${TR_LOC:0:17}~"
        printf "  %-15s %-4s %-16s %-18s %-5s %-6s %-4s %b%s%b\n" \
            "$n" "$(tunnel_mark "$n")" "$TR_EXIT4" "$TR_LOC" "$TR_V6" "$TR_PING" "$TR_MTU" "$c" "$TR_RESULT" "$NC"
    done
    echo ""
    if [ "$bad" -eq 0 ]; then
        ok "${BOLD}All ${#names[@]} tunnels OK${NC}"
    else
        err "$bad of ${#names[@]} tunnels have problems — details: wg-manager test <name>"
        return 1
    fi
}

print_xray_hint() {
    local name="$1" t="$2"
    echo ""
    echo -e "  ${BOLD}Xray outbound for $name:${NC}"
    echo -e "    ${CYAN}{ \"tag\": \"wg-$name\", \"protocol\": \"freedom\",${NC}"
    echo -e "    ${CYAN}  \"settings\": { \"domainStrategy\": \"AsIs\" },${NC}"
    echo -e "    ${CYAN}  \"streamSettings\": { \"sockopt\": { \"mark\": $t } } }${NC}"
    note "Route to it: { \"type\": \"field\", \"inboundTag\": [\"...\"], \"outboundTag\": \"wg-$name\" }"
    if ! conf_get_all "$(cfg_path "$name")" Address | grep -q ':'; then
        note "This tunnel has no IPv6 address — use \"domainStrategy\": \"ForceIPv4\" for it"
    fi
}

# ── عرض ترمینال (روی گوشی ~50 ستون) ───────────────
term_cols() {
    local c="${COLUMNS:-}"
    [[ "$c" =~ ^[0-9]+$ ]] || c=$(tput cols 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    echo "$c"
}
is_narrow() { [ "$(term_cols)" -lt 90 ]; }   # جدول جدید ~۸۶ ستونه
is_compact() { [ "$(term_cols)" -lt 60 ]; }  # گوشی (عمودی): هر تونل یه خط، کلیدهای کمتر

# ── لوگو (ابر + مدار) ────────────────────────────
# همه خط‌ها دقیقاً LOGO_W کاراکتر (برای کنار هم گذاشتن با متن). WGM_LOGO=0 → بدون لوگو
LOGO_W=26
LOGO_PLAIN=(
"       ╭──────╮           "
"    ╭──┴─╮    ╰─────╮     "
"  ╭─╯    ╵  ┃┃      ╰──╮  "
"  │      ╷  ┃┃  ╷      │  "
"  ╰──────┤  ┃┃  ├──────╯  "
"         │  ▪▪  │         "
" ▪ ▪ ○───╯  ▪▪  ╰───○ ▪ ▪ "
"            ▪▪            "
)
LOGO=()
# str_sub <var> <char> <replacement> — جایگزینی بدون ${x//a/b} (رفتار & و \ توی bash 5.2 فرق داره)
str_sub() {
    local __s="${!1}" __o=""
    while [[ "$__s" == *"$2"* ]]; do
        __o="$__o${__s%%"$2"*}$3"
        __s="${__s#*"$2"}"
    done
    printf -v "$1" '%s' "$__o$__s"
}
logo_build() {   # رنگ‌ها: ابر آبی، خط‌های وسط سفید، نقطه‌ها خاکستری، دایره‌ها فیروزه‌ای
    local l c="${BLUE}"
    LOGO=()
    for l in "${LOGO_PLAIN[@]}"; do
        str_sub l "┃" "${WHITE}${BOLD}┃${NC}${c}"
        str_sub l "▪" "${DIM}▪${c}"
        str_sub l "○" "${CYAN}${BOLD}○${NC}${c}"
        LOGO+=("${c}${l}${NC}")
    done
}
show_logo() { [ "${WGM_LOGO:-1}" = 1 ] && [ "$(term_cols)" -ge 34 ]; }

# ── اسم Mullvad → محل ───────────────────────────
# de-fra-wg-203 → "DE Frankfurt". پرچم فقط با WGM_FLAGS=1 (خیلی از ترمینال‌ها مثل
# Windows Terminal/PuTTY/tmux پرچم رو درست نشون نمیدن و ستون‌ها رو به هم میریزن)
mullvad_city() {
    case "$1" in
        al-tia) echo Tirana ;;      at-vie) echo Vienna ;;       au-adl) echo Adelaide ;;
        au-bne) echo Brisbane ;;    au-mel) echo Melbourne ;;    au-per) echo Perth ;;
        au-syd) echo Sydney ;;      be-bru) echo Brussels ;;     bg-sof) echo Sofia ;;
        br-sao) echo "Sao Paulo" ;; br-for) echo Fortaleza ;;    ca-mtr) echo Montreal ;;
        ca-tor) echo Toronto ;;     ca-van) echo Vancouver ;;    ca-yyc) echo Calgary ;;
        ch-zrh) echo Zurich ;;      cl-scl) echo Santiago ;;     co-bog) echo Bogota ;;
        cy-nic) echo Nicosia ;;     cz-prg) echo Prague ;;       de-ber) echo Berlin ;;
        de-dus) echo Dusseldorf ;;  de-fra) echo Frankfurt ;;    dk-cph) echo Copenhagen ;;
        ee-tll) echo Tallinn ;;     es-bcn) echo Barcelona ;;    es-mad) echo Madrid ;;
        es-vlc) echo Valencia ;;    fi-hel) echo Helsinki ;;     fr-bod) echo Bordeaux ;;
        fr-mrs) echo Marseille ;;   fr-par) echo Paris ;;        gb-glw) echo Glasgow ;;
        gb-lon) echo London ;;      gb-mnc) echo Manchester ;;   gr-ath) echo Athens ;;
        hk-hkg) echo "Hong Kong" ;; hr-zag) echo Zagreb ;;       hu-bud) echo Budapest ;;
        id-jpu) echo Jakarta ;;     ie-dub) echo Dublin ;;       il-tlv) echo "Tel Aviv" ;;
        it-mil) echo Milan ;;       it-pmo) echo Palermo ;;      jp-osa) echo Osaka ;;
        jp-tyo) echo Tokyo ;;       mx-qro) echo Queretaro ;;    my-kul) echo "Kuala Lumpur" ;;
        ng-los) echo Lagos ;;       nl-ams) echo Amsterdam ;;    no-osl) echo Oslo ;;
        no-svg) echo Stavanger ;;   nz-akl) echo Auckland ;;     pe-lim) echo Lima ;;
        ph-mnl) echo Manila ;;      pl-waw) echo Warsaw ;;       pt-lis) echo Lisbon ;;
        ro-buh) echo Bucharest ;;   rs-beg) echo Belgrade ;;     se-got) echo Gothenburg ;;
        se-mma) echo Malmo ;;       se-sto) echo Stockholm ;;    sg-sin) echo Singapore ;;
        si-lju) echo Ljubljana ;;   sk-bts) echo Bratislava ;;   th-bkk) echo Bangkok ;;
        tr-ist) echo Istanbul ;;    ua-iev) echo Kyiv ;;         us-atl) echo Atlanta ;;
        us-bos) echo Boston ;;      us-chi) echo Chicago ;;      us-dal) echo Dallas ;;
        us-den) echo Denver ;;      us-det) echo Detroit ;;      us-hou) echo Houston ;;
        us-lax) echo "Los Angeles" ;; us-mia) echo Miami ;;      us-mkc) echo "Kansas City" ;;
        us-nyc) echo "New York" ;;  us-phx) echo Phoenix ;;      us-qas) echo Ashburn ;;
        us-rag) echo Raleigh ;;     us-sea) echo Seattle ;;      us-sjc) echo "San Jose" ;;
        us-slc) echo "Salt Lake City" ;; us-uyk) echo Secaucus ;; za-jnb) echo Johannesburg ;;
        *) return 1 ;;
    esac
}
location_of() {
    local n="$1" cc city
    if [[ "$n" =~ ^([a-z]{2})-([a-z]{3})(-|$) ]]; then
        cc="${BASH_REMATCH[1]}"
        city=$(mullvad_city "$cc-${BASH_REMATCH[2]}") || city=$(printf '%s' "${BASH_REMATCH[2]}" | tr 'a-z' 'A-Z')
        printf '%s %s' "$(printf '%s' "$cc" | tr 'a-z' 'A-Z')" "$city"
    else
        printf '%s' "-"
    fi
}
# پرچم (فقط با WGM_FLAGS=1)؛ همیشه ۲ ستون عرض + فاصله، یا هیچی
flag_of() {
    local a b
    [ "${WGM_FLAGS:-1}" = 1 ] || return 0      # پیش‌فرض روشن؛ WGM_FLAGS=0 خاموش
    [[ "$1" =~ ^([a-z])([a-z])- ]] || { printf '   '; return 0; }
    a=$(printf '%d' "'${BASH_REMATCH[1]}"); b=$(printf '%d' "'${BASH_REMATCH[2]}")
    # regional indicator: U+1F1E6 + (حرف - a) → UTF-8: F0 9F 87 (A6 + i)
    printf "\xF0\x9F\x87\x$(printf '%x' $((0xA6 + a - 97)))\xF0\x9F\x87\x$(printf '%x' $((0xA6 + b - 97))) "
}

# ── handshake سه سطحی (بدون رنگ هم معلوم باشه) ──
# ≤180s خوب · تا ۱۰ دقیقه "?" (مشکوک) · بیشتر یا هیچ‌وقت "!" (مشکل)
hs_label() {   # hs_label <latest-handshake-epoch> → HS_TXT HS_C
    local hs="$1" age
    if [ "${hs:-0}" -le 0 ]; then HS_TXT="never!"; HS_C="$RED"; return; fi
    age=$(($(date +%s) - hs))
    if [ "$age" -le "$HANDSHAKE_STALE" ]; then HS_TXT="$(fmt_age "$age")"; HS_C="$GREEN"
    elif [ "$age" -le 600 ]; then HS_TXT="$(fmt_age "$age")?"; HS_C="$YELLOW"
    else HS_TXT="$(fmt_age "$age")!"; HS_C="$RED"; fi
}

# وضعیت یکسان همه‌جا: up · LEAK · DOWN (فعال ولی پایین) · off (خاموش عمدی)
tunnel_state() {   # → ST ST_C
    local n="$1" t
    t=$(tunnel_mark "$n")
    if is_up "$n"; then
        if [[ "$t" =~ ^[0-9]+$ ]] && ! routing_ok_quick "$n" "$t"; then ST="LEAK"; ST_C="$RED"
        else ST="up"; ST_C="$GREEN"; fi
    elif is_enabled "$n"; then ST="DOWN"; ST_C="$RED"
    else ST="off"; ST_C="$GRAY"; fi
}

# ── جدول تونل‌ها ────────────────────────────────
# ستون # همون شماره‌ایه که توی منو و دستورها قبول میشه (مرتب بر اساس اسم، ثابت)
print_tunnel_table() {
    local names=() n t i=0 loc v6 rx tx traffic unmanaged offmarks="" narrow=0 fp=""
    while read -r n; do [ -n "$n" ] && names+=("$n"); done < <(list_tunnels)

    if [ ${#names[@]} -eq 0 ]; then
        echo -e "  No tunnels yet."
        echo ""
        echo -e "  $(key_hint a dd) a Mullvad config      $(key_hint install "") boot service + watchdog"
        return
    fi
    is_narrow && narrow=1
    is_compact && narrow=2
    [ "${WGM_FLAGS:-1}" = 1 ] && fp="   "        # جای پرچم توی سرستون

    if [ "$narrow" = 2 ]; then
        printf "  %b%-2s %s%-15s %-4s %-4s %s%b\n" "$DIM" "#" "$fp" "NAME" "" "MARK" "HS" "$NC"
    elif [ "$narrow" = 0 ]; then
        printf "  %b%-3s %s%-15s   %-5s   %-16s   %-4s   %-2s   %-6s   %s%b\n" "$DIM" \
            "#" "$fp" "NAME" "STATE" "LOCATION" "MARK" "v6" "HS" "↓ / ↑ TOTAL" "$NC"
        echo ""
    fi
    for n in "${names[@]}"; do
        i=$((i + 1))
        t=$(tunnel_mark "$n")
        tunnel_state "$n"
        loc=$(location_of "$n")
        conf_get_all "$(cfg_path "$n")" Address | grep -q ':' && v6="✓" || v6="–"
        if is_up "$n"; then
            hs_label "$(latest_handshake "$n")"
            rx=0; tx=0
            read -r rx tx < <(wg show "$n" transfer 2>/dev/null | awk 'NR==1 {print $2, $3}')
            traffic="$(fmt_bytes "${rx:-0}") / $(fmt_bytes "${tx:-0}")"
        else
            HS_TXT="–"; HS_C="$DIM"; traffic="–"
        fi
        # مشکل‌ها (LEAK/DOWN/handshake) توی نوار سلامت بالای صفحه با [f] نشون داده میشن
        [ "$ST" = off ] && [[ "$t" =~ ^[0-9]+$ ]] && offmarks="$offmarks $t"

        if [ "$narrow" = 2 ]; then
            # گوشی: هر تونل یه خط (~۴۰ ستون)
            printf "  %b%-2s%b %s%b%-15s%b %b%-4s%b %-4s %b%s%b\n" "$DIM" "$i" "$NC" "$(flag_of "$n")" \
                "$WHITE" "$n" "$NC" "$ST_C" "$ST" "$NC" "${t:-?}" "$HS_C" "$HS_TXT" "$NC"
        elif [ "$narrow" = 1 ]; then
            # روی گوشی: دو خط برای هر تونل + یه خط خالی
            printf "  %b%-2s%b %s%b%-15s%b  %b%-4s%b  %s\n" "$DIM" "$i" "$NC" "$(flag_of "$n")" \
                "$WHITE" "$n" "$NC" "$ST_C" "$ST" "$NC" "$loc"
            printf "     %bmark%b %s   %bv6%b %s   %bhs%b %b%s%b   %s\n\n" "$DIM" "$NC" "${t:-?}" "$DIM" "$NC" "$v6" \
                "$DIM" "$NC" "$HS_C" "$HS_TXT" "$NC" "$traffic"
        else
            [ ${#loc} -gt 16 ] && loc="${loc:0:15}~"
            printf "  %b%-3s%b %s%b%-15s%b   %b%-5s%b   %-16s   %-4s   %-2s   %b%-6s%b   %s\n" \
                "$DIM" "$i" "$NC" "$(flag_of "$n")" "$WHITE" "$n" "$NC" "$ST_C" "$ST" "$NC" \
                "$loc" "${t:-?}" "$v6" "$HS_C" "$HS_TXT" "$NC" "$traffic"
        fi
    done

    unmanaged=""
    for n in $(wg show interfaces 2>/dev/null); do
        [ -f "$(cfg_path "$n")" ] || unmanaged="$unmanaged $n"
    done
    if [ -n "$unmanaged" ] || [ -n "$offmarks" ]; then echo ""; fi
    [ -n "$unmanaged" ] && note "Other WireGuard interfaces (not managed here):$unmanaged"
    # انتخاب کاربر: تونل خاموش بلاک نمیشه، ولی نباید بی‌خبر بمونه
    [ -n "$offmarks" ] && echo -e "  ${YELLOW}!${NC} Xray outbounds with mark${offmarks} exit via the server IP while those tunnels are off"
    return 0
}

service_state() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}not installed${NC}"
    elif systemctl is-enabled wg-manager.service &>/dev/null; then
        echo -e "${GREEN}on${NC}"
    else
        echo -e "${GRAY}off${NC}"
    fi
}

watchdog_state() {
    local age
    if systemctl is-enabled wg-manager-watchdog.timer &>/dev/null; then
        age=$(watchdog_age)
        if [ -z "$age" ]; then
            echo -e "${GREEN}on${NC}"
        elif [ "$age" -gt 900 ]; then
            echo -e "${RED}last run $(fmt_age "$age") ago!${NC}"
        else
            echo -e "${GREEN}$(fmt_age "$age") ago${NC}"
        fi
    else
        echo -e "${YELLOW}off${NC}"
    fi
}

# ── داشبورد بالای منو ───────────────────────────
# سرعت کل: دو نمونه با ۰.۴ ثانیه فاصله از /sys (بدون fork برای هر تونل)
total_rate() {   # → RATE_RX RATE_TX (bit/s)
    local n f r1=0 t1=0 r2=0 t2=0 ifs=()
    for n in $(list_tunnels); do [ -d "/sys/class/net/$n" ] && ifs+=("$n"); done
    RATE_RX=0; RATE_TX=0
    [ ${#ifs[@]} -gt 0 ] || return 0
    for n in "${ifs[@]}"; do
        r1=$((r1 + $(cat "/sys/class/net/$n/statistics/rx_bytes" 2>/dev/null || echo 0)))
        t1=$((t1 + $(cat "/sys/class/net/$n/statistics/tx_bytes" 2>/dev/null || echo 0)))
    done
    sleep 0.4
    for n in "${ifs[@]}"; do
        r2=$((r2 + $(cat "/sys/class/net/$n/statistics/rx_bytes" 2>/dev/null || echo 0)))
        t2=$((t2 + $(cat "/sys/class/net/$n/statistics/tx_bytes" 2>/dev/null || echo 0)))
    done
    RATE_RX=$(((r2 - r1) * 8 * 10 / 4)); RATE_TX=$(((t2 - t1) * 8 * 10 / 4))
    [ "$RATE_RX" -lt 0 ] && RATE_RX=0
    [ "$RATE_TX" -lt 0 ] && RATE_TX=0
    return 0
}
fmt_rate() {   # bit/s → "12.3 Mb/s"
    awk -v b="$1" 'BEGIN {
        if (b >= 1e9) printf "%.1f Gb/s", b / 1e9
        else if (b >= 1e6) printf "%.1f Mb/s", b / 1e6
        else if (b >= 1e3) printf "%.0f Kb/s", b / 1e3
        else printf "%d b/s", b }'
}

# آخرین مشکل/تعمیر از لاگ (۷ روز اخیر) + تعداد تعمیرهای امروز (نشون میده چیزی مدام خراب میشه)
last_event() {
    local line ts age today fixes
    [ -f "$LOG_FILE" ] || return 0
    line=$(grep -E 'doctor: |up-all failed|wg-quick up failed' "$LOG_FILE" 2>/dev/null | tail -1)
    [ -n "$line" ] || return 0
    ts=$(date -d "$(echo "$line" | sed -n 's/^\[\([^]]*\)\].*/\1/p')" +%s 2>/dev/null) || return 0
    age=$(($(date +%s) - ts))
    [ "$age" -le 604800 ] || return 0
    today=$(date '+%Y-%m-%d')
    fixes=$(grep -c "^\[$today .*doctor: fixed" "$LOG_FILE" 2>/dev/null)
    line=$(echo "$line" | sed 's/^\[[^]]*\] //; s/^doctor: //')
    [ ${#line} -gt 60 ] && line="${line:0:59}…"
    printf '%s · %s ago' "$line" "$(fmt_age "$age")"
    [ "${fixes:-0}" -gt 0 ] && printf ' · repairs today: %s' "$fixes"
}

# ── سلامت کلی (سریع، بدون قفل، بدون شبکه) ──────────
# → HEALTH_ISSUES (متن کوتاه) · HEALTH_NEED_INSTALL (تعمیرش install میخواد) · HC_UP/HC_TOTAL
health_check() {
    local n i=0 age
    HEALTH_ISSUES=(); HEALTH_NEED_INSTALL=0; HEALTH_PAUSED=0; HC_UP=0; HC_TOTAL=0
    [ -f "$PAUSE_FLAG" ] && HEALTH_PAUSED=1
    for n in $(list_tunnels); do
        i=$((i + 1)); HC_TOTAL=$((HC_TOTAL + 1))
        tunnel_state "$n"
        case "$ST" in
            up)   HC_UP=$((HC_UP + 1))
                  hs_label "$(latest_handshake "$n")"
                  case "$HS_TXT" in
                      never!) HEALTH_ISSUES+=("#$i $n: no handshake yet — Mullvad server not answering") ;;
                      *!)     HEALTH_ISSUES+=("#$i $n: no handshake for ${HS_TXT%!}") ;;
                  esac ;;
            LEAK) HC_UP=$((HC_UP + 1))
                  HEALTH_ISSUES+=("#$i $n: routing rules are gone — Xray exits via the server IP") ;;
            DOWN) [ "$HEALTH_PAUSED" = 1 ] || HEALTH_ISSUES+=("#$i $n: enabled but down") ;;
        esac
    done
    [ "$HC_TOTAL" -gt 0 ] || return 0
    case "$(networkd_status)" in
        unsafe|pending) HEALTH_ISSUES+=("systemd-networkd can delete the tunnel rules when it restarts") ;;
    esac
    if [ ! -f "$SERVICE_FILE" ] || ! systemctl is-enabled wg-manager.service &>/dev/null; then
        HEALTH_ISSUES+=("auto-start on boot is not installed"); HEALTH_NEED_INSTALL=1
    fi
    if ! systemctl is-enabled wg-manager-watchdog.timer &>/dev/null; then
        HEALTH_ISSUES+=("watchdog is not installed"); HEALTH_NEED_INSTALL=1
    else
        age=$(watchdog_age)
        if [ -n "$age" ] && [ "$age" -gt 900 ]; then
            HEALTH_ISSUES+=("watchdog has not run for $(fmt_age "$age")"); HEALTH_NEED_INSTALL=1
        fi
    fi
    if schema_pending; then HEALTH_ISSUES+=("upgrade pending (this version needs 'install')"); HEALTH_NEED_INSTALL=1; fi
    return 0
}

# [f] از منو: اول install (اگه لازمه)، بعد doctor --fix
fix_now() {
    if [ "$HEALTH_NEED_INSTALL" = 1 ]; then
        run_locked cmd_install || return 1
    fi
    DOC_FIX=1 run_locked cmd_doctor
}

print_health() {
    local n k=0 max=4 w cnt=${#HEALTH_ISSUES[@]}
    [ "$HC_TOTAL" -gt 0 ] || [ "$cnt" -gt 0 ] || return 0
    w=$(($(term_cols) - 8))
    if [ "$cnt" -eq 0 ]; then
        if [ "$HEALTH_PAUSED" = 1 ]; then :
        elif is_compact; then echo -e "  ${GREEN}${BOLD}✓ All good${NC}"
        else echo -e "  ${GREEN}${BOLD}✓ All good${NC}   ${DIM}rules in place · handshakes fresh · watchdog on${NC}"; fi
    else
        [ "$cnt" -eq 1 ] && n="1 problem" || n="$cnt problems"
        echo -e "  ${RED}${BOLD}✗ $n${NC}   $(key_hint f " fix now")    $(key_hint d " details")"
        for n in "${HEALTH_ISSUES[@]}"; do
            k=$((k + 1))
            if [ "$k" -gt "$max" ]; then note "+$((cnt - max)) more"; break; fi
            [ ${#n} -gt "$w" ] && n="${n:0:$((w - 1))}…"
            echo -e "    ${RED}·${NC} $n"
        done
    fi
    if [ "$HEALTH_PAUSED" = 1 ]; then
        echo -e "  ${YELLOW}${BOLD}❚❚ Paused${NC}  ${DIM}down-all was used — tunnels stay down until up-all or a reboot${NC}"
    fi
    return 0
}

# ── «از آخرین باری که سر زدی» ────────────────────
# $STATE_DIR/last-visit: "<epoch> <boot_id> <جمع شمارنده leak>" — موقع باز و بسته شدن منو نوشته میشه
leak_total() {
    local n t sum=0
    for n in $(list_tunnels); do
        t=$(tunnel_mark "$n")
        [[ "$t" =~ ^[0-9]+$ ]] || continue
        leak_read "$t"; sum=$((sum + LEAK_PKTS))
    done
    echo "$sum"
}
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo -; }
visit_save() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '%s %s %s\n' "$(date +%s)" "$(boot_id)" "$(leak_total)" > "$STATE_DIR/last-visit" 2>/dev/null
    return 0
}
menu_exit() { visit_save; echo ""; exit 0; }

since_visit_init() {
    local prev="" pboot="" pleak="" now age since out rep=0 fail=0 rest="" e nm c
    local leak rebooted=0 parts=() list="" joined=""
    SINCE_LINE=""
    [ -f "$STATE_DIR/last-visit" ] && read -r prev pboot pleak 2>/dev/null < "$STATE_DIR/last-visit"
    visit_save
    [[ "$prev" =~ ^[0-9]+$ ]] || return 0           # بار اول
    now=$(date +%s); age=$((now - prev))
    [ "$age" -ge 600 ] || return 0                   # همین چند دقیقه پیش اینجا بودی
    since=$(date -d "@$prev" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || return 0

    if [ -f "$LOG_FILE" ]; then
        out=$(awk -v s="[$since]" '
            substr($0, 1, 21) > s {
                m = substr($0, 23)
                if (m ~ /^doctor: fixed/) rep++
                else if (m ~ /^doctor: not fixed|up-all failed|wg-quick up failed/) fail++
                else if (m ~ /^[^ ]+ up \| table/) { split(m, a, " "); up[a[1]]++ }
            }
            END { printf "%d %d", rep, fail; for (n in up) printf " %s:%d", n, up[n] }' "$LOG_FILE" 2>/dev/null)
        read -r rep fail rest <<< "$out"
    fi

    [ "$(boot_id)" != "${pboot:--}" ] && [ "${pboot:--}" != - ] && rebooted=1
    leak=$(leak_total)
    if [ "$rebooted" = 1 ] || ! [[ "$pleak" =~ ^[0-9]+$ ]] || [ "$leak" -lt "$pleak" ]; then :
    else leak=$((leak - pleak)); fi

    [ "$rebooted" = 1 ] && parts+=("${YELLOW}server rebooted${NC}")
    for e in $rest; do
        nm="${e%:*}"; c="${e##*:}"
        [ "$rebooted" = 1 ] && c=$((c - 1))          # بالا اومدن بعد از ریبوت ری‌استارت حساب نمیشه
        [ "$c" -gt 0 ] || continue
        [ "$c" -gt 1 ] && nm="$nm ×$c"
        list="${list:+$list, }$nm"
    done
    [ -n "$list" ] && parts+=("restarted ${YELLOW}$list${NC}")
    [ "${rep:-0}" -gt 0 ] && parts+=("${YELLOW}$rep${NC} auto-repair$([ "$rep" -gt 1 ] && echo s)")
    [ "${fail:-0}" -gt 0 ] && parts+=("${RED}$fail failed repair$([ "$fail" -gt 1 ] && echo s)${NC}")
    if [ "$leak" -gt 0 ]; then parts+=("${RED}$leak leaked packets${NC}")
    else parts+=("leaks 0"); fi

    if [ ${#parts[@]} -eq 1 ] && [ "$leak" -eq 0 ]; then
        SINCE_LINE="${DIM}since last visit ($(fmt_age "$age") ago):${NC} ${GREEN}quiet — nothing happened ✓${NC}"
        return 0
    fi
    for e in "${parts[@]}"; do joined="${joined:+$joined ${DIM}·${NC} }$e"; done
    SINCE_LINE="${DIM}since last visit ($(fmt_age "$age") ago):${NC} $joined"
}

print_dashboard() {
    local sep="     " ev cols i dot wd l_title l_state l_rate right=()
    health_check
    total_rate
    cols=$(term_cols)
    is_narrow && sep="   "
    [ ${#HEALTH_ISSUES[@]} -gt 0 ] && dot="${RED}●${NC}" || dot="${GREEN}●${NC}"
    l_title="${WHITE}${BOLD}WireGuard SAFE Manager${NC}  ${DIM}v$VERSION${NC}"
    l_rate="${GREEN}↓${NC} $(fmt_rate "$RATE_RX")$sep${BLUE}↑${NC} $(fmt_rate "$RATE_TX")"
    echo ""
    if is_compact; then
        wd=$(watchdog_state)
        echo -e "  $l_title"
        echo -e "  $dot ${WHITE}$HC_UP/$HC_TOTAL${NC} up  ${DIM}wd${NC} $wd  ${DIM}boot${NC} $(service_state)"
        echo -e "  $l_rate"
    else
        l_state="$dot ${WHITE}$HC_UP/$HC_TOTAL${NC} up$sep${DIM}watchdog${NC} $(watchdog_state)$sep${DIM}boot${NC} $(service_state)"
        if show_logo && [ "$cols" -ge 72 ]; then
            [ ${#LOGO[@]} -gt 0 ] || logo_build
            right=("" "$l_title" "${DIM}Mullvad WireGuard tunnels for Xray${NC}" "" "$l_state" "$l_rate" "" "")
            for i in "${!LOGO[@]}"; do printf '  %b  %b\n' "${LOGO[$i]}" "${right[$i]}"; done
        else
            echo -e "  $l_title"
            echo ""
            echo -e "  $l_state"
            echo -e "  $l_rate"
        fi
    fi
    echo ""
    print_health
    [ -n "${SINCE_LINE:-}" ] && echo -e "  $SINCE_LINE"
    if ! is_compact; then
        ev=$(last_event)
        [ -n "$ev" ] && echo -e "  ${DIM}last event  $ev${NC}"
    fi
    echo ""
    hr
    echo ""
}

# ── پیدا کردن تونل از ورودی کاربر ───────────────
# اسم کامل، شماره ردیف جدول، یا بخشی از اسم که فقط به یه تونل بخوره ("fra" → de-fra-wg-203).
# exact = فقط اسم کامل (برای delete و وقتی ورودی از اسکریپت میاد، نه ترمینال)
match_tunnel() {   # match_tunnel <var> <input> [exact]
    local __mv="$1" in="$2" mode="${3:-}" names=() hits=() n lin
    while read -r n; do [ -n "$n" ] && names+=("$n"); done < <(list_tunnels)
    for n in "${names[@]}"; do
        [ "$n" = "$in" ] && { printf -v "$__mv" '%s' "$n"; return 0; }
    done
    if [ "$mode" = exact ]; then err "No tunnel named '$in' (the full name is needed here)"; return 1; fi
    if [[ "$in" =~ ^[0-9]+$ ]]; then
        if [ "$in" -ge 1 ] && [ "$in" -le ${#names[@]} ]; then
            printf -v "$__mv" '%s' "${names[$((in - 1))]}"
            return 0
        fi
        err "There is no tunnel #$in (1-${#names[@]})"
        return 1
    fi
    lin=$(printf '%s' "$in" | tr 'A-Z' 'a-z')
    for n in "${names[@]}"; do
        [[ "$(printf '%s' "$n" | tr 'A-Z' 'a-z')" == *"$lin"* ]] && hits+=("$n")
    done
    case ${#hits[@]} in
        0) err "No tunnel matches '$in'"; return 1 ;;
        1) [ -t 1 ] && note "→ ${hits[0]}"
           printf -v "$__mv" '%s' "${hits[0]}"; return 0 ;;
        *) err "'$in' matches ${#hits[@]} tunnels: ${hits[*]} — be more specific"; return 1 ;;
    esac
}

# pick_tunnel <var> <filter> — filter: all | up | startable | stoppable
pick_tunnel() {
    local __var="$1" filter="$2" names=() all=() n sel i
    while read -r n; do [ -n "$n" ] && all+=("$n"); done < <(list_tunnels)
    for n in "${all[@]}"; do
        case "$filter" in
            up)        is_up "$n" || continue ;;
            startable) is_up "$n" && is_enabled "$n" && continue ;;
            stoppable) ! is_up "$n" && ! is_enabled "$n" && continue ;;
        esac
        names+=("$n")
    done

    if [ ${#names[@]} -eq 0 ]; then
        case "$filter" in
            up)        warn "No tunnels are up — start one with: enable" ;;
            startable) warn "All tunnels are already up and enabled" ;;
            stoppable) warn "All tunnels are already off" ;;
            *)         warn "No tunnels yet — add one first" ;;
        esac
        return 1
    fi

    # شماره‌ها همون شماره‌های جدول اصلی‌ان (حتی وقتی فقط بعضی نشون داده میشن)
    for n in "${names[@]}"; do
        i=1
        while [ "${all[$((i - 1))]}" != "$n" ]; do i=$((i + 1)); done
        tunnel_state "$n"
        printf "    %b%2d)%b %-15s %b%s%b\n" "$BOLD" "$i" "$NC" "$n" "$ST_C" "$ST" "$NC"
    done
    [ "${PICK_ALLOW_ALL:-}" = 1 ] && printf "    %b a)%b %s\n" "$BOLD" "$NC" "all of them"

    while true; do
        prompt sel "Tunnel (number or part of the name, Enter = cancel)" || return 1
        if [ "${PICK_ALLOW_ALL:-}" = 1 ] && { [ "$sel" = a ] || [ "$sel" = all ]; }; then
            printf -v "$__var" '%s' all
            return 0
        fi
        match_tunnel "$__var" "$sel" && return 0
    done
}

# اسم از آرگومان (کامل، شماره، یا بخشی از اسم)، وگرنه از لیست انتخاب
resolve_target() {
    local __var="$1" filter="$2" given="$3"
    if [ -n "$given" ]; then
        # ورودی از اسکریپت (نه ترمینال) → فقط اسم کامل، که اشتباهی تونل دیگه‌ای انتخاب نشه
        if [ -t 0 ]; then match_tunnel "$__var" "$given"; else match_tunnel "$__var" "$given" exact; fi
        return
    fi
    if [ ! -t 0 ]; then
        err "Tunnel name required"
        return 1
    fi
    pick_tunnel "$__var" "$filter"
}

# چند تونل: "all"، لیست با کاما ("1,3,5" یا "fra,nyc")، یا یکی → TARGETS
resolve_targets() {
    local filter="$1" given="$2" n one part
    TARGETS=()
    if [ "$given" = all ]; then
        while read -r n; do
            [ -z "$n" ] && continue
            case "$filter" in
                up)        is_up "$n" || continue ;;
                startable) is_up "$n" && is_enabled "$n" && continue ;;
                stoppable) ! is_up "$n" && ! is_enabled "$n" && continue ;;
            esac
            TARGETS+=("$n")
        done < <(list_tunnels)
        [ ${#TARGETS[@]} -gt 0 ] || { warn "No matching tunnels"; return 1; }
        return 0
    fi
    if [[ "$given" == *,* ]]; then
        for part in ${given//,/ }; do
            resolve_target one "$filter" "$part" || return 1
            TARGETS+=("$one")
        done
        return 0
    fi
    resolve_target one "$filter" "$given" || return 1
    TARGETS=("$one")
}

# ════════════════════════════════════════════════
#  CMD: add — پیست کانفیگ / فایل / دستی
# ════════════════════════════════════════════════
read_pasted() {
    local out="$1" line n=0
    echo -e "  ${DIM}Paste the whole config, then type ${NC}${BOLD}END${NC}${DIM} on a new line (or press Ctrl+D):${NC}"
    : > "$out"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*END[[:space:]]*$ ]] && break
        printf '%s\n' "$line" >> "$out"
        n=$((n + 1))
    done
    if [ "$n" -eq 0 ]; then
        warn "Nothing pasted"
        return 1
    fi
}

build_manual() {
    local out="$1" addr pk pub ep
    prompt addr "Interface address (e.g. 10.0.0.2/32)" "" v_address || return 1
    while true; do
        read -r -s -p "$(printf '  %b?%b Private key (Enter = generate a new one): ' "$BLUE" "$NC")" pk || return 1
        echo ""
        pk=$(trim "$pk")
        if [ -z "$pk" ]; then
            pk=$(wg genkey)
            ok "New key pair generated"
            note "Public key (give this to the peer): $(echo "$pk" | wg pubkey)"
            break
        fi
        v_key "$pk" && break
    done
    prompt pub "Peer public key" "" v_key      || return 1
    prompt ep  "Endpoint (IP:PORT)" "" v_endpoint || return 1

    cat > "$out" <<EOF
[Interface]
PrivateKey = $pk
Address = $addr
Table = off

[Peer]
PublicKey = $pub
Endpoint = $ep
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}

# اسم پیش‌فرض: از اسم فایل، وگرنه wg1, wg2, ...
suggest_name() {
    local src="$1" n i
    if [ -n "$src" ]; then
        n=$(basename "$src" | sed -E 's/\.conf$//; s/[^a-zA-Z0-9_=+.-]/-/g' | cut -c1-15)
        if [ -n "$n" ] && [ ! -f "$(cfg_path "$n")" ] && ! ip link show "$n" &>/dev/null; then
            echo "$n"
            return
        fi
    fi
    for ((i = 1; i < 1000; i++)); do
        if [ ! -f "$(cfg_path "wg$i")" ] && ! ip link show "wg$i" &>/dev/null; then
            echo "wg$i"
            return
        fi
    done
}

# cmd_add [paste|file|manual] [file] [name]
# ورودی گرفتن (paste/ادیتور/سوال‌ها) بدون قفل انجام میشه تا watchdog بلاک نشه؛
# فقط مرحله ذخیره و بالا آوردن قفل میگیره
cmd_add() {
    local mode="${1:-}" src="${2:-}" name="${3:-}" tmp rc
    new_tmp tmp || { err "Could not create a temp file in $RUN_DIR"; return 1; }
    _add "$mode" "$src" "$name" "$tmp"
    rc=$?
    rm -f "$tmp"
    unlock
    return $rc
}

_add() {
    local mode="$1" src="$2" name="$3" tmp="$4" choice t def_t cfg n
    header "Add Tunnel"

    # اسم از آرگومان → قبل از پیست چک بشه
    if [ -n "$name" ]; then
        v_new_name "$name" || return 1
    fi

    if [ -z "$mode" ]; then
        echo -e "    ${BOLD}1)${NC} Paste config text   ${GREEN}(fastest)${NC}"
        echo -e "    ${BOLD}2)${NC} Config file on this server"
        echo -e "    ${BOLD}3)${NC} Enter fields one by one"
        echo -e "    ${BOLD}4)${NC} Many Mullvad configs at once ${DIM}(.zip or folder)${NC}"
        echo ""
        prompt choice "Method" "1" v_menu_1_4 || return 1
        case "$choice" in 1) mode=paste ;; 2) mode=file ;; 3) mode=manual ;; 4) mode=bulk ;; esac
        echo ""
    fi

    case "$mode" in
        bulk)
            [ -n "$src" ] || prompt src "Path to the Mullvad .zip or folder" || return 1
            cmd_import_bulk "$src"
            return
            ;;
        paste)
            read_pasted "$tmp" || return 1
            ;;
        file)
            while [ ! -f "$src" ]; do
                [ -n "$src" ] && err "File not found: $src"
                src=""
                prompt src "Path to .conf file" || return 1
            done
            cp "$src" "$tmp"
            ;;
        manual)
            build_manual "$tmp" || return 1
            ;;
    esac

    sanitize_config "$tmp"
    if ! check_config "$tmp"; then
        note "Nothing was saved."
        return 1
    fi
    echo ""
    ok "Config looks valid"
    for n in "${SANITIZE_NOTES[@]}"; do note "• $n"; done
    echo ""

    if [ -z "$name" ]; then
        prompt name "Tunnel name" "$(suggest_name "$src")" v_new_name || return 1
    fi

    # اگه کانفیگ از قبل table داشت (مثلاً بکاپ) و آزاده، همونو پیشنهاد بده
    def_t=$(meta_get "$tmp" Table-ID)
    if [ -z "$def_t" ] || ! v_table "$def_t" 2>/dev/null; then
        def_t=$(free_table)
    fi
    prompt t "Table ID / Xray mark" "$def_t" v_table || return 1

    echo ""
    echo -e "  ${BOLD}Summary${NC}"
    note "Name     : $name"
    note "Address  : $(conf_get_all "$tmp" Address | paste -sd, -)"
    note "Endpoint : $(conf_get "$tmp" Endpoint)"
    note "Mark     : $t"
    echo ""
    confirm "Save and start $name?" y || { warn "Cancelled — nothing saved"; return 1; }

    lock || return 1
    # شاید وقتی منتظر جواب بودیم یه نفر دیگه همین اسم یا table رو گرفته باشه
    v_new_name "$name" && v_table "$t" || { note "Nothing was saved."; return 1; }
    meta_set "$tmp" Table-ID "$t"
    meta_set "$tmp" Enabled yes
    cfg=$(cfg_path "$name")
    install -m 600 "$tmp" "$cfg"
    ok "Saved: $cfg"
    log_file "$name added | table $t"

    if ! tunnel_up "$name"; then
        unlock
        warn "Saved, but the tunnel did not start. Fix it with: wg-manager edit $name"
        return 1
    fi
    unlock
    test_tunnel "$name"
    print_xray_hint "$name" "$t"
    [ -f "$SERVICE_FILE" ] || { echo ""; warn "Auto-start service is not installed — run: wg-manager install"; }
    networkd_banner
    return 0
}

# ════════════════════════════════════════════════
#  CMD: enable / disable / restart / test
# ════════════════════════════════════════════════
tunnel_mark() { meta_get "$(cfg_path "$1")" Table-ID; }

# NO_TEST=1 → بعد از بالا اومدن تست کامل اجرا نمیشه (منو: فقط handshake چک میشه)
quick_check() {
    if handshake_fresh "$1"; then ok "$1: handshake OK"; else warn "$1: no handshake yet — check with: wg-manager test $1"; fi
}

# enable / disable / restart قبول میکنن: اسم، شماره، بخشی از اسم، "1,3" ، و (restart) "all"
cmd_enable() {
    local name rc=0
    header "Enable Tunnel"
    resolve_targets startable "$1" || return 1
    for name in "${TARGETS[@]}"; do
        meta_set "$(cfg_path "$name")" Enabled yes
        if ! tunnel_up "$name"; then rc=1; continue; fi
        # اتصال‌هایی که وقتی تونل پایین بود از IP سرور رفتن بسته میشن تا از تونل وصل بشن
        flush_conntrack_mark "$(tunnel_mark "$name")"
        ok "$name will also start after reboot"
        if [ ${#TARGETS[@]} -eq 1 ] && [ "${NO_TEST:-}" != 1 ]; then test_tunnel "$name"; else quick_check "$name"; fi
    done
    return $rc
}

cmd_disable() {
    local name t rc=0
    header "Disable Tunnel"
    resolve_targets stoppable "$1" || return 1
    for name in "${TARGETS[@]}"; do
        t=$(tunnel_mark "$name")
        meta_set "$(cfg_path "$name")" Enabled no
        tunnel_stop "$name" || { rc=1; continue; }
        ok "$name stays off after reboot ${DIM}(turn it back on with 'enable')${NC}"
        [[ "$t" =~ ^[0-9]+$ ]] && warn "Xray outbounds with mark $t now exit via the server IP"
        log_file "$name disabled"
    done
    return $rc
}

cmd_restart() {
    local name rc=0
    header "Restart Tunnel"
    PICK_ALLOW_ALL=1 resolve_targets all "$1" || return 1
    [ "${TARGETS[0]}" = all ] && { resolve_targets all all || return 1; }
    for name in "${TARGETS[@]}"; do
        if ! tunnel_up "$name"; then rc=1; continue; fi
        flush_conntrack_mark "$(tunnel_mark "$name")"
        if [ ${#TARGETS[@]} -eq 1 ] && [ "${NO_TEST:-}" != 1 ]; then test_tunnel "$name"; else quick_check "$name"; fi
    done
    return $rc
}

cmd_test() {
    local name
    header "Test Tunnel"
    if [ "$1" = all ]; then
        test_all
        return
    fi
    PICK_ALLOW_ALL=1 resolve_targets up "$1" || return 1
    if [ "${TARGETS[0]}" = all ]; then
        test_all
    elif [ ${#TARGETS[@]} -gt 1 ]; then
        test_all "${TARGETS[@]}"
    else
        test_tunnel "${TARGETS[0]}" full
    fi
}

# backup_save <file> <name> — یه نسخه توی BACKUP_DIR. اسم همیشه یکتاست
# (دو بکاپ توی یه ثانیه همدیگه رو پاک نمیکنن)
backup_save() {
    local base dest i=1
    base="$BACKUP_DIR/$2.conf.$(date +%Y%m%d%H%M%S)"
    dest="$base"
    while [ -e "$dest" ]; do dest="$base.$i"; i=$((i + 1)); done
    cp "$1" "$dest"
}

# فقط BACKUP_KEEP نسخه آخر هر تونل توی پوشه بکاپ میمونه (هر کدوم کلید خصوصی دارن)
prune_backups() {
    local name="$1" f n=0
    while read -r f; do
        n=$((n + 1))
        [ "$n" -gt "$BACKUP_KEEP" ] && rm -f "$f"
    done < <(ls -1t "$BACKUP_DIR/$name".conf.* 2>/dev/null)
}

# ════════════════════════════════════════════════
#  CMD: edit
# ════════════════════════════════════════════════
cmd_edit() {
    local name cfg tmp orig editor t old_t was_up n rc=1
    header "Edit Tunnel"
    resolve_target name all "$1" || return 1
    cfg=$(cfg_path "$name")

    editor="${EDITOR:-}"
    if [ -z "$editor" ]; then
        command -v nano &>/dev/null && editor=nano || editor=vi
    fi

    # ادیتور بدون قفل باز میشه (watchdog در این مدت کارش رو میکنه)
    new_tmp tmp && new_tmp orig || { err "Could not create a temp file in $RUN_DIR"; return 1; }
    cp "$cfg" "$tmp"
    cp "$cfg" "$orig"
    old_t=$(meta_get "$cfg" Table-ID)
    while true; do
        $editor "$tmp"
        if cmp -s "$tmp" "$cfg"; then
            ok "No changes"
            return 0
        fi
        sanitize_config "$tmp"
        t=$(meta_get "$tmp" Table-ID)
        if check_config "$tmp" && TABLE_SELF="$name" v_table "$t"; then
            break
        fi
        if ! confirm "Edit again? (No = discard changes)" y; then
            warn "Changes discarded"
            return 1
        fi
    done
    for n in "${SANITIZE_NOTES[@]}"; do note "• $n"; done

    lock || return 1
    if ! cmp -s "$orig" "$cfg"; then
        unlock
        err "$name was changed by something else while you were editing — nothing saved"
        return 1
    fi

    was_up=0
    is_up "$name" && was_up=1
    [ "$was_up" = 1 ] && tunnel_stop "$name" >/dev/null   # با table قدیمی پاک کن
    # mark عوض شده → شمارنده leak قدیمی دیگه معنی نداره
    [[ "$old_t" =~ ^[0-9]+$ ]] && [ "$old_t" != "$t" ] && leak_rules_del "$name" "$old_t"

    backup_save "$cfg" "$name"
    prune_backups "$name"
    install -m 600 "$tmp" "$cfg"
    ok "Saved ${DIM}(previous version in $BACKUP_DIR)${NC}"
    log_file "$name edited"

    if [ "$was_up" = 1 ] || is_enabled "$name"; then
        if tunnel_up "$name"; then
            flush_conntrack_mark "$t"
            unlock
            test_tunnel "$name" && rc=0
        fi
    else
        rc=0
    fi
    unlock
    return $rc
}

# ════════════════════════════════════════════════
#  CMD: delete
# ════════════════════════════════════════════════
cmd_delete() {
    local name cfg dest t
    header "Delete Tunnel"
    # کار خطرناک: از آرگومان فقط اسم کامل قبوله (نه شماره یا بخشی از اسم)
    if [ -n "$1" ]; then match_tunnel name "$1" exact || return 1
    else resolve_target name all "" || return 1; fi
    cfg=$(cfg_path "$name")
    t=$(meta_get "$cfg" Table-ID)
    [[ "$t" =~ ^[0-9]+$ ]] && note "Xray outbounds with mark $t will exit via the server IP afterwards"
    confirm "Delete '$name'? (config is moved to $BACKUP_DIR)" n || { warn "Cancelled"; return 1; }

    lock || return 1
    if ip link show "$name" &>/dev/null; then
        tunnel_stop "$name" || { unlock; return 1; }
    elif [[ "$t" =~ ^[0-9]+$ ]]; then
        clear_routing "$name" "$t"
    fi
    [[ "$t" =~ ^[0-9]+$ ]] && leak_rules_del "$name" "$t"

    dest="$BACKUP_DIR/$name.conf.deleted.$(date +%Y%m%d%H%M%S)"
    mv "$cfg" "$dest"
    prune_backups "$name"
    systemctl disable "wg-quick@$name" &>/dev/null
    [ -f "/etc/wireguard/$name.conf" ] && mv "/etc/wireguard/$name.conf" "$dest.etc"
    rm -f "$STATE_DIR/test-$name" 2>/dev/null
    unlock
    ok "$name deleted ${DIM}(backup: $dest)${NC}"
    log_file "$name deleted"
}

# ════════════════════════════════════════════════
#  CMD: status / logs
# ════════════════════════════════════════════════
cmd_status() {
    local rules
    if [ "$JSON" = 1 ]; then
        cmd_status_json
        return
    fi
    header "Tunnels"
    print_tunnel_table
    echo ""
    echo -e "  ${DIM}Auto-start:${NC} $(service_state)   ${DIM}Watchdog:${NC} $(watchdog_state)"
    networkd_banner

    if [ "$VERBOSE" = 1 ]; then
        echo ""
        echo -e "  ${BOLD}${CYAN}Routing rules${NC}"
        hr
        rules=$(ip rule show 2>/dev/null | grep -E '^[12][0-9]{3}:')
        has_ipv6 && rules="$rules"$'\n'$(ip -6 rule show 2>/dev/null | grep -E '^[12][0-9]{3}:' | sed 's/^/[v6] /')
        echo "$rules" | sed '/^$/d; s/^/  /'
        echo ""
        echo -e "  ${BOLD}${CYAN}NAT rules${NC}"
        hr
        iptables -t nat -S POSTROUTING 2>/dev/null | grep MASQUERADE | sed 's/^/  /'
        echo ""
        echo -e "  ${BOLD}${CYAN}Recent log${NC}"
        hr
        [ -f "$LOG_FILE" ] && tail -8 "$LOG_FILE" | sed 's/^/  /'
    else
        note "More detail: wg-manager status -v"
    fi
    echo ""
}

cmd_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        warn "No log yet ($LOG_FILE)"
        return 0
    fi
    if [ "${1:-}" = "-f" ]; then
        tail -n 30 -f "$LOG_FILE"
    else
        header "Log ($LOG_FILE)"
        tail -n 30 "$LOG_FILE" | sed 's/^/  /'
        echo ""
        note "Follow live: wg-manager logs -f   •   Boot log: journalctl -u wg-manager"
    fi
}

d_ok()    { [ "$QUIET" = 1 ] || ok "$1"; }
d_info()  { [ "$QUIET" = 1 ] || note "$1"; }
d_bad()   { DOC_BAD=$((DOC_BAD + 1)); warn "$1"; [ "$QUIET" = 1 ] && log_file "doctor: $1"; }
d_note()  { warn "$1"; [ "$QUIET" = 1 ] && log_file "doctor: $1"; }     # گزارش، بدون شمردن به عنوان مشکل
d_fixed() { ok "  fixed: $1"; log_file "doctor: fixed — $1"; }
d_fail()  { DOC_UNFIXED=$((DOC_UNFIXED + 1)); err "  not fixed: $1"; log_file "doctor: not fixed — $1"; }

# ── کمکی‌های watchdog ───────────────────────────
WATCHDOG_STAMP="$RUN_DIR/watchdog-last"
# ثانیه از آخرین اجرای watchdog (خالی = از بوت تا حالا اجرا نشده)
watchdog_age() {
    local s
    s=$(cat "$WATCHDOG_STAMP" 2>/dev/null)
    [[ "$s" =~ ^[0-9]+$ ]] && echo $(($(date +%s) - s))
}
uptime_s() { awk '{ print int($1) }' /proc/uptime 2>/dev/null; }

# backoff: ری‌استارت کامل هر تونل حداکثر هر RESTART_BACKOFF ثانیه یه بار
restart_allowed() {
    local s
    s=$(cat "$RUN_DIR/restart-$1" 2>/dev/null)
    [[ "$s" =~ ^[0-9]+$ ]] || return 0
    [ $(($(date +%s) - s)) -ge "$RESTART_BACKOFF" ]
}
restart_mark() { mkdir -p "$RUN_DIR" && date +%s > "$RUN_DIR/restart-$1"; }

# peer رو همون‌جا دوباره تنظیم کن (endpoint دوباره resolve میشه). rule ها دست
# نمیخورن → برخلاف ری‌استارت، هیچ لحظه‌ای ترافیک از IP سرور نمیره
peer_reset() {
    local name="$1" cfg pub ep
    cfg="$RUN_DIR/$name.conf"
    [ -f "$cfg" ] || cfg=$(cfg_path "$name")
    pub=$(conf_get "$cfg" PublicKey)
    ep=$(conf_get "$cfg" Endpoint)
    [ -n "$pub" ] && [ -n "$ep" ] || return 1
    wg set "$name" peer "$pub" endpoint "$ep" 2>/dev/null
}

# ── sysctl: all.disable_ipv6=1 ──────────────────
# این پیش‌فرض لینوکس نیست؛ بعضی اسکریپت‌های نصب اضافه‌ش میکنن. هر بار که
# 'sysctl --system' اجرا بشه (مثلاً آپدیت procps/systemd) آدرس IPv6 همه
# اینترفیس‌ها پاک میشه، از جمله تونل‌ها و کارت شبکه اصلی
sysctl_all_v6_files() {
    grep -lsE '^[[:space:]]*net[./]ipv6[./]conf[./]all[./]disable_ipv6[[:space:]]*=[[:space:]]*1' \
        /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null
}

# فقط همون یه خط comment میشه (بکاپ توی BACKUP_DIR). default و lo دست نمیخورن
fix_sysctl_all_v6() {
    local f rc=0
    for f in $(sysctl_all_v6_files); do
        case "$f" in
            /etc/*)
                cp "$f" "$BACKUP_DIR/$(basename "$f").$(date +%Y%m%d%H%M%S)"
                if sed -i -E 's@^([[:space:]]*net[./]ipv6[./]conf[./]all[./]disable_ipv6[[:space:]]*=)@# disabled by wg-manager: \1@' "$f"; then
                    ok "Commented out all.disable_ipv6 in $f ${DIM}(backup in $BACKUP_DIR)${NC}"
                    log_file "sysctl: commented out all.disable_ipv6 in $f"
                else
                    err "Could not edit $f"; rc=1
                fi
                ;;
            *)
                warn "$f belongs to a package — override it with a file of the same name in /etc/sysctl.d/ without that line"
                rc=1
                ;;
        esac
    done
    return $rc
}

# ════════════════════════════════════════════════
#  CMD: doctor — چک (و با --fix تعمیر) همه چیز
#  watchdog هر ۵ دقیقه و بعد از هر ری‌استارت networkd اینو با --fix -q اجرا میکنه
# ════════════════════════════════════════════════
cmd_doctor() {
    local n t hs st age files f running=0 i
    local up=() stale=() still=()
    DOC_BAD=0; DOC_UNFIXED=0

    if [ "$QUIET" != 1 ]; then
        [ "$DOC_FIX" = 1 ] && header "Doctor (repair)" || header "Doctor"
        echo -e "  ${BOLD}System${NC}"
        st=$(networkd_status)
        case "$st" in
            none)    d_ok "systemd-networkd not in use" ;;
            ok)      d_ok "systemd-networkd keeps the tunnel rules" ;;
            old)     d_info "systemd < 249: networkd can't be told to keep rules — the watchdog re-adds them" ;;
            unsafe)  d_bad "systemd-networkd deletes tunnel rules whenever it restarts (e.g. during updates)" ;;
            pending) d_bad "systemd-networkd fix is saved but networkd has not restarted yet" ;;
        esac
        if [ "$DOC_FIX" = 1 ] && { [ "$st" = unsafe ] || [ "$st" = pending ]; }; then
            ensure_networkd || DOC_UNFIXED=$((DOC_UNFIXED + 1))
        fi

        if [ -f "$SERVICE_FILE" ] && systemctl is-enabled wg-manager.service &>/dev/null; then
            d_ok "Auto-start on boot: on"
        else
            d_bad "Auto-start on boot is not installed — run: wg-manager install"
            DOC_UNFIXED=$((DOC_UNFIXED + 1))
        fi

        if systemctl is-enabled wg-manager-watchdog.timer &>/dev/null; then
            age=$(watchdog_age)
            if [ -n "$age" ] && [ "$age" -le 900 ]; then
                d_ok "Watchdog: on, last run $(fmt_age "$age") ago"
            elif [ -n "$age" ]; then
                d_bad "Watchdog has not run for $(fmt_age "$age") — check: systemctl status wg-manager-watchdog.timer"
                DOC_UNFIXED=$((DOC_UNFIXED + 1))
            elif [ "$(uptime_s)" -gt 900 ] && ! systemctl is-active --quiet wg-manager-watchdog.timer; then
                d_bad "Watchdog timer is enabled but not running — check: systemctl status wg-manager-watchdog.timer"
                DOC_UNFIXED=$((DOC_UNFIXED + 1))
            else
                d_ok "Watchdog: on (no run recorded yet — it runs every 5 min)"
            fi
        else
            d_bad "Watchdog is not installed — run: wg-manager install"
            DOC_UNFIXED=$((DOC_UNFIXED + 1))
        fi

        if [ -f "$SERVICE_FILE" ] && ! grep -qF "wg-manager v$VERSION" "$SERVICE_FILE" "$WATCHDOG_SERVICE" 2>/dev/null; then
            d_bad "Boot service / watchdog files are from an older version — run: wg-manager install"
            DOC_UNFIXED=$((DOC_UNFIXED + 1))
        fi
        if schema_pending; then
            d_bad "Upgrade steps are pending — run: wg-manager install"
            DOC_UNFIXED=$((DOC_UNFIXED + 1))
        fi

        files=$(has_ipv6 && sysctl_all_v6_files)
        if [ -n "$files" ]; then
            for f in $files; do
                d_bad "$f sets all.disable_ipv6=1 — every 'sysctl --system' (e.g. package updates) removes IPv6 from all interfaces, tunnels included"
            done
            if [ "$DOC_FIX" = 1 ]; then
                note "Only that line is commented out; 'default' and 'lo' stay, so nothing changes until the next sysctl run."
                if confirm "Comment out all.disable_ipv6 now?" y && fix_sysctl_all_v6; then
                    :
                else
                    DOC_UNFIXED=$((DOC_UNFIXED + 1))
                fi
            fi
        else
            d_ok "sysctl: nothing removes IPv6 from the tunnels"
        fi
        echo ""
        echo -e "  ${BOLD}Tunnels${NC}"
    fi

    # ── ۱) هر تونل: بالا بودن، routing، leak ──
    for n in $(list_tunnels); do
        t=$(tunnel_mark "$n")

        if ! is_up "$n"; then
            if ! is_enabled "$n"; then
                d_info "$n: off${t:+ — Xray outbounds with mark $t exit via the server IP}"
                continue
            fi
            if [ -f "$PAUSE_FLAG" ]; then d_info "$n: down (paused by down-all)"; continue; fi
            d_bad "$n: enabled but down"
            if [ "$DOC_FIX" = 1 ]; then
                if tunnel_up "$n" >/dev/null 2>&1; then
                    flush_conntrack_mark "$t"
                    d_fixed "$n started"
                else
                    d_fail "$n did not start — try: wg-manager restart $n"
                fi
            fi
            is_up "$n" || continue
        fi
        running=1

        if ! [[ "$t" =~ ^[0-9]+$ ]]; then
            d_bad "$n: no valid Table-ID — fix with: wg-manager edit $n"
            DOC_UNFIXED=$((DOC_UNFIXED + 1))
            continue
        fi

        # routing — فقط rule ها دوباره ساخته میشن. تونل فقط وقتی ری‌استارت میشه که
        # واقعاً لازمه (آدرس IPv6 از روی اینترفیس پاک شده)
        if check_routing "$n" "$t"; then
            d_ok "$n: routing OK (mark $t)"
        else
            for i in "${ROUTE_ISSUES[@]}"; do d_bad "$n: $i"; done
            if [ "$DOC_FIX" = 1 ]; then
                if apply_routing "$n" "$t" >/dev/null 2>&1 && check_routing "$n" "$t"; then
                    flush_conntrack_mark "$t"      # اتصال‌هایی که این مدت از IP سرور رفتن
                    d_fixed "$n routing re-applied"
                elif [ "$ROUTE_NEED_RESTART" = 1 ] && tunnel_up "$n" >/dev/null 2>&1 && check_routing "$n" "$t"; then
                    flush_conntrack_mark "$t"
                    d_fixed "$n restarted, routing OK"
                else
                    d_fail "$n routing: ${ROUTE_ISSUES[*]:-tunnel did not start}"
                fi
            fi
        fi
        # IPv6 آدرس داره ولی AllowedIPs رنج IPv6 نداره → IPv6 کار نمیکنه (فقط گزارش)
        if [ "$QUIET" != 1 ] && conf_get_all "$(cfg_path "$n")" Address | grep -q ':' && \
           ! conf_get_all "$(cfg_path "$n")" AllowedIPs | grep -q ':'; then
            d_bad "$n: has an IPv6 address but AllowedIPs has no IPv6 range — add ::/0 (wg-manager edit $n)"
            DOC_UNFIXED=$((DOC_UNFIXED + 1))
        fi
        is_up "$n" || continue   # ری‌استارت ناموفق بود؛ دور بعد دوباره امتحان میشه

        # فقط وقتی rule های خودمون سالمن معنی داره
        if check_routing "$n" "$t" && ! marked_route_ok "$n" "$t"; then
            d_bad "$n: traffic with mark $t does not reach $n — another rule has priority (see: ip rule show)"
            DOC_UNFIXED=$((DOC_UNFIXED + 1))
        fi

        # شمارنده leak: watchdog مبدأ رو جلو میبره، doctor دستی فقط نگاه میکنه
        if [ "$QUIET" = 1 ]; then leak_since_check "$t" save; else leak_since_check "$t"; fi
        if [ "$LEAK_NEW_PKTS" -gt 0 ]; then
            d_note "$n: $LEAK_NEW_PKTS packets ($(fmt_bytes "$LEAK_NEW_BYTES")) with mark $t left via the server IP since the last watchdog check"
        fi
        up+=("$n")
    done

    # ── ۲) handshake — همه با هم. اول فقط یه کم ترافیک (شاید فقط بیکار بودن) ──
    for n in "${up[@]}"; do
        hs=$(latest_handshake "$n")
        if [ "${hs:-0}" -gt 0 ] && [ $(($(date +%s) - hs)) -le "$HANDSHAKE_STALE" ]; then
            d_ok "$n: handshake $(fmt_age $(($(date +%s) - hs))) ago"
        else
            ping -c 1 -W 2 -I "$n" 1.1.1.1 &>/dev/null &
            stale+=("$n")
        fi
    done
    if [ ${#stale[@]} -gt 0 ]; then
        spin_start "waiting for handshakes…"
        sleep 6      # WireGuard هر ۵ ثانیه دوباره handshake رو امتحان میکنه
        spin_stop    # قبل از wait (وگرنه wait منتظر spinner هم میمونه)
        wait
        for n in "${stale[@]}"; do
            hs=$(latest_handshake "$n")
            if [ "${hs:-0}" -gt 0 ] && [ $(($(date +%s) - hs)) -le "$HANDSHAKE_STALE" ]; then
                d_ok "$n: handshake $(fmt_age $(($(date +%s) - hs))) ago (was idle)"
            else
                still+=("$n")
            fi
        done
    fi

    if [ ${#still[@]} -ge 2 ] && [ ${#still[@]} -eq ${#up[@]} ]; then
        # همه با هم → مشکل از تونل‌ها نیست؛ ری‌استارت فقط leak کوتاه پشت سر هم میسازه
        d_bad "All ${#up[@]} tunnels have no handshake — usually the Mullvad account/key, DNS or this server's internet, not the tunnels"
        if [ "$DOC_FIX" = 1 ]; then
            for n in "${still[@]}"; do peer_reset "$n"; done
            d_fail "not restarting the tunnels (it would not help) — check the Mullvad account and the server's network"
        fi
    else
        for n in "${still[@]}"; do
            hs=$(latest_handshake "$n")
            [ "${hs:-0}" -gt 0 ] && age="$(fmt_age $(($(date +%s) - hs))) ago" || age="never"
            d_bad "$n: no recent handshake (last: $age)"
            [ "$DOC_FIX" = 1 ] || continue

            # اول بدون ری‌استارت: peer دوباره تنظیم میشه
            if peer_reset "$n" && handshake_fresh "$n"; then
                d_fixed "$n: handshake is back after re-setting the peer (no restart needed)"
                continue
            fi
            if ! restart_allowed "$n"; then
                d_fail "$n: Mullvad server is not answering; restarted less than $((RESTART_BACKOFF / 60)) min ago — waiting"
                continue
            fi
            restart_mark "$n"
            if tunnel_up "$n" >/dev/null 2>&1; then
                flush_conntrack_mark "$(tunnel_mark "$n")"
                if handshake_fresh "$n"; then
                    d_fixed "$n restarted, handshake OK"
                else
                    d_fail "$n restarted but the Mullvad server is not answering (next restart in $((RESTART_BACKOFF / 60)) min at the earliest)"
                fi
            else
                d_fail "$n could not be restarted"
            fi
        done
    fi

    # heartbeat: status/doctor نشون میدن watchdog آخرین بار کی اجرا شده
    if [ "$QUIET" = 1 ]; then
        mkdir -p "$RUN_DIR" && date +%s > "$WATCHDOG_STAMP"
        return $(( DOC_FIX == 1 ? (DOC_UNFIXED > 0) : (DOC_BAD > 0) ))
    fi

    echo ""
    hr
    if [ "$DOC_BAD" -eq 0 ]; then
        ok "${BOLD}Everything looks good${NC}"
        return 0
    fi
    if [ "$DOC_FIX" = 1 ]; then
        if [ "$DOC_UNFIXED" -eq 0 ]; then ok "${BOLD}All problems fixed${NC}"; return 0; fi
        err "$DOC_UNFIXED problem(s) need your attention (see above)"
        return 1
    fi
    warn "$DOC_BAD problem(s) found"
    if [ -t 0 ]; then
        # موقع منتظر جواب موندن قفل آزاد باشه تا watchdog بلاک نشه
        unlock
        if confirm "Fix them now?" y; then
            lock || return 1
            DOC_FIX=1 cmd_doctor
            return $?
        fi
    fi
    note "Fix later with: wg-manager doctor --fix"
    return 1
}

# ════════════════════════════════════════════════
#  CMD: up-all — فقط تونل‌های enable (برای بوت)
# ════════════════════════════════════════════════
cmd_up_all() {
    local names=() failed=() retry=() n attempt ok_count=0
    header "Start All Enabled Tunnels"
    rm -f "$PAUSE_FLAG"
    if [ "$(networkd_status)" = unsafe ]; then
        warn "systemd-networkd may delete tunnel rules later — run: wg-manager install"
        log_file "warning: systemd-networkd may delete tunnel rules — run: wg-manager install"
    fi

    while read -r n; do
        [ -n "$n" ] && is_enabled "$n" && names+=("$n")
    done < <(list_tunnels)

    if [ ${#names[@]} -eq 0 ]; then
        warn "No enabled tunnels"
        return 0
    fi

    failed=("${names[@]}")
    # موقع بوت ممکنه شبکه/DNS هنوز آماده نباشه → چند بار تلاش
    for attempt in 1 2 3 4; do
        retry=()
        for n in "${failed[@]}"; do
            echo -e "  ${CYAN}━━ $n ━━${NC}"
            if tunnel_up "$n"; then
                ok_count=$((ok_count + 1))
            else
                retry+=("$n")
            fi
        done
        failed=("${retry[@]}")
        [ ${#failed[@]} -eq 0 ] && break
        [ "$attempt" -lt 4 ] && { warn "Retrying ${failed[*]} in 5s..."; sleep 5; }
    done

    # اتصال‌هایی که وقتی تونل‌ها پایین بودن از IP سرور رفتن → از تونل دوباره وصل بشن
    for n in "${names[@]}"; do
        is_up "$n" && flush_conntrack_mark "$(tunnel_mark "$n")"
    done
    echo ""
    hr
    if [ ${#failed[@]} -eq 0 ]; then
        ok "${BOLD}Done:${NC} ${GREEN}$ok_count up${NC} / ${#names[@]} enabled"
    else
        err "Done: $ok_count up / ${#names[@]} enabled — failed: ${failed[*]}"
        log_file "up-all failed: ${failed[*]}"
        return 1
    fi
}

# ════════════════════════════════════════════════
#  CMD: down-all — موقت؛ وضعیت enable دست نمیخوره
# ════════════════════════════════════════════════
cmd_down_all() {
    local n count=0
    header "Stop All Tunnels"
    # watchdog تا ریبوت یا up-all بعدی تونل‌ها رو دوباره بالا نمیاره
    mkdir -p "$RUN_DIR" && touch "$PAUSE_FLAG"
    for n in $(list_tunnels); do
        ip link show "$n" &>/dev/null || continue
        tunnel_stop "$n" && count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        warn "No managed tunnels were up"
    else
        note "Temporary — enabled tunnels start again on reboot or with 'up-all'"
    fi
}

# ════════════════════════════════════════════════
#  CMD: status --json — برای اسکریپت‌ها/ربات. بدون شبکه، بدون قفل، بدون کلید خصوصی
# ════════════════════════════════════════════════
json_str()  { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
json_bool() { if [ "$1" = 1 ]; then printf true; else printf false; fi; }

cmd_status_json() {
    local n t first=1 state en hs age rx tx v6 rok ep wd leak autostart=0 watchdog=0
    [ -f "$SERVICE_FILE" ] && systemctl is-enabled wg-manager.service &>/dev/null && autostart=1
    systemctl is-enabled wg-manager-watchdog.timer &>/dev/null && watchdog=1
    wd=$(watchdog_age)
    printf '{"version":%s,"autostart":%s,"watchdog":%s,"watchdog_last_run_age":%s,"networkd":%s,"tunnels":[' \
        "$(json_str "$VERSION")" "$(json_bool "$autostart")" "$(json_bool "$watchdog")" "${wd:-null}" \
        "$(json_str "$(networkd_status)")"
    for n in $(list_tunnels); do
        t=$(tunnel_mark "$n")
        [[ "$t" =~ ^[0-9]+$ ]] || t=null
        en=0; is_enabled "$n" && en=1
        hs=null; rx=0; tx=0; rok=null
        ep=$(conf_get "$(cfg_path "$n")" Endpoint)
        if is_up "$n"; then
            state=up
            ep=$(wg show "$n" endpoints 2>/dev/null | awk 'NR==1 {print $2}')
            age=$(latest_handshake "$n")
            [ "${age:-0}" -gt 0 ] && hs=$(($(date +%s) - age))
            read -r rx tx < <(wg show "$n" transfer 2>/dev/null | awk 'NR==1 {print $2, $3}')
            if [ "$t" != null ]; then
                if routing_ok_quick "$n" "$t"; then rok=true; else rok=false; fi
            fi
        elif [ "$en" = 1 ]; then
            state=down
        else
            state=off
        fi
        v6=0; conf_get_all "$(cfg_path "$n")" Address | grep -q ':' && v6=1
        leak=0
        if [ "$t" != null ]; then leak_read "$t"; leak=$LEAK_PKTS; fi
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"name":%s,"state":%s,"enabled":%s,"mark":%s,"endpoint":%s,"handshake_age":%s,"rx_bytes":%s,"tx_bytes":%s,"ipv6":%s,"routing_ok":%s,"leak_packets_since_boot":%s}' \
            "$(json_str "$n")" "$(json_str "$state")" "$(json_bool "$en")" "$t" "$(json_str "${ep:-}")" \
            "$hs" "${rx:-0}" "${tx:-0}" "$(json_bool "$v6")" "$rok" "${leak:-0}"
    done
    printf ']}\n'
}

# ════════════════════════════════════════════════
#  CMD: backup / restore — همه تونل‌ها توی یه فایل (برای انتقال به سرور دیگه)
# ════════════════════════════════════════════════
cmd_backup() {
    local out="${1:-}" stage dir n count=0
    header "Backup"
    if [ -z "$(list_tunnels)" ]; then warn "No tunnels to back up"; return 1; fi
    [ -n "$out" ] || out="/root/wg-manager-backup-$(hostname -s 2>/dev/null || echo server)-$(date +%Y%m%d-%H%M%S).tar.gz"
    case "$out" in
        /tmp/*|/var/tmp/*) warn "This file holds private keys — /tmp is not a good place for it (use /root)" ;;
    esac
    new_tmp stage dir || { err "Could not create a temp dir in $RUN_DIR"; return 1; }
    dir="$stage/wg-manager-backup"
    mkdir -p "$dir"
    for n in $(list_tunnels); do
        install -m 600 "$(cfg_path "$n")" "$dir/$n.conf" && count=$((count + 1))
    done
    printf 'wg-manager-backup\nversion=%s\nschema=%s\ncreated=%s\ntunnels=%s\n' \
        "$VERSION" "$SCHEMA_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" "$count" > "$dir/MANIFEST"
    # umask 077 → فایل از اول فقط برای root خوندنیه
    if tar -C "$stage" -czf "$out.part" wg-manager-backup && chmod 600 "$out.part" && mv -f "$out.part" "$out"; then
        ok "Saved $count tunnels to ${BOLD}$out${NC}"
        warn "This file contains your WireGuard private keys — keep it private"
        note "Restore on this or another server: wg-manager restore $out"
        log_file "backup: $count tunnels → $out"
    else
        rm -f "$out.part"
        err "Could not write $out"
        return 1
    fi
}

cmd_restore() {
    local file="${1:-}" listing line kind path stage dir f n t cfg action i was_up old_t
    local names=() actions=() marks=() start=() taken=" " count=0
    header "Restore"
    if [ -z "$file" ]; then prompt file "Path to backup file (.tar.gz)" || return 1; fi
    [ -f "$file" ] || { err "File not found: $file"; return 1; }

    # فقط فایل معمولی wg-manager-backup/<name>.conf و MANIFEST قبوله
    # (بدون symlink، بدون ../، بدون مسیر مطلق — فایل دستکاری‌شده نمیتونه جای دیگه‌ای بنویسه)
    listing=$(tar -tvzf "$file" 2>/dev/null) || { err "Not a valid .tar.gz backup"; return 1; }
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        kind=${line:0:1}
        path=${line##* }
        [ "$kind" = d ] && [ "$path" = "wg-manager-backup/" ] && continue
        if [ "$kind" = - ] && { [ "$path" = "wg-manager-backup/MANIFEST" ] || \
             [[ "$path" =~ ^wg-manager-backup/[a-zA-Z0-9_][a-zA-Z0-9_=+.-]{0,14}\.conf$ ]]; }; then
            continue
        fi
        err "Unexpected entry in the archive: $path — refusing to restore"
        return 1
    done <<< "$listing"

    new_tmp stage dir || { err "Could not create a temp dir in $RUN_DIR"; return 1; }
    tar -C "$stage" -xzf "$file" --no-same-owner --no-same-permissions wg-manager-backup 2>/dev/null \
        || { err "Could not extract $file"; return 1; }
    dir="$stage/wg-manager-backup"
    head -1 "$dir/MANIFEST" 2>/dev/null | grep -qx 'wg-manager-backup' || warn "No wg-manager MANIFEST in the archive — restoring anyway"

    # برنامه: new / replace / same — mark تکراری یا نامعتبر → mark جدید
    for f in "$dir"/*.conf; do
        [ -f "$f" ] || continue
        n=$(basename "$f" .conf)
        sanitize_config "$f"            # PostUp/DNS/... از یه فایل دستکاری‌شده هم پاک میشن
        if ! check_config "$f" 2>/dev/null; then warn "$n: incomplete config — skipped"; continue; fi
        cfg=$(cfg_path "$n")
        if [ -f "$cfg" ]; then
            if cmp -s "$f" "$cfg"; then action=same; else action=replace; fi
        elif ip link show "$n" &>/dev/null; then
            warn "$n: a network interface with this name already exists — skipped"
            continue
        else
            action=new
        fi
        t=$(meta_get "$f" Table-ID)
        if ! [[ "$t" =~ ^[0-9]+$ ]] || ! TABLE_SELF="$n" v_table "$t" 2>/dev/null || [[ "$taken" == *" $t "* ]]; then
            t=$(free_table "$taken")
            if [ -z "$t" ]; then warn "$n: no free table ID left — skipped"; continue; fi
            [ "$action" = same ] && action=replace
            action="$action+mark"
        fi
        taken="$taken$t "
        names+=("$n"); actions+=("$action"); marks+=("$t")
    done
    if [ ${#names[@]} -eq 0 ]; then warn "Nothing to restore"; return 1; fi

    echo -e "  ${BOLD}Plan${NC}"
    for i in "${!names[@]}"; do
        case "${actions[$i]}" in
            new)          note "${names[$i]}  →  add (mark ${marks[$i]})" ;;
            replace)      note "${names[$i]}  →  replace (current version is backed up first)" ;;
            same)         note "${names[$i]}  →  unchanged" ;;
            *+mark)       note "${names[$i]}  →  ${actions[$i]%+mark} with NEW mark ${marks[$i]} — update the Xray outbound!" ;;
        esac
    done
    echo ""
    confirm "Apply?" y || { warn "Cancelled — nothing changed"; return 1; }

    lock || return 1
    for i in "${!names[@]}"; do
        [ "${actions[$i]}" = same ] && { is_enabled "${names[$i]}" && start+=("${names[$i]}"); continue; }
        n="${names[$i]}"; t="${marks[$i]}"; f="$dir/$n.conf"; cfg=$(cfg_path "$n")
        meta_set "$f" Table-ID "$t"
        [ -n "$(meta_get "$f" Enabled)" ] || meta_set "$f" Enabled yes
        if [ -f "$cfg" ]; then
            old_t=$(meta_get "$cfg" Table-ID)
            is_up "$n" && tunnel_stop "$n" >/dev/null       # با table قدیمی پاک بشه
            [[ "$old_t" =~ ^[0-9]+$ ]] && [ "$old_t" != "$t" ] && leak_rules_del "$n" "$old_t"
            backup_save "$cfg" "$n"
            prune_backups "$n"
        fi
        install -m 600 "$f" "$cfg"
        count=$((count + 1))
        [ "$(meta_get "$cfg" Enabled)" != no ] && start+=("$n")
    done
    unlock
    ok "Restored $count tunnel(s)"
    log_file "restore: $count tunnels from $file"

    if [ ${#start[@]} -gt 0 ] && confirm "Start the enabled ones now? (${start[*]})" y; then
        lock || return 1
        for n in "${start[@]}"; do
            if is_up "$n" && routing_ok_quick "$n" "$(tunnel_mark "$n")"; then continue; fi
            tunnel_up "$n" && flush_conntrack_mark "$(tunnel_mark "$n")"
        done
        unlock
    fi
    [ -f "$SERVICE_FILE" ] || warn "Auto-start + watchdog are not installed on this server — run: wg-manager install"
}

# ════════════════════════════════════════════════
#  CMD: import (چندتایی) — zip یا پوشه کانفیگ‌های Mullvad
#  تونل جدید → mark آزاد؛ تونلی که از قبل هست → آپدیت (mark و on/off خودش میمونه)
# ════════════════════════════════════════════════
# فقط اسم فایل (بدون مسیر) استخراج میشه → فایل zip نمیتونه بیرون از پوشه موقت بنویسه
PY_UNZIP='
import os, re, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
n = 0
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        if info.is_dir() or info.file_size > 65536:
            continue
        base = os.path.basename(info.filename)
        if not base.lower().endswith(".conf") or not re.match(r"^[A-Za-z0-9_.+=-]+$", base):
            continue
        with z.open(info) as fsrc, open(os.path.join(dst, base), "wb") as fdst:
            fdst.write(fsrc.read())
        n += 1
print(n)
'

# اسم تونل از اسم فایل: mullvad-de-fra-wg-203.conf → de-fra-wg-203
bulk_name() {
    local n
    n=$(basename "$1" | sed -E 's/\.[Cc][Oo][Nn][Ff]$//; s/^[Mm][Uu][Ll][Ll][Vv][Aa][Dd][-_]//' | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9_=+.-]/-/g' | cut -c1-15)
    [[ "$n" =~ $NAME_RE ]] || return 1
    echo "$n"
}

# انتخاب: "all" · "de" (کشور) · "de-fra" (شهر) · اسم کامل · چندتا با کاما
bulk_select() {   # bulk_select <filter> <names...> → اسم‌های انتخاب‌شده (هر کدوم یه خط)
    local filter="$1" n tok
    shift
    for n in "$@"; do
        if [ "$filter" = all ]; then echo "$n"; continue; fi
        for tok in ${filter//,/ }; do
            if [ "$n" = "$tok" ] || [[ "$n" == "$tok"-* ]]; then echo "$n"; break; fi
        done
    done
}

cmd_import_bulk() {
    local src="$1" stage f n t old_t i count=0 filter total
    local names=() sel=() actions=() marks=() start=() names_plan=() taken=" " cc_list shown="" old_en
    header "Import Mullvad configs"
    new_tmp stage dir || { err "Could not create a temp dir in $RUN_DIR"; return 1; }

    if [ -d "$src" ]; then
        find "$src" -maxdepth 1 -type f -name '*.conf' -size -64k -exec cp {} "$stage"/ \; 2>/dev/null
    elif [ -f "$src" ] && [[ "$src" == *.zip ]]; then
        command -v python3 &>/dev/null || { err "python3 is needed to read zip files"; return 1; }
        python3 -I -c "$PY_UNZIP" "$src" "$stage" >/dev/null 2>&1 || { err "Could not read $src (is it a zip file?)"; return 1; }
    else
        err "Give a .zip file or a folder with .conf files"
        return 1
    fi

    # فایل‌ها → اسم‌ها
    for f in "$stage"/*.conf; do
        [ -f "$f" ] || continue
        n=$(bulk_name "$f") || continue
        [ "$f" = "$stage/$n.conf" ] || mv -f "$f" "$stage/$n.conf"
    done
    while read -r n; do [ -n "$n" ] && names+=("$n"); done < <(ls -1 "$stage"/*.conf 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.conf$//' | sort -u)
    total=${#names[@]}
    if [ "$total" -eq 0 ]; then err "No WireGuard .conf files found in $src"; return 1; fi

    # خلاصه بر اساس کشور
    cc_list=$(printf '%s\n' "${names[@]}" | awk -F- 'NF > 2 { c[$1]++ } END { for (k in c) printf "%s %d  ", k, c[k] }')
    ok "$total configs found"
    [ -n "$cc_list" ] && note "by country: $cc_list"

    if [ "$total" -eq 1 ]; then
        filter=all
    else
        echo ""
        note "Pick by country (de), city (de-fra), exact name (de-fra-wg-203), several with commas, or all"
        prompt filter "Which ones" || return 1
    fi
    while read -r n; do [ -n "$n" ] && sel+=("$n"); done < <(bulk_select "$filter" "${names[@]}")
    if [ ${#sel[@]} -eq 0 ]; then warn "Nothing matches '$filter'"; return 1; fi
    [ ${#sel[@]} -gt 20 ] && warn "${#sel[@]} tunnels — each one is a separate tunnel and Xray mark; usually you want a few cities"

    # برنامه
    for n in "${sel[@]}"; do
        f="$stage/$n.conf"
        sanitize_config "$f"
        if ! check_config "$f" 2>/dev/null; then warn "$n: incomplete config — skipped"; continue; fi
        if [ -f "$(cfg_path "$n")" ]; then
            # فقط محتوای WireGuard مقایسه میشه (متادیتای ما توی فایل جدید نیست)
            if diff -q <(grep -v '^# X-' "$(cfg_path "$n")") <(grep -v '^# X-' "$f") >/dev/null 2>&1; then
                actions+=(same); marks+=("$(tunnel_mark "$n")")
            else
                actions+=(update); marks+=("$(tunnel_mark "$n")")
            fi
        elif ip link show "$n" &>/dev/null; then
            warn "$n: a network interface with this name already exists — skipped"
            continue
        else
            t=$(free_table "$taken")
            [ -n "$t" ] || { warn "$n: no free table ID left — skipped"; continue; }
            taken="$taken$t "
            actions+=(new); marks+=("$t")
        fi
        names_plan+=("$n")
    done
    [ ${#names_plan[@]} -gt 0 ] || { warn "Nothing to import"; return 1; }

    echo ""
    echo -e "  ${WHITE}Plan${NC}"
    for i in "${!names_plan[@]}"; do
        case "${actions[$i]}" in
            new)    echo -e "    ${GREEN}+${NC} ${names_plan[$i]}   ${DIM}new · mark ${marks[$i]}${NC}" ;;
            update) echo -e "    ${YELLOW}~${NC} ${names_plan[$i]}   ${DIM}update · keeps mark ${marks[$i]} (old version is backed up)${NC}" ;;
            same)   echo -e "    ${DIM}= ${names_plan[$i]}   unchanged${NC}" ;;
        esac
    done
    echo ""
    confirm "Apply?" y || { warn "Cancelled — nothing changed"; return 1; }

    lock || return 1
    for i in "${!names_plan[@]}"; do
        n="${names_plan[$i]}"; f="$stage/$n.conf"
        case "${actions[$i]}" in
            same) continue ;;
            update)
                meta_set "$f" Table-ID "${marks[$i]}"
                old_en=$(meta_get "$(cfg_path "$n")" Enabled)
                meta_set "$f" Enabled "${old_en:-yes}"
                backup_save "$(cfg_path "$n")" "$n"
                prune_backups "$n"
                is_up "$n" && start+=("$n")
                ;;
            new)
                meta_set "$f" Table-ID "${marks[$i]}"
                meta_set "$f" Enabled yes
                start+=("$n")
                ;;
        esac
        install -m 600 "$f" "$(cfg_path "$n")"
        count=$((count + 1))
        log_file "import: $n ${actions[$i]} (mark ${marks[$i]})"
    done
    unlock
    ok "Imported $count tunnel(s)"

    if [ ${#start[@]} -gt 0 ]; then
        echo ""
        note "y = start them now · n = keep the new ones off (turn each on later with o<#> in the menu)"
        if confirm "Start / restart them now? (${start[*]})" y; then
            lock || return 1
            for n in "${start[@]}"; do
                tunnel_up "$n" && flush_conntrack_mark "$(tunnel_mark "$n")"
            done
            unlock
        else
            # جدیدها خاموش میمونن (وگرنه watchdog چند دقیقه بعد خودش روشنشون میکرد)
            for i in "${!names_plan[@]}"; do
                [ "${actions[$i]}" = new ] && meta_set "$(cfg_path "${names_plan[$i]}")" Enabled no
            done
            ok "New tunnels are saved but off — turn them on with o<#> in the menu"
        fi
    fi

    # mark های جدید برای Xray
    for i in "${!names_plan[@]}"; do
        [ "${actions[$i]}" = new ] || continue
        [ -z "$shown" ] && { echo ""; echo -e "  ${WHITE}New Xray marks${NC}"; shown=1; }
        echo -e "    ${names_plan[$i]}   →   ${BOLD}${marks[$i]}${NC}   ${DIM}$(location_of "${names_plan[$i]}")${NC}"
    done
    [ -n "$shown" ] && note "Outbound JSON for one of them: open wg-manager and press x<#>"
    [ -f "$SERVICE_FILE" ] || warn "Auto-start + watchdog are not installed — run: wg-manager install"
    return 0
}

# ════════════════════════════════════════════════
#  CMD: rollback — برگشت به یکی از نسخه‌های قبلی (با diff)
#  هر edit/import/restore/rollback قبلش یه نسخه توی $BACKUP_DIR میذاره (حداکثر BACKUP_KEEP تا)
# ════════════════════════════════════════════════
backup_when() {   # اسم فایل ...YYYYmmddHHMMSS → "2026-11-18 05:24"
    local ts
    ts=$(basename "$1" | grep -oE '[0-9]{14}' | tail -1) || { echo "?"; return; }
    [ -n "$ts" ] || { echo "?"; return; }
    echo "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2}"
}
backup_kind() {
    case "$1" in
        *.deleted.*)       echo "deleted" ;;
        *.etc-wireguard.*) echo "old /etc/wireguard copy" ;;
        *)                 echo "replaced" ;;
    esac
}
# کلید خصوصی هیچ‌وقت توی diff نشون داده نمیشه
masked_conf() { sed -E 's/^([[:space:]]*[Pp]rivate[Kk]ey[[:space:]]*=[[:space:]]*).*/\1(hidden)/' "$1"; }

cmd_rollback() {
    local given="$1" name f n i sel pick cfg tmp t cur_t was_up names=() files=() changed
    header "Rollback"
    # تونل‌هایی که نسخه قبلی دارن (حتی حذف‌شده‌ها)
    while read -r n; do [ -n "$n" ] && names+=("$n"); done < <(
        for f in "$BACKUP_DIR"/*.conf.*; do [ -f "$f" ] && basename "$f"; done | sed 's/\.conf\..*$//' | sort -u)
    if [ ${#names[@]} -eq 0 ]; then warn "No earlier versions saved yet (they are made by edit, import, restore and rollback)"; return 1; fi

    if [ -n "$given" ]; then
        name=""
        for n in "${names[@]}"; do [ "$n" = "$given" ] && name="$n"; done
        if [ -z "$name" ]; then
            match_tunnel name "$given" || return 1
            [ -n "$(ls "$BACKUP_DIR/$name".conf.* 2>/dev/null)" ] || { warn "No earlier versions of $name"; return 1; }
        fi
    else
        [ -t 0 ] || { err "Tunnel name required"; return 1; }
        for i in "${!names[@]}"; do
            n="${names[$i]}"
            if [ -f "$(cfg_path "$n")" ]; then
                printf "    %b%2d)%b %-15s %b%s versions%b\n" "$BOLD" $((i + 1)) "$NC" "$n" "$DIM" "$(ls "$BACKUP_DIR/$n".conf.* | wc -l | tr -d ' ')" "$NC"
            else
                printf "    %b%2d)%b %-15s %bdeleted%b\n" "$BOLD" $((i + 1)) "$NC" "$n" "$YELLOW" "$NC"
            fi
        done
        while true; do
            prompt sel "Tunnel (number, Enter = cancel)" || return 1
            [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#names[@]} ] && { name="${names[$((sel - 1))]}"; break; }
            err "Choose 1-${#names[@]}"
        done
    fi
    cfg=$(cfg_path "$name")

    # نسخه‌ها، جدیدترین اول
    while read -r f; do [ -n "$f" ] && files+=("$f"); done < <(ls -1t "$BACKUP_DIR/$name".conf.* 2>/dev/null)
    echo ""
    echo -e "  ${WHITE}$name${NC} — earlier versions"
    for i in "${!files[@]}"; do
        f="${files[$i]}"
        if [ -f "$cfg" ]; then
            changed=$(diff <(masked_conf "$cfg") <(masked_conf "$f") 2>/dev/null | grep -c '^[<>]')
            changed="${changed:-0} lines differ"
        else
            changed=""
        fi
        printf "    %b%2d)%b %s   %-10s %b%s%b\n" "$BOLD" $((i + 1)) "$NC" "$(backup_when "$f")" "$(backup_kind "$f")" "$DIM" "$changed" "$NC"
    done
    while true; do
        prompt sel "Version (number, Enter = cancel)" "1" || return 1
        [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#files[@]} ] && { pick="${files[$((sel - 1))]}"; break; }
        err "Choose 1-${#files[@]}"
    done

    # diff (کلید خصوصی مخفی)
    echo ""
    if [ -f "$cfg" ]; then
        if diff -q <(masked_conf "$cfg") <(masked_conf "$pick") >/dev/null 2>&1; then
            ok "That version is the same as the current one — nothing to do"
            return 0
        fi
        diff -u --label "current" --label "version from $(backup_when "$pick")" <(masked_conf "$cfg") <(masked_conf "$pick") | \
            while IFS= read -r line; do
                case "$line" in
                    ---*|+++*) echo -e "  ${DIM}$line${NC}" ;;
                    @@*)       echo -e "  ${CYAN}$line${NC}" ;;
                    +*)        echo -e "  ${GREEN}$line${NC}" ;;
                    -*)        echo -e "  ${RED}$line${NC}" ;;
                    *)         echo -e "  ${DIM}$line${NC}" ;;
                esac
            done
    else
        note "$name was deleted — it will be created again from this version:"
        masked_conf "$pick" | sed 's/^/    /'
    fi
    echo ""
    confirm "Restore this version?" y || { warn "Cancelled — nothing changed"; return 1; }

    new_tmp tmp || return 1
    cp "$pick" "$tmp"
    sanitize_config "$tmp"
    check_config "$tmp" || { err "That version is not a complete config — not restored"; return 1; }
    t=$(meta_get "$tmp" Table-ID)
    if ! [[ "$t" =~ ^[0-9]+$ ]] || ! TABLE_SELF="$name" v_table "$t" 2>/dev/null; then
        t=$(free_table)
        [ -n "$t" ] || { err "No free table ID left"; return 1; }
        meta_set "$tmp" Table-ID "$t"
        warn "Its old mark is taken now — it gets mark $t (update the Xray outbound)"
    fi
    [ -n "$(meta_get "$tmp" Enabled)" ] || meta_set "$tmp" Enabled yes

    lock || return 1
    was_up=0
    is_up "$name" && was_up=1
    if [ -f "$cfg" ]; then
        cur_t=$(tunnel_mark "$name")
        [ "$was_up" = 1 ] && tunnel_stop "$name" >/dev/null
        [[ "$cur_t" =~ ^[0-9]+$ ]] && [ "$cur_t" != "$t" ] && leak_rules_del "$name" "$cur_t"
        # نسخه فعلی هم نگه داشته میشه → خود rollback هم قابل برگشته
        backup_save "$cfg" "$name"
        prune_backups "$name"
    fi
    install -m 600 "$tmp" "$cfg"
    log_file "$name rolled back to the version from $(backup_when "$pick")"
    ok "$name restored to the version from $(backup_when "$pick") ${DIM}(the replaced one is kept too)${NC}"
    if [ "$was_up" = 1 ] || is_enabled "$name"; then
        tunnel_up "$name" && flush_conntrack_mark "$t"
    fi
    unlock
    return 0
}

# ════════════════════════════════════════════════
#  Tab completion (با 'install' نصب میشه)
# ════════════════════════════════════════════════
COMPLETION_FILE="/etc/bash_completion.d/wg-manager"
write_completion() {
    write_file 644 "$COMPLETION_FILE" <<EOF
# Written by wg-manager v$VERSION — bash completion
_wg_manager() {
    local cur prev names
    cur="\${COMP_WORDS[COMP_CWORD]}"
    prev="\${COMP_WORDS[COMP_CWORD-1]}"
    if [ "\$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=(\$(compgen -W "monitor add paste import create enable disable restart test edit delete rollback doctor status logs backup restore up-all down-all install help version" -- "\$cur"))
        return
    fi
    case "\$prev" in
        enable|disable|restart|test|edit|delete|remove|rollback|load|up|down)
            names=\$(ls $BASE_DIR/*.conf 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\\.conf\$//')
            case "\$prev" in restart|test) names="\$names all" ;; esac
            COMPREPLY=(\$(compgen -W "\$names" -- "\$cur")) ;;
        doctor|check) COMPREPLY=(\$(compgen -W "--fix" -- "\$cur")) ;;
        status|list)  COMPREPLY=(\$(compgen -W "-v --json" -- "\$cur")) ;;
        logs)         COMPREPLY=(\$(compgen -W "-f" -- "\$cur")) ;;
        *)            COMPREPLY=() ;;   # import/restore/backup → اسم فایل (complete -o default)
    esac
}
complete -o bashdefault -o default -F _wg_manager wg-manager
EOF
}

# ════════════════════════════════════════════════
#  CMD: install — کپی به /usr/local/bin + سرویس‌های systemd
# ════════════════════════════════════════════════
install_files() {
    local src stamp="# Written by wg-manager v$VERSION — rerun 'wg-manager install' after upgrading"
    src=$(readlink -f "$0")
    if [ "$src" != "$INSTALL_PATH" ]; then
        # اتمیک: یه نسخه در حال اجرا (watchdog) هیچ‌وقت فایل نیمه‌کپی نمیبینه
        install -m 755 "$src" "$INSTALL_PATH.new" && mv -f "$INSTALL_PATH.new" "$INSTALL_PATH" || return 1
    fi

    # Before=xray: موقع بوت Xray بعد از ساخته شدن rule ها شروع میشه و موقع خاموش
    # شدن قبل از برداشتن rule ها بسته میشه (اگه این سرویس‌ها نباشن، بی‌اثره)
    write_file 644 "$SERVICE_FILE" <<EOF || return 1
$stamp
[Unit]
Description=WireGuard SAFE Manager - start enabled tunnels with routing
After=network-online.target
Wants=network-online.target
Before=xray.service x-ui.service

[Service]
Type=oneshot
RemainAfterExit=yes
# پیش‌فرض ۹۰ ثانیه‌ست؛ با چند تونل و retry موقع بوت ممکنه وسط کار kill بشه
TimeoutStartSec=5min
Environment=NO_COLOR=1
ExecStart=$INSTALL_PATH up-all
ExecStop=$INSTALL_PATH down-all
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # watchdog: doctor --fix هر ۵ دقیقه
    write_file 644 "$WATCHDOG_SERVICE" <<EOF || return 1
$stamp
[Unit]
Description=WireGuard SAFE Manager - check and repair tunnel routing
After=wg-manager.service

[Service]
Type=oneshot
TimeoutStartSec=10min
Environment=NO_COLOR=1
ExecStartPre=/bin/sleep 5
ExecStart=$INSTALL_PATH doctor --fix --quiet
EOF
    write_file 644 "$WATCHDOG_TIMER" <<EOF || return 1
$stamp
[Unit]
Description=WireGuard SAFE Manager - watchdog every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
    # بعد از هر ری‌استارت networkd فوراً watchdog اجرا بشه (حتی اگه تنظیم
    # ManageForeign* یه روز برگرده، rule ها چند ثانیه بعد دوباره ساخته میشن).
    # networkd با کاربر systemd-network اجرا میشه؛ '+' یعنی این دستور با root اجرا
    # بشه، وگرنه systemctl اجازه نداره و '-' بی‌صدا خطا رو نادیده میگیره
    write_file 644 "$NETWORKD_HOOK" <<EOF || return 1
$stamp
# Re-check tunnel routing whenever systemd-networkd (re)starts
[Service]
ExecStartPost=-+/bin/systemctl --no-block start wg-manager-watchdog.service
EOF

    # لاگ watchdog نباید بی‌نهایت بزرگ بشه
    if [ -d /etc/logrotate.d ]; then
        write_file 644 "$LOGROTATE_FILE" <<EOF
$LOG_FILE {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0600 root root
}
EOF
    fi

    # Tab completion برای دستورها و اسم تونل‌ها (از ترمینال بعدی فعاله)
    [ -d "$(dirname "$COMPLETION_FILE")" ] && write_completion

    systemctl daemon-reload
    systemctl enable wg-manager.service &>/dev/null
    systemctl enable --now wg-manager-watchdog.timer &>/dev/null
}

cmd_install() {
    local cur files
    header "Install"
    cur=$(schema_current)
    if [ "$cur" -gt "$SCHEMA_VERSION" ]; then
        err "These configs were written by a newer wg-manager (schema $cur) — install that version instead"
        return 1
    fi
    if [ "$cur" -lt "$SCHEMA_VERSION" ]; then
        step "Upgrading your setup to v$VERSION ($((SCHEMA_VERSION - cur)) step(s))"
        run_migrations || { err "Upgrade stopped — nothing else was changed"; return 1; }
    else
        echo "$SCHEMA_VERSION" > "$SCHEMA_FILE"
    fi

    step "Copying script to $INSTALL_PATH"
    step "Writing boot service, watchdog timer and networkd hook"
    install_files || { err "Install failed"; return 1; }
    ok "Installed v$VERSION — run ${BOLD}wg-manager${NC} from anywhere"
    ok "Auto-start on boot: enabled tunnels only (before Xray)"
    ok "Watchdog: every 5 min and right after systemd-networkd restarts"
    [ -f "$COMPLETION_FILE" ] && ok "Tab completion: open a new terminal, then try: wg-manager <Tab>"
    ensure_networkd

    files=$(has_ipv6 && sysctl_all_v6_files)
    if [ -n "$files" ]; then
        echo ""
        warn "$(echo "$files" | tr '\n' ' ')sets all.disable_ipv6=1"
        note "Every 'sysctl --system' (e.g. package updates) then removes IPv6 from all interfaces, tunnels included."
        note "Only that line is commented out; 'default' and 'lo' stay, so nothing changes right now."
        confirm "Comment it out?" y && fix_sysctl_all_v6
    fi
    note "systemctl status wg-manager   •   journalctl -u wg-manager -u wg-manager-watchdog"
    log_file "Installed v$VERSION"
    # یه دور watchdog با نسخه جدید (۵ ثانیه بعد، وقتی قفل آزاد شده)
    systemctl --no-block start wg-manager-watchdog.service &>/dev/null
    return 0
}

# ════════════════════════════════════════════════
#  ارتقا از نسخه‌های قدیمی — فقط با 'install' اجرا میشه
#  هر مرحله فقط وقتی موفق بود شماره‌ش توی $SCHEMA_FILE ثبت میشه
# ════════════════════════════════════════════════
schema_current() {
    local v
    v=$(tr -dc '0-9' 2>/dev/null < "$SCHEMA_FILE")
    if [ -n "$v" ]; then echo "$v"; return; fi
    # قبل از 5.1 به جای شماره، فایل‌های علامت بود
    if   [ -f "$MIGRATION_MARK_V5" ]; then echo 2
    elif [ -f "$MIGRATION_MARK" ]; then echo 1
    elif [ -n "$(list_tunnels)" ]; then echo 0
    else echo "$SCHEMA_VERSION"            # نصب تازه: چیزی برای ارتقا نیست
    fi
}
schema_pending() { [ "$(schema_current)" -lt "$SCHEMA_VERSION" ]; }

run_migrations() {
    local cur n
    cur=$(schema_current)
    for ((n = cur + 1; n <= SCHEMA_VERSION; n++)); do
        "migrate_$n" || { err "Upgrade step $n failed"; return 1; }
        echo "$n" > "$SCHEMA_FILE"
    done
    log_file "Migrated to schema $SCHEMA_VERSION (v$VERSION)"
}

# ۱) نسخه‌های قبل از v4
migrate_1() {
    local n cfg t
    for n in $(list_tunnels); do
        cfg=$(cfg_path "$n")
        # وضعیت فعلی = وضعیت بعد از ریبوت
        if [ -z "$(meta_get "$cfg" Enabled)" ]; then
            if is_up "$n"; then meta_set "$cfg" Enabled yes; else meta_set "$cfg" Enabled no; fi
        fi
        # نسخه قدیمی wg-quick@ رو enable میکرد → بعد از ریبوت تونل بدون routing بالا میومد
        systemctl is-enabled "wg-quick@$n" &>/dev/null && systemctl disable "wg-quick@$n" &>/dev/null
        # کپی قدیمی دیگه لازم نیست
        if [ -f "/etc/wireguard/$n.conf" ]; then
            mv "/etc/wireguard/$n.conf" "$BACKUP_DIR/$n.conf.etc-wireguard.$(date +%Y%m%d%H%M%S)"
        fi
        t=$(meta_get "$cfg" Table-ID)
        if [ -n "$t" ] && ! TABLE_SELF="$n" v_table "$t" 2>/dev/null; then
            warn "$n: table $t is not allowed anymore — fix with: wg-manager edit $n"
        fi
    done
    ok "Tunnels that are up now start on boot; tunnels that are down stay off"
    return 0
}

# ۲) v5.0: rule های IPv6 (قبلاً روی سرورهای all.disable_ipv6=1 ساخته نمیشد)
migrate_2() {
    reapply_routing_all
    ok "IPv6 routing added for running tunnels"
    note "Older versions deleted IPv6 addresses from configs — add them back with: wg-manager edit <name>"
    return 0
}

# ۳) v5.1: تگ conntrack، شمارنده leak و keepalive برای تونل‌های در حال اجرا (بدون ری‌استارت)
migrate_3() {
    local n pub
    reapply_routing_all
    for n in $(list_tunnels); do
        is_up "$n" || continue
        grep -qiE '^PersistentKeepalive[[:space:]]*=' "$(cfg_path "$n")" && continue
        pub=$(conf_get "$(cfg_path "$n")" PublicKey)
        [ -n "$pub" ] && wg set "$n" peer "$pub" persistent-keepalive "$KEEPALIVE_DEFAULT" 2>/dev/null
    done
    ok "Per-tunnel conntrack tagging, leak counters and keepalive $KEEPALIVE_DEFAULT s enabled"
    return 0
}

warn_outdated_install() {
    local src
    src=$(readlink -f "$0")
    if [ -f "$INSTALL_PATH" ] && [ "$src" != "$INSTALL_PATH" ] && ! cmp -s "$src" "$INSTALL_PATH"; then
        warn "The installed copy ($INSTALL_PATH) differs from this script — run: bash $src install"
    fi
}

# watchdog: اگه یه wg-manager دیگه در حال کاره این دور رد میشه (و لاگ میشه).
# بعد از ۳ دور پشت سر هم، دیگه رد نمیکنه و صبر میکنه
watchdog_lock() {
    local f="$RUN_DIR/watchdog-skips" n
    if lock try; then rm -f "$f"; return 0; fi
    n=$(cat "$f" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$((n + 1))
    if [ "$n" -ge 3 ]; then
        rm -f "$f"
        log_file "watchdog: another wg-manager has been busy for $n checks — waiting for it"
        lock
        return
    fi
    mkdir -p "$RUN_DIR" && echo "$n" > "$f"
    log_file "watchdog: skipped this check (another wg-manager is running)"
    return 1
}

# ════════════════════════════════════════════════
#  راهنما
# ════════════════════════════════════════════════
usage() {
    cat <<EOF
WireGuard SAFE Manager v$VERSION

Usage: wg-manager [command] [tunnel] [options]
  <tunnel> can be the full name, the # from the table, or part of the name ("fra").
  restart/test/enable/disable also take lists ("1,3" or "fra,nyc"); restart/test take "all".

  (no command)          interactive menu
  monitor               live traffic per tunnel (q quit, s sort)
  add                   add a tunnel (paste / file / manual)
  paste [name]          add by pasting the whole config
  import <file> [name]  add from a .conf file
  import <zip|folder>   add/update many Mullvad configs at once (pick by country/city)
  create                add by entering fields one by one
  enable  [tunnel]      start + keep on after reboot   (alias: load, up)
  disable [tunnel]      stop + keep off after reboot   (alias: down)
  restart [tunnel|all]  restart
  test    [tunnel|all]  test the real Xray path: exit IP v4/v6, leaks, ping, MTU
  edit    [tunnel]      edit a config in \$EDITOR and apply it
  rollback [tunnel]     go back to an earlier version of a config (shows a diff)  (alias: undo)
  delete  [name]        remove a tunnel (full name needed; config moved to $BACKUP_DIR)  (alias: remove)
  doctor  [--fix]       check routing, leaks, handshakes, networkd (--fix: repair)  (alias: check)
  status  [-v|--json]   overview (-v: rules, NAT, log; --json: machine-readable)  (alias: list)
  logs    [-f]          show the log (-f: follow)
  backup  [file]        save all tunnels to one .tar.gz (contains private keys!)
  restore <file>        restore tunnels from a backup (shows a plan first)
  up-all                start all enabled tunnels (used at boot)
  down-all              stop all tunnels (temporary; pauses the watchdog)
  install               install/upgrade: $INSTALL_PATH + boot service + watchdog

  -y, --yes             accept defaults, don't ask
  -v, --verbose         more detail (status)
  -q, --quiet           only print problems (doctor)
  --fix                 repair what doctor finds
  --json                JSON output (status)
  WGM_FLAGS=0           hide the country flags (if your terminal doesn't render them)
EOF
}

show_help() {
    local l
    if show_logo; then
        [ ${#LOGO[@]} -gt 0 ] || logo_build
        echo ""
        for l in "${LOGO[@]}"; do printf '  %b\n' "$l"; done
        echo -e "  ${WHITE}${BOLD}WireGuard SAFE Manager${NC}  ${DIM}v$VERSION${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}${CYAN}Keys${NC}"
    hr
    echo -e "  ${BOLD}/${NC}          search every action by name (e.g. ${BOLD}/backup${NC}, ${BOLD}/speed${NC}, ${BOLD}/xray${NC}) — no need to remember keys"
    echo -e "  ${BOLD}f${NC}          fix the problems shown at the top (install if needed, then doctor --fix)"
    echo -e "  ${BOLD}2${NC}          open tunnel #2 (details + actions)"
    echo -e "  ${BOLD}r2${NC}  ${BOLD}t2${NC}  ${BOLD}e2${NC}  ${BOLD}o2${NC}  restart · test · edit · turn on/off tunnel #2   (also 2r, r 1,3, r all)"
    echo -e "  ${BOLD}x2${NC}         Xray outbound JSON for tunnel #2"
    echo -e "  ${BOLD}a${NC} add   ${BOLD}m${NC} monitor   ${BOLD}t${NC} test all   ${BOLD}d${NC} doctor   ${BOLD}s${NC} status   ${BOLD}l${NC} logs   ${BOLD}q${NC} quit"
    echo -e "  Type a command name for the rest: ${BOLD}import rollback backup restore install up-all down-all delete${NC}"
    echo -e "  ${DIM}import = many Mullvad configs from a .zip or folder · rollback = earlier version of a config (with diff)${NC}"
    echo -e "  ${DIM}Ctrl+C stops the current action and comes back here.${NC}"
    echo ""
    echo -e "  ${BOLD}${CYAN}Command line${NC}"
    hr
    usage | sed -n '3,$p' | sed 's/^/  /'
}

# key_hint <key> <rest> → "[a]dd" (حرف اول خود کلمه‌ست) یا "[r#] restart" (rest با فاصله شروع بشه)
key_hint() { printf '%b[%b%b%s%b%b]%b%s' "$GRAY" "$NC" "$BLUE$BOLD" "$1" "$NC" "$GRAY" "$NC" "$2"; }

clear_screen() { [ -t 1 ] && printf '\033[H\033[2J%b' "$FG"; }

# ════════════════════════════════════════════════
#  CMD: monitor — سرعت لحظه‌ای هر تونل
#  از /sys/class/net میخونه (بدون fork برای هر تونل)؛ بدون قفل
# ════════════════════════════════════════════════
SPARK_CHARS=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
sparkline() {   # sparkline <width> <v1 v2 ...> — مقیاس نسبت به بیشترین مقدار همین ردیف
    local w="$1" v max=0 out="" vals=() i
    shift
    vals=("$@")
    [ ${#vals[@]} -gt "$w" ] && vals=("${vals[@]: -$w}")
    for v in "${vals[@]}"; do [ "$v" -gt "$max" ] && max=$v; done
    for v in "${vals[@]}"; do
        if [ "$max" -le 0 ]; then i=0; else i=$((v * 7 / max)); fi
        out="$out${SPARK_CHARS[$i]}"
    done
    printf '%s' "$out"
}

mon_restore() { printf '\033[?25h'; tput rmcup 2>/dev/null; }

cmd_monitor() {
    local names=() n i key sort=name order line t0 t1 dt v cur
    local prx=() ptx=() rrx=() rtx=() hist=() down=()
    local srx stx narrow w
    if [ ! -t 0 ] || [ ! -t 1 ]; then err "monitor needs an interactive terminal"; return 1; fi
    while read -r n; do [ -n "$n" ] && names+=("$n"); done < <(list_tunnels)
    if [ ${#names[@]} -eq 0 ]; then warn "No tunnels yet"; return 1; fi

    tput smcup 2>/dev/null; printf '\033[?25l'; clear_screen
    trap 'mon_restore; cleanup' EXIT
    t0=$(date +%s%N)
    for i in "${!names[@]}"; do
        prx[$i]=$(cat "/sys/class/net/${names[$i]}/statistics/rx_bytes" 2>/dev/null || echo 0)
        ptx[$i]=$(cat "/sys/class/net/${names[$i]}/statistics/tx_bytes" 2>/dev/null || echo 0)
        rrx[$i]=0; rtx[$i]=0; hist[$i]=""
    done

    while true; do
        key=""
        read -rsn1 -t 1 key
        case "$key" in
            q|Q) break ;;
            s|S) case "$sort" in name) sort=down ;; down) sort=up ;; *) sort=name ;; esac ;;
        esac
        t1=$(date +%s%N); dt=$(((t1 - t0) / 1000000)); [ "$dt" -lt 1 ] && dt=1; t0=$t1

        srx=0; stx=0
        for i in "${!names[@]}"; do
            n="${names[$i]}"
            if [ -r "/sys/class/net/$n/statistics/rx_bytes" ]; then
                down[$i]=0
                cur=$(< "/sys/class/net/$n/statistics/rx_bytes")
                v=$(((cur - prx[$i]) * 8000 / dt)); [ "$v" -lt 0 ] && v=0
                rrx[$i]=$v; prx[$i]=$cur
                cur=$(< "/sys/class/net/$n/statistics/tx_bytes")
                v=$(((cur - ptx[$i]) * 8000 / dt)); [ "$v" -lt 0 ] && v=0
                rtx[$i]=$v; ptx[$i]=$cur
            else
                down[$i]=1; rrx[$i]=0; rtx[$i]=0
            fi
            hist[$i]=$(echo "${hist[$i]} ${rrx[$i]}" | awk '{ s = ""; for (k = (NF > 30 ? NF - 29 : 1); k <= NF; k++) s = s " " $k; print s }')
            srx=$((srx + rrx[$i])); stx=$((stx + rtx[$i]))
        done

        # ترتیب نمایش
        case "$sort" in
            down) order=$(for i in "${!names[@]}"; do echo "${rrx[$i]} $i"; done | sort -rn | awk '{print $2}') ;;
            up)   order=$(for i in "${!names[@]}"; do echo "${rtx[$i]} $i"; done | sort -rn | awk '{print $2}') ;;
            *)    order="${!names[*]}" ;;
        esac

        is_narrow && narrow=1 || narrow=0
        w=20; [ "$narrow" = 1 ] && w=12
        printf '\033[H'
        printf '  %bmonitor%b  ↓ %b%s%b  ↑ %b%s%b\033[K\n' "$BOLD$CYAN" "$NC" "$BOLD" "$(fmt_rate "$srx")" "$NC" "$BOLD" "$(fmt_rate "$stx")" "$NC"
        printf '  %bsort: %s · s change · q quit%b\033[K\n\033[K\n' "$DIM" "$sort" "$NC"
        if [ "$narrow" = 0 ]; then
            printf '  %b%-15s %-11s %-11s %-8s %-8s %-6s %s%b\033[K\n' "$DIM" "NAME" "↓ NOW" "↑ NOW" "↓ TOTAL" "↑ TOTAL" "HS" "↓ LAST 30s" "$NC"
        fi
        for i in $order; do
            n="${names[$i]}"
            if [ "${down[$i]}" = 1 ]; then
                printf '  %b%-15s%b %bdown%b\033[K\n' "$BOLD" "$n" "$NC" "$RED" "$NC"
                [ "$narrow" = 1 ] && printf '\033[K\n'
                continue
            fi
            hs_label "$(latest_handshake "$n")"
            # shellcheck disable=SC2086
            if [ "$narrow" = 1 ]; then
                printf '  %b%-15s%b ↓ %-10s ↑ %s\033[K\n' "$BOLD" "$n" "$NC" "$(fmt_rate "${rrx[$i]}")" "$(fmt_rate "${rtx[$i]}")"
                printf '     %b%s / %s · hs %b%s%b%b · %s%b\033[K\n' "$DIM" "$(fmt_bytes "${prx[$i]}")" "$(fmt_bytes "${ptx[$i]}")" \
                    "$HS_C" "$HS_TXT" "$NC" "$DIM" "$(sparkline "$w" ${hist[$i]})" "$NC"
            else
                printf '  %b%-15s%b %-11s %-11s %-8s %-8s %b%-6s%b %b%s%b\033[K\n' "$BOLD" "$n" "$NC" \
                    "$(fmt_rate "${rrx[$i]}")" "$(fmt_rate "${rtx[$i]}")" "$(fmt_bytes "${prx[$i]}")" "$(fmt_bytes "${ptx[$i]}")" \
                    "$HS_C" "$HS_TXT" "$NC" "$CYAN" "$(sparkline "$w" ${hist[$i]})" "$NC"
            fi
        done
        printf '\033[J'
    done
    mon_restore
    trap cleanup EXIT
    return 0
}

# ════════════════════════════════════════════════
#  منو
# ════════════════════════════════════════════════
pause() {
    echo ""
    read -r -p "$(printf '  %bEnter = back to menu%b ' "$DIM" "$NC")" _ || true
}

# هر کار توی یه subshell اجرا میشه: Ctrl+C فقط همون کار رو متوقف میکنه و به منو برمیگرده
# (قفل و فایل‌های موقت اون کار هم با بسته شدن subshell آزاد/پاک میشن)
# run_action <quick|long> <command...> — quick: اگه موفق بود بدون Enter به منو برمیگرده
run_action() {
    local kind="$1"
    shift
    MENU_IDLE=0
    ( trap cleanup EXIT; trap 'echo ""; exit 130' INT TERM; "$@" )
    ACTION_RC=$?
    MENU_IDLE=1
    if [ "$ACTION_RC" = 130 ]; then
        TOAST="${YELLOW}! Cancelled${NC}"
        return
    fi
    if [ "$kind" = long ] || [ "$ACTION_RC" != 0 ]; then pause; fi
}

# روشن/خاموش: فعال و بالا → disable؛ وگرنه → enable
toggle_tunnel() {
    local n="$1"
    if is_enabled "$n" && is_up "$n"; then
        NO_TEST=1 run_locked cmd_disable "$n"
    else
        NO_TEST=1 run_locked cmd_enable "$n"
    fi
}

tunnel_log() {
    header "Log: $1"
    grep -F " $1" "$LOG_FILE" 2>/dev/null | tail -n 20 | sed 's/^/  /'
    [ -n "$(grep -F " $1" "$LOG_FILE" 2>/dev/null | tail -1)" ] || note "Nothing logged for $1 yet"
}

# اجرای یه کار روی تونل(ها) از منو (کلید + شماره) → TOAST
tunnel_action() {   # tunnel_action <key> <targets>
    local key="$1" tg="$2" one label="$2"
    # برای پیام: شماره → اسم
    match_tunnel one "$tg" >/dev/null 2>&1 && label="$one"
    case "$key" in
        r)  run_action quick env_no_test run_locked cmd_restart "$tg"
            [ "$ACTION_RC" = 0 ] && TOAST="${GREEN}✓ restarted: $label${NC}" ;;
        t)  run_action long cmd_test "$tg" ;;
        e)  resolve_target one all "$tg" >/dev/null 2>&1 || { TOAST="${RED}✗ no tunnel '$tg'${NC}"; return; }
            run_action long cmd_edit "$one" ;;
        o)  resolve_targets all "$tg" 2>/dev/null || { TOAST="${RED}✗ no tunnel '$tg'${NC}"; return; }
            for one in "${TARGETS[@]}"; do run_action quick toggle_tunnel "$one"; done
            [ "$ACTION_RC" = 0 ] && TOAST="${GREEN}✓ turned on/off: ${TARGETS[*]}${NC}" ;;
        x)  resolve_target one all "$tg" >/dev/null 2>&1 || { TOAST="${RED}✗ no tunnel '$tg'${NC}"; return; }
            run_action long print_xray_hint "$one" "$(tunnel_mark "$one")" ;;
        *)  TOAST="${RED}✗ unknown key '$key' — press ? for help${NC}" ;;
    esac
}
env_no_test() { NO_TEST=1 "$@"; }

# ── صفحه یه تونل ────────────────────────────────
fmt_dur() {   # ثانیه → "3d 4h" / "5h 12m" / "7m 3s"
    local s="${1:-0}"
    [ "$s" -lt 0 ] && s=0
    if   [ "$s" -ge 86400 ]; then echo "$((s / 86400))d $((s % 86400 / 3600))h"
    elif [ "$s" -ge 3600 ];  then echo "$((s / 3600))h $((s % 3600 / 60))m"
    else                          echo "$((s / 60))m $((s % 60))s"; fi
}
tunnel_rate() {   # tunnel_rate <name> → TRATE_RX TRATE_TX (bit/s، نمونه ۰.۴ ثانیه)
    local d="/sys/class/net/$1/statistics" r1 t1 r2 t2
    TRATE_RX=0; TRATE_TX=0
    [ -d "$d" ] || return 0
    r1=$(cat "$d/rx_bytes" 2>/dev/null || echo 0); t1=$(cat "$d/tx_bytes" 2>/dev/null || echo 0)
    sleep 0.4
    r2=$(cat "$d/rx_bytes" 2>/dev/null || echo 0); t2=$(cat "$d/tx_bytes" 2>/dev/null || echo 0)
    TRATE_RX=$(((r2 - r1) * 20)); TRATE_TX=$(((t2 - t1) * 20))
    [ "$TRATE_RX" -lt 0 ] && TRATE_RX=0
    [ "$TRATE_TX" -lt 0 ] && TRATE_TX=0
    return 0
}
page_row() { printf '  %b%-10s%b %b\n' "$DIM" "$1" "$NC" "$2"; }

tunnel_menu() {
    local name="$1" t c rx tx ep onoff now since ka rs rp bo lt detail today
    while true; do
        clear_screen
        now=$(date +%s)
        t=$(tunnel_mark "$name")
        tunnel_state "$name"
        echo ""
        if is_compact; then
            echo -e "  $(flag_of "$name")${WHITE}${BOLD}$name${NC}   ${ST_C}$ST${NC}"
            echo -e "  $(location_of "$name")   ${DIM}mark${NC} ${t:-?}"
        else
            echo -e "  $(flag_of "$name")${WHITE}${BOLD}$name${NC}     ${ST_C}$ST${NC}     $(location_of "$name")     ${DIM}mark${NC} ${t:-?}"
        fi
        echo ""
        hr
        echo ""
        if is_up "$name"; then
            ep=$(wg show "$name" endpoints 2>/dev/null | awk 'NR==1 {print $2}')
            hs_label "$(latest_handshake "$name")"
            rx=0; tx=0
            read -r rx tx < <(wg show "$name" transfer 2>/dev/null | awk 'NR==1 {print $2, $3}')
            ka=$(wg show "$name" persistent-keepalive 2>/dev/null | awk 'NR==1 && $2 ~ /^[0-9]+$/ {print $2}')
            # کپی runtime موقع هر بالا اومدن نوشته میشه → زمانش = زمان بالا اومدن تونل
            since=$(stat -c %Y "$RUN_DIR/$name.conf" 2>/dev/null)
            tunnel_rate "$name"
            [[ "$since" =~ ^[0-9]+$ ]] && \
                page_row uptime "$(fmt_dur $((now - since)))  ${DIM}since $(date -d "@$since" '+%b %d %H:%M' 2>/dev/null)${NC}"
            page_row endpoint "$ep"
            page_row handshake "${HS_C}$HS_TXT${NC}${ka:+   ${DIM}keepalive ${ka}s${NC}}"
            page_row "speed now" "${GREEN}↓${NC} $(fmt_rate "$TRATE_RX")   ${BLUE}↑${NC} $(fmt_rate "$TRATE_TX")"
            page_row traffic "↓ $(fmt_bytes "${rx:-0}")   ↑ $(fmt_bytes "${tx:-0}")  ${DIM}since up${NC}"
        else
            page_row endpoint "$(conf_get "$(cfg_path "$name")" Endpoint)"
            [ "$ST" = off ] && echo -e "  ${YELLOW}!${NC} Xray outbounds with mark $t exit via the server IP while this is off"
        fi

        # آخرین تست (از فایل ذخیره‌شده؛ تست جدید با t)
        if test_load "$name"; then
            [ "$LT_RESULT" = OK ] && lt="${GREEN}✓ OK${NC}" || lt="${RED}✗ $LT_RESULT${NC}"
            detail=""
            [ -n "$LT_EXIT" ] && [ "$LT_EXIT" != - ] && detail="   exit $LT_EXIT"
            [ -n "$LT_LOC" ] && [ "$LT_LOC" != - ] && detail="$detail ($LT_LOC)"
            [ -n "$LT_PING" ] && [ "$LT_PING" != - ] && detail="$detail · ping $LT_PING"
            page_row "last test" "$lt ${DIM}$(fmt_age $((now - LT_TS))) ago${NC}$detail"
        else
            page_row "last test" "${DIM}never — press t${NC}"
        fi

        if conf_get_all "$(cfg_path "$name")" Address | grep -q ':'; then
            page_row IPv6 "${GREEN}yes${NC}"
        else
            page_row IPv6 "${DIM}no (blocked for this mark — use ForceIPv4 in Xray)${NC}"
        fi
        page_row boot "$(is_enabled "$name" && echo on || echo off)"
        if [[ "$t" =~ ^[0-9]+$ ]]; then
            leak_read "$t"
            if [ "$LEAK_PKTS" -gt 0 ]; then
                page_row leaks "${YELLOW}$LEAK_PKTS packets${NC} since boot ${DIM}(left via the server IP)${NC}"
            else
                page_row leaks "${GREEN}0${NC} since boot"
            fi
        fi

        # امروز: چند بار بالا اومده / تعمیر شده (از لاگ)
        today=$(date '+%Y-%m-%d')
        read -r rs rp < <(awk -v d="[$today " -v u="] $name up | table" -v n="$name" '
            index($0, d) == 1 { if (index($0, u)) r++; else if (index($0, "doctor: fixed") && index($0, n)) p++ }
            END { print r + 0, p + 0 }' "$LOG_FILE" 2>/dev/null)
        if [ "${rs:-0}" -gt 0 ] || [ "${rp:-0}" -gt 0 ]; then
            page_row today "${rs:-0} start$([ "${rs:-0}" -ne 1 ] && echo s) · ${rp:-0} auto-repair$([ "${rp:-0}" -ne 1 ] && echo s)"
        else
            page_row today "${DIM}no restarts or repairs${NC}"
        fi
        bo=$(cat "$RUN_DIR/restart-$name" 2>/dev/null)
        if [[ "$bo" =~ ^[0-9]+$ ]] && [ $((now - bo)) -lt "$RESTART_BACKOFF" ]; then
            page_row watchdog "${YELLOW}restarted it $(fmt_age $((now - bo))) ago — next auto-restart in $(fmt_age $((RESTART_BACKOFF - now + bo))) at the earliest${NC}"
        fi
        echo ""
        hr
        is_enabled "$name" && is_up "$name" && onoff="turn off" || onoff="turn on"
        echo ""
        hint_row actions r estart t est e dit o " $onoff" x " xray json" l og u ndo delete "" Enter " back"
        if [ -n "$TOAST" ]; then echo ""; echo -e "  $TOAST"; TOAST=""; fi
        echo ""
        read -r -p "$(printf '  %b?%b %s: ' "$BLUE" "$NC" "$name")" c
        [ $? -gt 128 ] && return            # Ctrl+C → برگشت
        c=$(trim "$c")
        case "$c" in
            "")        return ;;
            r)         run_action quick env_no_test run_locked cmd_restart "$name"
                       [ "$ACTION_RC" = 0 ] && TOAST="${GREEN}✓ restarted${NC}" ;;
            t)         run_action long cmd_test "$name" ;;
            e)         run_action long cmd_edit "$name"; [ -f "$(cfg_path "$name")" ] || return ;;
            o)         run_action quick toggle_tunnel "$name"; [ "$ACTION_RC" = 0 ] && TOAST="${GREEN}✓ done${NC}" ;;
            x)         run_action long print_xray_hint "$name" "$t" ;;
            l)         run_action long tunnel_log "$name" ;;
            u)         run_action long cmd_rollback "$name" ;;
            delete)    run_action long cmd_delete "$name"; [ -f "$(cfg_path "$name")" ] || return ;;
            q|quit)    menu_exit ;;
            *)         TOAST="${RED}✗ unknown key '$c'${NC}" ;;
        esac
    done
}

# ════════════════════════════════════════════════
#  جستجوی کارها با / — لازم نیست کلیدها رو حفظ کنی
#  هر خط: کلید میانبر | اسم | کلمه‌های جستجو | کار
# ════════════════════════════════════════════════
PALETTE=(
"a|add a tunnel (paste a config)|new paste create config conf file|add"
"i|import Mullvad configs (.zip or folder)|bulk zip folder mullvad many download|import"
"#|open a tunnel page (details + actions)|details info show page uptime endpoint|open"
"r#|restart a tunnel|reconnect reload restart fix|restart"
"t#|test a tunnel (exit IP, leaks, ping, MTU)|check ip exit leak ping mtu speed|test"
"t|test all tunnels|check ip exit leak ping mtu every|test-all"
"o#|turn a tunnel on|enable start up load boot on|enable"
"o#|turn a tunnel off|disable stop down off|disable"
"e#|edit a tunnel config|change modify endpoint mtu key keepalive dns|edit"
"x#|Xray outbound JSON for a tunnel|xray json mark sockopt outbound routing|xray"
"u|undo: go back to an earlier config|rollback revert history previous restore diff|rollback"
"delete|delete a tunnel|remove|delete"
"m|live monitor (speed per tunnel)|speed rate bandwidth traffic graph top usage|monitor"
"f|fix problems now|repair heal doctor fix broken|fix"
"d|doctor: check everything|check health problems diagnose networkd watchdog|doctor"
"s|detailed status (rules, NAT, log)|list info verbose rules nat|status"
"l|logs|history events log journal|logs"
"b|backup all configs to a .tar.gz|save export archive keys|backup"
"restore|restore from a backup|import backup recover tar|restore"
"install|install / update the boot service + watchdog|service systemd watchdog update upgrade timer|install"
"up-all|start all enabled tunnels (un-pause)|resume start all unpause|up-all"
"down-all|stop all tunnels (pauses the watchdog)|pause stop all|down-all"
"?|help (all keys and commands)|keys commands usage manual|help"
"q|quit|exit close leave|quit"
)

# palette_run <id> — توی شل اصلی (نه subshell)، چون صفحه تونل و monitor خودشون حلقه دارن
palette_run() {
    local tg
    case "$1" in
        add)      run_action long cmd_add ;;
        import)   run_action long env_bulk ;;
        open)     MENU_IDLE=0
                  tg=$( ( trap 'exit 130' INT; pick_tunnel tg all >&2 && echo "$tg" ) )
                  MENU_IDLE=1
                  [ -n "$tg" ] && tunnel_menu "$tg" ;;
        restart)  run_action long run_locked cmd_restart ;;
        test)     run_action long cmd_test ;;
        test-all) run_action long cmd_test all ;;
        enable)   run_action long run_locked cmd_enable ;;
        disable)  run_action long run_locked cmd_disable ;;
        edit)     run_action long cmd_edit ;;
        xray)     run_action long xray_pick ;;
        rollback) run_action long cmd_rollback ;;
        delete)   run_action long cmd_delete ;;
        monitor)  MENU_IDLE=0; ( trap 'exit 130' INT; cmd_monitor ); MENU_IDLE=1 ;;
        fix)      run_action long fix_now ;;
        doctor)   run_action long run_locked cmd_doctor ;;
        status)   run_action long env_verbose cmd_status ;;
        logs)     run_action long cmd_logs ;;
        backup)   run_action long cmd_backup ;;
        restore)  run_action long cmd_restore ;;
        install)  run_action long run_locked cmd_install ;;
        up-all)   run_action long run_locked cmd_up_all ;;
        down-all) run_action long run_locked cmd_down_all ;;
        help)     run_action long show_help ;;
        quit)     menu_exit ;;
    esac
}
xray_pick() { local n; resolve_target n all "" || return 1; print_xray_hint "$n" "$(tunnel_mark "$n")"; }

# palette_filter <query> → PAL_HITS (کلمه‌ها با هر ترتیبی باید توی کلید/اسم/کلمه‌ها باشن)
palette_filter() {
    local q e key label words id hay w ok
    q=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    PAL_HITS=()
    for e in "${PALETTE[@]}"; do
        IFS='|' read -r key label words id <<< "$e"
        hay=$(printf '%s %s %s' "$key" "$label" "$words" | tr '[:upper:]' '[:lower:]')
        ok=1
        for w in $q; do
            [[ "$hay" == *"$w"* ]] || { ok=0; break; }
        done
        [ "$ok" = 1 ] && PAL_HITS+=("$e")
    done
}

palette() {
    local q="$1" e key label words id i sel n
    while true; do
        palette_filter "$q"
        n=${#PAL_HITS[@]}
        clear_screen
        echo ""
        if [ -n "$q" ]; then
            echo -e "  ${WHITE}${BOLD}Search${NC}  ${CYAN}$q${NC}   ${DIM}$n match$([ "$n" -ne 1 ] && echo es)${NC}"
        else
            echo -e "  ${WHITE}${BOLD}All actions${NC}   ${DIM}type words to filter${NC}"
        fi
        hr
        echo ""
        [ "$n" -eq 0 ] && echo -e "  ${YELLOW}!${NC} Nothing matches '$q' — try other words, or Enter for the menu"
        i=0
        for e in "${PAL_HITS[@]}"; do
            i=$((i + 1))
            IFS='|' read -r key label words id <<< "$e"
            if is_compact; then
                printf "  %b%2d%b  %s\n" "$BLUE$BOLD" "$i" "$NC" "$label"
            else
                printf "  %b%2d%b  %-46s %bkey%b %b%s%b\n" "$BLUE$BOLD" "$i" "$NC" "$label" "$GRAY" "$NC" "$DIM" "$key" "$NC"
            fi
        done
        echo ""
        if [ -n "$TOAST" ]; then echo -e "  $TOAST"; TOAST=""; fi
        note "number = run it · words = search again · Enter = back"
        read -r -p "$(printf '  %b/%b ' "$BLUE" "$NC")" sel || return 0
        sel=$(trim "$sel")
        sel="${sel#/}"
        [ -z "$sel" ] && return 0
        if [[ "$sel" =~ ^[0-9]+$ ]]; then
            if [ "$sel" -ge 1 ] && [ "$sel" -le "$n" ]; then
                IFS='|' read -r key label words id <<< "${PAL_HITS[$((sel - 1))]}"
                palette_run "$id"
                return 0
            fi
            TOAST="${RED}✗ no #$sel in the list${NC}"
            continue
        fi
        q="$sel"
    done
}


# hint_row <label> <key> <rest> [<key> <rest> ...] — کلیدها؛ به عرض ترمینال میشکنه
hint_row() {
    local label="$1" w len=0 ilen sp="    " lw=9
    shift
    is_narrow && sp="   "
    is_compact && { lw=0; sp="  "; }              # گوشی: بدون ستون برچسب
    w=$(($(term_cols) - 3 - lw))
    if [ "$lw" -gt 0 ]; then printf '  %b%-9s%b' "$DIM" "$label" "$NC"; else printf '  '; fi
    while [ $# -ge 2 ]; do
        ilen=$((${#1} + ${#2} + 2))
        if [ "$len" -gt 0 ] && [ $((len + ${#sp} + ilen)) -gt "$w" ]; then
            printf '\n  %*s' "$lw" ""
            len=0
        fi
        [ "$len" -gt 0 ] && { printf '%s' "$sp"; len=$((len + ${#sp})); }
        printf '%s' "$(key_hint "$1" "$2")"
        len=$((len + ilen))
        shift 2
    done
    echo ""
}

show_menu() {
    clear_screen
    print_dashboard
    print_tunnel_table
    echo ""
    hr
    if is_compact; then
        # گوشی: فقط کلیدهای اصلی؛ بقیه با / پیدا میشن
        [ -n "$(list_tunnels)" ] && hint_row "" "#" " open" "r#" " restart" "t#" " test" "o#" " on/off"
        hint_row "" "/" " search" a dd m onitor "?" " help" q uit
    else
        if [ -n "$(list_tunnels)" ]; then
            hint_row tunnel "#" " open" "r#" " restart" "t#" " test" "e#" " edit" "o#" " on/off"
            echo -e "  ${DIM}         e.g. 2 · r2 · r 1,3 · t all${NC}"
        fi
        hint_row general "/" " search everything" a dd m onitor t "est all" d octor s tatus l ogs "?" " help" q uit
        hint_row tools i "mport Mullvad" u "ndo (rollback)" b ackup "restore" "" "install" "" "up-all" "" "down-all" ""
    fi
    echo ""
    if [ -n "$TOAST" ]; then echo -e "  $TOAST"; echo ""; TOAST=""; fi
}

# Ctrl+C توی منو: وقتی منتظر تایپ توئه → خروج از برنامه.
# وقتی یه کار در حال اجراست (MENU_IDLE=0) فقط همون کار (subshell) متوقف میشه
menu_on_int() {
    if [ "${MENU_IDLE:-1}" = 1 ]; then
        menu_exit
    fi
}

menu() {
    local choice rc key tg
    TOAST=""
    if [ ! -t 0 ]; then
        usage
        exit 1
    fi
    # Ctrl+C: توی منوی اصلی → خروج؛ توی صفحه تونل → برگشت؛ وسط یه کار → فقط همون کار متوقف میشه
    MENU_IDLE=1
    trap 'menu_on_int' INT
    since_visit_init
    while true; do
        show_menu
        read -r -p "$(printf '  %b?%b Choose: ' "$BLUE" "$NC")" choice
        rc=$?
        [ "$rc" -ne 0 ] && menu_exit                  # Ctrl+D
        choice=$(trim "$choice")
        case "$choice" in
            "")              continue ;;
            q|quit|exit|0)   menu_exit ;;
            /*)              palette "$(trim "${choice#/}")" ;;
            search|find)     palette "" ;;
            search\ *|find\ *) palette "${choice#* }" ;;
            f|fix)           run_action long fix_now ;;
            "?"|h|help)      run_action long show_help ;;
            a|add)           run_action long cmd_add ;;
            i)               run_action long env_bulk ;;
            u)               run_action long cmd_rollback ;;
            b)               run_action long cmd_backup ;;
            m|monitor)       MENU_IDLE=0; ( trap 'exit 130' INT; cmd_monitor ); MENU_IDLE=1 ;;
            t|test)          run_action long cmd_test all ;;
            d|doctor)        run_action long run_locked cmd_doctor ;;
            s|status)        run_action long env_verbose cmd_status ;;
            l|logs)          run_action long cmd_logs ;;
            backup)          run_action long cmd_backup ;;
            restore)         run_action long cmd_restore ;;
            install)         run_action long run_locked cmd_install ;;
            up-all)          run_action long run_locked cmd_up_all ;;
            down-all)        run_action long run_locked cmd_down_all ;;
            delete|remove)   run_action long cmd_delete ;;
            rollback|undo)   run_action long cmd_rollback ;;
            rollback\ *|undo\ *) run_action long cmd_rollback "${choice#* }" ;;
            import)          run_action long env_bulk ;;
            import\ *)       run_action long cmd_import_bulk "${choice#* }" ;;
            delete\ *|remove\ *) run_action long cmd_delete "${choice#* }" ;;
            enable|disable|restart)
                             run_action long run_locked "cmd_$choice" ;;
            edit)            run_action long cmd_edit ;;      # edit خودش فقط موقع ذخیره قفل میگیره
            enable\ *|disable\ *|restart\ *)
                             run_action long run_locked "cmd_${choice%% *}" "${choice#* }" ;;
            test\ *|edit\ *) run_action long "cmd_${choice%% *}" "${choice#* }" ;;
            *)
                # <#> → صفحه تونل؛ r2 / 2r / r 1,3 / r all → کار روی تونل
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    if match_tunnel tg "$choice" 2>/dev/null; then tunnel_menu "$tg"; else TOAST="${RED}✗ there is no tunnel #$choice${NC}"; fi
                # (اسم بعد از حرف فقط با فاصله: "t fra". "tr-ist" یعنی باز کردن تونل tr-ist)
                elif [[ "$choice" =~ ^([rteox])[[:space:]]*([0-9][0-9,]*|all)$ ]] || \
                     [[ "$choice" =~ ^([rteox])[[:space:]]+([a-zA-Z0-9_=+.,-]+)$ ]]; then
                    tunnel_action "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
                elif [[ "$choice" =~ ^([0-9]+)[[:space:]]*([rteox])$ ]]; then
                    tunnel_action "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
                elif match_tunnel tg "$choice" 2>/dev/null; then
                    tunnel_menu "$tg"                    # اسم یا بخشی از اسم
                else
                    # ناشناخته → اگه به یه کار بخوره، جستجو باز میشه ("speed" → monitor، "xray" → Xray JSON)
                    palette_filter "$choice"
                    if [ ${#PAL_HITS[@]} -gt 0 ]; then palette "$choice"
                    else TOAST="${RED}✗ unknown command '$choice' — press / to search${NC}"; fi
                fi
                ;;
        esac
    done
}
env_verbose() { VERBOSE=1 "$@"; }
env_bulk() { local src; prompt src "Path to the Mullvad .zip or folder" || return 1; cmd_import_bulk "$src"; }

# ════════════════════════════════════════════════
#  MAIN — کل برنامه داخل یه تابعه و آخرش exit: اگه فایل وسط اجرا عوض بشه
#  (scp/cp روی همین فایل)، bash کد نیمه‌جدید رو اجرا نمیکنه
# ════════════════════════════════════════════════
# دستور ناقص (مثلاً "mon" → monitor). اگه به چندتا بخوره، پیشنهاد میده
ALL_CMDS="monitor add paste import create enable disable restart test edit rollback delete doctor status logs backup restore up-all down-all install help version"
CMD_ALIASES="load up down remove check list undo top install-service -h --help --version"
resolve_cmd() {
    local c hits=()
    [ -z "$CMD" ] && return 0
    [[ " $ALL_CMDS $CMD_ALIASES " == *" $CMD "* ]] && return 0
    for c in $ALL_CMDS; do [[ "$c" == "$CMD"* ]] && hits+=("$c"); done
    case ${#hits[@]} in
        1) [ -t 1 ] && echo -e "  ${DIM}→ ${hits[0]}${NC}"
           CMD="${hits[0]}"; return 0 ;;
        0) err "Unknown command: $CMD"; echo ""; echo "  Run 'wg-manager help' for all commands, or just 'wg-manager' for the menu."; return 1 ;;
        *) err "'$CMD' could be: ${hits[*]}"; return 1 ;;
    esac
}

main() {
    local a
    ARGS=()
    for a in "$@"; do
        case "$a" in
            -y|--yes)     ASSUME_YES=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            -q|--quiet)   QUIET=1 ;;
            --fix)        DOC_FIX=1 ;;
            --json)       JSON=1 ;;
            *)            ARGS+=("$a") ;;
        esac
    done
    CMD="${ARGS[0]:-}"
    ARG1="${ARGS[1]:-}"
    ARG2="${ARGS[2]:-}"
    resolve_cmd || exit 1

    case "$CMD" in
        help|-h|--help) usage; exit 0 ;;
        version|--version) echo "$VERSION"; exit 0 ;;
    esac

    check_root
    check_deps
    [ -n "$FG" ] && printf '%b' "$FG"
    mkdir -p "$BASE_DIR" "$BACKUP_DIR" "$RUN_DIR"
    chmod 700 "$BASE_DIR" "$BACKUP_DIR" "$RUN_DIR"
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"

    # نصب تازه: شماره schema از همین الان ثبت بشه
    if [ ! -f "$SCHEMA_FILE" ] && [ ! -f "$MIGRATION_MARK" ] && [ ! -f "$MIGRATION_MARK_V5" ] && \
       [ -z "$(list_tunnels)" ]; then
        echo "$SCHEMA_VERSION" > "$SCHEMA_FILE"
    fi
    # کانفیگ‌ها مال یه نسخه جدیدترن (مثلاً بعد از برگشت به نسخه قدیمی) → فقط خوندنی
    if [ "$(schema_current)" -gt "$SCHEMA_VERSION" ]; then
        case "$CMD" in
            status|list|logs|test|backup|monitor) ;;
            *) err "These configs were written by a newer wg-manager — install that version (only status/logs/test/backup work here)"
               exit 1 ;;
        esac
    fi

    # قفل: دستورهای کوتاهی که چیزی رو عوض میکنن از اول قفل میگیرن.
    # add/edit/delete/restore فقط موقع اعمال، و منو برای هر کار جدا.
    # status/test/logs/backup چیزی رو عوض نمیکنن (و 'logs -f' نباید watchdog رو بلاک کنه)
    case "$CMD" in
        doctor|check)
            if [ "$QUIET" = 1 ]; then watchdog_lock || exit 0; else lock || exit 1; fi ;;
        enable|load|up|disable|down|restart|up-all|down-all|install|install-service)
            lock || exit 1 ;;
    esac

    # یادآوری‌ها (نه برای watchdog/بوت/خروجی json)
    if [ "$QUIET" != 1 ] && [ "$JSON" != 1 ]; then
        case "$CMD" in
            up-all|down-all|install|install-service|monitor|"") ;;
            *) schema_pending && warn "Upgrade pending — run: wg-manager install"
               warn_outdated_install ;;
        esac
        [ -z "$CMD" ] && warn_outdated_install
    fi

    case "$CMD" in
        "")                  menu ;;
        add)                 cmd_add ;;
        paste)               cmd_add paste "" "$ARG1" ;;
        import)
            [ -n "$ARG1" ] || { err "Usage: wg-manager import <file.conf|mullvad.zip|folder> [name]"; exit 1; }
            # zip یا پوشه → چندتایی؛ یه فایل .conf → مثل قبل
            if [ -d "$ARG1" ] || [[ "$ARG1" == *.zip ]]; then cmd_import_bulk "$ARG1"
            else cmd_add file "$ARG1" "$ARG2"; fi ;;
        create)              cmd_add manual ;;
        enable|load|up)      cmd_enable "$ARG1" ;;
        disable|down)        cmd_disable "$ARG1" ;;
        restart)             cmd_restart "$ARG1" ;;
        test)                cmd_test "$ARG1" ;;
        edit)                cmd_edit "$ARG1" ;;
        delete|remove)       cmd_delete "$ARG1" ;;
        rollback|undo)       cmd_rollback "$ARG1" ;;
        doctor|check)        cmd_doctor ;;
        status|list)         cmd_status ;;
        logs)                cmd_logs "$ARG1" ;;
        backup)              cmd_backup "$ARG1" ;;
        monitor|top)         cmd_monitor ;;
        restore)             cmd_restore "$ARG1" ;;
        up-all)              cmd_up_all ;;
        down-all)            cmd_down_all ;;
        install|install-service) cmd_install ;;
        *)                   err "Unknown command: $CMD"; echo ""; usage; exit 1 ;;
    esac
}

main "$@"
exit $?
