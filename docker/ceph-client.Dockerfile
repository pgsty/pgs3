FROM python:3.12.9-slim-bookworm@sha256:48a11b7ba705fd53bf15248d1f94d36c39549903c5d59edcfa2f3f84126e7b44

ARG S3TESTS_COMMIT=5522d1c351f75bc00ae0f64f742f3f095f5939d9

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

RUN git init /opt/s3-tests \
    && git -C /opt/s3-tests remote add origin https://github.com/ceph/s3-tests.git \
    && git -C /opt/s3-tests fetch --depth=1 origin "${S3TESTS_COMMIT}" \
    && git -C /opt/s3-tests checkout --detach FETCH_HEAD \
    && test "$(git -C /opt/s3-tests rev-parse HEAD)" = "${S3TESTS_COMMIT}"

COPY tests/ceph/requirements.lock /tmp/pgs3-ceph-requirements.lock

# The complete environment is fixed independently of upstream's open-ended
# requirements.txt. awscrt enables the modern botocore CRC64NVME request path.
RUN python -m venv /opt/pgs3-ceph \
    && /opt/pgs3-ceph/bin/pip install --no-cache-dir \
        --requirement /tmp/pgs3-ceph-requirements.lock \
    && /opt/pgs3-ceph/bin/pip check

ENV PATH=/opt/pgs3-ceph/bin:${PATH} \
    AWS_DEFAULT_REGION=us-east-1 \
    AWS_EC2_METADATA_DISABLED=true \
    AWS_REGION=us-east-1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

LABEL org.opencontainers.image.source="https://github.com/ceph/s3-tests" \
      org.opencontainers.image.revision="${S3TESTS_COMMIT}" \
      org.opencontainers.image.title="pgs3 pinned Ceph s3-tests client"

WORKDIR /opt/s3-tests
CMD ["bash"]
