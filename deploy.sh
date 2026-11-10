#!/usr/bin/env bash
# One-command deployment of a Ghost blog on a Hetzner Cloud server that has
# no inbound ports open. The blog and SSH are reachable only through a
# Cloudflare Tunnel. Safe to run again: existing resources are reused.
#
# Usage: cp .env.example .env   (fill it in)   then   ./deploy.sh

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# ---------------------------------------------------------------- preflight

check_credentials() {
  log "Checking credentials"
  cloudflare GET "/user/tokens/verify" >/dev/null
  resolve_cloudflare_zone
  info "Cloudflare zone ${CLOUDFLARE_ZONE} found"

  local server_type
  server_type="$(hetzner GET "/server_types?name=${SERVER_TYPE}")"
  [ "$(printf '%s' "$server_type" | jq '.server_types | length')" -gt 0 ] \
    || die "Hetzner server type '${SERVER_TYPE}' does not exist. Set SERVER_TYPE in .env."
  info "Hetzner token works, server type ${SERVER_TYPE} exists"
}

# --------------------------------------------------------------- Cloudflare

# Prints the tunnel id, creating the tunnel if needed.
ensure_tunnel() {
  local tunnels tunnel_id body
  tunnels="$(cloudflare GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${PROJECT_NAME}&is_deleted=false")"
  tunnel_id="$(printf '%s' "$tunnels" | jq -r '.result[0].id // empty')"
  if [ -z "$tunnel_id" ]; then
    body="$(jq -n --arg name "$PROJECT_NAME" '{name: $name, config_src: "cloudflare"}')"
    tunnel_id="$(cloudflare POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" "$body" | jq -r '.result.id')"
    info "Created tunnel ${PROJECT_NAME}"
  else
    info "Reusing tunnel ${PROJECT_NAME}"
  fi
  printf '%s' "$tunnel_id"
}

# Tells Cloudflare where each public hostname goes on the server.
configure_tunnel_routes() {
  local tunnel_id="$1" body
  body="$(jq -n --arg blog "$BLOG_HOSTNAME" --arg ssh "$SSH_HOSTNAME" '{
    config: {ingress: [
      {hostname: $blog, service: "http://localhost:8080"},
      {hostname: $ssh,  service: "ssh://localhost:22"},
      {service: "http_status:404"}
    ]}
  }')"
  cloudflare PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" "$body" >/dev/null
}

# Points a hostname at the tunnel (creates or updates the DNS record).
ensure_dns_record() {
  local hostname="$1" tunnel_id="$2" record_id body
  body="$(jq -n --arg name "$hostname" --arg target "${tunnel_id}.cfargotunnel.com" \
    '{type: "CNAME", name: $name, content: $target, proxied: true, ttl: 1}')"
  record_id="$(cloudflare GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${hostname}" \
    | jq -r '.result[0].id // empty')"
  if [ -n "$record_id" ]; then
    cloudflare PUT "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$body" >/dev/null
  else
    cloudflare POST "/zones/${CF_ZONE_ID}/dns_records" "$body" >/dev/null
  fi
  info "DNS: ${hostname} -> tunnel"
}

# Puts the SSH hostname behind Cloudflare Access: only ACCESS_EMAIL can even
# open a connection to sshd; the SSH key is still required after that.
ensure_ssh_access_policy() {
  local apps policy_name policy_id body
  apps="$(cloudflare GET "/accounts/${CF_ACCOUNT_ID}/access/apps")"
  if printf '%s' "$apps" | jq -e --arg d "$SSH_HOSTNAME" '.result[]? | select(.domain == $d)' >/dev/null; then
    info "Reusing Access application for ${SSH_HOSTNAME}"
    return
  fi

  policy_name="${PROJECT_NAME}-ssh-admins"
  policy_id="$(cloudflare GET "/accounts/${CF_ACCOUNT_ID}/access/policies" \
    | jq -r --arg n "$policy_name" '[.result[]? | select(.name == $n)][0].id // empty')"
  if [ -z "$policy_id" ]; then
    body="$(jq -n --arg n "$policy_name" --arg email "$ACCESS_EMAIL" \
      '{name: $n, decision: "allow", include: [{email: {email: $email}}]}')"
    policy_id="$(cloudflare POST "/accounts/${CF_ACCOUNT_ID}/access/policies" "$body" | jq -r '.result.id')"
  fi

  body="$(jq -n --arg n "${PROJECT_NAME} SSH" --arg d "$SSH_HOSTNAME" --arg p "$policy_id" \
    '{name: $n, domain: $d, type: "self_hosted", session_duration: "24h",
      policies: [{id: $p, precedence: 1}]}')"
  cloudflare POST "/accounts/${CF_ACCOUNT_ID}/access/apps" "$body" >/dev/null
  info "Access: only ${ACCESS_EMAIL} may open ${SSH_HOSTNAME}"
}

# ------------------------------------------------------------------ Hetzner

ensure_local_ssh_key() {
  if [ ! -f "$SSH_KEY_FILE" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "$PROJECT_NAME" -f "$SSH_KEY_FILE"
    info "Created SSH key ${SSH_KEY_FILE}"
  fi
  [ -f "${SSH_KEY_FILE}.pub" ] || die "Public key ${SSH_KEY_FILE}.pub not found."
}

# Prints the Hetzner id of our SSH key, uploading it if needed. Supplying a
# key stops Hetzner from generating a root password and emailing it.
ensure_hetzner_ssh_key() {
  local fingerprint key_id body
  fingerprint="$(ssh-keygen -E md5 -lf "${SSH_KEY_FILE}.pub" | awk '{print $2}' | sed 's/^MD5://')"
  key_id="$(hetzner GET "/ssh_keys?fingerprint=${fingerprint}" | jq -r '.ssh_keys[0].id // empty')"
  if [ -z "$key_id" ]; then
    body="$(jq -n --arg n "$PROJECT_NAME" --arg k "$(cat "${SSH_KEY_FILE}.pub")" '{name: $n, public_key: $k}')"
    key_id="$(hetzner POST "/ssh_keys" "$body" | jq -r '.ssh_key.id')"
  fi
  printf '%s' "$key_id"
}

# Prints the id of a firewall with no inbound rules. Hetzner drops all
# inbound traffic for such a firewall and still allows all outbound.
ensure_closed_firewall() {
  local firewall_id body
  firewall_id="$(hetzner GET "/firewalls?name=${PROJECT_NAME}" | jq -r '.firewalls[0].id // empty')"
  if [ -z "$firewall_id" ]; then
    body="$(jq -n --arg n "$PROJECT_NAME" '{name: $n, rules: []}')"
    firewall_id="$(hetzner POST "/firewalls" "$body" | jq -r '.firewall.id')"
    info "Created firewall ${PROJECT_NAME} (no inbound rules)"
  fi
  printf '%s' "$firewall_id"
}

escape_for_sed() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Prints the first-boot configuration with all placeholders filled in.
render_cloud_init() {
  local tunnel_token="$1" compose_b64
  compose_b64="$(base64 < "${ROOT_DIR}/server/docker-compose.yml" | tr -d '\n')"
  sed \
    -e "s|__ADMIN_USER__|$(escape_for_sed "$ADMIN_USER")|g" \
    -e "s|__SSH_PUBLIC_KEY__|$(escape_for_sed "$(cat "${SSH_KEY_FILE}.pub")")|g" \
    -e "s|__COMPOSE_FILE_B64__|${compose_b64}|g" \
    -e "s|__GHOST_IMAGE__|$(escape_for_sed "$GHOST_IMAGE")|g" \
    -e "s|__CLOUDFLARED_IMAGE__|$(escape_for_sed "$CLOUDFLARED_IMAGE")|g" \
    -e "s|__BLOG_HOSTNAME__|$(escape_for_sed "$BLOG_HOSTNAME")|g" \
    -e "s|__TUNNEL_TOKEN__|$(escape_for_sed "$tunnel_token")|g" \
    "${ROOT_DIR}/server/cloud-init.yaml.tpl"
}

ensure_server() {
  local tunnel_token="$1" ssh_key_id="$2" firewall_id="$3" existing body
  existing="$(hetzner GET "/servers?name=${PROJECT_NAME}" | jq -r '.servers[0].id // empty')"
  if [ -n "$existing" ]; then
    info "Server ${PROJECT_NAME} already exists; leaving it as it is"
    return
  fi

  body="$(jq -n \
    --arg name "$PROJECT_NAME" --arg type "$SERVER_TYPE" --arg image "$SERVER_IMAGE" \
    --arg location "$SERVER_LOCATION" --arg user_data "$(render_cloud_init "$tunnel_token")" \
    --argjson ssh_key "$ssh_key_id" --argjson firewall "$firewall_id" '{
      name: $name, server_type: $type, image: $image, location: $location,
      ssh_keys: [$ssh_key], firewalls: [{firewall: $firewall}],
      user_data: $user_data, labels: {project: $name}
    }')"
  hetzner POST "/servers" "$body" >/dev/null
  info "Created server ${PROJECT_NAME} (${SERVER_TYPE}, ${SERVER_LOCATION})"
}

# ------------------------------------------------------------------- finish

wait_for_blog() {
  local url="https://${BLOG_HOSTNAME}/" attempts=90 status
  log "Waiting for ${url} (first boot installs everything; usually 3-6 minutes)"
  while [ "$attempts" -gt 0 ]; do
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"
    [ "$status" = "200" ] && return 0
    printf '.' >&2
    sleep 10
    attempts=$((attempts - 1))
  done
  printf '\n' >&2
  die "The blog did not answer within 15 minutes (last status: ${status}). See Troubleshooting in the README."
}

write_ssh_config() {
  cat > "${ROOT_DIR}/ssh_config" <<CONFIG
Host ${SSH_HOSTNAME}
  User ${ADMIN_USER}
  IdentityFile ${SSH_KEY_FILE}
  IdentitiesOnly yes
  ProxyCommand cloudflared access ssh --hostname %h
CONFIG
}

print_summary() {
  cat >&2 <<SUMMARY

$(printf '\033[1;32mDone.\033[0m')

  Blog:        https://${BLOG_HOSTNAME}/
  Admin setup: https://${BLOG_HOSTNAME}/ghost/   <- open now and create the owner account
  SSH:         ssh -F ssh_config ${SSH_HOSTNAME}
               (needs cloudflared on this machine; a browser opens to log in as ${ACCESS_EMAIL})

SUMMARY
}

main() {
  require_commands curl jq ssh-keygen base64
  load_config
  check_credentials

  log "Cloudflare: tunnel, DNS and SSH access policy"
  local tunnel_id tunnel_token
  tunnel_id="$(ensure_tunnel)"
  configure_tunnel_routes "$tunnel_id"
  ensure_dns_record "$BLOG_HOSTNAME" "$tunnel_id"
  ensure_dns_record "$SSH_HOSTNAME" "$tunnel_id"
  ensure_ssh_access_policy
  tunnel_token="$(cloudflare GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token" | jq -r '.result')"

  log "Hetzner: SSH key, firewall and server"
  local ssh_key_id firewall_id
  ensure_local_ssh_key
  ssh_key_id="$(ensure_hetzner_ssh_key)"
  firewall_id="$(ensure_closed_firewall)"
  ensure_server "$tunnel_token" "$ssh_key_id" "$firewall_id"

  wait_for_blog
  write_ssh_config
  print_summary
}

# Run only when executed, so the functions can be sourced for testing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
