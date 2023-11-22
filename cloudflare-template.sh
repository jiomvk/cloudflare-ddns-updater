#!/bin/bash

# Constants
CLOUDFLARE_API="https://api.cloudflare.com/client/v4"  # Cloudflare API base URL
IP_API="https://api.ipify.org"                        # IP lookup API URL
ICANHAZIP_API="https://ipv4.icanhazip.com"             # Alternative IP lookup API URL
AUTH_EMAIL=""                                         # Email used to login 'https://dash.cloudflare.com'
AUTH_METHOD="token"                                   # Set to "global" for Global API Key or "token" for Scoped API Token
AUTH_KEY=""                                           # Your API Token or Global API Key
ZONE_IDENTIFIER=""                                    # Can be found in the "Overview" tab of your domain
RECORD_NAME=""                                        # Which record you want to be synced
TTL="3600"                                            # Set the DNS TTL (seconds)
PROXY="false"                                         # Set the proxy to true or false
SITENAME=""                                           # Title of the site "Example Site"
SLACK_CHANNEL=""                                      # Slack Channel #example
SLACK_URI=""                                          # URI for Slack WebHook "https://hooks.slack.com/services/xxxxx"
DISCORD_URI=""                                        # URI for Discord WebHook "https://discordapp.com/api/webhooks/xxxxx"

# Function to get public IP
get_public_ip() {
    local ip
    ip=$(curl -s -4 "$IP_API" || curl -s "$ICANHAZIP_API")
    # Additional checks and error handling if needed
    echo "$ip"
}

# Function to handle Cloudflare API requests
cloudflare_request() {
    local url="$1"
    local method="$2"
    local data="$3"

    # Perform the API request and handle errors
    result=$(curl -s -X "$method" "$url" \
        -H "X-Auth-Email: $AUTH_EMAIL" \
        -H "$auth_header $AUTH_KEY" \
        -H "Content-Type: application/json" \
        --data "$data")

    # Additional checks and error handling if needed
    echo "$result"
}

# Check if we have a public IP
ipv4_regex='([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])'
ip=$(get_public_ip)

# Use regex to check for proper IPv4 format.
if [[ ! $ip =~ ^$ipv4_regex$ ]]; then
    logger -s "DDNS Updater: Failed to find a valid IP."
    exit 2
fi

# Check and set the proper auth header
if [[ "${AUTH_METHOD}" == "global" ]]; then
    auth_header="X-Auth-Key:"
else
    auth_header="Authorization: Bearer"
fi

# Seek for the A record
logger "DDNS Updater: Check Initiated"
record_url="$CLOUDFLARE_API/zones/$ZONE_IDENTIFIER/dns_records?type=A&name=$RECORD_NAME"
record=$(cloudflare_request "$record_url" "GET" "")

# Check if the domain has an A record
if [[ $record == *"\"count\":0"* ]]; then
    logger -s "DDNS Updater: Record does not exist, perhaps create one first? (${ip} for ${RECORD_NAME})"
    exit 1
fi

# Get existing IP
old_ip=$(echo "$record" | sed -E 's/.*"content":"(([0-9]{1,3}\.){3}[0-9]{1,3})".*/\1/')
# Compare if they're the same
if [[ $ip == $old_ip ]]; then
    logger "DDNS Updater: IP ($ip) for ${RECORD_NAME} has not changed."
    exit 0
fi

# Set the record identifier from result
record_identifier=$(echo "$record" | sed -E 's/.*"id":"(\w+)".*/\1/')

# Change the IP@Cloudflare using the API
update_url="$CLOUDFLARE_API/zones/$ZONE_IDENTIFIER/dns_records/$record_identifier"
update_data="{\"type\":\"A\",\"name\":\"$RECORD_NAME\",\"content\":\"$ip\",\"ttl\":\"$TTL\",\"proxied\":${PROXY}}"
update=$(cloudflare_request "$update_url" "PATCH" "$update_data")

# Report the status
case "$update" in
    *"\"success\":false"*)
        log_message="DDNS Updater: $ip $RECORD_NAME DDNS failed for $record_identifier ($ip). DUMPING RESULTS:\n$update"
        echo -e "$log_message" | logger -s
        if [[ $SLACK_URI != "" ]]; then
            curl -L -X POST $SLACK_URI \
            --data-raw '{
              "channel": "'$SLACK_CHANNEL'",
              "text" : "'"$SITENAME"' DDNS Update Failed: '$RECORD_NAME': '$record_identifier' ('$ip')."
            }'
        fi
        if [[ $DISCORD_URI != "" ]]; then
            curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
            --data-raw '{
              "content" : "'"$SITENAME"' DDNS Update Failed: '$RECORD_NAME': '$record_identifier' ('$ip')."
            }' $DISCORD_URI
        fi
        exit 1;;
    *)
        log_message="DDNS Updater: $ip $RECORD_NAME DDNS updated."
        logger "$log_message"
        if [[ $SLACK_URI != "" ]]; then
            curl -L -X POST $SLACK_URI \
            --data-raw '{
              "channel": "'$SLACK_CHANNEL'",
              "text" : "'"$SITENAME"' Updated: '$RECORD_NAME''"'"'s'""' new IP Address is '$ip'"
            }'
        fi
        if [[ $DISCORD_URI != "" ]]; then
            curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
            --data-raw '{
              "content" : "'"$SITENAME"' Updated: '$RECORD_NAME''"'"'s'""' new IP Address is '$ip'"
            }' $DISCORD_URI
        fi
        exit 0;;
esac
