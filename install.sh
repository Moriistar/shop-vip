#!/usr/bin/env bash
# ============================================================
#  Auto Installer - Telegram Shop Bot by MoriiStar
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
 ____  _                    __     _____ ____
/ ___|| |__   ___  _ __    \ \   / /_ _|  _ \
\___ \| '_ \ / _ \| '_ \    \ \ / / | || |_) |
 ___) | | | | (_) | |_) |    \ V /  | ||  __/
|____/|_| |_|\___/| .__/      \_/  |___|_|
                   |_|   by MoriiStar
EOF
echo -e "${NC}"
echo -e "${BOLD}ربات فروشگاه تلگرام — نصب یکپارچه و خودکار${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

[[ $EUID -ne 0 ]] && error "این اسکریپت باید با کاربر root (sudo) اجرا شود."

# ── دریافت اطلاعات از کاربر در همان ابتدای کار ──
echo -e "${BOLD}━━━ تنظیمات ربات ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
read -rp "$(echo -e "${YELLOW}توکن ربات (BOT_TOKEN):${NC} ")" BOT_TOKEN
[[ -z "$BOT_TOKEN" ]] && error "وارد کردن توکن ربات الزامی است."

read -rp "$(echo -e "${YELLOW}آیدی عددی مالک ربات (ADMIN_ID):${NC} ")" ADMIN_ID
[[ -z "$ADMIN_ID" ]] && error "وارد کردن آیدی ادمین الزامی است."

read -rp "$(echo -e "${YELLOW}نام ربات [مثال: Shop Bot]:${NC} ")" BOT_NAME
BOT_NAME="${BOT_NAME:-Shop Bot}"

read -rp "$(echo -e "${YELLOW}دامنه یا ساب‌دامنه سرور (مثال: bot.domain.com):${NC} ")" DOMAIN
[[ -z "$DOMAIN" ]] && error "وارد کردن دامنه برای تنظیم Webhook و Nginx الزامی است."

echo -e "\n${CYAN}در صورت تمایل لینک‌های درگاه پرداخت را وارد کنید (برای رد شدن Enter بزنید):${NC}"
read -rp "لینک پرداخت 100 سکه: " PAY_100
read -rp "لینک پرداخت 200 سکه: " PAY_200
read -rp "لینک پرداخت 300 سکه: " PAY_300

WEBHOOK_SECRET=$(openssl rand -hex 24)

# ── نصب پیش‌نیازها ──
info "در حال بررسی و نصب پیش‌نیازها (PHP, Nginx, Curl, SSL)..."
if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq php php-cli php-curl php-fpm curl nginx openssl certbot python3-certbot-nginx
elif command -v yum &>/dev/null; then
    yum install -y php php-cli php-curl php-fpm curl nginx openssl certbot python3-certbot-nginx
else
    error "سیستم‌عامل پشتیبانی نمی‌شود. لطفاً از اوبونتو/دبیان یا سنت‌اواس استفاده کنید."
fi

PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
success "PHP نسخه $PHP_VER و سایر پیش‌نیازها نصب شدند."

# ── ساخت مسیر نصب ──
INSTALL_DIR="/var/www/shop-vip"
info "در حال ایجاد مسیر نصب در $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR/data/users" "$INSTALL_DIR/data/products" "$INSTALL_DIR/data/codes"

# ── ساخت فایل bot.php ──
info "در حال ساخت هسته ربات (bot.php)..."
cat > "$INSTALL_DIR/bot.php" << 'EOF_PHP'
<?php
declare(strict_types=1);
date_default_timezone_set('Asia/Tehran');

function loadEnv(string $path): void {
  if (!file_exists($path)) return;
  $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
  foreach ($lines as $line) {
    $line = trim($line);
    if ($line === '' || str_starts_with($line, '#')) continue;
    $pos = strpos($line, '=');
    if ($pos === false) continue;
    $key = trim(substr($line, 0, $pos));
    $val = trim(substr($line, $pos + 1));
    $val = trim($val, "\"'");
    if ($key !== '' && getenv($key) === false) {
      putenv($key . '=' . $val);
      $_ENV[$key] = $val;
    }
  }
}
loadEnv(__DIR__ . '/.env');

function env(string $key, $default = null) {
  $v = getenv($key);
  if ($v === false || $v === '') return $default;
  return $v;
}

$BOT_TOKEN = (string)env('BOT_TOKEN', '');
$ADMIN_ID  = (int)env('ADMIN_ID', '0');
$BOT_NAME  = (string)env('BOT_NAME', 'Shop Bot');
$WEBHOOK_SECRET = (string)env('WEBHOOK_SECRET', '');

if ($BOT_TOKEN === '' || $ADMIN_ID === 0) {
  http_response_code(500); echo "Bot is not configured."; exit;
}

if ($WEBHOOK_SECRET !== '') {
  $header = $_SERVER['HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN'] ?? '';
  if ($header !== $WEBHOOK_SECRET) {
    http_response_code(403); echo "Forbidden"; exit;
  }
}

const DELIM = "(******)";

function ensureDir(string $dir): void { if (!is_dir($dir)) mkdir($dir, 0775, true); }
function dataPath(string $rel): string { return __DIR__ . '/data/' . ltrim($rel, '/'); }
function readFileSafe(string $path, string $default = ''): string { return file_exists($path) ? (string)file_get_contents($path) : $default; }
function writeFileSafe(string $path, string $content): void { ensureDir(dirname($path)); file_put_contents($path, $content, LOCK_EX); }
function userDir(int $userId): string { return dataPath("users/$userId"); }
function userFile(int $userId, string $name): string { return userDir($userId) . "/$name"; }
function getStep(int $userId): string { return readFileSafe(userFile($userId, 'step.txt'), 'none'); }
function setStep(int $userId, string $step): void { writeFileSafe(userFile($userId, 'step.txt'), $step); }
function getCoins(int $userId): int { $p = userFile($userId, 'coin.txt'); return file_exists($p) ? (int)trim((string)file_get_contents($p)) : 0; }
function setCoins(int $userId, int $coins): void { writeFileSafe(userFile($userId, 'coin.txt'), (string)max(0, $coins)); }
function addCoins(int $userId, int $delta): int { $c = getCoins($userId) + $delta; setCoins($userId, $c); return $c; }

function registerUserIfNeeded(int $userId): void {
  $dir = userDir($userId);
  if (!is_dir($dir)) {
    ensureDir($dir); setCoins($userId, 0); setStep($userId, 'none');
    $m = __DIR__ . '/Member.txt';
    $members = readFileSafe($m, '');
    if (strpos($members, "$userId\n") === false) writeFileSafe($m, $members . $userId . "\n");
  }
}

function getProductCount(): int { $p = dataPath('products/count.txt'); if (!file_exists($p)) { writeFileSafe($p, '0'); return 0; } return (int)trim((string)file_get_contents($p)); }
function setProductCount(int $n): void { writeFileSafe(dataPath('products/count.txt'), (string)max(0,$n)); }
function productByIdPath(int $id): string { return dataPath("products/$id.txt"); }
function productTitleIndexPath(string $title): string { return dataPath("products/idx_" . md5($title) . ".idx"); }
function saveProduct(int $id, string $title, string $desc, string $link, int $price): void {
  writeFileSafe(productByIdPath($id), $title . DELIM . $desc . DELIM . $link . DELIM . $price);
  writeFileSafe(productTitleIndexPath($title), (string)$id);
}
function loadProductById(int $id): ?array {
  $p = productByIdPath($id); if (!file_exists($p)) return null;
  $a = explode(DELIM, (string)file_get_contents($p));
  return ['id'=>$id,'title'=>$a[0]??'','desc'=>$a[1]??'','link'=>$a[2]??'','price'=>(int)($a[3]??0)];
}
function findProductIdByTitle(string $title): ?int { $p = productTitleIndexPath($title); return file_exists($p) ? (int)trim((string)file_get_contents($p)) : null; }
function deleteProductById(int $id): bool {
  $prod = loadProductById($id); if (!$prod) return false;
  @unlink(productByIdPath($id)); @unlink(productTitleIndexPath($prod['title'])); return true;
}

function tg(string $method, array $params = []) {
  global $BOT_TOKEN;
  $ch = curl_init("https://api.telegram.org/bot{$BOT_TOKEN}/{$method}");
  curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER=>true,CURLOPT_POST=>true, CURLOPT_POSTFIELDS=>$params,CURLOPT_CONNECTTIMEOUT=>10,CURLOPT_TIMEOUT=>30]);
  $res = curl_exec($ch); curl_close($ch); return json_decode((string)$res, true);
}
function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES|ENT_SUBSTITUTE, 'UTF-8'); }
function sendMessage(int|string $chatId, string $text, array $replyKeyboard=null, array $inlineKeyboard=null): void {
  $p = ['chat_id'=>$chatId,'text'=>$text,'parse_mode'=>'HTML','disable_web_page_preview'=>false];
  if ($replyKeyboard !== null) $p['reply_markup'] = json_encode(['keyboard'=>$replyKeyboard,'resize_keyboard'=>true],JSON_UNESCAPED_UNICODE);
  elseif ($inlineKeyboard !== null) $p['reply_markup'] = json_encode(['inline_keyboard'=>$inlineKeyboard],JSON_UNESCAPED_UNICODE);
  tg('sendMessage', $p);
}
function answerCallback(string $id, string $text=''): void { tg('answerCallbackQuery',['callback_query_id'=>$id,'text'=>$text,'show_alert'=>false]); }

function mainMenu(): array { return [[['text'=>'فروشگاه 🛒'],['text'=>'افزایش موجودی 💳']],[['text'=>'کد هدیه 🛍'],['text'=>'حساب کاربری 🔖']],[['text'=>'👥پشتیبانی'],['text'=>'خرید پک VIP 🎬']]]; }
function backMenu(): array { return [[['text'=>'بازگشت']]]; }
function adminMenu(): array { return [[['text'=>'محصول جدید'],['text'=>'حذف محصول']],[['text'=>'ساخت کد هدیه'],['text'=>'اهدای سکه']],[['text'=>'کم کردن سکه']],[['text'=>'بازگشت']]]; }

function showWelcome(int $chatId, int $userId, ?int $refId): void {
  registerUserIfNeeded($userId);
  if ($refId !== null && $refId !== $userId) {
    registerUserIfNeeded($refId); addCoins($refId, 1); sendMessage($refId, "یک نفر از طریق لینک شما وارد شد ✅\n+1 سکه ثبت شد.");
  }
  sendMessage($chatId, "سلام، خوش آمدید 👋\n\nاز منوی زیر بخش موردنظر را انتخاب کنید.", mainMenu());
}
function adminRequire(int $chatId, int $fromId): bool { global $ADMIN_ID; if ($fromId !== $ADMIN_ID) { sendMessage($chatId,"⛔️ دسترسی ادمین ندارید.",mainMenu()); return false; } return true; }

$raw = file_get_contents('php://input');
$update = json_decode((string)$raw, true);
if (!is_array($update)) { http_response_code(200); echo "OK"; exit; }

$message  = $update['message'] ?? null;
$callback = $update['callback_query'] ?? null;

if ($callback) { answerCallback($callback['id'] ?? ''); http_response_code(200); echo "OK"; exit; }
if (!$message) { http_response_code(200); echo "OK"; exit; }

$chatId   = (int)($message['chat']['id']??0);
$fromId   = (int)($message['from']['id']??0);
$name     = (string)($message['from']['first_name']??'کاربر');
$text     = (string)($message['text']??'');

if ($chatId===0||$fromId===0) { http_response_code(200); echo "OK"; exit; }
registerUserIfNeeded($fromId);
$step = getStep($fromId);

if ($text==='/cancel'||$text==='بازگشت') { setStep($fromId,'none'); sendMessage($chatId,"✅ لغو شد.",mainMenu()); http_response_code(200); echo "OK"; exit; }
if (str_starts_with($text,'/start')) { showWelcome($chatId,$fromId,null); setStep($fromId,'none'); http_response_code(200); echo "OK"; exit; }
if ($text==='/panel') { if(adminRequire($chatId,$fromId)){ setStep($fromId,'none'); sendMessage($chatId,"پنل مدیریت:",adminMenu()); } http_response_code(200); echo "OK"; exit; }

if($step==='admin_set_title'){ writeFileSafe(userFile($fromId,'tmp_title.txt'),trim($text)); setStep($fromId,'admin_set_desc'); sendMessage($chatId,"توضیحات:",backMenu()); http_response_code(200); echo "OK"; exit; }
if($step==='admin_set_desc'){ writeFileSafe(userFile($fromId,'tmp_desc.txt'),trim($text)); setStep($fromId,'admin_set_link'); sendMessage($chatId,"لینک تحویل:",backMenu()); http_response_code(200); echo "OK"; exit; }
if($step==='admin_set_link'){ writeFileSafe(userFile($fromId,'tmp_link.txt'),trim($text)); setStep($fromId,'admin_set_price'); sendMessage($chatId,"قیمت (سکه):",backMenu()); http_response_code(200); echo "OK"; exit; }
if($step==='admin_set_price'){
  $price=(int)trim($text);
  if($price>0){
      $newId=getProductCount()+1;
      saveProduct($newId, readFileSafe(userFile($fromId,'tmp_title.txt')), readFileSafe(userFile($fromId,'tmp_desc.txt')), readFileSafe(userFile($fromId,'tmp_link.txt')), $price);
      setProductCount($newId); setStep($fromId,'none'); sendMessage($chatId,"✅ محصول ثبت شد. آیدی: $newId",adminMenu());
  }
  http_response_code(200); echo "OK"; exit;
}

switch($text){
  case 'فروشگاه 🛒':
    $count = getProductCount();
    if ($count <= 0) { sendMessage($chatId, "فعلاً محصولی نیست.", mainMenu()); break; }
    $kb = []; for ($i=1; $i<=$count; $i++) { $p = loadProductById($i); if ($p) $kb[] = [['text'=>$p['title']]]; } $kb[] = [['text'=>'بازگشت']];
    sendMessage($chatId, "🛒 محصولات:", $kb); break;
  case 'حساب کاربری 🔖': sendMessage($chatId, "موجودی: " . getCoins($fromId) . " سکه\nشناسه: $fromId", mainMenu()); break;
  case 'محصول جدید': if(adminRequire($chatId,$fromId)){ setStep($fromId,'admin_set_title'); sendMessage($chatId,"عنوان محصول:",backMenu()); } break;
  default:
      if(preg_match('/^\/buy(\d+)$/',trim($text),$m)){
        $p=loadProductById((int)$m[1]); $coin=getCoins($fromId);
        if($p && $coin>=$p['price']){ setCoins($fromId,$coin-$p['price']); sendMessage($chatId,"✅ خرید موفق!\nلینک: ".$p['link'],mainMenu()); }
        else { sendMessage($chatId,"❌ موجودی کافی نیست یا محصول یافت نشد.",mainMenu()); }
      }
      $pid=findProductIdByTitle($text);
      if($pid){ $p=loadProductById($pid); sendMessage($chatId,"🧾 {$p['title']}\n📌 {$p['desc']}\n💰 {$p['price']} سکه\n\n✅ خرید:\n/buy{$p['id']}", [[['text'=>'بازگشت']]]); }
}
http_response_code(200); echo "OK";
EOF_PHP
success "کدهای PHP ربات با موفقیت نوشته شد."

# ── ساخت فایل .env ──
info "در حال پیکربندی متغیرهای محیطی (.env) ..."
cat > "$INSTALL_DIR/.env" <<EOF_ENV
BOT_TOKEN=${BOT_TOKEN}
ADMIN_ID=${ADMIN_ID}
BOT_NAME=${BOT_NAME}
WEBHOOK_SECRET=${WEBHOOK_SECRET}
PAY_100_URL=${PAY_100:-}
PAY_200_URL=${PAY_200:-}
PAY_300_URL=${PAY_300:-}
EOF_ENV
chmod 600 "$INSTALL_DIR/.env"

# ── تنظیم مجوزها ──
chown -R www-data:www-data "$INSTALL_DIR" 2>/dev/null || true
chmod -R 755 "$INSTALL_DIR"
chmod -R 775 "$INSTALL_DIR/data"

# ── تنظیم Nginx ──
info "در حال کانفیگ Nginx ..."
cat > /etc/nginx/sites-available/shop-vip <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    root ${INSTALL_DIR};
    index bot.php;

    location / { try_files \$uri \$uri/ /bot.php?\$query_string; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\. { deny all; }
    location ^~ /data/ { deny all; }
}
NGINX

ln -sf /etc/nginx/sites-available/shop-vip /etc/nginx/sites-enabled/shop-vip
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t && systemctl reload nginx

# ── فعال‌سازی PHP-FPM ──
systemctl enable php${PHP_VER}-fpm --now 2>/dev/null || true

# ── نصب SSL با Let's Encrypt ──
echo ""
read -rp "$(echo -e "${YELLOW}آیا می‌خواهید SSL رایگان (Let's Encrypt) نصب شود؟ [Y/n]:${NC} ")" DO_SSL
DO_SSL=${DO_SSL:-y}
SCHEME="http"

if [[ "${DO_SSL,,}" == "y" ]]; then
    info "در حال دریافت گواهینامه SSL..."
    if certbot --nginx -d "$DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive; then
        success "SSL با موفقیت روی دامنه تنظیم شد."
        SCHEME="https"
    else
        warn "تنظیم SSL با مشکل مواجه شد. از Http استفاده می‌شود."
    fi
fi

# ── ثبت Webhook در تلگرام ──
info "در حال ثبت Webhook در تلگرام ..."
WEBHOOK_URL="${SCHEME}://${DOMAIN}/bot.php"

API_RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
    -d "url=${WEBHOOK_URL}" \
    -d "secret_token=${WEBHOOK_SECRET}" \
    -d "allowed_updates=[\"message\",\"callback_query\"]")

if echo "$API_RESPONSE" | grep -q '"ok":true'; then
    success "وب‌هوک با موفقیت متصل شد!"
else
    warn "خطا در ثبت وب‌هوک تلگرام. لطفاً توکن یا دامنه را بررسی کنید:"
    echo "$API_RESPONSE"
fi

# ── پایان ──
echo ""
echo -e "${BOLD}${GREEN}━━━ نصب و راه‌اندازی ربات با موفقیت به پایان رسید! ━━━━━━━━━${NC}"
echo -e "  📂 مسیر فایل‌های شما : ${CYAN}${INSTALL_DIR}${NC}"
echo -e "  🔗 لینک Webhook      : ${CYAN}${WEBHOOK_URL}${NC}"
echo -e "  🔑 آیدی مالک         : ${CYAN}${ADMIN_ID}${NC}"
echo -e "${YELLOW}توجه: برای دسترسی به پنل مدیریت، در تلگرام دستور /panel را ارسال کنید.${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
