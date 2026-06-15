#!/bin/bash
set -euo pipefail

CLUSTER_NAME="dev-cluster"
ARGOCD_NAMESPACE="argocd"
DEV_NAMESPACE="dev"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Installing dependencies..."
sudo apt update
sudo apt install -y docker.io curl ca-certificates

echo "Starting Docker..."
sudo systemctl enable docker
sudo systemctl start docker

echo "Adding user to docker group..."
sudo usermod -aG docker "$USER" || true

if ! docker ps >/dev/null 2>&1; then
    echo "Re-executing script with docker group..."
    exec sg docker "bash '$0'"
fi

echo "Installing kubectl..."
if ! command -v kubectl >/dev/null 2>&1; then
    curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
fi

echo "Installing k3d..."
if ! command -v k3d >/dev/null 2>&1; then
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

echo "Creating k3d cluster..."
if ! k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
    k3d cluster create "$CLUSTER_NAME" --servers 1 --agents 0 --no-lb
else
    echo "Cluster already exists: $CLUSTER_NAME"
fi

echo "Switching kubeconfig context..."
k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-switch-context

echo "Creating namespaces..."
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$DEV_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Argo CD..."
kubectl apply \
  --server-side \
  -n "$ARGOCD_NAMESPACE" \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for Argo CD server..."
kubectl rollout status deployment/argocd-server \
  -n "$ARGOCD_NAMESPACE" \
  --timeout=300s

echo "Applying Argo CD application..."
kubectl apply -f "$ROOT_DIR/confs/application.yaml"

echo "Starting Argo CD port-forward..."
pkill -f "kubectl port-forward svc/argocd-server" 2>/dev/null || true

kubectl port-forward \
  svc/argocd-server \
  -n "$ARGOCD_NAMESPACE" \
  8080:443 >/dev/null 2>&1 &

sleep 2

set +x
ARGO_PASS="$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"

echo ""
echo "====================================="
echo "Argo CD UI: https://localhost:8080"
echo "Username: admin"
echo "Password: $ARGO_PASS"
echo "====================================="
