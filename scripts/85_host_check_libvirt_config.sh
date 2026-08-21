echo "Printing the environment variables to verify that they are set correctly:"
echo $LIBVIRT_HOME
echo $STORAGE_POOL_IMAGES
echo $STORAGE_POOL_ISOS
echo $STORAGE_POOL_DISKS
echo $STORAGE_POOL_SNAPSHOTS
echo $STORAGE_POOL_CLOUD_INIT_ISOS


echo "Printing version information:"
virt-install --version
cloud-init --version
qemu-img --version
yq --version

echo "Printing libvirt configuration:"
virsh -c qemu:///system list --all
virsh -c qemu:///system pool-list --all
virsh -c qemu:///system net-list --all

# Confirm the lifecycle scripts can run without sudo (requires the
# usermod -aG libvirt/kvm above and a fresh login session):
virsh -c qemu:///system list --all
