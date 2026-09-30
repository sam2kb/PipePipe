# Disposable Android build toolchain for the PipePipe restricted-mode fork.
#
# The box itself has no JDK and no Android SDK; this image is the jail.
#   docker build -t pipepipe-android-build -f .build/Dockerfile .build
#   docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work -w /work/PipePipeClient \
#       -v pipepipe-gradle:/cache -e GRADLE_USER_HOME=/cache \
#       pipepipe-android-build ./gradlew assembleDebug
FROM eclipse-temurin:25-jdk-noble

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        procps \
        python3 \
        unzip \
        zip \
    && rm -rf /var/lib/apt/lists/*

ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:$PATH

# cmdline-tools must live in <sdk>/cmdline-tools/latest for sdkmanager to work.
RUN mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools" \
    && curl -fsSL -o /tmp/cmdline-tools.zip \
        https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip \
    && unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_SDK_ROOT/cmdline-tools" \
    && mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip

# Package list is passed at build time so the image can be rebuilt when the
# upstream project bumps compileSdk / build-tools.
ARG SDK_PACKAGES="platform-tools platforms;android-37.0 platforms;android-36 build-tools;37.0.0 build-tools;36.0.0"
RUN yes | sdkmanager --licenses > /dev/null \
    && sdkmanager --install ${SDK_PACKAGES} \
    && yes | sdkmanager --licenses > /dev/null

# Gradle downloads its distribution and all dependencies at first build; that
# cache belongs in a named volume (see tools/restricted-mode/build.sh).
ENV GRADLE_USER_HOME=/cache
WORKDIR /work
