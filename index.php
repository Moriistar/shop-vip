<?php
declare(strict_types=1);

/*
  One-file Telegram Shop Bot (Public-safe)
  - Reads secrets from .env (DO NOT commit .env)
  - File-based storage in /data
  - Admin panel: add product, delete product, create gift code, add/remove coins
  - User: shop list, buy with coins, redeem code, account, support, top-up page with discount table + pay buttons
*/

date_default_timezone_set('Asia/Tehran');

/* =========================
   0) Minimal .env loader
========================= */
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
  echo "Bot is not configured. Please set BOT_TOKEN and ADMIN_ID in .env";
  exit;
}

/* =========================
   1) Security: webhook secret (optional)
========================= */
if ($WEBHOOK_SECRET !== '') {
  $header = $_SERVER['HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN'] ?? '';
  if ($header !== $WEBHOOK_SECRET) {
    http_response_code(403);
    echo "Forbidden";
    exit;
  }
}

/* =========================
   2) Storage helpers
========================= */
const DELIM = "(******)";

function ensureDir(string $dir): void {
  if (!is_dir($dir)) {
    mkdir($dir, 0775, true);
  }
}

function dataPath(string $rel): string {
  return __DIR__ . '/data/' . ltrim($rel, '/');
}

function readFileSafe(string $path, string $default = ''): string {
  return file_exists($path) ? (string)file_get_contents($path) : $default;
}

function writeFileSafe(string $path, string $content): void {
  $dir = dirname($path);
  ensureDir($dir);
  file_put_contents($path, $content, LOCK_EX);
}

function userDir(int $userId): string {
  return dataPath("users/$userId");
}

function userFile(int $userId, string $name): string {
  return userDir($userId) . "/$name";
}

function getStep(int $userId): string {
  return readFileSafe(userFile($userId, 'step.txt'), 'none');
}

function setStep(int $userId, string $step): void {
  writeFileSafe(userFile($userId, 'step.txt'), $step);
}

function getCoins(int $userId): int {
  $p = userFile($userId, 'coin.txt');
  if (!file_exists($p)) return 0;
  return (int)trim((string)file_get_contents($p));
}

function setCoins(int $userId, int $coins): void {
  writeFileSafe(userFile($userId, 'coin.txt'), (string)max(0, $coins));
}

function addCoins(int $userId, int $delta): int {
  $c = getCoins($userId);
  $c += $delta;
  setCoins($userId, $c);
  return $c;
}

function registerUserIfNeeded(int $userId): void {
  $dir = userDir($userId);
  if (!is_dir($dir)) {
    ensureDir($dir);
    setCoins($userId, 0);
    setStep($userId, 'none');
    // member list
    $m = __DIR__ . '/Member.txt';
    $members = readFileSafe($m, '');
    writeFileSafe($m, $members . $userId . "\n");
  }
}

function productCountPath(): string {
  return dataPath('products/count.txt');
}

function getProductCount(): int {
  $p = productCountPath();
  if (!file_exists($p)) {
    ensureDir(dirname($p));
    writeFileSafe($p, '0');
    return 0;
  }
  return (int)trim((string)file_get_contents($p));
}

function setProductCount(int $n): void {
  writeFileSafe(productCountPath(), (string)max(0, $n));
}

function productByIdPath(int $id): string {
  return dataPath("products/$id.txt");
}

function productTitleIndexPath(string $title): string {
  // title->id index
  return dataPath("products/" . $title . ".idx");
}

function saveProduct(int $id, string $title, string $desc, string $successLink, int $priceCoins): void {
  $content = $title . DELIM . $desc . DELIM . $successLink . DELIM . $priceCoins;
  writeFileSafe(productByIdPath($id), $content);
  writeFileSafe(productTitleIndexPath($title), (string)$id);
}

function loadProductById(int $id): ?array {
  $p = productByIdPath($id);
  if (!file_exists($p)) return null;
  $raw = (string)file_get_contents($p);
  $a = explode(DELIM, $raw);
  return [
    'id' => $id,
    'title' => $a[0] ?? '',
    'desc' => $a[1] ?? '',
    'link' => $a[2] ?? '',
    'price' => (int)($a[3] ?? 0),
  ];
}

function findProductIdByTitle(string $title): ?int {
  $p = productTitleIndexPath($title);
  if (!file_exists($p)) return null;
  return (int)trim((string)file_get_contents($p));
}

function deleteProductById(int $id): bool {
  $prod = loadProductById($id);
  if (!$prod) return false;
  $title = $prod['title'];
  @unlink(productByIdPath($id));
  @unlink(productTitleIndexPath($title));
  return true;
}

/* =========================
   3) Telegram API
========================= */
function tg(string $method, array $params = []) {
  global $BOT_TOKEN;
  $url = "https://api.telegram.org/bot{$BOT_TOKEN}/{$method}";
  $ch = curl_init($url);
  curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
  curl_setopt($ch, CURLOPT_POST, true);
  curl_setopt($ch, CURLOPT_POSTFIELDS, $params);
  curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 10);
  curl_setopt($ch, CURLOPT_TIMEOUT, 60);
  $res = curl_exec($ch);
  $err = curl_error($ch);
  curl_close($ch);
  if ($err) return null;
  $j = json_decode((string)$res, true);
  return $j;
}

function h(string $s): string {
  // HTML escape
  return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function sendMessage(int|string $chatId, string $text, array $replyKeyboard = null, array $inlineKeyboard = null): void {
  $payload = [
    'chat_id' => $chatId,
    'text' => $text,
    'parse_mode' => 'HTML',
    'disable_web_page_preview' => false
  ];

  if ($replyKeyboard !== null) {
    $payload['reply_markup'] = json_encode([
      'keyboard' => $replyKeyboard,
      'resize_keyboard' => true
    ], JSON_UNESCAPED_UNICODE);
  } elseif ($inlineKeyboard !== null) {
    $payload['reply_markup'] = json_encode([
      'inline_keyboard' => $inlineKeyboard
    ], JSON_UNESCAPED_UNICODE);
  }

  tg('sendMessage', $payload);
}

function answerCallback(string $callbackId, string $text = ''): void {
  tg('answerCallbackQuery', [
    'callback_query_id' => $callbackId,
    'text' => $text,
    'show_alert' => false
  ]);
}

/* =========================
   4) Keyboards (UI)
========================= */
function mainMenu(): array {
  return [
    [ ['text' => 'فروشگاه 🛒'], ['text' => 'افزایش موجودی 💳'] ],
    [ ['text' => 'کد هدیه 🛍'], ['text' => 'حساب کاربری 🔖'] ],
    [ ['text' => '👥پشتیبانی'], ['text' => 'خرید پک VIP 🎬'] ],
  ];
}

function backMenu(): array {
  return [
    [ ['text' => 'بازگشت'] ]
  ];
}

function adminMenu(): array {
  return [
    [ ['text' => 'محصول جدید'], ['text' => 'حذف محصول'] ],
    [ ['text' => 'ساخت کد هدیه'], ['text' => 'اهدای سکه'] ],
    [ ['text' => 'کم کردن سکه'] ],
    [ ['text' => 'بازگشت'] ],
  ];
}

/* =========================
   5) Business logic
========================= */
function showWelcome(int $chatId, int $userId, ?int $refId): void {
  registerUserIfNeeded($userId);

  if ($refId !== null && $refId !== $userId) {
    // Referral reward (optional): +1 coin
    registerUserIfNeeded($refId);
    addCoins($refId, 1);
    sendMessage($refId, "یک نفر از طریق لینک شما وارد ربات شد ✅\n+1 سکه برای شما ثبت شد.");
  }

  $txt =
    "سلام، خوش آمدید.\n\n"
    . "این یک ربات فروشگاه دیجیتال است.\n"
    . "از منوی زیر بخش موردنظر را انتخاب کنید.";
  sendMessage($chatId, $txt, mainMenu());
}

function showAccount(int $chatId, int $userId, string $name, string $username = ''): void {
  $coin = getCoins($userId);
  $u = $username ? "@$username" : "—";
  $txt =
    "👤 <b>حساب کاربری</b>\n\n"
    . "نام: <b>" . h($name) . "</b>\n"
    . "یوزرنیم: <b>" . h($u) . "</b>\n"
    . "موجودی سکه: <b>$coin</b>\n"
    . "شناسه شما: <code>$userId</code>";
  sendMessage($chatId, $txt, mainMenu());
}

function showSupport(int $chatId): void {
  $txt =
    "👥 <b>پشتیبانی</b>\n\n"
    . "قبل از پیام دادن:\n"
    . "1) سوال تکراری نپرسید\n"
    . "2) اسپم نکنید\n"
    . "3) درخواست غیرمنطقی ارسال نکنید\n\n"
    . "آیدی پشتیبانی را در اینجا قرار دهید:\n"
    . "<b>@YourSupportID</b>";
  sendMessage($chatId, $txt, mainMenu());
}

function showTopUp(int $chatId, int $userId): void {
  // Discount table like screenshots [Source](https://www.genspark.ai/api/files/s/vz1Pr99n)
  $txt =
    "💳 <b>افزایش موجودی</b>\n\n"
    . "100 سکه = 100 تومان\n"
    . "200 سکه با 10% تخفیف = 180 تومان\n"
    . "300 سکه با 15% تخفیف = 255 تومان\n"
    . "400 سکه با 20% تخفیف = 320 تومان\n"
    . "640 سکه با 25% تخفیف = 480 تومان\n"
    . "960 سکه با 30% تخفیف = 672 تومان\n\n"
    . "⚠️ حتماً در پرداخت، شناسه زیر را در بخش «شناسه/کد/توضیحات» وارد کنید:\n"
    . "<code>$userId</code>\n\n"
    . "یکی از گزینه‌های زیر را برای پرداخت انتخاب کنید:";

  $pay = [
    ['coin' => 100, 'env' => 'PAY_100_URL'],
    ['coin' => 200, 'env' => 'PAY_200_URL'],
    ['coin' => 300, 'env' => 'PAY_300_URL'],
    ['coin' => 400, 'env' => 'PAY_400_URL'],
    ['coin' => 640, 'env' => 'PAY_640_URL'],
    ['coin' => 960, 'env' => 'PAY_960_URL'],
  ];

  $inline = [];
  foreach ($pay as $p) {
    $url = (string)env($p['env'], '');
    $label = "💰 {$p['coin']} سکه";
    if ($url === '') {
      $inline[] = [
        [ 'text' => $label . " (لینک تنظیم نشده)", 'callback_data' => 'noop' ]
      ];
    } else {
      $inline[] = [
        [ 'text' => $label, 'url' => $url ]
      ];
    }
  }

  sendMessage($chatId, $txt, null, $inline);
}

function showVipPacks(int $chatId): void {
  // Similar to screenshot pack selection [Source](https://www.genspark.ai/api/files/s/jdWyL9OY)
  $txt =
    "🎬 <b>خرید پک VIP</b>\n\n"
    . "یکی از پک‌های زیر را انتخاب کنید:\n"
    . "1- مجموعه پک‌های #VIP\n"
    . "2- مجموعه پک‌های #فیلم\n"
    . "3- مجموعه پک‌های #ایرانی 🇮🇷\n"
    . "4- مجموعه پک‌های #اقتصادی\n"
    . "5- مجموعه پک‌های #ترکی\n"
    . "6- مجموعه پک‌های #دوبله\n"
    . "7- مجموعه پک‌های VIP 2\n"
    . "8- مجموعه پک‌های فیلم VIP\n"
    . "9- مجموعه پک‌های تخفیف ویژه\n\n"
    . "عدد را ارسال کنید (1 تا 9).";

  setStep((int)$chatId, 'vip_select'); // step by userId==chatId in private chats
  sendMessage($chatId, $txt, [
    [ ['text'=>'1'], ['text'=>'2'], ['text'=>'3'] ],
    [ ['text'=>'4'], ['text'=>'5'], ['text'=>'6'] ],
    [ ['text'=>'7'], ['text'=>'8'], ['text'=>'9'] ],
    [ ['text'=>'بازگشت'] ],
  ]);
}

function showShop(int $chatId): void {
  $count = getProductCount();
  if ($count <= 0) {
    sendMessage($chatId, "فعلاً محصولی ثبت نشده است.", mainMenu());
    return;
  }

  $keyboard = [];
  for ($i = 1; $i <= $count; $i++) {
    $prod = loadProductById($i);
    if (!$prod) continue;
    $keyboard[] = [ ['text' => $prod['title']] ];
  }
  $keyboard[] = [ ['text' => 'بازگشت'] ];

  sendMessage($chatId, "🛒 <b>محصولات</b>\n\nبرای مشاهده جزئیات روی نام محصول بزنید:", $keyboard);
}

function showProductDetails(int $chatId, string $title): void {
  $id = findProductIdByTitle($title);
  if (!$id) {
    sendMessage($chatId, "محصول یافت نشد.", mainMenu());
    return;
  }
  $prod = loadProductById($id);
  if (!$prod) {
    sendMessage($chatId, "محصول یافت نشد.", mainMenu());
    return;
  }

  $txt =
    "🧾 <b>نام محصول:</b> " . h($prod['title']) . "\n\n"
    . "📌 <b>توضیحات:</b>\n" . h($prod['desc']) . "\n\n"
    . "💰 <b>قیمت:</b> " . (int)$prod['price'] . " سکه\n\n"
    . "✅ برای خرید:\n"
    . "<code>/buy{$prod['id']}</code>";

  sendMessage($chatId, $txt, [
    [ ['text' => 'فروشگاه 🛒'], ['text' => 'افزایش موجودی 💳'] ],
    [ ['text' => 'بازگشت'] ],
  ]);
}

function redeemCode(int $chatId, int $userId, string $code): void {
  $codePath = dataPath("codes/$code.txt");
  if (!file_exists($codePath)) {
    sendMessage($chatId, "کد وارد شده نامعتبر است.", mainMenu());
    setStep($userId, 'none');
    return;
  }
  $value = (int)trim((string)file_get_contents($codePath));
  @unlink($codePath);

  $new = addCoins($userId, $value);
  setStep($userId, 'none');

  sendMessage($chatId, "✅ موجودی شما به مقدار <b>$value</b> افزایش یافت.\nموجودی جدید: <b>$new</b>", mainMenu());
}

/* =========================
   6) Admin workflows (steps)
========================= */
function adminRequire(int $chatId, int $fromId): bool {
  global $ADMIN_ID;
  if ($fromId !== $ADMIN_ID) {
    sendMessage($chatId, "⛔️ شما دسترسی ادمین ندارید.", mainMenu());
    return false;
  }
  return true;
}

function adminStartAddProduct(int $chatId, int $fromId): void {
  if (!adminRequire($chatId, $fromId)) return;
  setStep($fromId, 'admin_set_title');
  sendMessage($chatId, "عنوان محصول را ارسال کنید:", backMenu());
}

function adminStartDeleteProduct(int $chatId, int $fromId): void {
  if (!adminRequire($chatId, $fromId)) return;
  setStep($fromId, 'admin_del_product');
  sendMessage($chatId, "آیدی محصول را ارسال کنید (مثلاً 3):", backMenu());
}

function adminStartCreateCode(int $chatId, int $fromId): void {
  if (!adminRequire($chatId, $fromId)) return;
  setStep($fromId, 'admin_create_code');
  sendMessage($chatId, "کد و مقدار را ارسال کنید:\nمثال:\n<code>ABC123 50</code>", backMenu());
}

function adminStartAddCoins(int $chatId, int $fromId): void {
  if (!adminRequire($chatId, $fromId)) return;
  setStep($fromId, 'admin_add_coins');
  sendMessage($chatId, "فرمت:\n<code>USERID COINS</code>\nمثال:\n<code>123456789 20</code>", backMenu());
}

function adminStartRemoveCoins(int $chatId, int $fromId): void {
  if (!adminRequire($chatId, $fromId)) return;
  setStep($fromId, 'admin_remove_coins');
  sendMessage($chatId, "فرمت:\n<code>USERID COINS</code>\nمثال:\n<code>123456789 10</code>", backMenu());
}

/* =========================
   7) Entry: parse webhook
========================= */
$payloadRaw = file_get_contents('php://input');
$update = json_decode((string)$payloadRaw, true);

if (!is_array($update)) {
  http_response_code(200);
  echo "OK";
  exit;
}

/*
  If you later want payment callback in same file, you can detect it here.
  For public safety and clarity, keep payment callback separate.
*/
if (isset($update['CustomField']) || isset($update['Title'])) {
  // Placeholder: You can implement gateway callback safely here if needed.
  http_response_code(200);
  echo "PAYMENT_OK";
  exit;
}

// Telegram update:
$message = $update['message'] ?? null;
$callback = $update['callback_query'] ?? null;

if ($callback) {
  $cbId = $callback['id'] ?? '';
  $data = $callback['data'] ?? '';
  if ($data === 'noop') {
    answerCallback($cbId, 'لینک پرداخت هنوز تنظیم نشده است.');
  } else {
    answerCallback($cbId);
  }
  http_response_code(200);
  echo "OK";
  exit;
}

if (!$message) {
  http_response_code(200);
  echo "OK";
  exit;
}

$chatId = (int)($message['chat']['id'] ?? 0);
$fromId = (int)($message['from']['id'] ?? 0);
$name = (string)($message['from']['first_name'] ?? 'کاربر');
$username = (string)($message['from']['username'] ?? '');
$text = (string)($message['text'] ?? '');

registerUserIfNeeded($fromId);

if ($chatId === 0 || $fromId === 0) {
  http_response_code(200);
  echo "OK";
  exit;
}

/* =========================
   8) Commands & routing
========================= */
$step = getStep($fromId);

if ($text === '/cancel' || $text === 'بازگشت') {
  setStep($fromId, 'none');
  sendMessage($chatId, "✅ عملیات لغو شد.", mainMenu());
  http_response_code(200);
  echo "OK";
  exit;
}

if (str_starts_with($text, '/start')) {
  $ref = null;
  $parts = explode(' ', $text, 2);
  if (isset($parts[1]) && trim($parts[1]) !== '') {
    $ref = (int)trim($parts[1]);
    if ($ref <= 0) $ref = null;
  }
  showWelcome($chatId, $fromId, $ref);
  setStep($fromId, 'none');
  http_response_code(200);
  echo "OK";
  exit;
}

if ($text === '/panel') {
  if (!adminRequire($chatId, $fromId)) {
    http_response_code(200); echo "OK"; exit;
  }
  setStep($fromId, 'none');
  sendMessage($chatId, "پنل مدیریت باز شد:", adminMenu());
  http_response_code(200);
  echo "OK";
  exit;
}

/* ----- Step handlers ----- */
if ($step === 'use_code') {
  redeemCode($chatId, $fromId, trim($text));
  http_response_code(200);
  echo "OK";
  exit;
}

if ($step === 'vip_select') {
  if (preg_match('/^[1-9]$/', trim($text))) {
    $n = (int)trim($text);
    setStep($fromId, 'none');
    $txt =
      "✅ انتخاب شما: <b>$n</b>\n\n"
      . "حالا می‌توانید محصولات مربوط به این دسته را داخل «فروشگاه 🛒» قرار دهید\n"
      . "یا اگر می‌خواهید همینجا لینک/کاتالوگ بدهید، متن را ویرایش کنید.";
    sendMessage($chatId, $txt, mainMenu());
  } else {
    sendMessage($chatId, "فقط عدد 1 تا 9 را ارسال کنید یا «بازگشت».", backMenu());
  }
  http_response_code(200);
  echo "OK";
  exit;
}

if ($step === 'admin_set_title') {
  if (!adminRequire($chatId, $fromId)) { http_response_code(200); echo "OK"; exit; }
  $title = trim($text);
  if ($title === '') {
    sendMessage($chatId, "عنوان نمی‌تواند خالی باشد.", backMenu());
    http_response_code(200); echo "OK"; exit;
  }
  writeFileSafe(userFile($fromId, 'tmp_title.txt'), $title);
  setStep($fromId, 'admin_set_desc');
  sendMessage($chatId, "توضیحات محصول را ارسال کنید:", backMenu());
  http_response_code(200); echo "OK"; exit;
}

if ($step === 'admin_set_desc') {
  if (!adminRequire($chatId, $fromId)) { http_response_code(200); echo "OK"; exit; }
  writeFileSafe(userFile($fromId, 'tmp_desc.txt'), trim($text));
  setStep($fromId, 'admin_set_link');
  sendMessage($chatId, "لینک تحویل/موفق (مثلاً لینک دانلود یا لینک دسترسی قانونی) را ارسال کنید:", backMenu());
  http_response_code(200); echo "OK"; exit;
}

if ($step === 'admin_set_link') {
  if (!adminRequire($chatId, $fromId)) { http_response_code(200); echo "OK"; exit; }
  writeFileSafe(userFile($fromId, 'tmp_link.txt'), trim($text));
  setStep($fromId, 'admin_set_price');
  sendMessage($chatId, "قیمت (به سکه) را فقط عدد ارسال کنید:", backMenu());
  http_response_code(200); echo "OK"; exit;
}

if ($step === 'admin_set_price') {
  if (!adminRequire($chatId, $fromId)) { http_response_code(200); echo "OK"; exit; }
  $price = (int)trim($text);
  if ($price <= 0) {
    sendMessage($chatId, "قیمت باید عدد مثبت باشد.", backMenu());
    http_response_code(200); echo "OK"; exit;
  }

  $title = readFileSafe(userFile($fromId, 'tmp_title.txt'), '');
  $desc  = readFileSafe(userFile($fromId, 'tmp_desc.txt'), '');
  $link  = readFileSafe(userFile($fromId, 'tmp_link.txt'), '');

  $count = getProductCount();
  $newId = $count + 1;

  saveProduct($newId, $title, $desc, $link, $price);
  setProductCount($newId);

  setStep($fromId, 'none');
  sendMessage($chatId, "✅ محصول ثبت شد.\nآیدی محصول: <b>$newId</b>", adminMenu());
  http_response_code(200); echo "OK"; exit;
}

if ($step === 'admin_del_product') {
  if (!adminRequire($chatId, $fromId)) { http_response_code(200); echo "OK"; exit; }
  $id = (int)trim($text);
  if ($id <= 0) {
    sendMessage($chatId, "آیدی نامعتبر است.", backMenu());
    http_response_code(200); echo "OK"; exit;
  }
  $ok = deleteProductById($id);
  setStep($fromId, 'none');
  sendMessage($chatId, $ok ? "✅ محصول حذف شد." : "محصول پیدا نشد.", adminMenu());
  http_response_code(200); echo "OK"; exit;
}

if ($step === 'admin_create_code') {
  if (!adminRequire($chatId, $fromId)) { http_response_code(200); echo "OK"; exit; }
  $parts = preg_split('/\s+/', trim($text));
  if (count($parts) < 2) {
    sendMessage($chatId, "فرمت اشتباه است.\nمثال:\n<code>ABC123 50</code>", backMenu());
    http_response_code(200); echo "OK"; exit;
  }
  $code = $parts[0];
  $val  = (int)$parts[1];
  if ($val <= 0) {
    sendMessage($chatId, "مقدار باید عدد مثبت باشد.", backMenu());
    http_response_code(200); echo "OK"; exit;
  }
  writeFileSafe(dataPath("codes/$code.txt"), (string)$val);
  setStep($fromId, 'none');
  sendMessage($chatId, "✅ کد ساخته شد:\nکد: <code>$code</code>\nمقدار: <b>$val</b> سکه", adminMenu());
  http_response_code(200); echo "OK"; exit;
}

if ($step === 'admin_add_coins' || $step === 'admin_remove_coins') {
  if (!adminRequire($chatId, $fromId)) { http_response_code(200); echo "OK"; exit; }
  $parts = preg_split('/\s+/', trim($text));
  if (count($parts) < 2) {
    sendMessage($chatId, "فرمت اشتباه است.\nمثال:\n<code>123456789 20</code>", backMenu());
    http_response_code(200); echo "OK"; exit;
  }
  $uid = (int)$parts[0];
  $val = (int)$parts[1];
  if ($uid <= 0 || $val <= 0) {
    sendMessage($chatId, "مقادیر نامعتبر هستند.", backMenu());
    http_response_code(200); echo "OK"; exit;
  }
  registerUserIfNeeded($uid);

  if ($step === 'admin_add_coins') {
    addCoins($uid, $val);
    sendMessage($uid, "✅ <b>$val</b> سکه به حساب شما اضافه شد.");
    sendMessage($chatId, "✅ انجام شد.", adminMenu());
  } else {
    addCoins($uid, -$val);
    sendMessage($uid, "⚠️ <b>$val</b> سکه از حساب شما کم شد.");
    sendMessage($chatId, "✅ انجام شد.", adminMenu());
  }
  setStep($fromId, 'none');
  http_response_code(200); echo "OK"; exit;
}

/* ----- Text routing (no step) ----- */
if ($text === 'فروشگاه 🛒') {
  setStep($fromId, 'none');
  showShop($chatId);
  http_response_code(200); echo "OK"; exit;
}

if ($text === 'افزایش موجودی 💳') {
  setStep($fromId, 'none');
  showTopUp($chatId, $fromId);
  http_response_code(200); echo "OK"; exit;
}

if ($text === 'کد هدیه 🛍' || str_contains($text, 'کد هدیه')) {
  setStep($fromId, 'use_code');
  sendMessage($chatId, "کد موردنظر را ارسال کنید:", backMenu());
  http_response_code(200); echo "OK"; exit;
}

if ($text === 'حساب کاربری 🔖') {
  setStep($fromId, 'none');
  showAccount($chatId, $fromId, $name, $username);
  http_response_code(200); echo "OK"; exit;
}

if ($text === '👥پشتیبانی') {
  setStep($fromId, 'none');
  showSupport($chatId);
  http_response_code(200); echo "OK"; exit;
}

if ($text === 'خرید پک VIP 🎬') {
  showVipPacks($chatId);
  http_response_code(200); echo "OK"; exit;
}

/* Admin menu buttons */
if ($text === 'محصول جدید') { adminStartAddProduct($chatId, $fromId); http_response_code(200); echo "OK"; exit; }
if ($text === 'حذف محصول') { adminStartDeleteProduct($chatId, $fromId); http_response_code(200); echo "OK"; exit; }
if ($text === 'ساخت کد هدیه') { adminStartCreateCode($chatId, $fromId); http_response_code(200); echo "OK"; exit; }
if ($text === 'اهدای سکه') { adminStartAddCoins($chatId, $fromId); http_response_code(200); echo "OK"; exit; }
if ($text === 'کم کردن سکه') { adminStartRemoveCoins($chatId, $fromId); http_response_code(200); echo "OK"; exit; }

/* Buy command: /buy{ID} */
if (preg_match('/^\/buy(\d+)$/', trim($text), $m)) {
  $id = (int)$m[1];
  $prod = loadProductById($id);
  if (!$prod) {
    sendMessage($chatId, "محصول در سیستم موجود نیست.", mainMenu());
    http_response_code(200); echo "OK"; exit;
  }
  $coin = getCoins($fromId);
  if ($coin < (int)$prod['price']) {
    sendMessage($chatId, "❌ موجودی شما کافی نیست.\nموجودی: <b>$coin</b>\nقیمت: <b>{$prod['price']}</b>", mainMenu());
    http_response_code(200); echo "OK"; exit;
  }

  setCoins($fromId, $coin - (int)$prod['price']);
  sendMessage($chatId, "✅ خرید با موفقیت انجام شد.\n\nلینک تحویل:\n" . h($prod['link']), mainMenu());
  http_response_code(200); echo "OK"; exit;
}

/* Transfer: /transfer USERID AMOUNT */
if (preg_match('/^\/transfer\s+(\d+)\s+(\d+)$/', trim($text), $m)) {
  $to = (int)$m[1];
  $amount = (int)$m[2];

  if ($amount < 1) {
    sendMessage($chatId, "مقدار انتقال باید حداقل 1 باشد.", mainMenu());
    http_response_code(200); echo "OK"; exit;
  }

  registerUserIfNeeded($to);
  $have = getCoins($fromId);
  if ($have < $amount) {
    sendMessage($chatId, "موجودی شما کافی نیست.\nموجودی: <b>$have</b>", mainMenu());
    http_response_code(200); echo "OK"; exit;
  }

  setCoins($fromId, $have - $amount);
  addCoins($to, $amount);

  sendMessage($chatId, "✅ انتقال انجام شد.\n<b>$amount</b> سکه به <code>$to</code> ارسال شد.", mainMenu());
  sendMessage($to, "✅ <b>$amount</b> سکه از طرف <code>$fromId</code> برای شما واریز شد.");
  http_response_code(200); echo "OK"; exit;
}

/* If user typed a product title */
$id = findProductIdByTitle($text);
if ($id) {
  showProductDetails($chatId, $text);
  http_response_code(200); echo "OK"; exit;
}

/* Default */
sendMessage($chatId, "دستور/متن مورد نظر یافت نشد.", mainMenu());
http_response_code(200);
echo "OK";
exit;
