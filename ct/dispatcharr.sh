#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/ekke85/ProxmoxVED/refs/heads/dispatcharr/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: ekke85
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Dispatcharr/Dispatcharr

APP="Dispatcharr"
var_tags="${var_tags:-media;arr}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  # Check if installation is present | -f for file, -d for folder
  if [[ ! -d "/opt/dispatcharr_data" ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  # Crawling the new version and checking whether an update is required
  RELEASE=$(curl -fsSL https://api.github.com/repos/Dispatcharr/Dispatcharr/releases/latest | awk '{print substr($2, 2, length($2)-3) }')
  if [[ "${RELEASE}" != "$(cat /opt/${APP}_version.txt)" ]] || [[ ! -f /opt/${APP}_version.txt ]]; then
    # Stopping Services
    msg_info "Stopping $APP"

    msg_ok "Stopped $APP"

    # Creating Backup
    msg_info "Creating Backup"
    # BACKUP_FILE="/opt/dispatcharr_backup_$(date +%F).tar.gz"
    # $STD tar -czf "$BACKUP_FILE" /opt/dispatcharr_data &>/dev/null
    msg_ok "Backup Created"

    # Execute Update
    msg_info "Updating $APP to v${RELEASE}"

    msg_ok "Updated $APP to v${RELEASE}"

    # Starting Services
    msg_info "Starting $APP"

    msg_ok "Started $APP"

    # Cleaning up
    msg_info "Cleaning Up"
    #rm -rf [TEMP_FILES]
    msg_ok "Cleanup Completed"

    # Last Action


    msg_ok "Update Successful"
  else
    msg_ok "No update required. ${APP} is already at v${RELEASE}"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:9191${CL}"