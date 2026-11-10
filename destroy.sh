#!/usr/bin/env bash
# Removes everything deploy.sh created: the server (and all blog data on it),
# firewall, uploaded SSH key, DNS records, Access application and tunnel.
# The local SSH key file is kept.
#
# Usage: ./destroy.sh          (asks for confirmation)
#        ./destroy.sh --yes

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

confirm() {
  [ "${1:-}" = "--yes" ] && return
  printf 'This deletes the server "%s" and ALL blog content on it.\nType the project name to continue: ' "$PROJECT_NAME" >&2
  local answer
  read -r answer
  [ "$answer" = "$PROJECT_NAME" ] || die "Aborted."
}

delete_server() {
  local server_id
  server_id="$(hetzner GET "/servers?name=${PROJECT_NAME}" | jq -r '.servers[0].id // empty')"
  [ -n "$server_id" ] || return 0
  hetzner DELETE "/servers/${server_id}" >/dev/null
  info "Deleted server"
}

# A firewall cannot be deleted while it is still attached to a server that
# is being removed, so retry for a short while.
delete_firewall() {
  local firewall_id attempts=12
  firewall_id="$(hetzner GET "/firewalls?name=${PROJECT_NAME}" | jq -r '.firewalls[0].id // empty')"
  [ -n "$firewall_id" ] || return 0
  while [ "$attempts" -gt 0 ]; do
    if api_request "$HCLOUD_TOKEN" DELETE "${HETZNER_API}/firewalls/${firewall_id}" >/dev/null; then
      info "Deleted firewall"
      return 0
    fi
    sleep 5
    attempts=$((attempts - 1))
  done
  die "Could not delete firewall ${PROJECT_NAME}; delete it in the Hetzner console."
}

delete_hetzner_ssh_key() {
  local key_id
  key_id="$(hetzner GET "/ssh_keys?name=${PROJECT_NAME}" | jq -r '.ssh_keys[0].id // empty')"
  [ -n "$key_id" ] || return 0
  hetzner DELETE "/ssh_keys/${key_id}" >/dev/null
  info "Deleted uploaded SSH key"
}

# Deletes a DNS record only if it points at our tunnel.
delete_dns_record() {
  local hostname="$1" tunnel_id="$2" record_id
  record_id="$(cloudflare GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${hostname}" \
    | jq -r --arg t "${tunnel_id}.cfargotunnel.com" '[.result[]? | select(.content == $t)][0].id // empty')"
  [ -n "$record_id" ] || return 0
  cloudflare DELETE "/zones/${CF_ZONE_ID}/dns_records/${record_id}" >/dev/null
  info "Deleted DNS record ${hostname}"
}

delete_ssh_access_policy() {
  local app_id policy_id
  app_id="$(cloudflare GET "/accounts/${CF_ACCOUNT_ID}/access/apps" \
    | jq -r --arg d "$SSH_HOSTNAME" '[.result[]? | select(.domain == $d)][0].id // empty')"
  if [ -n "$app_id" ]; then
    cloudflare DELETE "/accounts/${CF_ACCOUNT_ID}/access/apps/${app_id}" >/dev/null
    info "Deleted Access application"
  fi
  policy_id="$(cloudflare GET "/accounts/${CF_ACCOUNT_ID}/access/policies" \
    | jq -r --arg n "${PROJECT_NAME}-ssh-admins" '[.result[]? | select(.name == $n)][0].id // empty')"
  if [ -n "$policy_id" ]; then
    cloudflare DELETE "/accounts/${CF_ACCOUNT_ID}/access/policies/${policy_id}" >/dev/null
    info "Deleted Access policy"
  fi
}

delete_tunnel() {
  local tunnel_id="$1"
  # A tunnel with live connections cannot be deleted; drop them first.
  cloudflare DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/connections" >/dev/null
  cloudflare DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}" >/dev/null
  info "Deleted tunnel"
}

main() {
  require_commands curl jq
  load_config
  confirm "${1:-}"

  log "Hetzner"
  delete_server
  delete_firewall
  delete_hetzner_ssh_key

  log "Cloudflare"
  resolve_cloudflare_zone
  local tunnel_id
  tunnel_id="$(cloudflare GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${PROJECT_NAME}&is_deleted=false" \
    | jq -r '.result[0].id // empty')"
  delete_ssh_access_policy
  if [ -n "$tunnel_id" ]; then
    delete_dns_record "$BLOG_HOSTNAME" "$tunnel_id"
    delete_dns_record "$SSH_HOSTNAME" "$tunnel_id"
    delete_tunnel "$tunnel_id"
  fi
  rm -f "${ROOT_DIR}/ssh_config"
  log "Everything removed."
}

# Run only when executed, so the functions can be sourced for testing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
