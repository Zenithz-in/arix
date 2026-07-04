#!/bin/bash
set -e

echo "================================================"
echo "   Arix Theme Auto-Installer"
echo "================================================"

cd /var/www/pterodactyl || {
    echo "Error: /var/www/pterodactyl folder not found!"
    exit 1
}

echo "-> Installing dependencies..."
apt update
apt install -y ca-certificates curl git gnupg unzip wget zip

echo "-> Downloading theme..."
wget -q https://github.com/ArainCloud07/arix-craked/raw/refs/heads/main/pterodactyl.zip -O pterodactyl.zip

echo "-> Extracting theme..."
unzip -o pterodactyl.zip

if [ -d "pterodactyl" ]; then
    cp -rf pterodactyl/* .
    rm -rf pterodactyl
fi

rm -f pterodactyl.zip

if ! command -v node >/dev/null 2>&1; then
    echo "-> Installing Node.js 22..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list

    apt update
    apt install -y nodejs
fi

echo "-> Installing Yarn..."
npm install -g yarn

echo "-> Installing Node packages..."
yarn install

echo "-> Running Arix installer..."
php artisan arix install

echo "-> Clearing caches..."
php artisan view:clear
php artisan optimize:clear

echo "-> Setting permissions..."
chown -R www-data:www-data /var/www/pterodactyl
find /var/www/pterodactyl -type d -exec chmod 755 {} \;
find /var/www/pterodactyl -type f -exec chmod 644 {} \;
chmod -R 775 storage bootstrap/cache

echo "========================================"
echo "Arix Theme installation completed!"
echo "========================================"
