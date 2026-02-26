#!/usr/bin/env bash
set -euo pipefail

# ========= تنظیمات =========
PROJECT_DIR="shop-bot-public"
BRANCH="main"

# اینو بعداً موقع اجرا ازت می‌پرسه، ولی می‌تونی همینجا هم ست کنی:
REPO_URL_DEFAULT=""

# ========= ابزارهای لازم =========
command -v git >/dev/null 2>&1 || { echo "git نصب نیست"; exit 1; }

read -rp "Repo URL (مثال: https://github.com/USERNAME/REPO.git) : " REPO_URL
REPO_URL="${REPO_URL:-$REPO_URL_DEFAULT}"
if [[ -z "${REPO_URL}" ]]; then
  echo "Repo URL خالیه."
  exit 1
fi

# ========= ساخت پوشه پروژه =========
rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/data/products" "$PROJECT_DIR/data/codes" "$PROJECT_DIR/data/users"

# ========= .gitkeep برای نگه داشتن پوشه data در گیت =========
cat > "$PROJECT_DIR/data/.gitkeep" <<'EOF'
# keep data directory in git
EOF

# ========= .gitignore (خیلی مهم برای پابلیک) =========
cat > "$PROJECT_DIR/.gitignore" <<'EOF'
.env
data/users/
data/products/*.txt
data/codes/*.txt
Member.txt
error_log
EOF

# ========= .env.example =========
cat > "$PROJECT_DIR/.env.example" <<'EOF'
BOT_TOKEN=PUT_YOUR_NEW_BOT_TOKEN
ADMIN_ID=123456789
BOT_NAME=Shop Bot

PAY_100_URL=https://example.com/pay/100
PAY_200_URL=https://example.com/pay/200
PAY_300_URL=https://example.com/pay/300
PAY_400_URL=https://example.com/pay/400
PAY_640_URL=https://example.com/pay/640
PAY_960_URL=https://example.com/pay/960

REPORT_CHANNEL_URL=https://t.me/yourChannelOrInvite
WEBHOOK_SECRET=CHANGE_ME_TO_RANDOM_STRING
EOF

# ========= README =========
cat > "$PROJECT_DIR/README.md" <<'EOF'
# Telegram Shop Bot (Public Safe)

## نصب
1) فایل `.env` بساز (از روی `.env.example`) و مقدارهای BOT_TOKEN و ADMIN_ID را پر کن.
2) وب‌هوک را ست کن:
```bash
curl "https://api.telegram.org/bot<BOT_TOKEN>/setWebhook?url=https://YOUR_DOMAIN/index.php&secret_token=<WEBHOOK_SECRET>"
