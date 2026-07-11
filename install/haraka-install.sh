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
if ! PURPOSES=$(whiptail --title "Haraka Setup — Step 1 of 4" \
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
build_item() {
  local name="$1"
  local desc="$2"
  local state="OFF"
  echo "${PLUGIN_SELECTED}" | grep -qw "${name}" && state="ON"
  echo "$name" "$desc" "$state"
}

# shellcheck disable=SC2046
if ! PLUGIN_LIST=$(whiptail --title "Haraka Setup — Step 2 of 4" \
  --checklist "Review and adjust plugins. Pre-checked items come from your selected presets." 30 78 20 \
  $(build_item "tls"                     "TLS/STARTTLS support (recommended)") \
  $(build_item "spf"                     "SPF validation") \
  $(build_item "dkim"                    "DKIM sign and verify") \
  $(build_item "fcrdns"                  "Forward-confirmed reverse DNS checks") \
  $(build_item "helo.checks"             "HELO/EHLO validity checks") \
  $(build_item "mail_from.is_resolvable" "Verify sender domain has MX record") \
  $(build_item "bounce"                  "Bounce processing") \
  $(build_item "rcpt_to.in_host_list"    "Define local recipient domains") \
  $(build_item "relay"                   "Manage relay permissions") \
  $(build_item "auth/flat_file"          "SMTP AUTH against a flat file") \
  $(build_item "rspamd"                  "Spam scanning via rspamd") \
  $(build_item "greylist"                "Greylisting") \
  $(build_item "karma"                   "Dynamic connection scoring") \
  $(build_item "dns-list"                "DNS blacklist/whitelist checks") \
  $(build_item "uribl"                   "URI blacklist checks") \
  $(build_item "delay_deny"              "Delay deny responses to waste spammer time") \
  $(build_item "tarpit"                  "Slow down suspicious connections") \
  $(build_item "early_talker"            "Reject clients that talk before banner") \
  $(build_item "toobusy"                 "Defer connections when server is under load") \
  $(build_item "clamd"                   "Antivirus scanning via ClamAV") \
  $(build_item "watch"                   "Live SMTP traffic web UI (port 8055)") \
  $(build_item "process_title"           "Show activity counters in ps output") \
  $(build_item "syslog"                  "Log to syslog") \
  3>&1 1>&2 2>&3); then
  msg_error "Installation cancelled."
  exit 1
fi

# ---------------------------------------------------------------------------
# SCREEN 3: Queue plugin (required)
# ---------------------------------------------------------------------------
if ! QUEUE=$(whiptail --title "Haraka Setup — Step 3 of 4" \
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
# SCREEN 4 (conditional): rspamd install notice
# ---------------------------------------------------------------------------
INSTALL_RSPAMD=false
if echo "${PLUGIN_LIST}" | grep -q "rspamd"; then
  whiptail --title "rspamd Setup" --msgbox \
    "rspamd will be installed and configured on this container.\n\nHaraka will connect to rspamd on localhost:11333.\nThe rspamd web UI will be available on port 11334.\n\nThis may take a few minutes." \
    12 65
  INSTALL_RSPAMD=true
fi

# ---------------------------------------------------------------------------
# SCREEN 5 (conditional): ClamAV install notice
# ---------------------------------------------------------------------------
INSTALL_CLAMD=false
if echo "${PLUGIN_LIST}" | grep -q "clamd"; then
  whiptail --title "ClamAV Setup" --msgbox \
    "ClamAV will be installed and configured on this container.\n\nNote: ClamAV requires ~500MB RAM. Ensure the container has sufficient memory.\n\nfreshclam will run to download the initial virus definitions — this may take several minutes." \
    12 65
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
  MANUAL_CONFIG_ITEMS+="  • dkim        → run: haraka-dkim-gen (key generation required)\n"
fi
if echo "${PLUGIN_LIST}" | grep -q "tls"; then
  MANUAL_CONFIG_ITEMS+="  • tls         → /opt/haraka/config/tls.ini (cert/key paths)\n"
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

if echo "${PLUGIN_LIST}" | grep -q "watch"; then
  {
    echo "[main]"
    echo "port=8055"
    echo "bind=0.0.0.0"
  } >/opt/haraka/config/watch.ini
fi

# Install npm-packaged plugins that were selected
NPM_PLUGINS=()
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
if [[ "${QUEUE}" == "smtp_forward" ]];                        then NPM_PLUGINS+=("haraka-plugin-queue-smtp-forward"); fi
if [[ "${QUEUE}" == "rabbitmq" ]];                            then NPM_PLUGINS+=("haraka-plugin-queue-rabbitmq"); fi

if [[ ${#NPM_PLUGINS[@]} -gt 0 ]]; then
  msg_info "Installing npm plugins"
  cd /opt/haraka || exit
  $STD npm install "${NPM_PLUGINS[@]}"
  msg_ok "Installed npm plugins"
fi

chown -R haraka:haraka /opt/haraka
msg_ok "Configured Haraka"

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
