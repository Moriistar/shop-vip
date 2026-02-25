#!/usr/bin/env bash
# ============================================================
#  shop-vip — Auto Installer
#  GitHub: https://github.com/Moriistar/shop-vip
#  Usage : sudo bash <(curl -Ls https://raw.githubusercontent.com/Moriistar/shop-vip/main/install.sh)
# ============================================================
set -euo pipefail

# ── رنگ‌ها ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── بنر ─────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
 ____  _                    __     _____ ____
/ ___|| |__   ___  _ __    \ \   / /_ _|  _ \
\___ \| '_ \ / _ \| '_ \    \ \ / / | || |_) |
 ___) | | | | (_) | |_) |    \ V /  | ||  __/
|____/|_| |_|\___/| .__/      \_/  |___|_|
                   |_|   by Moriistar
EOF
echo -e "${NC}"
echo -e "${BOLD}ربات فروشگاه تلگرام — نصب خودکار${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── بررسی root ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "این اسکریپت باید با sudo اجرا شود."

# ── تشخیص OS ────────────────────────────────────────────────
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
else
    error "سیستم‌عامل پشتیبانی نمی‌شود. فقط Debian/Ubuntu/CentOS."
fi
info "Package manager: $PKG_MANAGER"

# ── نصب وابستگی‌ها ───────────────────────────────────────────
info "نصب PHP و وابستگی‌ها..."
if [[ $PKG_MANAGER == "apt" ]]; then
    apt-get update -qq
    apt-get install -y -qq php php-cli php-curl curl nginx unzip git
else
    $PKG_MANAGER install -y php php-cli php-curl curl nginx unzip git
fi
success "وابستگی‌ها نصب شدند."

# ── مسیر نصب ────────────────────────────────────────────────
INSTALL_DIR="/var/www/shop-vip"
info "مسیر نصب: $INSTALL_DIR"

# ── دانلود فایل‌های ربات ────────────────────────────────────
info "دانلود فایل‌های ربات از GitHub..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

RAW="https://raw.githubusercontent.com/Moriistar/shop-vip/main"
curl -fsSL "$RAW/bot.php"     -o bot.php
curl -fsSL "$RAW/.env.example" -o .env.example
success "فایل‌ها دانلود شدند."

# ── ساخت پوشه‌های data ──────────────────────────────────────
mkdir -p data/users data/products data/codes
chown -R www-data:www-data "$INSTALL_DIR" 2>/dev/null || true
chmod -R 755 "$INSTALL_DIR"
chmod -R 775 "$INSTALL_DIR/data"
success "پوشه‌های data ساخته شدند."

# ── دریافت اطلاعات از کاربر ─────────────────────────────────
echo ""
echo -e "${BOLD}━━━ تنظیمات ربات ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -rp "$(echo -e "${YELLOW}توکن ربات (BOT_TOKEN):${NC} ")" BOT_TOKEN
[[ -z "$BOT_TOKEN" ]] && error "توکن ربات الزامی است."

read -rp "$(echo -e "${YELLOW}آیدی عددی ادمین (ADMIN_ID):${NC} ")" ADMIN_ID
[[ -z "$ADMIN_ID" ]] && error "آیدی ادمین الزامی است."

read -rp "$(echo -e "${YELLOW}نام ربات (BOT_NAME) [Shop Bot]:${NC} ")" BOT_NAME
BOT_NAME="${BOT_NAME:-Shop Bot}"

read -rp "$(echo -e "${YELLOW}دامنه سرور (مثال: example.com):${NC} ")" DOMAIN
[[ -z "$DOMAIN" ]] && error "دامنه الزامی است."

# تولید Webhook Secret تصادفی
WEBHOOK_SECRET=$(openssl rand -hex 24)

# لینک‌های پرداخت (اختیاری)
echo ""
echo -e "${CYAN}لینک‌های پرداخت را وارد کنید (اختیاری — Enter برای رد کردن):${NC}"
read -rp "  PAY_100_URL : " PAY_100
read -rp "  PAY_200_URL : " PAY_200
read -rp "  PAY_300_URL : " PAY_300
read -rp "  PAY_400_URL : " PAY_400
read -rp "  PAY_640_URL : " PAY_640
read -rp "  PAY_960_URL : " PAY_960

# ── ساخت .env ───────────────────────────────────────────────
cat > "$INSTALL_DIR/.env" <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_ID=${ADMIN_ID}
BOT_NAME=${BOT_NAME}
WEBHOOK_SECRET=${WEBHOOK_SECRET}

PAY_100_URL=${PAY_100:-}
PAY_200_URL=${PAY_200:-}
PAY_300_URL=${PAY_300:-}
PAY_400_URL=${PAY_400:-}
PAY_640_URL=${PAY_640:-}
PAY_960_URL=${PAY_960:-}
EOF
chmod 600 "$INSTALL_DIR/.env"
success ".env ساخته شد."

# ── تنظیم Nginx ─────────────────────────────────────────────
info "تنظیم Nginx..."
cat > /etc/nginx/sites-available/shop-vip <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    root ${INSTALL_DIR};
    index bot.php;

    location / {
        try_files \$uri \$uri/ /bot.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # مسدود کردن دسترسی به .env و data
    location ~ /\. {
        deny all;
    }
    location ^~ /data/ {
        deny all;
    }
}
NGINX

# ── فعال کردن سایت ──────────────────────────────────────────
if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sf /etc/nginx/sites-available/shop-vip /etc/nginx/sites-enabled/shop-vip
    rm -f /etc/nginx/sites-enabled/default
fi
nginx -t && systemctl reload nginx
success "Nginx تنظیم شد."

# ── نصب PHP-FPM ─────────────────────────────────────────────
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
systemctl enable php${PHP_VER}-fpm --now 2>/dev/null || \
systemctl enable php-fpm --now 2>/dev/null || \
warn "PHP-FPM را به صورت دستی راه‌اندازی کنید."

# ── SSL با Let's Encrypt ─────────────────────────────────────
echo ""
read -rp "$(echo -e "${YELLOW}آیا می‌خواهید SSL (Let's Encrypt) نصب شود؟ [y/N]:${NC} ")" DO_SSL
if [[ "${DO_SSL,,}" == "y" ]]; then
    if [[ $PKG_MANAGER == "apt" ]]; then
        apt-get install -y -qq certbot python3-certbot-nginx
    else
        $PKG_MANAGER install -y certbot python3-certbot-nginx
    fi
    read -rp "$(echo -e "${YELLOW}ایمیل برای SSL:${NC} ")" SSL_EMAIL
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$SSL_EMAIL" && \
        success "SSL نصب شد." || warn "SSL نصب نشد. بعداً می‌توانید دستی اقدام کنید."
fi

# ── ثبت Webhook ─────────────────────────────────────────────
info "ثبت Webhook در تلگرام..."
SCHEME="http"
[[ "${DO_SSL,,}" == "y" ]] && SCHEME="https"

WEBHOOK_URL="${SCHEME}://${DOMAIN}/bot.php"

RESPONSE=$(curl -s -X POST \
    "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
    -d "url=${WEBHOOK_URL}" \
    -d "secret_token=${WEBHOOK_SECRET}" \
    -d "allowed_updates=[\"message\",\"callback_query\"]")

if echo "$RESPONSE" | grep -q '"ok":true'; then
    success "Webhook ثبت شد: $WEBHOOK_URL"
else
    warn "ثبت Webhook با مشکل مواجه شد:"
    echo "$RESPONSE"
fi

# ── پایان ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━ نصب کامل شد! ━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  📂 مسیر نصب  : ${CYAN}${INSTALL_DIR}${NC}"
echo -e "  🔗 Webhook   : ${CYAN}${WEBHOOK_URL}${NC}"
echo -e "  🔑 Secret    : ${CYAN}${WEBHOOK_SECRET}${NC}"
echo -e "  📄 .env      : ${CYAN}${INSTALL_DIR}/.env${NC}"
echo ""
echo -e "${YELLOW}⚠️  .env را هرگز در گیت‌هاب آپلود نکنید!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
