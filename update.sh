#!/bin/bash

SCRIPT_VERSION="115"
SCRIPT_URL='https://raw.githubusercontent.com/wh1te909/tacticalrmm/master/update.sh'
LATEST_SETTINGS_URL='https://raw.githubusercontent.com/wh1te909/tacticalrmm/master/api/tacticalrmm/tacticalrmm/settings.py'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
THIS_SCRIPT=$(readlink -f "$0")

TMP_FILE=$(mktemp -p "" "rmmupdate_XXXXXXXXXX")
curl -s -L "${SCRIPT_URL}" > ${TMP_FILE}
NEW_VER=$(grep "^SCRIPT_VERSION" "$TMP_FILE" | awk -F'[="]' '{print $3}')

if [ "${SCRIPT_VERSION}" -ne "${NEW_VER}" ]; then
    printf >&2 "${YELLOW}Old update script detected, downloading and replacing with the latest version...${NC}\n"
    wget -q "${SCRIPT_URL}" -O update.sh
    exec ${THIS_SCRIPT}
fi

rm -f $TMP_FILE

force=false
if [[ $* == *--force* ]]; then
    force=true
fi

if [ $EUID -eq 0 ]; then
  echo -ne "\033[0;31mDo NOT run this script as root. Exiting.\e[0m\n"
  exit 1
fi

sudo apt update

strip="User="
ORIGUSER=$(grep ${strip} /etc/systemd/system/rmm.service | sed -e "s/^${strip}//")

if [ "$ORIGUSER" != "$USER" ]; then
  printf >&2 "${RED}ERROR: You must run this update script from the same user account used during install: ${GREEN}${ORIGUSER}${NC}\n"
  exit 1
fi

CHECK_TOO_OLD=$(grep natsapi /etc/nginx/sites-available/rmm.conf)
if ! [[ $CHECK_TOO_OLD ]]; then
  printf >&2 "${RED}Your version of TRMM is no longer supported. Refusing to update.${NC}\n"
  exit 1
fi

TMP_SETTINGS=$(mktemp -p "" "rmmsettings_XXXXXXXXXX")
curl -s -L "${LATEST_SETTINGS_URL}" > ${TMP_SETTINGS}
SETTINGS_FILE="/rmm/api/tacticalrmm/tacticalrmm/settings.py"

LATEST_TRMM_VER=$(grep "^TRMM_VERSION" "$TMP_SETTINGS" | awk -F'[= "]' '{print $5}')
CURRENT_TRMM_VER=$(grep "^TRMM_VERSION" "$SETTINGS_FILE" | awk -F'[= "]' '{print $5}')

if [[ "${CURRENT_TRMM_VER}" == "${LATEST_TRMM_VER}" ]] && ! [[ "$force" = true ]]; then
  printf >&2 "${GREEN}Already on latest version. Current version: ${CURRENT_TRMM_VER} Latest version: ${LATEST_TRMM_VER}${NC}\n"
  rm -f $TMP_SETTINGS
  exit 0
fi

LATEST_MESH_VER=$(grep "^MESH_VER" "$TMP_SETTINGS" | awk -F'[= "]' '{print $5}')
LATEST_PIP_VER=$(grep "^PIP_VER" "$TMP_SETTINGS" | awk -F'[= "]' '{print $5}')
LATEST_NPM_VER=$(grep "^NPM_VER" "$TMP_SETTINGS" | awk -F'[= "]' '{print $5}')

CURRENT_PIP_VER=$(grep "^PIP_VER" "$SETTINGS_FILE" | awk -F'[= "]' '{print $5}')
CURRENT_NPM_VER=$(grep "^NPM_VER" "$SETTINGS_FILE" | awk -F'[= "]' '{print $5}')

for i in nginx nats natsapi rmm celery celerybeat
do
printf >&2 "${GREEN}Stopping ${i} service...${NC}\n"
sudo systemctl stop ${i}
done

printf >&2 "${GREEN}Restarting postgresql database${NC}\n"
sudo systemctl restart postgresql
sleep 5

rm -f /rmm/api/tacticalrmm/app.ini

numprocs=$(nproc)
uwsgiprocs=4
if [[ "$numprocs" == "1" ]]; then
  uwsgiprocs=2
else
  uwsgiprocs=$numprocs
fi

uwsgini="$(cat << EOF
[uwsgi]
chdir = /rmm/api/tacticalrmm
module = tacticalrmm.wsgi
home = /rmm/api/env
master = true
processes = ${uwsgiprocs}
threads = ${uwsgiprocs}
enable-threads = true
socket = /rmm/api/tacticalrmm/tacticalrmm.sock
harakiri = 300
chmod-socket = 660
buffer-size = 65535
vacuum = true
die-on-term = true
max-requests = 500
EOF
)"
echo "${uwsgini}" > /rmm/api/tacticalrmm/app.ini


# forgot to add this in install script. catch any installs that don't have it enabled and enable it
sudo systemctl enable natsapi.service

CHECK_NGINX_WORKER_CONN=$(grep "worker_connections 2048" /etc/nginx/nginx.conf)
if ! [[ $CHECK_NGINX_WORKER_CONN ]]; then
  printf >&2 "${GREEN}Changing nginx worker connections to 2048${NC}\n"
  sudo sed -i 's/worker_connections.*/worker_connections 2048;/g' /etc/nginx/nginx.conf
fi

CHECK_HAS_GO116=$(/usr/local/rmmgo/go/bin/go version | grep go1.16)
if ! [[ $CHECK_HAS_GO116 ]]; then
  printf >&2 "${GREEN}Updating golang to version 1.16${NC}\n"
  sudo rm -rf /home/${USER}/go/
  sudo rm -rf /usr/local/rmmgo/
  sudo mkdir -p /usr/local/rmmgo
  go_tmp=$(mktemp -d -t rmmgo-XXXXXXXXXX)
  wget https://golang.org/dl/go1.16.linux-amd64.tar.gz -P ${go_tmp}
  tar -xzf ${go_tmp}/go1.16.linux-amd64.tar.gz -C ${go_tmp}
  sudo mv ${go_tmp}/go /usr/local/rmmgo/
  rm -rf ${go_tmp}
  sudo chown -R $USER:$GROUP /home/${USER}/.cache
fi

HAS_PY39=$(which python3.9)
if ! [[ $HAS_PY39 ]]; then
  printf >&2 "${GREEN}Updating to Python 3.9${NC}\n"
  sudo apt install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev libbz2-dev
  numprocs=$(nproc)
  cd ~
  wget https://www.python.org/ftp/python/3.9.2/Python-3.9.2.tgz
  tar -xf Python-3.9.2.tgz
  cd Python-3.9.2
  ./configure --enable-optimizations
  make -j $numprocs
  sudo make altinstall
  cd ~
  sudo rm -rf Python-3.9.2 Python-3.9.2.tgz
fi

HAS_NATS220=$(/usr/local/bin/nats-server -version | grep v2.2.0)
if ! [[ $HAS_NATS220 ]]; then
  printf >&2 "${GREEN}Updating nats to v2.2.0${NC}\n"
  nats_tmp=$(mktemp -d -t nats-XXXXXXXXXX)
  wget https://github.com/nats-io/nats-server/releases/download/v2.2.0/nats-server-v2.2.0-linux-amd64.tar.gz -P ${nats_tmp}
  tar -xzf ${nats_tmp}/nats-server-v2.2.0-linux-amd64.tar.gz -C ${nats_tmp}
  sudo rm -f /usr/local/bin/nats-server
  sudo mv ${nats_tmp}/nats-server-v2.2.0-linux-amd64/nats-server /usr/local/bin/
  sudo chmod +x /usr/local/bin/nats-server
  sudo chown ${USER}:${USER} /usr/local/bin/nats-server
  rm -rf ${nats_tmp}
fi

sudo npm install -g npm

cd /rmm
git config user.email "admin@example.com"
git config user.name "Bob"
git fetch
git checkout master
git reset --hard FETCH_HEAD
git clean -df
git pull


sudo chown ${USER}:${USER} -R /rmm
sudo chown ${USER}:${USER} /var/log/celery
sudo chown ${USER}:${USER} -R /etc/conf.d/
sudo chown -R $USER:$GROUP /home/${USER}/.npm
sudo chown -R $USER:$GROUP /home/${USER}/.config
sudo chown -R $USER:$GROUP /home/${USER}/.cache
sudo chown ${USER}:${USER} -R /etc/letsencrypt
sudo chmod 775 -R /etc/letsencrypt

CHECK_ADMIN_ENABLED=$(grep ADMIN_ENABLED /rmm/api/tacticalrmm/tacticalrmm/local_settings.py)
if ! [[ $CHECK_ADMIN_ENABLED ]]; then
adminenabled="$(cat << EOF
ADMIN_ENABLED = False
EOF
)"
echo "${adminenabled}" | tee --append /rmm/api/tacticalrmm/tacticalrmm/local_settings.py > /dev/null
fi

/usr/local/rmmgo/go/bin/go get github.com/josephspurrier/goversioninfo/cmd/goversioninfo
sudo cp /rmm/api/tacticalrmm/core/goinstaller/bin/goversioninfo /usr/local/bin/
sudo chown ${USER}:${USER} /usr/local/bin/goversioninfo
sudo chmod +x /usr/local/bin/goversioninfo

sudo cp /rmm/natsapi/bin/nats-api /usr/local/bin
sudo chown ${USER}:${USER} /usr/local/bin/nats-api
sudo chmod +x /usr/local/bin/nats-api

if [[ "${CURRENT_PIP_VER}" != "${LATEST_PIP_VER}" ]] || [[ "$force" = true ]]; then
  rm -rf /rmm/api/env
  cd /rmm/api
  python3.9 -m venv env
  source /rmm/api/env/bin/activate
  cd /rmm/api/tacticalrmm
  pip install --no-cache-dir --upgrade pip
  pip install --no-cache-dir setuptools==53.0.0 wheel==0.36.2
  pip install --no-cache-dir -r requirements.txt
else
  source /rmm/api/env/bin/activate
  cd /rmm/api/tacticalrmm
  pip install -r requirements.txt
fi

python manage.py pre_update_tasks
python manage.py migrate
python manage.py delete_tokens
python manage.py collectstatic --no-input
python manage.py reload_nats
python manage.py load_chocos
python manage.py post_update_tasks
deactivate

rm -rf /rmm/web/dist
rm -rf /rmm/web/.quasar
cd /rmm/web
if [[ "${CURRENT_NPM_VER}" != "${LATEST_NPM_VER}" ]] || [[ "$force" = true ]]; then
  rm -rf /rmm/web/node_modules
fi

npm install
npm run build
sudo rm -rf /var/www/rmm/dist
sudo cp -pr /rmm/web/dist /var/www/rmm/
sudo chown www-data:www-data -R /var/www/rmm/dist

for i in rmm celery celerybeat nginx nats natsapi
do
printf >&2 "${GREEN}Starting ${i} service${NC}\n"
sudo systemctl start ${i}
done

CURRENT_MESH_VER=$(cd /meshcentral/node_modules/meshcentral && node -p -e "require('./package.json').version")
if [[ "${CURRENT_MESH_VER}" != "${LATEST_MESH_VER}" ]] || [[ "$force" = true ]]; then
  printf >&2 "${GREEN}Updating meshcentral from ${CURRENT_MESH_VER} to ${LATEST_MESH_VER}${NC}\n"
  sudo systemctl stop meshcentral
  sudo chown ${USER}:${USER} -R /meshcentral
  cd /meshcentral
  rm -rf node_modules/
  npm install meshcentral@${LATEST_MESH_VER}
  sudo systemctl start meshcentral
fi

rm -f $TMP_SETTINGS
printf >&2 "${GREEN}Update finished!${NC}\n"