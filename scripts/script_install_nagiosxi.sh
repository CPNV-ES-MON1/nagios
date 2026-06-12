#!/bin/bash
# =============================================================================
#  Automated Nagios XI 2026 installation on Ubuntu 24.04
#  Reference: https://assets.nagios.com/downloads/nagiosxi/docs/Manual-Install-Instructions-for-Nagios-XI-2026.pdf
#  Usage: sudo bash install_nagiosxi.sh
#
#  MySQL data directory is placed on /dev/nvme1n1 (dedicated disk).
#  The script handles partitioning, formatting, and mounting before
#  MySQL is installed, so the installer writes directly to that disk.
# =============================================================================

set -euo pipefail

# --- Log file ---
LOG_FILE="/tmp/nagiosxi_install_$(date +%Y%m%d_%H%M%S).log"

# Console: minimal (only key steps + errors)
# Log file: everything
log_info()  { echo "[INFO]  $*" >> "$LOG_FILE"; echo "  --> $*"; }
log_ok()    { echo "[OK]    $*" >> "$LOG_FILE"; echo "  [OK] $*"; }
log_warn()  { echo "[WARN]  $*" >> "$LOG_FILE"; echo "  [WARN] $*"; }
log_error() { echo "[ERROR] $*" >> "$LOG_FILE"; echo "  [ERROR] $* -- see $LOG_FILE"; exit 1; }
log_debug() { echo "[DEBUG] $*" >> "$LOG_FILE"; }  # log file only

echo "==> Nagios XI install started. Full log: $LOG_FILE"
echo "==> $(date)" | tee -a "$LOG_FILE"

# =============================================================================
# 1. PRE-FLIGHT CHECKS
# =============================================================================

log_info "Running pre-flight checks..."

# Must run as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root. Use: sudo bash $0"
fi

# OS check
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    log_debug "Detected OS: $PRETTY_NAME"
    if [[ "$ID" != "ubuntu" ]]; then
        log_warn "OS: $PRETTY_NAME — this script is optimized for Ubuntu 24.04."
    fi
fi

# Internet connectivity
log_debug "Checking internet connectivity to assets.nagios.com..."
if ! curl -sf --max-time 10 https://assets.nagios.com > /dev/null 2>&1; then
    log_error "No internet access to assets.nagios.com. Check your network."
fi

# Required tools for disk setup
for cmd in parted mkfs.ext4 blkid; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required tool '$cmd' not found. Install it with: apt install parted e2fsprogs util-linux"
    fi
done

log_ok "Pre-flight checks passed."

# =============================================================================
# 2. MYSQL DISK SETUP — /dev/nvme1n1 → /var/lib/mysql
# =============================================================================

MYSQL_DISK="/dev/nvme1n1"
MYSQL_PART="${MYSQL_DISK}p1"
MYSQL_DIR="/var/lib/mysql"

log_info "Setting up dedicated MySQL disk on $MYSQL_DISK..."

# Verify the disk exists and is a block device
if [[ ! -b "$MYSQL_DISK" ]]; then
    log_error "Disk $MYSQL_DISK not found or is not a block device."
fi

# Safety check: refuse to proceed if the disk already has partitions in use
if lsblk -no MOUNTPOINT "${MYSQL_DISK}" 2>/dev/null | grep -q .; then
    log_error "$MYSQL_DISK has mounted partitions. Aborting to prevent data loss."
fi

# Warn if the disk already has a partition table and give a 10-second bail-out window
if parted -s "$MYSQL_DISK" print &>/dev/null 2>&1; then
    log_warn "$MYSQL_DISK already has a partition table. It will be wiped in 10 seconds."
    log_warn "Press Ctrl+C NOW to abort."
    sleep 10
fi

log_info "Wiping existing signatures on $MYSQL_DISK..."
wipefs -a "$MYSQL_DISK" >> "$LOG_FILE" 2>&1 \
    || log_error "wipefs failed on $MYSQL_DISK."

log_info "Creating GPT partition table and single partition on $MYSQL_DISK..."
parted -s "$MYSQL_DISK" \
    mklabel gpt \
    mkpart primary ext4 0% 100% \
    >> "$LOG_FILE" 2>&1 \
    || log_error "parted failed on $MYSQL_DISK."

# Let the kernel re-read the new partition table
partprobe "$MYSQL_DISK" >> "$LOG_FILE" 2>&1 || true
sleep 2

# Confirm the partition appeared
if [[ ! -b "$MYSQL_PART" ]]; then
    log_error "Partition $MYSQL_PART not found after partitioning. Check dmesg."
fi
log_ok "Partition $MYSQL_PART created."

log_info "Formatting $MYSQL_PART as ext4..."
mkfs.ext4 -L nagios-mysql "$MYSQL_PART" >> "$LOG_FILE" 2>&1 \
    || log_error "mkfs.ext4 failed on $MYSQL_PART."
log_ok "Partition formatted (label: nagios-mysql)."

# Retrieve UUID for fstab (more robust than device path across reboots)
PART_UUID=$(blkid -s UUID -o value "$MYSQL_PART")
if [[ -z "$PART_UUID" ]]; then
    log_error "Could not retrieve UUID from $MYSQL_PART."
fi
log_debug "Partition UUID: $PART_UUID"

# Create the MySQL data directory if it doesn't exist yet
mkdir -p "$MYSQL_DIR"

# Mount the partition at /var/lib/mysql before MySQL is installed
log_info "Mounting $MYSQL_PART at $MYSQL_DIR..."
mount "$MYSQL_PART" "$MYSQL_DIR" >> "$LOG_FILE" 2>&1 \
    || log_error "mount failed for $MYSQL_PART → $MYSQL_DIR."
log_ok "$MYSQL_PART mounted at $MYSQL_DIR."

# Persist the mount in /etc/fstab (idempotent: skip if UUID already present)
if grep -q "$PART_UUID" /etc/fstab 2>/dev/null; then
    log_warn "UUID $PART_UUID already present in /etc/fstab — skipping fstab entry."
else
    log_info "Adding fstab entry for $MYSQL_PART (UUID=$PART_UUID)..."
    echo "UUID=${PART_UUID}  ${MYSQL_DIR}  ext4  defaults,noatime  0  2" >> /etc/fstab
    log_ok "fstab entry added."
fi

# =============================================================================
# 3. MYSQL PASSWORDS — auto-generated (no input required)
# =============================================================================
# Passing empty strings causes fullinstall to generate random passwords.
# They are stored after install in: /usr/local/nagiosxi/etc/xi-sys.cfg

export NAGIOSXI_MYSQL_NAGIOSXI_PASS=""
export NAGIOSXI_MYSQL_DBMAINT_PASS=""
export NAGIOSXI_MYSQL_NAGIOSSQL_PASS=""
export NAGIOSXI_MYSQL_NDOUTILS_PASS=""

log_debug "MySQL passwords set to empty (will be auto-generated by fullinstall)."

# =============================================================================
# 4. DOWNLOAD & EXTRACT
# =============================================================================

WORKDIR="$HOME"
TARBALL="xi-latest.tar.gz"
NAGIOSXI_DIR="nagiosxi"

cd "$WORKDIR"
log_debug "Working directory: $WORKDIR"

# Clean up any previous attempt
if [[ -f "$TARBALL" ]]; then
    log_debug "Removing existing tarball..."
    rm -f "$TARBALL"
fi
if [[ -d "$NAGIOSXI_DIR" ]]; then
    log_debug "Removing existing nagiosxi directory..."
    rm -rf "$NAGIOSXI_DIR"
fi

log_info "Downloading Nagios XI (latest)..."
wget -q --show-progress \
     -O "$TARBALL" \
     https://assets.nagios.com/downloads/nagiosxi/xi-latest.tar.gz >> "$LOG_FILE" 2>&1 \
  || log_error "Download failed."
log_ok "Download complete."

log_info "Extracting archive..."
tar xzf "$TARBALL" >> "$LOG_FILE" 2>&1 || log_error "Extraction failed."
log_ok "Extraction complete."

# =============================================================================
# 5. AUTOMATED INSTALLATION
# =============================================================================

cd "$NAGIOSXI_DIR" || log_error "Directory $NAGIOSXI_DIR not found after extraction."

log_info "Running Nagios XI fullinstall (this may take several minutes)..."

# 4 empty lines answer the 4 MySQL password prompts — passwords are auto-generated.
printf '\n\n\n\n' | ./fullinstall >> "$LOG_FILE" 2>&1 \
  || log_error "fullinstall failed. Check $LOG_FILE for details."

log_ok "Nagios XI installation complete."

# =============================================================================
# 6. POST-INSTALL: VERIFY MYSQL DATA DIRECTORY IS ON DEDICATED DISK
# =============================================================================

log_info "Verifying MySQL data directory mount..."
MOUNTED_DEV=$(findmnt -n -o SOURCE "$MYSQL_DIR" 2>/dev/null || true)
if [[ "$MOUNTED_DEV" == "$MYSQL_PART" ]]; then
    log_ok "MySQL data directory ($MYSQL_DIR) confirmed on $MYSQL_PART."
else
    log_warn "Could not confirm $MYSQL_DIR is on $MYSQL_PART (got: ${MOUNTED_DEV:-none}). Check manually."
fi

# =============================================================================
# 7. PORT RECONFIGURATION — HTTP: 8080 / HTTPS: 8443
# =============================================================================
#
# Nagios XI installs Apache configs in:
#   /etc/apache2/ports.conf              — global Listen directives
#   /etc/apache2/sites-enabled/nagiosxi* — VirtualHost blocks (may vary by distro/version)
#   /etc/apache2/sites-available/        — same files before symlinking
#
# xi-sys.cfg stores the base URL used internally by Nagios XI (e.g. for
# notification links). We patch that too so self-referential URLs are correct.
# =============================================================================
 
HTTP_PORT=8080
HTTPS_PORT=8443
 
log_info "Reconfiguring Apache to listen on HTTP:${HTTP_PORT} / HTTPS:${HTTPS_PORT}..."
 
# --- 7a. ports.conf ---
PORTS_CONF="/etc/apache2/ports.conf"
if [[ -f "$PORTS_CONF" ]]; then
    cp "${PORTS_CONF}" "${PORTS_CONF}.bak_preNagios"
    # Replace "Listen 80" with new port (word-boundary aware, ignores e.g. "Listen 8080" if already set)
    sed -i "s/^\(Listen\) 80$/\1 ${HTTP_PORT}/" "$PORTS_CONF"
    sed -i "s/^\(Listen\) 443$/\1 ${HTTPS_PORT}/" "$PORTS_CONF"
    # Also handle IfModule ssl_module / http2_module blocks
    sed -i "/<IfModule ssl_module>/,/<\/IfModule>/ s/^\(\s*Listen\) 443\b/\1 ${HTTPS_PORT}/" "$PORTS_CONF"
    sed -i "/<IfModule mod_gnutls.c>/,/<\/IfModule>/ s/^\(\s*Listen\) 443\b/\1 ${HTTPS_PORT}/" "$PORTS_CONF"
    log_ok "ports.conf updated."
else
    log_warn "ports.conf not found at $PORTS_CONF — skipping."
fi
 
# --- 7b. VirtualHost blocks in all Apache site configs ---
log_info "Patching VirtualHost port declarations in Apache site configs..."
APACHE_SITES_DIR="/etc/apache2/sites-available"
if [[ -d "$APACHE_SITES_DIR" ]]; then
    for conf_file in "$APACHE_SITES_DIR"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        cp "${conf_file}" "${conf_file}.bak_preNagios" 2>/dev/null || true
        # Replace <VirtualHost *:80> and <VirtualHost _default_:80>
        sed -i "s|<VirtualHost \(.*\):80>|<VirtualHost \1:${HTTP_PORT}>|g" "$conf_file"
        # Replace <VirtualHost *:443> and variants
        sed -i "s|<VirtualHost \(.*\):443>|<VirtualHost \1:${HTTPS_PORT}>|g" "$conf_file"
        log_debug "Patched: $conf_file"
    done
    log_ok "VirtualHost ports updated in $APACHE_SITES_DIR."
else
    log_warn "Apache sites-available directory not found — skipping VirtualHost patch."
fi
 
# --- 7c. Nagios XI internal base URL (xi-sys.cfg) ---
XI_CFG="/usr/local/nagiosxi/etc/xi-sys.cfg"
if [[ -f "$XI_CFG" ]]; then
    cp "${XI_CFG}" "${XI_CFG}.bak_prePortChange"
    # xi-sys.cfg contains a line like: sysprotocol=http or baseurl=http://hostname/nagiosxi
    # Patch any explicit port-80 or port-443 references in baseurl, and add port to bare http/https URLs
    sed -i "s|http://\([^/:]*\)/nagiosxi|http://\1:${HTTP_PORT}/nagiosxi|g" "$XI_CFG"
    sed -i "s|https://\([^/:]*\)/nagiosxi|https://\1:${HTTPS_PORT}/nagiosxi|g" "$XI_CFG"
    log_ok "xi-sys.cfg base URL updated."
else
    log_warn "xi-sys.cfg not found at $XI_CFG — skipping internal URL patch."
fi
 
# --- 7d. Restart Apache to apply changes ---
log_info "Restarting Apache..."
systemctl restart apache2 >> "$LOG_FILE" 2>&1 \
    || log_error "Apache failed to restart after port change. Check: journalctl -u apache2 --no-pager -n 50"
log_ok "Apache restarted successfully."
 
# --- 7e. Quick sanity check — confirm Apache is actually listening on new ports ---
log_info "Verifying Apache is listening on ports ${HTTP_PORT} and ${HTTPS_PORT}..."
sleep 2  # brief settle time
HTTP_LISTEN=$(ss -tlnp | grep ":${HTTP_PORT} " || true)
HTTPS_LISTEN=$(ss -tlnp | grep ":${HTTPS_PORT} " || true)
 
if [[ -n "$HTTP_LISTEN" ]]; then
    log_ok "Apache confirmed listening on HTTP:${HTTP_PORT}."
else
    log_warn "Apache does not appear to be listening on port ${HTTP_PORT}. Check: ss -tlnp | grep apache"
fi
 
if [[ -n "$HTTPS_LISTEN" ]]; then
    log_ok "Apache confirmed listening on HTTPS:${HTTPS_PORT}."
else
    log_warn "Apache does not appear to be listening on port ${HTTPS_PORT} (expected if SSL not yet configured)."
fi
 
# =============================================================================
# 8. POST-INSTALL SUMMARY
# =============================================================================
 
SERVER_IP=$(hostname -I | awk '{print $1}')
PASSWORDS_FILE="/usr/local/nagiosxi/etc/xi-sys.cfg"
 
echo ""
echo "============================================================"
echo "  Nagios XI installation successful!"
echo "============================================================"
echo "  Web UI (HTTP) : http://${SERVER_IP}:${HTTP_PORT}/nagiosxi"
echo "  Web UI (HTTPS): https://${SERVER_IP}:${HTTPS_PORT}/nagiosxi"
echo "  Passwords     : $PASSWORDS_FILE"
echo "  Full log      : $LOG_FILE"
echo "------------------------------------------------------------"
echo "  MySQL disk layout:"
echo "    Disk      : $MYSQL_DISK"
echo "    Partition : $MYSQL_PART  (UUID: $PART_UUID)"
echo "    Mount     : $MYSQL_DIR"
echo "    fstab     : persistent (noatime, fsck order 2)"
echo "------------------------------------------------------------"
echo "  Apache port changes:"
echo "    HTTP  : 80  → ${HTTP_PORT}"
echo "    HTTPS : 443 → ${HTTPS_PORT}"
echo "    Backups of modified configs saved as *.bak_preNagios / *.bak_prePortChange"
echo "------------------------------------------------------------"
echo "  Next steps:"
echo "    1. Open http://${SERVER_IP}:${HTTP_PORT}/nagiosxi in your browser"
echo "    2. Set timezone, language, and theme"
echo "    3. Set the admin password"
echo "    4. Enter your license key or select Trial"
echo "    5. Click 'Finish Install'"
echo "    NOTE: If a firewall is active, open ports ${HTTP_PORT} and ${HTTPS_PORT}:"
echo "      ufw allow ${HTTP_PORT}/tcp && ufw allow ${HTTPS_PORT}/tcp"
echo "============================================================"
echo ""
 

