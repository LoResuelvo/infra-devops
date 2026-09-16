#!/bin/sh
set -eu

: "${API_SERVER_NAMES:?API_SERVER_NAMES is required}"
: "${WEB_SERVER_NAMES:?WEB_SERVER_NAMES is required}"
: "${ADMIN_SERVER_NAMES:?ADMIN_SERVER_NAMES is required}"
: "${ANDROID_APP_LINK_PACKAGE_NAME:?ANDROID_APP_LINK_PACKAGE_NAME is required}"
: "${ANDROID_APP_LINK_SHA256_CERT_FINGERPRINT:?ANDROID_APP_LINK_SHA256_CERT_FINGERPRINT is required}"

sed \
  -e "s|{{ api_server_names }}|$API_SERVER_NAMES|g" \
  -e "s|{{ web_server_names }}|$WEB_SERVER_NAMES|g" \
  -e "s|{{ admin_server_names }}|$ADMIN_SERVER_NAMES|g" \
  /opt/loresuelvo/gateway/nginx/default.conf.template \
  > /etc/nginx/conf.d/default.conf

sed \
  -e "s|{{ android_app_link_package_name }}|$ANDROID_APP_LINK_PACKAGE_NAME|g" \
  -e "s|{{ android_app_link_sha256_cert_fingerprint }}|$ANDROID_APP_LINK_SHA256_CERT_FINGERPRINT|g" \
  /opt/loresuelvo/gateway/nginx/assetlinks.json.template \
  > /etc/nginx/conf.d/assetlinks.json

exec "$@"
