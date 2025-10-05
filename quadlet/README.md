# Quadlet

## 시작하기

> 이 문서에서는 mysql이 호스트의 `$HOME/mysql/mysql`에, ca 파일은 `$HOME/`, 기타 설정 파일은 `$HOME/mysql`에 저장된다고 간주합니다.

1. `mysql.container`, `mysqlnet.network`, `syncstorage-rs.container`를 적절한 위치로 옮기세요.
2. syncstorage-rs가 mysql에 정상적으로 접근하기 위해서는 SSL 설정을 해야 합니다.

사설 CA를 설정합니다(`$HOME`).

```shell
openssl genrsa -out ca.key 4096
openssl req -x509 -new -key ca.key -days 3650 -sha256 -subj "/CN=TheCA" -out ca.pem
```

서버 키를 생성합니다. DNS.1은 애플리케이션에서 mysql로 접속할 때 쓸 도메인이어야 합니다(`$HOME/mysql`).

```shell
openssl genrsa -out server.key 4096
cat > server.cnf <<'EOF'
[ req ]
distinguished_name = dn
req_extensions = req_ext
prompt = no
[ dn ]
CN = mysql
[ req_ext ]
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = mysql
EOF
openssl req -new -key server.key -out server.csr -config server.cnf
```

앞서 만든 사설 CA로 인증된 사설 인증서를 만듭니다(`$HOME/mysql`).

```shell
cat > ca.ext <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = mysql
EOF
openssl x509 -req -in server.csr -CA ~/ca.pem -CAkey ~/ca.key -CAcreateserial -out server.crt -days 825 -sha256 -extfile ca.ext
```

3. podman 비밀값을 생성해야 합니다.
    1. `podman secret create mysql-root-password -`, `sync-password`도 동일하게 생성합니다.
    2. `cat /dev/urandom | base32 | head -c64 | podman secret create sync-master-secret -`, `sync-metrics-hash-secret`도 동일하게 생성합니다.

## 환경변수

podman/quadlet에 맞게 조정하면서 entrypoint에서 사용하는 환경변수에도 변화가 생겼습니다.

* 이제 DB URL을 직접 받지 않습니다. HOST, PORT, NAME, PASSWORD 나누어서 받습니다.
* 더이상 DB가 직접 syncstorage-rs 준비를 하지 않습니다. 사용자 및 데이터베이스 생성은 이제 syncstorage-rs가 스스로 합니다.
* `SYNCSTORAGE_DB_HOST`: SyncStorage DB 호스트 주소. 기본값 _mysql_
* `SYNCSTORAGE_DB_PORT`: SyncStorage DB 포트. 기본값 _3306_
* `SYNCSTORAGE_DB_NAME`: SyncStorage DB명. 기본값 _syncstorage_rs_
* `SYNCSTORAGE_DB_USER`: SyncStorage DB 사용자. 기본값 _sync_
* `SYNCSTORAGE_DB_PASSWORD`: SyncStorage DB 비밀번호. 기본값은 빈 문자열입니다. 이론상 비워둘 수 있으나, 설정하는 것은 **강력하게** 권장합니다.
* `SYNC_TOKENSERVER_DB_HOST`: Tokenserver DB 호스트 주소. 기본값 _mysql_
* `SYNC_TOKENSERVER_DB_PORT`: Tokenserver DB 포트. 기본값 _3306_
* `SYNC_TOKENSERVER_DB_NAME`: Tokenserver DB명. 기본값 _tokenserver_rs_
* `SYNC_TOKENSERVER_DB_USER`: Tokenserver DB 사용자. 기본값 _sync_
* `SYNC_TOKENSERVER_DB_PASSWORD`: SyncStorage DB 비밀번호. 이론상 비워둘 수 있으나, 설정하는 것은 **강력하게** 권장합니다.
* `SYNC_URL`: 토큰서버 nodes 테이블에 등록될 동기화 노드 URL. 기본값 http://localhost:8000
* `SYNC_CAPACITY`: 기본값 100.
* `SYNC_MASTER_SECRET`: 서비스 마스터 시크릿. 필수입니다.
* `METRICS_HASH_SECRET`: 메트릭 해시 시크릿. 필수입니다.
* `LOGLEVEL`: Rust용 로그 레벨. 기본값 warn.