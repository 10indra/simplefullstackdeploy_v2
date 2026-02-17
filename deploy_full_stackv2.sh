#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# GLOBAL CONFIG
########################################
DOMAINS=("app1.local" "app2.local" "app3.local")
BASE_DIR="/opt/webapps"
START_PORT=8443
LOG="/var/log/full_deploy.log"
USER_NAME="${SUDO_USER:-$(whoami)}"

exec > >(tee -a "$LOG") 2>&1

########################################
# COLORS
########################################
g(){ echo -e "\e[32m$1\e[0m"; }
y(){ echo -e "\e[33m$1\e[0m"; }
r(){ echo -e "\e[31m$1\e[0m"; }

step(){ g "▶ $1"; }
fail(){ r "[ERROR] $1"; exit 1; }

trap 'fail "FAILED line $LINENO"' ERR
[[ $EUID -ne 0 ]] && fail "Run as root"

########################################
# RETRY
########################################
retry(){
for i in {1..5}; do
 "$@" && return
 y "Retry $i..."
 sleep 2
done
return 1
}

########################################
# INSTALL DOCKER
########################################
install_docker(){
if command -v docker >/dev/null; then
 step "Docker already installed"
 return
fi

step "Installing Docker"
apt update -y
apt install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
| gpg --dearmor -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
> /etc/apt/sources.list.d/docker.list

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl restart docker
usermod -aG docker "$USER_NAME" || true
}

########################################
# HARDENING
########################################
harden(){
step "System hardening"

apt install -y ufw fail2ban jq htop net-tools sysstat

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable

systemctl enable fail2ban
systemctl start fail2ban

cat > /etc/docker/daemon.json <<EOF
{
 "log-driver": "json-file",
 "log-opts": {
  "max-size": "50m",
  "max-file": "3"
 }
}
EOF

systemctl restart docker
}

########################################
# CHECK DOCKER
########################################
check_docker(){
step "Validating docker"
retry docker info >/dev/null || fail "Docker failed"
docker compose version >/dev/null || fail "Compose missing"
}

########################################
# FIX PERMISSION
########################################
fix_perm(){
APP=$1
chown -R 33:33 "$APP"
chmod -R 775 "$APP/storage"
chmod -R 775 "$APP/bootstrap/cache"
}

########################################
# DEPLOY APP STACK (CORE ORIGINAL)
########################################
deploy_app(){

NAME=$1
PORT=$2
PROJ=$(echo "$NAME" | tr . _)

step "Deploy $NAME → $PORT"

mkdir -p "$BASE_DIR/$NAME"
cd "$BASE_DIR/$NAME"

#################################
# COMPOSE (UNCHANGED CORE)
#################################
cat > docker-compose.yml <<EOF
services:

 php:
  image: php:8.4-fpm
  container_name: ${PROJ}_php
  user: "33:33"
  working_dir: /var/www/html
  volumes:
   - ./app:/var/www/html
  command: sh -c "chmod -R 775 storage bootstrap/cache || true && php-fpm"
  restart: unless-stopped

 nginx:
  image: nginx:alpine
  container_name: ${PROJ}_nginx
  volumes:
   - ./app:/var/www/html
   - ./nginx.conf:/etc/nginx/nginx.conf
  restart: unless-stopped

 db:
  image: mysql:8
  container_name: ${PROJ}_db
  environment:
   MYSQL_ROOT_PASSWORD: strongpass
   MYSQL_DATABASE: laravel
  volumes:
   - dbdata:/var/lib/mysql
  restart: unless-stopped

volumes:
 dbdata:
EOF

#################################
# APP NGINX (UNCHANGED)
#################################
cat > nginx.conf <<EOF
events {}
http {
 server {
  listen 80;
  root /var/www/html/public;
  index index.php;

  location / {
   try_files \$uri \$uri/ /index.php?\$query_string;
  }

  location ~ \.php$ {
   include fastcgi_params;
   fastcgi_pass php:9000;
   fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
  }
 }
}
EOF

#################################
# LARAVEL INSTALL
#################################
if [ ! -d app ]; then
 step "Installing Laravel $NAME"
 retry docker run --rm -v "$(pwd)":/app composer create-project laravel/laravel app
 fix_perm app

 echo "<?php echo 'Welcome to $NAME'; ?>" > app/public/index.php
fi

fix_perm app

step "Starting containers"
docker compose -p "$PROJ" up -d

g "✔ $NAME running"
cd ..
}

########################################
# REVERSE PROXY (PATCHED ONLY HERE)
########################################
deploy_gateway(){

step "Deploy central reverse proxy"

mkdir -p "$BASE_DIR/gateway"
cd "$BASE_DIR/gateway"

cat > nginx.conf <<EOF
events {}
http {

 resolver 127.0.0.11 valid=10s ipv6=off;

$(for d in "${DOMAINS[@]}"; do
u=$(echo "$d" | tr . _)_nginx
cat <<BLOCK
 server {
  listen 443 ssl;
  server_name $d;

  ssl_certificate /certs/cert.pem;
  ssl_certificate_key /certs/key.pem;

  location / {
   set \$upstream http://$u;
   proxy_pass \$upstream;
   proxy_set_header Host \$host;
   proxy_set_header X-Real-IP \$remote_addr;
  }
 }
BLOCK
done)

}
EOF

mkdir -p certs
openssl req -x509 -nodes -days 365 \
-newkey rsa:2048 \
-keyout certs/key.pem \
-out certs/cert.pem \
-subj "/CN=local" >/dev/null 2>&1

cat > docker-compose.yml <<EOF
services:
 gateway:
  image: nginx:alpine
  container_name: central_gateway
  ports:
   - "443:443"
  volumes:
   - ./nginx.conf:/etc/nginx/nginx.conf
   - ./certs:/certs
  networks:
$(for d in "${DOMAINS[@]}"; do
echo "   - ${d//./_}_default"
done)

networks:
$(for d in "${DOMAINS[@]}"; do
echo " ${d//./_}_default:
  external: true"
done)
EOF

docker compose up -d
g "✔ Gateway ready"
}

########################################
# MAIN
########################################
install_docker
harden
check_docker

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

PORT=$START_PORT
for d in "${DOMAINS[@]}"; do
 deploy_app "$d" "$PORT"
 PORT=$((PORT+1))
done

deploy_gateway

g "======================================"
g " ALL APPS + GATEWAY SUCCESS"
g "======================================"