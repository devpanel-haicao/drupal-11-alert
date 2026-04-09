#!/usr/bin/env bash
if [ -n "${DEBUG_SCRIPT:-}" ]; then
  set -x
fi
set -eu -o pipefail
cd $APP_ROOT

LOG_FILE="logs/init-$(date +%F-%T).log"
exec > >(tee $LOG_FILE) 2>&1

TIMEFORMAT=%lR
# For faster performance, don't audit dependencies automatically.
export COMPOSER_NO_AUDIT=1
# For faster performance, don't install dev dependencies.
export COMPOSER_NO_DEV=1

#== Remove root-owned files.
echo
echo Remove root-owned files.
time sudo rm -rf lost+found

#== Composer install.
echo
if [ -f composer.json ]; then
  if composer show --locked cweagans/composer-patches ^2 &> /dev/null; then
    echo 'Update patches.lock.json.'
    time composer prl
    echo
  fi
else
  echo 'Generate composer.json.'
  time source .devpanel/composer_setup.sh
  echo
fi
# If update fails, change it to install.
time composer -n update --no-dev --no-progress

#== Create the private files directory.
if [ ! -d private ]; then
  echo
  echo 'Create the private files directory.'
  time mkdir private
fi

#== Create the config sync directory.
if [ ! -d config/sync ]; then
  echo
  echo 'Create the config sync directory.'
  time mkdir -p config/sync
fi

#== Install Drupal.
echo
if [ -z "$(drush status --field=db-status)" ]; then
  echo 'Install Drupal.'
  time drush -n si
else
  echo 'Update database.'
  time drush -n updb
fi

# ==============================================================================
# SET UP ALERT BAR (DYNAMIC DATA FETCHING & INJECTION)
# ==============================================================================
echo
echo 'Configuring DevPanel Alert Bar...'

# 1. Fetch Dynamic Data from DrupalForge Proxy
CURRENT_APP_ID="${DP_APP_ID:-}"
if [ -z "$CURRENT_APP_ID" ]; then
    echo "⚠️ Không tìm thấy DP_APP_ID. Dùng dữ liệu mặc định."
    SAFE_APP_NAME="My Application"
    SAFE_SUB_ID="Standard"
else
    # Tự động nhận diện môi trường từ Hostname
    if [ -n "${DP_HOSTNAME:-}" ]; then
        CURRENT_ENV=$(echo "$DP_HOSTNAME" | cut -d'-' -f1)
    else
        CURRENT_ENV="dev"
    fi

    case "$CURRENT_ENV" in
        "local" | "docksal" | "dev") BASE_PROXY_URL="http://drupal-forge.docksal.site" ;;
        # "dev") BASE_PROXY_URL="https://dev.drupalforge.org" ;;
        "stage" | "staging") BASE_PROXY_URL="https://stage.drupalforge.org" ;;
        "prod" | "production" | "www") BASE_PROXY_URL="https://www.drupalforge.org" ;;
        *) BASE_PROXY_URL="https://dev.drupalforge.org" ;;
    esac

    DRUPALFORGE_PROXY="${BASE_PROXY_URL}/api/internal/alert-app-info?app_id=${CURRENT_APP_ID}"
    
    # Dùng '|| true' để ngăn cản set -e làm sập script nếu curl bị lỗi mạng
    SAFE_JSON=$(curl -s -f -X GET "$DRUPALFORGE_PROXY" || true)
    
    if[ -n "$SAFE_JSON" ]; then
        # Dùng '|| echo' để tránh jq lỗi phá vỡ bash script
        SAFE_APP_NAME=$(echo "$SAFE_JSON" | jq -r '.appName // "My Application"' 2>/dev/null || echo "My Application")
        SAFE_SUB_ID=$(echo "$SAFE_JSON" | jq -r '.submissionId // "Standard"' 2>/dev/null || echo "Standard")
    else
        echo "❌ Lỗi kết nối tới DrupalForge Proxy. Dùng dữ liệu mặc định."
        SAFE_APP_NAME="My Application"
        SAFE_SUB_ID="Standard"
    fi
fi

# 2. Tạo file tĩnh chứa Data cho Alert Bar
if [ -d "web" ]; then
  BUY_LINK_URL="${BASE_PROXY_URL}/app/purchase/${CURRENT_APP_ID}"

  jq -n \
    --arg app "$SAFE_APP_NAME" \
    --arg subid "$SAFE_SUB_ID" \
    --arg link "$BUY_LINK_URL" \
    '{appName: $app, subId: $subid, buyLink: $link}' > alert-bar-data.json

  echo "✅ Ghi dữ liệu JSON (alert-bar-data.json) thành công!"
fi

# 3. Tiêm code nhúng alert-bar.php vào index.php
# Chú ý: Đã sửa lỗi syntax khoảng trắng (if [ -f...) của bạn
if [ -f "web/index.php" ]; then
  # Kiểm tra xem file index.php đã có chuỗi alert-bar.php chưa để tránh chèn đè 2 lần 
  # (phòng trường hợp người dùng chạy init.sh nhiều lần)
  if ! grep -q "alert-bar.php" web/index.php; then
    sed -i 's/<?php/<?php\ninclude_once __DIR__ . "\/..\/alert-bar.php";\n/g' web/index.php
    echo "✅ Đã gắn thanh Alert Bar vào index.php thành công!"
  else
    echo "✅ Thanh Alert Bar đã được nhúng từ trước."
  fi
fi
# ==============================================================================

#== Warm up caches.
echo
echo 'Run cron.'
time drush cron
echo
echo 'Populate caches.'
time drush cache:warm &> /dev/null || :
time .devpanel/warm

#== Finish measuring script time.
INIT_DURATION=$SECONDS
INIT_HOURS=$(($INIT_DURATION / 3600))
INIT_MINUTES=$(($INIT_DURATION % 3600 / 60))
INIT_SECONDS=$(($INIT_DURATION % 60))
printf "\nTotal elapsed time: %d:%02d:%02d\n" $INIT_HOURS $INIT_MINUTES $INIT_SECONDS
