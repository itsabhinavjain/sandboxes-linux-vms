## ROADMAP 
## Things to implement 
- [ ] Check the networking using Tailscale. See if you want to do it automatically or have a manual setup 
- [ ] Check if the networking has been setup as per the design decisions that I have taken 
- [ ] Create a script to edit the configuration of a virtual machine - CPUs, RAM, Disk Space, Autostart - The script should show what the current config is and interactively ask for new config. It should stop and restart vm accordingly as and when needed. 
- [ ] Check using the vms - how will you ssh into the machines etc 
- [ ] Install qemu guest agent in the virtual machines. (can be done through cloud-init as well)

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

- [ ] Snapshot scripts (`21/22` snapshot scripts)
- [ ] Move docker away from cloud-init and instead put it in the configuration scripts - automated and interactive 
- [ ] user-data customization. Can ask to specify the user instead of hardcoded to `abhinav`. this can also be controlled from an environment variable. 

## Wishlist (Might implement later. Dont implement this right now)
- [ ] Move from individual yaml state files to a global repositry. Think this through later. Dont waste your time on this. 
- CLI tool development (Long shot - Dont invest your time on this right now)
  - [ ] Change from scripts to an actual cli tool that I can design. That would make it more distributable 
  - [ ] When making into a CLI tool, you can actually make the tool a little more generic and support other types of sandboxes like - microvms, docker containers etc 
  - [ ] While implementing the cli tool, you could also implement a gateway of sort and expose using an API so that AI agents can provision and manage the sandboxes on demand 

--- 

## AGENT LOGS 
Claude and Other Coding Agents can add their log here :- 
