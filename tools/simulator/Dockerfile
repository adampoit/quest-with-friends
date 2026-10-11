FROM rust:1.92-bookworm@sha256:e90e846de4124376164ddfbaab4b0774c7bdeef5e738866295e5a90a34a307a2 AS source

RUN apt-get update && apt-get install -y --no-install-recommends \
    clang mold git pkg-config cmake \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Keep this source revision and the runtime image below on the same upstream release.
RUN git init . \
    && git remote add origin https://github.com/Osso/wow-ui-sim.git \
    && git fetch --depth=1 origin e7cece054a8182da139a62675a1773f48b1fde7e \
    && git checkout --detach FETCH_HEAD \
    && rm -rf .git

RUN cargo fetch --locked

# The upstream native CPU flags can emit AMD-only SSE4a instructions on CI.
ENV RUSTFLAGS="-C target-cpu=x86-64 -C link-arg=-fuse-ld=mold -C link-arg=-Wl,--thread-count=4"

FROM source AS test-builder
RUN cargo build --release --bin wow-sim --no-default-features --features client-retail --locked \
    && strip /build/target/release/wow-sim

# Preserve the published Blizzard UI, fonts, entrypoint, and runtime libraries.
FROM ghcr.io/osso/wow-ui-sim:0.1.32@sha256:0de69a21954b1bca591877054177ab9f0a99f7e521b40f29e1a1b569fe167c8b AS runtime-assets

FROM runtime-assets AS test
COPY --from=test-builder /build/target/release/wow-sim /app/wow-sim
LABEL local.wow-ui-sim.target-cpu="x86-64"

FROM source AS preview-builder
RUN apt-get update && apt-get install -y --no-install-recommends libudev-dev \
    && rm -rf /var/lib/apt/lists/*
ENV CARGO_BUILD_JOBS=2
RUN cargo build --release --bin wow-sim --no-default-features --features gui,client-retail --locked \
    && strip /build/target/release/wow-sim

# Reuse the compiled dependencies when adjusting the preview-only renderer.
FROM preview-builder AS preview-color-builder
COPY preview-color.patch preview-text-alignment.patch /build/
RUN git apply /build/preview-color.patch /build/preview-text-alignment.patch \
    && cargo test --release --lib preview_text_top_inset --no-default-features --features gui,client-retail --locked \
    && cargo build --release --bin wow-sim --no-default-features --features gui,client-retail --locked \
    && strip /build/target/release/wow-sim

FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS preview
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates fonts-dejavu-core libvulkan1 mesa-vulkan-drivers libudev1 \
    libxkbcommon0 libx11-6 libx11-xcb1 libxcb1 libwayland-client0 libwayland-cursor0 libwayland-egl1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=preview-color-builder /build/target/release/wow-sim /app/wow-sim
COPY --from=source /build/data/ /app/data/
COPY --from=runtime-assets /app/Interface/ /app/Interface/
COPY --from=runtime-assets /root/.cache/wow-ui-sim/blizzard-ui/ /opt/wow-ui-sim/blizzard-ui/
COPY --chmod=755 preview_entrypoint.sh /app/preview-entrypoint.sh
ENV WOW_SIM_NO_SAVED_VARS=1 \
    WOW_SIM_SOFTWARE_RENDER=1 \
    VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json \
    XDG_CACHE_HOME=/tmp/wow-ui-sim-cache \
    XDG_RUNTIME_DIR=/tmp/wow-ui-sim-runtime \
    HOME=/tmp
LABEL local.wow-ui-sim.target-cpu="x86-64" \
    local.wow-ui-sim.preview-color="srgb-runtime-visibility-boost" \
    local.wow-ui-sim.preview-text="top-fontstring-inset-2"
ENTRYPOINT ["/app/preview-entrypoint.sh"]
CMD ["--help"]
