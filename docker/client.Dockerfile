FROM python:3.12.9-slim-bookworm@sha256:48a11b7ba705fd53bf15248d1f94d36c39549903c5d59edcfa2f3f84126e7b44

ARG TARGETARCH
ARG AWSCLI_VERSION=1.37.13
ARG BOTO3_VERSION=1.36.13
ARG DUCKDB_VERSION=1.2.0
ARG RCLONE_VERSION=1.69.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        fuse3 \
        s3fs \
        unzip \
        vim-tiny \
    && ln -s /usr/bin/vim.tiny /usr/local/bin/vim \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/pgs3-clients \
    && /opt/pgs3-clients/bin/pip install --no-cache-dir \
        "awscli==${AWSCLI_VERSION}" \
        "boto3==${BOTO3_VERSION}" \
        "duckdb==${DUCKDB_VERSION}"

RUN case "${TARGETARCH}" in \
        amd64) rclone_arch=amd64; rclone_sha=231841f8d8029ae6cfca932b601b3b50d0e2c3c2cb9da3166293f1c3eae7d79c ;; \
        arm64) rclone_arch=arm64; rclone_sha=a03de8f700fcda7a1aef6b568f88d44218b698fb4e1637596c024d341bb24124 ;; \
        *) echo "unsupported client image architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && archive="rclone-v${RCLONE_VERSION}-linux-${rclone_arch}.zip" \
    && curl --fail --location --proto '=https' --tlsv1.2 \
        --output "/tmp/${archive}" "https://downloads.rclone.org/v${RCLONE_VERSION}/${archive}" \
    && echo "${rclone_sha}  /tmp/${archive}" | sha256sum --check --strict \
    && unzip -q "/tmp/${archive}" -d /tmp/rclone \
    && install -m 0755 "/tmp/rclone/rclone-v${RCLONE_VERSION}-linux-${rclone_arch}/rclone" \
        /usr/local/bin/rclone \
    && rm -rf /tmp/rclone "/tmp/${archive}"

# Bake the version-matched httpfs extension into the image.  Acceptance runs
# remain deterministic and do not need Internet access to load the extension.
RUN /opt/pgs3-clients/bin/python -c \
    "import duckdb; c=duckdb.connect(); c.execute('INSTALL httpfs'); c.close()"

ENV PATH=/opt/pgs3-clients/bin:${PATH} \
    AWS_EC2_METADATA_DISABLED=true \
    AWS_DEFAULT_REGION=us-east-1 \
    AWS_REGION=us-east-1

WORKDIR /work
CMD ["bash"]
