#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

clear
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
 ____  _                    __     _____ ____
/ ___|| |__   ___  _ __    \ \   / /_ _|  _ \
\___ \| '_ \ / _ \| '_ \    \ \ / / | || |_) |
 ___) | | | | (_) | |_) |    \ V /  | ||  __/
|____/|_| |_|\___/| .__/      \_/  |___|_|
                   |_|   by Moriistar
BANNER
echo -e "${NC}"
echo -e "${BOLD}ربات فروشگاه تلگرام — نصب خودکار${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $EUID -ne 0 ]] && error "با sudo اجرا کنید."

# ── تشخیص OS ──
if command -v apt-get &>/dev/null; then PKG="apt"
elif command -v yum &>/dev/null; then PKG="yum"
elif command -v dnf &>/dev/null; then PKG="dnf"
else error "OS پشتیبانی نمی‌شود."; fi

# ── نصب پیش‌نیازها ──
info "نصب PHP، Nginx، curl..."
if [[ $PKG == "apt" ]]; then
    apt-get update -qq
    apt-get install -y -qq php php-cli php-curl curl nginx openssl git
else
    $PKG install -y php php-cli php-curl curl nginx openssl git
fi
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
success "PHP $PHP_VER نصب شد."

INSTALL_DIR="/var/www/shop-vip"
mkdir -p "$INSTALL_DIR/data/users" "$INSTALL_DIR/data/products" "$INSTALL_DIR/data/codes"

# ══════════════════════════════════════════════
#   ساخت bot.php مستقیم داخل اسکریپت
# ══════════════════════════════════════════════
info "ساخت bot.php ..."
cat > "$INSTALL_DIR/bot.php" << 'BOTPHP'
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
  http_response_code(500);
  echo "Bot is not configured.";
  exit;
}

if ($WEBHOOK_SECRET !== '') {
  $header = $_SERVER['HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN'] ?? '';
  if ($header !== $WEBHOOK_SECRET) {
    http_response_code(403); echo "Forbidden"; exit;
  }
}

const DELIM = "(******)";

function ensureDir(string $dir): void {
  if (!is_dir($dir)) mkdir($dir, 0775, true);
}
function dataPath(string $rel): string {
  return __DIR__ . '/data/' . ltrim($rel, '/');
}
function readFileSafe(string $path, string $default = ''): string {
  return file_exists($path) ? (string)file_get_contents($path) : $default;
}
function writeFileSafe(string $path, string $content): void {
  ensureDir(dirname($path));
  file_put_contents($path, $content, LOCK_EX);
}
function userDir(int $userId): string { return dataPath("users/$userId"); }
function userFile(int $userId, string $name): string { return userDir($userId) . "/$name"; }
function getStep(int $userId): string { return readFileSafe(userFile($userId, 'step.txt'), 'none'); }
function setStep(int $userId, string $step): void { writeFileSafe(userFile($userId, 'step.txt'), $step); }
function getCoins(int $userId): int {
  $p = userFile($userId, 'coin.txt');
  if (!file_exists($p)) return 0;
  return (int)trim((string)file_get_contents($p));
}
function setCoins(int $userId, int $coins): void {
  writeFileSafe(userFile($userId, 'coin.txt'), (string)max(0, $coins));
}
function addCoins(int $userId, int $delta): int {
  $c = getCoins($userId) + $delta;
  setCoins($userId, $c);
  return $c;
}
function registerUserIfNeeded(int $userId): void {
  $dir = userDir($userId);
  if (!is_dir($dir)) {
    ensureDir($dir);
    setCoins($userId, 0);
    setStep($userId, 'none');
    $m = __DIR__ . '/Member.txt';
    $members = readFileSafe($m, '');
    if (strpos($members, "$userId\n") === false)
      writeFileSafe($m, $members . $userId . "\n");
  }
}
function getProductCount(): int {
  $p = dataPath('products/count.txt');
  if (!file_exists($p)) { writeFileSafe($p, '0'); return 0; }
  return (int)trim((string)file_get_contents($p));
}
function setProductCount(int $n): void { writeFileSafe(dataPath('products/count.txt'), (string)max(0,$n)); }
function productByIdPath(int $id): string { return dataPath("products/$id.txt"); }
function productTitleIndexPath(string $title): string { return dataPath("products/idx_" . md5($title) . ".idx"); }
function saveProduct(int $id, string $title, string $desc, string $link, int $price): void {
  writeFileSafe(productByIdPath($id), $title . DELIM . $desc . DELIM . $link . DELIM . $price);
  writeFileSafe(productTitleIndexPath($title), (string)$id);
}
function loadProductById(int $id): ?array {
  $p = productByIdPath($id);
  if (!file_exists($p)) return null;
  $a = explode(DELIM, (string)file_get_contents($p));
  return ['id'=>$id,'title'=>$a[0]??'','desc'=>$a[1]??'','link'=>$a[2]??'','price'=>(int)($a[3]??0)];
}
function findProductIdByTitle(string $title): ?int {
  $p = productTitleIndexPath($title);
  if (!file_exists($p)) return null;
  return (int)trim((string)file_get_contents($p));
}
function deleteProductById(int $id): bool {
  $prod = loadProductById($id);
  if (!$prod) return false;
  @unlink(productByIdPath($id));
  @unlink(productTitleIndexPath($prod['title']));
  return true;
}

function tg(string $method, array $params = []) {
  global $BOT_TOKEN;
  $ch = curl_init("https://api.telegram.org/bot{$BOT_TOKEN}/{$method}");
  curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER=>true,CURLOPT_POST=>true,
    CURLOPT_POSTFIELDS=>$params,CURLOPT_CONNECTTIMEOUT=>10,CURLOPT_TIMEOUT=>30]);
  $res = curl_exec($ch); curl_close($ch);
  return json_decode((string)$res, true);
}
function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES|ENT_SUBSTITUTE, 'UTF-8'); }
function sendMessage(int|string $chatId, string $text, array $replyKeyboard=null, array $inlineKeyboard=null): void {
  $p = ['chat_id'=>$chatId,'text'=>$text,'parse_mode'=>'HTML','disable_web_page_preview'=>false];
  if ($replyKeyboard !== null)
    $p['reply_markup'] = json_encode(['keyboard'=>$replyKeyboard,'resize_keyboard'=>true],JSON_UNESCAPED_UNICODE);
  elseif ($inlineKeyboard !== null)
    $p['reply_markup'] = json_encode(['inline_keyboard'=>$inlineKeyboard],JSON_UNESCAPED_UNICODE);
  tg('sendMessage', $p);
}
function answerCallback(string $id, string $text=''): void {
  tg('answerCallbackQuery',['callback_query_id'=>$id,'text'=>$text,'show_alert'=>false]);
}

function mainMenu(): array {
  return [
    [['text'=>'فروشگاه 🛒'],['text'=>'افزایش موجودی 💳']],
    [['text'=>'کد هدیه 🛍'],['text'=>'حساب کاربری 🔖']],
    [['text'=>'👥پشتیبانی'],['text'=>'خرید پک VIP 🎬']],
  ];
}
function backMenu(): array { return [[['text'=>'بازگشت']]]; }
function adminMenu(): array {
  return [
    [['text'=>'محصول جدید'],['text'=>'حذف محصول']],
    [['text'=>'ساخت کد هدیه'],['text'=>'اهدای سکه']],
    [['text'=>'کم کردن سکه']],
    [['text'=>'بازگشت']],
  ];
}

function showWelcome(int $chatId, int $userId, ?int $refId): void {
  registerUserIfNeeded($userId);
  if ($refId !== null && $refId !== $userId) {
    registerUserIfNeeded($refId);
    addCoins($refId, 1);
    sendMessage($refId, "یک نفر از طریق لینک شما وارد شد ✅\n+1 سکه ثبت شد.");
  }
  sendMessage($chatId, "سلام، خوش آمدید 👋\n\nاز منوی زیر بخش موردنظر را انتخاب کنید.", mainMenu());
}
function showAccount(int $chatId, int $userId, string $name, string $username=''): void {
  $coin = getCoins($userId);
  $u = $username ? "@$username" : "—";
  sendMessage($chatId,
    "👤 <b>حساب کاربری</b>\n\nنام: <b>".h($name)."</b>\nیوزرنیم: <b>".h($u)."</b>\nموجودی: <b>$coin سکه</b>\nشناسه: <code>$userId</code>",
    mainMenu());
}
function showSupport(int $chatId): void {
  sendMessage($chatId,
    "👥 <b>پشتیبانی</b>\n\n1) سوال تکراری نپرسید\n2) اسپم نکنید\n\n<b>@YourSupportID</b>",
    mainMenu());
}
function showTopUp(int $chatId, int $userId): void {
  $txt = "💳 <b>افزایش موجودی</b>\n\n100 سکه = 100 تومان\n200 سکه با 10% تخفیف = 180 تومان\n300 سکه با 15% تخفیف = 255 تومان\n400 سکه با 20% تخفیف = 320 تومان\n640 سکه با 25% تخفیف = 480 تومان\n960 سکه با 30% تخفیف = 672 تومان\n\n⚠️ شناسه خود را در توضیحات پرداخت وارد کنید:\n<code>$userId</code>\n\nیکی از گزینه‌های زیر را انتخاب کنید:";
  $pay = [
    ['coin'=>100,'env'=>'PAY_100_URL'],['coin'=>200,'env'=>'PAY_200_URL'],
    ['coin'=>300,'env'=>'PAY_300_URL'],['coin'=>400,'env'=>'PAY_400_URL'],
    ['coin'=>640,'env'=>'PAY_640_URL'],['coin'=>960,'env'=>'PAY_960_URL'],
  ];
  $inline = [];
  foreach ($pay as $p) {
    $url = (string)env($p['env'],'');
    $label = "💰 {$p['coin']} سکه";
    $inline[] = $url === ''
      ? [['text'=>$label.' (تنظیم نشده)','callback_data'=>'noop']]
      : [['text'=>$label,'url'=>$url]];
  }
  sendMessage($chatId, $txt, null, $inline);
}
function showVipPacks(int $chatId, int $userId): void {
  setStep($userId, 'vip_select');
  sendMessage($chatId,
    "🎬 <b>خرید پک VIP</b>\n\n1- پک‌های VIP\n2- پک‌های فیلم\n3- پک‌های ایرانی 🇮🇷\n4- پک‌های اقتصادی\n5- پک‌های ترکی\n6- پک‌های دوبله\n7- پک VIP 2\n8- پک فیلم VIP\n9- پک تخفیف ویژه\n\nعدد 1 تا 9 را ارسال کنید:",
    [[['text'=>'1'],['text'=>'2'],['text'=>'3']],[['text'=>'4'],['text'=>'5'],['text'=>'6']],[['text'=>'7'],['text'=>'8'],['text'=>'9']],[['text'=>'بازگشت']]]);
}
function showShop(int $chatId): void {
  $count = getProductCount();
  if ($count <= 0) { sendMessage($chatId, "فعلاً محصولی ثبت نشده است.", mainMenu()); return; }
  $kb = [];
  for ($i=1; $i<=$count; $i++) {
    $p = loadProductById($i);
    if ($p) $kb[] = [['text'=>$p['title']]];
  }
  $kb[] = [['text'=>'بازگشت']];
  sendMessage($chatId, "🛒 <b>محصولات</b>\n\nروی نام محصول بزنید:", $kb);
}
function showProductDetails(int $chatId, string $title): void {
  $id = findProductIdByTitle($title);
  if (!$id) { sendMessage($chatId, "محصول یافت نشد.", mainMenu()); return; }
  $p = loadProductById($id);
  if (!$p) { sendMessage($chatId, "محصول یافت نشد.", mainMenu()); return; }
  sendMessage($chatId,
    "🧾 <b>".h($p['title'])."</b>\n\n📌 ".h($p['desc'])."\n\n💰 قیمت: <b>{$p['price']} سکه</b>\n\n✅ برای خرید:\n<code>/buy{$p['id']}</code>",
    [[['text'=>'فروشگاه 🛒'],['text'=>'بازگشت']]]);
}
function redeemCode(int $chatId, int $userId, string $code): void {
  if (!preg_match('/^[a-zA-Z0-9_\-]{3,32}$/', $code)) {
    sendMessage($chatId, "کد نامعتبر است.", mainMenu()); setStep($userId,'none'); return;
  }
  $cp = dataPath("codes/$code.txt");
  if (!file_exists($cp)) {
    sendMessage($chatId, "کد وارد شده اشتباه است.", mainMenu()); setStep($userId,'none'); return;
  }
  $value = (int)trim((string)file_get_contents($cp));
  @unlink($cp);
  $new = addCoins($userId, $value);
  setStep($userId,'none');
  sendMessage($chatId, "✅ <b>$value سکه</b> به حساب شما اضافه شد.\nموجودی: <b>$new</b>", mainMenu());
}
function adminRequire(int $chatId, int $fromId): bool {
  global $ADMIN_ID;
  if ($fromId !== $ADMIN_ID) { sendMessage($chatId,"⛔️ دسترسی ادمین ندارید.",mainMenu()); return false; }
  return true;
}

$raw = file_get_contents('php://input');
$update = json_decode((string)$raw, true);
if (!is_array($update)) { http_response_code(200); echo "OK"; exit; }

if (isset($update['CustomField'])||isset($update['Title'])) {
  http_response_code(200); echo "PAYMENT_OK"; exit;
}

$message  = $update['message'] ?? null;
$callback = $update['callback_query'] ?? null;

if ($callback) {
  $cbId = $callback['id'] ?? '';
  $data = $callback['data'] ?? '';
  answerCallback($cbId, $data==='noop'?'لینک پرداخت تنظیم نشده است':'');
  http_response_code(200); echo "OK"; exit;
}
if (!$message) { http_response_code(200); echo "OK"; exit; }

$chatId   = (int)($message['chat']['id']??0);
$fromId   = (int)($message['from']['id']??0);
$name     = (string)($message['from']['first_name']??'کاربر');
$username = (string)($message['from']['username']??'');
$text     = (string)($message['text']??'');

if ($chatId===0||$fromId===0) { http_response_code(200); echo "OK"; exit; }
registerUserIfNeeded($fromId);

$step = getStep($fromId);

if ($text==='/cancel'||$text==='بازگشت') {
  setStep($fromId,'none'); sendMessage($chatId,"✅ لغو شد.",mainMenu());
  http_response_code(200); echo "OK"; exit;
}
if (str_starts_with($text,'/start')) {
  $parts=explode(' ',$text,2);
  $ref=isset($parts[1])&&trim($parts[1])!==''?(int)trim($parts[1]):null;
  if($ref<=0)$ref=null;
  showWelcome($chatId,$fromId,$ref); setStep($fromId,'none');
  http_response_code(200); echo "OK"; exit;
}
if ($text==='/panel') {
  if(!adminRequire($chatId,$fromId)){http_response_code(200);echo "OK";exit;}
  setStep($fromId,'none'); sendMessage($chatId,"پنل مدیریت:",adminMenu());
  http_response_code(200); echo "OK"; exit;
}

// Step handlers
if (str_starts_with($step,'admin_')&&!adminRequire($chatId,$fromId)){http_response_code(200);echo "OK";exit;}

if($step==='use_code'){redeemCode($chatId,$fromId,trim($text));http_response_code(200);echo "OK";exit;}
if($step==='vip_select'){
  if(preg_match('/^[1-9]$/',trim($text))){
    $n=(int)trim($text); setStep($fromId,'none');
    sendMessage($chatId,"✅ پک شماره <b>$n</b> انتخاب شد.\n\nبرای مشاهده محصولات به فروشگاه بروید.",mainMenu());
  }else{sendMessage($chatId,"فقط عدد 1 تا 9 یا «بازگشت».",backMenu());}
  http_response_code(200);echo "OK";exit;
}
if($step==='admin_set_title'){
  $t=trim($text); if($t===''){sendMessage($chatId,"عنوان خالی نباشد.",backMenu());http_response_code(200);echo "OK";exit;}
  writeFileSafe(userFile($fromId,'tmp_title.txt'),$t); setStep($fromId,'admin_set_desc');
  sendMessage($chatId,"توضیحات محصول را ارسال کنید:",backMenu()); http_response_code(200);echo "OK";exit;
}
if($step==='admin_set_desc'){
  writeFileSafe(userFile($fromId,'tmp_desc.txt'),trim($text)); setStep($fromId,'admin_set_link');
  sendMessage($chatId,"لینک تحویل را ارسال کنید:",backMenu()); http_response_code(200);echo "OK";exit;
}
if($step==='admin_set_link'){
  writeFileSafe(userFile($fromId,'tmp_link.txt'),trim($text)); setStep($fromId,'admin_set_price');
  sendMessage($chatId,"قیمت (سکه) را ارسال کنید:",backMenu()); http_response_code(200);echo "OK";exit;
}
if($step==='admin_set_price'){
  $price=(int)trim($text); if($price<=0){sendMessage($chatId,"قیمت باید مثبت باشد.",backMenu());http_response_code(200);echo "OK";exit;}
  $title=readFileSafe(userFile($fromId,'tmp_title.txt'),'');
  $desc=readFileSafe(userFile($fromId,'tmp_desc.txt'),'');
  $link=readFileSafe(userFile($fromId,'tmp_link.txt'),'');
  $newId=getProductCount()+1;
  saveProduct($newId,$title,$desc,$link,$price); setProductCount($newId); setStep($fromId,'none');
  sendMessage($chatId,"✅ محصول ثبت شد. آیدی: <b>$newId</b>",adminMenu()); http_response_code(200);echo "OK";exit;
}
if($step==='admin_del_product'){
  $id=(int)trim($text); if($id<=0){sendMessage($chatId,"آیدی نامعتبر.",backMenu());http_response_code(200);echo "OK";exit;}
  $ok=deleteProductById($id); setStep($fromId,'none');
  sendMessage($chatId,$ok?"✅ محصول حذف شد.":"محصول پیدا نشد.",adminMenu()); http_response_code(200);echo "OK";exit;
}
if($step==='admin_create_code'){
  $pts=preg_split('/\s+/',trim($text));
  if(count($pts)<2){sendMessage($chatId,"فرمت:\n<code>ABC123 50</code>",backMenu());http_response_code(200);echo "OK";exit;}
  $code=$pts[0]; $val=(int)$pts[1];
  if($val<=0){sendMessage($chatId,"مقدار باید مثبت باشد.",backMenu());http_response_code(200);echo "OK";exit;}
  writeFileSafe(dataPath("codes/$code.txt"),(string)$val); setStep($fromId,'none');
  sendMessage($chatId,"✅ کد: <code>$code</code>\nمقدار: <b>$val سکه</b>",adminMenu()); http_response_code(200);echo "OK";exit;
}
if($step==='admin_add_coins'||$step==='admin_remove_coins'){
  $pts=preg_split('/\s+/',trim($text));
  if(count($pts)<2){sendMessage($chatId,"فرمت:\n<code>123456789 20</code>",backMenu());http_response_code(200);echo "OK";exit;}
  $uid=(int)$pts[0]; $val=(int)$pts[1];
  if($uid<=0||$val<=0){sendMessage($chatId,"مقادیر نامعتبر.",backMenu());http_response_code(200);echo "OK";exit;}
  registerUserIfNeeded($uid);
  if($step==='admin_add_coins'){
    addCoins($uid,$val); sendMessage($uid,"✅ <b>$val سکه</b> به حساب شما اضافه شد.");
    sendMessage($chatId,"✅ انجام شد.",adminMenu());
  }else{
    addCoins($uid,-$val); sendMessage($uid,"⚠️ <b>$val سکه</b> از حساب شما کم شد.");
    sendMessage($chatId,"✅ انجام شد.",adminMenu());
  }
  setStep($fromId,'none'); http_response_code(200);echo "OK";exit;
}

// Text routing
switch($text){
  case 'فروشگاه 🛒': setStep($fromId,'none'); showShop($chatId); break;
  case 'افزایش موجودی 💳': setStep($fromId,'none'); showTopUp($chatId,$fromId); break;
  case 'کد هدیه 🛍': setStep($fromId,'use_code'); sendMessage($chatId,"کد را ارسال کنید:",backMenu()); break;
  case 'حساب کاربری 🔖': setStep($fromId,'none'); showAccount($chatId,$fromId,$name,$username); break;
  case '👥پشتیبانی': setStep($fromId,'none'); showSupport($chatId); break;
  case 'خرید پک VIP 🎬': showVipPacks($chatId,$fromId); break;
  case 'محصول جدید': setStep($fromId,'admin_set_title'); sendMessage($chatId,"عنوان محصول:",backMenu()); break;
  case 'حذف محصول': setStep($fromId,'admin_del_product'); sendMessage($chatId,"آیدی محصول:",backMenu()); break;
  case 'ساخت کد هدیه': setStep($fromId,'admin_create_code'); sendMessage($chatId,"فرمت:\n<code>CODE مقدار</code>",backMenu()); break;
  case 'اهدای سکه': setStep($fromId,'admin_add_coins'); sendMessage($chatId,"فرمت:\n<code>USERID مقدار</code>",backMenu()); break;
  case 'کم کردن سکه': setStep($fromId,'admin_remove_coins'); sendMessage($chatId,"فرمت:\n<code>USERID مقدار</code>",backMenu()); break;
  default:
    if(preg_match('/^\/buy(\d+)$/',trim($text),$m)){
      $id=(int)$m[1]; $p=loadProductById($id);
      if(!$p){sendMessage($chatId,"محصول موجود نیست.",mainMenu());break;}
      $coin=getCoins($fromId);
      if($coin<(int)$p['price']){sendMessage($chatId,"❌ موجودی کافی نیست.\nموجودی: <b>$coin</b>\nقیمت: <b>{$p['price']}</b>",mainMenu());break;}
      setCoins($fromId,$coin-(int)$p['price']);
      sendMessage($chatId,"✅ خرید موفق!\n\n<a href=\"".h($p['link'])."\">👆 دریافت محصول</a>",mainMenu());
      break;
    }
    if(preg_match('/^\/transfer\s+(\d+)\s+(\d+)$/',trim($text),$m)){
      $to=(int)$m[1]; $amount=(int)$m[2];
      if($amount<1){sendMessage($chatId,"حداقل 1 سکه.",mainMenu());break;}
      registerUserIfNeeded($to); $have=getCoins($fromId);
      if($have<$amount){sendMessage($chatId,"موجودی کافی نیست. موجودی: <b>$have</b>",mainMenu());break;}
      setCoins($fromId,$have-$amount); addCoins($to,$amount);
      sendMessage($chatId,"✅ <b>$amount سکه</b> به <code>$to</code> ارسال شد.",mainMenu());
      sendMessage($to,"✅ <b>$amount سکه</b> از <code>$fromId</code> دریافت شد.");
      break;
    }
    $pid=findProductIdByTitle($text);
    if($pid){showProductDetails($chatId,$text);break;}
    sendMessage($chatId,"دستور یافت نشد.",mainMenu());
}
http_response_code(200);
echo "OK";
BOTPHP

success "bot.php ساخته شد."

# ══════════════════════════════════════════════
#   دریافت اطلاعات از کاربر
# ══════════════════════════════════════════════
echo ""
echo -e "${BOLD}━━━ تنظیمات ربات ━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}توکن ربات (BOT_TOKEN):${NC} ")" BOT_TOKEN
[[ -z "$BOT_TOKEN" ]] && error "توکن الزامی است."

read -rp "$(echo -e "${YELLOW}آیدی عددی ادمین (ADMIN_ID):${NC} ")" ADMIN_ID
[[ -z "$ADMIN_ID" ]] && error "آیدی ادمین الزامی است."

read -rp "$(echo -e "${YELLOW}نام ربات [Shop Bot]:${NC} ")" BOT_NAME
BOT_NAME="${BOT_NAME:-Shop Bot}"

read -rp "$(echo -e "${YELLOW}دامنه سرور (مثال: bot.example.com):${NC} ")" DOMAIN
[[ -z "$DOMAIN" ]] && error "دامنه الزامی است."

WEBHOOK_SECRET=$(openssl rand -hex 24)

echo ""
echo -e "${CYAN}لینک‌های پرداخت (اختیاری — Enter برای رد):${NC}"
read -rp "  PAY_100_URL : " PAY_100
read -rp "  PAY_200_URL : " PAY_200
read -rp "  PAY_300_URL : " PAY_300
read -rp "  PAY_400_URL : " PAY_400
read -rp "  PAY_640_URL : " PAY_640
read -rp "  PAY_960_URL : " PAY_960

# ── ساخت .env ──
cat > "$INSTALL_DIR/.env" <<ENVEOF
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
ENVEOF
chmod 600 "$INSTALL_DIR/.env"
success ".env ساخته شد."

# ── تنظیم Nginx ──
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

# ── PHP-FPM ──
systemctl enable php${PHP_VER}-fpm --now 2>/dev/null || \
systemctl enable php-fpm --now 2>/dev/null || true

# ── مجوزها ──
chown -R www-data:www-data "$INSTALL_DIR" 2>/dev/null || true
chmod -R 755 "$INSTALL_DIR"
chmod -R 775 "$INSTALL_DIR/data"
chmod 600 "$INSTALL_DIR/.env"

nginx -t && systemctl reload nginx
success "Nginx راه‌اندازی شد."

# ── SSL ──
echo ""
read -rp "$(echo -e "${YELLOW}نصب SSL رایگان (Let's Encrypt)؟ [y/N]:${NC} ")" DO_SSL
SCHEME="http"
if [[ "${DO_SSL,,}" == "y" ]]; then
    apt-get install -y -qq certbot python3-certbot-nginx 2>/dev/null || \
    $PKG install -y certbot python3-certbot-nginx
    read -rp "$(echo -e "${YELLOW}ایمیل برای SSL:${NC} ")" SSL_EMAIL
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$SSL_EMAIL" \
        && { success "SSL نصب شد."; SCHEME="https"; } \
        || warn "SSL نصب نشد. بعداً اقدام کنید."
fi

# ── ثبت Webhook ──
info "ثبت Webhook..."
WEBHOOK_URL="${SCHEME}://${DOMAIN}/bot.php"
RESP=$(curl -s -X POST \
    "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
    -d "url=${WEBHOOK_URL}" \
    -d "secret_token=${WEBHOOK_SECRET}" \
    -d "allowed_updates=[\"message\",\"callback_query\"]")

if echo "$RESP" | grep -q '"ok":true'; then
    success "Webhook ثبت شد!"
else
    warn "مشکل در ثبت Webhook: $RESP"
fi

# ── پایان ──
echo ""
echo -e "${BOLD}${GREEN}━━━ نصب کامل شد! ━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  📂 مسیر    : ${CYAN}${INSTALL_DIR}${NC}"
echo -e "  🔗 Webhook : ${CYAN}${WEBHOOK_URL}${NC}"
echo -e "  🔑 Secret  : ${CYAN}${WEBHOOK_SECRET}${NC}"
echo ""
echo -e "${YELLOW}⚠️  فایل .env رو در GitHub آپلود نکنید!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
