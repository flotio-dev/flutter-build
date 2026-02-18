# Flutter Build Docker Image

Single Docker image for building Flutter applications across Android, Linux Desktop, and Web, with S3-compatible storage upload support.

## 🚀 Quick Start

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/flutter-app.git" \
  -e PLATFORM="android" \
  -e BUILD_ID="build-001" \
  -v $(pwd)/outputs:/outputs \
  ghcr.io/flotio-dev/flutter-build:latest
```

## 📋 Environment Variables

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `GIT_REPO` | Git repository URL | `https://github.com/user/app.git` |
| `PLATFORM` | Target platform: `android`, `linux`, `web` | `android` |
| `BUILD_ID` | Unique build identifier | `build-123` |

### Git Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GIT_BRANCH` | `main` | Branch to clone |
| `GIT_USERNAME` | - | Git username (for private repos) |
| `GIT_PASSWORD` | - | Git password/token (for private repos) |

### Build Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_FOLDER` | `.` (root) | Subfolder containing Flutter project |
| `BUILD_MODE` | `release` | Build mode: `debug`, `profile`, `release` |
| `BUILD_TARGET` | `apk` | Android target: `apk`, `appbundle` (or `aab`) |
| `ANDROID_SKIP_BUILD_DEPENDENCY_VALIDATION` | `true` | Add Flutter flag `--android-skip-build-dependency-validation` for Android builds |
| `ANDROID_AUTO_FIX_MIN_SDK` | `true` | Automatically bump Android `minSdk` to 23 when lower in `android/app/build.gradle(.kts)` |
| `FLUTTER_CHANNEL` | `stable` | Flutter channel: `stable`, `beta`, `master` |
| `OUTPUT_DIR` | `/outputs` | Output directory for artifacts |

### Android Signing (Optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `KEYSTORE_PATH` | - | Path to keystore file (mount as volume) |
| `KEYSTORE_PASSWORD` | `android` | Keystore password |
| `KEY_PASSWORD` | `android` | Key password |
| `KEY_ALIAS` | `key` | Key alias |

### S3 Upload (Optional - Garage/MinIO/AWS S3)

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_S3_BUCKET` | - | S3 bucket name (enables upload when set) |
| `AWS_S3_PREFIX` | `builds` | Folder prefix in bucket |
| `AWS_S3_ENDPOINT` | - | Custom S3 endpoint URL (for Garage/MinIO) |
| `AWS_REGION` | `garage` | AWS region (can be any value for Garage) |
| `AWS_ACCESS_KEY_ID` | - | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | - | S3 secret key |

### Environment Files

| Variable | Default | Description |
|----------|---------|-------------|
| `ENV_FILES_DIR` | `/env-files` | Directory with environment files to inject |

## 📦 Examples

### Build Android APK

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/flutter-app.git" \
  -e PLATFORM="android" \
  -e BUILD_ID="$(date +%s)" \
  -e BUILD_MODE="release" \
  -v $(pwd)/outputs:/outputs \
  ghcr.io/flotio-dev/flutter-build:latest
```

### Build Android App Bundle (AAB)

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/flutter-app.git" \
  -e PLATFORM="android" \
  -e BUILD_TARGET="appbundle" \
  -e BUILD_ID="$(date +%s)" \
  -v $(pwd)/outputs:/outputs \
  ghcr.io/flotio-dev/flutter-build:latest
```

### Build from Private Repository

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/private-app.git" \
  -e GIT_USERNAME="your-username" \
  -e GIT_PASSWORD="your-github-token" \
  -e GIT_BRANCH="develop" \
  -e PLATFORM="android" \
  -e BUILD_ID="$(date +%s)" \
  -v $(pwd)/outputs:/outputs \
  ghcr.io/flotio-dev/flutter-build:latest
```

### Build with Android Signing

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/flutter-app.git" \
  -e PLATFORM="android" \
  -e BUILD_ID="$(date +%s)" \
  -e KEYSTORE_PATH="/keystore/release.jks" \
  -e KEYSTORE_PASSWORD="your-keystore-password" \
  -e KEY_PASSWORD="your-key-password" \
  -e KEY_ALIAS="release" \
  -v $(pwd)/outputs:/outputs \
  -v $(pwd)/keystore:/keystore:ro \
  ghcr.io/flotio-dev/flutter-build:latest
```

### Build with S3 Upload (Garage)

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/flutter-app.git" \
  -e PLATFORM="android" \
  -e BUILD_ID="$(date +%s)" \
  -e AWS_S3_BUCKET="flutter-builds" \
  -e AWS_S3_PREFIX="releases" \
  -e AWS_S3_ENDPOINT="https://s3.garage.example.com" \
  -e AWS_ACCESS_KEY_ID="GKxxxxxxxxxxxxxxxx" \
  -e AWS_SECRET_ACCESS_KEY="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
  -v $(pwd)/outputs:/outputs \
  ghcr.io/flotio-dev/flutter-build:latest
```

### Build with S3 Upload (AWS S3)

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/flutter-app.git" \
  -e PLATFORM="android" \
  -e BUILD_ID="$(date +%s)" \
  -e AWS_S3_BUCKET="my-flutter-builds" \
  -e AWS_S3_PREFIX="releases" \
  -e AWS_REGION="eu-west-1" \
  -e AWS_ACCESS_KEY_ID="AKIA..." \
  -e AWS_SECRET_ACCESS_KEY="..." \
  -v $(pwd)/outputs:/outputs \
  ghcr.io/flotio-dev/flutter-build:latest
```

### Build Web Application

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/flutter-app.git" \
  -e PLATFORM="web" \
  -e BUILD_ID="$(date +%s)" \
  -v $(pwd)/outputs:/outputs \
  ghcr.io/flotio-dev/flutter-build:latest
```

### Build Linux Desktop Application

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/flutter-app.git" \
  -e PLATFORM="linux" \
  -e BUILD_ID="$(date +%s)" \
  -v $(pwd)/outputs:/outputs \
  ghcr.io/flotio-dev/flutter-build:latest
```

### Build from Subfolder (Monorepo)

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/monorepo.git" \
  -e BUILD_FOLDER="apps/mobile" \
  -e PLATFORM="android" \
  -e BUILD_ID="$(date +%s)" \
  -v $(pwd)/outputs:/outputs \
  ghcr.io/flotio-dev/flutter-build:latest
```

### Inject Environment Files

Mount a directory with files to copy into the project:

```bash
docker run --rm \
  -e GIT_REPO="https://github.com/user/flutter-app.git" \
  -e PLATFORM="android" \
  -e BUILD_ID="$(date +%s)" \
  -v $(pwd)/outputs:/outputs \
  -v $(pwd)/env-files:/env-files:ro \
  ghcr.io/flotio-dev/flutter-build:latest
```

File naming convention for custom paths:
- `firebase.json` → copied to project root
- `lib__config.dart::lib__config.dart` → copied to `lib/config.dart`

## 🏗️ Building the Image

### Build locally

```bash
docker build -f flutter-build.Dockerfile -t flutter-build:local .
```

### Build for multiple architectures

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -f flutter-build.Dockerfile \
  -t ghcr.io/flotio-dev/flutter-build:latest \
  --push .
```

## 📁 Output Structure

After a successful build:

```
/outputs/
├── app-{BUILD_ID}.apk          # Android APK (or .aab for appbundle)
├── linux-build-{BUILD_ID}.tar.gz # Linux desktop build (compressed)
├── web-build-{BUILD_ID}.tar.gz # Web build (compressed)
└── build-info.json             # Build metadata
```

### build-info.json

```json
{
  "build_id": "build-123",
  "platform": "android",
  "build_mode": "release",
  "build_target": "apk",
  "flutter_channel": "stable",
  "git_repo": "https://github.com/user/app.git",
  "git_branch": "main",
  "build_folder": "",
  "timestamp": "2025-12-04T10:30:00Z",
  "flutter_version": "Flutter 3.35.7",
  "s3_bucket": "flutter-builds",
  "s3_prefix": "releases",
  "s3_endpoint": "https://s3.garage.example.com"
}
```

## 🔧 Troubleshooting

### Build fails with Dart version mismatch

The image automatically detects required Dart version from `pubspec.yaml` and attempts to switch Flutter versions. If this fails:

1. Check your `pubspec.yaml` SDK constraints
2. Consider using a specific Flutter version image tag
3. Use FVM in your project for version management

### iOS builds

iOS builds are not supported in this Linux container image.
iOS requires a macOS runner with Xcode installed.

### Warning about Kotlin version on Android builds

If you see warnings about Kotlin version support (for example KGP 1.8.x), the image now enables
`--android-skip-build-dependency-validation` by default for Android builds.

To enforce strict validation, set:

```bash
-e ANDROID_SKIP_BUILD_DEPENDENCY_VALIDATION="false"
```

### Error `DebugMinSdkCheck` (minSdk lower than 23)

The image now auto-fixes `minSdk` to `23` when it detects a lower numeric value
in `android/app/build.gradle` or `android/app/build.gradle.kts`.

To disable this behavior, set:

```bash
-e ANDROID_AUTO_FIX_MIN_SDK="false"
```

### Memory issues during build

Increase Docker memory limit:

```bash
docker run --rm -m 8g \
  -e GIT_REPO="..." \
  ...
```

### S3 upload fails

1. Verify credentials are correct
2. Check endpoint URL format (include `https://`)
3. Ensure bucket exists and is accessible
4. Check network connectivity from container

## 📄 License

MIT
