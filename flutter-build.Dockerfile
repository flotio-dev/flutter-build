# Flutter Build Container - Production Ready (Optimized for CI)
# Includes Android SDK, Java, Flutter (Full Clone) and all necessary build tools
# Multi-architecture support (amd64/arm64)

FROM ubuntu:22.04 AS builder

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Define versions
ENV FLUTTER_VERSION=3.35.7
ENV ANDROID_SDK_VERSION=9477386
ENV ANDROID_BUILD_TOOLS_VERSION=34.0.0
ENV ANDROID_PLATFORMS_VERSION=34
ENV JAVA_VERSION=17

# Detect architecture for Android SDK
ARG TARGETARCH
ENV TARGETARCH=${TARGETARCH}

# 1. Install dependencies, Java, Python and AWS CLI in a single optimized layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git unzip xz-utils zip libglu1-mesa wget ca-certificates \
    openjdk-${JAVA_VERSION}-jdk-headless \
    clang cmake ninja-build pkg-config libgtk-3-0 liblzma5 libstdc++6 \
    libglib2.0-0 libsqlite3-0 libgtk-3-dev libsqlite3-dev \
    file ccache python3 python3-pip \
    && curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" \
    && unzip -q awscliv2.zip && ./aws/install && rm -rf awscliv2.zip aws \
    && apt-get autoremove -y && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Set Java environment
ENV JAVA_HOME=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-${TARGETARCH}
ENV PATH=$PATH:$JAVA_HOME/bin

# 2. Install Android SDK (architecture-aware) and NDK, then clean up immediately
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=$ANDROID_HOME
ENV PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/build-tools/${ANDROID_BUILD_TOOLS_VERSION}

RUN mkdir -p $ANDROID_HOME/cmdline-tools && cd $ANDROID_HOME/cmdline-tools \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip \
    && unzip -q commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip \
    && rm commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip \
    && mv cmdline-tools latest && rm -rf latest/NOTICE.txt \
    && yes | sdkmanager --licenses \
    && sdkmanager --install "platform-tools" "platforms;android-${ANDROID_PLATFORMS_VERSION}" "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" "ndk;25.1.8937393" \
    && rm -rf $ANDROID_HOME/tools $ANDROID_HOME/emulator $ANDROID_HOME/system-images $ANDROID_HOME/sources \
    && rm -rf $ANDROID_HOME/ndk/*/prebuilt/android-* $ANDROID_HOME/ndk/*/simpleperf $ANDROID_HOME/ndk/*/shader-tools \
    && find $ANDROID_HOME -name "*.jar.orig" -delete \
    && find $ANDROID_HOME -name "*.zip" -delete

# 3. Install Flutter (Full clone pour permettre le changement de channel/version à la volée)
ENV FLUTTER_HOME=/opt/flutter
ENV PATH=$PATH:$FLUTTER_HOME/bin

RUN git clone https://github.com/flutter/flutter.git -b ${FLUTTER_VERSION} $FLUTTER_HOME \
    && cd $FLUTTER_HOME \
    && git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" \
    && flutter config --no-analytics --enable-linux-desktop --enable-web \
    && flutter precache --android --linux --web --no-ios --no-windows --no-macos \
    && rm -rf $FLUTTER_HOME/bin/cache/artifacts/ios* \
    && rm -rf $FLUTTER_HOME/bin/cache/artifacts/macos* \
    && rm -rf $FLUTTER_HOME/bin/cache/artifacts/windows* \
    && rm -rf $FLUTTER_HOME/bin/cache/artifacts/fuchsia* \
    && rm -rf $FLUTTER_HOME/examples $FLUTTER_HOME/dev/benchmarks

# 4. Configure Gradle
ENV GRADLE_USER_HOME=/opt/gradle
RUN mkdir -p $GRADLE_USER_HOME \
    && echo "org.gradle.daemon=true\norg.gradle.parallel=true\norg.gradle.caching=true\norg.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=512m -XX:+HeapDumpOnOutOfMemoryError" > $GRADLE_USER_HOME/gradle.properties

# 5. Install FVM and set up non-root user properly (CRITICAL FIX)
ENV FVM_HOME=/opt/fvm
ENV FVM_CACHE_PATH=/opt/fvm/versions
RUN curl -fsSL https://fvm.app/install.sh | bash \
    && groupadd -r flutter -g 1000 \
    && useradd -r -u 1000 -g flutter -m -s /bin/bash flutter \
    && mkdir -p $FVM_HOME/versions /workspace /outputs \
    && chown -R flutter:flutter $FLUTTER_HOME $ANDROID_HOME $GRADLE_USER_HOME $FVM_HOME /workspace /outputs

# Put FVM binaries and standard pub cache in PATH for the flutter user
ENV PATH="/home/flutter/.pub-cache/bin:$PATH"

# Copy build script
COPY build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

# Switch to non-root user
USER flutter
WORKDIR /workspace

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/build.sh"]