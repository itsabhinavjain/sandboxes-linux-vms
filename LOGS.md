Note : This file mentions the various changes that we have implemented over time. It also documents the various design decisions that we have taken. 


## Notes 

*Decision : Networking*
- Try to connect the VM directly to Tailnet. (Simple and preferred)
    - Tailscale SSH vs Normal SSH 
        - Make sure that ssh port is open. I dont want to use Tailscale ssh. This is so that I am not unknowingly get locked out of my machine because of Tailscale configurations. 
- Alternate way could be to connect using host and subrouter. Dont do this yet, unless required to bypass company firewalls. 

*Decision : Cloud-init and indempotent configuration scripts*
- Cloud-Init : 
    - Setting up hostname and timezone 
    - Non root sudo user `abhinav`
        - ssh keys added 
        - adding to groups 
    - Disable root login 
    - Disable login using password (only through keys) 
    - Setup updates, upgrades, unattended updates
- Separate Indempotent Script : 
    - Tailscale
    - UFW 

*Note : Status*
Everything is implemented. Need to start implementing configuration and snapshot related functionalities

*Decision : Autostart settings*
The VMs can be setup so that they autostart when the host linux machine restarts. This is now managed in this repo. 

*Decision : Snapshots - have internal snapshots*
Internal vs. external qcow2 snapshots

Internal snapshots live inside the same qcow2 file as the disk itself. virsh snapshot-create-as vm snap1 adds a snapshot point to vmname.qcow2 directly — no new file, no path changes. Revert (virsh snapshot-revert) and delete are single-file operations libvirt handles atomically.

External snapshots create a new qcow2 file as an overlay (vmname.snap1.qcow2), with the current disk becoming a read-only backing file underneath it. The VM's active disk switches to the new overlay file. This is what STORAGE_POOL_SNAPSHOTS was set up to hold.

Trade-offs:

┌─────────────────────────┬──────────────────────────────────────────────────────┬────────────────────────────────────────────────┐
│                         │                       Internal                       │                    External                    │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│ File management         │ One file, simple                                     │ New file per snapshot, chain grows             │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│ Revert                  │ virsh snapshot-revert, clean                         │ Needs blockcommit/blockpull or manual XML      │
│                         │                                                      │ repointing — more fragile in libvirt           │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│                         │ Yes — disk_path()/state.yaml/05_destroy_vm.sh all       │ No — the "active disk" changes after every     │
│ Fits our scripts        │ assume exactly one qcow2 per VM, unchanged           │ snapshot, which breaks that assumption         │
│                         │                                                      │ throughout common.sh                           │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│ Uses                    │ No (stays empty)                                     │ Yes                                            │
│ STORAGE_POOL_SNAPSHOTS  │                                                      │                                                │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│ Good for                │ Occasional "snapshot before I break this, revert if  │ Portable/prunable backup-style snapshot chains │
│                         │ needed"                                              │                                                │
└─────────────────────────┴──────────────────────────────────────────────────────┴────────────────────────────────────────────────┘

My recommendation: internal. This is a personal sandbox tool, not a backup system — the actual need is "try something risky, revert if it goes wrong," and internal snapshots handle that with far less code and no changes to the disk-path assumptions baked into every script so far. STORAGE_POOL_SNAPSHOTS stays defined but unused for now; I'd note that in the docs rather than rip out the pool, in case external snapshots become worth it later. Happy to build it out this way when we get to Phase 6 — say the word.


*Decision : Use Linux Cloud Images instead of provisioning it from ISO images*
- Option 1 : Using the ISO Images (Installer, Packages, Bootloader)
- Option 2 (Choosing this): Using Cloud Images (`.img` files). Use base images here. 