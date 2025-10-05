#!/usr/bin/env bash
set -euo pipefail

: "${SYNC_SYNCSTORAGE_DB_HOST:=mysql}"
: "${SYNC_SYNCSTORAGE_DB_PORT:=3306}"
: "${SYNC_SYNCSTORAGE_DB_NAME:=syncstorage_rs}"
: "${SYNC_SYNCSTORAGE_DB_USER:=sync}"
: "${SYNC_SYNCSTORAGE_DB_PASSWORD:=}"

: "${SYNC_TOKENSERVER_DB_HOST:=mysql}"
: "${SYNC_TOKENSERVER_DB_PORT:=3306}"
: "${SYNC_TOKENSERVER_DB_NAME:=tokenserver_rs}"
: "${SYNC_TOKENSERVER_DB_USER:=sync}"
: "${SYNC_TOKENSERVER_DB_PASSWORD:=}"


: "${SYNC_DB_ADMIN_HOST:=${SYNC_TOKENSERVER_DB_HOST}}"
: "${SYNC_DB_ADMIN_PORT:=${SYNC_TOKENSERVER_DB_PORT}}"
: "${SYNC_DB_ADMIN_USER:=root}"
: "${SYNC_DB_ADMIN_PASSWORD:=}"  # MySQL 측에서 root 비번이 꼭 있어야 함(권장)
: "${SYNC_DB_USER_HOST:=%}"      # 앱 유저 허용 호스트(기본: 전체)

: "${SYNC_URL:=http://localhost:8000}"
: "${SYNC_CAPACITY:=100}"
: "${LOGLEVEL:=warn}"
: "${METRICS_HASH_SECRET:=}"
: "${SYNC_MASTER_SECRET:?SYNC_MASTER_SECRET is required (set a strong secret)}"

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

# MySQL string literal escape: ' => ''  (단일 인용부호 이스케이프)
sql_escape() {
  printf "%s" "${1:-}" | sed "s/'/''/g"
}

wait_for_mysql() {
  local host="$1" port="$2" user="$3" pass="$4"
  echo "Waiting for MySQL at ${host}:${port} as ${user} ..."
  until mysql --protocol=TCP -h "$host" -P "$port" -u "$user" -p"$pass" -e "SELECT 1" >/dev/null 2>&1; do
    sleep 1
  done
}

build_mysql_url() {
  local user="$1" pass="$2" host="$3" port="$4" db="$5"
  printf 'mysql://%s:%s@%s:%s/%s' \
    "$user" "$(urlencode "$pass")" "$host" "$port" "$db"
}

# 0) DB 준비 대기 (관리자)
wait_for_mysql "$SYNC_DB_ADMIN_HOST" "$SYNC_DB_ADMIN_PORT" "$SYNC_DB_ADMIN_USER" "$SYNC_DB_ADMIN_PASSWORD"
# 1) DB / 사용자 생성 및 권한 부여 (idempotent)
create_db_and_user() {
  local db_host="$1" db_port="$2"
  local admin_user="$3" admin_pass="$4"

  local app_db="$5" app_user="$6" app_pass="$7" user_host="$8"

  local esc_db="$(sql_escape "$app_db")"
  local esc_user="$(sql_escape "$app_user")"
  local esc_pass="$(sql_escape "$app_pass")"
  local esc_host="$(sql_escape "$user_host")"

  # MySQL 8 기준: CREATE USER IF NOT EXISTS, ALTER USER ... IDENTIFIED BY
  # 비밀번호가 변경될 수 있으니 ALTER USER로 매번 보정해도 안전.
  mysql --protocol=TCP \
    -h "$db_host" -P "$db_port" \
    -u "$admin_user" -p"$admin_pass" <<SQL
CREATE DATABASE IF NOT EXISTS \`${esc_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${esc_user}'@'${esc_host}';
ALTER USER '${esc_user}'@'${esc_host}' IDENTIFIED BY '${esc_pass}';

GRANT ALL PRIVILEGES ON \`${esc_db}\`.* TO '${esc_user}'@'${esc_host}';
FLUSH PRIVILEGES;
SQL
}

# SyncStorage용 DB/유저
create_db_and_user \
  "$SYNC_DB_ADMIN_HOST" "$SYNC_DB_ADMIN_PORT" \
  "$SYNC_DB_ADMIN_USER" "$SYNC_DB_ADMIN_PASSWORD" \
  "$SYNC_SYNCSTORAGE_DB_NAME" "$SYNC_SYNCSTORAGE_DB_USER" "$SYNC_SYNCSTORAGE_DB_PASSWORD" "$SYNC_DB_USER_HOST"

# Tokenserver용 DB/유저
create_db_and_user \
  "$SYNC_DB_ADMIN_HOST" "$SYNC_DB_ADMIN_PORT" \
  "$SYNC_DB_ADMIN_USER" "$SYNC_DB_ADMIN_PASSWORD" \
  "$SYNC_TOKENSERVER_DB_NAME" "$SYNC_TOKENSERVER_DB_USER" "$SYNC_TOKENSERVER_DB_PASSWORD" "$SYNC_DB_USER_HOST"

# 2) 앱 계정으로도 접속 확인
wait_for_mysql "$SYNC_SYNCSTORAGE_DB_HOST" "$SYNC_SYNCSTORAGE_DB_PORT" "$SYNC_SYNCSTORAGE_DB_USER" "$SYNC_SYNCSTORAGE_DB_PASSWORD"
wait_for_mysql "$SYNC_TOKENSERVER_DB_HOST" "$SYNC_TOKENSERVER_DB_PORT" "$SYNC_TOKENSERVER_DB_USER" "$SYNC_TOKENSERVER_DB_PASSWORD"

# 3) DSN 생성 및 마이그레이션
SYNCSTORAGE_DATABASE_URL="$(build_mysql_url \
  "$SYNC_SYNCSTORAGE_DB_USER" "$SYNC_SYNCSTORAGE_DB_PASSWORD" \
  "$SYNC_SYNCSTORAGE_DB_HOST" "$SYNC_SYNCSTORAGE_DB_PORT" "$SYNC_SYNCSTORAGE_DB_NAME")"

TOKENSERVER_DATABASE_URL="$(build_mysql_url \
  "$SYNC_TOKENSERVER_DB_USER" "$SYNC_TOKENSERVER_DB_PASSWORD" \
  "$SYNC_TOKENSERVER_DB_HOST" "$SYNC_TOKENSERVER_DB_PORT" "$SYNC_TOKENSERVER_DB_NAME")"

/usr/local/cargo/bin/diesel --database-url "$SYNCSTORAGE_DATABASE_URL" migration --migration-dir syncstorage-mysql/migrations run
/usr/local/cargo/bin/diesel --database-url "$TOKENSERVER_DATABASE_URL" migration --migration-dir tokenserver-db/migrations run

# 4) Tokenserver 초기 데이터 upsert
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

source /app/venv/bin/activate
RUST_LOG="${LOGLEVEL}" /usr/local/cargo/bin/syncserver --config /config/local.toml
