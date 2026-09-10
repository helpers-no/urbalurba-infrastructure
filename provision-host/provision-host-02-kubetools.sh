#!/bin/bash
# filename: provision-host-02-kubetools.sh
# description: Installs Kubernetes-related software on the provision host using snap where possible.

# Run systemctl daemon-reload to address unit file changes (ignore if not available in container)
sudo systemctl daemon-reload 2>/dev/null || true

# Initialize associative arrays for status and errors
declare -A STATUS
declare -A ERRORS

# Global variable for architecture
ARCHITECTURE=$(uname -m)

# Function to add status
add_status() {
    local tool=$1
    local step=$2
    local status=$3
    STATUS["$tool|$step"]=$status
}

# Function to add error
add_error() {
    local tool=$1
    local error=$2
    ERRORS["$tool"]="${ERRORS[$tool]}${ERRORS[$tool]:+$'\n'}$error"
}

# Function to check command success
check_command_success() {
    local tool=$1
    local step=$2
    if [ $? -ne 0 ]; then
        add_status "$tool" "$step" "Fail"
        add_error "$tool" "$step"
        return 1
    else
        add_status "$tool" "$step" "OK"
        return 0
    fi
}

# Function to check supported architecture
check_architecture() {
    local tool=$1
    if [[ "$ARCHITECTURE" != "x86_64" && "$ARCHITECTURE" != "aarch64" ]]; then
        add_error "$tool" "Unsupported architecture: $ARCHITECTURE"
        return 1
    fi
    return 0
}


# Install Ansible and Kubernetes Python module
install_ansible_kubernetes() {
    if command -v ansible &> /dev/null; then
        ANSIBLE_VERSION=$(ansible --version 2>&1 | head -n1 | sed -E 's/ansible \[core ([0-9.]+)\].*/\1/')
        add_status "Ansible" "Status" "Already installed (${ANSIBLE_VERSION})"
    else
        echo "Installing Ansible and Kubernetes Python module"
        # ansible-core is installed from PyPI rather than the ppa:ansible/ansible PPA.
        # Launchpad's HTTPS layer flakes regularly (504s, SSL handshake EOF), and the
        # add-apt-repository call goes through api.launchpad.net which is the
        # single point of failure. PyPI is more reliable. On Python 3.10 (Ubuntu 22.04),
        # pip auto-resolves to ansible-core 2.17.x, which matches what the PPA shipped.
        # python3-kubernetes still comes from apt (universe), unchanged.
        sudo apt-get update -qq || return 1
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq -y --no-install-recommends \
            python3-pip python3-kubernetes || return 1
        sudo pip3 install --quiet ansible-core || return 1
        check_command_success "Ansible" "Installation" || return 1

        # Install only required Ansible collections (used in our playbooks)
        # Galaxy is often down, so try Galaxy first then fall back to GitHub
        echo "Installing required Ansible collections..."

        install_collection() {
            local collection="$1"
            local github_url="$2"

            echo "Installing $collection from Galaxy..."
            local output
            output=$(ansible-galaxy collection install "$collection" --force 2>&1)
            echo "$output"

            # Check if Galaxy returned 500 error
            if echo "$output" | grep -q "HTTP Code: 500"; then
                # Galaxy failed, try GitHub
                if [ -n "$github_url" ]; then
                    echo "Galaxy unavailable, installing $collection from GitHub..."
                    output=$(ansible-galaxy collection install "$github_url" --force 2>&1)
                    echo "$output"
                    if echo "$output" | grep -q "was installed successfully"; then
                        echo "Successfully installed $collection from GitHub"
                        return 0
                    fi
                fi
                echo "Warning: Failed to install $collection"
                return 1
            fi

            # Galaxy succeeded
            if echo "$output" | grep -q "was installed successfully\|is already installed"; then
                echo "Successfully installed $collection from Galaxy"
                return 0
            fi

            echo "Warning: Failed to install $collection"
            return 1
        }

        local collections_failed=0
        install_collection kubernetes.core "git+https://github.com/ansible-collections/kubernetes.core.git,6.2.0" || collections_failed=1
        install_collection community.postgresql "git+https://github.com/ansible-collections/community.postgresql.git,3.4.0" || collections_failed=1
        install_collection community.general "git+https://github.com/ansible-collections/community.general.git,8.6.0" || collections_failed=1

        if [ "$collections_failed" -eq 0 ]; then
            add_status "Ansible Collections" "Status" "kubernetes.core, community.postgresql, community.general"
        else
            add_status "Ansible Collections" "Status" "Some collections failed"
            echo "Note: Playbooks requiring these collections won't work"
        fi

        ANSIBLE_VERSION=$(ansible --version 2>&1 | head -n1 | sed -E 's/ansible \[core ([0-9.]+)\].*/\1/')
        add_status "Ansible" "Status" "Installed (${ANSIBLE_VERSION})"
    fi

    # Verify Kubernetes module installation
    if python3 -c "import kubernetes; print(kubernetes.__version__)" &> /dev/null; then
        K8S_MODULE_VERSION=$(python3 -c "import kubernetes; print(kubernetes.__version__)")
        add_status "Kubernetes Python Module" "Status" "Installed (${K8S_MODULE_VERSION})"
    else
        add_error "Kubernetes Python Module" "Installation failed"
        return 1
    fi

    # Configure Ansible to work from any directory
    echo "Configuring Ansible global settings"

    # Create global Ansible config directory if it doesn't exist
    sudo mkdir -p /etc/ansible

    # Determine SSH key path (prefer new paths, fall back to legacy)
    local SSH_KEY_PATH="/mnt/urbalurbadisk/secrets/id_rsa_ansible"
    if [ -d "/mnt/urbalurbadisk/.uis.secrets/ssh" ]; then
        SSH_KEY_PATH="/mnt/urbalurbadisk/.uis.secrets/ssh/id_rsa_ansible"
    fi

    # Create or update the ansible.cfg file using sudo tee
    sudo tee /etc/ansible/ansible.cfg > /dev/null << ENDCONFIG
[defaults]
inventory = /mnt/urbalurbadisk/ansible/inventory.yml
private_key_file = $SSH_KEY_PATH
host_key_checking = False
roles_path = /mnt/urbalurbadisk/ansible/roles

[ssh_connection]
pipelining = True
control_path = /tmp/ansible-ssh-%%h-%%p-%%r
ENDCONFIG

    # Set permissions
    sudo chmod 644 /etc/ansible/ansible.cfg

    add_status "Ansible Config" "Status" "Global configuration created"

    return 0
}

# Install kubectl
install_kubectl() {
    if command -v kubectl &> /dev/null; then
        KUBECTL_VERSION=$(kubectl version --client 2>&1 | grep -oP 'Client Version: v\K[0-9.]+')
        add_status "kubectl" "Status" "Already installed (v${KUBECTL_VERSION})"
        return 0
    fi

    echo "Installing kubectl"
    # Check if we're in a container or if snap is available
    if [ "$RUNNING_IN_CONTAINER" = "true" ] || ! command -v snap &> /dev/null; then
        echo "Installing kubectl directly (not using snap)"
        KUBECTL_VERSION=$(curl -fL -s https://dl.k8s.io/release/stable.txt) || { add_error "kubectl" "Failed to fetch stable version"; return 1; }
        if [ -z "$KUBECTL_VERSION" ]; then
            add_error "kubectl" "Empty version from dl.k8s.io/release/stable.txt"
            return 1
        fi
        curl -fLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/$(dpkg --print-architecture)/kubectl" || { add_error "kubectl" "Failed to download kubectl binary"; return 1; }
        chmod +x kubectl || { add_error "kubectl" "Failed to chmod kubectl"; return 1; }
        sudo mv kubectl /usr/local/bin/ || { add_error "kubectl" "Failed to move kubectl to /usr/local/bin/"; return 1; }
        if ! command -v kubectl &> /dev/null; then
            add_error "kubectl" "kubectl not on PATH after install"
            return 1
        fi
        KUBECTL_VERSION=$(kubectl version --client --output=yaml | grep gitVersion | cut -d' ' -f4)
        add_status "kubectl" "Status" "Installed (${KUBECTL_VERSION})"
        return 0
    else
        echo "Installing kubectl using snap"
        if sudo snap install kubectl --classic; then
            KUBECTL_VERSION=$(kubectl version --client 2>&1 | grep -oP 'Client Version: v\K[0-9.]+')
            add_status "kubectl" "Status" "Installed (v${KUBECTL_VERSION})"
            return 0
        else
            add_error "kubectl" "Installation failed"
            return 1
        fi
    fi
}

# Install k9s
install_k9s() {
    if command -v k9s &> /dev/null; then
        # ⚠️ NOT K9S_VERSION — that is the pinned constant this function
        # downloads. Reusing the name for "what is installed" meant one
        # identifier held two meanings in one function, and the reporting
        # assignment below would have clobbered the pin for anything later.
        local k9s_installed_version
        k9s_installed_version=$(k9s version 2>&1 | grep "Version:" | tr -d '\r')
        add_status "k9s" "Status" "Already installed (${k9s_installed_version})"
        return 0
    fi

    echo "Installing k9s"
    check_architecture "k9s" || return 1

    if [ "$ARCHITECTURE" = "x86_64" ]; then
        ARCH_NAME="amd64"
    elif [ "$ARCHITECTURE" = "aarch64" ]; then
        ARCH_NAME="arm64"
    else
        add_error "k9s" "Unsupported architecture: $ARCHITECTURE"
        return 1
    fi

    # 🔴 PINNED, and it is not only about supply chain — it is why the build
    # was red.
    #
    # This used to ask api.github.com for the latest release. That call is
    # UNAUTHENTICATED and rate-limited to 60/hour per IP, and both architecture
    # builds run concurrently from the same GitHub Actions runner. On 1.6.41
    # amd64 got an answer and arm64 did not: LATEST_VERSION came back empty,
    # the function returned 1, and the whole image build failed — on a commit
    # that touched two Ansible playbooks and nothing else.
    #
    # ⚠️ So an unpinned binary did not merely risk drift; it made the build a
    # coin flip against someone else's rate limit. PLAN-system-pin-provisioned-
    # binaries predicted the drift and not this, and this is the sharper
    # argument.
    #
    # To bump: change K9S_VERSION, then take both sums from
    #   https://github.com/derailed/k9s/releases/download/<ver>/checksums.sha256
    # Never self-compute them — a sum you calculate from the bytes you received
    # attests to nothing.
    local expected_sum
    if [ "$ARCH_NAME" = "amd64" ]; then
        expected_sum="$K9S_SHA256_amd64"
    else
        expected_sum="$K9S_SHA256_arm64"
    fi

    TEMP_DIR=$(mktemp -d)
    curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH_NAME}.tar.gz" \
        -o "${TEMP_DIR}/k9s.tar.gz" || {
        add_error "k9s" "Failed to download k9s ${K9S_VERSION} for ${ARCH_NAME}"
        rm -rf "${TEMP_DIR}"
        return 1
    }

    local actual_sum
    actual_sum=$(sha256sum "${TEMP_DIR}/k9s.tar.gz" | cut -d' ' -f1)
    if [ "$actual_sum" != "$expected_sum" ]; then
        add_error "k9s" "Checksum mismatch for ${ARCH_NAME}: expected ${expected_sum}, got ${actual_sum}"
        rm -rf "${TEMP_DIR}"
        return 1
    fi

    tar -xzf "${TEMP_DIR}/k9s.tar.gz" -C "${TEMP_DIR}" || {
        add_error "k9s" "Failed to extract k9s"
        rm -rf "${TEMP_DIR}"
        return 1
    }

    sudo mv "${TEMP_DIR}/k9s" /usr/local/bin/ || {
        add_error "k9s" "Failed to move k9s to /usr/local/bin/"
        rm -rf "${TEMP_DIR}"
        return 1
    }

    sudo chmod +x /usr/local/bin/k9s || {
        add_error "k9s" "Failed to make k9s executable"
        return 1
    }

    rm -rf "${TEMP_DIR}"

    local k9s_installed_version
    k9s_installed_version=$(k9s version 2>&1 | grep "Version:" | tr -d '\r')
    if [ -z "$k9s_installed_version" ]; then
        add_error "k9s" "Failed to verify k9s installation"
        return 1
    fi

    add_status "k9s" "Status" "Installed (${K9S_VERSION})"
    return 0
}

# Install Helm
# ─── oras ─────────────────────────────────────────────────────────────────────
#
# Fetches an application's UIS install definition, which is published as its own
# small OCI artifact beside the application's image (Terje, urb-agents#361). One
# static binary; `uis template install` cannot resolve a pointer without it.
#
# ⚠️ PINNED TO AN EXACT VERSION AND CHECKSUM-VERIFIED, unlike its neighbours in
# this file, and deliberately so (Terje, 2026-09-09):
#
#   - k9s above resolves `releases/latest` AT BUILD TIME, so two builds of the
#     same commit can install different versions. The image is not reproducible,
#     which sits badly against INVESTIGATE-system-version-pinning — that
#     investigation exists because 16 Helm charts took whatever the repo served
#     that day, and this is a binary in the product image.
#   - nothing else in this file verifies a checksum at all.
#   - and this particular binary is what fetches THIRD-PARTY SQL that
#     `uis configure --init-file` then applies as the database owner. An
#     unverified download in that position is the wrong place to save two lines.
#
# The checksums below are the values published in oras's own
# `oras_<v>_checksums.txt`, not values computed from what a build happened to
# receive — a self-computed sum attests to nothing.
#
# To bump: change ORAS_VERSION, then take both sums from
#   https://github.com/oras-project/oras/releases/download/v<ver>/oras_<ver>_checksums.txt
# Bringing kubectl/helm/k9s up to this standard is PLAN-system-pin-provisioned-binaries.
K9S_VERSION="v0.51.0"
K9S_SHA256_amd64="c3752ad51a5a4015a113819c4eeb6e55a4d0e4b8e652494797532f6fc8161dd7"
K9S_SHA256_arm64="3ee05c82e5f9198928a4e86133608ba6a2c10a2244d6a7789e820f78319d640c"

ORAS_VERSION="1.3.4"
ORAS_SHA256_amd64="f27adb935022d94df8dc77719c322dda592c78a0d57a6f7dcdd8d900b248c454"
ORAS_SHA256_arm64="15702c6e3a4a56a8bd8ac5c17efdbcab56d9bada661ccbcf017f5b10c1d89399"

install_oras() {
    if command -v oras &> /dev/null; then
        add_status "oras" "Status" "Already installed ($(oras version 2>&1 | head -1 | tr -d '\r'))"
        return 0
    fi

    echo "Installing oras ${ORAS_VERSION}"
    check_architecture "oras" || return 1

    local arch_name expected
    if [ "$ARCHITECTURE" = "x86_64" ]; then
        arch_name="amd64"; expected="$ORAS_SHA256_amd64"
    elif [ "$ARCHITECTURE" = "aarch64" ]; then
        arch_name="arm64"; expected="$ORAS_SHA256_arm64"
    else
        add_error "oras" "Unsupported architecture: $ARCHITECTURE"
        return 1
    fi

    local tmp tarball url
    tmp=$(mktemp -d)
    tarball="${tmp}/oras.tar.gz"
    url="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${arch_name}.tar.gz"

    if ! curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$tarball"; then
        add_error "oras" "Failed to download oras ${ORAS_VERSION} for ${arch_name}"
        rm -rf "$tmp"; return 1
    fi

    local actual
    actual=$(sha256sum "$tarball" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        # Refuse rather than warn. A mismatch means the bytes are not what was
        # pinned, and this binary goes on to fetch SQL that runs as the database
        # owner.
        add_error "oras" "Checksum mismatch for ${arch_name}: expected ${expected}, got ${actual}"
        rm -rf "$tmp"; return 1
    fi

    if ! tar -xzf "$tarball" -C "$tmp" oras; then
        add_error "oras" "Failed to extract oras"
        rm -rf "$tmp"; return 1
    fi

    # ⚠️ `sudo`, and `chmod` separately rather than `install -m`. The provisioning
    # script does not run as root — kubectl (:190) and k9s (:250) both `sudo mv`
    # for this reason, and I used a bare `install` on the first attempt: download
    # and checksum both passed and the build died at
    # `cannot create regular file '/usr/local/bin/oras': Permission denied`.
    # Matching the neighbours here is right; the pinning is where this file should
    # differ from them, not the privilege idiom.
    sudo mv "${tmp}/oras" /usr/local/bin/oras || {
        add_error "oras" "Failed to move oras to /usr/local/bin"
        rm -rf "$tmp"; return 1
    }
    sudo chmod 0755 /usr/local/bin/oras || {
        add_error "oras" "Failed to make oras executable"
        rm -rf "$tmp"; return 1
    }
    rm -rf "$tmp"

    add_status "oras" "Status" "Installed v${ORAS_VERSION} (checksum verified)"
    return 0
}

install_helm() {
    if command -v helm &> /dev/null; then
        HELM_VERSION=$(helm version --short 2>&1 | cut -d'v' -f2)
        add_status "Helm" "Status" "Already installed (v${HELM_VERSION})"
        return 0
    fi

    echo "Installing Helm"
    check_architecture "Helm" || return 1

    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 || return 1
    chmod 700 get_helm.sh || return 1
    ./get_helm.sh || return 1
    rm get_helm.sh

    HELM_VERSION=$(helm version --short 2>&1 | cut -d'v' -f2)
    add_status "Helm" "Status" "Installed (v${HELM_VERSION})"
    return 0
}

# Cleanup function
cleanup() {
    echo "Performing cleanup..."
    sudo apt-get clean -qq
    sudo apt-get autoremove -qq -y
}

# Print summary
print_summary() {
    echo "---------- Installation Summary ----------"
    echo "System Architecture: $ARCHITECTURE"
    echo "---------------------------------------------------"

    for tool in "Ansible" "Kubernetes Python Module" "kubectl" "k9s" "Helm"; do
        echo "$tool: ${STATUS[$tool|Status]:-Not installed}"
    done

    if [ ${#ERRORS[@]} -eq 0 ]; then
        echo "All installations completed successfully."
    else
        echo "Errors occurred during installation:"
        for tool in "${!ERRORS[@]}"; do
            echo "  $tool: ${ERRORS[$tool]}"
        done
    fi
}

# Main execution
main() {
    echo "Starting Kubernetes tools installation on $(hostname)"
    echo "System Architecture: $ARCHITECTURE"
    echo "---------------------------------------------------"

    trap cleanup EXIT

    # Run apt update once at the beginning
    sudo apt-get update -qq || return 1

    # Install curl; skip snapd in containers (not needed and saves ~91MB)
    if [ "$RUNNING_IN_CONTAINER" = "true" ]; then
        sudo apt-get install -qq -y curl || return 1
    else
        sudo apt-get install -qq -y curl snapd || return 1
    fi

    # Install kubectl, helm, k9s first — direct downloads from k8s.io / GitHub,
    # most resilient. Ansible install (via PyPI) also avoids launchpad now,
    # but we keep it last so a transient PyPI hiccup can't strand the cluster
    # tooling that other scripts depend on.
    install_kubectl || return 1
    install_helm || return 1
    install_k9s || return 1
    install_oras || return 1
    install_ansible_kubernetes || return 1

    print_summary

    # Return 0 if no errors, 1 otherwise
    return ${#ERRORS[@]}
}

# Run the main function and exit with its return code
main
exit $?