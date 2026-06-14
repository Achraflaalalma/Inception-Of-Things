#!/bin/bash
set -e

# ============================================================
# Configuration
# ============================================================

CLUSTER_NAME="dev-cluster"

GITHUB_REPO_URL="https://github.com/Achraflaalalma/alaalalm-iot.git"

GITLAB_PROJECT_NAME="alaalalm-iot"
GITLAB_PROJECT_PATH="alaalalm-iot"
GITLAB_TOKEN="glpat-local-token-1234567890"

GITLAB_LOCAL_URL="http://localhost:8081"
GITLAB_CLUSTER_URL="http://gitlab-webservice-default.gitlab.svc.cluster.local:8181"

ARGOCD_LOCAL_URL="https://localhost:8080"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BONUS_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================
# Helpers
# ============================================================

info() {
    echo ""
    echo "=> $1"
}

install_host_dependencies() {
    info "Installing host dependencies"

    sudo apt update
    sudo apt install -y docker.io curl git ca-certificates

    sudo systemctl enable docker
    sudo systemctl start docker
}

ensure_docker_group() {
    info "Checking Docker group"

    sudo usermod -aG docker "$USER" || true

    if ! groups | grep -q docker; then
        echo "Re-executing script with docker group..."
        exec sg docker "$0"
    fi
}

install_kubectl() {
    if command -v kubectl >/dev/null 2>&1; then
        return
    fi

    info "Installing kubectl"

    curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
}

install_k3d() {
    if command -v k3d >/dev/null 2>&1; then
        return
    fi

    info "Installing k3d"

    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
}

install_helm() {
    if command -v helm >/dev/null 2>&1; then
        return
    fi

    info "Installing Helm"

    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

create_cluster() {
    info "Creating k3d cluster"

    if ! k3d cluster list | grep -q "$CLUSTER_NAME"; then
        k3d cluster create "$CLUSTER_NAME" --servers 1 --agents 0 --no-lb
    fi

    k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-switch-context
}

create_namespaces() {
    info "Creating namespaces"

    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -
}

install_argocd() {
    info "Installing Argo CD"

    kubectl apply \
        --server-side \
        -n argocd \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    kubectl rollout status deployment/argocd-server \
        -n argocd \
        --timeout=300s
}

install_gitlab() {
    info "Installing GitLab"

    helm repo add gitlab https://charts.gitlab.io || true
    helm repo update

    helm upgrade --install gitlab gitlab/gitlab \
        --version 9.6.1 \
        -n gitlab \
        --set global.hosts.domain=gitlab.local \
        --set global.hosts.https=false \
        --set global.ingress.enabled=false \
        --set global.ingress.configureCertmanager=false \
        --set installCertmanager=false \
        --set certmanager-issuer.email=admin@example.com \
        --set nginx-ingress.enabled=false \
        --set prometheus.install=false \
        --set gitlab-runner.install=false \
        --set registry.enabled=false \
        --set gitlab.kas.enabled=false \
        --set gitlab.gitlab-pages.enabled=false \
        --set gitlab.webservice.minReplicas=1 \
        --set gitlab.webservice.maxReplicas=1 \
        --set gitlab.sidekiq.minReplicas=1 \
        --set gitlab.sidekiq.maxReplicas=1 \
        --set gitlab.gitlab-shell.minReplicas=1 \
        --set gitlab.gitlab-shell.maxReplicas=1 \
        --set minio.persistence.enabled=false \
        --set postgresql.primary.persistence.enabled=false \
        --set redis.master.persistence.enabled=false \
        --timeout 35m
}

wait_for_gitlab() {
    info "Waiting for GitLab deployments"

    kubectl rollout status deployment/gitlab-webservice-default \
        -n gitlab \
        --timeout=2400s

    kubectl rollout status deployment/gitlab-toolbox \
        -n gitlab \
        --timeout=1200s
}

start_gitlab_port_forward() {
    info "Starting GitLab port-forward"

    pkill -f "kubectl port-forward svc/gitlab-webservice-default" || true

    kubectl port-forward svc/gitlab-webservice-default \
        -n gitlab \
        8081:8181 >/tmp/gitlab-port-forward.log 2>&1 &

    sleep 10

    info "Waiting for GitLab HTTP"

    until curl -s "$GITLAB_LOCAL_URL/users/sign_in" >/dev/null 2>&1; do
        sleep 10
    done
}

get_gitlab_password() {
    GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
        -n gitlab \
        -o jsonpath="{.data.password}" | base64 -d)
}

create_gitlab_project() {
    info "Creating GitLab token and project"

    TOOLBOX_POD=$(kubectl get pod -n gitlab \
        -l app=toolbox \
        -o jsonpath="{.items[0].metadata.name}")

    kubectl exec -n gitlab "$TOOLBOX_POD" -c toolbox -- gitlab-rails runner "
user = User.find_by_username('root')

token = user.personal_access_tokens.find_by_name('local-argo-token')
token.destroy if token

token = user.personal_access_tokens.create!(
  name: 'local-argo-token',
  scopes: [:api, :read_repository, :write_repository],
  expires_at: 1.year.from_now
)

token.set_token('$GITLAB_TOKEN')
token.save!

project = Project.find_by_full_path('root/$GITLAB_PROJECT_PATH')

unless project
  project = Projects::CreateService.new(
    user,
    {
      name: '$GITLAB_PROJECT_NAME',
      path: '$GITLAB_PROJECT_PATH',
      namespace_id: user.namespace.id,
      visibility_level: Gitlab::VisibilityLevel::PUBLIC
    }
  ).execute
end

puts 'GitLab token and project are ready'
"
}

push_repo_to_gitlab() {
    info "Cloning GitHub repo and pushing it to local GitLab"

    TMP_REPO=$(mktemp -d)

    git clone "$GITHUB_REPO_URL" "$TMP_REPO"

    cd "$TMP_REPO"

    git remote remove origin || true
    git remote add origin "http://root:$GITLAB_TOKEN@localhost:8081/root/$GITLAB_PROJECT_PATH.git"

    git branch -M main
    git push -u origin main --force
}

apply_argocd_application() {
    info "Applying Argo CD Application"

    kubectl apply -f "$BONUS_DIR/confs/application.yaml"
}

start_argocd_port_forward() {
    info "Starting Argo CD port-forward"

    pkill -f "kubectl port-forward svc/argocd-server" || true

    kubectl port-forward svc/argocd-server \
        -n argocd \
        8080:443 >/tmp/argocd-port-forward.log 2>&1 &
}

get_argocd_password() {
    ARGO_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" | base64 -d)
}

print_summary() {
    cat <<EOF

=====================================
 GitLab
=====================================
URL:      $GITLAB_LOCAL_URL
Username: root
Password: $GITLAB_ROOT_PASSWORD
Project:  $GITLAB_LOCAL_URL/root/$GITLAB_PROJECT_PATH

=====================================
 Argo CD
=====================================
URL:      $ARGOCD_LOCAL_URL
Username: admin
Password: $ARGO_PASS

=====================================
 Useful checks
=====================================
kubectl get pods -n gitlab
kubectl get pods -n argocd
kubectl get pods -n dev
kubectl get application -n argocd

EOF
}

# ============================================================
# Main
# ============================================================

install_host_dependencies
ensure_docker_group

install_kubectl
install_k3d
install_helm

create_cluster
create_namespaces

install_argocd

install_gitlab
wait_for_gitlab
start_gitlab_port_forward
get_gitlab_password
create_gitlab_project
push_repo_to_gitlab

apply_argocd_application

start_argocd_port_forward
get_argocd_password

print_summary