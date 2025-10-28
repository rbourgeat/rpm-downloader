#!/bin/bash

set -e

C_BOLD="\033[1m"
C_BLUE="\033[1;34m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_RESET="\033[0m"

print_header() {
    echo -e "\n${C_BLUE}--- ${C_BOLD}$1 ${C_RESET}${C_BLUE}---${C_RESET}"
}

if ! command -v docker &> /dev/null; then
    echo -e "${C_RED}[!] Error: Docker is not installed or not in your PATH.${C_RESET}"
    echo -e "    Please install Docker on this machine to run the script."
    exit 1
fi

# ==============================================================================
#  USER INTERACTION
# ==============================================================================

print_header "RPM Package Downloader"
echo -e "This script will download RPMs for Docker, Kubernetes, or NVIDIA Container Toolkit."

while true; do
    echo -e "\n${C_YELLOW}[>] Select the target AlmaLinux version:${C_RESET}"
    echo "    1) AlmaLinux 9 (Recommended)"
    echo "    2) AlmaLinux 8"
    read -p "    Enter your choice [1-2]: " os_choice

    case $os_choice in
        1) ALMA_VERSION=9; DOCKER_IMAGE="almalinux:9"; break ;;
        2) ALMA_VERSION=8; DOCKER_IMAGE="almalinux:8"; break ;;
        *) echo -e "${C_RED}[!] Invalid selection. Please enter 1 or 2.${C_RESET}" ;;
    esac
done
echo -e "${C_GREEN}[*] Target OS set to AlmaLinux ${ALMA_VERSION}.${C_RESET}"

while true; do
    echo -e "\n${C_YELLOW}[>] Select the tool to download:${C_RESET}"
    echo "    1) Docker CE"
    echo "    2) Kubernetes (kubeadm, kubelet, kubectl)"
    echo "    3) NVIDIA Container Toolkit"
    read -p "    Enter your choice [1-3]: " tool_choice

    case $tool_choice in
        1)
            TOOL_NAME="docker"
            PACKAGES_TO_DOWNLOAD=("docker-ce" "docker-ce-cli" "containerd.io" "docker-buildx-plugin" "docker-compose-plugin")
            REPO_SETUP_COMMANDS="echo '---> Adding Docker CE repository...'; dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo > /dev/null"
            break
            ;;
        2)
            while true; do
                echo -e "\n${C_YELLOW}[>] Enter the desired Kubernetes major.minor version (e.g., 1.30, 1.29, 1.28):${C_RESET}"
                read -p "    Version: " K8S_VERSION
                if [[ -n "$K8S_VERSION" ]]; then
                    break
                else
                    echo -e "${C_RED}[!] Version cannot be empty. Please try again.${C_RESET}"
                fi
            done
            echo -e "${C_GREEN}[*] Kubernetes version set to ${K8S_VERSION}.${C_RESET}"

            TOOL_NAME="k8s-v${K8S_VERSION}"
            PACKAGES_TO_DOWNLOAD=("kubelet" "kubeadm" "kubectl")
            REPO_SETUP_COMMANDS="
    echo '---> Configuring Kubernetes repository for version ${K8S_VERSION}...'
    cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repodata.fly.key
EOF
    echo '---> Restricting to x86_64 architecture...'
    echo 'multilib_policy=best' >> /etc/dnf/dnf.conf
    echo 'exclude=*.aarch64 *.ppc64le *.s390x' >> /etc/dnf/dnf.conf
"
            break
            ;;
        3)
            TOOL_NAME="nvidia-toolkit"
            PACKAGES_TO_DOWNLOAD=("nvidia-container-toolkit")
            REPO_SETUP_COMMANDS="
    echo '---> Enabling EPEL repository for potential dependencies...'
    dnf install -y epel-release > /dev/null
    echo '---> Adding NVIDIA Container Toolkit repository...'
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo -o /etc/yum.repos.d/nvidia-container-toolkit.repo
"
            break
            ;;
        *) echo -e "${C_RED}[!] Invalid selection. Please enter 1, 2, or 3.${C_RESET}" ;;
    esac
done
echo -e "${C_GREEN}[*] Tool set to ${TOOL_NAME^}.${C_RESET}"


# ==============================================================================
#  DOWNLOAD LOGIC
# ==============================================================================

DOWNLOAD_DIR="alma${ALMA_VERSION}-${TOOL_NAME}-rpms"

print_header "Starting Download Process"
echo -e "${C_CYAN}[*] Preparing download directory: ./${DOWNLOAD_DIR}${C_RESET}"
mkdir -p "$DOWNLOAD_DIR"
ABS_DOWNLOAD_DIR="$(cd "$DOWNLOAD_DIR" && pwd)"
echo -e "${C_CYAN}[*] RPMs will be saved to: ${ABS_DOWNLOAD_DIR}${C_RESET}"
echo -e "${C_CYAN}[*] Spinning up a temporary ${DOCKER_IMAGE} container...${C_RESET}"

docker run --rm -v "${ABS_DOWNLOAD_DIR}:/rpms" "${DOCKER_IMAGE}" bash -c "
    set -e
    echo '---> Inside container: Installing dnf-utils...'
    dnf install -y dnf-utils > /dev/null
    ${REPO_SETUP_COMMANDS}
    echo '---> Inside container: Downloading packages and all dependencies...'
    dnf download -y --resolve --downloaddir=/rpms ${PACKAGES_TO_DOWNLOAD[*]}
"

# ==============================================================================
#  COMPLETION
# ==============================================================================

print_header "Download Complete"
TOTAL_FILES=$(ls -1q "${DOWNLOAD_DIR}" | wc -l)
echo -e "${C_GREEN}[✓] Success! Downloaded ${TOTAL_FILES} RPM files to './${DOWNLOAD_DIR}'.${C_RESET}"

echo
echo -e "${C_BOLD}--- Manual/Offline Installation Instructions ---${C_RESET}"
echo -e "1. Copy the '${C_YELLOW}${DOWNLOAD_DIR}${C_RESET}' directory to your target AlmaLinux ${ALMA_VERSION} machine."
echo -e "   ${C_CYAN}Example: scp -r ./${DOWNLOAD_DIR} user@almalinux-server:~/ ${C_RESET}"
echo
echo -e "2. On the target machine, install all RPMs with one command:"
echo -e "   ${C_CYAN}cd ${DOWNLOAD_DIR}${C_RESET}"
echo -e "   ${C_CYAN}sudo dnf install ./*.rpm${C_RESET}"
echo -e "${C_BOLD}------------------------------------------------${C_RESET}"