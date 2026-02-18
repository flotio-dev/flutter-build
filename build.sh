#!/bin/bash
set -e

# Let's build a Flutter application inside a Podman/Docker container
# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}===========================================${NC}"
echo -e "${GREEN}Flutter Build Script (CI Edition)${NC}"
echo -e "${GREEN}===========================================${NC}"

# Required environment variables
: ${GIT_REPO:?GIT_REPO environment variable is required}
: ${PLATFORM:?PLATFORM environment variable is required}
: ${BUILD_ID:?BUILD_ID environment variable is required}

# Optional environment variables with defaults
BUILD_FOLDER=${BUILD_FOLDER:-""}
TARGET_FLUTTER_VERSION=${TARGET_FLUTTER_VERSION:-""} # Remplace la détection hasardeuse
BUILD_MODE=${BUILD_MODE:-"release"}
BUILD_TARGET=${BUILD_TARGET:-"apk"}
OUTPUT_DIR=${OUTPUT_DIR:-"/outputs"}
ANDROID_SKIP_BUILD_DEPENDENCY_VALIDATION=${ANDROID_SKIP_BUILD_DEPENDENCY_VALIDATION:-"true"}
ANDROID_AUTO_FIX_MIN_SDK=${ANDROID_AUTO_FIX_MIN_SDK:-"true"}

# Git configuration
GIT_BRANCH=${GIT_BRANCH:-"main"}
GIT_USERNAME=${GIT_USERNAME:-""}
GIT_PASSWORD=${GIT_PASSWORD:-""}

# Keystore configuration for Android signing
KEYSTORE_PATH=${KEYSTORE_PATH:-""}

# Environment files directory
ENV_FILES_DIR=${ENV_FILES_DIR:-"/env-files"}

# AWS S3 configuration
AWS_S3_BUCKET=${AWS_S3_BUCKET:-""}
AWS_S3_PREFIX=${AWS_S3_PREFIX:-"builds"}
AWS_S3_ENDPOINT=${AWS_S3_ENDPOINT:-""}
AWS_REGION=${AWS_REGION:-"garage"}
AWS_S3_CACHE_PREFIX=${AWS_S3_CACHE_PREFIX:-"build-cache"}

# Build cache configuration
CACHE_ENABLED=${CACHE_ENABLED:-"true"}
CACHE_UPLOAD_ON_SUCCESS=${CACHE_UPLOAD_ON_SUCCESS:-"true"}
CACHE_NAMESPACE=${CACHE_NAMESPACE:-"global/main"}
CACHE_TTL_HOURS=${CACHE_TTL_HOURS:-"336"}
CACHE_INCLUDE_ANDROID_INTERMEDIATES=${CACHE_INCLUDE_ANDROID_INTERMEDIATES:-"true"}

echo -e "${YELLOW}Build Configuration:${NC}"
echo "  Git Repository: $GIT_REPO"
echo "  Git Branch: $GIT_BRANCH"
echo "  Build Folder: ${BUILD_FOLDER:-'(root)'}"
echo "  Platform: $PLATFORM"
echo "  Build Mode: $BUILD_MODE"
echo "  Build Target: $BUILD_TARGET"
[ -n "$TARGET_FLUTTER_VERSION" ] && echo "  Target Flutter Version: $TARGET_FLUTTER_VERSION"
echo "  Cache Enabled: $CACHE_ENABLED"
echo "  Cache Namespace: $CACHE_NAMESPACE"
echo ""

is_true() {
    local value
    value=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    [ "$value" = "true" ] || [ "$value" = "1" ] || [ "$value" = "yes" ] || [ "$value" = "on" ]
}

compute_cache_key() {
    local lock_files=(
        "pubspec.lock"
        "android/gradle/wrapper/gradle-wrapper.properties"
        "android/build.gradle"
        "android/build.gradle.kts"
        "android/app/build.gradle"
        "android/app/build.gradle.kts"
    )

    local fingerprint_source=""
    local lock_hash
    for lock_file in "${lock_files[@]}"; do
        if [ -f "$lock_file" ]; then
            lock_hash=$(sha256sum "$lock_file" | awk '{print $1}')
            fingerprint_source+="${lock_file}:${lock_hash}\n"
        fi
    done

    if [ -z "$fingerprint_source" ]; then
        fingerprint_source="${GIT_BRANCH}:${PLATFORM}:${BUILD_MODE}:${BUILD_TARGET}"
    fi

    local fingerprint
    fingerprint=$(printf "%b" "$fingerprint_source" | sha256sum | awk '{print $1}')
    echo "${CACHE_NAMESPACE}/${fingerprint}"
}

aws_s3_sync_best_effort() {
    local source_path="$1"
    local destination_path="$2"

    if [ -n "$AWS_S3_ENDPOINT" ]; then
        aws s3 sync "$source_path" "$destination_path" --region "$AWS_REGION" --endpoint-url "$AWS_S3_ENDPOINT" >/dev/null 2>&1 || return 1
        return 0
    fi

    aws s3 sync "$source_path" "$destination_path" --region "$AWS_REGION" >/dev/null 2>&1 || return 1
    return 0
}

restore_cache_if_enabled() {
    if ! is_true "$CACHE_ENABLED"; then
        echo "  Cache restore disabled"
        return
    fi

    if [ -z "$AWS_S3_BUCKET" ]; then
        echo "  Cache restore skipped (AWS_S3_BUCKET not configured)"
        return
    fi

    local pub_cache_dir
    pub_cache_dir="${PUB_CACHE:-$HOME/.pub-cache}"
    local gradle_cache_dir
    gradle_cache_dir="${GRADLE_USER_HOME:-$HOME/.gradle}"
    local intermediates_dir
    intermediates_dir="$(pwd)/build/app/intermediates"

    mkdir -p "$pub_cache_dir" "$gradle_cache_dir" "$intermediates_dir"

    local cache_key
    cache_key=$(compute_cache_key)
    local cache_s3_base
    cache_s3_base="s3://${AWS_S3_BUCKET}/${AWS_S3_CACHE_PREFIX}/${cache_key}"

    echo "  Cache key: $cache_key"

    if aws_s3_sync_best_effort "${cache_s3_base}/pub-cache/" "$pub_cache_dir/"; then
        echo "  ✓ Pub cache restored"
    else
        echo "  • No pub cache to restore"
    fi

    if aws_s3_sync_best_effort "${cache_s3_base}/gradle/" "$gradle_cache_dir/"; then
        echo "  ✓ Gradle cache restored"
    else
        echo "  • No Gradle cache to restore"
    fi

    if [ "$PLATFORM" = "android" ] && is_true "$CACHE_INCLUDE_ANDROID_INTERMEDIATES"; then
        if aws_s3_sync_best_effort "${cache_s3_base}/android-intermediates/" "$intermediates_dir/"; then
            echo "  ✓ Android intermediates restored"
        else
            echo "  • No Android intermediates cache to restore"
        fi
    fi

    export BUILD_CACHE_KEY="$cache_key"
}

save_cache_if_enabled() {
    if ! is_true "$CACHE_ENABLED"; then
        echo "  Cache upload disabled"
        return
    fi

    if ! is_true "$CACHE_UPLOAD_ON_SUCCESS"; then
        echo "  Cache upload policy disabled"
        return
    fi

    if [ -z "$AWS_S3_BUCKET" ]; then
        echo "  Cache upload skipped (AWS_S3_BUCKET not configured)"
        return
    fi

    local pub_cache_dir
    pub_cache_dir="${PUB_CACHE:-$HOME/.pub-cache}"
    local gradle_cache_dir
    gradle_cache_dir="${GRADLE_USER_HOME:-$HOME/.gradle}"
    local intermediates_dir
    intermediates_dir="$(pwd)/build/app/intermediates"

    local cache_key
    cache_key="${BUILD_CACHE_KEY:-$(compute_cache_key)}"
    local cache_s3_base
    cache_s3_base="s3://${AWS_S3_BUCKET}/${AWS_S3_CACHE_PREFIX}/${cache_key}"

    echo "  Cache key: $cache_key"

    if [ -d "$pub_cache_dir" ]; then
        aws_s3_sync_best_effort "$pub_cache_dir/" "${cache_s3_base}/pub-cache/" && echo "  ✓ Pub cache uploaded"
    fi

    if [ -d "$gradle_cache_dir" ]; then
        aws_s3_sync_best_effort "$gradle_cache_dir/" "${cache_s3_base}/gradle/" && echo "  ✓ Gradle cache uploaded"
    fi

    if [ "$PLATFORM" = "android" ] && is_true "$CACHE_INCLUDE_ANDROID_INTERMEDIATES" && [ -d "$intermediates_dir" ]; then
        aws_s3_sync_best_effort "$intermediates_dir/" "${cache_s3_base}/android-intermediates/" && echo "  ✓ Android intermediates uploaded"
    fi

    if [ -n "$CACHE_TTL_HOURS" ]; then
        echo "  Cache TTL target: ${CACHE_TTL_HOURS}h (appliqué via lifecycle bucket)"
    fi
}

# Step 1: Clone repository
echo -e "${GREEN}[1/8] Cloning repository...${NC}"
if [ -n "$GIT_USERNAME" ] && [ -n "$GIT_PASSWORD" ]; then
    GIT_URL_WITH_AUTH=$(echo "$GIT_REPO" | sed "s|https://|https://${GIT_USERNAME}:${GIT_PASSWORD}@|")
    git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL_WITH_AUTH" /workspace/repo
else
    git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_REPO" /workspace/repo
fi

# Navigate to build folder
if [ -n "$BUILD_FOLDER" ]; then
    cd "/workspace/repo/$BUILD_FOLDER"
    echo "  Working directory: /workspace/repo/$BUILD_FOLDER"
else
    cd /workspace/repo
    echo "  Working directory: /workspace/repo"
fi

# Step 2: Configure Flutter Version (Deterministic Approach via FVM)
echo -e "${GREEN}[2/8] Setting up Flutter version...${NC}"
if [ -n "$TARGET_FLUTTER_VERSION" ]; then
    echo "  Requested specific Flutter version: $TARGET_FLUTTER_VERSION"
    fvm install "$TARGET_FLUTTER_VERSION"
    fvm global "$TARGET_FLUTTER_VERSION"
    alias flutter="fvm flutter" # S'assure que les commandes suivantes utilisent FVM
elif [ -f ".fvm/fvm_config.json" ]; then
    echo "  Detected FVM configuration in project. Installing..."
    fvm install
    alias flutter="fvm flutter"
else
    echo "  No specific version requested. Using default global Flutter version."
fi
echo "  Active Flutter version:"
flutter --version | head -n 1

# Step 3: Process environment files
echo -e "${GREEN}[3/8] Processing environment files...${NC}"
if [ -d "$ENV_FILES_DIR" ] && [ "$(ls -A $ENV_FILES_DIR)" ]; then
    for file in "$ENV_FILES_DIR"/*; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            if [[ $filename == *"::"* ]]; then
                dest_path="${filename#*::}"
                dest_path="${dest_path//__/\/}"
                mkdir -p "$(dirname "$dest_path")"
                cp "$file" "$dest_path"
                echo "    ✓ $filename -> $dest_path"
            else
                cp "$file" "./$filename"
                echo "    ✓ $filename -> ./$filename"
            fi
        fi
    done
else
    echo "  No environment files to process"
fi

echo -e "${GREEN}[cache] Restoring dependency cache...${NC}"
restore_cache_if_enabled

# Step 4: Setup Android keystore if provided
if [ "$PLATFORM" = "android" ] && [ -f "$KEYSTORE_PATH" ]; then
    echo -e "${GREEN}[4/8] Setting up Android keystore...${NC}"
    
    # FIX: Path relative to the current project directory, not absolute workspace
    KEY_PROPERTIES_PATH="$(pwd)/android/key.properties"
    
    mkdir -p "$(dirname "$KEY_PROPERTIES_PATH")"
    cat > "$KEY_PROPERTIES_PATH" << EOF
storePassword=${KEYSTORE_PASSWORD:-android}
keyPassword=${KEY_PASSWORD:-android}
keyAlias=${KEY_ALIAS:-key}
storeFile=$KEYSTORE_PATH
EOF
    echo "  ✓ Keystore configured at: $KEY_PROPERTIES_PATH"
else
    echo -e "${GREEN}[4/8] Skipping keystore setup${NC}"
fi

# Step 5: Get Flutter dependencies
echo -e "${GREEN}[5/8] Getting Flutter dependencies...${NC}"
flutter pub get

# Step 6: Build the application
echo -e "${GREEN}[6/8] Building Flutter application...${NC}"

# Function definition placed before execution
ensure_android_min_sdk() {
    local min_sdk_required=23
    local gradle_file="android/app/build.gradle"
    local gradle_kts_file="android/app/build.gradle.kts"

    if [ "$ANDROID_AUTO_FIX_MIN_SDK" != "true" ]; then
        return 0
    fi

    if [ -f "$gradle_file" ]; then
        perl -i -pe "s/\\bminSdkVersion\\s+([0-9]+)/'minSdkVersion '.(\$1 < $min_sdk_required ? $min_sdk_required : \$1)/eg" "$gradle_file"
        perl -i -pe "s/\\bminSdk\\s+([0-9]+)/'minSdk '.(\$1 < $min_sdk_required ? $min_sdk_required : \$1)/eg" "$gradle_file"
        perl -i -pe "s/\\bminSdk\\s*=\\s*([0-9]+)/'minSdk = '.(\$1 < $min_sdk_required ? $min_sdk_required : \$1)/eg" "$gradle_file"
        echo "  ✓ minSdk patch applied on build.gradle"
    elif [ -f "$gradle_kts_file" ]; then
        perl -i -pe "s/\\bminSdk\\s*=\\s*([0-9]+)/'minSdk = '.(\$1 < $min_sdk_required ? $min_sdk_required : \$1)/eg" "$gradle_kts_file"
        perl -i -pe "s/\\bminSdkVersion\\s*=\\s*([0-9]+)/'minSdkVersion = '.(\$1 < $min_sdk_required ? $min_sdk_required : \$1)/eg" "$gradle_kts_file"
        echo "  ✓ minSdk patch applied on build.gradle.kts"
    fi
}

case "$PLATFORM" in
    android)
        ensure_android_min_sdk
        ANDROID_VALIDATION_FLAG=""
        # Safety check: Flag only exists in recent Flutter versions
        if [ "$ANDROID_SKIP_BUILD_DEPENDENCY_VALIDATION" = "true" ]; then
            ANDROID_VALIDATION_FLAG="--android-skip-build-dependency-validation"
        fi

        if [ "$BUILD_TARGET" = "appbundle" ] || [ "$BUILD_TARGET" = "aab" ]; then
            flutter build appbundle --$BUILD_MODE $ANDROID_VALIDATION_FLAG
            AAB_FILE=$(find build/app/outputs/bundle -name "*.aab" | head -n 1)
            if [ -f "$AAB_FILE" ]; then
                mkdir -p "$OUTPUT_DIR"
                cp "$AAB_FILE" "$OUTPUT_DIR/app-${BUILD_ID}.aab"
            else
                echo -e "${RED}  ✗ AAB file not found${NC}" && exit 1
            fi
        else
            flutter build apk --$BUILD_MODE $ANDROID_VALIDATION_FLAG
            APK_FILE=$(find build/app/outputs/flutter-apk -name "*.apk" | head -n 1)
            if [ -f "$APK_FILE" ]; then
                mkdir -p "$OUTPUT_DIR"
                cp "$APK_FILE" "$OUTPUT_DIR/app-${BUILD_ID}.apk"
            else
                echo -e "${RED}  ✗ APK file not found${NC}" && exit 1
            fi
        fi
        ;;
    ios)
        echo -e "${RED}  ✗ iOS build is not supported in this Linux container${NC}"
        exit 1
        ;;
    linux)
        flutter config --enable-linux-desktop
        flutter build linux --$BUILD_MODE
        mkdir -p "$OUTPUT_DIR"
        tar -czf "$OUTPUT_DIR/linux-build-${BUILD_ID}.tar.gz" -C build/linux .
        ;;
    web)
        flutter build web --$BUILD_MODE
        mkdir -p "$OUTPUT_DIR"
        tar -czf "$OUTPUT_DIR/web-build-${BUILD_ID}.tar.gz" -C build/web .
        ;;
    *)
        echo -e "${RED}  ✗ Unknown platform: $PLATFORM${NC}"
        exit 1
        ;;
esac

# Step 7: Generate build info
echo -e "${GREEN}[7/8] Generating build information...${NC}"
cat > "$OUTPUT_DIR/build-info.json" << EOF
{
  "build_id": "${BUILD_ID}",
  "platform": "${PLATFORM}",
  "build_mode": "${BUILD_MODE}",
  "build_target": "${BUILD_TARGET}",
  "git_repo": "${GIT_REPO}",
  "build_folder": "${BUILD_FOLDER}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "flutter_version": "$(flutter --version | head -n 1 | sed 's/"/\\"/g')",
  "s3_bucket": "${AWS_S3_BUCKET:-null}"
}
EOF

# Step 8: Upload to S3-compatible storage
if [ -n "$AWS_S3_BUCKET" ]; then
    echo -e "${GREEN}[8/8] Uploading artifacts to S3...${NC}"
    S3_PATH="s3://${AWS_S3_BUCKET}/${AWS_S3_PREFIX}/${BUILD_ID}"
    
    ENDPOINT_ARG=""
    [ -n "$AWS_S3_ENDPOINT" ] && ENDPOINT_ARG="--endpoint-url $AWS_S3_ENDPOINT"
    
    if aws s3 cp "$OUTPUT_DIR" "$S3_PATH" --recursive --region "$AWS_REGION" $ENDPOINT_ARG; then
        echo "  ✓ Artifacts uploaded successfully"
    else
        echo -e "${RED}  ✗ Failed to upload artifacts to S3${NC}"
    fi
else
    echo -e "${GREEN}[8/8] Skipping S3 upload${NC}"
fi

echo -e "${GREEN}[cache] Uploading dependency cache...${NC}"
save_cache_if_enabled

echo -e "${GREEN}===========================================${NC}"
echo -e "${GREEN}Build completed successfully!${NC}"
echo -e "${GREEN}===========================================${NC}"