# audiobookshelf-alpine — minimal Docker image of Audiobookshelf on Alpine
#
# Pattern mirrors chefcai/seerr-alpine and chefcai/jellyfin-alpine:
#   - Build happens in GitHub Actions, not on the deploying host.
#   - Final image is alpine:3.21 + apk nodejs (LTS) + a slim static
#     ffmpeg/ffprobe + the runtime artifacts needed by `node index.js`.
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
# so we fetch the linux-musl-x64 build unconditionally (amd64-only for now).
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
# NOTE: arm64 prebuild pruned too -- nusqlite3 (fetched above) is amd64-only,
# so an arm64 build would break at runtime even with sqlite3's binding present.
# See https://github.com/chefcai/audiobookshelf-alpine/issues/3
RUN set -e; \
    cd node_modules/sqlite3/lib/binding 2>/dev/null && \
    ls 1>/dev/null 2>&1 && { \
      find . -maxdepth 1 -mindepth 1 -type d \
        ! -name 'napi-v6-linux-musl-x64' \
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

# ---- Stage 2b: slim static ffmpeg/ffprobe ---------------------------------
# Alpine's `ffmpeg` apk hard-links every video codec lib (x264, x265, aom,
# SVT-AV1, rav1e, dav1d, vpx, vulkan, libplacebo, ...) as NEEDED deps, and
# they cannot be pruned after install (see the NOTE in the runtime stage).
# Audiobookshelf only ever uses ffmpeg for:
#   - probing audio files (ffprobe)
#   - HLS streaming: `-c:a copy` or `-c:a aac`, `-f hls` (mpegts or fmp4)
#   - m4b merge/encode: concat demuxer -> aac -> mp4/ipod
#   - tag/chapter embedding: ffmetadata input + cover-art attached_pic
#   - podcast download: node pipes the HTTP body into ffmpeg (pipe:),
#     ffmpeg never opens a network URL itself
#   - cover extraction (-map 0:v:0 -frames:v 1) and cover/author thumbnail
#     resize (`-vf scale=W:H` to .webp/.jpeg/.png)
# So we build ffmpeg with --disable-everything and enable only those
# components, statically linked against musl + libwebp + zlib. Network
# protocols are disabled on purpose.
FROM alpine:3.21 AS build-ffmpeg
ARG FFMPEG_VERSION=7.1.1
RUN apk add --no-cache build-base nasm pkgconf curl xz \
        zlib-dev zlib-static libwebp-dev libwebp-static
WORKDIR /src
RUN curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" | tar xJ --strip-components=1
RUN ./configure \
        --prefix=/opt/ffmpeg \
        --pkg-config-flags=--static \
        --extra-ldflags=-static \
        --enable-static --disable-shared \
        --disable-debug --disable-doc --disable-ffplay \
        --disable-autodetect --disable-network \
        --enable-zlib --enable-libwebp \
        --disable-everything \
        --enable-protocol=file,pipe \
        --enable-demuxer=mov,mp3,aac,flac,ogg,wav,aiff,asf,matroska,ape,wv,ac3,eac3,concat,ffmetadata,image2,image_jpeg_pipe,image_png_pipe,image_webp_pipe,mjpeg \
        --enable-muxer=mp4,ipod,mov,mp3,adts,flac,ogg,opus,wav,matroska,hls,mpegts,segment,ffmetadata,image2,mjpeg,webp,null \
        --enable-decoder=aac,aac_latm,mp3,mp3float,mp2,flac,alac,vorbis,opus,ac3,eac3,ape,wavpack,wmav1,wmav2,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,mjpeg,png,webp,gif,bmp \
        --enable-encoder=aac,flac,pcm_s16le,mjpeg,png,libwebp \
        --enable-parser=aac,aac_latm,mpegaudio,flac,opus,vorbis,ac3,mjpeg,png,webp \
        --enable-bsf=aac_adtstoasc,extract_extradata,null \
        --enable-filter=scale,format,null,anull,aresample,aformat,atrim,asetpts,setpts,pan,volume,concat,amix,apad,copy,acopy \
        --enable-swscale --enable-swresample \
 && make -j"$(nproc)" \
 && make install \
 && strip /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe \
 && /opt/ffmpeg/bin/ffmpeg -hide_banner -version | head -1 \
 && ! ldd /opt/ffmpeg/bin/ffmpeg 2>/dev/null | grep -q '=>'

# ---- Stage 3: runtime -----------------------------------------------------
# alpine:3.21 + `nodejs` (LTS, v22.x in 3.21). The previous `nodejs-current`
# package is v23.x in 3.21 -- an odd-numbered, end-of-life Node release.
# ffmpeg/ffprobe come from the slim static build stage above instead of apk.
# alpine:3.21 is kept deliberately: the sonarr/radarr/prowlarr/bazarr images
# use the same base, so the base layer is stored once on the host.
FROM alpine:3.21
ARG NUSQLITE3_DIR
ARG NUSQLITE3_PATH

# UID/GID 13001:13000 by default at build time (homelab convention, matches
# sonarr/radarr/jellyfin/seerr-alpine) -- fully overridable at runtime via
# the PUID/PGID env vars, see entrypoint.sh and
# https://github.com/chefcai/audiobookshelf-alpine/issues/1
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
        nodejs \
        tini \
        tzdata \
        su-exec \
 && addgroup -g 13000 abs \
 && adduser -D -u 13001 -G abs abs \
 && rm -rf /usr/share/man /usr/share/doc /usr/share/info \
           /usr/share/X11 /usr/share/locale \
           /var/cache/apk/*

WORKDIR /app

COPY --from=build-client --chown=abs:abs /src/client/dist /app/client/dist
COPY --from=build-server --chown=abs:abs /server          /app
COPY --from=build-server --chown=abs:abs ${NUSQLITE3_PATH} ${NUSQLITE3_PATH}
# Slim static ffmpeg/ffprobe (root-owned, on PATH for fluent-ffmpeg).
COPY --from=build-ffmpeg /opt/ffmpeg/bin/ffmpeg /opt/ffmpeg/bin/ffprobe /usr/local/bin/

RUN mkdir -p /config /metadata /audiobooks /podcasts \
 && chown -R abs:abs /config /metadata /app

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# NOTE: intentionally stays as root here -- entrypoint.sh drops to
# PUID:PGID (default 1000:1000) via su-exec at container start. See
# https://github.com/chefcai/audiobookshelf-alpine/issues/1

EXPOSE 80

ENV PORT=80
ENV NODE_ENV=production
ENV CONFIG_PATH=/config
ENV METADATA_PATH=/metadata
ENV SOURCE=docker
ENV NUSQLITE3_DIR=${NUSQLITE3_DIR}
ENV NUSQLITE3_PATH=${NUSQLITE3_PATH}

ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
CMD ["node", "index.js"]
