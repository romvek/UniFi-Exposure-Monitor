#!/usr/bin/env bash
# =============================================================================
# unifi_monitor.sh — UniFi Exposure Monitor
#
# Periodically checks whether your UniFi management interface is exposed to
# the internet. Reports findings via Telegram and Prometheus Pushgateway.
#
# Checks performed:
#   - DNS: does your controller hostname resolve to a public IP?
#   - Curl: does port 8443 on your WAN IP respond to HTTPS requests?
#   - Shodan InternetDB: are any UniFi management ports listed as open?
#
# Dependencies: curl, dnsutils (dig), git
# Config: copy config.env.example to config.env and fill in your values
# Schedule: see /etc/cron.d/unifi-monitor for schedule options. 
# Telegram: configured to alert on every run for warnings/exposures,
#   clean confirmations are throttled to once per day.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# LOAD CONFIG
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.env not found at ${CONFIG_FILE}"
    echo "Copy config.env.example to config.env and fill in your values."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Non-secret defaults (override in config.env if needed)
UNIFI_PORTS=(8443 8080 443 8843 8880)
JOB_NAME="unifi_exposure_monitor"
LOG_FILE="/var/log/unifi_monitor.log"
# -----------------------------------------------------------------------------

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
EPOCH=$(date +%s)

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[${TIMESTAMP}] $*" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# GIT PULL — re-exec after pull so bash doesn't re-read a modified script
# -----------------------------------------------------------------------------
if [[ "${UNIFI_MONITOR_UPDATED:-0}" != "1" ]]; then
    git -C "$SCRIPT_DIR" pull --quiet 2>/dev/null || true
    UNIFI_MONITOR_UPDATED=1 exec bash "$0" "$@"
fi

# -----------------------------------------------------------------------------
# AUTO-DETECT WAN IP
# Falls back to two external services; can be overridden in config.env
# -----------------------------------------------------------------------------
get_wan_ip() {
    if [[ -n "${WAN_IP:-}" ]]; then
        echo "$WAN_IP"
        return
    fi
    local ip
    ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo "")
    echo "$ip"
}

# -----------------------------------------------------------------------------
# DNS CHECK
# Resolves the controller hostname and checks whether it's a public IP.
# A public result means the hostname is externally routable — a red flag.
# -----------------------------------------------------------------------------
check_dns() {
    local hostname="$1"
    local resolved
    resolved=$(dig +short "$hostname" 2>/dev/null | tail -n1)

    if [[ -z "$resolved" ]]; then
        echo "unresolvable"
        return
    fi

    if echo "$resolved" | grep -qE \
        '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|169\.254\.|::1|fc|fd)'; then
        echo "private:${resolved}"
    else
        echo "public:${resolved}"
    fi
}

# -----------------------------------------------------------------------------
# CURL CHECK
# Attempts an HTTPS connection to port 8443 on the WAN IP.
# A 404 is treated as unreachable — some gateway devices (e.g. UDM SE) return
# 404 on unrecognized paths without exposing the UniFi controller itself.
# Any other HTTP response code is flagged as reachable.
# -----------------------------------------------------------------------------
check_curl() {
    local target="$1"
    local http_code
    http_code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
        "https://${target}:8443" 2>/dev/null || echo "000")

    if [[ "$http_code" == "000" || "$http_code" == "404" ]]; then
        echo "unreachable"
    else
        echo "reachable:${http_code}"
    fi
}

# -----------------------------------------------------------------------------
# SHODAN INTERNETDB CHECK
# Queries Shodan's free InternetDB API for open ports on the WAN IP.
# No API key required. Returns open ports if found, notfound if no data,
# or error if the API call fails.
#
# Returns one of:
#   found:<ports>    — open ports found (comma-separated)
#   notfound         — IP not in Shodan's database
#   error            — API call failed
# -----------------------------------------------------------------------------
check_shodan() {
    local wan_ip="$1"
    local response
    response=$(curl -s --max-time 10 \
        "https://internetdb.shodan.io/${wan_ip}" \
        2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        echo "error"
        return
    fi

    if echo "$response" | grep -q "No information available"; then
        echo "notfound"
        return
    fi

    # Extract open ports as comma-separated list
    local ports
    ports=$(echo "$response" | grep -o '"ports":\[[^]]*\]' | grep -o '[0-9]*' | tr '\n' ',' | sed 's/,$//')

    echo "found:${ports}"
}

# -----------------------------------------------------------------------------
# PUSH METRICS TO PROMETHEUS PUSHGATEWAY
# -----------------------------------------------------------------------------
push_metrics() {
    local wan_ip="$1"
    local dns_status="$2"
    local curl_status="$3"
    local exposed_count="$4"
    local overall_risk="$5"

    local dns_public=0
    [[ "$dns_status" == "public" ]] && dns_public=1

    local curl_reachable=0
    [[ "$curl_status" == "reachable" ]] && curl_reachable=1

    local payload
    payload=$(cat <<EOF
# HELP unifi_exposure_risk Overall exposure risk level (0=clean, 1=warning, 2=exposed)
# TYPE unifi_exposure_risk gauge
unifi_exposure_risk{wan_ip="${wan_ip}"} ${overall_risk}
# HELP unifi_dns_public_ip DNS resolves to public IP (1=yes, 0=no)
# TYPE unifi_dns_public_ip gauge
unifi_dns_public_ip{hostname="${UNIFI_HOSTNAME}"} ${dns_public}
# HELP unifi_curl_reachable Controller reachable via curl on port 8443 (1=yes, 0=no)
# TYPE unifi_curl_reachable gauge
unifi_curl_reachable{wan_ip="${wan_ip}"} ${curl_reachable}
# HELP unifi_exposed_ports_total Number of UniFi ports found open in Shodan
# TYPE unifi_exposed_ports_total gauge
unifi_exposed_ports_total{wan_ip="${wan_ip}"} ${exposed_count}
# HELP unifi_last_check_timestamp_seconds Unix timestamp of last check
# TYPE unifi_last_check_timestamp_seconds gauge
unifi_last_check_timestamp_seconds ${EPOCH}
EOF
)

    local response
    response=$(echo "$payload" | curl -sf --max-time 10 \
        --data-binary @- \
        "${PUSHGATEWAY_URL}/metrics/job/${JOB_NAME}/instance/unifi_controller" \
        2>&1) || true

    if [[ $? -eq 0 ]]; then
        log "Metrics pushed to Pushgateway successfully."
    else
        log "WARNING: Failed to push metrics to Pushgateway: ${response}"
    fi
}

# -----------------------------------------------------------------------------
# SEND TELEGRAM NOTIFICATION
# -----------------------------------------------------------------------------
send_telegram() {
    local message="$1"
    local parse_mode="${2:-Markdown}"

    curl -sf --max-time 10 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="${parse_mode}" \
        -d text="${message}" \
        > /dev/null 2>&1 || log "WARNING: Failed to send Telegram message."
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    log "=== UniFi Exposure Check Starting ==="

    # --- WAN IP ---
    local wan_ip
    wan_ip=$(get_wan_ip)
    if [[ -z "$wan_ip" ]]; then
        log "ERROR: Could not determine WAN IP. Check connectivity."
        send_telegram "⚠️ *UniFi Monitor Error*%0AUnable to determine WAN IP. Check script host connectivity."
        exit 1
    fi
    log "WAN IP: ${wan_ip}"

    # --- DNS CHECK ---
    local dns_result dns_status dns_resolved_ip
    dns_result=$(check_dns "$UNIFI_HOSTNAME")
    dns_status=$(echo "$dns_result" | cut -d: -f1)
    dns_resolved_ip=$(echo "$dns_result" | cut -d: -f2)
    log "DNS: ${UNIFI_HOSTNAME} → ${dns_result}"

    # --- CURL CHECK ---
    local curl_result curl_status
    curl_result=$(check_curl "$wan_ip")
    curl_status=$(echo "$curl_result" | cut -d: -f1)
    log "Curl check: ${curl_result}"

    # --- SHODAN CHECK ---
    log "Querying Shodan InternetDB for ${wan_ip}..."
    local shodan_result shodan_status shodan_ports
    shodan_result=$(check_shodan "$wan_ip")
    shodan_status=$(echo "$shodan_result" | cut -d: -f1)
    shodan_ports=$(echo "$shodan_result" | cut -d: -f2-)

    local unifi_exposed_ports=() exposed_count=0

    case "$shodan_status" in
        found)
            log "Shodan InternetDB: open ports=${shodan_ports}"
            for port in "${UNIFI_PORTS[@]}"; do
                if echo ",$shodan_ports," | grep -q ",${port},"; then
                    unifi_exposed_ports+=("$port")
                    ((exposed_count++))
                fi
            done
            ;;
        notfound)
            log "Shodan InternetDB: no data for ${wan_ip}"
            shodan_ports="none"
            ;;
        error)
            log "WARNING: Shodan InternetDB query failed"
            shodan_ports="unknown"
            ;;
    esac

    log "Shodan check complete. UniFi ports exposed: ${exposed_count}"

    # --- DETERMINE OVERALL RISK ---
    # 0 = clean, 1 = warning, 2 = confirmed exposed
    local overall_risk=0
    local risk_label="✅ CLEAN"
    local alert_needed=false

    if [[ $exposed_count -gt 0 ]]; then
        overall_risk=2
        risk_label="🚨 EXPOSED"
        alert_needed=true
    elif [[ "$dns_status" == "public" ]]; then
        overall_risk=1
        risk_label="⚠️ WARNING"
        alert_needed=true
    elif [[ "$curl_status" == "reachable" ]]; then
        overall_risk=1
        risk_label="⚠️ WARNING"
        alert_needed=true
    elif [[ "$shodan_status" == "error" ]]; then
        overall_risk=1
        risk_label="⚠️ WARNING (Shodan Unavailable)"
        alert_needed=true
    fi

    log "Overall risk: ${risk_label} (level ${overall_risk})"

    # --- PUSH TO PROMETHEUS ---
    push_metrics "$wan_ip" "$dns_status" "$curl_status" "$exposed_count" "$overall_risk"

    # --- TELEGRAM NOTIFICATION ---
    # Alerts fire on every run for WARNING/EXPOSED.
    # CLEAN confirmation is throttled to once per day via a flag file.
    local flag_file="/tmp/unifi_monitor_clean_$(date +%Y%m%d)"

    if [[ "$alert_needed" == true ]]; then
        local exposed_list="None"
        if [[ ${#unifi_exposed_ports[@]} -gt 0 ]]; then
            exposed_list=$(printf '%s, ' "${unifi_exposed_ports[@]}" | sed 's/, $//')
        fi

        local msg
        msg="*UniFi Exposure Monitor*
${risk_label}

🕐 \`${TIMESTAMP}\`
🌐 WAN IP: \`${wan_ip}\`

*DNS Check*
Hostname: \`${UNIFI_HOSTNAME}\`
Resolves to: \`${dns_resolved_ip}\` (${dns_status})

*Curl Check (port 8443)*
Status: ${curl_status}

*Shodan InternetDB*
All open ports: \`${shodan_ports}\`
UniFi ports exposed: \`${exposed_list}\`

⚡ Check your firewall rules immediately."

        send_telegram "$msg"
        log "Alert sent to Telegram."

    elif [[ ! -f "$flag_file" ]]; then
        local msg
        msg="*UniFi Exposure Monitor*
✅ CLEAN — Daily Check Passed

🕐 \`${TIMESTAMP}\`
🌐 WAN IP: \`${wan_ip}\`
DNS resolves to private IP ✓
Curl unreachable externally ✓
Shodan InternetDB: 0 UniFi ports exposed ✓"

        send_telegram "$msg"
        touch "$flag_file"
        log "Daily clean confirmation sent to Telegram."
    else
        log "Status clean, daily notification already sent today. Skipping Telegram."
    fi

    log "=== Check Complete ==="
}

main "$@"
