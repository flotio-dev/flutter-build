# Flutter Build Container - Production Ready (Optimized for CI)
# Includes Android SDK, Java, Flutter (Full Clone) and all necessary build tools
# Multi-architecture support (amd64/arm64)

FROM ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b AS builder

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Define versions
ENV FLUTTER_VERSION=3.35.7
ENV FLUTTER_REVISION=adc901062556672b4138e18a4dc62a4be8f4b3c2
ENV ANDROID_SDK_VERSION=15859902
ENV ANDROID_SDK_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
ENV ANDROID_BUILD_TOOLS_VERSION=36.0.0
ENV ANDROID_PLATFORMS_VERSION=36
ENV ANDROID_NDK_VERSION=27.0.12077973
ENV JAVA_VERSION=17
ENV AWS_CLI_VERSION=2.36.25

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
    && curl -fsSLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m)-${AWS_CLI_VERSION}.zip" \
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

ARG NDK_SETUPTOOLS_VERSION=84.0.0
ARG NDK_SETUPTOOLS_SHA256=51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670

RUN mkdir -p $ANDROID_HOME/cmdline-tools && cd $ANDROID_HOME/cmdline-tools \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip \
    && echo "${ANDROID_SDK_SHA256}  commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip" | sha256sum -c - \
    && unzip -q commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip \
    && rm commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip \
    && mv cmdline-tools latest && rm -rf latest/NOTICE.txt \
    && yes | sdkmanager --licenses \
    && sdkmanager --install "platform-tools" "platforms;android-${ANDROID_PLATFORMS_VERSION}" "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" "ndk;${ANDROID_NDK_VERSION}" \
    && setuptools_wheel="/tmp/setuptools-${NDK_SETUPTOOLS_VERSION}-py3-none-any.whl" \
    && curl -fsSLo "$setuptools_wheel" "https://files.pythonhosted.org/packages/95/9c/c510029fc6ef33a6275cd2c5d3cecd6613dfd6aa401d57c54f1c18852ccf/setuptools-${NDK_SETUPTOOLS_VERSION}-py3-none-any.whl" \
    && echo "${NDK_SETUPTOOLS_SHA256}  $setuptools_wheel" | sha256sum -c - \
    && ndk_site="$ANDROID_HOME/ndk/${ANDROID_NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/python3/lib/python3.11/site-packages" \
    && rm -rf "$ndk_site"/setuptools "$ndk_site"/setuptools-*.dist-info "$ndk_site"/_distutils_hack "$ndk_site"/distutils-precedence.pth \
    && python3 -m pip install --no-index --target "$ndk_site" "$setuptools_wheel" \
    && grep -qx "Version: ${NDK_SETUPTOOLS_VERSION}" "$ndk_site/setuptools-${NDK_SETUPTOOLS_VERSION}.dist-info/METADATA" \
    && rm -f "$setuptools_wheel" \
    && rm -rf $ANDROID_HOME/tools $ANDROID_HOME/emulator $ANDROID_HOME/system-images $ANDROID_HOME/sources \
    && rm -rf $ANDROID_HOME/ndk/*/prebuilt/android-* $ANDROID_HOME/ndk/*/simpleperf $ANDROID_HOME/ndk/*/shader-tools \
    && find $ANDROID_HOME -name "*.jar.orig" -delete \
    && find $ANDROID_HOME -name "*.zip" -delete

# 3. Install Flutter (Full clone pour permettre le changement de channel/version à la volée)
ENV FLUTTER_HOME=/opt/flutter
ENV PATH=$PATH:$FLUTTER_HOME/bin

RUN git clone https://github.com/flutter/flutter.git $FLUTTER_HOME \
    && cd $FLUTTER_HOME \
    && git checkout --detach ${FLUTTER_REVISION} \
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
ENV PUB_CACHE=/opt/pub-cache
RUN dart pub global activate fvm 4.1.2 \
    && groupadd -r flutter -g 1000 \
    && useradd -r -u 1000 -g flutter -m -s /bin/bash flutter \
    && mkdir -p $FVM_HOME/versions /workspace /outputs \
    && chown flutter:flutter /opt \
    && chown -R flutter:flutter $FLUTTER_HOME $ANDROID_HOME $GRADLE_USER_HOME $FVM_HOME $PUB_CACHE /workspace /outputs

# Put FVM binaries and standard pub cache in PATH for the flutter user
ENV PATH="$PUB_CACHE/bin:/home/flutter/.pub-cache/bin:$PATH"

# Copy build script
COPY build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

# Switch to non-root user
USER flutter
WORKDIR /workspace

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/build.sh"]
