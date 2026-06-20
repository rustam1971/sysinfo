#!/bin/bash
# sysinfo.sh — simpan info sistem ke log per hari, keep 2 tahun
# Usage: ./sysinfo.sh        -> simpan ke log saja (cron)
#        ./sysinfo.sh -v     -> tampilkan ke console saja (manual)
# Crontab: 2-57/5 * * * * nice -n 19 /usr/local/bin/sysinfo.sh
# Supported: Ubuntu 20.04+ / Debian 10+

# -----------------------------------------------
# Cek kompatibilitas OS
# -----------------------------------------------
if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: Tidak dapat mendeteksi OS. Script ini hanya mendukung Ubuntu/Debian."
    exit 1
fi

source /etc/os-release

case "${ID,,}" in
    ubuntu|debian) ;;
    *)
        echo "ERROR: OS tidak didukung — terdeteksi: ${PRETTY_NAME:-$ID}"
        echo "       Script ini hanya berjalan di Ubuntu atau Debian."
        echo "       CentOS, RHEL, Fedora, dan distro lain tidak didukung."
        exit 1
        ;;
esac

_ver_major=$(echo "${VERSION_ID}" | cut -d'.' -f1)

if [[ "${ID,,}" == "ubuntu" && -n "$_ver_major" && "$_ver_major" -lt 20 ]]; then
    echo "ERROR: Ubuntu ${VERSION_ID} tidak didukung."
    echo "       Script ini membutuhkan Ubuntu 20.04 atau lebih baru."
    exit 1
fi

if [[ "${ID,,}" == "debian" && -n "$_ver_major" && "$_ver_major" -lt 10 ]]; then
    echo "ERROR: Debian ${VERSION_ID} tidak didukung."
    echo "       Script ini membutuhkan Debian 10 (Buster) atau lebih baru."
    exit 1
fi

# -----------------------------------------------
# Konfigurasi
# -----------------------------------------------
LOG_DIR="/var/log/sysinfo"
DATE=$(date '+%Y-%m-%d')
LOG_FILE="${LOG_DIR}/sysinfo-${DATE}.log"
KEEP_DAYS=730
FAILED_LOGIN_HOURS=24
MONITOR_SERVICES=(ssh cron docker nginx mysql)
TMP_DIR="/tmp/sysinfo_$$"
VERBOSE=false
[[ "${1:-}" == "-v" ]] && VERBOSE=true

mkdir -p "${LOG_DIR}" "${TMP_DIR}"
trap "rm -rf ${TMP_DIR}" EXIT

# -----------------------------------------------
# Auto-install lm-sensors jika tidak ada
# -----------------------------------------------
if ! command -v sensors &>/dev/null; then
    apt-get install -y lm-sensors &>/dev/null
    sensors-detect --auto &>/dev/null
fi

# -----------------------------------------------
# Warna
# -----------------------------------------------
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
RED='\033[0;31m';  YELLOW='\033[0;33m'; RESET='\033[0m'

# -----------------------------------------------
# Helper functions
# -----------------------------------------------
log() {
    if $VERBOSE; then
        printf "${CYAN}%-22s${RESET}${GREEN}%s${RESET}\n" "${2:-}" "${3:-}"
    else
        echo "$(date '+%H:%M:%S') | $1" >> "${LOG_FILE}"
    fi
}

log_bar() {
    local label=$1 pct=$2 info=$3 log_msg=$4
    local filled=$(awk "BEGIN{printf \"%d\",($pct*40)/100}")
    local empty=$(( 40-filled )); local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="#"; done
    for (( i=0; i<empty;  i++ )); do bar+="."; done
    if $VERBOSE; then
        printf "${CYAN}%-22s${RESET}${GREEN}[%s] %s${RESET}\n" "${label}" "${bar}" "${info}"
    else
        echo "$(date '+%H:%M:%S') | ${log_msg}" >> "${LOG_FILE}"
    fi
}

print_header() {
    $VERBOSE && echo -e "\n${BOLD}${YELLOW}System Information${RESET}"
    $VERBOSE && printf '%0.s-' {1..40} && echo
}

print_footer() { $VERBOSE && echo; }

get_field() {
    hostnamectl 2>/dev/null | grep -i "^ *$1" | head -1 | sed 's/^[^:]*: *//'
}

# -----------------------------------------------
# Auto-scale
# -----------------------------------------------
scale_bits() {
    awk "BEGIN {
        b=$1
        if(b<1000) printf \"%.2f bit/s\",b
        else if(b<1000000) printf \"%.2f Kbit/s\",b/1000
        else if(b<1000000000) printf \"%.2f Mbit/s\",b/1000000
        else printf \"%.2f Gbit/s\",b/1000000000
    }"
}

scale_bytes() {
    awk "BEGIN {
        b=$1
        if(b<1024) printf \"%.2f B/s\",b
        else if(b<1048576) printf \"%.2f KiB/s\",b/1024
        else if(b<1073741824) printf \"%.2f MiB/s\",b/1048576
        else printf \"%.2f GiB/s\",b/1073741824
    }"
}

# -----------------------------------------------
# Resolve device root
# -----------------------------------------------
resolve_dev() {
    local raw
    raw=$(findmnt -n -o SOURCE / | sed 's|/dev/||')
    if awk '{print $3}' /proc/diskstats 2>/dev/null | grep -qx "$raw"; then
        echo "$raw"
    else
        echo "$raw" | sed 's/[0-9]*$//'
    fi
}

# -----------------------------------------------
# Sampling paralel
# -----------------------------------------------
sample_cpu() {
    read -r cpu user nice system idle iowait rest < /proc/stat; sleep 1
    read -r cpu user2 nice2 system2 idle2 iowait2 rest2 < /proc/stat
    used=$(( (user2+nice2+system2)-(user+nice+system) ))
    total=$(( (user2+nice2+system2+idle2+iowait2)-(user+nice+system+idle+iowait) ))
    awk "BEGIN{printf \"%d\",($used/$total)*100}" > "${TMP_DIR}/cpu"
}

sample_disk_io() {
    local dev r1 w1 r2 w2
    dev=$(resolve_dev)
    r1=$(awk -v d="$dev" '$3==d{print $6}' /proc/diskstats 2>/dev/null)
    w1=$(awk -v d="$dev" '$3==d{print $10}' /proc/diskstats 2>/dev/null)
    sleep 1
    r2=$(awk -v d="$dev" '$3==d{print $6}' /proc/diskstats 2>/dev/null)
    w2=$(awk -v d="$dev" '$3==d{print $10}' /proc/diskstats 2>/dev/null)
    local rb=$(( (${r2:-0}-${r1:-0})*512 ))
    local wb=$(( (${w2:-0}-${w1:-0})*512 ))
    echo "$(scale_bytes "$rb") read / $(scale_bytes "$wb") write" > "${TMP_DIR}/diskio"
}

sample_network() {
    local ifaces; ifaces=$(ls /sys/class/net/ | grep -vE '^(lo|bonding_masters)$')
    declare -A rx1_map tx1_map
    for iface in $ifaces; do
        rx1_map[$iface]=$(cat /sys/class/net/${iface}/statistics/rx_bytes 2>/dev/null || echo 0)
        tx1_map[$iface]=$(cat /sys/class/net/${iface}/statistics/tx_bytes 2>/dev/null || echo 0)
    done
    sleep 1
    for iface in $ifaces; do
        local ip rx2 tx2
        ip=$(ip -4 addr show "$iface" 2>/dev/null \
            | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        [[ -z "$ip" ]] && ip="no IP"
        rx2=$(cat /sys/class/net/${iface}/statistics/rx_bytes 2>/dev/null || echo 0)
        tx2=$(cat /sys/class/net/${iface}/statistics/tx_bytes 2>/dev/null || echo 0)
        echo "${ip} [ $(scale_bits $(( (rx2-rx1_map[$iface])*8 ))) in / $(scale_bits $(( (tx2-tx1_map[$iface])*8 ))) out ]" \
            > "${TMP_DIR}/net_${iface}"
    done
}

# -----------------------------------------------
# Fungsi data
# -----------------------------------------------
get_cpu_model() { grep -m1 "model name" /proc/cpuinfo | sed 's/.*: //;s/  */ /g'; }

get_cpu_temp() {
    command -v sensors &>/dev/null || { echo ""; return; }
    local t; t=$(sensors 2>/dev/null | grep -E '(Core 0|Package|Tdie|Tctl)' \
        | head -1 | grep -oP '[+-]\d+\.\d+' | head -1)
    [[ -n "$t" ]] && echo "${t}°C" || echo ""
}

get_mem_info() {
    local mt ma mu
    mt=$(grep MemTotal    /proc/meminfo | awk '{print $2}')
    ma=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mu=$(( mt-ma ))
    awk "BEGIN{printf \"%.2f%% (%.2f GiB of %.2f GiB)\",$mu/$mt*100,$mu/1048576,$mt/1048576}"
}
get_mem_pct() {
    local mt ma mu
    mt=$(grep MemTotal    /proc/meminfo | awk '{print $2}')
    ma=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mu=$(( mt-ma ))
    awk "BEGIN{printf \"%d\",$mu/$mt*100}"
}

get_swap_info() {
    local st sf su
    st=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    [[ "$st" -eq 0 ]] && echo "" && return
    sf=$(grep SwapFree /proc/meminfo | awk '{print $2}'); su=$(( st-sf ))
    awk "BEGIN{printf \"%.2f%% (%.2f GiB of %.2f GiB)\",$su/$st*100,$su/1048576,$st/1048576}"
}
get_swap_pct() {
    local st sf su
    st=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    [[ "$st" -eq 0 ]] && echo "0" && return
    sf=$(grep SwapFree /proc/meminfo | awk '{print $2}'); su=$(( st-sf ))
    awk "BEGIN{printf \"%d\",$su/$st*100}"
}

get_disk_info() {
    df -k / | awk 'NR==2{printf "%.2f%% (%.2f GiB of %.2f GiB)",$3/$2*100,$3/1048576,$2/1048576}'
}
get_disk_pct()   { df -k / | awk 'NR==2{printf "%d",$3/$2*100}'; }
get_inode_info() { df -i / | awk 'NR==2{printf "%.2f%% (%d of %d)",$3/$2*100,$3,$2}'; }
get_inode_pct()  { df -i / | awk 'NR==2{printf "%d",$3/$2*100}'; }

get_kernel_info() {
    local running latest reboot_req
    running=$(uname -r)
    latest=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
    if [[ -f /var/run/reboot-required ]] || \
       [[ -n "$latest" && "$running" != "$latest" ]]; then
        reboot_req="required"
    else
        reboot_req="not required"
    fi
    echo "${running}|${latest:-$running}|${reboot_req}"
}

get_ntp_info() {
    local svc synced is_ct
    if command -v timedatectl &>/dev/null; then
        svc=$(timedatectl show 2>/dev/null | grep "^NTP=" | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
        synced=$(timedatectl show 2>/dev/null | grep "^NTPSynchronized=" | cut -d= -f2 | tr '[:upper:]' '[:lower:]')
        [[ "$svc" == "yes" ]] && svc="active" || svc="inactive"
        [[ "$synced" == "yes" ]] && synced="yes" || synced="no"
        if [[ "$svc" == "inactive" ]]; then
            is_ct=$(systemd-detect-virt --container 2>/dev/null)
            [[ -n "$is_ct" && "$is_ct" != "none" ]] && svc="inactive (container)"
        fi
    else
        svc="N/A"; synced="N/A"
    fi
    echo "${svc}|${synced}"
}

get_dns_resolvers() {
    local r
    if command -v resolvectl &>/dev/null; then
        r=$(resolvectl status 2>/dev/null | grep -i "DNS Servers" | head -1 \
            | sed 's/.*DNS Servers: *//' | tr ' ' ',')
    fi
    [[ -z "$r" ]] && r=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null \
        | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    echo "${r:-none}"
}

get_default_gateway() {
    local gw
    gw=$(ip route show default 2>/dev/null | awk '/default/{print $3,"via",$5}' | head -1)
    echo "${gw:-none}"
}

get_firewall_status() {
    if command -v ufw &>/dev/null; then
        local st rules
        st=$(ufw status 2>/dev/null | grep -i "^Status:" | awk '{print tolower($2)}')
        if [[ "$st" == "active" ]]; then
            rules=$(ufw status 2>/dev/null | grep -c "ALLOW\|DENY\|REJECT" || echo 0)
            rules=$(echo "$rules" | tr -d '[:space:]')
            echo "active (${rules} rules)"
        else
            echo "${st:-inactive}"
        fi
    elif command -v iptables &>/dev/null; then
        local rules
        rules=$(iptables -L 2>/dev/null \
            | grep -E "^(ACCEPT|DROP|REJECT)" | wc -l | tr -d '[:space:]')
        echo "iptables (${rules} rules)"
    else
        echo "not installed"
    fi
}

get_open_ports() {
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oP '(?<=:)\d+$' \
        | sort -n | uniq | tr '\n' ',' | sed 's/,$//'
}

get_uptime() {
    local up days hours minutes
    up=$(awk '{print int($1)}' /proc/uptime)
    days=$(( up/86400 )); hours=$(( (up%86400)/3600 )); minutes=$(( (up%3600)/60 ))
    echo "${days} days, ${hours} hours, ${minutes} minutes"
}

get_last_reboot() {
    last -x -F reboot 2>/dev/null | grep "^reboot" | head -1 \
        | awk '{print $5,$6,$7,$8,$9}'
}

get_process_count() { ps -e --no-headers | wc -l; }
get_pid_max()       { cat /proc/sys/kernel/pid_max; }
get_process_pct()   { awk "BEGIN{printf \"%d\",$1/$2*100}"; }
get_load_avg()      { awk '{print $1", "$2", "$3}' /proc/loadavg; }

get_logged_users() {
    local users count
    users=$(who | awk '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')
    count=$(who | awk '{print $1}' | sort -u | wc -l)
    [[ -z "$users" ]] && echo "none" || echo "${count} [ ${users} ]"
}

get_failed_logins() {
    local count=0
    if journalctl --since "${FAILED_LOGIN_HOURS} hours ago" \
        _SYSTEMD_UNIT=ssh.service 2>/dev/null | grep -qi "Failed password"; then
        count=$(journalctl --since "${FAILED_LOGIN_HOURS} hours ago" \
            _SYSTEMD_UNIT=ssh.service 2>/dev/null | grep -c "Failed password")
    elif [[ -f /var/log/auth.log ]]; then
        count=$(grep "Failed password" /var/log/auth.log 2>/dev/null \
            | awk -v hrs="$FAILED_LOGIN_HOURS" \
            'BEGIN{cmd="date -d \"-"hrs" hours\" \"+%b %e %H:%M:%S\"";cmd|getline cutoff;close(cmd)}
             $0>=cutoff{count++}END{print count+0}')
    fi
    echo "${count} (last ${FAILED_LOGIN_HOURS}h)"
}

get_pending_updates() {
    command -v apt &>/dev/null || { echo "N/A"; return; }
    [[ -f /var/lib/apt/lists/lock ]] || { echo "N/A"; return; }
    apt-get -s --no-act upgrade 2>/dev/null | grep "^Inst" | awk '{print $2}' | sort
}

# -----------------------------------------------
# Sub-output functions
# -----------------------------------------------
log_top_cpu() {
    log "Top CPU proses   :" "Top CPU proses :" ""
    local i=1
    ps -eo pid,pcpu,comm --sort=-%cpu --no-headers 2>/dev/null | head -5 | \
    while read -r pid pcpu comm; do
        local entry; entry=$(printf "  %-3s %-16s %-6s (pid %s)" "${i}." "$comm" "${pcpu}%" "$pid")
        if $VERBOSE; then echo -e "${GREEN}${entry}${RESET}"
        else echo "$(date '+%H:%M:%S') |${entry}" >> "${LOG_FILE}"; fi
        (( i++ ))
    done
}

log_top_mem() {
    log "Top MEM proses   :" "Top MEM proses :" ""
    local i=1
    ps -eo pid,rss,comm --sort=-rss --no-headers 2>/dev/null | head -5 | \
    while read -r pid rss comm; do
        local mib entry
        mib=$(awk "BEGIN{printf \"%.1f\",$rss/1024}")
        entry=$(printf "  %-3s %-16s %-10s (pid %s)" "${i}." "$comm" "${mib} MiB" "$pid")
        if $VERBOSE; then echo -e "${GREEN}${entry}${RESET}"
        else echo "$(date '+%H:%M:%S') |${entry}" >> "${LOG_FILE}"; fi
        (( i++ ))
    done
}

log_firewall() {
    local val="$FIREWALL"
    if $VERBOSE; then
        if [[ "$val" == active* || "$val" == iptables* ]]; then
            printf "${CYAN}%-22s${RESET}${GREEN}%s${RESET}\n" "Firewall :" "$val"
        else
            printf "${CYAN}%-22s${RESET}${RED}%s${RESET}\n"   "Firewall :" "$val"
        fi
    else
        echo "$(date '+%H:%M:%S') | Firewall        : ${val}" >> "${LOG_FILE}"
    fi
}

log_gateway() {
    local val="$DEFAULT_GW"
    if $VERBOSE; then
        if [[ "$val" == "none" ]]; then
            printf "${CYAN}%-22s${RESET}${RED}%s${RESET}\n"   "Default gateway :" "$val"
        else
            printf "${CYAN}%-22s${RESET}${GREEN}%s${RESET}\n" "Default gateway :" "$val"
        fi
    else
        echo "$(date '+%H:%M:%S') | Default gateway : ${val}" >> "${LOG_FILE}"
    fi
}

log_ntp_service() {
    local val="$NTP_SERVICE"
    if $VERBOSE; then
        if [[ "$val" == "active" ]]; then
            printf "${CYAN}%-22s${RESET}${GREEN}%s${RESET}\n" "NTP service :" "$val"
        else
            printf "${CYAN}%-22s${RESET}${RED}%s${RESET}\n"   "NTP service :" "$val"
        fi
    else
        echo "$(date '+%H:%M:%S') | NTP service     : ${val}" >> "${LOG_FILE}"
    fi
}

log_services() {
    local tr ta
    tr=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | wc -l)
    ta=$(systemctl list-units --type=service --no-legend 2>/dev/null | wc -l)
    log "Services total   : ${tr} running of ${ta}" "Services total :" "${tr} running of ${ta}"
    for svc in "${MONITOR_SERVICES[@]}"; do
        local st check_svc="$svc"
        # Auto-detect ssh vs ssh.socket
        if [[ "$svc" == "ssh" ]]; then
            if ! systemctl is-active ssh &>/dev/null; then
                if systemctl is-active ssh.socket &>/dev/null; then
                    check_svc="ssh.socket"
                fi
            fi
        fi
        st=$(systemctl is-active "${check_svc}" 2>/dev/null)
        [[ -z "$st" ]] && st="not-found"
        if $VERBOSE; then
            if [[ "$st" == "active" ]]; then
                printf "${CYAN}%-22s${RESET}${GREEN}%s${RESET}\n" "Service ${svc} :" "$st"
            else
                printf "${CYAN}%-22s${RESET}${RED}%s${RESET}\n"   "Service ${svc} :" "$st"
            fi
        else
            echo "$(date '+%H:%M:%S') | Service ${svc}       : ${st}" >> "${LOG_FILE}"
        fi
    done
}

log_pending_updates() {
    local pkgs count
    pkgs=$(get_pending_updates)
    if [[ "$pkgs" == "N/A" ]]; then
        log "Pending updates  : N/A" "Pending updates :" "N/A"; return
    fi
    count=$(echo "$pkgs" | sed '/^$/d' | wc -l)
    if [[ "$count" -eq 0 ]]; then
        log "Pending updates  : 0" "Pending updates :" "0"; return
    fi
    log "Pending updates  : ${count} packages" "Pending updates :" "${count} packages"
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        log "  - ${pkg}" "" "  - ${pkg}"
    done <<< "$pkgs"
}

# -----------------------------------------------
# Jalankan sampling paralel
# -----------------------------------------------
sample_cpu & sample_disk_io & sample_network & wait

CPU_USAGE=$(cat "${TMP_DIR}/cpu"   2>/dev/null || echo 0)
DISK_IO=$(cat   "${TMP_DIR}/diskio" 2>/dev/null || echo "N/A")

# -----------------------------------------------
# Kumpulkan data
# -----------------------------------------------
CPU_CORES=$(nproc)
CPU_MODEL=$(get_cpu_model);   CPU_TEMP=$(get_cpu_temp)
MEM_INFO=$(get_mem_info);     MEM_PCT=$(get_mem_pct)
SWAP_INFO=$(get_swap_info);   SWAP_PCT=$(get_swap_pct)
DISK_INFO=$(get_disk_info);   DISK_PCT=$(get_disk_pct)
INODE_INFO=$(get_inode_info); INODE_PCT=$(get_inode_pct)
OPEN_PORTS=$(get_open_ports)
DNS_RESOLVERS=$(get_dns_resolvers)
DEFAULT_GW=$(get_default_gateway)
FIREWALL=$(get_firewall_status)
NTP_INFO=$(get_ntp_info)
NTP_SERVICE=$(echo "$NTP_INFO" | cut -d'|' -f1)
NTP_SYNCED=$(echo  "$NTP_INFO" | cut -d'|' -f2)
KERNEL_INFO=$(get_kernel_info)
KERNEL_RUNNING=$(echo "$KERNEL_INFO" | cut -d'|' -f1)
KERNEL_LATEST=$(echo  "$KERNEL_INFO" | cut -d'|' -f2)
KERNEL_REBOOT=$(echo  "$KERNEL_INFO" | cut -d'|' -f3)
UPTIME_INFO=$(get_uptime);    LAST_REBOOT=$(get_last_reboot)
PROCESS_COUNT=$(get_process_count); PID_MAX=$(get_pid_max)
PROCESS_PCT=$(get_process_pct "$PROCESS_COUNT" "$PID_MAX")
LOAD_AVG=$(get_load_avg)
LOGGED_USERS=$(get_logged_users)
FAILED_LOGINS=$(get_failed_logins)
STATIC_HOSTNAME=$(get_field "Static hostname")
CHASSIS=$(get_field "Chassis");    MACHINE_ID=$(get_field "Machine ID")
BOOT_ID=$(get_field "Boot ID");    VIRT=$(get_field "Virtualization")
OS=$(get_field "Operating System"); KERNEL=$(get_field "Kernel")
ARCH=$(get_field "Architecture");  HW_VENDOR=$(get_field "Hardware Vendor")
HW_MODEL=$(get_field "Hardware Model")

# -----------------------------------------------
# Output
# -----------------------------------------------
print_header
log "========================================"
log "Static hostname : ${STATIC_HOSTNAME:-N/A}"  "Static hostname :"  "${STATIC_HOSTNAME:-N/A}"
log "Chassis         : ${CHASSIS:-N/A}"           "Chassis :"          "${CHASSIS:-N/A}"
log "Machine ID      : ${MACHINE_ID:-N/A}"        "Machine ID :"       "${MACHINE_ID:-N/A}"
log "Boot ID         : ${BOOT_ID:-N/A}"           "Boot ID :"          "${BOOT_ID:-N/A}"
log "Virtualization  : ${VIRT:-N/A}"              "Virtualization :"   "${VIRT:-N/A}"
log "Operating System: ${OS:-N/A}"               "Operating System :" "${OS:-N/A}"
log "Kernel          : ${KERNEL:-N/A}"            "Kernel :"           "${KERNEL:-N/A}"
log "Architecture    : ${ARCH:-N/A}"              "Architecture :"     "${ARCH:-N/A}"
log "Hardware Vendor : ${HW_VENDOR:-N/A}"         "Hardware Vendor :"  "${HW_VENDOR:-N/A}"
log "Hardware Model  : ${HW_MODEL:-N/A}"          "Hardware Model :"   "${HW_MODEL:-N/A}"
log "CPU Model       : ${CPU_MODEL:-N/A}"         "CPU Model :"        "${CPU_MODEL:-N/A}"
[[ -n "$CPU_TEMP" ]] && \
log "CPU Temp        : ${CPU_TEMP}"               "CPU Temp :"         "${CPU_TEMP}"
log "Kernel running  : ${KERNEL_RUNNING}"         "Kernel running :"   "${KERNEL_RUNNING}"
log "Kernel latest   : ${KERNEL_LATEST}"          "Kernel latest :"    "${KERNEL_LATEST}"
if $VERBOSE; then
    [[ "$KERNEL_REBOOT" == "required" ]] \
        && printf "${CYAN}%-22s${RESET}${RED}%s${RESET}\n"   "Kernel reboot :" "${KERNEL_REBOOT}" \
        || printf "${CYAN}%-22s${RESET}${GREEN}%s${RESET}\n" "Kernel reboot :" "${KERNEL_REBOOT}"
else
    echo "$(date '+%H:%M:%S') | Kernel reboot    : ${KERNEL_REBOOT}" >> "${LOG_FILE}"
fi
log "----------------------------------------"
log_bar "CPU usage :"     "$CPU_USAGE"   "${CPU_USAGE}% of ${CPU_CORES} CPU(s)"  "CPU usage       : ${CPU_USAGE}% of ${CPU_CORES} CPU(s)"
log_bar "Memory usage :"  "$MEM_PCT"     "${MEM_INFO}"                            "Memory usage    : ${MEM_INFO}"
[[ -n "$SWAP_INFO" ]] && \
log_bar "Swap usage :"    "$SWAP_PCT"    "${SWAP_INFO}"                           "Swap usage      : ${SWAP_INFO}"
log_bar "Disk usage / :"  "$DISK_PCT"    "${DISK_INFO}"                           "Disk usage /    : ${DISK_INFO}"
log_bar "Inode usage / :" "$INODE_PCT"   "${INODE_INFO}"                          "Inode usage /   : ${INODE_INFO}"
log     "Disk I/O /      : ${DISK_IO}"           "Disk I/O / :"      "${DISK_IO}"
log_bar "Processes :"     "$PROCESS_PCT" "${PROCESS_COUNT} of ${PID_MAX}"        "Processes       : ${PROCESS_COUNT} of ${PID_MAX}"
log_top_cpu
log_top_mem
log "Uptime          : ${UPTIME_INFO}"           "Uptime :"          "${UPTIME_INFO}"
log "Last reboot     : ${LAST_REBOOT:-N/A}"      "Last reboot :"     "${LAST_REBOOT:-N/A}"
log "Load average    : ${LOAD_AVG}"              "Load average :"    "${LOAD_AVG}"
log "Logged users    : ${LOGGED_USERS}"          "Logged users :"    "${LOGGED_USERS}"
log "Failed logins   : ${FAILED_LOGINS}"         "Failed logins :"   "${FAILED_LOGINS}"
log_firewall
log_ntp_service
log "NTP synced      : ${NTP_SYNCED}"            "NTP synced :"      "${NTP_SYNCED}"
log "DNS resolver    : ${DNS_RESOLVERS}"         "DNS resolver :"    "${DNS_RESOLVERS}"
log_gateway
log "Open ports      : ${OPEN_PORTS:-none}"      "Open ports :"      "${OPEN_PORTS:-none}"

# Network per interface
ifaces=$(ls /sys/class/net/ | grep -vE '^(lo|bonding_masters)$')
for iface in $ifaces; do
    info=$(cat "${TMP_DIR}/net_${iface}" 2>/dev/null || echo "N/A")
    if $VERBOSE; then
        printf "${CYAN}%-22s${RESET}${GREEN}%s${RESET}\n" "Network ${iface} :" "${info}"
    else
        echo "$(date '+%H:%M:%S') | Network ${iface}     : ${info}" >> "${LOG_FILE}"
    fi
done

log_services
log_pending_updates
print_footer

if ! $VERBOSE; then
    find "${LOG_DIR}" -name "sysinfo-*.log" -mtime +${KEEP_DAYS} -delete
fi
