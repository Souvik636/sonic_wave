# SonicWave

A modern, beautiful music streaming app built with Flutter.

## Getting Started

```bash
flutter pub get
flutter run
```

---

## Versioning — Single Source of Truth

**Only edit the version in `pubspec.yaml`.** Everything else is auto-generated.

| File | Role |
|------|------|
| `pubspec.yaml` | **Source of truth** — edit this only |
| `lib/constants/app_version.dart` | Auto-generated — do not edit |
| `android/app/build.gradle.kts` | Reads from Flutter automatically |

### Bump the version (one command)

```bash
dart run tool/bump_version.dart patch      # 1.3.0 -> 1.3.1
dart run tool/bump_version.dart minor      # 1.3.0 -> 1.4.0
dart run tool/bump_version.dart major      # 1.3.0 -> 2.0.0
dart run tool/bump_version.dart build      # increment build number only
dart run tool/bump_version.dart set 2.0.0  # set an exact version
```

This updates `pubspec.yaml` and regenerates `app_version.dart` in one step.

### Install the git pre-commit hook (once per clone)

```bash
git config core.hooksPath .githooks
```

After this, every `git commit` automatically syncs `app_version.dart`
from `pubspec.yaml` — you never have to remember manually.

### CI

The CI workflow runs `dart run tool/sync_version.dart` and fails if
`app_version.dart` was not kept in sync before pushing.
