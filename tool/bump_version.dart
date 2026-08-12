// tool/bump_version.dart
//
// ONE-COMMAND version bump for SonicWave.
//
// Usage:
//   dart run tool/bump_version.dart patch      # 1.3.0 -> 1.3.1
//   dart run tool/bump_version.dart minor      # 1.3.0 -> 1.4.0
//   dart run tool/bump_version.dart major      # 1.3.0 -> 2.0.0
//   dart run tool/bump_version.dart build      # 1.3.0+1 -> 1.3.0+2  (build only)
//   dart run tool/bump_version.dart set 2.0.0  # set an exact version
//
// After bumping:
//   - pubspec.yaml version is updated
//   - lib/constants/app_version.dart is regenerated
//   - A summary is printed showing the old -> new version
//
// The CI workflow also runs sync_version.dart on every push, so the Dart
// constant can never go stale in CI even if you forget to run this locally.

import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    _usage();
    exit(1);
  }

  final root = _projectRoot();
  final pubspecFile = File('${root.path}${Platform.pathSeparator}pubspec.yaml');

  if (!pubspecFile.existsSync()) {
    stderr.writeln('[bump_version] ERROR: pubspec.yaml not found');
    exit(1);
  }

  final lines = pubspecFile.readAsLinesSync();
  int versionLineIdx = -1;
  String? rawVersion;

  for (int i = 0; i < lines.length; i++) {
    final match = RegExp(r'^version:\s*(.+)$').firstMatch(lines[i].trim());
    if (match != null) {
      rawVersion = match.group(1)!.trim();
      versionLineIdx = i;
      break;
    }
  }

  if (rawVersion == null || versionLineIdx < 0) {
    stderr.writeln('[bump_version] ERROR: No "version:" field found in pubspec.yaml');
    exit(1);
  }

  // Parse  e.g.  "1.3.0+5"
  final plusIdx = rawVersion.indexOf('+');
  final semver = plusIdx >= 0 ? rawVersion.substring(0, plusIdx) : rawVersion;
  int buildNum = plusIdx >= 0 ? int.tryParse(rawVersion.substring(plusIdx + 1)) ?? 1 : 1;
  final semParts = semver.split('.').map(int.parse).toList();

  int major = semParts[0];
  int minor = semParts.length > 1 ? semParts[1] : 0;
  int patch = semParts.length > 2 ? semParts[2] : 0;

  final oldVersion = rawVersion;

  // ── Apply the requested bump ──────────────────────────────────────────────
  switch (args[0].toLowerCase()) {
    case 'major':
      major++;
      minor = 0;
      patch = 0;
      buildNum++;
    case 'minor':
      minor++;
      patch = 0;
      buildNum++;
    case 'patch':
      patch++;
      buildNum++;
    case 'build':
      buildNum++;
    case 'set':
      if (args.length < 2) {
        stderr.writeln('[bump_version] ERROR: "set" requires a version argument, e.g. "set 2.0.0"');
        exit(1);
      }
      final setRaw = args[1].trim().replaceAll(RegExp(r'^[vV]'), '');
      final setParts = setRaw.split('+');
      final setSem = setParts[0].split('.').map(int.parse).toList();
      major = setSem[0];
      minor = setSem.length > 1 ? setSem[1] : 0;
      patch = setSem.length > 2 ? setSem[2] : 0;
      buildNum = setParts.length > 1 ? int.tryParse(setParts[1]) ?? buildNum + 1 : buildNum + 1;
    default:
      stderr.writeln('[bump_version] ERROR: Unknown command "${args[0]}"');
      _usage();
      exit(1);
  }

  final newSemver = '$major.$minor.$patch';
  final newVersion = '$newSemver+$buildNum';

  // ── Write pubspec.yaml ────────────────────────────────────────────────────
  lines[versionLineIdx] = 'version: $newVersion';
  pubspecFile.writeAsStringSync(lines.join('\n'));

  stdout.writeln('[bump_version] pubspec.yaml  : $oldVersion  ->  $newVersion');

  // ── Regenerate app_version.dart via sync_version ─────────────────────────
  final syncScript = File(
    '${root.path}${Platform.pathSeparator}'
    'tool${Platform.pathSeparator}'
    'sync_version.dart',
  );

  if (syncScript.existsSync()) {
    final result = Process.runSync(
      Platform.resolvedExecutable,
      ['run', syncScript.path],
      workingDirectory: root.path,
    );
    if (result.exitCode != 0) {
      stderr.writeln('[bump_version] sync_version failed:\n${result.stderr}');
      exit(result.exitCode);
    }
    stdout.write(result.stdout);
  } else {
    stderr.writeln('[bump_version] WARNING: tool/sync_version.dart not found — skipping Dart constant sync');
  }

  stdout.writeln('');
  stdout.writeln('Version bumped: $oldVersion  ->  $newVersion');
  stdout.writeln('');
  stdout.writeln('Next steps:');
  stdout.writeln('  git add pubspec.yaml lib/constants/app_version.dart');
  stdout.writeln('  git commit -m "chore: bump version to $newVersion"');
  stdout.writeln('  git tag v$newSemver');
  stdout.writeln('  git push && git push --tags');
}

void _usage() {
  stdout.writeln('Usage: dart run tool/bump_version.dart <command> [args]');
  stdout.writeln('');
  stdout.writeln('Commands:');
  stdout.writeln('  patch        Increment patch version  (1.3.0 -> 1.3.1)');
  stdout.writeln('  minor        Increment minor version  (1.3.0 -> 1.4.0)');
  stdout.writeln('  major        Increment major version  (1.3.0 -> 2.0.0)');
  stdout.writeln('  build        Increment build number only  (1.3.0+1 -> 1.3.0+2)');
  stdout.writeln('  set <ver>    Set an exact version  (e.g. set 2.0.0)');
}

Directory _projectRoot() {
  var dir = File(Platform.script.toFilePath()).parent;
  while (!File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln('[bump_version] ERROR: Could not locate project root');
      exit(1);
    }
    dir = parent;
  }
  return dir;
}
