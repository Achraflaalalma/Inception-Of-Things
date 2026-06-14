#!/bin/bash

apt-get update
apt-get install -y curl

while [ ! -f /vagrant/token ]
do
    sleep 2
done

TOKEN=$(cat /vagrant/token)

curl -sfL https://get.k3s.io | \
K3S_URL="https://192.168.56.110:6443" \
K3S_TOKEN="$TOKEN" \
sh -