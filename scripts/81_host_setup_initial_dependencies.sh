#!/usr/bin/env bash
set -euo pipefail

sudo apt install -y cpu-checker
sudo kvm-ok

sudo apt update && sudo apt upgrade -y
sudo apt autoremove --purge -y
sudo apt autoclean -y

sudo apt install -y qemu-kvm 
sudo apt install -y libvirt-daemon-system 
sudo apt install -y libvirt-clients 
sudo apt install -y virtinst 
sudo apt install -y bridge-utils
sudo apt install -y libosinfo-bin
sudo apt install -y virt-top
sudo apt install -y virt-manager
sudo apt install -y genisoimage
sudo apt install -y cloud-image-utils

sudo apt install -y jq

# yq -- used to read/write state.yaml. The `yq` package in apt is NOT
# guaranteed to be mikefarah/yq (Go); install the Go binary explicitly so
# the -i / `.key = "value"` syntax used by lib/common.sh works:
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) YQ_ARCH=amd64 ;;
    aarch64) YQ_ARCH=arm64 ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

sudo curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}"
sudo chmod +x /usr/local/bin/yq
yq --version   # should print "yq (https://github.com/mikefarah/yq/) version ..."

sudo usermod -aG libvirt "$USER"
sudo usermod -aG kvm "$USER"

sudo systemctl enable libvirtd
sudo systemctl start libvirtd

echo "Initial dependencies setup complete."

echo "Log out and back in to apply group membership changes."
echo "Then run the following commands to verify libvirt is working:"
echo
echo "sudo kvm-ok" 
echo "sudo systemctl status libvirtd"
echo "groups"
echo "sudo virsh list --all"
echo "sudo virsh net-list --all"
echo "sudo virsh pool-list --all"