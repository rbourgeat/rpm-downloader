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
echo -e "This script will download RPMs for Docker or Kubernetes."

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
    read -p "    Enter your choice [1-2]: " tool_choice

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
        *) echo -e "${C_RED}[!] Invalid selection. Please enter 1 or 2.${C_RESET}" ;;
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
    dnf download --resolve --downloaddir=/rpms ${PACKAGES_TO_DOWNLOAD[*]}
"

# ==============================================================================
#  COMPLETION
# ==============================================================================

print_header "Download Complete"
TOTAL_FILES=$(ls -1q "${DOWNLOAD_DIR}" | wc -l)
echo -e "${C_GREEN}[✓] Success! Downloaded ${TOTAL_FILES} RPM files to './${DOWNLOAD_DIR}'.${C_RESET}"

print_header "Next Steps: Choose Your Method"
while true; do
    echo -e "\n${C_YELLOW}[>] How would you like to use these RPMs?${C_RESET}"
    echo -e "    ${C_BOLD}A)${C_RESET} Manual/Offline Install (copy files to a server)"
    echo -e "    ${C_BOLD}B)${C_RESET} Upload to Nexus (for centralized repository management)"
    read -p "    Enter your choice [A/B]: " next_step_choice

    case ${next_step_choice^^} in
        A)
            echo
            echo -e "${C_BOLD}--- Manual/Offline Installation Instructions ---${C_RESET}"
            echo -e "1. Copy the '${C_YELLOW}${DOWNLOAD_DIR}${C_RESET}' directory to your target AlmaLinux ${ALMA_VERSION} machine."
            echo -e "   ${C_CYAN}Example: scp -r ./${DOWNLOAD_DIR} user@almalinux-server:~/ ${C_RESET}"
            echo
            echo -e "2. On the target machine, install all RPMs with one command:"
            echo -e "   ${C_CYAN}cd ${DOWNLOAD_DIR}${C_RESET}"
            echo -e "   ${C_CYAN}sudo dnf install ./*.rpm${C_RESET}"
            echo -e "${C_BOLD}------------------------------------------------${C_RESET}"
            break
            ;;
        B)
            UPLOAD_SCRIPT_NAME="upload-to-nexus.sh"
            UPLOAD_SCRIPT_PATH="${DOWNLOAD_DIR}/${UPLOAD_SCRIPT_NAME}"

            cat <<'EOF' > "${UPLOAD_SCRIPT_PATH}"
#!/bin/bash
set -e

# ==============================================================================
#  This script uploads all .rpm files in its directory to a Nexus YUM repo.
# ==============================================================================

# --- CONFIGURATION: EDIT THESE VALUES ---
NEXUS_URL="https://nexus.your-company.com"
NEXUS_REPO="your-yum-hosted-repo-name"
NEXUS_USER="your-username"
# ----------------------------------------

echo "--- Nexus RPM Uploader ---"
echo "URL:  ${NEXUS_URL}"
echo "Repo: ${NEXUS_REPO}"
echo "User: ${NEXUS_USER}"
echo

# Securely prompt for the password
read -sp "Enter password for ${NEXUS_USER}: " NEXUS_PASS
echo
echo

# Loop through all .rpm files in the current directory
for rpm_file in ./*.rpm; do
    # Check if the file exists to handle cases with no RPMs
    [ -e "$rpm_file" ] || continue

    echo -n "Uploading $(basename "$rpm_file")... "
    
    # Use curl to upload the package
    # The API endpoint is /service/rest/v1/components
    response=$(curl -s -o /dev/null -w "%{http_code}" \
         -u "${NEXUS_USER}:${NEXUS_PASS}" \
         -X POST "${NEXUS_URL}/service/rest/v1/components?repository=${NEXUS_REPO}" \
         -H "Content-Type: multipart/form-data" \
         -F "yum.asset=@${rpm_file}")
    
    if [ "$response" -ge 200 ] && [ "$response" -lt 300 ]; then
        echo "OK (HTTP ${response})"
    else
        echo "FAILED (HTTP ${response})"
        echo "  Please check your credentials, URL, and repository name."
        exit 1
    fi
done

echo
echo "✅ All RPMs uploaded successfully."
EOF
            chmod +x "${UPLOAD_SCRIPT_PATH}"

            echo
            echo -e "${C_GREEN}[✓] A helper script has been created for you!${C_RESET}"
            echo -e "${C_BOLD}--- How to Upload to Nexus ---${C_RESET}"
            echo -e "A new script has been placed inside your download folder."
            echo
            echo -e "1. ${C_BOLD}Navigate into the directory:${C_RESET}"
            echo -e "   ${C_CYAN}cd ${DOWNLOAD_DIR}${C_RESET}"
            echo
            echo -e "2. ${C_BOLD}Edit the script with your Nexus details:${C_RESET}"
            echo -e "   (Use any text editor, like nano or vim)"
            echo -e "   ${C_CYAN}vim ${UPLOAD_SCRIPT_NAME}${C_RESET}"
            echo
            echo -e "3. ${C_BOLD}Run the script to upload all RPMs:${C_RESET}"
            echo -e "   (It will securely prompt for your password)"
            echo -e "   ${C_CYAN}./${UPLOAD_SCRIPT_NAME}${C_RESET}"
            echo -e "${C_BOLD}--------------------------------${C_RESET}"
            break
            ;;
        *)
            echo -e "${C_RED}[!] Invalid selection. Please enter A or B.${C_RESET}"
            ;;
    esac
done