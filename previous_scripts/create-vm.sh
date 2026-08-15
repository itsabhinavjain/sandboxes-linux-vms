#!/bin/bash
set -e

# Usage: ./create-vm.sh <vm-name> [disk-size] [ram-mb] [vcpus]
VMNAME="${1:?Usage: $0 <vm-name> [disk-size-gb] [ram-mb] [vcpus]}"
DISK_SIZE="${2:-20}"
RAM="${3:-2048}"
VCPUS="${4:-2}"

IMAGES_DIR="/mnt/extreme_ssd/libvirt/images"
ISOS_DIR="/mnt/extreme_ssd/libvirt/isos"
TEMPLATE_DIR="$PWD"

BASE_IMAGE_NAME="noble-server-cloudimg-amd64"
BASE_IMAGE="$ISOS_DIR/$BASE_IMAGE_NAME.img"

DISK_PATH="$IMAGES_DIR/$BASE_IMAGE_NAME-${VMNAME}.qcow2"
SEED_PATH="$IMAGES_DIR/$BASE_IMAGE_NAME-${VMNAME}-seed.iso"

USERDATA="$PWD/${VMNAME}-user-data"
METADATA="$PWD/${VMNAME}-meta-data"

echo "==> Creating VM: $VMNAME (${DISK_SIZE}GB disk, ${RAM}MB RAM, ${VCPUS} vCPUs)"

# 1. Create disk from base image, expand to requested size
echo "==> Creating disk image..."
sudo qemu-img create -F qcow2 -b "$BASE_IMAGE" -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"

# Note that the above is space efficiency 

# 2. Generate cloud-init config files
echo "==> Generating cloud-init config..."
sed "s/VMNAME/$VMNAME/g" "$TEMPLATE_DIR/user-data.tmpl" > "$USERDATA"
cat > "$METADATA" <<EOF
instance-id: $VMNAME
local-hostname: $VMNAME
EOF

# 3. Build the seed ISO
echo "==> Building seed ISO..."
sudo cloud-localds "$SEED_PATH" "$USERDATA" "$METADATA"

# 4. Set ownership
sudo chown libvirt-qemu:kvm "$DISK_PATH" "$SEED_PATH"

# 5. Create the VM
echo "==> Creating and starting VM..."
sudo virt-install \
    --name "$VMNAME" \
    --memory "$RAM" \
    --vcpus "$VCPUS" \
    --disk path="$DISK_PATH",format=qcow2,bus=virtio \
    --disk path="$SEED_PATH",device=cdrom \
    --os-variant ubuntu24.04 \
    --network network=default,model=virtio \
    --graphics none \
    --noautoconsole \
    --import

echo ""
echo "==> VM '$VMNAME' is starting up. Cloud-init is configuring it now."
echo "==> Wait ~60-90 seconds, then try:  ssh $VMNAME.<your-tailnet>.ts.net"
echo "==> Watch progress with:  sudo virsh console $VMNAME  (Ctrl+] to exit)"

