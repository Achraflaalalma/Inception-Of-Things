#!/bin/bash

apt-get update
apt-get install -y curl

curl -sfL https://get.k3s.io | sh -

while [ ! -f /var/lib/rancher/k3s/server/node-token ]
do
    sleep 2
done

cp /var/lib/rancher/k3s/server/node-token /vagrant/token
chmod 644 /vagrant/token