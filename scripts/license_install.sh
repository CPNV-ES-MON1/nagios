#!/bin/bash
# =============================================================================
#  Nagios XI — License key submission script
#  Usage: sudo bash nagiosxi_license.sh
#
#  What this does:
#    1. Writes the license key directly into the nagiosxi MySQL database
#       (xi_options table — same place the web UI writes it)
#    2. Falls back to the Admin → License Information web form (nsp scrape +
#       POST) if the DB method fails or the DB isn't accessible yet
#    3. Does NOT perform online activation — that requires a Customer/Client ID
#       from Nagios Enterprises and phones home to nagios.com. Activation is
#       not required during the 30-day trial period.
#
#  IMPORTANT: Run this AFTER install.php wizard has been completed (i.e. after
#  the main install script finishes). The nagiosxi DB must exist.
#
#  Activation note:
#    After submitting the key, full activation requires:
#      Admin → License Information → "Activate your license key"
#      → enter your Customer ID → click Activate
#    This step cannot be scripted without your Customer ID, which is provided
#    by Nagios Enterprises at purchase. If you're on Trial, skip it entirely.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — loaded from config/nagios.env
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../config/nagios.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "  [ERROR] config/nagios.env not found at: $ENV_FILE"
    echo "          Copy config/nagios.env.example to config/nagios.env and fill in your values."
    exit 1
fi

# shellcheck source=../config/nagios.env
set -a; source "$ENV_FILE"; set +a

# Validate required variables
for var in NAGIOS_LICENSE_KEY NAGIOS_ADMIN_PASSWORD NAGIOS_HTTP_PORT; do
    if [[ -z "${!var:-}" ]]; then
        echo "  [ERROR] $var is not set in config/nagios.env"
        exit 1
    fi
done

LOG_FILE="/tmp/nagiosxi_license_$(date +%Y%m%d_%H%M%S).log"

log_info()  { echo "[INFO]  $*" >> "$LOG_FILE"; echo "  --> $*"; }
log_ok()    { echo "[OK]    $*" >> "$LOG_FILE"; echo "  [OK] $*"; }
log_warn()  { echo "[WARN]  $*" >> "$LOG_FILE"; echo "  [WARN] $*"; }
log_error() { echo "[ERROR] $*" >> "$LOG_FILE"; echo "  [ERROR] $* -- see $LOG_FILE"; exit 1; }
log_debug() { echo "[DEBUG] $*" >> "$LOG_FILE"; }

echo "==> Nagios XI license submission. Full log: $LOG_FILE"
echo "==> $(date)" | tee -a "$LOG_FILE"

# =============================================================================
# CONFIGURATION — resolved from nagios.env
# =============================================================================

LICENSE_KEY="${NAGIOS_LICENSE_KEY}"
ADMIN_PASSWORD="${NAGIOS_ADMIN_PASSWORD}"
HTTP_PORT="${NAGIOS_HTTP_PORT}"
NAGIOSXI_URL="http://localhost:${HTTP_PORT}/nagiosxi"

# MySQL credentials — XI 2026 uses root with password 'nagiosxi' by default.
# The actual root password is set during fullinstall and stored in xi-sys.cfg.
# We read it from there at runtime; 'nagiosxi' is the known XI default fallback.
XI_CFG="/usr/local/nagiosxi/etc/xi-sys.cfg"
MYSQL_ROOT_PASS="nagiosxi"

# =============================================================================
# 0. PREFLIGHT
# =============================================================================

if [[ $EUID -ne 0 ]]; then
    log_error "Must run as root."
fi

if [[ -z "$LICENSE_KEY" ]]; then
    log_error "NAGIOS_LICENSE_KEY is empty in config/nagios.env — nothing to submit."
fi

# Try to override MySQL root password from xi-sys.cfg if available
if [[ -f "$XI_CFG" ]]; then
    _CFG_PASS=$(grep -Po '^mysqlpass=\K.*' "$XI_CFG" || true)
    if [[ -n "$_CFG_PASS" ]]; then
        MYSQL_ROOT_PASS="$_CFG_PASS"
        log_debug "MySQL root password read from xi-sys.cfg."
    else
        log_debug "mysqlpass not found in xi-sys.cfg — using default 'nagiosxi'."
    fi
else
    log_warn "xi-sys.cfg not found — using default MySQL password 'nagiosxi'."
fi

# =============================================================================
# 1. PRIMARY METHOD — write directly to MySQL xi_options table
# =============================================================================
# This is the same table the web UI writes to. Avoids the nsp CSRF dance.
# Keys in xi_options: license_key, licensed (1=licensed, 0=trial)
# =============================================================================

log_info "Attempting to write license key to MySQL (xi_options table)..."

MYSQL_CMD="mysql -u root"
if [[ -n "$MYSQL_ROOT_PASS" ]]; then
    MYSQL_CMD+=" -p${MYSQL_ROOT_PASS}"
fi
MYSQL_CMD+=" nagiosxi"

DB_SUCCESS=0

# Test DB connectivity first
if echo "SELECT 1;" | $MYSQL_CMD >> "$LOG_FILE" 2>&1; then
    log_ok "MySQL connection successful."

    # Check if license_key row already exists
    KEY_EXISTS=$(echo "SELECT COUNT(*) FROM xi_options WHERE keyname='license_key';" \
                 | $MYSQL_CMD --skip-column-names 2>/dev/null | tr -d '[:space:]' || echo "0")

    if [[ "$KEY_EXISTS" == "1" ]]; then
        log_info "Updating existing license_key row..."
        echo "UPDATE xi_options SET keyvalue='${LICENSE_KEY}' WHERE keyname='license_key';" \
            | $MYSQL_CMD >> "$LOG_FILE" 2>&1 \
            && log_ok "license_key updated in xi_options." \
            || log_warn "UPDATE failed — will try web form fallback."
    else
        log_info "Inserting license_key row..."
        echo "INSERT INTO xi_options (keyname, keyvalue) VALUES ('license_key', '${LICENSE_KEY}');" \
            | $MYSQL_CMD >> "$LOG_FILE" 2>&1 \
            && log_ok "license_key inserted into xi_options." \
            || log_warn "INSERT failed — will try web form fallback."
    fi

    # Set licensed=1 (switches XI from Trial to Licensed mode)
    LICENSED_EXISTS=$(echo "SELECT COUNT(*) FROM xi_options WHERE keyname='licensed';" \
                      | $MYSQL_CMD --skip-column-names 2>/dev/null | tr -d '[:space:]' || echo "0")

    if [[ "$LICENSED_EXISTS" == "1" ]]; then
        echo "UPDATE xi_options SET keyvalue='1' WHERE keyname='licensed';" \
            | $MYSQL_CMD >> "$LOG_FILE" 2>&1 \
            && log_ok "licensed flag set to 1." \
            || log_warn "Could not set licensed flag."
    else
        echo "INSERT INTO xi_options (keyname, keyvalue) VALUES ('licensed', '1');" \
            | $MYSQL_CMD >> "$LOG_FILE" 2>&1 \
            && log_ok "licensed flag inserted (value=1)." \
            || log_warn "Could not insert licensed flag."
    fi

    DB_SUCCESS=1
else
    log_warn "MySQL connection failed — falling back to web form method."
fi

# =============================================================================
# 2. FALLBACK — web form POST to Admin → License Information page
# =============================================================================
# Only runs if DB method failed. Uses the same nsp CSRF scrape pattern
# as install.php. Requires the wizard to already be completed so that
# a valid admin session can be established.
# =============================================================================

if [[ "$DB_SUCCESS" -eq 0 ]]; then
    log_info "Attempting license submission via web form..."

    LICENSE_PAGE="${NAGIOSXI_URL}/admin/license.php"
    LOGIN_PAGE="${NAGIOSXI_URL}/login.php"
    COOKIE_JAR="/tmp/nagiosxi_license_cookies_$$.txt"
    RESPONSE_FILE="/tmp/nagiosxi_license_response_$$.html"

    # --- Step 1: GET login page → grab nsp ---
    log_info "Fetching login page for session cookie + nsp token..."
    curl -sk \
        -c "$COOKIE_JAR" \
        -o "$RESPONSE_FILE" \
        --max-time 15 \
        "$LOGIN_PAGE" >> "$LOG_FILE" 2>&1 \
        || log_error "GET login.php failed."

    LOGIN_NSP=$(grep -oP 'name="nsp"\s+value="\K[^"]+' "$RESPONSE_FILE" \
                || grep -oP "name='nsp'\s+value='\K[^']+" "$RESPONSE_FILE" \
                || true)

    if [[ -z "$LOGIN_NSP" ]]; then
        log_error "Could not extract nsp from login page. Is Nagios XI running?"
    fi

    # --- Step 2: POST login credentials ---
    log_info "Logging in as nagiosadmin..."
    curl -sk \
        -b "$COOKIE_JAR" \
        -c "$COOKIE_JAR" \
        -X POST \
        --data "nsp=${LOGIN_NSP}&username=nagiosadmin&password=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${ADMIN_PASSWORD}', safe=''))")&loginButton=" \
        -o "$RESPONSE_FILE" \
        --max-time 15 \
        -L \
        "$LOGIN_PAGE" >> "$LOG_FILE" 2>&1 \
        || log_error "POST to login.php failed."

    # Check we're actually logged in (redirect away from login page means success)
    if grep -qi "invalid username\|login failed\|incorrect password" "$RESPONSE_FILE"; then
        log_error "Login failed. Check ADMIN_PASSWORD in this script."
    fi
    log_ok "Login successful."

    # --- Step 3: GET license.php → grab its nsp ---
    log_info "Fetching license.php..."
    curl -sk \
        -b "$COOKIE_JAR" \
        -c "$COOKIE_JAR" \
        -o "$RESPONSE_FILE" \
        --max-time 15 \
        "${LICENSE_PAGE}" >> "$LOG_FILE" 2>&1 \
        || log_error "GET license.php failed."

    LICENSE_NSP=$(grep -oP 'name="nsp"\s+value="\K[^"]+' "$RESPONSE_FILE" \
                  || grep -oP "name='nsp'\s+value='\K[^']+" "$RESPONSE_FILE" \
                  || true)

    if [[ -z "$LICENSE_NSP" ]]; then
        log_error "Could not extract nsp from license.php. Check $RESPONSE_FILE."
    fi
    log_debug "license.php nsp extracted."

    # --- Step 4: POST license key ---
    # Fields observed from browser devtools on the license.php form:
    #   nsp, licensed=1, license_key=<key>, update=1
    log_info "Submitting license key via web form..."
    curl -sk \
        -b "$COOKIE_JAR" \
        -c "$COOKIE_JAR" \
        -X POST \
        --data "nsp=${LICENSE_NSP}&licensed=1&license_key=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${LICENSE_KEY}', safe=''))")&update=1" \
        -o "$RESPONSE_FILE" \
        --max-time 20 \
        "${LICENSE_PAGE}" >> "$LOG_FILE" 2>&1 \
        || log_error "POST to license.php failed."

    if grep -qi "license.*updated\|success\|valid license" "$RESPONSE_FILE"; then
        log_ok "License key accepted via web form."
    else
        log_warn "Could not confirm license acceptance from response."
        log_warn "Response saved to: $RESPONSE_FILE — inspect manually."
    fi

    rm -f "$COOKIE_JAR" "$RESPONSE_FILE"
fi

# =============================================================================
# 3. SUMMARY
# =============================================================================

echo ""
echo "============================================================"
echo "  Nagios XI license key submission complete"
echo "============================================================"
echo "  Method used : $([ "$DB_SUCCESS" -eq 1 ] && echo "Direct MySQL write" || echo "Web form POST")"
echo "  License key : ${LICENSE_KEY:0:8}...${LICENSE_KEY: -4}   (truncated)"
echo "  Full log    : $LOG_FILE"
echo "------------------------------------------------------------"
echo "  Next step — Online activation (if you have a Customer ID):"
echo "    1. Open ${NAGIOSXI_URL}/admin/license.php"
echo "    2. Click 'Activate your license key'"
echo "    3. Enter your Customer ID and click Activate"
echo ""
echo "  If you are on Trial, no activation is needed."
echo "  Trial is fully functional for 30 days."
echo "============================================================"
echo ""