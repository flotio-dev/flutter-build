#!/bin/bash
set -e

# Let's build a Flutter application inside a Podman container
# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}===========================================${NC}"
echo -e "${GREEN}Flutter Build Script${NC}"
echo -e "${GREEN}===========================================${NC}"

# Required environment variables
: ${GIT_REPO:?GIT_REPO environment variable is required}
: ${PLATFORM:?PLATFORM environment variable is required}
: ${BUILD_ID:?BUILD_ID environment variable is required}

# Optional environment variables with defaults
BUILD_FOLDER=${BUILD_FOLDER:-""}
FLUTTER_CHANNEL=${FLUTTER_CHANNEL:-"stable"}
BUILD_MODE=${BUILD_MODE:-"release"}
BUILD_TARGET=${BUILD_TARGET:-"apk"}
OUTPUT_DIR=${OUTPUT_DIR:-"/outputs"}

# Git configuration
GIT_BRANCH=${GIT_BRANCH:-"main"}
GIT_USERNAME=${GIT_USERNAME:-""}
GIT_PASSWORD=${GIT_PASSWORD:-""}

# Keystore configuration for Android signing
KEYSTORE_PATH=${KEYSTORE_PATH:-""}
KEY_PROPERTIES_PATH="/workspace/android/key.properties"

# Environment files directory
ENV_FILES_DIR=${ENV_FILES_DIR:-"/env-files"}

# AWS S3 configuration for artifact upload (S3-compatible providers like Garage, MinIO, etc.)
AWS_S3_BUCKET=${AWS_S3_BUCKET:-""}
AWS_S3_PREFIX=${AWS_S3_PREFIX:-"builds"}
AWS_S3_ENDPOINT=${AWS_S3_ENDPOINT:-""}  # Custom endpoint URL for S3-compatible providers (e.g., https://s3.garage.example.com)
AWS_REGION=${AWS_REGION:-"garage"}       # Region (can be any value for Garage)
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY should be set via environment

echo -e "${YELLOW}Build Configuration:${NC}"
echo "  Git Repository: $GIT_REPO"
echo "  Git Branch: $GIT_BRANCH"
echo "  Build Folder: ${BUILD_FOLDER:-'(root)'}"
echo "  Flutter Channel: $FLUTTER_CHANNEL"
echo "  Platform: $PLATFORM"
echo "  Build Mode: $BUILD_MODE"
echo "  Build Target: $BUILD_TARGET"
if [ -n "$AWS_S3_BUCKET" ]; then
    echo "  S3 Bucket: $AWS_S3_BUCKET"
    echo "  S3 Prefix: $AWS_S3_PREFIX"
    [ -n "$AWS_S3_ENDPOINT" ] && echo "  S3 Endpoint: $AWS_S3_ENDPOINT"
fi
echo ""

# Step 1: Clone repository
echo -e "${GREEN}[1/8] Cloning repository...${NC}"
if [ -n "$GIT_USERNAME" ] && [ -n "$GIT_PASSWORD" ]; then
    # Clone with authentication
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

# Step 2: Detect and install required Flutter version
echo -e "${GREEN}[2/8] Detecting required Flutter/Dart version...${NC}"

# Function to extract version constraint from pubspec.yaml
detect_flutter_version() {
    if [ ! -f "pubspec.yaml" ]; then
        echo "  ⚠ No pubspec.yaml found, using installed Flutter version"
        return
    fi

    # Check for Flutter SDK constraint
    FLUTTER_CONSTRAINT=$(grep -A 2 "^  sdk:" pubspec.yaml | grep "flutter:" | sed 's/.*flutter: *"\([^"]*\)".*/\1/' || echo "")

    # Check for Dart SDK constraint (more common)
    DART_CONSTRAINT=$(grep -A 2 "^environment:" pubspec.yaml | grep "sdk:" | sed 's/.*: *["\x27]\([^"\x27]*\)["\x27].*/\1/' || echo "")

    if [ -z "$DART_CONSTRAINT" ]; then
        DART_CONSTRAINT=$(grep "^  sdk:" pubspec.yaml | sed 's/.*: *["\x27]\([^"\x27]*\)["\x27].*/\1/' || echo "")
    fi

    echo "  Detected constraints:"
    [ -n "$FLUTTER_CONSTRAINT" ] && echo "    Flutter: $FLUTTER_CONSTRAINT"
    [ -n "$DART_CONSTRAINT" ] && echo "    Dart: $DART_CONSTRAINT"

    # Extract minimum version from constraint (e.g., ">=3.0.0 <4.0.0" -> "3.0.0" or "^3.9.2" -> "3.9.2")
    if [ -n "$DART_CONSTRAINT" ]; then
        REQUIRED_VERSION=$(echo "$DART_CONSTRAINT" | sed -E 's/.*[>=^~]([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
        echo "  Minimum Dart version required: $REQUIRED_VERSION"

        # Get current Dart version
        CURRENT_DART_VERSION=$(dart --version 2>&1 | grep -oP 'Dart SDK version: \K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
        echo "  Current Dart version: $CURRENT_DART_VERSION"

        # Compare versions
        if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$CURRENT_DART_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
            echo "  ⚠ Current Dart version ($CURRENT_DART_VERSION) is older than required ($REQUIRED_VERSION)"
            echo "  Attempting to switch to compatible Flutter version..."

            # Try to find and install compatible Flutter version
            install_compatible_flutter "$REQUIRED_VERSION"
        else
            echo "  ✓ Current Dart version is compatible"
        fi
    else
        echo "  No specific Dart SDK constraint found, using current Flutter installation"
    fi
}

# Function to install compatible Flutter version
install_compatible_flutter() {
    local required_dart_version=$1

    echo "  Preparing Flutter repository for channel switching..."
    cd $FLUTTER_HOME

    # Ensure we can fetch all branches
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    git fetch origin --depth=1 stable beta master 2>/dev/null || git fetch origin stable beta master

    # Get current channel or default to stable
    CURRENT_CHANNEL=$(flutter channel 2>/dev/null | grep '^\*' | awk '{print $2}' || echo "stable")
    if [ -z "$CURRENT_CHANNEL" ] || [ "$CURRENT_CHANNEL" = "*" ]; then
        echo "  No channel detected, switching to stable first..."
        git checkout origin/stable
        flutter channel stable
        CURRENT_CHANNEL="stable"
    fi

    echo "  Current channel: $CURRENT_CHANNEL"
    cd - > /dev/null

    # Use FVM (Flutter Version Management) if available
    if command -v fvm &> /dev/null; then
        echo "  Using FVM to install compatible Flutter version..."
        # FVM can automatically select the right version
        if fvm install 2>/dev/null && fvm use 2>/dev/null; then
            echo "  ✓ FVM configured successfully"
            return 0
        fi
        echo "  FVM not configured for this project, falling back to flutter upgrade"
    fi

    echo "  Attempting to upgrade Flutter to get compatible Dart version..."

    # First, try upgrading on current channel
    flutter upgrade --force

    UPDATED_DART_VERSION=$(dart --version 2>&1 | grep -oP 'Dart SDK version: \K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    echo "  Updated Dart version: $UPDATED_DART_VERSION"

    # If still not compatible, try switching to a different channel
    if [ "$(printf '%s\n' "$required_dart_version" "$UPDATED_DART_VERSION" | sort -V | head -n1)" != "$required_dart_version" ]; then
        echo "  Trying beta channel for newer Dart version..."
        flutter channel beta
        flutter upgrade --force

        BETA_DART_VERSION=$(dart --version 2>&1 | grep -oP 'Dart SDK version: \K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
        echo "  Beta channel Dart version: $BETA_DART_VERSION"

        # If beta still not enough, try master
        if [ "$(printf '%s\n' "$required_dart_version" "$BETA_DART_VERSION" | sort -V | head -n1)" != "$required_dart_version" ]; then
            echo "  Trying master channel for latest Dart version..."
            flutter channel master
            flutter upgrade --force
        fi
    fi

    FINAL_DART_VERSION=$(dart --version 2>&1 | grep -oP 'Dart SDK version: \K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    echo "  Final Dart version: $FINAL_DART_VERSION"

    if [ "$(printf '%s\n' "$required_dart_version" "$FINAL_DART_VERSION" | sort -V | head -n1)" != "$required_dart_version" ]; then
        echo -e "${RED}  ✗ Could not find compatible Flutter/Dart version${NC}"
        echo -e "${RED}  Required Dart: $required_dart_version, Available: $FINAL_DART_VERSION${NC}"
        echo ""
        echo "  Suggestion: Update your Dockerfile to use a newer Flutter version or"
        echo "  specify FLUTTER_VERSION environment variable with a compatible version."
        exit 1
    else
        echo "  ✓ Successfully installed compatible Flutter/Dart version"
    fi
}

# Run version detection
detect_flutter_version

# Step 3: Process environment files
echo -e "${GREEN}[3/8] Processing environment files...${NC}"
if [ -d "$ENV_FILES_DIR" ] && [ "$(ls -A $ENV_FILES_DIR)" ]; then
    echo "  Found environment files to process:"
    for file in "$ENV_FILES_DIR"/*; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            # Extract destination from filename if it contains "::" separator
            if [[ $filename == *"::"* ]]; then
                dest_path="${filename#*::}"
                dest_path="${dest_path//__/\/}"  # Replace __ with /
                mkdir -p "$(dirname "$dest_path")"
                cp "$file" "$dest_path"
                echo "    ✓ $filename -> $dest_path"
            else
                # Default behavior: place in project root
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

    # Create key.properties file
    mkdir -p "$(dirname "$KEY_PROPERTIES_PATH")"
    cat > "$KEY_PROPERTIES_PATH" << EOF
storePassword=${KEYSTORE_PASSWORD:-android}
keyPassword=${KEY_PASSWORD:-android}
keyAlias=${KEY_ALIAS:-key}
storeFile=$KEYSTORE_PATH
EOF

    echo "  ✓ Keystore configured at: $KEYSTORE_PATH"

    # Update build.gradle to use key.properties if not already configured
    GRADLE_FILE="android/app/build.gradle"
    if [ -f "$GRADLE_FILE" ]; then
        if ! grep -q "key.properties" "$GRADLE_FILE"; then
            echo "  ⚠ Warning: build.gradle may need manual configuration for signing"
        fi
    fi
else
    echo -e "${GREEN}[4/8] Skipping keystore setup${NC}"
fi

# Step 5: Get Flutter dependencies
echo -e "${GREEN}[5/8] Getting Flutter dependencies...${NC}"
flutter pub get

# Step 6: Build the application
echo -e "${GREEN}[6/8] Building Flutter application...${NC}"

case "$PLATFORM" in
    android)
        if [ "$BUILD_TARGET" = "appbundle" ] || [ "$BUILD_TARGET" = "aab" ]; then
            echo "  Building Android App Bundle (.aab)..."
            flutter build appbundle --$BUILD_MODE

            # Find and copy the AAB file
            AAB_FILE=$(find build/app/outputs/bundle -name "*.aab" | head -n 1)
            if [ -f "$AAB_FILE" ]; then
                mkdir -p "$OUTPUT_DIR"
                OUTPUT_FILE="$OUTPUT_DIR/app-${BUILD_ID}.aab"
                cp "$AAB_FILE" "$OUTPUT_FILE"
                echo "  ✓ AAB built successfully: $OUTPUT_FILE"
            else
                echo -e "${RED}  ✗ AAB file not found${NC}"
                exit 1
            fi
        else
            echo "  Building Android APK..."
            flutter build apk --$BUILD_MODE

            # Find and copy the APK file
            APK_FILE=$(find build/app/outputs/flutter-apk -name "*.apk" | head -n 1)
            if [ -f "$APK_FILE" ]; then
                mkdir -p "$OUTPUT_DIR"
                OUTPUT_FILE="$OUTPUT_DIR/app-${BUILD_ID}.apk"
                cp "$APK_FILE" "$OUTPUT_FILE"
                echo "  ✓ APK built successfully: $OUTPUT_FILE"
            else
                echo -e "${RED}  ✗ APK file not found${NC}"
                exit 1
            fi
        fi
        ;;

    ios)
        echo "  Building iOS application..."
        flutter build ios --$BUILD_MODE --no-codesign

        # Copy iOS build artifacts
        mkdir -p "$OUTPUT_DIR"
        if [ -d "build/ios/iphoneos" ]; then
            tar -czf "$OUTPUT_DIR/ios-build-${BUILD_ID}.tar.gz" -C build/ios/iphoneos .
            echo "  ✓ iOS build completed: $OUTPUT_DIR/ios-build-${BUILD_ID}.tar.gz"
        else
            echo -e "${RED}  ✗ iOS build directory not found${NC}"
            exit 1
        fi
        ;;

    web)
        echo "  Building web application..."
        flutter build web --$BUILD_MODE

        # Copy web build artifacts
        mkdir -p "$OUTPUT_DIR"
        tar -czf "$OUTPUT_DIR/web-build-${BUILD_ID}.tar.gz" -C build/web .
        echo "  ✓ Web build completed: $OUTPUT_DIR/web-build-${BUILD_ID}.tar.gz"
        ;;

    *)
        echo -e "${RED}  ✗ Unknown platform: $PLATFORM${NC}"
        echo "  Supported platforms: android, ios, web"
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
  "flutter_channel": "${FLUTTER_CHANNEL}",
  "git_repo": "${GIT_REPO}",
  "git_branch": "${GIT_BRANCH}",
  "build_folder": "${BUILD_FOLDER}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "flutter_version": "$(flutter --version | head -n 1)",
  "s3_bucket": "${AWS_S3_BUCKET:-null}",
  "s3_prefix": "${AWS_S3_PREFIX}",
  "s3_endpoint": "${AWS_S3_ENDPOINT:-null}"
}
EOF

# Step 8: Upload to S3-compatible storage (if configured)
if [ -n "$AWS_S3_BUCKET" ]; then
    echo -e "${GREEN}[8/8] Uploading artifacts to S3...${NC}"
    
    # Check if AWS credentials are configured
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        echo -e "${YELLOW}  ⚠ AWS credentials not set via environment variables${NC}"
        echo "  Checking for IAM role or other credential sources..."
    fi
    
    S3_PATH="s3://${AWS_S3_BUCKET}/${AWS_S3_PREFIX}/${BUILD_ID}"
    
    # Build endpoint argument for S3-compatible providers (Garage, MinIO, etc.)
    ENDPOINT_ARG=""
    if [ -n "$AWS_S3_ENDPOINT" ]; then
        ENDPOINT_ARG="--endpoint-url $AWS_S3_ENDPOINT"
        echo "  Using custom S3 endpoint: $AWS_S3_ENDPOINT"
    fi
    
    echo "  Uploading to: $S3_PATH"
    
    # Upload all files in output directory
    if aws s3 cp "$OUTPUT_DIR" "$S3_PATH" --recursive --region "$AWS_REGION" $ENDPOINT_ARG; then
        echo "  ✓ Artifacts uploaded successfully to S3"
        
        # Generate and display download URLs
        echo ""
        echo -e "${YELLOW}Artifact URLs:${NC}"
        for file in "$OUTPUT_DIR"/*; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                if [ -n "$AWS_S3_ENDPOINT" ]; then
                    # Custom endpoint URL (Garage, MinIO, etc.)
                    echo "  ${AWS_S3_ENDPOINT}/${AWS_S3_BUCKET}/${AWS_S3_PREFIX}/${BUILD_ID}/${filename}"
                else
                    # Standard AWS S3 URL
                    echo "  https://${AWS_S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com/${AWS_S3_PREFIX}/${BUILD_ID}/${filename}"
                fi
            fi
        done
    else
        echo -e "${RED}  ✗ Failed to upload artifacts to S3${NC}"
        echo "  Build artifacts are still available locally in: $OUTPUT_DIR"
    fi
else
    echo -e "${GREEN}[8/8] Skipping S3 upload (AWS_S3_BUCKET not configured)${NC}"
fi

echo ""
echo -e "${GREEN}===========================================${NC}"
echo -e "${GREEN}Build completed successfully!${NC}"
echo -e "${GREEN}===========================================${NC}"
echo ""
echo "Output files are available in: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
