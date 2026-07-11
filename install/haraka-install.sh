#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: cjarvis
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://haraka.github.io
# Description: Installs Haraka, a high-performance Node.js SMTP server with interactive plugin selection

# shellcheck source=/dev/null
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  ca-certificates \
  gnupg \
  whiptail \
  python3
msg_ok "Installed Dependencies"

msg_info "Installing Node.js"
NODE_VERSION="22" setup_nodejs
msg_ok "Installed Node.js"

msg_info "Installing Haraka"
RELEASE=$(curl -fsSL https://registry.npmjs.org/Haraka/latest | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")
if [[ -z "${RELEASE}" ]]; then
  msg_error "Failed to fetch latest Haraka version from npm"
  exit 1
fi
$STD npm install -g Haraka@"${RELEASE}"
useradd -r -s /usr/sbin/nologin haraka
mkdir -p /opt/haraka
$STD haraka --install /opt/haraka
echo "${RELEASE}" >/opt/haraka_version.txt
msg_ok "Installed Haraka ${RELEASE}"

# ---------------------------------------------------------------------------
# SCREEN 1: Purpose selector
# ---------------------------------------------------------------------------
if ! PURPOSES=$(whiptail --title "Haraka Setup — Step 1 of 3" \
  --checklist "Select your use case(s). Plugins will be pre-selected on the next screen." 20 70 5 \
  "inbound"   "Inbound MTA (receive mail)"          OFF \
  "relay"     "Outbound Relay (send via upstream)"  OFF \
  "spam"      "Spam Filtering (rspamd + extras)"    OFF \
  "antivirus" "Antivirus (ClamAV)"                  OFF \
  "monitor"   "Monitoring (watch UI, syslog)"       OFF \
  3>&1 1>&2 2>&3); then
  msg_error "Installation cancelled."
  exit 1
fi

# Build pre-selected plugin list from chosen purposes
# Base plugins always enabled regardless of preset
PLUGIN_SELECTED="tls helo.checks bounce spf fcrdns mail_from.is_resolvable early_talker toobusy process_title"

if echo "${PURPOSES}" | grep -q "inbound"; then
  PLUGIN_SELECTED="${PLUGIN_SELECTED} spf dkim fcrdns mail_from.is_resolvable rcpt_to.in_host_list"
fi

if echo "${PURPOSES}" | grep -q "relay"; then
  PLUGIN_SELECTED="${PLUGIN_SELECTED} relay auth/flat_file"
fi

if echo "${PURPOSES}" | grep -q "spam"; then
  PLUGIN_SELECTED="${PLUGIN_SELECTED} rspamd greylist karma dns-list uribl delay_deny tarpit early_talker"
fi

if echo "${PURPOSES}" | grep -q "antivirus"; then
  PLUGIN_SELECTED="${PLUGIN_SELECTED} clamd"
fi

if echo "${PURPOSES}" | grep -q "monitor"; then
  PLUGIN_SELECTED="${PLUGIN_SELECTED} watch process_title syslog"
fi

# Export so subshells (build_item) can access it
export PLUGIN_SELECTED

# ---------------------------------------------------------------------------
# SCREEN 2: Plugin fine-tuning
# ---------------------------------------------------------------------------
is_selected() { echo "${PLUGIN_SELECTED}" | grep -qw "$1" && echo "ON" || echo "OFF"; }

PLUGIN_ARGS=(
  "tls"                     "TLS/STARTTLS support"                        "$(is_selected tls)"
  "spf"                     "SPF validation"                               "$(is_selected spf)"
  "dkim"                    "DKIM sign and verify"                         "$(is_selected dkim)"
  "fcrdns"                  "Forward-confirmed reverse DNS"                "$(is_selected fcrdns)"
  "helo.checks"             "HELO/EHLO validity checks"                    "$(is_selected helo.checks)"
  "mail_from.is_resolvable" "Verify sender domain has MX record"           "$(is_selected mail_from.is_resolvable)"
  "bounce"                  "Bounce processing"                            "$(is_selected bounce)"
  "rcpt_to.in_host_list"    "Define local recipient domains"               "$(is_selected rcpt_to.in_host_list)"
  "relay"                   "Manage relay permissions"                     "$(is_selected relay)"
  "auth/flat_file"          "SMTP AUTH against a flat file"                "$(is_selected auth/flat_file)"
  "rspamd"                  "Spam scanning via rspamd"                     "$(is_selected rspamd)"
  "greylist"                "Greylisting"                                  "$(is_selected greylist)"
  "karma"                   "Dynamic connection scoring"                   "$(is_selected karma)"
  "dns-list"                "DNS blacklist and whitelist checks"           "$(is_selected dns-list)"
  "uribl"                   "URI blacklist checks"                         "$(is_selected uribl)"
  "delay_deny"              "Delay deny responses"                         "$(is_selected delay_deny)"
  "tarpit"                  "Slow down suspicious connections"             "$(is_selected tarpit)"
  "early_talker"            "Reject clients that talk before banner"       "$(is_selected early_talker)"
  "toobusy"                 "Defer connections when server is under load"  "$(is_selected toobusy)"
  "clamd"                   "Antivirus scanning via ClamAV"                "$(is_selected clamd)"
  "watch"                   "Live SMTP traffic web UI - port 8055"         "$(is_selected watch)"
  "process_title"           "Show activity counters in ps output"          "$(is_selected process_title)"
  "syslog"                  "Log to syslog"                                "$(is_selected syslog)"
)

if ! PLUGIN_LIST=$(whiptail --title "Haraka Setup — Step 2 of 3" \
  --checklist "Review and adjust plugins. Pre-checked items come from your selected presets." 30 78 20 \
  "${PLUGIN_ARGS[@]}" \
  3>&1 1>&2 2>&3); then
  msg_error "Installation cancelled."
  exit 1
fi

# ---------------------------------------------------------------------------
# SCREEN 3: Queue plugin (required)
# ---------------------------------------------------------------------------
if ! QUEUE=$(whiptail --title "Haraka Setup — Step 3 of 3" \
  --menu "Select a queue (delivery) plugin. This is required — Haraka will not deliver mail without one." 18 70 4 \
  "smtp_forward" "Forward to upstream SMTP (SES, Mailgun, etc.)" \
  "lmtp"         "Deliver via LMTP (e.g. to Dovecot)" \
  "discard"      "Discard all mail (testing only)" \
  "rabbitmq"     "Queue to RabbitMQ" \
  3>&1 1>&2 2>&3); then
  msg_error "Installation cancelled."
  exit 1
fi

# Queue-specific config prompts
if [[ "${QUEUE}" == "smtp_forward" ]]; then
  FWD_HOST=$(whiptail --title "Queue: smtp_forward" --inputbox \
    "Forward host (e.g. email-smtp.us-east-1.amazonaws.com or smtp.mailgun.org):" \
    10 70 "" 3>&1 1>&2 2>&3)
  FWD_PORT=$(whiptail --title "Queue: smtp_forward" --inputbox \
    "Forward port:" 10 40 "587" 3>&1 1>&2 2>&3)
  FWD_USER=$(whiptail --title "Queue: smtp_forward" --inputbox \
    "Auth username (leave blank if not required):" 10 70 "" 3>&1 1>&2 2>&3)
  FWD_PASS=$(whiptail --title "Queue: smtp_forward" --passwordbox \
    "Auth password (leave blank if not required):" 10 70 "" 3>&1 1>&2 2>&3)
  {
    echo "[main]"
    echo "host=${FWD_HOST}"
    echo "port=${FWD_PORT}"
    if [[ -n "${FWD_USER}" ]]; then
      echo "auth_user=${FWD_USER}"
      echo "auth_pass=${FWD_PASS}"
      echo "enable_tls=1"
    fi
  } >/opt/haraka/config/smtp_forward.ini

elif [[ "${QUEUE}" == "lmtp" ]]; then
  LMTP_TARGET=$(whiptail --title "Queue: lmtp" --inputbox \
    "LMTP target (socket path e.g. /var/run/dovecot/lmtp, or host:port):" \
    10 70 "/var/run/dovecot/lmtp" 3>&1 1>&2 2>&3)
  if [[ "${LMTP_TARGET}" == /* ]]; then
    echo "path=${LMTP_TARGET}" >/opt/haraka/config/lmtp.ini
  else
    LMTP_HOST="${LMTP_TARGET%%:*}"
    LMTP_PORT="${LMTP_TARGET##*:}"
    printf "[main]\nhost=%s\nport=%s\n" "${LMTP_HOST}" "${LMTP_PORT}" >/opt/haraka/config/lmtp.ini
  fi

elif [[ "${QUEUE}" == "rabbitmq" ]]; then
  RMQ_HOST=$(whiptail --title "Queue: rabbitmq" --inputbox "RabbitMQ host:" 10 50 "localhost" 3>&1 1>&2 2>&3)
  RMQ_PORT=$(whiptail --title "Queue: rabbitmq" --inputbox "RabbitMQ port:" 10 40 "5672" 3>&1 1>&2 2>&3)
  RMQ_VHOST=$(whiptail --title "Queue: rabbitmq" --inputbox "RabbitMQ vhost:" 10 40 "/" 3>&1 1>&2 2>&3)
  RMQ_USER=$(whiptail --title "Queue: rabbitmq" --inputbox "RabbitMQ username:" 10 50 "guest" 3>&1 1>&2 2>&3)
  RMQ_PASS=$(whiptail --title "Queue: rabbitmq" --passwordbox "RabbitMQ password:" 10 50 "" 3>&1 1>&2 2>&3)
  {
    echo "[main]"
    echo "host=${RMQ_HOST}"
    echo "port=${RMQ_PORT}"
    echo "vhost=${RMQ_VHOST}"
    echo "user=${RMQ_USER}"
    echo "password=${RMQ_PASS}"
    echo "queue=haraka"
  } >/opt/haraka/config/rabbitmq.ini
fi

# ---------------------------------------------------------------------------
# SCREEN 3b (conditional): SMTP AUTH setup
# ---------------------------------------------------------------------------
if echo "${PLUGIN_LIST}" | grep -q "auth/flat_file"; then
  AUTH_USER=$(whiptail --title "SMTP AUTH Setup" --inputbox \
    "Enter a username for SMTP AUTH:\n(Additional users can be added to /opt/haraka/config/auth_flat_file.ini)" \
    10 65 "" 3>&1 1>&2 2>&3)
  AUTH_PASS=$(whiptail --title "SMTP AUTH Setup" --passwordbox \
    "Enter password for '${AUTH_USER}':" \
    8 50 "" 3>&1 1>&2 2>&3)
fi

# ---------------------------------------------------------------------------
# SCREEN 3c (conditional): Relay network setup
# ---------------------------------------------------------------------------
if echo "${PLUGIN_LIST}" | grep -q "relay"; then
  RELAY_NETS=$(whiptail --title "Relay Network Setup" --inputbox \
    "Enter networks allowed to relay without authentication.\nComma-separated CIDRs (e.g. 192.168.1.0/24, 10.0.0.0/8):" \
    10 70 "" 3>&1 1>&2 2>&3)
fi

# ---------------------------------------------------------------------------
# SCREEN 3d: TLS setup
# ---------------------------------------------------------------------------
if ! TLS_CERT_TYPE=$(whiptail --title "TLS Certificate Setup" \
  --menu "Select a TLS certificate option:" 12 65 2 \
  "self-signed" "Generate a self-signed certificate automatically" \
  "existing"    "Use an existing certificate (Let's Encrypt, etc.)" \
  3>&1 1>&2 2>&3); then
  msg_error "Installation cancelled."
  exit 1
fi

if [[ "${TLS_CERT_TYPE}" == "existing" ]]; then
  TLS_CERT_PATH=$(whiptail --title "TLS Certificate" --inputbox \
    "Path to certificate file (.pem or .crt):" \
    8 65 "/etc/letsencrypt/live/yourdomain/fullchain.pem" 3>&1 1>&2 2>&3)
  TLS_KEY_PATH=$(whiptail --title "TLS Certificate" --inputbox \
    "Path to private key file (.pem or .key):" \
    8 65 "/etc/letsencrypt/live/yourdomain/privkey.pem" 3>&1 1>&2 2>&3)
fi

if whiptail --title "TLS — Enforce STARTTLS" --yesno \
  "Enforce STARTTLS for all inbound connections?\n\nYes: reject clients that do not support STARTTLS (more secure)\nNo:  offer STARTTLS but allow unencrypted connections (more compatible)" \
  10 70; then
  TLS_REQUIRE="true"
else
  TLS_REQUIRE="false"
fi

# ---------------------------------------------------------------------------
# SCREEN 4 (conditional): rspamd install
# ---------------------------------------------------------------------------
INSTALL_RSPAMD=false
if echo "${PLUGIN_LIST}" | grep -q "rspamd"; then
  INSTALL_RSPAMD=true
fi

# ---------------------------------------------------------------------------
# SCREEN 5 (conditional): ClamAV install
# ---------------------------------------------------------------------------
INSTALL_CLAMD=false
if echo "${PLUGIN_LIST}" | grep -q "clamd"; then
  INSTALL_CLAMD=true
fi

# ---------------------------------------------------------------------------
# SCREEN 6: Additional configuration required notice
# ---------------------------------------------------------------------------
MANUAL_CONFIG_ITEMS=""
if echo "${PLUGIN_LIST}" | grep -q "relay"; then
  MANUAL_CONFIG_ITEMS+="  • relay       → /opt/haraka/config/relay_acl_allow\n"
fi
if echo "${PLUGIN_LIST}" | grep -q "rcpt_to.in_host_list"; then
  MANUAL_CONFIG_ITEMS+="  • rcpt_to     → /opt/haraka/config/host_list\n"
fi
if echo "${PLUGIN_LIST}" | grep -q "auth/flat_file"; then
  MANUAL_CONFIG_ITEMS+="  • auth        → /opt/haraka/config/auth_flat_file.ini\n"
fi
if echo "${PLUGIN_LIST}" | grep -q "dkim"; then
  if [[ "${QUEUE}" == "smtp_forward" ]]; then
    MANUAL_CONFIG_ITEMS+="  • dkim        → Not required: your upstream relay (SES/Mailgun) handles DKIM signing.\n"
  else
    MANUAL_CONFIG_ITEMS+="  • dkim        → Key generation required. Run: haraka-dkim-gen\n                   Then add the DNS TXT record to your domain.\n"
  fi
fi
if echo "${PLUGIN_LIST}" | grep -q "greylist"; then
  MANUAL_CONFIG_ITEMS+="  • greylist    → /opt/haraka/config/greylist.ini\n"
fi

if [[ -n "${MANUAL_CONFIG_ITEMS}" ]]; then
  whiptail --title "Haraka Setup — Additional Configuration Required" --msgbox \
    "The following plugins require manual configuration after install:\n\n${MANUAL_CONFIG_ITEMS}\nAll config files are located in /opt/haraka/config/" \
    20 72
fi

# ---------------------------------------------------------------------------
# Install rspamd (if selected)
# ---------------------------------------------------------------------------
if [[ "${INSTALL_RSPAMD}" == true ]]; then
  msg_info "Installing rspamd"
  $STD apt-get install -y lsb-release
  CODENAME=$(lsb_release -cs)
  curl -fsSL https://rspamd.com/apt-stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/rspamd-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/rspamd-archive-keyring.gpg] https://rspamd.com/apt-stable/ ${CODENAME} main" \
    >/etc/apt/sources.list.d/rspamd.list
  $STD apt-get update
  $STD apt-get install -y rspamd
  {
    echo 'bind_socket = "localhost:11333";'
  } >/etc/rspamd/local.d/worker-normal.inc
  {
    echo 'bind_socket = "localhost:11334";'
    echo 'password = "";'
    echo 'secure_ip = ["127.0.0.1", "::1"];'
  } >/etc/rspamd/local.d/worker-controller.inc
  systemctl enable --now rspamd
  msg_ok "Installed rspamd"

  {
    echo "[main]"
    echo "host=localhost"
    echo "port=11333"
  } >/opt/haraka/config/rspamd.ini
fi

# ---------------------------------------------------------------------------
# Install ClamAV (if selected)
# ---------------------------------------------------------------------------
if [[ "${INSTALL_CLAMD}" == true ]]; then
  msg_info "Installing ClamAV"
  $STD apt-get install -y clamav clamav-daemon
  systemctl stop clamav-freshclam
  msg_info "Updating virus definitions (this may take a few minutes)"
  $STD freshclam
  systemctl enable --now clamav-daemon clamav-freshclam
  msg_ok "Installed ClamAV"

  {
    echo "[main]"
    echo "clamd_socket=/var/run/clamav/clamd.ctl"
  } >/opt/haraka/config/clamd.ini
fi

# ---------------------------------------------------------------------------
# Write Haraka config/plugins file
# ---------------------------------------------------------------------------
msg_info "Configuring Haraka plugins"
{
  echo "# Haraka plugins — managed by installer"
  echo "# Add or remove plugins here, then restart haraka"
  echo ""
  for plugin in $(echo "${PLUGIN_LIST}" | tr -d '"' | tr ' ' '\n'); do
    echo "${plugin}"
  done
  echo "queue/${QUEUE}"
} >/opt/haraka/config/plugins
msg_ok "Configured plugins"

# ---------------------------------------------------------------------------
# Configure SMTP port and optional watch UI
# ---------------------------------------------------------------------------
msg_info "Configuring Haraka"
{
  echo "[main]"
  echo "port=2525"
  echo "listen_host=0.0.0.0"
} >/opt/haraka/config/smtp.ini

# Write SMTP AUTH config if auth/flat_file was selected
if [[ -n "${AUTH_USER:-}" ]]; then
  AUTH_PASS_ENC=$(node -e "const crypto=require('crypto'); const h=crypto.createHash('sha1'); h.update('${AUTH_PASS}'); console.log('{SHA}'+h.digest('base64'));")
  {
    echo "[core]"
    echo "methods=PLAIN,LOGIN,CRAM-MD5"
    echo ""
    echo "[users]"
    echo "${AUTH_USER}=${AUTH_PASS_ENC}"
  } >/opt/haraka/config/auth_flat_file.ini
  # Remove auth from manual config notice since we configured it
  MANUAL_CONFIG_ITEMS="${MANUAL_CONFIG_ITEMS//  • auth        → \/opt\/haraka\/config\/auth_flat_file.ini\\n/}"
fi

# Write relay ACL if relay was selected
if [[ -n "${RELAY_NETS:-}" ]]; then
  {
    echo "# Relay allowed networks"
    echo "${RELAY_NETS}" | tr ',' '\n' | sed 's/^[[:space:]]*//'
  } >/opt/haraka/config/relay_acl_allow
  # Remove relay from manual config notice since we configured it
  MANUAL_CONFIG_ITEMS="${MANUAL_CONFIG_ITEMS//  • relay       → \/opt\/haraka\/config\/relay_acl_allow\\n/}"
fi

if echo "${PLUGIN_LIST}" | grep -q "watch"; then
  {
    echo "[main]"
    echo "port=8055"
    echo "bind=0.0.0.0"
  } >/opt/haraka/config/watch.ini
  msg_info "Installing Redis (required by watch plugin)"
  $STD apt-get install -y redis-server
  systemctl enable --now redis-server
  msg_ok "Installed Redis"
fi

# Install npm-packaged plugins that were selected
# Note: tarpit, delay_deny, process_title, rcpt_to.in_host_list,
# reseed_rng, record_envelope_addresses, and all queue/* plugins are built into
# Haraka and do not need to be installed via npm.
# toobusy is built-in but requires the external toobusy-js npm dependency.
# syslog requires haraka-plugin-syslog from npm.
NPM_PLUGINS=("toobusy-js")
if echo "${PLUGIN_LIST}" | grep -q "syslog";                  then NPM_PLUGINS+=("haraka-plugin-syslog"); fi
if echo "${PLUGIN_LIST}" | grep -q "rspamd";                  then NPM_PLUGINS+=("haraka-plugin-rspamd"); fi
if echo "${PLUGIN_LIST}" | grep -q "greylist";                then NPM_PLUGINS+=("haraka-plugin-greylist"); fi
if echo "${PLUGIN_LIST}" | grep -q "karma";                   then NPM_PLUGINS+=("haraka-plugin-karma"); fi
if echo "${PLUGIN_LIST}" | grep -q "dns-list";                then NPM_PLUGINS+=("haraka-plugin-dns-list"); fi
if echo "${PLUGIN_LIST}" | grep -q "uribl";                   then NPM_PLUGINS+=("haraka-plugin-uribl"); fi
if echo "${PLUGIN_LIST}" | grep -q "fcrdns";                  then NPM_PLUGINS+=("haraka-plugin-fcrdns"); fi
if echo "${PLUGIN_LIST}" | grep -q "clamd";                   then NPM_PLUGINS+=("haraka-plugin-clamd"); fi
if echo "${PLUGIN_LIST}" | grep -q "spf";                     then NPM_PLUGINS+=("haraka-plugin-spf"); fi
if echo "${PLUGIN_LIST}" | grep -q "dkim";                    then NPM_PLUGINS+=("haraka-plugin-dkim"); fi
if echo "${PLUGIN_LIST}" | grep -q "watch";                   then NPM_PLUGINS+=("haraka-plugin-watch"); fi
if echo "${PLUGIN_LIST}" | grep -q "relay";                   then NPM_PLUGINS+=("haraka-plugin-relay"); fi
if echo "${PLUGIN_LIST}" | grep -q "bounce";                  then NPM_PLUGINS+=("haraka-plugin-bounce"); fi
if echo "${PLUGIN_LIST}" | grep -q "early_talker";            then NPM_PLUGINS+=("haraka-plugin-early_talker"); fi
if echo "${PLUGIN_LIST}" | grep -q "helo.checks";             then NPM_PLUGINS+=("haraka-plugin-helo.checks"); fi
if echo "${PLUGIN_LIST}" | grep -q "mail_from.is_resolvable"; then NPM_PLUGINS+=("haraka-plugin-mail_from.is_resolvable"); fi

msg_info "Installing npm plugins"
$STD apt-get install -y build-essential
$STD npm install -g toobusy-js
cd /usr/lib/node_modules/Haraka || exit
$STD npm install "${NPM_PLUGINS[@]}"
msg_ok "Installed npm plugins"

chown -R haraka:haraka /opt/haraka
msg_ok "Configured Haraka"

# ---------------------------------------------------------------------------
# Generate or configure TLS certificate
# ---------------------------------------------------------------------------
msg_info "Configuring TLS"
if [[ "${TLS_CERT_TYPE}" == "self-signed" ]]; then
  $STD apt-get install -y openssl
  openssl req -new -x509 -days 3650 -nodes \
    -out /opt/haraka/config/tls_cert.pem \
    -keyout /opt/haraka/config/tls_key.pem \
    -subj "/CN=$(hostname)" \
    -addext "subjectAltName=IP:$(hostname -I | awk '{print $1}')" &>/dev/null
  TLS_CERT_PATH="/opt/haraka/config/tls_cert.pem"
  TLS_KEY_PATH="/opt/haraka/config/tls_key.pem"
  chown haraka:haraka /opt/haraka/config/tls_cert.pem /opt/haraka/config/tls_key.pem
  chmod 600 /opt/haraka/config/tls_key.pem
else
  # Symlink existing certs into Haraka config dir for consistency
  ln -sf "${TLS_CERT_PATH}" /opt/haraka/config/tls_cert.pem
  ln -sf "${TLS_KEY_PATH}" /opt/haraka/config/tls_key.pem
  TLS_CERT_PATH="/opt/haraka/config/tls_cert.pem"
  TLS_KEY_PATH="/opt/haraka/config/tls_key.pem"
fi

{
  echo "[main]"
  echo "key=/opt/haraka/config/tls_key.pem"
  echo "cert=/opt/haraka/config/tls_cert.pem"
  echo "requireTLS=${TLS_REQUIRE}"
} >/opt/haraka/config/tls.ini
msg_ok "Configured TLS"

# ---------------------------------------------------------------------------
# Create systemd service
# ---------------------------------------------------------------------------
msg_info "Creating Service"
HARAKA_BIN=$(which haraka)
cat <<EOF >/etc/systemd/system/haraka.service
[Unit]
Description=Haraka SMTP Server
After=network.target

[Service]
Type=simple
User=haraka
Group=haraka
WorkingDirectory=/opt/haraka
ExecStart=${HARAKA_BIN} -c /opt/haraka
Restart=on-failure
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now haraka
msg_ok "Created Service"

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"

motd_ssh
customize
cleanup_lxc
