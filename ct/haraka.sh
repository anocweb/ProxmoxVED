#!/usr/bin/env bash
# shellcheck source=/dev/null
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: cjarvis
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://haraka.github.io

APP="Haraka"
var_tags="${var_tags:-mail;smtp;relay}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/haraka ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  CURRENT=$(cat /opt/haraka_version.txt 2>/dev/null || echo "none")
  LATEST=$(curl -fsSL https://registry.npmjs.org/Haraka/latest | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")

  if [[ -z "${LATEST}" ]]; then
    msg_error "Failed to fetch latest version from npm"
    exit
  fi

  if [[ "${CURRENT}" == "${LATEST}" ]]; then
    msg_ok "${APP} is already up to date (${CURRENT})"
  else
    msg_info "Stopping ${APP}"
    systemctl stop haraka
    msg_ok "Stopped ${APP}"

    msg_info "Updating ${APP} (${CURRENT} → ${LATEST})"
    $STD npm install -g Haraka@"${LATEST}"
    echo "${LATEST}" >/opt/haraka_version.txt
    msg_ok "Updated ${APP} to ${LATEST}"

    msg_info "Starting ${APP}"
    systemctl start haraka
    msg_ok "Started ${APP}"
  fi

  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URLs:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}smtp://${IP}:2525${CL} (SMTP)"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8055${CL} (Watch UI — if monitoring was selected)"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:11334${CL} (rspamd UI — if spam filtering was selected)"
