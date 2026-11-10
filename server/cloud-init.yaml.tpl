#cloud-config
# First-boot setup for the Ghost server. Rendered by deploy.sh, which replaces
# the placeholder values, and passed to Hetzner as user data. Nothing
# connects to the server to install it: it configures itself and then dials
# out to Cloudflare.

package_update: true
package_upgrade: true
packages:
  - docker.io
  - docker-compose-v2
  - ufw
  - unattended-upgrades

# One unprivileged admin user, key-only. Root cannot log in at all.
users:
  - name: __ADMIN_USER__
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - __SSH_PUBLIC_KEY__
disable_root: true
ssh_pwauth: false

write_files:
  # sshd listens on loopback only. The only way to reach it is through the
  # cloudflared process on this machine, i.e. through the tunnel.
  - path: /etc/ssh/sshd_config.d/10-tunnel-only.conf
    permissions: "0644"
    content: |
      ListenAddress 127.0.0.1
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      AllowUsers __ADMIN_USER__

  - path: /opt/ghost/docker-compose.yml
    permissions: "0644"
    encoding: b64
    content: __COMPOSE_FILE_B64__

  # Values known at deploy time. Database passwords are NOT here: they are
  # generated on the server below and never leave it.
  - path: /opt/ghost/deploy.env
    permissions: "0600"
    content: |
      COMPOSE_PROFILES=tunnel
      GHOST_IMAGE=__GHOST_IMAGE__
      CLOUDFLARED_IMAGE=__CLOUDFLARED_IMAGE__
      GHOST_URL=https://__BLOG_HOSTNAME__
      TUNNEL_TOKEN=__TUNNEL_TOKEN__

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    permissions: "0644"
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

runcmd:
  # Second layer behind the Hetzner Cloud Firewall: deny all inbound on the host too.
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw --force enable

  # Apply the loopback-only sshd config (Ubuntu 24.04 uses socket activation,
  # so the socket unit has to be regenerated as well).
  - systemctl daemon-reload
  - systemctl restart ssh.socket || true
  - systemctl restart ssh.service || true

  # Generate database passwords once; keep them on re-runs of cloud-init.
  - |
    if [ ! -f /opt/ghost/.env ]; then
      umask 077
      {
        cat /opt/ghost/deploy.env
        echo "DB_PASSWORD=$(openssl rand -hex 24)"
        echo "DB_ROOT_PASSWORD=$(openssl rand -hex 24)"
      } > /opt/ghost/.env
      rm -f /opt/ghost/deploy.env
    fi

  - systemctl enable --now docker
  - cd /opt/ghost && docker compose up -d
