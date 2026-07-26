# CI/CD — SonicWave

This project ships with two GitHub Actions workflows:

| Workflow | File | Trigger | What it does |
|----------|------|---------|--------------|
| **CI** | `.github/workflows/ci.yml` | push / PR to `main`, `master`, `develop` | `dart format` check, `flutter analyze`, `flutter test` (with coverage), debug APK build |
| **Release** | `.github/workflows/release.yml` | push of a `v*` tag (or manual dispatch) | Builds a **signed** AAB + split APKs and publishes a GitHub Release |

Both use **Flutter stable** and **Java 17** (matching the Gradle 8.14 / Java 17 Android config).

---

## 1. Continuous Integration

Runs automatically. No configuration required. Notes:

- `dart format --set-exit-if-changed` fails the build on unformatted code. Run `dart format .` locally before pushing, or remove that step if you don't want enforced formatting.
- `flutter analyze --fatal-infos` treats info-level lints as failures. Drop `--fatal-infos` to only fail on warnings/errors.
- Coverage (`coverage/lcov.info`) is uploaded as a build artifact.

## 2. Release — one-time setup

The release build signs the app with a real upload keystore injected from
repository secrets. Local behavior is unchanged: without `android/key.properties`
the release build falls back to debug signing (see `android/app/build.gradle.kts`).

### a. Create an upload keystore (once)

```bash
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Keep `upload-keystore.jks` safe and **out of git** (already git-ignored). Losing it
means you can no longer update the app on the Play Store under the same signing key.

### b. Add repository secrets

In GitHub: **Settings → Secrets and variables → Actions → New repository secret**.

| Secret | Value |
|--------|-------|
| `ANDROID_KEYSTORE_BASE64` | Base64 of the `.jks` file (see below) |
| `ANDROID_KEYSTORE_PASSWORD` | The store password you set with `keytool` |
| `ANDROID_KEY_ALIAS` | `upload` (or your chosen alias) |
| `ANDROID_KEY_PASSWORD` | The key password you set with `keytool` |

Encode the keystore:

```bash
# Linux
base64 -w0 upload-keystore.jks > keystore.b64
# macOS
base64 -i upload-keystore.jks | tr -d '\n' > keystore.b64
```

Paste the contents of `keystore.b64` as `ANDROID_KEYSTORE_BASE64`.

### c. Cut a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow will:

1. Decode the keystore and write a temporary `android/key.properties`.
2. Build `app-release.aab` and per-ABI release APKs, versioned from the tag
   (`v1.0.0` → version name `1.0.0`, version code = workflow run number).
3. Delete the keystore/`key.properties` from the runner.
4. Create a GitHub Release named **SonicWave 1.0.0** with the AAB + APKs attached
   and auto-generated release notes.

You can also run it manually from the **Actions** tab (**Release → Run workflow**);
a manual run builds and uploads artifacts but does not create a GitHub Release.

---

## Local signed build (optional)

To reproduce a signed release build locally, place your keystore at
`android/app/upload-keystore.jks` and create `android/key.properties`:

```properties
storeFile=upload-keystore.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=upload
keyPassword=YOUR_KEY_PASSWORD
```

Then:

```bash
flutter build appbundle --release
flutter build apk --release --split-per-abi
```

Both `key.properties` and `*.jks` are git-ignored.

---

## Pinning the Flutter version (optional)

Both workflows track the `stable` channel. To lock an exact version for
reproducibility, set `flutter-version` on the `subosito/flutter-action@v2` step,
e.g. `flutter-version: 3.38.0` (must ship Dart ≥ 3.11 to satisfy `pubspec.yaml`).
