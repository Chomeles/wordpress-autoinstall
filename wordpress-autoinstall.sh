#!/bin/bash

# Define the domain name and directory for WordPress installation
domain="example.com"
wordpress_dir="/var/www/blog"

# Install nginx if it is not already installed
if [ ! -x "$(command -v nginx)" ]; then
  sudo apt-get update
  sudo apt-get install -y nginx
fi

# Install PHP if it is not already installed
if [ ! -x "$(command -v php)" ]; then
  sudo apt-get update
  sudo apt-get install -y php-fpm php-mysql
fi

# Install MariaDB if it is not already installed
if [ ! -x "$(command -v mariadb)" ]; then
  sudo apt-get update
  sudo apt-get install -y mariadb-server
fi

# Secure MariaDB installation
sudo mysql_secure_installation <<EOF

y
password
password
y
y
y
y
EOF

# Create a MariaDB database for WordPress to use
sudo mysql -e "CREATE DATABASE IF NOT EXISTS wordpress_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS 'wordpress_user'@'localhost' IDENTIFIED WITH mysql_native_password BY 'password';"
sudo mysql -e "GRANT ALL PRIVILEGES ON wordpress_db.* TO 'wordpress_user'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Configure WordPress with the necessary database settings
sudo cp $wordpress_dir/wp-config-sample.php $wordpress_dir/wp-config.php
sudo sed -i "s/database_name_here/wordpress_db/" $wordpress_dir/wp-config.php
sudo sed -i "s/username_here/wordpress_user/" $wordpress_dir/wp-config.php
sudo sed -i "s/password_here/password/" $wordpress_dir/wp-config.php
sudo sed -i "/Authentication Unique Keys and Salts/d" $wordpress_dir/wp-config.php
sudo curl -s https://api.wordpress.org/secret-key/1.1/salt/ >> $wordpress_dir/wp-config.php

# Set up nginx virtual host for WordPress
sudo tee /etc/nginx/sites-available/$domain <<EOF
server {
    listen 80;
    server_name $domain www.$domain;

    root $wordpress_dir;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php7.4-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Enable the virtual host
sudo ln -s /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/

# Restart nginx to ensure that the changes take effect
sudo systemctl restart nginx

#!/bin/bash

# Define the domain name and directory for WordPress installation
domain="example.com"
wordpress_dir="/var/www/blog"

# Install nginx if it is not already installed
if [ ! -x "$(command -v nginx)" ]; then
  sudo apt-get update
  sudo apt-get install -y nginx
fi

# Install PHP if it is not already installed
if [ ! -x "$(command -v php)" ]; then
  sudo apt-get update
  sudo apt-get install -y php-fpm php-mysql
fi

# Install MariaDB if it is not already installed
if [ ! -x "$(command -v mariadb)" ]; then
  sudo apt-get update
  sudo apt-get install -y mariadb-server
fi

# Secure MariaDB installation
sudo mysql_secure_installation <<EOF

y
password
password
y
y
y
y
EOF

# Create a MariaDB database for WordPress to use
sudo mysql -e "CREATE DATABASE IF NOT EXISTS wordpress_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS 'wordpress_user'@'localhost' IDENTIFIED WITH mysql_native_password BY 'password';"
sudo mysql -e "GRANT ALL PRIVILEGES ON wordpress_db.* TO 'wordpress_user'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Configure WordPress with the necessary database settings
sudo cp $wordpress_dir/wp-config-sample.php $wordpress_dir/wp-config.php
sudo sed -i "s/database_name_here/wordpress_db/" $wordpress_dir/wp-config.php
sudo sed -i "s/username_here/wordpress_user/" $wordpress_dir/wp-config.php
sudo sed -i "s/password_here/password/" $wordpress_dir/wp-config.php
sudo sed -i "/Authentication Unique Keys and Salts/d" $wordpress_dir/wp-config.php
sudo curl -s https://api.wordpress.org/secret-key/1.1/salt/ >> $wordpress_dir/wp-config.php

# Set up nginx virtual host for WordPress
sudo tee /etc/nginx/sites-available/$domain <<EOF
server {
    listen 80;
    server_name $domain www.$domain;

    root $wordpress_dir;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php7.4-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Enable the virtual host
sudo ln -s /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/

# Restart nginx to ensure that the changes take effect
sudo systemctl restart nginx