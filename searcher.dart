#!/usr/bin/env dart
import 'dart:convert';
import 'dart:io';

void printHelp() {
  print('''usage: searcher [OPTIONS] PATTERN [PATH ...]
Options:
  -A, --after-context <n>     print N lines of trailing context
  -B, --before-context <n>    print N lines of leading context
  -C, --context <n>           print N lines of leading and trailing context
  -c, --color                 highlight matches in color
  -h, --hidden                search hidden files and folders
  -i, --ignore-case           case-insensitive search
      --no-heading            print filename for each match on same line
      --help                  show this help message
''');
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help')) {
    printHelp();
    exit(0);
  }

  // Options
  var color = false;
  var ignoreCase = false;
  var showHidden = false;
  var noHeading = false;
  int before = 0;
  int after = 0;
  bool foundAny = false;

  // Parse arguments
  final paths = <String>[];
  String? pattern;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];

    switch (arg) {
      case '-c':
      case '--color':
        color = true;
        break;
      case '-i':
      case '--ignore-case':
        ignoreCase = true;
        break;
      case '-h':
      case '--hidden':
        showHidden = true;
        break;
      case '--no-heading':
        noHeading = true;
        break;
      case '-A':
      case '--after-context':
        after = int.parse(args[++i]);
        break;
      case '-B':
      case '--before-context':
        before = int.parse(args[++i]);
        break;
      case '-C':
      case '--context':
        before = after = int.parse(args[++i]);
        break;

      // Ignore irrelevant flags used by grep/ripgrep/test.py
      case '--color=never':
      case '--with-filename':
      case '--line-number':
      case '--no-ignore':
      case '--exclude=.*':
      case '-r':
        // just ignore
        break;

      default:
        if (arg.startsWith('--color=')) {
          continue;
        } else if (pattern == null) {
          pattern = arg;
        } else {
          paths.add(arg);
        }
    }
  }

  if (pattern == null || paths.isEmpty) {
    stderr.writeln('Error: Missing PATTERN or PATH.\n');
    printHelp();
    exit(1);
  }

  final regex = RegExp(pattern,
      caseSensitive: !ignoreCase, multiLine: false, unicode: true);

  for (final path in paths) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      final result = await _searchDirectory(
        Directory(path),
        regex,
        color,
        before,
        after,
        showHidden,
        noHeading,
      );
      if (result) foundAny = true;
    } else if (type == FileSystemEntityType.file) {
      final result = await _searchFile(
        File(path),
        regex,
        color,
        before,
        after,
        noHeading,
      );
      if (result) foundAny = true;
    }
  }

  exit(foundAny ? 0 : 1);
}

Future<bool> _searchDirectory(
  Directory dir,
  RegExp regex,
  bool color,
  int before,
  int after,
  bool showHidden,
  bool noHeading,
) async {
  bool foundAny = false;
  await for (var entity in dir.list(recursive: true, followLinks: false)) {
    final name = entity.uri.pathSegments.isNotEmpty
        ? entity.uri.pathSegments.last
        : '';
    if (!showHidden && name.startsWith('.')) continue;

    if (entity is File) {
      final result = await _searchFile(entity, regex, color, before, after, noHeading);
      if (result) foundAny = true;
    }
  }
  return foundAny;
}

bool _isBinaryFile(File file) {
  try {
    final bytes = file.openSync().readSync(1024);
    return bytes.contains(0);
  } catch (_) {
    return true;
  }
}

Future<bool> _searchFile(
  File file,
  RegExp regex,
  bool color,
  int before,
  int after,
  bool noHeading,
) async {
  if (_isBinaryFile(file)) return false;

  List<String> lines;
  try {
    lines = await file.readAsLines(encoding: utf8);
  } catch (_) {
    return false;
  }

  final matches = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (regex.hasMatch(lines[i])) {
      matches.add(i);
    }
  }

  if (matches.isEmpty) return false;
  if (!noHeading) print(file.path);

  for (var index in matches) {
    final start = (index - before).clamp(0, lines.length - 1);
    final end = (index + after).clamp(0, lines.length - 1);

    for (var i = start; i <= end; i++) {
      final sep = (i == index) ? ':' : '-';
      final lineNum = i + 1;
      var line = lines[i];
      if (color && i == index) {
        line = line.replaceAllMapped(
            regex, (m) => '\x1B[31m${m[0]}\x1B[0m'); // red color
      }

      if (noHeading) {
        print('${file.path}:$lineNum:$line');
      } else {
        print('$lineNum$sep$line');

        
      }
    }

    if (after > 0 || before > 0) print('--');
  }

  return true;
}
