#!/usr/bin/env bash
# Run a Gradle task for PipePipeClient inside the disposable Android toolchain
# image.  The checkout is mounted read-write; Gradle's caches live in the named
# volume `pipepipe-gradle` so repeated builds are fast and nothing bulky ends up
# in the task checkout.
#
#   tools/restricted-mode/build.sh assembleDebug
#   tools/restricted-mode/build.sh testDebugUnitTest
#   tools/restricted-mode/build.sh assembleDebug --stacktrace
#
# Env:
#   IMAGE   docker image name            (default pipepipe-android-build)
#   VOLUME  named volume for gradle home (default pipepipe-gradle)
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${IMAGE:-pipepipe-android-build}"
VOLUME="${VOLUME:-pipepipe-gradle}"
DOCKER_CONFIG="${DOCKER_CONFIG:-$TASK_ROOT/.build/docker-config}"
mkdir -p "$DOCKER_CONFIG"
export DOCKER_CONFIG

# A release variant is only signed when the signing environment is present: without KEY_PATH the
# release signingConfig is never created and Gradle happily produces an *unsigned* APK that looks
# like a normal artifact. Refuse instead of shipping one.
for arg in "$@"; do
  case "$arg" in
    *assembleRelease*|*bundleRelease*|*Release)
      if [ -z "${KEY_PATH:-}" ]; then
        cat >&2 <<'EOF'
refusing to build a release variant without a signing key.

  KEY_PATH / KEY_STORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD are unset, so Gradle would emit an
  UNSIGNED apk that cannot be installed (INSTALL_PARSE_FAILED_NO_CERTIFICATES).

  Use the wrapper that generates/uses a throwaway key and verifies the result:

      tools/restricted-mode/build-release.sh

  or export the four variables yourself before calling this script.
EOF
        exit 2
      fi
      ;;
  esac
done

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "building toolchain image $IMAGE ..." >&2
  docker build -t "$IMAGE" -f "$TASK_ROOT/tools/restricted-mode/Dockerfile" \
    "$TASK_ROOT/tools/restricted-mode" >&2
fi

# A fresh named volume is root-owned; the build runs as the invoking user, so
# hand it over once at creation time instead of chowning a multi-GB cache later.
if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  docker volume create "$VOLUME" >/dev/null
  docker run --rm -u 0 -v "$VOLUME":/cache alpine:3.20 \
    chown -R "$(id -u):$(id -g)" /cache >/dev/null
fi

exec docker run --rm \
  -u "$(id -u):$(id -g)" \
  -v "$TASK_ROOT":/work \
  -w /work/PipePipeClient \
  -v "$VOLUME":/cache \
  -e GRADLE_USER_HOME=/cache/gradle \
  -e ANDROID_USER_HOME=/cache/android \
  -e HOME=/cache \
  -e TMPDIR=/tmp \
  -e GRADLE_OPTS="-Dorg.gradle.daemon=false" \
  -e KEY_PATH -e KEY_STORE_PASSWORD -e KEY_ALIAS -e KEY_PASSWORD \
  "$IMAGE" \
  ./gradlew --no-daemon --console=plain "$@"
