#!/usr/bin/env bash
# ==============================================================================
# نشر موقع «ألعاب حكيم» على سيرفر Novixa تحت https://hakeem-games.novixa.dev
#
#   ./deploy/deploy.sh
#
# - يرفع ملفات الموقع إلى مجلد إصدار جديد: hakim-games/releases/<وقت>-<commit>
# - يثبّت deploy/hakim-games.conf ويختبر nginx؛ إذا فشل الاختبار يُرجع الملف القديم ويتوقف
# - يحوّل الرابط current إلى الإصدار الجديد ثم يعيد تحميل nginx (بدون إيقاف أي موقع آخر)
# - يحتفظ بآخر 5 إصدارات للرجوع السريع
# ==============================================================================
set -euo pipefail

HOST="${HOST:-root@161.97.75.64}"
BASE=/opt/mailcow-dockerized/data/conf/nginx
NAME=hakim-games
NGINX=mailcowdockerized-nginx-mailcow-1
SITE_FILES=(index.html favicon.png og.jpg robots.txt sitemap.xml icons fonts)

cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "⚠️  توجد تعديلات غير محفوظة (commit) — سيتم نشر الملفات كما هي على جهازك." >&2
fi
REL="$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)"

echo "▸ رفع الإصدار $REL"
ssh "$HOST" "mkdir -p '$BASE/$NAME/releases/$REL'"
tar -czf - "${SITE_FILES[@]}" | ssh "$HOST" "tar -xzf - --no-same-owner -C '$BASE/$NAME/releases/$REL' && chmod -R a+rX '$BASE/$NAME/releases/$REL'"
scp -q deploy/hakim-games.conf "$HOST:/tmp/$NAME.conf.new"

echo "▸ تثبيت إعدادات nginx واختبارها"
ssh "$HOST" bash -s -- "$BASE" "$NAME" "$NGINX" "$REL" <<'REMOTE'
set -euo pipefail
BASE=$1 NAME=$2 NGINX=$3 REL=$4
cd "$BASE"

# أول نشر: نسخة خاصة بالموقع من شهادة Cloudflare Origin (*.novixa.dev)
if [ ! -f "$NAME/origin.pem" ]; then
  cp -p hadramout-center/origin.pem hadramout-center/origin.key "$NAME/"
fi
# أول نشر: اجعل current موجوداً قبل اختبار nginx
[ -e "$NAME/current" ] || ln -s "releases/$REL" "$NAME/current"

[ -f "$NAME.conf" ] && cp -p "$NAME.conf" "/tmp/$NAME.conf.bak"
install -m 644 "/tmp/$NAME.conf.new" "$NAME.conf"
if ! docker exec "$NGINX" nginx -t 2>&1; then
  echo "✗ فشل اختبار nginx — إرجاع الإعدادات السابقة" >&2
  if [ -f "/tmp/$NAME.conf.bak" ]; then cp -p "/tmp/$NAME.conf.bak" "$NAME.conf"; else rm -f "$NAME.conf"; fi
  exit 1
fi

# تبديل الإصدار بشكل ذرّي، ثم إعادة تحميل nginx
ln -sfn "releases/$REL" "$NAME/current.tmp" && mv -T "$NAME/current.tmp" "$NAME/current"
docker exec "$NGINX" nginx -s reload

# الاحتفاظ بآخر 5 إصدارات
ls -1d "$NAME"/releases/*/ | sort | head -n -5 | xargs -r rm -rf
rm -f "/tmp/$NAME.conf.new"
echo "current -> $(readlink "$NAME/current")"
REMOTE

echo "✓ تم النشر: https://hakeem-games.novixa.dev/"
