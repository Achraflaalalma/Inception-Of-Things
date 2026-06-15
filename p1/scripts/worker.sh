#!/bin/bash
set -e

apt-get update
apt-get install -y curl

until [ -s /vagrant/token ]; do
    sleep 2
done

until timeout 2 bash -c "cat < /dev/null > /dev/tcp/192.168.56.110/6443" 2>/dev/null; do
    sleep 2
done

TOKEN=$(cat /vagrant/token)

curl -sfL https://get.k3s.io | \
K3S_URL="https://192.168.56.110:6443" \
K3S_TOKEN="$TOKEN" \
INSTALL_K3S_EXEC="agent --node-ip=192.168.56.111" \
sh -
