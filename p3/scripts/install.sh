#!/bin/bash

set -e

sudo apt update
sudo apt install -y docker.io curl

sudo systemctl enable docker
sudo systemctl start docker

# Install kubectl and k3d
curl -LO "https://dl.k8s.io/release/$(curl -L -s \
https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

chmod +x kubectl
sudo mv kubectl /usr/local/bin/

curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash