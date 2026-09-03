# pgs3 使用说明

本文面向已经有可用 pgs3 endpoint 的用户和管理员，介绍日常 S3 客户端、
pgs3 专属 SQL、凭据管理、worker 状态和常见错误。第一次本地运行请先阅读
[快速上手](getting-started.md)。

## 1. 使用模型

pgs3 的关键概念是：

- 一个 endpoint 只服务一个 PostgreSQL database；
- access key 映射到一个 PostgreSQL 租户角色；
- bucket 由 PostgreSQL 角色拥有，RLS 隔离租户数据；
- object key 使用 path-style S3 URL；
- 每次覆盖都会创建版本；普通删除创建 delete marker；
- 相同内容由 `pgs3.blob` 去重，Copy、Restore 和 Fork 共享 canonical blob；
- 普通对象 I/O 使用 S3；Restore 和 Fork 等 pgs3 扩展能力使用 SQL。

推荐为每个租户创建独立的 `NOLOGIN NOINHERIT` 角色和独立凭据。不要让应用
直接连接 PostgreSQL，也不要把 pgs3 的 service role 当作应用角色。

## 2. 客户端环境变量

以下示例统一使用：

```bash
export PGS3_ENDPOINT='https://s3.example.com'
export AWS_ACCESS_KEY_ID='<access-key>'
export AWS_SECRET_ACCESS_KEY='<secret-key>'
export AWS_DEFAULT_REGION='us-east-1'
export PGS3_BUCKET='agent-artifacts'
```

本地明文演示可把 endpoint 改为 `http://127.0.0.1:9000`。生产环境应由反向代理
终止 TLS。不要在日志、CI 参数回显、对象 metadata 或 Git 仓库中保存 secret。

## 3. AWS CLI

### 3.1 Path-style 配置

pgs3 不支持 virtual-host addressing。可使用独立配置文件：

```ini
[default]
region = us-east-1
s3 =
    addressing_style = path
    multipart_threshold = 8MB
    multipart_chunksize = 8MB
    max_concurrent_requests = 4
```

将其保存为受保护的文件，然后设置：

```bash
export AWS_CONFIG_FILE=/path/to/pgs3-aws-config
chmod 600 "$AWS_CONFIG_FILE"
```

以下每个命令都显式指定 endpoint，避免意外访问 AWS：

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api list-buckets
```

### 3.2 Bucket 操作

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api create-bucket \
  --bucket "$PGS3_BUCKET"

aws --endpoint-url "$PGS3_ENDPOINT" s3api head-bucket \
  --bucket "$PGS3_BUCKET"

aws --endpoint-url "$PGS3_ENDPOINT" s3api get-bucket-location \
  --bucket "$PGS3_BUCKET"

aws --endpoint-url "$PGS3_ENDPOINT" s3api get-bucket-versioning \
  --bucket "$PGS3_BUCKET"
```

只有 bucket 中不存在 object version 或 delete marker 时才能删除桶。未完成的
multipart upload 不算可见对象，删除空桶时会被原子中止。

### 3.3 上传、HEAD、下载与 Range

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api put-object \
  --bucket "$PGS3_BUCKET" \
  --key runs/2026-09-02/report.json \
  --body ./report.json \
  --content-type application/json \
  --metadata project=demo,run=2026-09-02

aws --endpoint-url "$PGS3_ENDPOINT" s3api head-object \
  --bucket "$PGS3_BUCKET" \
  --key runs/2026-09-02/report.json

aws --endpoint-url "$PGS3_ENDPOINT" s3api get-object \
  --bucket "$PGS3_BUCKET" \
  --key runs/2026-09-02/report.json \
  ./downloaded-report.json

aws --endpoint-url "$PGS3_ENDPOINT" s3api get-object \
  --bucket "$PGS3_BUCKET" \
  --key runs/2026-09-02/report.json \
  --range bytes=0-1023 \
  ./first-kib.bin
```

PUT 响应中的 ETag 是 S3 兼容标识：单对象为 MD5 形状，multipart ETag 为
`<md5>-N`。它不是授权 token，也不是通用 SHA-256 校验值。

### 3.4 条件写

只在 key 当前不存在可见对象时写入：

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api put-object \
  --bucket "$PGS3_BUCKET" \
  --key locks/once.json \
  --body ./once.json \
  --if-none-match '*'
```

只在当前 ETag 与预期一致时覆盖：

```bash
export CURRENT_ETAG='<不含或包含双引号均可>'

aws --endpoint-url "$PGS3_ENDPOINT" s3api put-object \
  --bucket "$PGS3_BUCKET" \
  --key locks/once.json \
  --body ./replacement.json \
  --if-match "$CURRENT_ETAG"
```

pgs3 在同一 key 的事务锁内判断条件；并发 `If-None-Match: *` 不会产生两个成功
写入。条件失败返回 S3 `PreconditionFailed` / HTTP 412。

### 3.5 Prefix、delimiter 与分页

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api list-objects-v2 \
  --bucket "$PGS3_BUCKET" \
  --prefix runs/ \
  --delimiter / \
  --max-keys 1000
```

当 `IsTruncated=true` 时，把 `NextContinuationToken` 原样传给下一页：

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api list-objects-v2 \
  --bucket "$PGS3_BUCKET" \
  --prefix runs/ \
  --delimiter / \
  --max-keys 1000 \
  --continuation-token "$NEXT_TOKEN"
```

不要解析、修改或自行构造 continuation token。当前 token 与 bucket/prefix/
delimiter 绑定，但尚未带服务端 MAC；见[已知限制](known-limitations.md)。

### 3.6 版本和删除

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api list-object-versions \
  --bucket "$PGS3_BUCKET" --prefix runs/2026-09-02/report.json

aws --endpoint-url "$PGS3_ENDPOINT" s3api get-object \
  --bucket "$PGS3_BUCKET" \
  --key runs/2026-09-02/report.json \
  --version-id "$VERSION_ID" \
  ./historical-report.json
```

普通删除创建 delete marker：

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api delete-object \
  --bucket "$PGS3_BUCKET" --key runs/2026-09-02/report.json
```

永久删除指定版本：

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api delete-object \
  --bucket "$PGS3_BUCKET" \
  --key runs/2026-09-02/report.json \
  --version-id "$VERSION_ID"
```

永久删除不可撤销。blob 只有在 object、pending upload 和 extent 都不再引用后，
才会由 GC 回收。

### 3.7 CopyObject

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api copy-object \
  --bucket "$PGS3_BUCKET" \
  --key copies/report.json \
  --copy-source "$PGS3_BUCKET/runs/2026-09-02/report.json"
```

Copy 创建一个新 object version，但共享 canonical blob，不复制 payload。若复制指定
历史版本，应把 `?versionId=...` 作为 copy source 的一部分并正确 URL encode。

### 3.8 Multipart

通常直接使用高层命令，让 AWS CLI 自动完成 multipart：

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3 cp \
  ./large.bin "s3://$PGS3_BUCKET/large/large.bin" \
  --only-show-errors
```

若需要控制 part、重试或 ListParts，可使用标准的
`create-multipart-upload`、`upload-part`、`list-parts`、
`complete-multipart-upload` 和 `abort-multipart-upload` API。除最后一个 part 外，
每个 part 必须至少 5 MiB；最多 10,000 parts。

## 4. rclone

推荐使用环境变量提供凭据，在 rclone 配置中只保存 endpoint：

```ini
[pgs3]
type = s3
provider = Other
env_auth = true
endpoint = https://s3.example.com
region = us-east-1
force_path_style = true
```

常用命令：

```bash
rclone sync ./artifacts "pgs3:$PGS3_BUCKET/artifacts" \
  --checkers 4 --transfers 4

rclone check --download ./artifacts \
  "pgs3:$PGS3_BUCKET/artifacts" --checkers 4

rclone copy "pgs3:$PGS3_BUCKET/artifacts" ./restored-artifacts
```

## 5. boto3

必须显式设置 SigV4 和 path-style：

```python
import os
import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["PGS3_ENDPOINT"],
    aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
    region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    config=Config(
        signature_version="s3v4",
        s3={"addressing_style": "path"},
        retries={"max_attempts": 3},
        request_checksum_calculation="when_supported",
        response_checksum_validation="when_supported",
    ),
)

s3.put_object(
    Bucket=os.environ["PGS3_BUCKET"],
    Key="python/hello.txt",
    Body=b"hello from boto3\n",
    ContentType="text/plain",
)

body = s3.get_object(
    Bucket=os.environ["PGS3_BUCKET"],
    Key="python/hello.txt",
)["Body"].read()
assert body == b"hello from boto3\n"
```

### 预签名 URL

```python
get_url = s3.generate_presigned_url(
    "get_object",
    Params={"Bucket": os.environ["PGS3_BUCKET"], "Key": "python/hello.txt"},
    ExpiresIn=300,
)

put_url = s3.generate_presigned_url(
    "put_object",
    Params={"Bucket": os.environ["PGS3_BUCKET"], "Key": "python/upload.txt"},
    ExpiresIn=300,
)
```

预签名只替代认证头，不绕过 RLS。method、path、query 或 body 签名被修改后请求必须
失败。生产环境只应生成短有效期 URL，并通过 HTTPS 传输。

## 6. s3fs

Linux 主机需要可用的 `/dev/fuse` 和 `fusermount3`：

```bash
printf '%s:%s\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" \
  >~/.passwd-s3fs
chmod 600 ~/.passwd-s3fs

mkdir -p ~/mnt/pgs3
s3fs "$PGS3_BUCKET" ~/mnt/pgs3 \
  -o passwd_file="$HOME/.passwd-s3fs" \
  -o "url=$PGS3_ENDPOINT" \
  -o use_path_request_style \
  -o retries=2

find ~/mnt/pgs3 -type f | head
grep 'needle' ~/mnt/pgs3/path/to/file

fusermount3 -u ~/mnt/pgs3
```

s3fs 提供的是 S3 文件系统视图，不是 POSIX 事务文件系统。重命名和部分编辑可能映射
成多个 S3 操作；不应把它用于需要原子目录操作或锁语义的工作负载。

## 7. DuckDB httpfs

明文 endpoint 示例：

```sql
INSTALL httpfs;
LOAD httpfs;

CREATE SECRET pgs3_secret (
  TYPE S3,
  KEY_ID '<access-key>',
  SECRET '<secret-key>',
  REGION 'us-east-1',
  ENDPOINT '127.0.0.1:9000',
  URL_STYLE 'path',
  USE_SSL false
);

SELECT count(*)
FROM read_parquet('s3://agent-artifacts/data/events.parquet');
```

生产 HTTPS endpoint 将 `ENDPOINT` 改为代理的 host:port，并设置 `USE_SSL true`。
不要把包含真实 secret 的 DuckDB 脚本提交到仓库。

## 8. pgs3 专属 SQL

普通对象操作优先使用 S3。SQL API 适合 Restore、Fork、运维或数据库内工作流。
以下示例假设当前连接是管理员，事务内切换到租户角色；应用不应使用 superuser。

```sql
BEGIN;
SET LOCAL ROLE pgs3_demo;

SELECT pgs3.create_bucket('sql-artifacts');

SELECT pgs3.put(
  'sql-artifacts',
  'notes/hello.txt',
  convert_to('hello from SQL', 'UTF8'),
  'text/plain',
  '{"source":"sql"}'::jsonb
);

SELECT convert_from(
  (pgs3.get('sql-artifacts', 'notes/hello.txt')).body,
  'UTF8'
);

SELECT *
FROM pgs3.list('sql-artifacts', 'notes/', NULL, NULL, NULL, 1000);

COMMIT;
```

### Restore

Restore 不修改历史版本，而是让指定历史内容成为一个新的 latest version：

```sql
BEGIN;
SET LOCAL ROLE pgs3_demo;

SELECT pgs3.restore(
  'sql-artifacts', 'notes/hello.txt', 42
);

COMMIT;
```

返回值包含新版本 ID，应记录它而不是假定序列连续。

### Fork bucket

Fork 复制源桶所有 latest metadata；源和目标后续写入互相独立，payload 继续共享：

```sql
BEGIN;
SET LOCAL ROLE pgs3_demo;

SELECT pgs3.fork_bucket(
  'sql-artifacts', 'sql-artifacts-experiment'
);

COMMIT;
```

返回值是复制的 latest object/delete-marker 数量。目标桶必须不存在。Fork 是 metadata
操作，但大桶仍会产生 object rows、index 和 WAL；不要把它理解为 O(1) snapshot。

## 9. 管理员操作

### 9.1 创建租户和凭据

```sql
CREATE ROLE tenant_app
  NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS;

SELECT pgs3.create_credential(
  'TENANTAPPACCESS01', '<secret>', 'tenant_app'::name, true
);
```

凭据表必须可逆地保存 SigV4 secret，因此数据库备份也包含敏感信息。限制数据库、
备份、日志和运维 SQL 的访问权限。

### 9.2 轮换、禁用和删除凭据

```sql
SELECT pgs3.rotate_credential('TENANTAPPACCESS01', '<new-secret>');
SELECT pgs3.set_credential_enabled('TENANTAPPACCESS01', false);
SELECT pgs3.set_credential_role('TENANTAPPACCESS01', 'another_tenant'::name);
SELECT pgs3.delete_credential('TENANTAPPACCESS01');
```

推荐轮换顺序是：创建新 access key、验证新客户端、禁用旧 key、观察错误率，最后删除
旧 key。不要复用 `pgs3_server` 作为 credential target。

### 9.3 Worker 生命周期与状态

动态模式：

```sql
SELECT pgs3.start();
TABLE pgs3.worker_state;
TABLE pgs3.stats;
SELECT pgs3.stop();
```

`start()` 和 `stop()` 默认不允许 PUBLIC 执行，应只授予运维角色。生产环境也可使用
preload 自动模式；参数、SIGHUP 和重启边界见 [GUC 参考](guc.md)。

### 9.4 凭据状态与扩展版本

```sql
SELECT pgs3.extension_version();

SELECT access_key, role_name, enabled, created_at
FROM pgs3.credential
ORDER BY access_key;
```

不要查询或输出 `secret` 列到普通运维日志。

## 10. 主库、备库和重试

- 主库 worker 处理读写；
- 热备 worker 可以处理 GET/LIST；
- 热备的写请求返回 `ServiceUnavailable`，并应在读取请求体前拒绝；
- 客户端应把写请求切换到主库 endpoint，而不是无限重试同一备库；
- `SlowDown` 通常表示 statement/lock timeout，应检查数据库锁、I/O 和 worker 状态。

不要盲目重试带条件的 PUT 或 multipart complete。先按 S3 语义判断请求是否幂等，
并在不确定时通过 HEAD、ListParts 或版本列表确认状态。

## 11. 当前边界

当前实现面向项目第一阶段的 path-style、版本化对象存储。以下能力不在范围内或仍有
明确限制：

- pgs3 自身不提供 TLS；
- 不支持 virtual-host bucket URL；
- 不实现 bucket policy、ACL、lifecycle/TTL 和跨 database endpoint；
- continuation token 尚未带服务端 MAC；
- 非 SHA-256 multipart 最终 composite checksum 尚未完整持久化；
- 小对象高 IOPS 性能尚未达到项目基线；
- Fork 是零 payload copy，但不是 O(1) metadata snapshot。

生产采用前请阅读：

- [运维指南](operations.md)
- [API 到 SQL 映射](api-sql-mapping.md)
- [已知限制](known-limitations.md)
- [验收矩阵](acceptance.md)
- [性能报告](perf.md)
