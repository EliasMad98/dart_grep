import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int MAX_LINE_LENGTH = 10000;

class Options {
  bool ignoreCase = false;
  bool color = false;
  bool hidden = false;
  bool noHeading = false;
  int before = 0;
  int after = 0;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help')) {
    printHelp();
    return;
  }

  final options = Options();
  final positional = <String>[];

  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-i':
      case '--ignore-case':
        options.ignoreCase = true;
        break;
      case '-c':
      case '--color':
        options.color = true;
        break;
      case '-h':
      case '--hidden':
        options.hidden = true;
        break;
      case '--no-heading':
        options.noHeading = true;
        break;
      case '-A':
      case '--after-context':
        options.after = int.parse(args[++i]);
        break;
      case '-B':
      case '--before-context':
        options.before = int.parse(args[++i]);
        break;
      case '-C':
      case '--context':
        final n = int.parse(args[++i]);
        options.before = n;
        options.after = n;
        break;
      default:
        positional.add(args[i]);
    }
  }

  if (positional.length < 2) {
    stderr.writeln('Pattern and path required.');
    exit(1);
  }

  final pattern = positional.first;
  final targets = positional.sublist(1);

  final regex = RegExp(
    pattern,
    caseSensitive: !options.ignoreCase,
    unicode: false, // grep-like \w behavior
  );

  final literalHint = _extractLiteralHint(pattern, options.ignoreCase);

  for (final target in targets) {
    await traverse(target, options, (file) async {
      await searchFile(file, regex, literalHint, options);
    });
  }
}

Future<void> traverse(
  String path,
  Options options,
  Future<void> Function(File) onFile,
) async {
  final type = FileSystemEntity.typeSync(path);

  if (type == FileSystemEntityType.file) {
    await onFile(File(path));
    return;
  }

  if (type != FileSystemEntityType.directory) return;

  final dir = Directory(path);
  await for (final entity in dir.list(followLinks: false)) {
    final name = entity.uri.pathSegments.last;
    if (!options.hidden && name.startsWith('.')) continue;

    final t = FileSystemEntity.typeSync(entity.path);
    if (t == FileSystemEntityType.directory) {
      await traverse(entity.path, options, onFile);
    } else if (t == FileSystemEntityType.file) {
      await onFile(File(entity.path));
    }
  }
}

Future<void> searchFile(
  File file,
  RegExp regex,
  String? literalHint,
  Options options,
) async {
  if (await isBinary(file)) return;

  final lines = <String>[];
  final matches = <int>[];

  try {
    final stream = file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    int lineNo = 0;
    await for (final line in stream) {
      lineNo++;
      lines.add(line);

      if (line.length > MAX_LINE_LENGTH) continue;

      if (literalHint != null) {
        final hay = options.ignoreCase ? line.toLowerCase() : line;
        if (!hay.contains(literalHint)) continue;
      }

      if (regex.hasMatch(line)) {
        matches.add(lineNo - 1); // zero-based
      }
    }
  } catch (_) {
    return;
  }

  if (matches.isEmpty) return;

  // merge context ranges (grep-correct)
  final ranges = <List<int>>[];
  for (final m in matches) {
    final start = (m - options.before).clamp(0, lines.length - 1);
    final end = (m + options.after).clamp(0, lines.length - 1);

    if (ranges.isEmpty || start > ranges.last[1] + 1) {
      ranges.add([start, end]);
    } else {
      ranges.last[1] = ranges.last[1] > end ? ranges.last[1] : end;
    }
  }

  bool headerPrinted = false;

  for (final range in ranges) {
    for (int i = range[0]; i <= range[1]; i++) {
      final isMatch = matches.contains(i);
      final sep = isMatch ? ':' : '-';

      if (!options.noHeading && !headerPrinted) {
        safeWrite('${file.path}\n');
        headerPrinted = true;
      }

      final content = isMatch
          ? highlight(lines[i], regex, options)
          : lines[i];

      safeWrite('${file.path}$sep${i + 1}:$content\n');
    }
  }
}

void safeWrite(String s) {
  try {
    stdout.write(s);
  } on FileSystemException catch (e) {
    if (e.osError?.errorCode == 32) exit(0); // broken pipe
    rethrow;
  }
}

String highlight(String line, RegExp regex, Options options) {
  if (!options.color) return line;
  return line.replaceAllMapped(
    regex,
    (m) => '\x1b[31m${m.group(0)}\x1b[0m',
  );
}

Future<bool> isBinary(File file) async {
  try {
    final raf = await file.open();
    final bytes = await raf.read(8000);
    await raf.close();
    return bytes.contains(0);
  } catch (_) {
    return true;
  }
}

String? _extractLiteralHint(String pattern, bool ignoreCase) {
  final matches =
      RegExp(r'[A-Za-z0-9_]{3,}').allMatches(pattern).map((m) => m.group(0)!);
  String? best;
  for (final m in matches) {
    if (best == null || m.length > best.length) best = m;
  }
  if (best == null) return null;
  return ignoreCase ? best.toLowerCase() : best;
}

void printHelp() {
  print('''
usage: searcher [OPTIONS] PATTERN [PATH ...]

-A, --after-context <n>    lines after match
-B, --before-context <n>   lines before match
-C, --context <n>          lines before and after
-c, --color                highlight matches
-h, --hidden               search hidden files
-i, --ignore-case          case insensitive
--no-heading               print filename on each line
--help                     show this help
''');
}
