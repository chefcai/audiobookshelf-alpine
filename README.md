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
| 2a | _attempted_ strip ffmpeg video-codec libs + HW-accel stubs | _broke ffmpeg_ | — | — |
| 2 | combine apk-add+prune into single RUN; drop man/doc/locale | **251 MB** | **−1 MB** | **−69 MB (−21.6 %)** |
| 3 | drop build-only `node-gyp` + `node-addon-api` from prod node_modules | _measuring…_ | _measuring…_ | _measuring…_ |

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

### Iter 2a — _failed_ — strip ffmpeg video-codec libs + HW-accel stubs

**Hypothesis (incorrect):** apk's `ffmpeg` pulls ~44 MB of video codec
providers (`libx265` 18.8 MB, `libaom` 7.4 MB, `libSvtAv1Enc` 6.5 MB,
`libvpx` 3.2 MB, `libx264`, `librav1e`, `libdav1d`, `libtheora*`,
`libpostproc`, plus `libvulkan` + `libdrm*` + `libva*` HW-accel stubs)
which the libav* core libraries dlopen on demand. An audio-only ABS
runtime should never trigger those code paths, so removing the `.so`
files should be safe.

**Why it didn't work:** alpine 3.21's apk-built ffmpeg lists every one
of those libraries as a hard `NEEDED` entry in the ELF dynamic section
of `/usr/bin/ffmpeg` and `libavcodec.so` itself. They're loaded at
process startup by the dynamic linker, regardless of which codec
paths the program ever takes. Removing them produced

```
Error loading shared library libpostproc.so.57: No such file or directory
    (needed by /usr/bin/ffmpeg)
Error loading shared library libdrm.so.2: No such file or directory
    (needed by /usr/lib/libavdevice.so.60)
```

at the first invocation of `ffmpeg`. `ldd /usr/bin/ffmpeg` confirms all
of them are direct deps. There is no audio-only build of ffmpeg in
Alpine's package repos.

**Side observation that mattered for iter 2:** even though the broken
image's `:latest` tag pointed to a runtime with the libs deleted, the
on-host image size was **still 252 MB** — identical to iter 1. Reason:
docker layers are immutable. The original `apk add ffmpeg` layer still
contains all those `.so` bytes; the subsequent `RUN rm` only writes
whiteout entries that hide them in the union view. The previous-layer
bytes still ship in the image. To actually shrink, the prune has to
happen in the **same RUN** as the install. Iter 2 corrects this layer
structure so any future in-layer prune actually reduces size.

**Carry-forward to future iters:** the ffmpeg slim path requires either
a custom-compiled ffmpeg (`./configure --disable-everything
--enable-decoder=mp3,aac,flac,opus,vorbis,…`) or replacing `apk add
ffmpeg` with a static minimal binary. Both add CI complexity and risk
to be evaluated separately if 252 MB is judged insufficient.

### Iter 2 — combine layers + prune docs/man/locale — 251 MB

Functional fixes from the iter 2a postmortem, plus small in-layer prunes
for free wins.

- All `apk add` + adduser + rm steps are now a single RUN, so any future
  same-layer pruning will actually reduce image size.
- Pruned in-layer: `/usr/share/man`, `/usr/share/doc`, `/usr/share/info`,
  `/usr/share/X11`, `/usr/share/locale`, `/var/cache/apk/*`.

Net: 1 MB reduction. The directories aren't huge in a minimal alpine, but
the corrected layer structure is the load-bearing change for any future
same-layer prune to actually shrink. Image boots cleanly, ffmpeg/ffprobe
work, ABS reaches `[Server] Init v2.33.2` and database init.

### Iter 3 — drop build-only npm packages from prod node_modules

`npm install --omit=dev` correctly skips the top-level devDependencies,
but `sqlite3` lists `node-gyp` and `node-addon-api` as runtime
`dependencies` so the resolver keeps them in the prod tree even though
they're only consulted when recompiling the native binding from source.

We already do `npm rebuild sqlite3` in the same stage, after which the
compiled `.node` binary lives in `node_modules/sqlite3/lib/binding/` and
neither `node-gyp` nor `node-addon-api` is ever loaded by the runtime.
Drop them.

| Package | Size | Reason it's safe to drop |
|---|---:|---|
| `node-gyp` | 2.1 MB | Compile-time orchestrator (Python + Make wrappers); only invoked by `npm rebuild`, which has already run. |
| `node-addon-api` | 416 KB | Header-only NAPI helper; symbols are baked into the compiled `.node` after `npm rebuild`. |
| `.cache` | varies | Build-tool scratch directory — never read at runtime. |

Net expected: ~2.5 MB.

### Plateau

After iter 3, the remaining 248-ish MB is mostly:

- `/usr/bin/node` — 61.7 MB, apk-stripped already
- `/usr/lib/lib*.so` — ~85 MB of ffmpeg deps that `ldd` shows are NEEDED
  at process startup (see iter 2a). Slimming any further requires
  building ffmpeg from source with codec subsetting, which is out of
  scope for this repo.
- `/app` — ~55 MB of ABS server source + production node_modules. The
  big-ticket items there (`moment` 4.6 MB, `lodash` 4.9 MB, `sqlite3`
  5.4 MB, `moment-timezone` 2.9 MB) are all runtime-essential.

Further iterations would yield <1 MB each — diminishing returns. Iter 3
is the last shrink pass.

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
