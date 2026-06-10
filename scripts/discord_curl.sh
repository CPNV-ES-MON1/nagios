#!/bin/bash

#
# 10.06.2026
# Discord Notifications Wizard Plugin
# Copyright (c) 2023 Nagios Enterprises, LLC. All rights reserved.
# Modified: user-friendly notifications (no IPs, no hostnames, impact-focused)
#

# Inputs
# --------------------------------------------------
# Host command defn:
#   command: discord_curl.sh webhook-url "$NOTIFICATIONTYPE$" "$HOSTNAME$" "$HOSTADDRESS$" "$HOSTSTATE$" "$HOSTOUTPUT$" "$LONGDATETIME$"
# Service command defn:
#   command: discord_curl.sh webhook-url "$NOTIFICATIONTYPE$" "$HOSTNAME$" "$HOSTADDRESS$" "$SERVICESTATE$" "$SERVICEOUTPUT$" "$LONGDATETIME$" "$SERVICEDESC$"

# Discord Colors
blurple=5793266
green=5763719
yellow=16705372
fuchsia=15418782
red=15548997

webhook_url=$1
notification_type=$2
hostname=$3
hostaddress=$4
state=$5
output=$6
datetime=$7
servicedesc=$8

# =============================================================================
# USER-FRIENDLY SERVICE/HOST LABELS
# Map internal service names to plain-language descriptions
# Add entries here as needed: ["internal_name"]="User-facing label|Impact description"
# =============================================================================
declare -A service_labels
service_labels["HTTP"]="Website|The website may be unavailable or slow to load."
service_labels["HTTPS"]="Website (Secure)|The website may be unavailable or slow to load."
service_labels["SSH"]="Remote Access|Remote administration access may be unavailable."
service_labels["FTP"]="File Transfer|File uploads or downloads may be unavailable."
service_labels["SMTP"]="Email Sending|Outgoing emails may not be delivered."
service_labels["IMAP"]="Email Reception|Incoming emails may not be accessible."
service_labels["POP3"]="Email Reception|Incoming emails may not be accessible."
service_labels["DNS"]="Name Resolution|Some services or websites may be unreachable by name."
service_labels["MySQL"]="Database|Some application features requiring data storage may be unavailable."
service_labels["PostgreSQL"]="Database|Some application features requiring data storage may be unavailable."
service_labels["Ping"]="Network Connectivity|The server may be unreachable from the network."
service_labels["PING"]="Network Connectivity|The server may be unreachable from the network."
service_labels["Current Load"]="Server Performance|The server may be slow or unresponsive."
service_labels["Current Users"]="Server Capacity|The server may be experiencing high usage."
service_labels["Disk Space"]="Storage|Available disk space is low; some operations may fail."
service_labels["Swap Usage"]="Memory|The server may be experiencing memory pressure."
service_labels["Total Processes"]="Server Processes|Unexpected number of processes detected on the server."

# Resolve service label and impact
friendly_service="Service"
impact_description="Some functionality may be affected."

if [ -n "$servicedesc" ]; then
    if [[ -v service_labels["$servicedesc"] ]]; then
        IFS='|' read -r friendly_service impact_description <<< "${service_labels[$servicedesc]}"
    else
        # Fallback: use the service name as-is but strip technical suffixes
        friendly_service=$(echo "$servicedesc" | sed 's/_/ /g')
        impact_description="Some functionality may be affected. Our team is investigating."
    fi
fi

# =============================================================================
# STATE → user-friendly status + color + emoji
# =============================================================================
case $state in
    "CRITICAL"|"DOWN")
        color=$red
        emoji=":red_circle:"
        status_label="Outage Detected"
        status_detail="The service is currently unavailable."
        ;;
    "WARNING")
        color=$yellow
        emoji=":yellow_circle:"
        status_label="Degraded Performance"
        status_detail="The service is experiencing issues and may be slow or partially unavailable."
        ;;
    "OK"|"UP")
        color=$green
        emoji=":green_circle:"
        status_label="Service Restored"
        status_detail="The service is back to normal operation."
        ;;
    "UNREACHABLE")
        color=$fuchsia
        emoji=":white_circle:"
        status_label="Service Unreachable"
        status_detail="The service cannot be reached at this time."
        ;;
    *)
        color=$fuchsia
        emoji=":white_circle:"
        status_label="Status Unknown"
        status_detail="The status of the service could not be determined."
        ;;
esac

# =============================================================================
# BUILD DISCORD EMBED — two distinct formats: PROBLEM vs RECOVERY
# No IPs, no hostnames, no raw technical output.
# =============================================================================

if [[ "$notification_type" == "RECOVERY" || "$state" == "OK" || "$state" == "UP" ]]; then
    # -----------------------------------------------------------------
    # RECOVERY — service is back up
    # -----------------------------------------------------------------
    discord_json=$(jq -n \
        --arg username "Infrastructure Status" \
        --arg title "✅  Service Restored" \
        --argjson color "$green" \
        --arg service_field "$friendly_service" \
        --arg recovery_msg "The service has been restored and is operating normally." \
        --arg impact_field "All features related to **${friendly_service}** are available again. Thank you for your patience." \
        --arg datetime "$datetime" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: [
                    {name: "✅  Service Back Online", value: $service_field},
                    {name: "What happened?",          value: $recovery_msg},
                    {name: "What can users do now?",  value: $impact_field}
                ],
                footer: {text: $datetime}
            }]
        }')

elif [[ "$notification_type" == "PROBLEM" || "$state" == "CRITICAL" || "$state" == "DOWN" || "$state" == "WARNING" ]]; then
    # -----------------------------------------------------------------
    # PROBLEM — service is down or degraded
    # -----------------------------------------------------------------
    discord_json=$(jq -n \
        --arg username "Infrastructure Status" \
        --arg title "🚨  Service Disruption Detected" \
        --argjson color "$color" \
        --arg service_field "$friendly_service" \
        --arg status_field "$status_label" \
        --arg status_detail "$status_detail" \
        --arg impact_field "$impact_description Our team has been notified and is working on a fix." \
        --arg datetime "$datetime" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: [
                    {name: "❌  Affected Service",   value: $service_field,  inline: true},
                    {name: "Current Status",          value: $status_field,   inline: true},
                    {name: "What is happening?",      value: $status_detail},
                    {name: "Impact for users",        value: $impact_field}
                ],
                footer: {text: $datetime}
            }]
        }')

elif [[ "$notification_type" == "ACKNOWLEDGEMENT" ]]; then
    # -----------------------------------------------------------------
    # ACKNOWLEDGEMENT — team is aware and working on it
    # -----------------------------------------------------------------
    discord_json=$(jq -n \
        --arg username "Infrastructure Status" \
        --arg title "👷  Incident Acknowledged" \
        --argjson color "$yellow" \
        --arg service_field "$friendly_service" \
        --arg ack_msg "Our team is aware of the issue and is actively working on a resolution." \
        --arg datetime "$datetime" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: [
                    {name: "Service",        value: $service_field},
                    {name: "What is next?",  value: $ack_msg}
                ],
                footer: {text: $datetime}
            }]
        }')

elif [[ "$notification_type" == "DOWNTIMESTART" ]]; then
    # -----------------------------------------------------------------
    # MAINTENANCE START
    # -----------------------------------------------------------------
    discord_json=$(jq -n \
        --arg username "Infrastructure Status" \
        --arg title "🔧  Scheduled Maintenance Started" \
        --argjson color "$blurple" \
        --arg service_field "$friendly_service" \
        --arg maint_msg "A planned maintenance window has started. Some features may be temporarily unavailable." \
        --arg datetime "$datetime" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: [
                    {name: "Service under maintenance", value: $service_field},
                    {name: "What to expect?",           value: $maint_msg}
                ],
                footer: {text: $datetime}
            }]
        }')

elif [[ "$notification_type" == "DOWNTIMEEND" ]]; then
    # -----------------------------------------------------------------
    # MAINTENANCE END
    # -----------------------------------------------------------------
    discord_json=$(jq -n \
        --arg username "Infrastructure Status" \
        --arg title "✅  Scheduled Maintenance Completed" \
        --argjson color "$green" \
        --arg service_field "$friendly_service" \
        --arg maint_msg "The maintenance window is over. All services should be back to normal." \
        --arg datetime "$datetime" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: [
                    {name: "Service restored", value: $service_field},
                    {name: "Status",           value: $maint_msg}
                ],
                footer: {text: $datetime}
            }]
        }')

else
    # -----------------------------------------------------------------
    # FALLBACK — any other notification type
    # -----------------------------------------------------------------
    discord_json=$(jq -n \
        --arg username "Infrastructure Status" \
        --arg title "ℹ️  Service Notification" \
        --argjson color "$blurple" \
        --arg service_field "$friendly_service" \
        --arg status_field "$status_label" \
        --arg datetime "$datetime" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: [
                    {name: "Service", value: $service_field, inline: true},
                    {name: "Status",  value: $status_field,  inline: true}
                ],
                footer: {text: $datetime}
            }]
        }')
fi

# Send to Discord
curl -s -g -X POST -H "Content-Type: application/json" -d "$discord_json" "$webhook_url"
