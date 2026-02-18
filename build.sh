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

echo -e "${YELLOW}Build Configuration:${NC}"
echo "  Git Repository: $GIT_REPO"
echo "  Git Branch: $GIT_BRANCH"
echo "  Build Folder: ${BUILD_FOLDER:-'(root)'}"
echo "  Platform: $PLATFORM"
echo "  Build Mode: $BUILD_MODE"
echo "  Build Target: $BUILD_TARGET"
[ -n "$TARGET_FLUTTER_VERSION" ] && echo "  Target Flutter Version: $TARGET_FLUTTER_VERSION"
echo ""

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

echo -e "${GREEN}===========================================${NC}"
echo -e "${GREEN}Build completed successfully!${NC}"
echo -e "${GREEN}===========================================${NC}"