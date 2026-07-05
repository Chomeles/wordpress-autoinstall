#!/bin/bash
set -euo pipefail
trap 'echo "ERROR: installation failed at line $LINENO" >&2' ERR

# Configuration (override via environment variables, e.g. DOMAIN=blog.example.com ./wordpress-autoinstall.sh)
domain="${DOMAIN:-example.com}"
wordpress_dir="${WP_DIR:-/var/www/blog}"
admin_email="${ADMIN_EMAIL:-admin@${domain}}"
db_name="${DB_NAME:-wordpress_db}"
db_user="${DB_USER:-wordpress_user}"

# Allow running either as root (no sudo needed, e.g. minimal VPS images or
# containers) or as a regular user with sudo
if [ "$(id -u)" -eq 0 ]; then
  # env(1) handles VAR=value prefixes the same way sudo does
  sudo() { env "$@"; }
elif ! command -v sudo >/dev/null; then
  echo "ERROR: run this script as root or install sudo first" >&2
  exit 1
fi

# Start and enable a service, falling back to init scripts where systemd is
# not running (e.g. inside containers)
start_service() {
  if [ -d /run/systemd/system ]; then
    sudo systemctl enable --now "$1"
  else
    sudo service "$1" start
  fi
}

echo "==> Installing packages"
# Collect all missing packages and install them in a single apt run
packages=()
command -v nginx   >/dev/null || packages+=(nginx)
# Check for the FPM binary, not the CLI — systems can have the php CLI
# installed without PHP-FPM
compgen -G '/usr/sbin/php-fpm*' >/dev/null || packages+=(php-fpm php-mysql)
command -v mariadb >/dev/null || packages+=(mariadb-server)
command -v certbot >/dev/null || packages+=(certbot python3-certbot-nginx)
command -v curl    >/dev/null || packages+=(curl)

if [ "${#packages[@]}" -gt 0 ]; then
  # --allow-releaseinfo-change keeps a repository whose metadata changed
  # (e.g. a renamed PPA label) from aborting the whole installation
  sudo apt-get update --allow-releaseinfo-change
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
fi

# Detect the installed PHP-FPM version from the FPM binary itself instead of
# hardcoding one (the CLI can be a different version, or missing entirely)
php_version="$(compgen -G '/usr/sbin/php-fpm*' | sort -V | tail -1 | sed 's|.*/php-fpm||')"
php_socket="/run/php/php${php_version}-fpm.sock"

start_service mariadb
start_service "php${php_version}-fpm"

# Make sure PHP-FPM is actually listening before nginx gets pointed at its
# socket — a silently failed service start would surface as 502 errors later.
# If the init system could not bring it up (some containers), launch the
# daemon directly.
if [ ! -S "$php_socket" ]; then
  sudo mkdir -p /run/php
  sudo "/usr/sbin/php-fpm${php_version}" --daemonize || true
  for _ in 1 2 3 4 5; do
    [ -S "$php_socket" ] && break
    sleep 1
  done
fi
if [ ! -S "$php_socket" ]; then
  echo "ERROR: PHP-FPM socket $php_socket did not appear" >&2
  exit 1
fi

echo "==> Securing MariaDB"
# Secure MariaDB non-interactively (replaces the fragile
# mysql_secure_installation heredoc, whose prompts differ between versions)
sudo mysql <<'EOF'
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
EOF

echo "==> Setting up WordPress in $wordpress_dir"
# Download and extract WordPress if it is not already present
if [ ! -f "$wordpress_dir/wp-load.php" ]; then
  sudo mkdir -p "$wordpress_dir"
  curl -fsSL https://wordpress.org/latest.tar.gz | sudo tar -xz --strip-components=1 -C "$wordpress_dir"
fi

# On re-runs keep the existing database password so a working site is never
# broken; otherwise generate a random one (finite pipe input — reading
# /dev/urandom straight into head dies of SIGPIPE under pipefail)
if [ -f "$wordpress_dir/wp-config.php" ]; then
  db_password="$(sudo grep -oP "define\(\s*'DB_PASSWORD',\s*'\K[^']+" "$wordpress_dir/wp-config.php")"
else
  db_password="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"

  # Configure WordPress with the necessary database settings
  sudo cp "$wordpress_dir/wp-config-sample.php" "$wordpress_dir/wp-config.php"
  sudo sed -i "s/database_name_here/${db_name}/" "$wordpress_dir/wp-config.php"
  sudo sed -i "s/username_here/${db_user}/" "$wordpress_dir/wp-config.php"
  sudo sed -i "s/password_here/${db_password}/" "$wordpress_dir/wp-config.php"

  # Replace the placeholder salts with fresh ones from the WordPress API
  salts="$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/)"
  sudo sed -i "/put your unique phrase here/d" "$wordpress_dir/wp-config.php"
  printf '%s\n' "$salts" | sudo tee -a "$wordpress_dir/wp-config.php" >/dev/null
fi

echo "==> Creating database"
sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF

sudo chown -R www-data:www-data "$wordpress_dir"
sudo find "$wordpress_dir" -type d -exec chmod 755 {} +
sudo find "$wordpress_dir" -type f -exec chmod 644 {} +
# wp-config.php contains the database credentials — keep it out of reach of
# other local users
sudo chmod 640 "$wordpress_dir/wp-config.php"

echo "==> Configuring nginx"
# Only listen on IPv6 where the kernel actually supports it — nginx refuses
# to start otherwise
ipv6_listen=""
[ -f /proc/net/if_inet6 ] && ipv6_listen="listen [::]:80;"

# Set up nginx virtual host for WordPress
sudo tee "/etc/nginx/sites-available/$domain" >/dev/null <<EOF
server {
    listen 80;
    $ipv6_listen
    server_name $domain www.$domain;

    root $wordpress_dir;
    index index.php index.html index.htm;

    server_tokens off;
    client_max_body_size 64m;

    # Compress text-based responses
    gzip on;
    gzip_vary on;
    gzip_types text/css text/javascript application/javascript application/json image/svg+xml;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$php_socket;
    }

    # Cache static assets in the browser
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|webp|woff2?)\$ {
        expires 30d;
        access_log off;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Enable the virtual host (idempotent) and remove the distro default site
sudo ln -sf "/etc/nginx/sites-available/$domain" /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Validate the configuration before applying it, and reload instead of a full
# restart so existing connections are not dropped
sudo nginx -t
start_service nginx
sudo nginx -s reload

# Obtain an SSL/TLS certificate from Let's Encrypt. A failure here (DNS not
# pointing at this server yet, firewall, rate limits) should not throw away
# the finished installation — the site still works over HTTP and certbot can
# simply be re-run later.
if [ "$domain" = "example.com" ]; then
  echo "==> Skipping SSL: set DOMAIN=your-domain.com to request a certificate"
elif sudo certbot --nginx --non-interactive --agree-tos --redirect --hsts \
    --email "$admin_email" -d "$domain" -d "www.$domain"; then
  # Set up automatic renewal of the certificate
  if [ -d /run/systemd/system ]; then
    sudo systemctl enable --now certbot.timer
  fi
else
  echo "WARNING: certbot failed — the site is reachable over HTTP only." >&2
  echo "Once DNS for $domain points at this server, run:" >&2
  echo "  sudo certbot --nginx --agree-tos --redirect --hsts --email $admin_email -d $domain -d www.$domain" >&2
fi

echo
echo "WordPress is ready: http://$domain (finish the setup in your browser)"
echo "Database:           $db_name"
echo "Database user:      $db_user"
echo "Database password:  $db_password  (also stored in $wordpress_dir/wp-config.php)"
