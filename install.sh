#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# ZENITHZ ARIX PTERODACTYL SAFE REINSTALLER
#
# SAFETY:
#   - NEVER stops SSH
#   - NEVER modifies SSH configuration
#   - NEVER touches /var/lib/pterodactyl
#   - NEVER deletes the live panel before the new ZIP is validated
#   - Keeps a rollback copy of the old panel
#   - Keeps the database dump until the script completes
#   - Attempts automatic rollback on failure
# ============================================================

PANEL="/var/www/pterodactyl"

TMP="/tmp/zenithz-ptero"
DOWNLOAD="$TMP/pterodactyl.zip"
EXTRACTED="$TMP/extracted"
DUMP="$TMP/database.sql"
OLD_PANEL="$TMP/old-panel"

PANEL_URL="https://github.com/Zenithz-in/arix/raw/refs/heads/main/pterodactyl.zip"

PHP_BIN="/usr/bin/php"
PHP_SERVICE="php8.3-fpm"

PTEROQ_SERVICE="pteroq"

ROLLBACK_NEEDED=0
OLD_PANEL_MOVED=0

# ============================================================
# LOGGING
# ============================================================

log() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

# ============================================================
# CLEANUP / ROLLBACK
# ============================================================

cleanup() {

    local EXIT_CODE=$?

    # --------------------------------------------------------
    # IMPORTANT:
    # Never touch SSH here.
    # --------------------------------------------------------

    if [ "$EXIT_CODE" -ne 0 ] && [ "$ROLLBACK_NEEDED" -eq 1 ]; then

        echo
        echo "============================================================"
        echo "                 INSTALLATION FAILED"
        echo "                 STARTING ROLLBACK"
        echo "============================================================"

        # Restore old panel if it was moved.
        if [ "$OLD_PANEL_MOVED" -eq 1 ] && [ -d "$OLD_PANEL" ]; then

            warn "Restoring previous Pterodactyl installation..."

            rm -rf "$PANEL"

            mv "$OLD_PANEL" "$PANEL" \
                || warn "Could not restore previous panel."

            OLD_PANEL_MOVED=0

            if [ -f "$PANEL/.env" ]; then
                chown -R www-data:www-data "$PANEL" 2>/dev/null || true
            fi

        fi

        # Try to bring services back.
        systemctl restart "$PHP_SERVICE" 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
        systemctl restart "$PTEROQ_SERVICE" 2>/dev/null || true

        echo
        warn "Rollback attempt completed."
        warn "SSH was NOT stopped or modified."
        echo

    fi

    # Keep temp data on failure for debugging.
    if [ "$EXIT_CODE" -eq 0 ]; then
        rm -rf "$TMP"
    else
        warn "Temporary files were kept at:"
        warn "$TMP"
    fi

    exit "$EXIT_CODE"
}

trap cleanup EXIT

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$EUID" -ne 0 ]; then
    die "Run this script as root."
fi

# ============================================================
# HEADER
# ============================================================

echo
echo "============================================================"
echo "        ZENITHZ ARIX PTERODACTYL SAFE REINSTALLER"
echo "============================================================"
echo
echo "Safety:"
echo " - SSH will NOT be stopped."
echo " - SSH configuration will NOT be modified."
echo " - /var/lib/pterodactyl will NOT be touched."
echo " - Existing panel will be preserved until new build is validated."
echo " - Automatic rollback is enabled."
echo
echo "Panel:"
echo " $PANEL"
echo
echo "Arix:"
echo " $PANEL_URL"
echo

# ============================================================
# EXISTING PANEL CHECK
# ============================================================

[ -d "$PANEL" ] || die "$PANEL does not exist."
[ -f "$PANEL/.env" ] || die "$PANEL/.env does not exist."

log "Existing Pterodactyl installation found."

# ============================================================
# CREATE TEMP DIRECTORY
# ============================================================

rm -rf "$TMP"

mkdir -p \
    "$TMP" \
    "$EXTRACTED"

chmod 700 "$TMP"

# ============================================================
# ENVIRONMENT READER
# ============================================================

env_value() {

    local KEY="$1"

    awk -F= -v key="$KEY" '
        $0 ~ "^" key "=" {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$PANEL/.env"
}

# ============================================================
# READ EXISTING ENV
# ============================================================

log "Reading existing Pterodactyl environment..."

APP_KEY="$(env_value APP_KEY)"
APP_ENV="$(env_value APP_ENV)"
APP_DEBUG="$(env_value APP_DEBUG)"
APP_URL="$(env_value APP_URL)"

DB_CONNECTION="$(env_value DB_CONNECTION)"
DB_HOST="$(env_value DB_HOST)"
DB_PORT="$(env_value DB_PORT)"
DB_DATABASE="$(env_value DB_DATABASE)"
DB_USERNAME="$(env_value DB_USERNAME)"
DB_PASSWORD="$(env_value DB_PASSWORD)"

REDIS_HOST="$(env_value REDIS_HOST)"
REDIS_PASSWORD="$(env_value REDIS_PASSWORD)"
REDIS_PORT="$(env_value REDIS_PORT)"

# Defaults
DB_CONNECTION="${DB_CONNECTION:-mysql}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"

[ -n "$APP_KEY" ] || die "APP_KEY missing from existing .env."
[ -n "$DB_DATABASE" ] || die "DB_DATABASE missing from existing .env."
[ -n "$DB_USERNAME" ] || die "DB_USERNAME missing from existing .env."

log "Existing environment loaded."

# ============================================================
# DISPLAY DATABASE INFO
# ============================================================

echo
echo "Database:"
echo " Connection : $DB_CONNECTION"
echo " Host       : $DB_HOST"
echo " Port       : $DB_PORT"
echo " Database   : $DB_DATABASE"
echo " Username   : $DB_USERNAME"
echo

# ============================================================
# PACKAGE LIST
# ============================================================

log "Updating package lists..."

DEBIAN_FRONTEND=noninteractive apt-get update

# ============================================================
# BASE PACKAGES
# ============================================================

log "Installing required packages..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    wget \
    unzip \
    git \
    gnupg \
    nginx \
    redis-server \
    mariadb-server \
    mariadb-client \
    cron \
    supervisor \
    lsof

# ============================================================
# PHP CHECK
# ============================================================

if command -v php8.3 >/dev/null 2>&1; then

    PHP_BIN="$(command -v php8.3)"

elif [ -x "/usr/bin/php8.3" ]; then

    PHP_BIN="/usr/bin/php8.3"

else

    log "PHP 8.3 is not installed."

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        php8.3 \
        php8.3-cli \
        php8.3-common \
        php8.3-gd \
        php8.3-mysql \
        php8.3-mbstring \
        php8.3-bcmath \
        php8.3-xml \
        php8.3-curl \
        php8.3-zip \
        php8.3-fpm \
        php8.3-opcache

    PHP_BIN="/usr/bin/php8.3"

fi

[ -x "$PHP_BIN" ] || die "PHP 8.3 binary was not found."

log "PHP binary: $PHP_BIN"

PHP_VERSION="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null || true)"

echo "PHP version: $PHP_VERSION"

[[ "$PHP_VERSION" == 8.3.* ]] \
    || die "Expected PHP 8.3.x, found $PHP_VERSION."

# ============================================================
# COMPOSER
# ============================================================

if ! command -v composer >/dev/null 2>&1; then

    log "Installing Composer..."

    curl \
        -fsSL \
        --retry 3 \
        --connect-timeout 15 \
        --max-time 120 \
        https://getcomposer.org/installer \
        -o "$TMP/composer-installer.php"

    "$PHP_BIN" "$TMP/composer-installer.php" \
        --install-dir=/usr/local/bin \
        --filename=composer

    rm -f "$TMP/composer-installer.php"

fi

command -v composer >/dev/null 2>&1 \
    || die "Composer installation failed."

log "Composer ready."

# ============================================================
# START DATABASE
# ============================================================

log "Starting MariaDB..."

systemctl start mariadb

sleep 2

systemctl is-active --quiet mariadb \
    || die "MariaDB failed to start."

# ============================================================
# DATABASE AUTHENTICATION
# ============================================================

DB_AUTH=""

if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then

    DB_AUTH="root"

elif mysql \
    -h "$DB_HOST" \
    -P "$DB_PORT" \
    -u "$DB_USERNAME" \
    -p"$DB_PASSWORD" \
    -e "SELECT 1;" >/dev/null 2>&1; then

    DB_AUTH="panel"

fi

[ -n "$DB_AUTH" ] \
    || die "Unable to authenticate to MariaDB."

log "MariaDB authentication successful using: $DB_AUTH"

# ============================================================
# DATABASE BACKUP
# ============================================================

log "Creating database backup..."

if [ "$DB_AUTH" = "root" ]; then

    mysqldump \
        -u root \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        "$DB_DATABASE" \
        > "$DUMP"

else

    mysqldump \
        -h "$DB_HOST" \
        -P "$DB_PORT" \
        -u "$DB_USERNAME" \
        -p"$DB_PASSWORD" \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        "$DB_DATABASE" \
        > "$DUMP"

fi

[ -s "$DUMP" ] \
    || die "Database backup failed or produced an empty dump."

log "Database backup created:"
log "$DUMP"

# ============================================================
# DOWNLOAD ARIX
# ============================================================

log "Downloading Zenithz Arix build..."

curl \
    -4 \
    -fL \
    --retry 5 \
    --retry-delay 3 \
    --connect-timeout 20 \
    --max-time 900 \
    "$PANEL_URL" \
    -o "$DOWNLOAD"

[ -s "$DOWNLOAD" ] \
    || die "Arix ZIP download failed."

# ============================================================
# ZIP VALIDATION
# ============================================================

log "Testing ZIP integrity..."

unzip -t "$DOWNLOAD" >/dev/null \
    || die "Arix ZIP is corrupt."

log "ZIP integrity verified."

# ============================================================
# EXTRACT TO TEMP
# ============================================================

log "Extracting Arix build into temporary directory..."

unzip -q "$DOWNLOAD" -d "$EXTRACTED"

# ============================================================
# FIND ARTISAN
# ============================================================

NEW_PANEL_ROOT=""

if [ -f "$EXTRACTED/artisan" ]; then

    NEW_PANEL_ROOT="$EXTRACTED"

elif [ -f "$EXTRACTED/pterodactyl/artisan" ]; then

    NEW_PANEL_ROOT="$EXTRACTED/pterodactyl"

else

    log "Searching ZIP contents for artisan..."

    FOUND_ARTISAN="$(
        find "$EXTRACTED" \
            -maxdepth 4 \
            -type f \
            -name artisan \
            -print \
            -quit
    )"

    if [ -n "$FOUND_ARTISAN" ]; then
        NEW_PANEL_ROOT="$(dirname "$FOUND_ARTISAN")"
    fi

fi

[ -n "$NEW_PANEL_ROOT" ] \
    || die "Invalid Arix build: artisan was not found."

[ -f "$NEW_PANEL_ROOT/artisan" ] \
    || die "Invalid Arix build: artisan missing."

log "New panel root detected:"
log "$NEW_PANEL_ROOT"

# ============================================================
# VALIDATE BUILD BEFORE TOUCHING LIVE PANEL
# ============================================================

[ -f "$NEW_PANEL_ROOT/.env.example" ] \
    || die "Arix build does not contain .env.example."

[ -f "$NEW_PANEL_ROOT/composer.json" ] \
    || die "Arix build does not contain composer.json."

log "Arix build structure validated."

# ============================================================
# PHP ARTISAN VALIDATION
# ============================================================

log "Testing artisan with the new build..."

cd "$NEW_PANEL_ROOT"

"$PHP_BIN" artisan --version >/dev/null 2>&1 \
    || die "New Arix build cannot execute artisan."

log "New Laravel/Pterodactyl build is executable."

# ============================================================
# BACKUP CURRENT PANEL
# ============================================================

log "Creating rollback copy of existing panel..."

rm -rf "$OLD_PANEL"

mv "$PANEL" "$OLD_PANEL"

OLD_PANEL_MOVED=1
ROLLBACK_NEEDED=1

log "Existing panel moved safely to:"
log "$OLD_PANEL"

# ============================================================
# INSTALL NEW PANEL
# ============================================================

log "Installing new Arix panel..."

mkdir -p "$PANEL"

cp -a \
    "$NEW_PANEL_ROOT/." \
    "$PANEL/"

[ -f "$PANEL/artisan" ] \
    || die "New panel installation failed: artisan missing."

[ -f "$PANEL/composer.json" ] \
    || die "New panel installation failed: composer.json missing."

# ============================================================
# RESTORE ENV
# ============================================================

log "Restoring existing .env..."

cp "$PANEL/.env.example" "$PANEL/.env"

# Use PHP instead of sed so special characters in values are safe.
export Z_APP_KEY="$APP_KEY"
export Z_APP_ENV="$APP_ENV"
export Z_APP_DEBUG="$APP_DEBUG"
export Z_APP_URL="$APP_URL"

export Z_DB_CONNECTION="$DB_CONNECTION"
export Z_DB_HOST="$DB_HOST"
export Z_DB_PORT="$DB_PORT"
export Z_DB_DATABASE="$DB_DATABASE"
export Z_DB_USERNAME="$DB_USERNAME"
export Z_DB_PASSWORD="$DB_PASSWORD"

export Z_REDIS_HOST="$REDIS_HOST"
export Z_REDIS_PASSWORD="$REDIS_PASSWORD"
export Z_REDIS_PORT="$REDIS_PORT"

"$PHP_BIN" <<'PHP'
<?php

$file = '/var/www/pterodactyl/.env';

$values = [
    'APP_KEY'        => getenv('Z_APP_KEY'),
    'APP_ENV'        => getenv('Z_APP_ENV'),
    'APP_DEBUG'      => getenv('Z_APP_DEBUG'),
    'APP_URL'        => getenv('Z_APP_URL'),

    'DB_CONNECTION'  => getenv('Z_DB_CONNECTION'),
    'DB_HOST'        => getenv('Z_DB_HOST'),
    'DB_PORT'        => getenv('Z_DB_PORT'),
    'DB_DATABASE'    => getenv('Z_DB_DATABASE'),
    'DB_USERNAME'    => getenv('Z_DB_USERNAME'),
    'DB_PASSWORD'    => getenv('Z_DB_PASSWORD'),

    'REDIS_HOST'     => getenv('Z_REDIS_HOST'),
    'REDIS_PASSWORD' => getenv('Z_REDIS_PASSWORD'),
    'REDIS_PORT'     => getenv('Z_REDIS_PORT'),
];

$contents = file_get_contents($file);

foreach ($values as $key => $value) {

    if ($value === false || $value === null) {
        continue;
    }

    $escaped = str_replace(
        ["\\", "\n", "\r"],
        ["\\\\", "", ""],
        $value
    );

    $pattern = '/^' . preg_quote($key, '/') . '=.*$/m';

    if (preg_match($pattern, $contents)) {

        $contents = preg_replace(
            $pattern,
            $key . '=' . $escaped,
            $contents,
            1
        );

    } else {

        $contents .= PHP_EOL . $key . '=' . $escaped . PHP_EOL;

    }
}

file_put_contents($file, $contents);
PHP

[ -f "$PANEL/.env" ] \
    || die ".env restoration failed."

log ".env restored."

# ============================================================
# PERMISSIONS
# ============================================================

log "Setting initial permissions..."

chown -R www-data:www-data "$PANEL"

mkdir -p \
    "$PANEL/storage" \
    "$PANEL/bootstrap/cache"

chmod -R 775 \
    "$PANEL/storage" \
    "$PANEL/bootstrap/cache"

# ============================================================
# COMPOSER
# ============================================================

log "Installing Composer dependencies..."

cd "$PANEL"

COMPOSER_ALLOW_SUPERUSER=1 \
COMPOSER_PROCESS_TIMEOUT=900 \
composer install \
    --no-dev \
    --optimize-autoloader \
    --prefer-dist \
    --no-interaction

log "Composer dependencies installed."

# ============================================================
# DATABASE RESTORE
# ============================================================

log "Preparing database restore..."

if [ "$DB_AUTH" = "root" ]; then

    mysql -u root <<SQL
DROP DATABASE IF EXISTS \`${DB_DATABASE}\`;
CREATE DATABASE \`${DB_DATABASE}\`;
SQL

else

    mysql \
        -h "$DB_HOST" \
        -P "$DB_PORT" \
        -u "$DB_USERNAME" \
        -p"$DB_PASSWORD" <<SQL
DROP DATABASE IF EXISTS \`${DB_DATABASE}\`;
CREATE DATABASE \`${DB_DATABASE}\`;
SQL

fi

log "Database recreated."

# ============================================================
# RESTORE DATABASE
# ============================================================

log "Restoring database..."

if [ "$DB_AUTH" = "root" ]; then

    mysql \
        -u root \
        "$DB_DATABASE" < "$DUMP"

else

    mysql \
        -h "$DB_HOST" \
        -P "$DB_PORT" \
        -u "$DB_USERNAME" \
        -p"$DB_PASSWORD" \
        "$DB_DATABASE" < "$DUMP"

fi

log "Database restored."

# ============================================================
# DATABASE VERIFICATION
# ============================================================

log "Verifying database..."

if [ "$DB_AUTH" = "root" ]; then

    TABLE_COUNT="$(
        mysql \
            -u root \
            -Nse \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_DATABASE}';"
    )"

else

    TABLE_COUNT="$(
        mysql \
            -h "$DB_HOST" \
            -P "$DB_PORT" \
            -u "$DB_USERNAME" \
            -p"$DB_PASSWORD" \
            -Nse \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_DATABASE}';"
    )"

fi

[[ "$TABLE_COUNT" =~ ^[0-9]+$ ]] \
    || die "Could not verify database."

[ "$TABLE_COUNT" -gt 0 ] \
    || die "Database verification failed: zero tables."

log "Database verified: $TABLE_COUNT tables."

# ============================================================
# LARAVEL
# ============================================================

cd "$PANEL"

log "Running Laravel migrations..."

"$PHP_BIN" artisan migrate --force

log "Clearing Laravel caches..."

"$PHP_BIN" artisan optimize:clear

log "Caching Laravel configuration..."

"$PHP_BIN" artisan config:cache

# Route/view cache failures should not kill an otherwise valid panel.
"$PHP_BIN" artisan route:cache 2>/dev/null || warn "Route cache failed."
"$PHP_BIN" artisan view:cache 2>/dev/null || warn "View cache failed."

# ============================================================
# ARTISAN HEALTH CHECK
# ============================================================

log "Checking Laravel..."

"$PHP_BIN" artisan about >/dev/null 2>&1 \
    || die "Laravel health check failed."

log "Laravel health check passed."

# ============================================================
# FINAL PERMISSIONS
# ============================================================

log "Fixing final permissions..."

chown -R www-data:www-data "$PANEL"

find "$PANEL" -type d -exec chmod 755 {} \;
find "$PANEL" -type f -exec chmod 644 {} \;

chmod -R 775 \
    "$PANEL/storage" \
    "$PANEL/bootstrap/cache"

# ============================================================
# PTEROQ
# ============================================================

log "Configuring Pteroq..."

cat > "/etc/systemd/system/${PTEROQ_SERVICE}.service" <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=network.target mariadb.service redis-server.service

[Service]
Type=simple
User=www-data
Group=www-data

WorkingDirectory=/var/www/pterodactyl

ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 --timeout=90

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$PTEROQ_SERVICE" >/dev/null 2>&1

# ============================================================
# CRON
# ============================================================

log "Configuring Pterodactyl scheduler..."

CRON_FILE="$TMP/ptero-cron"

crontab -u www-data -l 2>/dev/null \
    | grep -vF "/var/www/pterodactyl/artisan schedule:run" \
    > "$CRON_FILE" || true

echo "* * * * * /usr/bin/php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" \
    >> "$CRON_FILE"

crontab -u www-data "$CRON_FILE"

rm -f "$CRON_FILE"

# ============================================================
# SERVICE VALIDATION BEFORE RESTART
# ============================================================

log "Validating Nginx configuration..."

nginx -t \
    || die "Nginx configuration test failed. Existing services will be restored."

# ============================================================
# SERVICES
# ============================================================

log "Starting Redis..."

systemctl enable redis-server >/dev/null 2>&1 || true
systemctl restart redis-server

systemctl is-active --quiet redis-server \
    || die "Redis failed to start."

log "Starting MariaDB..."

systemctl enable mariadb >/dev/null 2>&1 || true
systemctl restart mariadb

systemctl is-active --quiet mariadb \
    || die "MariaDB failed to start."

log "Starting PHP-FPM..."

systemctl enable "$PHP_SERVICE" >/dev/null 2>&1 || true
systemctl restart "$PHP_SERVICE"

systemctl is-active --quiet "$PHP_SERVICE" \
    || die "PHP-FPM failed to start."

log "Starting Nginx..."

systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

systemctl is-active --quiet nginx \
    || die "Nginx failed to start."

log "Starting Pteroq..."

systemctl enable "$PTEROQ_SERVICE" >/dev/null 2>&1 || true
systemctl restart "$PTEROQ_SERVICE"

systemctl is-active --quiet "$PTEROQ_SERVICE" \
    || die "Pteroq failed to start."

# ============================================================
# SSH SAFETY CHECK
# ============================================================

echo
echo "============================================================"
echo "                    SSH SAFETY CHECK"
echo "============================================================"

SSH_SERVICE=""

if systemctl list-unit-files --type=service \
    | awk '{print $1}' \
    | grep -qx "ssh.service"; then

    SSH_SERVICE="ssh"

elif systemctl list-unit-files --type=service \
    | awk '{print $1}' \
    | grep -qx "sshd.service"; then

    SSH_SERVICE="sshd"

fi

if [ -n "$SSH_SERVICE" ]; then

    if systemctl is-active --quiet "$SSH_SERVICE"; then
        echo "[ONLINE]  $SSH_SERVICE"
    else
        warn "$SSH_SERVICE is not active."
    fi

else

    warn "Could not identify SSH service."

fi

# ============================================================
# SERVICE STATUS
# ============================================================

echo
echo "============================================================"
echo "                    SERVICE STATUS"
echo "============================================================"

SERVICES=(
    "mariadb"
    "redis-server"
    "$PHP_SERVICE"
    "nginx"
    "$PTEROQ_SERVICE"
)

FAILED=0

for SERVICE in "${SERVICES[@]}"; do

    if systemctl is-active --quiet "$SERVICE"; then

        echo "[ONLINE]  $SERVICE"

    else

        echo "[FAILED]  $SERVICE"

        FAILED=1

    fi

done

# ============================================================
# LARAVEL HEALTH
# ============================================================

echo
echo "============================================================"
echo "                    PANEL HEALTH"
echo "============================================================"

cd "$PANEL"

if "$PHP_BIN" artisan about >/dev/null 2>&1; then

    echo "[ONLINE]  Laravel"

else

    echo "[FAILED]  Laravel"

    FAILED=1

fi

# ============================================================
# LOCAL HTTP TEST
# ============================================================

log "Testing local HTTP endpoint..."

HTTP_CODE="$(
    curl \
        -4 \
        -k \
        -s \
        -o /dev/null \
        -w '%{http_code}' \
        --connect-timeout 5 \
        --max-time 10 \
        http://127.0.0.1/ \
        2>/dev/null || true
)"

if [[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then

    echo "[ONLINE]  HTTP -> $HTTP_CODE"

else

    echo "[FAILED]  HTTP endpoint"

    FAILED=1

fi

# ============================================================
# REMOVE OLD PANEL ONLY AFTER SUCCESS
# ============================================================

if [ "$FAILED" -eq 0 ]; then

    log "New panel passed health checks."

    # We no longer need rollback.
    ROLLBACK_NEEDED=0

    log "Removing old panel rollback copy..."

    rm -rf "$OLD_PANEL"

    OLD_PANEL_MOVED=0

fi

# ============================================================
# FINAL
# ============================================================

echo
echo "============================================================"

if [ "$FAILED" -eq 0 ]; then

    echo "       ZENITHZ ARIX PANEL INSTALLATION SUCCESSFUL"

else

    echo "       INSTALLATION COMPLETED WITH WARNINGS"

fi

echo "============================================================"

echo
echo "Panel      : $PANEL"
echo "Database   : $DB_DATABASE"
echo "Arix Build : $PANEL_URL"
echo
echo "SSH        : NOT STOPPED"
echo "SSH config : NOT MODIFIED"
echo "Wings data : NOT TOUCHED"
echo

if [ "$FAILED" -eq 0 ]; then
    echo "Status: ONLINE"
else
    echo "Status: CHECK FAILED"
fi

echo

exit "$FAILED"
