#!/usr/bin/env bash
# Shared helpers for deploy.sh and destroy.sh. Works with the bash 3.2 that
# ships with macOS; needs only curl and jq.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HETZNER_API="https://api.hetzner.cloud/v1"
CLOUDFLARE_API="https://api.cloudflare.com/client/v4"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
  done
}

load_config() {
  local env_file="${ROOT_DIR}/.env"
  [ -f "$env_file" ] || die "No .env file. Copy .env.example to .env and fill it in."
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a

  local name missing=""
  for name in HCLOUD_TOKEN CLOUDFLARE_API_TOKEN BLOG_HOSTNAME ACCESS_EMAIL; do
    [ -n "${!name:-}" ] || missing="${missing} ${name}"
  done
  [ -z "$missing" ] || die "Missing in .env:${missing}"

  # Optional settings and their defaults.
  PROJECT_NAME="${PROJECT_NAME:-ghost-blog}"
  SERVER_TYPE="${SERVER_TYPE:-cx23}"
  SERVER_LOCATION="${SERVER_LOCATION:-nbg1}"
  SERVER_IMAGE="${SERVER_IMAGE:-ubuntu-24.04}"
  ADMIN_USER="${ADMIN_USER:-deploy}"
  GHOST_IMAGE="${GHOST_IMAGE:-ghost:6-alpine}"
  CLOUDFLARED_IMAGE="${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}"
  SSH_KEY_FILE="${SSH_KEY_FILE:-${HOME}/.ssh/${PROJECT_NAME}_ed25519}"

  # Cloudflare zone = the registrable domain, e.g. example.com for blog.example.com.
  CLOUDFLARE_ZONE="${CLOUDFLARE_ZONE:-$(printf '%s' "$BLOG_HOSTNAME" | awk -F. '{print $(NF-1)"."$NF}')}"
  SSH_HOSTNAME="${SSH_HOSTNAME:-ssh-${PROJECT_NAME}.${CLOUDFLARE_ZONE}}"
}

# api_request <bearer token> <METHOD> <url> [json body]
# Prints the response body. Returns non-zero (body still printed) on HTTP >= 400.
api_request() {
  local token="$1" method="$2" url="$3" body="${4:-}"
  local response status
  if [ -n "$body" ]; then
    response="$(curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
      -w '\n%{http_code}' --data "$body")" || die "Request failed: ${method} ${url}"
  else
    response="$(curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -w '\n%{http_code}')" || die "Request failed: ${method} ${url}"
  fi
  status="$(printf '%s' "$response" | tail -n 1)"
  printf '%s' "$response" | sed '$d'
  [ "$status" -lt 400 ]
}

# hetzner <METHOD> <path> [json body]  — dies with the API's message on error.
hetzner() {
  local out
  if ! out="$(api_request "$HCLOUD_TOKEN" "$1" "${HETZNER_API}$2" "${3:-}")"; then
    die "Hetzner API $1 $2: $(printf '%s' "$out" | jq -r '.error.message // .' 2>/dev/null)"
  fi
  printf '%s' "$out"
}

# cloudflare <METHOD> <path> [json body]  — dies with the API's message on error.
cloudflare() {
  local out
  if ! out="$(api_request "$CLOUDFLARE_API_TOKEN" "$1" "${CLOUDFLARE_API}$2" "${3:-}")"; then
    die "Cloudflare API $1 $2: $(printf '%s' "$out" | jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null)"
  fi
  printf '%s' "$out"
}

# Sets CF_ZONE_ID and CF_ACCOUNT_ID from the zone name.
resolve_cloudflare_zone() {
  local zone
  zone="$(cloudflare GET "/zones?name=${CLOUDFLARE_ZONE}")"
  CF_ZONE_ID="$(printf '%s' "$zone" | jq -r '.result[0].id // empty')"
  # shellcheck disable=SC2034  # used by deploy.sh and destroy.sh
  CF_ACCOUNT_ID="$(printf '%s' "$zone" | jq -r '.result[0].account.id // empty')"
  [ -n "$CF_ZONE_ID" ] || die "Zone '${CLOUDFLARE_ZONE}' not found in Cloudflare (or the API token cannot read it)."
}
