#!/bin/bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VAGRANT_PROJECTS=("p1" "p2")
K3D_CLUSTERS=("dev-cluster" "bonus-cluster")

info() {
    echo ""
    echo "=> $1"
}

# ------------------------------------------------------------
# Stop port-forwards
# ------------------------------------------------------------

clean_port_forwards() {
    info "Stopping project port-forwards"

    for pid_file in \
        /tmp/bonus-gitlab-port-forward.pid \
        /tmp/bonus-argocd-port-forward.pid \
        /tmp/p3-argocd-port-forward.pid
    do
        if [ -f "$pid_file" ]; then
            kill "$(cat "$pid_file")" 2>/dev/null || true
            rm -f "$pid_file"
        fi
    done

    pkill -f "kubectl port-forward svc/argocd-server" 2>/dev/null || true
    pkill -f "kubectl port-forward svc/gitlab-webservice-default" 2>/dev/null || true

    rm -f /tmp/bonus-gitlab-port-forward.log
    rm -f /tmp/bonus-argocd-port-forward.log
    rm -f /tmp/p3-argocd-port-forward.log
}

# ------------------------------------------------------------
# Clean p1 / p2 Vagrant state
# ------------------------------------------------------------

clean_vagrant_projects() {
    info "Cleaning Vagrant projects"

    for project in "${VAGRANT_PROJECTS[@]}"; do
        project_dir="$ROOT_DIR/$project"

        if [ -d "$project_dir" ]; then
            echo "Cleaning $project..."

            cd "$project_dir" || continue

            vagrant destroy -f 2>/dev/null || true

            rm -rf .vagrant
            rm -f token
        fi
    done

    cd "$ROOT_DIR" || exit 1

    vagrant global-status --prune >/dev/null 2>&1 || true
}

# ------------------------------------------------------------
# Force-clean stale libvirt domains for p1 / p2
# ------------------------------------------------------------

clean_libvirt_domains() {
    info "Cleaning stale libvirt domains"

    if ! command -v virsh >/dev/null 2>&1; then
        echo "virsh not found, skipping libvirt cleanup"
        return
    fi

    mapfile -t domains < <(
        sudo virsh -c qemu:///system list --all --name 2>/dev/null | \
        grep -E "^(p1|p2)_" || true
    )

    if [ "${#domains[@]}" -eq 0 ]; then
        echo "No p1/p2 libvirt domains found"
        return
    fi

    for domain in "${domains[@]}"; do
        echo "Removing libvirt domain: $domain"

        sudo virsh -c qemu:///system destroy "$domain" 2>/dev/null || true
        sudo virsh -c qemu:///system undefine "$domain" --remove-all-storage 2>/dev/null || true
    done
}

# ------------------------------------------------------------
# Clean k3d clusters for p3 / bonus
# ------------------------------------------------------------

clean_k3d_clusters() {
    info "Cleaning k3d clusters"

    if ! command -v k3d >/dev/null 2>&1; then
        echo "k3d not found, skipping k3d cleanup"
        return
    fi

    for cluster in "${K3D_CLUSTERS[@]}"; do
        if k3d cluster list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx "$cluster"; then
            echo "Deleting k3d cluster: $cluster"
            k3d cluster delete "$cluster" || true
        else
            echo "Cluster not found: $cluster"
        fi
    done
}

# ------------------------------------------------------------
# Clean stale Docker leftovers from k3d
# ------------------------------------------------------------

clean_docker_leftovers() {
    info "Cleaning stale Docker leftovers"

    if ! command -v docker >/dev/null 2>&1; then
        echo "docker not found, skipping Docker cleanup"
        return
    fi

    if ! docker ps >/dev/null 2>&1; then
        echo "Docker not accessible, skipping Docker cleanup"
        return
    fi

    for cluster in "${K3D_CLUSTERS[@]}"; do
        echo "Removing stale Docker containers for: $cluster"

        docker ps -a --format '{{.Names}}' | \
            grep -E "^k3d-${cluster}" | \
            xargs -r docker rm -f 2>/dev/null || true

        docker network rm "k3d-${cluster}" 2>/dev/null || true
        docker volume ls --format '{{.Name}}' | \
            grep -E "k3d-${cluster}" | \
            xargs -r docker volume rm 2>/dev/null || true
    done
}

# ------------------------------------------------------------
# Clean local generated files
# ------------------------------------------------------------

clean_generated_files() {
    info "Cleaning generated local files"

    rm -f "$ROOT_DIR/p1/token"
    rm -f "$ROOT_DIR/p2/token"

    rm -rf "$ROOT_DIR/p1/.vagrant"
    rm -rf "$ROOT_DIR/p2/.vagrant"

    find "$ROOT_DIR" -name ".DS_Store" -delete 2>/dev/null || true
}

# ------------------------------------------------------------
# Final status
# ------------------------------------------------------------

print_status() {
    info "Final status"

    echo ""
    echo "Vagrant:"
    vagrant global-status --prune 2>/dev/null || true

    echo ""
    echo "libvirt p1/p2 domains:"
    sudo virsh -c qemu:///system list --all --name 2>/dev/null | \
        grep -E "^(p1|p2)_" || echo "No p1/p2 libvirt domains"

    echo ""
    echo "k3d clusters:"
    if command -v k3d >/dev/null 2>&1; then
        k3d cluster list 2>/dev/null || true
    else
        echo "k3d not installed"
    fi

    echo ""
    echo "Clean finished."
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

echo "This will clean generated resources for p1, p2, p3, and bonus."
echo "Project source files will NOT be deleted."
echo ""

clean_port_forwards
clean_vagrant_projects
clean_libvirt_domains
clean_k3d_clusters
clean_docker_leftovers
clean_generated_files
print_status
