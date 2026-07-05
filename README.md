# wordpress-autoinstall
Autoinstallation script for WordPress with nginx, PHP-FPM, MariaDB and a Let's Encrypt SSL certificate.

The script is idempotent — it can safely be re-run and will keep an existing installation (including its database password) intact.

## Usage

```bash
curl -O https://raw.githubusercontent.com/Chomeles/wordpress-autoinstall/main/wordpress-autoinstall.sh
chmod +x wordpress-autoinstall.sh
DOMAIN=blog.example.com ADMIN_EMAIL=you@example.com ./wordpress-autoinstall.sh
```

Run it as root or as a user with sudo. When it finishes, open `https://your-domain` and complete the WordPress setup in the browser. The generated database password is printed at the end and stored in `wp-config.php`.

## Configuration

All settings are optional environment variables:

| Variable      | Default                 | Description                                  |
|---------------|-------------------------|----------------------------------------------|
| `DOMAIN`      | `example.com`           | Your domain (required for the SSL certificate) |
| `ADMIN_EMAIL` | `admin@$DOMAIN`         | E-mail for Let's Encrypt expiry notices      |
| `WP_DIR`      | `/var/www/blog`         | WordPress installation directory             |
| `DB_NAME`     | `wordpress_db`          | MariaDB database name                        |
| `DB_USER`     | `wordpress_user`        | MariaDB user name                            |

If `DOMAIN` is left at its default, the SSL step is skipped and the site is served over HTTP. If certbot fails (e.g. DNS not pointing at the server yet), the installation still completes and certbot can simply be re-run later.
