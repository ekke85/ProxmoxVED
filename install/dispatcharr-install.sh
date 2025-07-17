#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: ekke85
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Dispatcharr/Dispatcharr

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os


APPLICATION="Dispatcharr"
APP_USER="dispatcharr"
APP_GROUP="dispatcharr"
APP_DIR="/opt/dispatcharr"
DISPATCH_BRANCH="main"
GUNICORN_RUNTIME_DIR="dispatcharr"
GUNICORN_SOCKET="/run/${GUNICORN_RUNTIME_DIR}/dispatcharr.sock"
NGINX_HTTP_PORT="9191"
WEBSOCKET_PORT="8001"
POSTGRES_DB="dispatcharr"
POSTGRES_USER="dispatch"
POSTGRES_PASSWORD="secret"

msg_info "Creating ${APP_USER} user"
groupadd -f $APP_GROUP
useradd -M -s /usr/sbin/nologin -g $APP_GROUP $APP_USER || true
msg_ok "Created ${APP_USER} user"

msg_info "Installing Dependencies"
$STD apt-get install -y \
  git \
  curl \
  wget \
  build-essential \
  gcc \
  libpcre3-dev \
  libpq-dev \
  python3-dev \
  python3-venv \
  python3-pip \
  nginx \
  redis-server \
  ffmpeg \
  procps \
  streamlink
msg_ok "Installed Dependencies"

setup_uv
NODE_VERSION="22" setup_nodejs
PG_VERSION="16" setup_postgresql

msg_info "Configuring PostgreSQL"

su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'\"" | grep -q 1 || \
  su - postgres -c "psql -c \"CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';\""

su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'\"" | grep -q 1 || \
  su - postgres -c "psql -c \"CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};\""

su - postgres -c "psql -d ${POSTGRES_DB} -c \"ALTER SCHEMA public OWNER TO ${POSTGRES_USER};\""

msg_ok "Configured PostgreSQL"

msg_info "Fetching latest Dispatcharr release version"
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/Dispatcharr/Dispatcharr/releases/latest | grep '"tag_name":' | cut -d '"' -f4)

if [[ -z "$LATEST_VERSION" ]]; then
  msg_error "Failed to fetch latest release version from GitHub."
  exit 1
fi

msg_info "Downloading Dispatcharr $LATEST_VERSION"
TARBALL_URL="https://github.com/Dispatcharr/Dispatcharr/archive/refs/tags/${LATEST_VERSION}.tar.gz"

mkdir -p "$APP_DIR"
curl -fsSL "$TARBALL_URL" | tar -xz --strip-components=1 -C "$APP_DIR"
chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
sed -i 's/program\[\x27channel_id\x27\]/program["channel_id"]/g' "${APP_DIR}/apps/output/views.py"

msg_ok "Downloaded Dispatcharr $LATEST_VERSION"

msg_info "Creating Python Virtual Environment"
cd $APP_DIR
python3 -m venv env
source env/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
pip install gunicorn
ln -sf /usr/bin/ffmpeg $APP_DIR/env/bin/ffmpeg
msg_ok "Python Environment Setup"

msg_info "Building Frontend"
cd $APP_DIR/frontend
npm install --legacy-peer-deps
npm run build
msg_ok "Built Frontend"

msg_info "Running Django Migrations"
cd $APP_DIR
source env/bin/activate
export POSTGRES_DB
export POSTGRES_USER
export POSTGRES_PASSWORD
export POSTGRES_HOST="localhost"
python manage.py migrate --noinput
python manage.py collectstatic --noinput
msg_ok "Migrations Complete"

msg_info "Configuring Nginx"
cat <<EOF >/etc/nginx/sites-available/dispatcharr.conf
server {
    listen $NGINX_HTTP_PORT;

    location / {
        include proxy_params;
        proxy_pass http://unix:$GUNICORN_SOCKET;
    }

    location /static/ {
        alias $APP_DIR/static/;
    }

    location /assets/ {
        alias $APP_DIR/frontend/dist/assets/;
    }

    location /media/ {
        alias $APP_DIR/media/;
    }

    location /ws/ {
        proxy_pass http://127.0.0.1:$WEBSOCKET_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/dispatcharr.conf /etc/nginx/sites-enabled/dispatcharr.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
systemctl enable nginx
msg_ok "Configured Nginx"

msg_info "Creating systemd services"

cat <<EOF >/etc/systemd/system/dispatcharr.service
[Unit]
Description=Gunicorn for Dispatcharr
After=network.target postgresql.service redis-server.service

[Service]
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
RuntimeDirectory=$GUNICORN_RUNTIME_DIR
RuntimeDirectoryMode=0775
Environment="PATH=$APP_DIR/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
Environment="POSTGRES_DB=$POSTGRES_DB"
Environment="POSTGRES_USER=$POSTGRES_USER"
Environment="POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
Environment="POSTGRES_HOST=localhost"
ExecStart=$APP_DIR/env/bin/gunicorn \\
    --workers=4 \\
    --worker-class=gevent \\
    --timeout=300 \\
    --bind unix:$GUNICORN_SOCKET \\
    dispatcharr.wsgi:application
Restart=always
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/dispatcharr-celery.service
[Unit]
Description=Celery Worker for Dispatcharr
After=network.target redis-server.service
Requires=dispatcharr.service

[Service]
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/env/bin"
Environment="POSTGRES_DB=$POSTGRES_DB"
Environment="POSTGRES_USER=$POSTGRES_USER"
Environment="POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
Environment="POSTGRES_HOST=localhost"
Environment="CELERY_BROKER_URL=redis://localhost:6379/0"
ExecStart=$APP_DIR/env/bin/celery -A dispatcharr worker -l info
Restart=always
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/dispatcharr-celerybeat.service
[Unit]
Description=Celery Beat Scheduler for Dispatcharr
After=network.target redis-server.service
Requires=dispatcharr.service

[Service]
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/env/bin"
Environment="POSTGRES_DB=$POSTGRES_DB"
Environment="POSTGRES_USER=$POSTGRES_USER"
Environment="POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
Environment="POSTGRES_HOST=localhost"
Environment="CELERY_BROKER_URL=redis://localhost:6379/0"
ExecStart=$APP_DIR/env/bin/celery -A dispatcharr beat -l info
Restart=always
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/dispatcharr-daphne.service
[Unit]
Description=Daphne for Dispatcharr (ASGI)
After=network.target
Requires=dispatcharr.service

[Service]
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/env/bin"
Environment="POSTGRES_DB=$POSTGRES_DB"
Environment="POSTGRES_USER=$POSTGRES_USER"
Environment="POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
Environment="POSTGRES_HOST=localhost"
ExecStart=$APP_DIR/env/bin/daphne -b 0.0.0.0 -p $WEBSOCKET_PORT dispatcharr.asgi:application
Restart=always
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

msg_ok "Created systemd services"


msg_info "Starting Dispatcharr Services"
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne
systemctl restart dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne
msg_ok "Started Dispatcharr Services"


motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"