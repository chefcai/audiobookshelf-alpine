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
#
# Iter 3: also drop build-time-only npm packages that npm's --omit=dev
# leaves in node_modules because sqlite3's runtime dep graph references
# them as `dependencies` (not `devDependencies`). They're only consulted
# when re-compiling the native binding from source — which we already did
# above in this same stage with `npm rebuild sqlite3`. After that, the
# .node binary is in lib/binding/ and these packages are dead weight.
#   - node-gyp        ~2.1 MB  — Python/C++ build orchestrator
#   - node-addon-api  ~416 KB  — header-only NAPI helper, compile-time only
#   - .cache          —         npm/node-gyp build cache leftovers
RUN set -e; \
    cd node_modules; \
    find . \( -name '*.md' -o -name '*.markdown' -o -name '*.map' -o -name '*.d.ts' -o -name '*.d.ts.map' \) -type f -delete; \
    find . -type d \( -name 'docs' -o -name 'doc' -o -name 'examples' -o -name 'example' -o -name '__tests__' -o -name 'test' -o -name 'tests' \) -prune -exec rm -rf {} +; \
    find . -type f \( -name 'CHANGELOG*' -o -name 'HISTORY*' -o -name 'AUTHORS' -o -name 'CONTRIBUTORS' -o -name '.travis.yml' -o -name '.eslintrc*' -o -name '.prettierrc*' -o -name 'tsconfig.json' \) -delete; \
    rm -rf node-gyp node-addon-api .cache; \
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
# Single RUN combining apk install + user setup + tiny housekeeping prunes.
# Why one RUN: docker layers are immutable, so a `rm` in a *later* layer
# only writes a whiteout — the bytes still occupy space in the prior layer.
# Any pruning has to happen in the same layer as the install to actually
# shrink the image.
#
# Pruned in-layer (small but free):
#   /usr/share/man, /usr/share/doc, /usr/share/info — apk's --no-cache
#       cleans the package cache but doesn't touch installed docs/manpages.
#       For a server image, these are dead weight (~2-4 MB).
#   /usr/share/X11, /usr/share/locale: no GUI, server uses TZ env not locale.
#
# NOTE: a previous attempt removed ffmpeg's transitive video-codec libs
# (libx264, libx265, libvpx, libaom, librav1e, libSvtAv1Enc, libdav1d,
# libtheora*, libpostproc, libvulkan, libdrm*, libva*) on the assumption
# that libavcodec dlopens them lazily and an audio-only runtime never
# would. WRONG: alpine 3.21's apk-built ffmpeg lists every one of these
# as a hard `NEEDED` ELF dep on /usr/bin/ffmpeg and on libavcodec.so —
# they're loaded at process startup regardless of which codec paths are
# taken, so removing any of them breaks ffmpeg with
# "Error loading shared library lib<x>.so.<ver>: No such file or directory".
# Documented in the README iteration log so future-us doesn't retry it.
RUN apk add --no-cache \
        nodejs-current \
        ffmpeg \
        tini \
        tzdata \
 && addgroup -g 13000 abs \
 && adduser -D -u 13001 -G abs abs \
 && rm -rf /usr/share/man /usr/share/doc /usr/share/info \
           /usr/share/X11 /usr/share/locale \
           /var/cache/apk/*

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
