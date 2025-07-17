#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: ekke85
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Dispatcharr/Dispatcharr

# Import Functions und Setup
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Installing Dependencies
msg_info "Installing Dependencies"
$STD apt-get update
$STD apt-get install -y \
  docker \
  docker-compose 
msg_ok "Installed Dependencies"

# Setup App
msg_info "Setup ${APPLICATION}"
RELEASE=$(curl -fsSL https://api.github.com/repos/Dispatcharr/Dispatcharr/releases/latest | awk '{print substr($2, 2, length($2)-3) }')
cd /opt
curl -fsSL "https://raw.githubusercontent.com/Dispatcharr/Dispatcharr/refs/heads/main/docker/docker-compose.aio.yml" -o compose.yml
sed -i 's|dispatcharr_data:/data|/opt/dispatcharr_data:/data|' compose.yml
sed -i '/^volumes:/,+1d' compose.yml
msg_ok "Setup ${APPLICATION}"

# Creating Service (if needed)
msg_info "Creating Service"
$STD docker-compose up -d
for i in {1..60}; do
  CONTAINER_ID=$(docker ps --filter "name=dispatcharr" --format "{{.ID}}")
  if [[ -n "$CONTAINER_ID" ]]; then
    STATUS=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_ID" 2>/dev/null || echo "starting")
    if [[ "$STATUS" == "running" ]]; then
      msg_ok "Dispatcharr is running and healthy"
      break
    elif [[ "$STATUS" == "unhealthy" ]]; then
      msg_error "Dispatcharr container is unhealthy! Check logs."
      docker logs "$CONTAINER_ID"
      exit 1
    fi
  fi
  sleep 2
  [[ $i -eq 60 ]] && msg_error "Dispatcharr container did not become healthy within 120s." && docker logs "$CONTAINER_ID" && exit 1
done
version_line=$(docker logs "$CONTAINER_ID" | grep -i 'version' | head -n 1)
if [[ $version_line ]]; then
    echo "$version_line" | awk '{print $4}' > "/opt/${APPLICATION}_version.txt"
fi

msg_ok "Created Service"

motd_ssh
customize

# Cleanup
msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"