#!/bin/bash
set -e

apt-get update
apt-get install -y curl

curl -sfL https://get.k3s.io | \
INSTALL_K3S_EXEC="server \
  --node-ip=192.168.56.110 \
  --advertise-address=192.168.56.110 \
  --tls-san=192.168.56.110 \
  --write-kubeconfig-mode=644" \
sh -

until [ -f /var/lib/rancher/k3s/server/node-token ]; do
    sleep 2
done

until kubectl get node >/dev/null 2>&1; do
    sleep 2
done

cp /var/lib/rancher/k3s/server/node-token /vagrant/token
chmod 644 /vagrant/token

echo "K3s server is ready"
