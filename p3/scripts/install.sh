#!/bin/bash
set -ex

sudo apt update
sudo apt install -y docker.io curl

sudo systemctl enable docker
sudo systemctl start docker

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# ensure docker group exists and user is inside it
sudo usermod -aG docker $USER || true

# IMPORTANT: re-run script in docker group context
if ! groups | grep -q docker; then
    echo "Re-executing script with docker group..."

    exec sg docker "$0"
fi

# -----------------------------
# From here: docker works
# -----------------------------

k3d cluster create dev-cluster --servers 1 --agents 0 --no-lb

k3d kubeconfig merge dev-cluster --kubeconfig-switch-context

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

kubectl apply \
  --server-side \
  -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl rollout status deployment/argocd-server \
  -n argocd --timeout=300s

kubectl apply -f "$ROOT_DIR/confs/application.yaml"

echo "Starting Argo CD UI at https://localhost:8080"

kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &

ARGO_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "====================================="
echo "Argo CD UI: https://localhost:8080"
echo "Username: admin"
echo "Password: $ARGO_PASS"
echo "====================================="