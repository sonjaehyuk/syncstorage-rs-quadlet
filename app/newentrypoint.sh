#!/usr/bin/env bash
set -euo pipefail

# --- 기본값 설정 (SyncStorage) ---
: "${SYNC_SYNCSTORAGE_DB_HOST:=mysql}"
: "${SYNC_SYNCSTORAGE_DB_PORT:=3306}"
: "${SYNC_SYNCSTORAGE_DB_NAME:=syncstorage_rs}"
: "${SYNC_SYNCSTORAGE_DB_USER:=sync}"
: "${SYNC_SYNCSTORAGE_DB_PASSWORD:=}"

# --- 기본값 설정 (Tokenserver) ---
: "${SYNC_TOKENSERVER_DB_HOST:=mysql}"
: "${SYNC_TOKENSERVER_DB_PORT:=3306}"
: "${SYNC_TOKENSERVER_DB_NAME:=tokenserver_rs}"
: "${SYNC_TOKENSERVER_DB_USER:=sync}"
: "${SYNC_TOKENSERVER_DB_PASSWORD:=}"

# --- 서비스 동작 기본값 ---
: "${SYNC_URL:=http://localhost:8000}"
: "${SYNC_CAPACITY:=10}"
: "${LOGLEVEL:=warn}"
: "${METRICS_HASH_SECRET:=}"

# 비밀키는 기본값을 강제하지 않음(반드시 지정 권장)
: "${SYNC_MASTER_SECRET:?SYNC_MASTER_SECRET is required (set a strong secret)}"

# URL-safe 인코딩 (비밀번호 등)
urlencode() {
  local raw="${1:-}"
  local length=${#raw}
  local i c
  for (( i=0; i<length; i++ )); do
    c="${raw:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

# MySQL 준비 대기
wait_for_mysql() {
  local host="$1" port="$2" user="$3" pass="$4"
  echo "Waiting for MySQL at ${host}:${port} ..."
  until mysql --protocol=TCP -h "$host" -P "$port" -u "$user" -p"$pass" -e "SELECT 1" >/dev/null 2>&1; do
    sleep 1
  done
}

# DSN 조립 (mysql://user:pass@host:port/db)
build_mysql_url() {
  local user="$1" pass="$2" host="$3" port="$4" db="$5"
  printf 'mysql://%s:%s@%s:%s/%s' \
    "$user" "$(urlencode "$pass")" "$host" "$port" "$db"
}

# DB 대기
wait_for_mysql "$SYNC_SYNCSTORAGE_DB_HOST" "$SYNC_SYNCSTORAGE_DB_PORT" "$SYNC_SYNCSTORAGE_DB_USER" "$SYNC_SYNCSTORAGE_DB_PASSWORD"
wait_for_mysql "$SYNC_TOKENSERVER_DB_HOST" "$SYNC_TOKENSERVER_DB_PORT" "$SYNC_TOKENSERVER_DB_USER" "$SYNC_TOKENSERVER_DB_PASSWORD"

# DSN 생성
SYNCSTORAGE_DATABASE_URL="$(build_mysql_url \
  "$SYNC_SYNCSTORAGE_DB_USER" "$SYNC_SYNCSTORAGE_DB_PASSWORD" \
  "$SYNC_SYNCSTORAGE_DB_HOST" "$SYNC_SYNCSTORAGE_DB_PORT" "$SYNC_SYNCSTORAGE_DB_NAME")"

TOKENSERVER_DATABASE_URL="$(build_mysql_url \
  "$SYNC_TOKENSERVER_DB_USER" "$SYNC_TOKENSERVER_DB_PASSWORD" \
  "$SYNC_TOKENSERVER_DB_HOST" "$SYNC_TOKENSERVER_DB_PORT" "$SYNC_TOKENSERVER_DB_NAME")"

# Diesel 마이그레이션
/usr/local/cargo/bin/diesel --database-url "$SYNCSTORAGE_DATABASE_URL" migration --migration-dir syncstorage-mysql/migrations run
/usr/local/cargo/bin/diesel --database-url "$TOKENSERVER_DATABASE_URL" migration --migration-dir tokenserver-db/migrations run

# Tokenserver DB에 서비스/노드 upsert
mysql "$SYNC_TOKENSERVER_DB_NAME" \
  -h "$SYNC_TOKENSERVER_DB_HOST" -P "$SYNC_TOKENSERVER_DB_PORT" \
  -u "$SYNC_TOKENSERVER_DB_USER" -p"$SYNC_TOKENSERVER_DB_PASSWORD" <<EOF
DELETE FROM services;
INSERT INTO services (id, service, pattern) VALUES
  (1, "sync-1.5", "{node}/1.5/{uid}");
INSERT INTO nodes (id, service, node, capacity, available, current_load, downed, backoff) VALUES
  (1, 1, "${SYNC_URL}", ${SYNC_CAPACITY}, ${SYNC_CAPACITY}, 0, 0, 0)
  ON DUPLICATE KEY UPDATE
    node = VALUES(node),
    capacity = VALUES(capacity),
    available = GREATEST(0, VALUES(capacity) - current_load);
EOF

# 설정 파일 작성
mkdir -p /config
cat > /config/local.toml <<EOF
master_secret = "${SYNC_MASTER_SECRET}"

human_logs = 1
host = "0.0.0.0"
port = 8000

syncstorage.database_url = "${SYNCSTORAGE_DATABASE_URL}"
syncstorage.enable_quota = 0
syncstorage.enabled = true

tokenserver.database_url = "${TOKENSERVER_DATABASE_URL}"
tokenserver.enabled = true
tokenserver.fxa_email_domain = "api.accounts.firefox.com"
tokenserver.fxa_metrics_hash_secret = "${METRICS_HASH_SECRET}"
tokenserver.fxa_oauth_server_url = "https://oauth.accounts.firefox.com"
tokenserver.fxa_browserid_audience = "https://token.services.mozilla.com"
tokenserver.fxa_browserid_issuer = "https://api.accounts.firefox.com"
tokenserver.fxa_browserid_server_url = "https://verifier.accounts.firefox.com/v2"
EOF

# 서버 실행
source /app/venv/bin/activate
RUST_LOG="${LOGLEVEL}" /usr/local/cargo/bin/syncserver --config /config/local.toml
