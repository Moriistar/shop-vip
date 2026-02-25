#!/bin/bash

# رنگ‌ها برای زیباتر شدن محیط اسکریپت
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] لطفا اسکریپت را با دسترسی root (sudo bash) اجرا کنید.${NC}"
  exit 1
fi

show_menu() {
    clear
    echo -e "${BLUE}=================================================${NC}"
    echo -e "${GREEN}      Shop Bot Auto-Installer & Manager        ${NC}"
    echo -e "${GREEN}      GitHub: @Moriistar                       ${NC}"
    echo -e "${BLUE}=================================================${NC}"
    echo -e "1) 🚀 نصب ربات (نصب کامل صفر تا صد)"
    echo -e "2) ⚙️ ویرایش اطلاعات (تغییر توکن ربات و آیدی ادمین)"
    echo -e "0) ❌ خروج"
    echo -e "${BLUE}=================================================${NC}"
    read -p "یک گزینه را انتخاب کنید [0-2]: " OPTION

    case $OPTION in
        1) install_bot ;;
        2) edit_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}گزینه نامعتبر!${NC}"; sleep 2; show_menu ;;
    esac
}

install_bot() {
    echo -e "\n${GREEN}--- دریافت اطلاعات اولیه ---${NC}"
    read -p "دامین یا ساب‌دامین خود را وارد کنید (مثلا bot.domain.com): " DOMAIN
    read -p "توکن ربات خود را از BotFather وارد کنید: " BOT_TOKEN
    read -p "آیدی عددی تلگرام ادمین را وارد کنید: " ADMIN_ID

    echo -e "\n${BLUE}[+] در حال آپدیت سرور و نصب پیش‌نیازها...${NC}"
    apt update -y
    apt install -y nginx php-fpm php-curl curl unzip git certbot python3-certbot-nginx

    DIR="/var/www/$DOMAIN"

    echo -e "${BLUE}[+] در حال کلون کردن فایل‌ها از گیت‌هاب...${NC}"
    rm -rf $DIR
    git clone https://github.com/Moriistar/shop-vip.git $DIR

    echo -e "${BLUE}[+] در حال ساخت دایرکتوری‌های دیتابیس...${NC}"
    mkdir -p $DIR/data/users
    mkdir -p $DIR/data/products
    mkdir -p $DIR/data/codes
    touch $DIR/Member.txt
    echo "0" > $DIR/data/products/count.txt

    echo -e "${BLUE}[+] در حال جایگذاری توکن و آیدی ادمین در فایل index.php...${NC}"
    sed -i "s/define('API_KEY','.*');/define('API_KEY','$BOT_TOKEN');/g" $DIR/index.php
    sed -i "s/\$admin = [0-9]*;/\$admin = $ADMIN_ID;/g" $DIR/index.php

    echo -e "${BLUE}[+] تنظیم سطح دسترسی (Permissions)...${NC}"
    chown -R www-data:www-data $DIR
    chmod -R 775 $DIR

    echo -e "${BLUE}[+] در حال کانفیگ وب‌سرور Nginx...${NC}"
    # پیدا کردن اتوماتیک ورژن PHP-FPM
    PHP_SOCK=$(find /var/run/php/ -name "*.sock" | head -n 1)
    if [ -z "$PHP_SOCK" ]; then
        PHP_SOCK="/var/run/php/php8.1-fpm.sock"
    fi

    cat <<EOF > /etc/nginx/sites-available/$DOMAIN
server {
    listen 80;
    server_name $DOMAIN;
    root $DIR;
    index index.php;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCK;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    systemctl reload nginx

    echo -e "${BLUE}[+] در حال دریافت گواهینامه SSL رایگان...${NC}"
    certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email

    echo -e "${BLUE}[+] در حال تنظیم Webhook تلگرام...${NC}"
    curl -s "https://api.telegram.org/bot$BOT_TOKEN/setWebhook?url=https://$DOMAIN/index.php"

    echo -e "\n${GREEN}[✔] نصب با موفقیت به پایان رسید! وب‌هوک تنظیم شد.${NC}"
    sleep 3
    show_menu
}

edit_config() {
    echo -e "\n${GREEN}--- ویرایش اطلاعات ربات ---${NC}"
    read -p "دامین یا ساب‌دامینی که ربات روی آن نصب شده را وارد کنید: " DOMAIN
    DIR="/var/www/$DOMAIN"

    if [ ! -f "$DIR/index.php" ]; then
        echo -e "${RED}[!] خطایی رخ داد: رباتی در مسیر $DIR پیدا نشد! ابتدا ربات را نصب کنید.${NC}"
        sleep 3
        show_menu
        return
    fi

    read -p "توکن جدید ربات را وارد کنید: " NEW_TOKEN
    read -p "آیدی عددی جدید ادمین را وارد کنید: " NEW_ADMIN

    echo -e "${BLUE}[+] در حال بروزرسانی اطلاعات در فایل index.php...${NC}"
    sed -i "s/define('API_KEY','.*');/define('API_KEY','$NEW_TOKEN');/g" $DIR/index.php
    sed -i "s/\$admin = [0-9]*;/\$admin = $NEW_ADMIN;/g" $DIR/index.php

    echo -e "${BLUE}[+] در حال آپدیت Webhook تلگرام...${NC}"
    curl -s "https://api.telegram.org/bot$NEW_TOKEN/setWebhook?url=https://$DOMAIN/index.php"

    echo -e "\n${GREEN}[✔] اطلاعات جدید با موفقیت ذخیره و آپدیت شد!${NC}"
    sleep 3
    show_menu
}

# اجرای منو
show_menu
