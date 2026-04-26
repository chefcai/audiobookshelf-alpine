# audiobookshelf-alpine

A footprint-minimized Docker image for [Audiobookshelf](https://github.com/advplyr/audiobookshelf),
built on Alpine Linux.

Same pattern as [`chefcai/seerr-alpine`](https://github.com/chefcai/seerr-alpine),
[`chefcai/jellyfin-alpine`](https://github.com/chefcai/jellyfin-alpine),
[`chefcai/ttyd-alpine`](https://github.com/chefcai/ttyd-alpine), and
[`chefcai/bazarr-alpine`](https://github.com/chefcai/bazarr-alpine): the image is
assembled in GitHub Actions and published to `ghcr.io`, so the eMMC-bound homelab
host (`squirttle`) never holds intermediate build artifacts.

## Upstream tracking

This image tracks the **latest tagged release** of
[`advplyr/audiobookshelf`](https://github.com/advplyr/audiobookshelf). The
GitHub Actions workflow resolves `https://api.github.com/repos/advplyr/audiobookshelf/releases/latest`
on each run and skips the build if that tag is already published to GHCR
(daily cron at 07:45 UTC).

## Image

```
ghcr.io/chefcai/audiobookshelf-alpine:latest
ghcr.io/chefcai/audiobookshelf-alpine:<upstream-tag>   # e.g., v2.33.2
```

## Result

| | Size | Δ vs upstream |
|---|---:|---:|
| `ghcr.io/advplyr/audiobookshelf:latest` (upstream) | **320 MB** | — |
| `ghcr.io/chefcai/audiobookshelf-alpine:latest` (iter 2) | _measuring…_ | _measuring…_ |

(Sizes here are reported uncompressed by `docker images` — i.e., what the
image occupies on the host's filesystem after pull. The CI workflow logs
the compressed manifest size as a sanity-check.)

## Why

`squirttle` (Wyse 5020) has only ~12 GB of eMMC and no expansion path. Audiobookshelf
upstream is already multi-stage and reasonably tight, but several lines remain on the
table:

- the `node:20-alpine` base layer (~127 MB) versus alpine:3.21 + apk
  `nodejs-current` (~50 MB)
- arch-specific `sqlite3` prebuilds for darwin/win/linux-glibc that musl-x64 never
  loads
- `*.d.ts`, `*.map`, `*.md`, `docs/`, `test/`, `examples/`, and lifecycle metadata
  in production `node_modules`
- ffmpeg ships with codecs and tools the audio-server runtime never invokes (subject
  to verification — see iteration log below)

## How it shrinks the image

Multi-stage Dockerfile:

1. **Build client** (`node:20-alpine`): `git clone --depth 1` upstream at the tracked
   release, `cd client && npm ci && npm run generate` → static SPA in `client/dist/`.
2. **Build server** (`node:20-alpine`): same source clone, `npm ci --omit=dev
   --ignore-scripts`, `npm rebuild sqlite3`, fetch `libnusqlite3.so` for
   `linux-musl-x64`, then strip arch-specific sqlite3 prebuilds + `*.d.ts` /
   `*.map` / `*.md` / `docs/` / `test/` / `examples/` from `node_modules`.
3. **Runtime** (`alpine:3.21`): `apk add nodejs-current ffmpeg tini tzdata`, copy
   only the runtime artifacts from the prior stages, drop privileges to UID
   13001 / GID 13000 (homelab-wide PUID/PGID convention).

Net effect: same `node index.js` entrypoint, same upstream release SHA,
none of the build-time weight or non-target arch binaries.

## Iteration log

| Iter | Change | Image size | Δ vs prev | Δ vs upstream |
|---:|---|---:|---:|---:|
| 0 | upstream `ghcr.io/advplyr/audiobookshelf:latest` | 320 MB | — | — |
| 1 | multi-stage + prod-only re-install + alpine runtime + native/cruft prune | **252 MB** | **−68 MB** | **−68 MB (−21.3 %)** |
| 2 | strip ffmpeg video-codec libs + HW-accel stubs (audio-only runtime) | _measuring…_ | _measuring…_ | _measuring…_ |

(The iteration log is updated in-place with each commit. Each row corresponds
to one Dockerfile change pushed to `main`; the size column is the uncompressed
on-host size as reported by `docker images`.)

### Iter 1 — multi-stage + prod-only re-install + alpine runtime base — 252 MB

Adopt the seerr-alpine playbook end-to-end. Three stages: build-client (Nuxt
generate), build-server (`npm ci --omit=dev --ignore-scripts` + `npm rebuild
sqlite3` + nusqlite3 fetch + node_modules prune), runtime (`alpine:3.21` +
apk `nodejs-current` + apk `ffmpeg` + apk `tini` + apk `tzdata`).

Wins versus upstream's already-multi-stage `node:20-alpine` runtime base:

- swapping `node:20-alpine` → `alpine:3.21 + nodejs-current` is the dominant
  contribution (~127 MB → ~50 MB on the runtime base layer)
- dropping non-musl-x64 sqlite3 prebuilds + `*.d.ts` / `*.map` / docs / tests
  in `node_modules` accounts for the rest

The 21 % shave from this iter alone covers the headroom most easily attacked
without runtime smoke-testing. ffmpeg slimming is the next big lever and gets
its own iter so the diff is bisectable if anything regresses.

### Iter 2 — strip ffmpeg video-codec libs + HW-accel stubs

Audiobookshelf only ever transcodes audio (HLS audio streaming, cover-art
extraction, chapter timing). Apk's `ffmpeg` package pulls in a lot of video
codec providers via shared deps that the audio runtime never invokes:

| Library | Size | Purpose | Audio-only need? |
|---|---:|---|---|
| `libx265.so` | 18.8 MB | H.265 video encoder | No |
| `libaom.so` | 7.4 MB | AV1 video encoder | No |
| `libSvtAv1Enc.so` | 6.5 MB | AV1 video encoder | No |
| `libvpx.so` | 3.2 MB | VP8/VP9 video encoder | No |
| `libx264.so` | 2.2 MB | H.264 video encoder | No |
| `librav1e.so` | 2.2 MB | AV1 video encoder | No |
| `libdav1d.so` | 1.6 MB | AV1 video decoder | No |
| `libtheora*.so` | 0.6 MB | Theora video codec | No |
| `libpostproc.so` | 84 KB | Video post-processing | No |
| `libvulkan.so` + `libdrm*.so` + `libva*.so` | ~1.4 MB | Hardware accel | No (no `--device` passthrough) |

ffmpeg's core (`libavcodec`, `libavformat`, `libavfilter`, `libswresample`,
`libswscale`, `libavutil`) loads these via `dlopen()` on demand; if an
audio-only code path is taken, the missing libs are never opened. Total
projected savings: **~44 MB**.

`libwebp` is kept — small (480 KB) and used for cover-art format conversion
in some audiobook libraries.

## Deployment

In `~/arrs/docker-compose.yml` on squirttle, side-by-side with the existing
upstream-image-based `audiobookshelf` service while validating:

```yaml
audiobookshelf-alpine:
  image: ghcr.io/chefcai/audiobookshelf-alpine:latest
  container_name: audiobookshelf-alpine
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
  environment:
    - TZ=America/New_York
  healthcheck:
    test: ["CMD", "wget", "-qO-", "http://localhost:80/healthcheck"]
    interval: 1m30s
    timeout: 10s
    retries: 3
  ports:
    - "13379:80"           # 13378 is the upstream-image install
  volumes:
    # Distinct host paths from the upstream-image install so a config
    # corruption in one doesn't bleed into the other.
    - /home/haadmin/config/audiobookshelf-alpine-config:/config
    - /mnt/Media/data/media/audiobooks:/audiobooks:ro
    - /mnt/Media/data/media/podcasts:/podcasts:ro
    - /mnt/Media/config/audiobookshelf-alpine/metadata:/metadata
  restart: unless-stopped
  networks:
    - arrs_net
```

The library mounts are read-only during validation — Audiobookshelf can write
metadata back into source files when "Embed metadata" is enabled, and we don't
want this validation install touching the production library.

After first start, the host paths must be `chown -R 13001:13000` to match the
container's UID/GID, or the runtime will EACCES on `/config/`.

## Bootstrap notes

This is a brand-new GHCR package, so the first push is bootstrapped manually
with a PAT (the workflow `GITHUB_TOKEN` cannot create new packages even with
`packages: write`). After the bootstrap push, package settings → "Manage
Actions access" → add this repo with **Write** role; subsequent workflow
runs push freely.

## License

Audiobookshelf is GPL-3.0 (upstream). This Dockerfile and supporting build
glue are MIT.
