# Email Round-Trip Monitoring API

A bash-based HTTP API service that monitors email server health by sending test emails via SMTP and verifying delivery via IMAP. Perfect for use with monitoring tools like Uptime Kuma.

## What It Does

This service provides an HTTP endpoint that performs complete email round-trip testing :

1. **Sends** a test email via your SMTP server with a unique subject line
2. **Waits** a configurable time (default: 10 seconds) for delivery
3. **Checks** an IMAP inbox to verify the email arrived
4. **Deletes** the test email automatically to keep the inbox clean
5. **Returns** HTTP 200 OK on success or 503 Service Unavailable on failure

Key features:

- Supports ports 25, 465, 587, and custom ports
- Configurable TLS modes: STARTTLS, implicit TLS, or plain text
- Optional SMTP authentication
- Automatic retry logic with exponential backoff for network reliability
- Full debug logging
- SystemD service integration with auto-restart


## Prerequisites

- Debian/Ubuntu Linux (or compatible)
- Root access
- Email account with IMAP access for monitoring
- Outbound connectivity to your SMTP and IMAP servers

## Security Notes

- The script stores IMAP credentials in plain text - secure the file with proper permissions
- Consider using a dedicated monitoring email account
- Use app-specific passwords where available
- Restrict API access using a firewall if exposed to untrusted networks

## Quick Install

### Method 1: Automated Install Script

```bash
wget adr
chmod +x install-mail-test-api.sh
sudo ./install-mail-test-api.sh
```



### Method 2: Manual Installation

1. **Install dependencies:**
```bash
sudo apt-get update
sudo apt-get install -y nmap swaks curl openssl
```

2. **Create the main script** at `/usr/local/bin/mail-test-api.sh` (copy the complete script from the installer above, between `EOFSCRIPT` markers)
3. **Edit configuration** in the script:
```bash
sudo nano /usr/local/bin/mail-test-api.sh
```

Update these variables:

- `PORT` - HTTP API port (default: 8081)
- `IMAP_HOST` - Your IMAP server (e.g., imap.gmail.com, imap.mail.yahoo.com)
- `IMAP_PORT` - IMAP port (default: 993 for IMAPS)
- `IMAP_USER` - Your email address
- `IMAP_PASS` - Your IMAP password or app password

4. **Make executable:**
```bash
sudo chmod +x /usr/local/bin/mail-test-api.sh
```

5. **Create SystemD service:**
```bash
sudo nano /etc/systemd/system/mail-test-api.service
```

Paste:

```ini
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
```

6. **Start the service:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable mail-test-api
sudo systemctl start mail-test-api
sudo systemctl status mail-test-api
```


## API Usage

### Endpoint

```
GET http://localhost:8081/test
```


### Parameters

| Parameter | Required | Description | Example |
| :-- | :-- | :-- | :-- |
| `host` | Yes | SMTP server hostname | `mail.example.com` |
| `port` | Yes | SMTP server port | `587`, `465`, `25`, or custom |
| `smtp_user` | No | SMTP username | `user@domain.com` |
| `smtp_pass` | No | SMTP password | `mypassword` |
| `tls` | No | TLS mode: `tls`, `tlsc`, `none` | `tls` |

### TLS Modes[^3][^2]

- `tls` or `starttls` - STARTTLS (typically port 587)
- `tlsc`, `implicit`, or `smtps` - Implicit TLS (typically port 465)
- `none` or empty - Plain text (typically port 25)


### Examples

**Port 587 with STARTTLS:**

```bash
curl "http://localhost:8081/test?host=smtp.gmail.com&port=587&smtp_user=user%40gmail.com&smtp_pass=apppassword&tls=tls"
```

**Port 465 with implicit TLS:**

```bash
curl "http://localhost:8081/test?host=smtp.office365.com&port=465&smtp_user=user%40domain.com&smtp_pass=password&tls=tlsc"
```

**Port 25 relay (no auth, no TLS):**

```bash
curl "http://localhost:8081/test?host=mail.example.com&port=25"
```

**Custom port with authentication:**

```bash
curl "http://localhost:8081/test?host=mail.example.com&port=2525&smtp_user=monitoring&smtp_pass=secret&tls=starttls"
```

**Note:** URL-encode special characters in passwords (e.g., `@` = `%40`, `]` = `%5D`, `(` = `%28`)

### Response Codes

- `200 OK` - Email successfully sent and verified
- `400 Bad Request` - Missing required parameters
- `404 Not Found` - Invalid endpoint
- `503 Service Unavailable` - Email send failed or not received


### Response Body

Success:

```
SUCCESS: Email round-trip completed via mail.example.com:587
```

Failure:

```
FAILED: Email sent but not received within 10s
```


## Integration with Uptime Kuma

1. Add new monitor
2. Monitor Type: **HTTP(s)**
3. URL: `http://your-server:8081/test?host=smtp.example.com&port=587&smtp_user=user%40domain.com&smtp_pass=password&tls=tls`
4. Heartbeat Interval: **300 seconds** (5 minutes)
5. Timeout: **90 seconds**
6. Expected Status: **200**

## Logs

**View real-time logs:**

```bash
sudo tail -f /var/log/mail-test-api.log
```

**View service status:**

```bash
sudo systemctl status mail-test-api
```

**View SystemD journal:**

```bash
sudo journalctl -u mail-test-api -f
```

**View last 50 log entries:**

```bash
sudo journalctl -u mail-test-api -n 50
```

**Enable debug mode** (edit script):

```bash
sudo nano /usr/local/bin/mail-test-api.sh
# Change: DEBUG=0 to DEBUG=1
sudo systemctl restart mail-test-api
```


## Configuration

Edit `/usr/local/bin/mail-test-api.sh`:


| Variable | Default | Description |
| :-- | :-- | :-- |
| `PORT` | 8081 | HTTP API port |
| `IMAP_HOST` | imap.gmail.com | IMAP server hostname |
| `IMAP_PORT` | 993 | IMAP server port |
| `IMAP_USER` | (your email) | IMAP username/email |
| `IMAP_PASS` | (your password) | IMAP password |
| `WAIT_TIME` | 10 | Seconds to wait before checking IMAP |
| `MAX_RETRIES` | 3 | Number of retry attempts for IMAP |
| `RETRY_DELAY` | 10 | Initial retry delay (exponential backoff) |
| `SMTP_TIMEOUT` | 30 | SMTP operation timeout in seconds |
| `IMAP_TIMEOUT` | 15 | IMAP operation timeout in seconds |
| `DEBUG` | 0 | Enable verbose logging (0=off, 1=on) |

After changes:

```bash
sudo systemctl restart mail-test-api
```


## Supported IMAP Services

This works with any IMAP-compatible email service:

- **Gmail** - imap.gmail.com:993 (requires App Password)
- **Outlook/Office365** - outlook.office365.com:993
- **Yahoo Mail** - imap.mail.yahoo.com:993
- **iCloud** - imap.mail.me.com:993
- **Custom** - Your own mail server


## Troubleshooting

**Service won't start:**

```bash
sudo journalctl -u mail-test-api -n 50
```

**ncat not found:**

```bash
sudo apt-get install nmap
```

**Test IMAP credentials:**

```bash
curl -v --max-time 10 \
  --url "imaps://imap.gmail.com:993/INBOX" \
  --user "your@email.com:your-password" \
  --request "NOOP"
```

**Test SMTP manually:**

```bash
swaks --to your@email.com --from test@test.com \
  --server smtp.gmail.com:587 --tls \
  --auth-user your@email.com --auth-password your-password
```

**Check firewall:**

```bash
sudo ufw status
sudo ufw allow 8081/tcp
```

**Connection refused:**

- Check if service is running: `systemctl status mail-test-api`
- Check if port is listening: `sudo netstat -tlnp | grep 8081`

**IMAP connection errors:**

- Verify IMAP credentials are correct
- Check if IMAP access is enabled for your account
- Gmail users: Use an App Password, not your regular password


## Uninstall

```bash
sudo systemctl stop mail-test-api
sudo systemctl disable mail-test-api
sudo rm /etc/systemd/system/mail-test-api.service
sudo rm /usr/local/bin/mail-test-api.sh
sudo rm /var/log/mail-test-api.log
sudo systemctl daemon-reload
```

## License

MIT License - Feel free to modify and distribute.

