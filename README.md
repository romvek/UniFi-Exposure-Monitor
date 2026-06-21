# UniFi Exposure Monitor

A lightweight bash-based monitor that periodically checks whether your UniFi management interface is exposed to the internet. Findings are reported via **Telegram** and pushed to **Prometheus Pushgateway** for visualization in **Grafana**.

## The why
I recently saw a critical vulnerability affecting UniFi gateways if exposed to the internet. After a quick search, I found a few simple ways to determine whether or not I was affected. Those checks all passed. 
Ok... cool, now what? I wanted to create a monitor to alert me if my gateway ever becomes exposed. This was more of a learning-type project for me.
- Is it necessary? Maybe, maybe not.
- Can it be done better? Probably, definitely.
- Did I learn something? Absolutely!!
While trying to add more context for the reason why I created this, I ran some searches trying to find the exact vulnerability I originally saw that sparked this project. 
**CVE-2026-34908 - CVE-2026-34909 - CVE-2026-34910**
- [Bishop Fox: Popping Root on UniFi OS Server: Unauthenticated RCE Chain Detection & Analysis](https://bishopfox.com/blog/popping-root-on-unifi-os-server-unauthenticated-rce-chain-detection-analysis)
- [UniFi - Security Advisory Bulletin 064](https://community.ui.com/releases/Security-Advisory-Bulletin-064-064/84811c09-4cf4-42ab-bd61-cc994445963b)

---

## How it works

Each run performs three checks against your WAN IP:

| Check | Method | Flag if... |
|-------|--------|------------|
| DNS | `dig` on your controller hostname | Resolves to a public IP |
| Curl | HTTPS request to WAN IP on port 8443 | Gets a non-404 HTTP response |
| Shodan | Shodan API query on your WAN IP | Any UniFi port listed as open |

UniFi ports checked via Shodan: `8443, 8080, 443, 8843, 8880`

Results are scored as:
- `0` — **CLEAN**: all checks passed
- `1` — **WARNING**: DNS or curl anomaly, stale Shodan data, or Shodan unavailable
- `2` — **EXPOSED**: one or more UniFi ports confirmed open in Shodan

> **Why Shodan instead of nmap?** Running nmap from inside your network against your own WAN IP triggers NAT loopback — your router responds internally, producing false positives. Shodan scans from the actual internet and gives you a true outside-in perspective.

---

## Prerequisites

- A Linux host — a VM, LXC container, Docker container, or VPS running **Debian 12** or **Ubuntu 22.04+**
- **Prometheus** already running on your network
- **Prometheus Pushgateway** running and configured as a scrape target in `prometheus.yml`
- **Grafana** pointed at your Prometheus instance
- A **Telegram bot** (setup instructions below)
- A **Shodan account** with an API key — free tier supported (https://account.shodan.io)
- A **private GitHub repo** (recommended) to host the script

---

## Installation

### 1. Clone the repo onto your host

For a private repo, set up a deploy key first:

```bash
ssh-keygen -t ed25519 -C "unifi-monitor" -f /root/.ssh/github_deploy -N ""
cat /root/.ssh/github_deploy.pub
```

Add the public key to your repo under **Settings → Deploy keys** (read-only). Then configure SSH:

```bash
cat >> /root/.ssh/config <<EOF2
Host github.com
    IdentityFile /root/.ssh/github_deploy
    IdentitiesOnly yes
EOF2
```

Test and clone:
```bash
ssh -T git@github.com
git clone git@github.com:yourusername/your-repo.git /opt/unifi-monitor
```

---

### 2. Configure

```bash
cp /opt/unifi-monitor/config.env.example /opt/unifi-monitor/config.env
nano /opt/unifi-monitor/config.env
```

Fill in your values:

```bash
UNIFI_HOSTNAME="unifi.yourdomain.com"
WAN_IP=""                                      # Leave blank to auto-detect
TELEGRAM_BOT_TOKEN="123456789:ABCdef..."       # Do NOT prefix with "bot"
TELEGRAM_CHAT_ID="123456789"
PUSHGATEWAY_URL="http://192.168.1.50:9091"
SHODAN_API_KEY="your-api-key"
```

> `config.env` is gitignored and will never be committed. It stays on your host only.

---

### 3. Set up Telegram

1. Message **@BotFather** in Telegram
2. Send `/newbot` and follow the prompts
3. Copy the token and paste into `TELEGRAM_BOT_TOKEN` (no "bot" prefix in the value)
4. Send any message to your bot, then visit:
   `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates`
5. Find `"chat":{"id":XXXXXXXXX}` and paste into `TELEGRAM_CHAT_ID`

---

### 4. Set up Prometheus Pushgateway

If Pushgateway is not running yet, install it on your Prometheus host:

```bash
wget https://github.com/prometheus/pushgateway/releases/download/v1.7.0/pushgateway-1.7.0.linux-amd64.tar.gz
tar xvf pushgateway-1.7.0.linux-amd64.tar.gz
mv pushgateway-1.7.0.linux-amd64/pushgateway /usr/local/bin/

cat > /etc/systemd/system/pushgateway.service << 'SVCEOF'
[Unit]
Description=Prometheus Pushgateway
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/pushgateway
Restart=on-failure
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable pushgateway
systemctl start pushgateway
```

Add to `prometheus.yml` under `scrape_configs`:

```yaml
  - job_name: 'pushgateway'
    honor_labels: true
    static_configs:
      - targets: ['localhost:9091']
```

Restart Prometheus: `systemctl restart prometheus`

---

### 5. Run setup

```bash
chmod +x /opt/unifi-monitor/setup.sh
bash /opt/unifi-monitor/setup.sh
```

Installs dependencies (`curl`, `dnsutils`, `git`), configures log rotation, and installs the cron job.

---

### 6. Test manually

```bash
/opt/unifi-monitor/unifi_monitor.sh
tail -f /var/log/unifi_monitor.log
```

A Telegram message should arrive and metrics should appear in Pushgateway:
```bash
curl http://<pushgateway-ip>:9091/metrics | grep unifi
```

---

### 7. Import the Grafana dashboard

Grafana → **Dashboards → Import** → upload `grafana_dashboard.json` → select your Prometheus datasource → **Import**.

---

## Schedule

Edit `/etc/cron.d/unifi-monitor`. Defaults to daily at 9am. Uncomment one line at a time:

```
# Once daily at 9am (active)
0 9 * * * root /opt/unifi-monitor/unifi_monitor.sh >> /var/log/unifi_monitor.log 2>&1

# Every 6 hours
# 0 */6 * * * root /opt/unifi-monitor/unifi_monitor.sh >> /var/log/unifi_monitor.log 2>&1

# Every 12 hours
# 0 */12 * * * root /opt/unifi-monitor/unifi_monitor.sh >> /var/log/unifi_monitor.log 2>&1

# Every other day at 9am
# 0 9 */2 * * root /opt/unifi-monitor/unifi_monitor.sh >> /var/log/unifi_monitor.log 2>&1

# Once a week on Monday at 9am
# 0 9 * * 1 root /opt/unifi-monitor/unifi_monitor.sh >> /var/log/unifi_monitor.log 2>&1
```

No restart needed — cron picks up changes automatically.

---

## Notification behavior

| Status | Telegram | Frequency |
|--------|----------|-----------|
| EXPOSED | Immediate alert with details | Every run |
| WARNING | Alert with details | Every run |
| CLEAN | Daily confirmation with Shodan last scan date | Once per day max |

---

## Prometheus metrics

| Metric | Type | Description |
|--------|------|-------------|
| `unifi_exposure_risk` | gauge | Overall risk: 0=clean, 1=warning, 2=exposed |
| `unifi_dns_public_ip` | gauge | 1 if hostname resolves to a public IP |
| `unifi_curl_reachable` | gauge | 1 if port 8443 responds externally |
| `unifi_exposed_ports_total` | gauge | Count of UniFi ports found open in Shodan |
| `unifi_shodan_data_stale` | gauge | 1 if Shodan data is older than 7 days |
| `unifi_last_check_timestamp_seconds` | gauge | Unix timestamp of last run |

---

## Troubleshooting

**`config.env: line N: $'\r': command not found`**
Windows line endings in the file. Fix with:
```bash
sed -i 's/\r//' /opt/unifi-monitor/config.env
```

**Telegram not sending**
Verify token format — `123456789:ABCdef...` with no `bot` prefix in the value. The script adds `bot` automatically in the API URL. Also make sure you have sent at least one message to the bot before running.

**Shodan returns no data**
Your WAN IP may not have been scanned yet. Logged as `notfound` and treated as inconclusive — does not trigger a WARNING.

**Shodan data is stale**
Shodan does not scan on a fixed schedule. If data is older than 7 days the script flags a WARNING with the last scan date in the Telegram message. Informational only.

**Pushgateway not receiving data**
```bash
curl http://your-pushgateway-ip:9091/metrics
```

**Grafana panels show no data**
Check `http://<prometheus-ip>:9090/targets` — both `prometheus` and `pushgateway` should show as UP.

**WAN IP detection failing**
Set `WAN_IP` manually in `config.env`.

---

## Repository structure

```
.
├── unifi_monitor.sh       # Main monitoring script
├── setup.sh               # One-time bootstrap script
├── grafana_dashboard.json # Grafana dashboard import file
├── config.env.example     # Config template (copy to config.env)
├── .gitignore             # Excludes config.env from version control
└── README.md              # This file
```
