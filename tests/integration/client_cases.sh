#!/usr/bin/env bash
set -Eeuo pipefail

case_name=${1:?usage: client_cases.sh CASE}
endpoint=${PGS3_ENDPOINT:?PGS3_ENDPOINT is required}
bucket=${PGS3_TEST_BUCKET:?PGS3_TEST_BUCKET is required}

run() {
    local quoted='' value part
    for value in "$@"; do
        printf -v part '%q' "${value}"
        quoted+="${quoted:+ }${part}"
    done
    printf '+ %s\n' "${quoted}" >&2
    "$@"
}

write_aws_config() {
    umask 077
    printf '%s\n' \
        '[default]' \
        'region = us-east-1' \
        's3 =' \
        '    addressing_style = path' \
        '    multipart_threshold = 8MB' \
        '    multipart_chunksize = 8MB' \
        '    max_concurrent_requests = 4' > /work/aws-config
    export AWS_CONFIG_FILE=/work/aws-config
}

aws_cmd() {
    aws --endpoint-url "${endpoint}" "$@"
}

rclone_cmd() {
    rclone "$@"
}

case ${case_name} in
    versions)
        run aws --version
        run rclone version
        run python -c 'import boto3,botocore,duckdb; print("boto3="+boto3.__version__); print("botocore="+botocore.__version__); print("duckdb="+duckdb.__version__)'
        run s3fs --version
        run vim --version
        ;;

    aws-s3api)
        write_aws_config
        printf 'aws s3api acceptance\n' > /work/s3api-input.txt
        run aws_cmd s3api create-bucket --bucket "${bucket}"
        run aws_cmd s3api put-object --bucket "${bucket}" --key nested/s3api.txt \
            --body /work/s3api-input.txt --content-type text/plain
        run aws_cmd s3api head-object --bucket "${bucket}" --key nested/s3api.txt
        run aws_cmd s3api get-object --bucket "${bucket}" --key nested/s3api.txt \
            /work/s3api-output.txt
        run cmp /work/s3api-input.txt /work/s3api-output.txt
        run aws_cmd s3api list-objects-v2 --bucket "${bucket}" --prefix nested/ \
            --max-keys 1000
        run aws_cmd s3api get-bucket-location --bucket "${bucket}"
        run aws_cmd s3api get-bucket-versioning --bucket "${bucket}"
        printf '{"Objects":[{"Key":"nested/s3api.txt"}],"Quiet":false}\n' \
            > /work/delete-objects.json
        run aws_cmd s3api delete-objects --bucket "${bucket}" \
            --delete file:///work/delete-objects.json
        ;;

    aws-s3)
        write_aws_config
        mkdir -p /work/aws-source/sub /work/aws-download
        printf 'alpha\n' > /work/aws-source/alpha.txt
        printf 'beta\n' > /work/aws-source/sub/beta.txt
        run aws_cmd s3 mb "s3://${bucket}"
        run aws_cmd s3 cp /work/aws-source/alpha.txt "s3://${bucket}/single.txt"
        run aws_cmd s3 sync /work/aws-source "s3://${bucket}/sync/" --only-show-errors
        run aws_cmd s3 ls "s3://${bucket}/sync/" --recursive
        run aws_cmd s3 cp "s3://${bucket}/sync/" /work/aws-download/ \
            --recursive --only-show-errors
        run diff -ru /work/aws-source /work/aws-download
        run aws_cmd s3 rm "s3://${bucket}/single.txt"
        ;;

    aws-multipart)
        write_aws_config
        run aws_cmd s3 mb "s3://${bucket}"
        run python -c 'from pathlib import Path; block=bytes(range(256))*4096; f=Path("/work/100MiB.bin").open("wb"); [f.write(block) for _ in range(100)]; f.close()'
        run sha256sum /work/100MiB.bin
        run aws_cmd s3 cp /work/100MiB.bin "s3://${bucket}/large/100MiB.bin" \
            --only-show-errors
        run aws_cmd s3api head-object --bucket "${bucket}" --key large/100MiB.bin \
            --output json > /work/multipart-head.json
        run python -c 'import hashlib,json; p="/work/100MiB.bin"; n=8*1024*1024; hs=[]; f=open(p,"rb");
while True:
 b=f.read(n)
 if not b: break
 hs.append(hashlib.md5(b,usedforsecurity=False).digest())
expected=hashlib.md5(b"".join(hs),usedforsecurity=False).hexdigest()+"-"+str(len(hs)); actual=json.load(open("/work/multipart-head.json"))["ETag"].strip("\\\""); print("part_count="+str(len(hs))); print("expected_etag="+expected); print("actual_etag="+actual); assert len(hs)==13 and actual==expected'
        mkdir -p /work/multipart-download /work/multipart-source
        run aws_cmd s3 cp "s3://${bucket}/large/100MiB.bin" \
            /work/multipart-download/100MiB.bin --only-show-errors
        run sha256sum /work/multipart-download/100MiB.bin
        run cmp /work/100MiB.bin /work/multipart-download/100MiB.bin
        run cp /work/100MiB.bin /work/multipart-source/100MiB.bin
        run rclone_cmd check --download /work/multipart-source \
            "pgs3:${bucket}/large" --one-way
        ;;

    rclone)
        write_aws_config
        run aws_cmd s3api create-bucket --bucket "${bucket}"
        mkdir -p /work/rclone-source/a /work/rclone-copy
        printf 'rclone one\n' > /work/rclone-source/one.txt
        printf 'rclone two\n' > /work/rclone-source/a/two.txt
        run rclone_cmd sync /work/rclone-source "pgs3:${bucket}/sync" --checkers 4 \
            --transfers 4
        run rclone_cmd check --download /work/rclone-source "pgs3:${bucket}/sync" \
            --checkers 4
        run rclone_cmd copy "pgs3:${bucket}/sync" /work/rclone-copy
        run diff -ru /work/rclone-source /work/rclone-copy
        ;;

    boto3)
        run python /repo/tests/integration/client_boto3.py
        ;;

    duckdb)
        run python /repo/tests/integration/client_duckdb.py
        ;;

    s3fs)
        write_aws_config
        run aws_cmd s3api create-bucket --bucket "${bucket}"
        if [[ ${PGS3_CREATE_FUSE_DEVICE:-0} == 1 && ! -e /dev/fuse ]]; then
            run mknod -m 666 /dev/fuse c 10 229
        fi
        mkdir -p /mnt/pgs3
        umask 077
        printf '%s:%s\n' "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" \
            > /tmp/passwd-s3fs
        chmod 600 /tmp/passwd-s3fs
        mounted=0
        cleanup_mount() {
            if ((mounted)); then
                fusermount3 -u /mnt/pgs3 || true
            fi
            rm -f -- /tmp/passwd-s3fs
        }
        trap cleanup_mount EXIT INT TERM
        run s3fs "${bucket}" /mnt/pgs3 -o passwd_file=/tmp/passwd-s3fs \
            -o "url=${endpoint}" -o use_path_request_style -o retries=1
        mounted=1
        printf 'alpha from s3fs\n' > /mnt/pgs3/editor.txt
        run vim -Nu NONE -n -es /mnt/pgs3/editor.txt \
            -c 'set noswapfile' -c '%s/alpha/beta/' -c 'write' -c 'quit'
        run grep -q 'beta from s3fs' /mnt/pgs3/editor.txt
        run bash -Eeuo pipefail -c \
            'find /mnt/pgs3 -type f -name editor.txt -print -quit | grep -qx /mnt/pgs3/editor.txt'
        run sync
        run fusermount3 -u /mnt/pgs3
        mounted=0
        ;;

    *)
        printf 'unknown client case: %s\n' "${case_name}" >&2
        exit 2
        ;;
esac
