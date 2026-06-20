#!/bin/bash
# install.sh — installer untuk sysinfo.sh
# Usage: wget -qO /tmp/install.sh https://raw.githubusercontent.com/rustam1971/sysinfo/main/install.sh && bash /tmp/install.sh

GITHUB_RAW="https://raw.githubusercontent.com/rustam1971/sysinfo/main"
SCRIPT_URL="${GITHUB_RAW}/sysinfo.sh"
INSTALL_PATH="/usr/local/bin/sysinfo.sh"
CRON_MONITOR="2-57/5 * * * * nice -n 19 /usr/local/bin/sysinfo.sh"
CRON_UPDATE="0 3 * * * wget -qO /tmp/sysinfo_new.sh ${GITHUB_RAW}/sysinfo.sh && if ! diff -q /tmp/sysinfo_new.sh ${INSTALL_PATH} &>/dev/null; then mv /tmp/sysinfo_new.sh ${INSTALL_PATH} && chmod +x ${INSTALL_PATH}; else rm -f /tmp/sysinfo_new.sh; fi"
LOG_DIR="/var/log/sysinfo"

# Warna
GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[0;33m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; }
success() { echo -e "${GREEN}[OK]${RESET}    $1"; }

echo ""
echo "================================================"
echo "  sysinfo.sh Installer"
echo "================================================"
echo ""

# -----------------------------------------------
# Cek root
# -----------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    error "Script harus dijalankan sebagai root."
    echo "       Gunakan: sudo bash install.sh"
    exit 1
fi

# -----------------------------------------------
# Cek OS
# -----------------------------------------------
info "Memeriksa OS..."

if [[ ! -f /etc/os-release ]]; then
    error "Tidak dapat mendeteksi OS."
    exit 1
fi

source /etc/os-release

case "${ID,,}" in
    ubuntu|debian) ;;
    *)
        error "OS tidak didukung: ${PRETTY_NAME:-$ID}"
        echo "       Script ini hanya berjalan di Ubuntu atau Debian."
        exit 1
        ;;
esac

_ver_major=$(echo "${VERSION_ID}" | cut -d'.' -f1)

if [[ "${ID,,}" == "ubuntu" && -n "$_ver_major" && "$_ver_major" -lt 20 ]]; then
    error "Ubuntu ${VERSION_ID} tidak didukung. Butuh Ubuntu 20.04+."
    exit 1
fi

if [[ "${ID,,}" == "debian" && -n "$_ver_major" && "$_ver_major" -lt 10 ]]; then
    error "Debian ${VERSION_ID} tidak didukung. Butuh Debian 10+."
    exit 1
fi

success "OS OK: ${PRETTY_NAME}"

# -----------------------------------------------
# Cek dependency
# -----------------------------------------------
info "Memeriksa dependency..."

for cmd in wget curl awk ps ss ip df findmnt; do
    if ! command -v "$cmd" &>/dev/null; then
        warn "${cmd} tidak ditemukan, mencoba install..."
        apt-get install -y "$cmd" &>/dev/null || {
            error "Gagal install ${cmd}."
            exit 1
        }
    fi
done

success "Dependency OK"

# -----------------------------------------------
# Download sysinfo.sh
# -----------------------------------------------
info "Mengunduh sysinfo.sh dari GitHub..."

if ! wget -qO "${INSTALL_PATH}.tmp" "${SCRIPT_URL}"; then
    error "Gagal mengunduh sysinfo.sh dari:"
    echo "       ${SCRIPT_URL}"
    rm -f "${INSTALL_PATH}.tmp"
    exit 1
fi

if grep -q "<!DOCTYPE html>" "${INSTALL_PATH}.tmp" 2>/dev/null; then
    error "URL tidak valid atau file tidak ditemukan di GitHub."
    rm -f "${INSTALL_PATH}.tmp"
    exit 1
fi

mv "${INSTALL_PATH}.tmp" "${INSTALL_PATH}"
chmod +x "${INSTALL_PATH}"
success "sysinfo.sh berhasil diinstall ke ${INSTALL_PATH}"

# -----------------------------------------------
# Buat log directory
# -----------------------------------------------
mkdir -p "${LOG_DIR}"
success "Log directory: ${LOG_DIR}"

# -----------------------------------------------
# Setup cronjob monitoring
# -----------------------------------------------
info "Memeriksa cronjob monitoring..."

if crontab -l 2>/dev/null | grep -v "sysinfo_new" | grep -qF "sysinfo.sh"; then
    warn "Cronjob monitoring sudah ada, dilewati."
else
    ( crontab -l 2>/dev/null; echo "${CRON_MONITOR}" ) | crontab -
    success "Cronjob monitoring ditambahkan: setiap 5 menit"
fi

# -----------------------------------------------
# Setup cronjob auto-update harian
# -----------------------------------------------
info "Memeriksa cronjob auto-update..."

if crontab -l 2>/dev/null | grep -qF "sysinfo_new.sh"; then
    warn "Cronjob auto-update sudah ada, dilewati."
else
    ( crontab -l 2>/dev/null; echo "${CRON_UPDATE}" ) | crontab -
    success "Cronjob auto-update ditambahkan: setiap hari jam 03:00"
fi

# -----------------------------------------------
# Test run
# -----------------------------------------------
info "Menjalankan test..."
echo ""

if bash "${INSTALL_PATH}" -v; then
    echo ""
    success "Test berhasil."
else
    echo ""
    warn "Test selesai dengan warning."
fi

# -----------------------------------------------
# Summary
# -----------------------------------------------
echo ""
echo "================================================"
success "Instalasi selesai!"
echo ""
echo "  Script     : ${INSTALL_PATH}"
echo "  Log dir    : ${LOG_DIR}"
echo "  Monitoring : ${CRON_MONITOR}"
echo "  Auto-update: setiap hari jam 03:00"
echo ""
echo "  Jalankan manual : sysinfo.sh -v"
echo "  Lihat log       : tail -f ${LOG_DIR}/sysinfo-$(date +%Y-%m-%d).log"
echo "  Cek crontab     : crontab -l"
echo "================================================"
echo ""
