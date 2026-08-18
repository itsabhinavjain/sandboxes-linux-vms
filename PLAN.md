## ROADMAP 
## Things to implement 
- [ ] Check the networking using Tailscale. See if you want to do it automatically or have a manual setup 
- [ ] Check if the networking has been setup as per the design decisions that I have taken 
- [x] Create a script to edit the configuration of a virtual machine - CPUs, RAM, Disk Space, Autostart - The script should show what the current config is and interactively ask for new config. It should stop and restart vm accordingly as and when needed. 
- [ ] Check using the vms - how will you ssh into the machines etc 
- [x] Install qemu guest agent in the virtual machines. (can be done through cloud-init as well)

```
sudo apt install qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```
Useful for :
```
virsh domifaddr
virsh shutdown
virsh reboot
```

- [ ] The `info` and the `list` scripts can be a little more detailed where you can give the IP addresses of all the vms etc 
```
for vm in $(virsh list --name); do
    printf "%-30s " "$vm"
    virsh domifaddr "$vm" --source agent 2>/dev/null |
        awk '$3 == "ipv4" {print $4}'
done
```

```
# Primary : 
virsh domifaddr VM --source agent

# DHCP Fallback : 
virsh net-dhcp-leases default
```

- [x] Move docker away from cloud-init and instead put it in the configuration scripts - automated and interactive 
- [ ] user-data customization. Can ask to specify the user instead of hardcoded to `abhinav`. this can also be controlled from an environment variable. 

## Wishlist (Might implement later. Dont implement this right now - overengineering and wastage of time)
- [ ] Snapshot scripts (`21/22` snapshot scripts)
- [ ] Move from individual yaml state files to a global repositry. Think this through later. Dont waste your time on this. 
- [ ] Script design - Maybe instead of having different scripts for automated and interactive, you can have a same script and send interactive flags. Check the best practices, this might make the code cleaner. 
- CLI tool development (Long shot - Dont invest your time on this right now)
  - [ ] Change from scripts to an actual cli tool that I can design. That would make it more distributable 
  - [ ] When making into a CLI tool, you can actually make the tool a little more generic and support other types of sandboxes like - microvms, docker containers etc 
  - [ ] While implementing the cli tool, you could also implement a gateway of sort and expose using an API so that AI agents can provision and manage the sandboxes on demand 

--- 

## AGENT LOGS 
Claude and Other Coding Agents can add their log here :- 

### 2026-08-18 -- Claude (Sonnet 5)
Implemented three wishlist items:
- **qemu-guest-agent**: added to `setup_config/user-data.tmpl`'s packages
  list (+ explicit `systemctl enable --now`), and added the required
  virtio-serial channel device (`--channel unix,target_type=virtio,
  name=org.qemu.guest_agent.0`) to the `virt-install` call in
  `00_init_vm-automated.sh`. New VMs only -- see DECISIONS.md.
- **Docker off cloud-init**: removed the Docker `runcmd` block from
  `user-data.tmpl`, added an idempotent `install_docker` remote step to
  `scripts/lib/configure_steps.sh`, wired into both
  `11_configure_vm-automated.sh`/`-interactive.sh` behind a new
  `--skip-docker` flag, recorded as `.docker` in state.yaml.
- **Resize script**: new `scripts/12_resize_vm-automated.sh` /
  `12_resize_vm-interactive.sh`, sharing `scripts/lib/resize_steps.sh`.
  Edits RAM/vCPUs/disk/autostart on an existing VM; RAM/vCPU/disk changes
  always apply while stopped (`--config` only, no live hotplug -- see
  DECISIONS.md) and restart the VM if it was running; disk resize is
  grow-only. Also added `state_set_raw` to `scripts/lib/common.sh` (numeric
  state fields, `state_set`'s own doc comment referenced this but it didn't
  exist yet).

Not verified end-to-end against a real host in this session (no VM was
started/stopped) -- syntax-checked (`bash -n`) all touched/new scripts
only. Treat as "believed correct but unverified," same caveat as the
existing `11_configure_vm-*` note above.
