#!/bin/sh
# Runtime PUID/PGID support (linuxserver.io-style).
# https://github.com/chefcai/audiobookshelf-alpine/issues/1
#
# Defaults to a generic 1000:1000 so this image runs out of the box on any
# host. Override with `-e PUID=... -e PGID=...` (or the PUID/PGID entries in
# docker-compose) to match your existing bind-mount ownership.
#
# Only app-state directories are remapped here -- never a media-library
# mount, which stays whatever the host already owns. Recursively chown'ing
# a large media library on every container start would be slow and is
# unnecessary; the deployer is expected to have already set that dir's
# ownership per the README.
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

CUR_UID=$(id -u abs)
CUR_GID=$(id -g abs)

if [ "$PGID" != "$CUR_GID" ]; then
  sed -i "s/^abs:x:[0-9]*:/abs:x:${PGID}:/" /etc/group
fi
if [ "$PUID" != "$CUR_UID" ]; then
  sed -i "s/^abs:x:[0-9]*:[0-9]*:/abs:x:${PUID}:${PGID}:/" /etc/passwd
fi

for dir in /config /metadata; do
  if [ -d "$dir" ]; then
    owner="$(stat -c '%u:%g' "$dir" 2>/dev/null || echo '?')"
    if [ "$owner" != "${PUID}:${PGID}" ]; then
      chown -R "${PUID}:${PGID}" "$dir"
    fi
  fi
done

exec su-exec abs "$@"
