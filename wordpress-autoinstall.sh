#!/bin/bash
set -euo pipefail

# Configuration (override via environment variables, e.g. DOMAIN=blog.example.com ./wordpress-autoinstall.sh)
domain="${DOMAIN:-example.com}"
wordpress_dir="${WP_DIR:-/var/www/blog}"
admin_email="${ADMIN_EMAIL:-your-email@example.com}"
db_name="${DB_NAME:-wordpress_db}"
db_user="${DB_USER:-wordpress_user}"

# Generate a random database password instead of shipping a hardcoded one
db_password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

# Collect all missing packages and install them in a single apt run
packages=()
command -v nginx   >/dev/null || packages+=(nginx)
command -v php     >/dev/null || packages+=(php-fpm php-mysql)
command -v mariadb >/dev/null || packages+=(mariadb-server)
command -v certbot >/dev/null || packages+=(certbot python3-certbot-nginx)
command -v curl    >/dev/null || packages+=(curl)

if [ "${#packages[@]}" -gt 0 ]; then
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
fi

# Secure MariaDB non-interactively (replaces the fragile mysql_secure_installation heredoc,
# whose prompts differ between versions)
sudo mysql <<'EOF'
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
EOF

# Create a MariaDB database and user for WordPress
sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Download and extract WordPress if it is not already present
if [ ! -f "$wordpress_dir/wp-load.php" ]; then
  sudo mkdir -p "$wordpress_dir"
  curl -fsSL https://wordpress.org/latest.tar.gz | sudo tar -xz --strip-components=1 -C "$wordpress_dir"
fi

# Configure WordPress with the necessary database settings
sudo cp "$wordpress_dir/wp-config-sample.php" "$wordpress_dir/wp-config.php"
sudo sed -i "s/database_name_here/${db_name}/" "$wordpress_dir/wp-config.php"
sudo sed -i "s/username_here/${db_user}/" "$wordpress_dir/wp-config.php"
sudo sed -i "s/password_here/${db_password}/" "$wordpress_dir/wp-config.php"

# Replace the placeholder salts with fresh ones from the WordPress API
salts="$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/)"
sudo sed -i "/put your unique phrase here/d" "$wordpress_dir/wp-config.php"
printf '%s\n' "$salts" | sudo tee -a "$wordpress_dir/wp-config.php" >/dev/null

sudo chown -R www-data:www-data "$wordpress_dir"
sudo find "$wordpress_dir" -type d -exec chmod 755 {} +
sudo find "$wordpress_dir" -type f -exec chmod 644 {} +

# Detect the installed PHP-FPM socket instead of hardcoding php7.4
php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
php_socket="/run/php/php${php_version}-fpm.sock"

# Set up nginx virtual host for WordPress
sudo tee "/etc/nginx/sites-available/$domain" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain www.$domain;

    root $wordpress_dir;
    index index.php index.html index.htm;

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

# Validate the configuration before reloading, and reload instead of a full
# restart so existing connections are not dropped
sudo nginx -t
sudo systemctl reload nginx

# Obtain SSL/TLS certificate from Let's Encrypt
sudo certbot --nginx --non-interactive --agree-tos --redirect --hsts --staple-ocsp \
  --email "$admin_email" -d "$domain" -d "www.$domain"

# Set up automatic renewal of SSL/TLS certificate
sudo systemctl enable --now certbot.timer

echo
echo "WordPress is ready: https://$domain"
echo "Database:          $db_name"
echo "Database user:     $db_user"
echo "Database password: $db_password  (also stored in $wordpress_dir/wp-config.php)"
