This file mentions about various setup and maintainence to be done on the linux host 

Table of contents 
- Notes and nomenclatures 
- Understanding the linux host 
- Initial host setup, libvirt setup and configuration 
    - Installing and setting up with dependencies 
    - Bootstrap script - Environment variables at the system level 
    - Configuring libvirt and the storage pools 
    - Checking configurations
- Editing libvirt configuration (and migrating the the current VMs) 
- Checking libvirt configuration
- Other setups 
    - Download the cloud images 
    - Tailscale setup 

TODO : Every section can actually be made into a script that we run. Please however make sure that every script is indempotent 

--- 

## Notes and nomenclature 
Environment variables and storage pool setup :- 

```
LIBVIRT_HOME
STORAGE_POOL_IMAGES
STORAGE_POOL_ISOS
STORAGE_POOL_DISKS
STORAGE_POOL_SNAPSHOTS
STORAGE_POOL_CLOUD_INIT_ISOS
```

```
export STORAGE_POOL_IMAGES="${LIBVIRT_HOME}/images"              : Will have the cloud images that I have downloaded from the internet. 
export STORAGE_POOL_ISOS="${LIBVIRT_HOME}/isos"                  : Will have installer-ISOs (an installer). this is not being used right now. Currently we are working with cloud images. 
export STORAGE_POOL_DISKS="${LIBVIRT_HOME}/disks"                : Will have the qcow2 disks and yaml specifications 
export STORAGE_POOL_SNAPSHOTS="${LIBVIRT_HOME}/snapshots"        : Will be used in case we have external snapshots. Right now we are planning internal snapshots only. 
export STORAGE_POOL_CLOUD_INIT_ISOS="${LIBVIRT_HOME}/cloud-init" : Will have seed-ISOs (cloud-init isos - essentially a configuration disk) that I create from cloud-init. 
```

This system-level bootstrap is the baseline. If you want per-checkout
overrides (a different storage pool location, different defaults) without
touching `/etc/profile.d/sandbox.sh`, copy [`env.sample`](./env.sample) to
`.env` in the repo root instead -- `scripts/lib/common.sh` loads it
automatically and it takes precedence over the system-level variables set
above. See [README.md](./README.md#requirements-for-the-repo) for the full
precedence order.


## Understanding the linux host 
[host_check_specs](./scripts/80_host_check_specs.sh)
- TODO : Things to improve : the CPU section should explicitly show physical cores, threads/core, sockets, and cache, rather than the current grep potentially hiding those fields. That will make the output much more useful when we use it to calculate VM capacity.

## Initial host setup, libvirt setup and configuration 
- Installing and setting up with dependencies : [81_host_setup_initial_dependencies](./scripts/81_host_setup_initial_dependencies.sh)
- Bootstrap script - Environment variables at the system level : [82_host_setup_bootstrap_script](./scripts/82_host_setup_bootstrap_script.sh)
- Configuring libvirt and the storage pools : [83_host_configure_libvirt_storage_pools](./scripts/83_host_configure_libvirt_storage_pools.sh)
- Edit storage pools : [84_host_change_libvirt_storage_pools](./scripts/84_host_change_libvirt_storage_pools.sh)
- Checking configurations : [85_host_check_libvirt_config](./scripts/85_host_check_libvirt_config.sh)

## Other setup 

### Download the cloud img 
```
curl -fsSL -o "$STORAGE_POOL_IMAGES/noble-server-cloudimg-amd64.img" \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

### TAILSCALE SETUP
1) Reusable + ephemeral auth key → TAILSCALE_AUTHKEY
Go to https://login.tailscale.com/admin/settings/keys
1. Click "Generate auth key..."
2. Description: something like sandboxes-linux-vms fleet
3. Toggle Reusable on
4. Toggle Ephemeral on
5. Under Tags, select tag:dmz-ephemeral
6. Set expiry (90 days is the max for a reusable key) — this is your rotation reminder
7. Click Generate key, copy the value immediately (it's shown once, starts tskey-auth-...)

2) OAuth client → TAILSCALE_API_CLIENT_ID / TAILSCALE_API_CLIENT_SECRET
Go to https://login.tailscale.com/admin/settings/oauth
1. Click "Generate OAuth client..."
2. Description: something like sandboxes-linux-vms destroy cleanup
3. Under Scopes, select only Devices → Core, and make sure it's set to Write (not read-only — deleting a device needs write)
4. Under Tags, restrict this client to tag:dmz-ephemeral only — this is what guarantees the credential can't touch anything else on your tailnet
5. Click Generate client, copy both the Client ID and Client Secret immediately (the secret is shown once)

Once you have all three values, you can either paste them here and I'll write them into .env for you, or add them yourself:

TAILSCALE_AUTHKEY="tskey-auth-..."
TAILSCALE_API_CLIENT_ID="..."
TAILSCALE_API_CLIENT_SECRET="..."

