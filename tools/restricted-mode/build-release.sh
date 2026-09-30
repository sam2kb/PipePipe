#!/usr/bin/env bash
# Build a *signed release* APK of the Restricted Mode fork with a throwaway key.
#
# The key is generated into .build/ (git-ignored) and is only meant for test installs
# (`adb install`). For a real deployment, sign with the administrator's own key by setting
# KEY_PATH / KEY_STORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD before calling build.sh.
#
#   tools/restricted-mode/build-release.sh
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${IMAGE:-pipepipe-android-build}"
VOLUME="${VOLUME:-pipepipe-gradle}"
KEYSTORE="$TASK_ROOT/.build/test-keystore.jks"
STOREPASS="${STOREPASS:-pipepipetest}"
ALIAS="${ALIAS:-pipepipe}"

DOCKER_CONFIG="${DOCKER_CONFIG:-$TASK_ROOT/.build/docker-config}"
mkdir -p "$DOCKER_CONFIG"
export DOCKER_CONFIG

if [ ! -f "$KEYSTORE" ]; then
  echo "generating throwaway signing key -> $KEYSTORE" >&2
  docker run --rm -u "$(id -u):$(id -g)" -v "$TASK_ROOT":/work -w /work \
    "$IMAGE" keytool -genkeypair -v \
      -keystore .build/test-keystore.jks \
      -storetype JKS \
      -alias "$ALIAS" \
      -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "$STOREPASS" -keypass "$STOREPASS" \
      -dname "CN=PipePipe Restricted Mode Test, OU=Test, O=Test, L=Test, S=Test, C=US"
fi

KEY_PATH=/work/.build/test-keystore.jks \
KEY_STORE_PASSWORD="$STOREPASS" \
KEY_ALIAS="$ALIAS" \
KEY_PASSWORD="$STOREPASS" \
  "$TASK_ROOT/tools/restricted-mode/build.sh" :app:assembleRelease "$@"

# Never trust that the build signed what it produced: verify every release APK, and fail the script
# if one of them does not verify. (Skipping this is how an unsigned "release" APK shipped once.)
docker run --rm -u "$(id -u):$(id -g)" -v "$TASK_ROOT":/work -w /work "$IMAGE" bash -c '
  BT=/opt/android-sdk/build-tools/36.0.0
  fail=0
  for apk in PipePipeClient/app/build/outputs/apk/release/*.apk; do
    if "$BT/apksigner" verify "$apk" >/dev/null 2>&1; then
      dn=$("$BT/apksigner" verify --print-certs "$apk" 2>/dev/null | sed -n "s/^Signer #1 certificate DN: //p" | head -1)
      printf "signed   %s  [%s]\n" "$(basename "$apk")" "$dn"
    else
      printf "UNSIGNED %s\n" "$(basename "$apk")" >&2
      fail=1
    fi
  done
  exit $fail
'
