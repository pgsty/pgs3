ARG PG_MAJOR=17
ARG POSTGRES_IMAGE=postgres:${PG_MAJOR}-bookworm

FROM ${POSTGRES_IMAGE} AS builder
ARG PG_MAJOR
ARG PGRX_VERSION=0.19.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        curl \
        libclang-dev \
        libssl-dev \
        pkg-config \
        postgresql-server-dev-${PG_MAJOR} \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/root/.cargo/bin:${PATH}
ENV PGRX_HOME=/root/.pgrx
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain stable \
    && rustup component add rustfmt \
    && cargo install cargo-pgrx --version "${PGRX_VERSION}" --locked \
    && cargo pgrx init \
        "--pg${PG_MAJOR}" "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" \
        --no-run

WORKDIR /workspace
COPY . .
RUN cargo pgrx package \
        --pg-config "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" \
        --no-default-features \
        --features "pg${PG_MAJOR}" \
        --out-dir /tmp/pgs3-package

FROM ${POSTGRES_IMAGE}
ARG PG_MAJOR
LABEL org.opencontainers.image.title="pgs3 development server"
LABEL org.opencontainers.image.description="PostgreSQL ${PG_MAJOR} with the locally built pgs3 extension"
COPY --from=builder /tmp/pgs3-package/ /
