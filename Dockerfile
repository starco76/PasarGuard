ARG PYTHON_VERSION=3.14
ARG BUN_VERSION=1

FROM ghcr.io/astral-sh/uv:python$PYTHON_VERSION-bookworm-slim AS builder
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    python3-dev \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

ENV UV_PYTHON_DOWNLOADS=0

WORKDIR /build
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project --no-dev
ADD . /build
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev


# Compile the dashboard frontend here so the image is self-contained and never
# needs bun at runtime (dashboard/__init__.py:run_build only shells out to bun
# when dashboard/build/ is missing).
FROM oven/bun:${BUN_VERSION}-slim AS dashboard-builder
WORKDIR /dashboard

# Manifest first, so frontend source edits reuse the install layer.
COPY dashboard/package.json dashboard/bun.lock ./
RUN bun install --frozen-lockfile

COPY dashboard/ ./

# Baked into the bundle at build time (src/service/http.ts reads it). Keep the
# default in step with DashboardSettings.vite_base_api and build_dashboard.sh.
ARG VITE_BASE_API=/
ENV VITE_BASE_API=${VITE_BASE_API}
RUN bun run build \
    && cp build/index.html build/404.html


FROM python:$PYTHON_VERSION-slim-bookworm

COPY --from=builder /build /code
WORKDIR /code

# Frontend sources reach /code via the builder context; the runtime only serves
# the compiled output, so keep dashboard/__init__.py and drop the rest. The
# compiled build/ is copied in below.
RUN find /code/dashboard -mindepth 1 -maxdepth 1 ! -name __init__.py -exec rm -rf {} +

COPY --from=dashboard-builder /dashboard/build /code/dashboard/build

ENV PATH="/code/.venv/bin:$PATH"

# Keep the runtime trust store explicit. Outbound notification clients use it
# without replacing Python's process-wide SSLContext.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY cli_wrapper.sh /usr/bin/pasarguard-cli
RUN chmod +x /usr/bin/pasarguard-cli

COPY tui_wrapper.sh /usr/bin/pasarguard-tui
RUN chmod +x /usr/bin/pasarguard-tui

# Copy healthcheck script
COPY healthcheck.sh /code/healthcheck.sh
RUN chmod +x /code/healthcheck.sh

RUN chmod +x /code/start.sh

ENTRYPOINT ["/code/start.sh"]
