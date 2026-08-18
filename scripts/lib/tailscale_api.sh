#!/usr/bin/env bash
# Tailscale API helpers -- sourced only by 04_destroy_vm.sh, to deregister a
# VM's device from the tailnet on teardown via a scoped OAuth client. This
# is what makes a destroy-then-recreate-with-the-same-name cycle reliably
# reclaim the same hostname, instead of racing Tailscale's own
# ephemeral-node cleanup (which runs on its own schedule, not tied to when
# this toolkit actually deletes the VM). See DECISIONS.md ("Decision :
# Tailscale device cleanup on destroy").
#
# Requires: curl, jq -- both only exercised if TAILSCALE_API_CLIENT_ID/
# TAILSCALE_API_CLIENT_SECRET are set. Every function here is best-effort:
# it returns non-zero / logs and returns 0 on failure rather than dying, so
# a Tailscale API hiccup (network blip, bad creds, missing jq) never blocks
# a local VM teardown that has already happened.

TAILSCALE_API_BASE="https://api.tailscale.com/api/v2"

# tailscale_api_configured -- true if both OAuth client credentials are set.
tailscale_api_configured() {
    [[ -n "${TAILSCALE_API_CLIENT_ID:-}" && -n "${TAILSCALE_API_CLIENT_SECRET:-}" ]]
}

# tailscale_api_get_token -- exchanges the OAuth client credentials for a
# short-lived access token (client_credentials grant). Echoes the token on
# success; returns non-zero on any failure (network, bad creds, no jq).
tailscale_api_get_token() {
    command -v jq >/dev/null 2>&1 || return 1
    local response token
    response="$(curl -sS -f -X POST "${TAILSCALE_API_BASE}/oauth/token" \
        -d "client_id=${TAILSCALE_API_CLIENT_ID}" \
        -d "client_secret=${TAILSCALE_API_CLIENT_SECRET}" 2>/dev/null)" || return 1
    token="$(jq -r '.access_token // empty' <<<"$response" 2>/dev/null)" || return 1
    [[ -n "$token" ]] || return 1
    echo "$token"
}

# tailscale_api_find_device_id <token> <hostname> -- looks up a device's ID
# by its Tailscale hostname (the name set via `tailscale up --hostname=...`,
# i.e. our VMNAME -- not the FQDN). Echoes the ID if found; returns non-zero
# if not found or the lookup itself failed.
tailscale_api_find_device_id() {
    local token="$1" hostname="$2" response id
    response="$(curl -sS -f -H "Authorization: Bearer ${token}" \
        "${TAILSCALE_API_BASE}/tailnet/-/devices" 2>/dev/null)" || return 1
    id="$(jq -r --arg h "$hostname" '.devices[]? | select(.hostname == $h) | .id' <<<"$response" 2>/dev/null | head -n1)"
    [[ -n "$id" ]] || return 1
    echo "$id"
}

# tailscale_api_delete_device <token> <device-id>
tailscale_api_delete_device() {
    local token="$1" device_id="$2"
    curl -sS -f -X DELETE -H "Authorization: Bearer ${token}" \
        "${TAILSCALE_API_BASE}/device/${device_id}" >/dev/null 2>&1
}

# tailscale_deregister_vm <vmname> -- best-effort end-to-end: get a token,
# find the device by hostname, delete it. Always logs what happened (or why
# it was skipped) and always returns 0 -- this must never fail the caller.
tailscale_deregister_vm() {
    local vmname="$1" token device_id

    if ! tailscale_api_configured; then
        log "Tailscale API credentials not set (TAILSCALE_API_CLIENT_ID/TAILSCALE_API_CLIENT_SECRET) -- skipping tailnet device cleanup. The device, if any, will only be removed by Tailscale's own ephemeral-node cleanup, on its own schedule."
        return 0
    fi

    token="$(tailscale_api_get_token)" || {
        log "Could not get a Tailscale API access token (check TAILSCALE_API_CLIENT_ID/_SECRET, network, and that jq is installed) -- skipping tailnet device cleanup."
        return 0
    }

    device_id="$(tailscale_api_find_device_id "$token" "$vmname")" || {
        log "No tailnet device found for hostname '$vmname' -- nothing to clean up."
        return 0
    }

    if tailscale_api_delete_device "$token" "$device_id"; then
        log "Removed tailnet device '$vmname' (id: $device_id)."
    else
        log "Found tailnet device '$vmname' (id: $device_id) but failed to delete it -- you may need to remove it manually at https://login.tailscale.com/admin/machines"
    fi
}
