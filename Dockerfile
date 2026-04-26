# audiobookshelf-alpine — minimal Docker image of Audiobookshelf on Alpine
#
# Pattern mirrors chefcai/seerr-alpine and chefcai/jellyfin-alpine:
#   - Build happens in GitHub Actions, not on squirttle's eMMC.
#   - Final image is alpine:3.21 + apk nodejs-current + apk ffmpeg + the
#     runtime artifacts needed by `node index.js`.
#
# Baseline (upstream): ghcr.io/advplyr/audiobookshelf:latest = 320 MB
# Target: ≥40 % reduction. Biggest single lever is swapping node:20-alpine
# (~127 MB) for alpine:3.21 + apk nodejs-current (~50 MB).

ARG ABS_REF=v2.33.2
ARG ABS_REPO=https://github.com/advplyr/audiobookshelf.git
ARG NUSQLITE3_DIR="/usr/local/lib/nusqlite3"
ARG NUSQLITE3_PATH="${NUSQLITE3_DIR}/libnusqlite3.so"
ARG NUSQLITE3_VERSION=v1.2

# ---- Stage 1: build client SPA --------------------------------------------
# Nuxt 2 generate produces a static client/dist tree. node:20-alpine matches
# what upstream uses; staying on it keeps lockfile-locked native bins happy.
FROM node:20-alpine AS build-client
ARG ABS_REF
ARG ABS_REPO

WORKDIR /src

# git only — Nuxt build doesn't need C toolchain.
RUN apk add --no-cache git

RUN git clone --depth 1 --branch "${ABS_REF}" "${ABS_REPO}" /src

WORKDIR /src/client
RUN npm ci && npm cache clean --force \
 && npm run generate

# ---- Stage 2: build server + fetch nusqlite3 ------------------------------
FROM node:20-alpine AS build-server
ARG ABS_REF
ARG ABS_REPO
ARG NUSQLITE3_DIR
ARG NUSQLITE3_VERSION

ENV NODE_ENV=production

# Toolchain for sqlite3 native rebuild + curl/unzip for nusqlite3 fetch.
RUN apk add --no-cache \
        curl \
        git \
        make \
        python3 \
        g++ \
        unzip

WORKDIR /server

RUN git clone --depth 1 --branch "${ABS_REF}" "${ABS_REPO}" /src \
 && cp -r /src/index.js /src/prod.js /src/package.json /src/package-lock.json /server/ \
 && cp -r /src/server /server/server \
 && rm -rf /src

# nusqlite3 is a C library bundled at runtime for SQLite Unicode collation.
# Upstream downloads it from a GitHub release per arch; this build is amd64-only
# (matches squirttle), so we fetch the linux-musl-x64 build unconditionally.
RUN curl -fL -o /tmp/nusqlite3.zip \
        "https://github.com/mikiher/nunicode-sqlite/releases/download/${NUSQLITE3_VERSION}/libnusqlite3-linux-musl-x64.zip" \
 && unzip -q /tmp/nusqlite3.zip -d "${NUSQLITE3_DIR}" \
 && rm /tmp/nusqlite3.zip

# Wipe + reinstall with --omit=dev --ignore-scripts so node_modules has no
# build-script residue, then rebuild sqlite3 explicitly so its prebuilt .node
# binary lands in lib/binding/. (Same pattern as seerr-alpine's prod-reinstall.)
# `--ignore-scripts` is needed to avoid running upstream lifecycle hooks that
# may reference devDeps.
RUN npm ci --omit=dev --ignore-scripts \
 && npm rebuild sqlite3

# Drop arch-specific sqlite3 prebuilds. sqlite3@5.x ships prebuilt .node
# binaries for darwin/win/linux-glibc/etc. that the runtime never loads on
# musl/x64. Saves ~5-10 MB.
RUN set -e; \
    cd node_modules/sqlite3/lib/binding 2>/dev/null && \
    ls 1>/dev/null 2>&1 && { \
      find . -maxdepth 1 -mindepth 1 -type d \
        ! -name 'napi-v6-linux-musl-x64' \
        ! -name 'napi-v6-linux-musl-arm64' \
        -prune -exec rm -rf {} +; \
    } || true

# Strip dev-only artifacts from prod node_modules:
#   - *.d.ts / *.d.ts.map: TypeScript declarations, never read by Node.
#   - *.map: source maps, only useful with a debugger attached.
#   - *.md / docs / examples / test / __tests__: documentation + tests.
#   - CHANGELOG / .eslintrc / .prettierrc / tsconfig.json: build-time config.
RUN set -e; \
    cd node_modules; \
    find . \( -name '*.md' -o -name '*.markdown' -o -name '*.map' -o -name '*.d.ts' -o -name '*.d.ts.map' \) -type f -delete; \
    find . -type d \( -name 'docs' -o -name 'doc' -o -name 'examples' -o -name 'example' -o -name '__tests__' -o -name 'test' -o -name 'tests' \) -prune -exec rm -rf {} +; \
    find . -type f \( -name 'CHANGELOG*' -o -name 'HISTORY*' -o -name 'AUTHORS' -o -name 'CONTRIBUTORS' -o -name '.travis.yml' -o -name '.eslintrc*' -o -name '.prettierrc*' -o -name 'tsconfig.json' \) -delete; \
    true

# ---- Stage 3: runtime -----------------------------------------------------
# alpine:3.21 + nodejs-current (= node 22.x in 3.21) is ~50 MB lighter than
# node:20-alpine. ffmpeg + tini + tzdata from apk; identical functional set
# to upstream, just on a smaller base.
FROM alpine:3.21
ARG NUSQLITE3_DIR
ARG NUSQLITE3_PATH

# Runtime UID/GID = 13001 / 13000 — homelab convention (PUID/PGID) used by
# sonarr/radarr/jellyfin/seerr-alpine. All bind-mounted dirs on squirttle
# are owned by this UID/GID; mismatch causes EACCES at first start.
RUN apk add --no-cache \
        nodejs-current \
        ffmpeg \
        tini \
        tzdata \
 && addgroup -g 13000 abs \
 && adduser -D -u 13001 -G abs abs

# Iter 2: drop ffmpeg's transitive video-codec libraries that an audio-only
# server never invokes. Sizes from `du` on iter 1's image (alpine 3.21 ffmpeg):
#   libx265 18.8M, libaom 7.4M, libSvtAv1Enc 6.5M, libvpx 3.2M, libx264 2.2M,
#   librav1e 2.2M, libdav1d 1.6M, libtheora* 0.6M, libpostproc 84K
# plus HW-accel stubs (libdrm*, libva*, libvulkan ~1.4M total) which are useless
# without a passthrough device anyway.
#
# ffmpeg's libav* core libs (avcodec, avformat, avutil, avfilter, swresample,
# swscale) load codec providers via dlopen; if a removed lib is referenced by
# a code path the runtime never enters (any video-encode operation), the
# request fails with "library not found" instead of crashing the binary.
# Audiobookshelf only ever transcodes audio, so this is safe.
#
# Kept on purpose:
#   libwebp       — cover-art format support (small ABS libraries embed webp art)
#   libavfilter   — required for any ffmpeg filter graph (incl. audio resampling)
RUN cd /usr/lib && \
    rm -f \
        libx264.so* libx265.so* \
        libvpx.so* \
        libtheora.so* libtheoraenc.so* libtheoradec.so* \
        libaom.so* librav1e.so* libSvtAv1Enc.so* libdav1d.so* \
        libpostproc.so* \
        libvulkan.so* \
        libdrm.so* libdrm_*.so* \
        libva.so* libva-drm.so* libva-x11.so* libva-wayland.so*

WORKDIR /app

COPY --from=build-client --chown=abs:abs /src/client/dist /app/client/dist
COPY --from=build-server --chown=abs:abs /server          /app
COPY --from=build-server --chown=abs:abs ${NUSQLITE3_PATH} ${NUSQLITE3_PATH}

RUN mkdir -p /config /metadata /audiobooks /podcasts \
 && chown -R abs:abs /config /metadata /app

USER abs

EXPOSE 80

ENV PORT=80
ENV NODE_ENV=production
ENV CONFIG_PATH=/config
ENV METADATA_PATH=/metadata
ENV SOURCE=docker
ENV NUSQLITE3_DIR=${NUSQLITE3_DIR}
ENV NUSQLITE3_PATH=${NUSQLITE3_PATH}

ENTRYPOINT ["tini", "--"]
CMD ["node", "index.js"]
