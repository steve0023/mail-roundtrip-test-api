#!/bin/bash

set -e

echo "========================================="
echo "Email Round-Trip Monitoring API Installer"
echo "========================================="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (use sudo)" 
   exit 1
fi

# Function to escape special characters for sed
escape_sed() {
    echo "$1" | sed 's/[&/\]/\\&/g'
}

# Install dependencies
echo "Step 1: Installing dependencies..."
apt-get update
apt-get install -y nmap swaks curl openssl

# Get configuration
echo ""
echo "Step 2: Configuration"
echo "Enter IMAP server details (where test emails will be checked):"
read -p "IMAP host [imap.gmail.com]: " IMAP_HOST
IMAP_HOST=${IMAP_HOST:-imap.gmail.com}
read -p "IMAP port [^993]: " IMAP_PORT
IMAP_PORT=${IMAP_PORT:-993}
read -p "IMAP username/email: " IMAP_USER
read -s -p "IMAP password: " IMAP_PASS           #PARSING ERROR TO FIX "&" CARS
echo ""
read -p "API port [^8081]: " API_PORT
API_PORT=${API_PORT:-8081}

# Escape special characters in variables
IMAP_HOST_SAFE=$(escape_sed "$IMAP_HOST")
IMAP_PORT_SAFE=$(escape_sed "$IMAP_PORT")
IMAP_USER_SAFE=$(escape_sed "$IMAP_USER")
IMAP_PASS_SAFE=$(escape_sed "$IMAP_PASS")
API_PORT_SAFE=$(escape_sed "$API_PORT")

# Create main script
echo ""
echo "Step 3: Creating service script..."
cat > /usr/local/bin/mail-test-api.sh <<'EOFSCRIPT'
#!/bin/bash

PORT=8081
IMAP_HOST="imap.gmail.com"
IMAP_PORT=993
IMAP_USER="user@example.com"
IMAP_PASS="password"
WAIT_TIME=10
MAX_RETRIES=3
RETRY_DELAY=10
SMTP_TIMEOUT=30
IMAP_TIMEOUT=15
LOG_FILE="/var/log/mail-test-api.log"
DEBUG=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

debug() {
    if [[ $DEBUG -eq 1 ]]; then
        log "DEBUG: $*"
    fi
}

urldecode() {
    local url_encoded="${1//+/ }"
    printf '%b' "${url_encoded//%/\\x}"
}

generate_subject() {
    echo "Mail-Round-Trip-Test-$(date +%s)-$RANDOM"
}

send_email() {
    local host="$1" 
    local port="$2" 
    local smtp_user="$3" 
    local smtp_pass="$4" 
    local subject="$5"
    local tls_mode="$6"
    
    local from_addr
    if [[ -n "$smtp_user" && "$smtp_user" == *@* ]]; then
        from_addr="$smtp_user"
    elif [[ -n "$smtp_user" ]]; then
        from_addr="${smtp_user}@${host}"
    else
        from_addr="postmaster@${host}"
    fi
    
    log "=== SEND EMAIL ==="
    log "Subject: $subject"
    log "From: $from_addr"
    log "To: $IMAP_USER"
    log "Server: $host:$port"
    log "TLS Mode: ${tls_mode:-none}"
    
    # Build base swaks command
    local swaks_cmd="swaks --to \"$IMAP_USER\" --from \"$from_addr\" --server \"$host:$port\" --header \"Subject: $subject\" --body \"Round-trip test\" --timeout \"$SMTP_TIMEOUT\""
    
    # Add TLS options based on tls_mode parameter
    case "${tls_mode,,}" in
        tls|starttls)
            debug "Using STARTTLS"
            swaks_cmd="$swaks_cmd --tls"
            ;;
        tlsc|implicit|smtps)
            debug "Using implicit TLS (SMTPS)"
            swaks_cmd="$swaks_cmd --tlsc"
            ;;
        none|"")
            debug "No TLS (plain text)"
            ;;
    esac

    # Add authentication if provided
    if [[ -n "$smtp_user" && -n "$smtp_pass" ]]; then
        debug "Using authentication (user: $smtp_user)"
        swaks_cmd="$swaks_cmd --auth LOGIN --auth-user \"$smtp_user\" --auth-password \"$smtp_pass\""
    else
        debug "No authentication (relay mode)"
    fi
    
    # Execute swaks command
    local swaks_output
    swaks_output=$(eval "$swaks_cmd" 2>&1)
    local exit_code=$?
    
    if [[ $DEBUG -eq 1 ]]; then
        log "=== SWAKS COMMAND ==="
        # Sanitize password for logging
        local safe_cmd="${swaks_cmd//$smtp_pass/**REDACTED**}"
        log "$safe_cmd"
        log "=== SWAKS OUTPUT ==="
        echo "$swaks_output" >> "$LOG_FILE"
        log "=== END SWAKS OUTPUT ==="
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        log "✓ Email sent successfully"
        return 0
    else
        log "✗ Email send FAILED (exit code: $exit_code)"
        return 1
    fi
}

# IMAP check using curl with retry logic
check_imap() {
    local subject="$1"
    
    log "=== CHECK IMAP ==="
    log "Waiting $WAIT_TIME seconds before IMAP check..."
    sleep "$WAIT_TIME"
    
    log "Searching for subject: $subject"
    debug "IMAP: imaps://$IMAP_HOST:$IMAP_PORT"
    debug "User: $IMAP_USER"

    # Retry loop for IMAP search - USE LOCAL VARIABLE
    local attempt=1
    local search_result=""
    local curl_exit=0
    local current_delay=$RETRY_DELAY  # LOCAL copy
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            log "Retry attempt $attempt/$MAX_RETRIES after ${current_delay}s..."
            sleep "$current_delay"
            current_delay=$((current_delay * 2))  # Exponential backoff on LOCAL variable
        fi
        
        # Use curl to search IMAP
        search_result=$(curl --silent --max-time "$IMAP_TIMEOUT" \
            --url "imaps://$IMAP_HOST:$IMAP_PORT/INBOX" \
            --user "$IMAP_USER:$IMAP_PASS" \
            --request "SEARCH SUBJECT \"$subject\"" 2>&1)
        
        curl_exit=$?
        debug "Curl exit code (attempt $attempt): $curl_exit"
        
        # Exit code 0 = success, break the retry loop
        if [[ $curl_exit -eq 0 ]]; then
            break
        fi
        
        # Log the error
        case $curl_exit in
            6) log "⚠ DNS resolution failed for $IMAP_HOST" ;;
            7) log "⚠ Failed to connect to $IMAP_HOST:$IMAP_PORT" ;;
            28) log "⚠ Connection timeout after ${IMAP_TIMEOUT}s" ;;
            *) log "⚠ Curl error: exit code $curl_exit" ;;
        esac
        
        attempt=$((attempt + 1))
    done
    
    if [[ $DEBUG -eq 1 ]]; then
        log "=== CURL SEARCH RESULT (after $((attempt-1)) attempts) ==="
        echo "$search_result" >> "$LOG_FILE"
        log "=== END SEARCH RESULT ==="
    fi
    
    if [[ $curl_exit -ne 0 ]]; then
        log "✗ IMAP connection failed after $MAX_RETRIES attempts (curl exit: $curl_exit)"
        return 1
    fi
    
    log "✓ IMAP search completed"
    
    local msg_id=""
    if echo "$search_result" | grep -q "SEARCH"; then
        msg_id=$(echo "$search_result" | grep "SEARCH" | grep -oE '[0-9]+' | head -1)
        debug "Extracted message ID: '$msg_id'"
    fi
    
    if [[ -z "$msg_id" || ! "$msg_id" =~ ^[0-9]+$ ]]; then
        log "✗ No messages found with subject: $subject"
        return 1
    fi
    
    log "✓ Message found: ID=$msg_id"
    
    # Delete the message using curl (with retry) - USE LOCAL VARIABLE
    log "Deleting message ID: $msg_id"
    
    attempt=1
    current_delay=$RETRY_DELAY  # Reset LOCAL copy
    local delete_success=0
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            debug "Delete retry attempt $attempt/$MAX_RETRIES"
            sleep "$current_delay"
            current_delay=$((current_delay * 2))  # Exponential backoff on LOCAL variable
        fi
        
        local delete_result
        delete_result=$(curl --silent --max-time "$IMAP_TIMEOUT" \
            --url "imaps://$IMAP_HOST:$IMAP_PORT/INBOX" \
            --user "$IMAP_USER:$IMAP_PASS" \
            --request "STORE $msg_id +FLAGS \\Deleted" 2>&1)
        
        local delete_exit=$?
        
        if [[ $delete_exit -eq 0 ]]; then
            delete_success=1
            
            if [[ $DEBUG -eq 1 ]]; then
                log "=== DELETE RESULT ==="
                echo "$delete_result" >> "$LOG_FILE"
                log "=== END DELETE RESULT ==="
            fi

            # Expunge to permanently delete
            curl --silent --max-time "$IMAP_TIMEOUT" \
                --url "imaps://$IMAP_HOST:$IMAP_PORT/INBOX" \
                --user "$IMAP_USER:$IMAP_PASS" \
                --request "EXPUNGE" >/dev/null 2>&1
            
            break
        fi
        
        log "⚠ Delete attempt $attempt failed (exit: $delete_exit)"
        attempt=$((attempt + 1))
    done
    
    if [[ $delete_success -eq 1 ]]; then
        log "✓ Message deleted successfully"
    else
        log "⚠ Message deletion failed after $MAX_RETRIES attempts (message may remain in inbox)"
    fi
    
    return 0
}

process_test() {
    local host="$1" 
    local port="$2" 
    local smtp_user="$3" 
    local smtp_pass="$4"
    local tls_mode="$5"
    
    local subject=$(generate_subject)
    
    log "========================================"
    log "=== NEW TEST REQUEST ==="
    log "Host: $host:$port"
    log "SMTP User: $smtp_user"
    log "TLS Mode: ${tls_mode:-none}"
    log "Generated Subject: $subject"
    log "========================================"
    
    if send_email "$host" "$port" "$smtp_user" "$smtp_pass" "$subject" "$tls_mode"; then
        if check_imap "$subject"; then
            local msg="SUCCESS: Email round-trip completed via $host:$port (${WAIT_TIME}s delay)"
            log "$msg"
            echo "$msg"
            return 0
        fi
        local msg="FAILED: Email sent but not received within ${WAIT_TIME}s"
        log "$msg"
        echo "$msg"
        return 1
    fi
    local msg="FAILED: Could not send email via SMTP"
    log "$msg"
    echo "$msg"
    return 1
}

handle_request() {
    local request host="" port="" smtp_user="" smtp_pass="" tls_mode=""
    
    read -r request
    log "HTTP Request: $request"
    
    while read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && break
    done
    
    if [[ "$request" =~ GET\ /test\?([^\ ]+) ]]; then
        local query="${BASH_REMATCH[1]}"
        
        IFS='&' read -ra PARAMS <<< "$query"
        for param in "${PARAMS[@]}"; do
            IFS='=' read -r key val <<< "$param"
            val=$(urldecode "$val")
            case "$key" in
                host) host="$val" ;;
                port) port="$val" ;;
                smtp_user) smtp_user="$val" ;;
                smtp_pass) smtp_pass="$val" ;;
                tls) tls_mode="$val" ;;
            esac
        done
        
        if [[ -z "$host" || -z "$port" ]]; then
            local body="ERROR: Missing required parameters (host and port)"
            printf "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: ${#body}\r\nConnection: close\r\n\r\n%s" "$body"
            return
        fi
        
        local result
        result=$(process_test "$host" "$port" "$smtp_user" "$smtp_pass" "$tls_mode" 2>&1)
        local rc=$?
        
        local status="200 OK"
        [[ $rc -ne 0 ]] && status="503 Service Unavailable"
        
        printf "HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: ${#result}\r\nConnection: close\r\n\r\n%s" "$status" "$result"
    else
        local body="ERROR: Use /test endpoint with host and port parameters"
        printf "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: ${#body}\r\nConnection: close\r\n\r\n%s" "$body"
    fi
}

start_server() {
    log "========================================"
    log "=== Mail Test API Starting ==="
    log "Port: $PORT"
    log "IMAP: $IMAP_USER @ imaps://$IMAP_HOST:$IMAP_PORT"
    log "Wait time: ${WAIT_TIME}s"
    log "Max retries: $MAX_RETRIES"
    log "Retry delay: ${RETRY_DELAY}s (exponential backoff)"
    log "SMTP timeout: ${SMTP_TIMEOUT}s"
    log "IMAP timeout: ${IMAP_TIMEOUT}s"
    log "Debug mode: $DEBUG"
    log "Using curl for IMAP"
    log "========================================"
    
    if ! command -v ncat >/dev/null 2>&1; then
        log "ERROR: ncat not found"
        exit 1
    fi
    
    while true; do
        ncat -l -p "$PORT" -c "$0 --handle-request" 2>> "$LOG_FILE"
        sleep 0.1
    done
}

case "${1:-}" in
    --handle-request) handle_request ;;
    *) start_server ;;
esac
EOFSCRIPT

# Replace placeholders with escaped values
sed -i "s/PORT=8081/PORT=$API_PORT_SAFE/" /usr/local/bin/mail-test-api.sh
sed -i "s/IMAP_HOST=\"imap.gmail.com\"/IMAP_HOST=\"$IMAP_HOST_SAFE\"/" /usr/local/bin/mail-test-api.sh
sed -i "s/IMAP_PORT=993/IMAP_PORT=$IMAP_PORT_SAFE/" /usr/local/bin/mail-test-api.sh
sed -i "s/IMAP_USER=\"user@example.com\"/IMAP_USER=\"$IMAP_USER_SAFE\"/" /usr/local/bin/mail-test-api.sh
sed -i "s/IMAP_PASS=\"password\"/IMAP_PASS=\"$IMAP_PASS_SAFE\"/" /usr/local/bin/mail-test-api.sh

chmod +x /usr/local/bin/mail-test-api.sh

# Create systemd service
echo ""
echo "Step 4: Creating SystemD service..."
cat > /etc/systemd/system/mail-test-api.service <<EOF
[Unit]
Description=Mail Round-Trip Test API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mail-test-api.sh
Restart=always
RestartSec=10
User=root
StandardOutput=append:/var/log/mail-test-api.log
StandardError=append:/var/log/mail-test-api.log

[Install]
WantedBy=multi-user.target
EOF

# Create log file
touch /var/log/mail-test-api.log
chmod 644 /var/log/mail-test-api.log

# Enable and start service
echo ""
echo "Step 5: Starting service..."
systemctl daemon-reload
systemctl enable mail-test-api
systemctl start mail-test-api

# Check status
sleep 2
if systemctl is-active --quiet mail-test-api; then
    echo ""
    echo "========================================="
    echo "✓ Installation successful!"
    echo "========================================="
    echo ""
    echo "Service is running on port $API_PORT"
    echo "Log file: /var/log/mail-test-api.log"
    echo ""
    echo "Test with:"
    echo "  curl \"http://localhost:$API_PORT/test?host=smtp.example.com&port=587&smtp_user=user@domain.com&smtp_pass=password&tls=tls\""
    echo ""
    echo "View logs:"
    echo "  tail -f /var/log/mail-test-api.log"
else
    echo ""
    echo "ERROR: Service failed to start"
    echo "Check logs: journalctl -u mail-test-api -n 50"
    exit 1
fi
