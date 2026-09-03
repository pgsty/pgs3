# pgs3 快速上手

本教程用一个本地 Docker 容器启动 PostgreSQL 17、安装 `pgs3 0.1.1`，
创建租户和 S3 凭据，然后通过 AWS CLI 完成建桶、上传、下载、覆盖与版本读取。
完成全流程通常只需要十几分钟。

> 这是一套本机开发演示配置。它使用 PostgreSQL 容器的 `trust` 认证并将
> 明文 HTTP 端点仅发布到 `127.0.0.1`，不能直接照搬到生产环境。

## 1. 准备环境

需要：

- Docker Engine 或 Docker Desktop；
- Git；
- AWS CLI v2；
- `openssl`，用于生成演示密钥。

当前仓库发布的是扩展源码和构建脚本，不是假定已经存在的公共二进制包。
克隆源码并构建 PostgreSQL 17 测试镜像：

```bash
git clone git@github.com:pgsty/pgs3.git
cd pgs3
make image PG_MAJOR=17
```

生成的镜像名为 `pgs3-test:pg17`。第一次构建需要下载 PostgreSQL、Rust、
`cargo-pgrx 0.19.2` 及编译依赖，耗时取决于网络和机器性能。

## 2. 启动 PostgreSQL

```bash
docker run --detach \
  --name pgs3-demo \
  --publish 127.0.0.1:9000:9000 \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  pgs3-test:pg17 \
  postgres \
  -c shared_preload_libraries=pgs3 \
  -c max_worker_processes=16 \
  -c pgs3.enabled=off \
  -c pgs3.listen_addr=0.0.0.0 \
  -c pgs3.port=9000 \
  -c pgs3.workers=2
```

等待数据库就绪：

```bash
until docker exec pgs3-demo \
  pg_isready --username postgres --dbname postgres >/dev/null 2>&1
do
  sleep 1
done
```

这里使用动态启动模式：库通过 `shared_preload_libraries` 加载，但
`pgs3.enabled=off` 不自动创建监听池；安装扩展后再调用 `pgs3.start()`。

## 3. 安装扩展并创建租户

先在本机生成一对演示凭据：

```bash
export PGS3_ACCESS_KEY=PGS3DEMOACCESS01
export PGS3_SECRET_KEY="$(openssl rand -hex 32)"
```

不要把 secret 写进仓库、命令日志或对象 metadata。将凭据安全地作为环境变量
传入容器，安装扩展并创建一个 `NOLOGIN` 租户角色：

```bash
docker exec --interactive \
  --env PGS3_ACCESS_KEY \
  --env PGS3_SECRET_KEY \
  pgs3-demo \
  bash -Eeuo pipefail -c '
    psql --username postgres --dbname postgres --no-psqlrc \
      --set ON_ERROR_STOP=1 \
      --set access="$PGS3_ACCESS_KEY" \
      --set secret="$PGS3_SECRET_KEY"
  ' <<'SQL'
CREATE EXTENSION pgs3;

CREATE ROLE pgs3_demo
  NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS;

SELECT pgs3.create_credential(
  :'access', :'secret', 'pgs3_demo'::name, true
);

SELECT pgs3.start();
SQL
```

`create_credential` 会把 access key 映射到 PostgreSQL 角色。HTTP worker
认证 SigV4 后，事务通过受限的 `SET ROLE` 权限和 RLS 执行该租户的操作；
pgs3 不维护第二套 IAM/ACL 体系。

等待 HTTP worker 就绪：

```bash
until test "$(docker exec pgs3-demo psql \
  --username postgres --dbname postgres --no-psqlrc \
  --tuples-only --no-align \
  --command "SELECT count(*) FROM pgs3.worker_state
             WHERE worker_kind='http' AND desired AND status='running'")" -ge 2
do
  sleep 1
done

docker exec pgs3-demo psql \
  --username postgres --dbname postgres \
  --command 'TABLE pgs3.stats'
```

## 4. 配置 AWS CLI

pgs3 只接受 path-style URL。使用临时 AWS 配置，不修改现有的默认账号配置：

```bash
export PGS3_ENDPOINT=http://127.0.0.1:9000
export AWS_ACCESS_KEY_ID="$PGS3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$PGS3_SECRET_KEY"
export AWS_DEFAULT_REGION=us-east-1

export AWS_CONFIG_FILE="$(mktemp)"
cat >"$AWS_CONFIG_FILE" <<'EOF'
[default]
region = us-east-1
s3 =
    addressing_style = path
    multipart_threshold = 8MB
    multipart_chunksize = 8MB
EOF
```

所有命令都必须显式指定 `--endpoint-url`，否则 AWS CLI 可能把请求发往 AWS。

## 5. 创建桶并读写对象

创建一个本次演示专用桶：

```bash
export PGS3_BUCKET="pgs3-demo-$(date +%s)"

aws --endpoint-url "$PGS3_ENDPOINT" s3api create-bucket \
  --bucket "$PGS3_BUCKET"
```

上传文件：

```bash
printf 'hello from pgs3\n' >/tmp/pgs3-hello.txt

aws --endpoint-url "$PGS3_ENDPOINT" s3api put-object \
  --bucket "$PGS3_BUCKET" \
  --key tutorial/hello.txt \
  --body /tmp/pgs3-hello.txt \
  --content-type text/plain \
  --metadata stage=getting-started
```

查看 metadata、列出前缀并下载：

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3api head-object \
  --bucket "$PGS3_BUCKET" --key tutorial/hello.txt

aws --endpoint-url "$PGS3_ENDPOINT" s3api list-objects-v2 \
  --bucket "$PGS3_BUCKET" --prefix tutorial/ --max-keys 1000

aws --endpoint-url "$PGS3_ENDPOINT" s3api get-object \
  --bucket "$PGS3_BUCKET" --key tutorial/hello.txt \
  /tmp/pgs3-downloaded.txt

cmp /tmp/pgs3-hello.txt /tmp/pgs3-downloaded.txt
```

也可以使用 AWS CLI 高层命令：

```bash
aws --endpoint-url "$PGS3_ENDPOINT" s3 sync \
  ./docs "s3://$PGS3_BUCKET/docs/" --only-show-errors

aws --endpoint-url "$PGS3_ENDPOINT" s3 ls \
  "s3://$PGS3_BUCKET/docs/" --recursive
```

超过 multipart threshold 的文件会由 AWS CLI 自动走 multipart，无需手工拆分。

## 6. 查看对象版本

pgs3 的桶始终使用版本语义。覆盖同一个 key 会创建新版本，而不是修改旧行：

```bash
printf 'second version\n' >/tmp/pgs3-hello-v2.txt

aws --endpoint-url "$PGS3_ENDPOINT" s3api put-object \
  --bucket "$PGS3_BUCKET" \
  --key tutorial/hello.txt \
  --body /tmp/pgs3-hello-v2.txt

aws --endpoint-url "$PGS3_ENDPOINT" s3api list-object-versions \
  --bucket "$PGS3_BUCKET" --prefix tutorial/hello.txt
```

从输出中取得旧版本的 `VersionId` 后，可以精确读取它：

```bash
export PGS3_VERSION_ID='<替换为 VersionId>'

aws --endpoint-url "$PGS3_ENDPOINT" s3api get-object \
  --bucket "$PGS3_BUCKET" \
  --key tutorial/hello.txt \
  --version-id "$PGS3_VERSION_ID" \
  /tmp/pgs3-old-version.txt
```

普通 `delete-object` 会创建 delete marker，旧版本仍可通过版本 ID 读取；
带 `--version-id` 的删除才是永久删除指定版本。

## 7. 停止和清理

先优雅停止动态 worker 池：

```bash
docker exec pgs3-demo psql \
  --username postgres --dbname postgres \
  --command 'SELECT pgs3.stop()'
```

删除演示容器及 PostgreSQL 镜像声明的匿名数据卷：

```bash
docker rm --force --volumes pgs3-demo
rm -f /tmp/pgs3-hello.txt \
      /tmp/pgs3-hello-v2.txt \
      /tmp/pgs3-downloaded.txt \
      /tmp/pgs3-old-version.txt \
      "$AWS_CONFIG_FILE"
unset PGS3_SECRET_KEY AWS_SECRET_ACCESS_KEY
```

## 常见问题

### `SignatureDoesNotMatch`

确认 region 为 `us-east-1`、系统时钟正常、请求使用 path-style，并且每个 AWS
命令都携带了正确的 `--endpoint-url`。不要在签名后让反向代理改写 path 或 `Host`。

### TCP 端口可连，但 S3 请求失败

检查扩展、worker 和角色状态，而不是只看端口：

```bash
docker exec pgs3-demo psql -U postgres -d postgres -c \
  "SELECT pgs3.extension_version(); TABLE pgs3.worker_state;"
```

### 客户端尝试 virtual-host 地址

pgs3 当前只支持 `http://host:port/bucket/key`。AWS SDK、rclone、s3fs 和
DuckDB 都必须启用 path-style；详细配置见[使用说明](usage.md)。

### 是否可以直接暴露到公网

不可以。pgs3 自身不终止 TLS。生产部署必须使用 nginx 等反向代理提供 HTTPS，
限制 PostgreSQL 和管理 SQL 的访问，并遵循[运维指南](operations.md)。

## 下一步

- 日常客户端和 SQL 操作：[使用说明](usage.md)
- 架构与事务边界：[设计文档](design.md)
- 参数和 SIGHUP 行为：[GUC 参考](guc.md)
- 生产部署与备份：[运维指南](operations.md)
- 已知限制与性能边界：[已知限制](known-limitations.md)
