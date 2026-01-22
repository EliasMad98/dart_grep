import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Options {
  bool ignoreCase = false;
  bool hidden = false;
  bool noHeading = true;  // Default to no-heading (like grep)
  bool color = false;
  int beforeContext = 0;
  int afterContext = 0;
}

class LineEntry {
  final int number;
  final String text;
  final bool isMatch;
  
  LineEntry(this.number, this.text, this.isMatch);
}

class FileMatch {
  final String path;
  final List<LineEntry> lines = [];
  
  FileMatch(this.path);
}

void printHelp() {
  print('''
usage: searcher [OPTIONS] PATTERN [PATH ...]

  -A,--after-context <arg>   prints the given number of following lines
                              for each match
  -B,--before-context <arg>  prints the given number of preceding lines
                              for each match
  -c,--color                  print with colors, highlighting the matched
                              phrase in the output
  -C,--context <arg>          prints the number of preceding and following
                              lines for each match. this is equivalent to
                              setting --before-context and --after-context
  -h,--hidden                 search hidden files and folders
      --help                  print this message
  -i,--ignore-case            search case insensitive
      --no-heading            prints a single line including the filename
                              for each match, instead of grouping matches
                              by file''');
}

Future<void> main(List<String> args) async {
  final options = Options();
  final positional = <String>[];

  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    
    if (arg == '--help') {
      printHelp();
      exit(0);
    }
    
    switch (arg) {
      case '-i':
      case '--ignore-case':
        options.ignoreCase = true;
        break;
      case '-h':
      case '--hidden':
        options.hidden = true;
        break;
      case '--no-heading':
        options.noHeading = true;
        break;
      case '--heading':
        options.noHeading = false;  // Enable heading mode
        break;
      case '-c':
      case '--color':
        options.color = true;
        break;
      case '-A':
      case '--after-context':
        if (i + 1 >= args.length) {
          stderr.writeln('Error: $arg requires an argument');
          exit(1);
        }
        options.afterContext = int.parse(args[++i]);
        break;
      case '-B':
      case '--before-context':
        if (i + 1 >= args.length) {
          stderr.writeln('Error: $arg requires an argument');
          exit(1);
        }
        options.beforeContext = int.parse(args[++i]);
        break;
      case '-C':
      case '--context':
        if (i + 1 >= args.length) {
          stderr.writeln('Error: $arg requires an argument');
          exit(1);
        }
        final n = int.parse(args[++i]);
        options.beforeContext = n;
        options.afterContext = n;
        break;
      default:
        if (arg.startsWith('-')) {
          stderr.writeln('Unknown option: $arg');
          exit(1);
        }
        positional.add(arg);
    }
  }

  if (positional.isEmpty) {
    printHelp();
    exit(1);
  }

  if (positional.length < 2) {
    stderr.writeln('usage: searcher [OPTIONS] PATTERN [PATH ...]');
    exit(1);
  }

  var pattern = positional.first;
  final paths = positional.sublist(1);

  // Dart's \w only matches ASCII, but grep's \w matches Unicode word characters
  // We need to expand \w to include Unicode letters and numbers
  // Use Unicode property escapes: \p{L} (letters), \p{N} (numbers), plus underscore
  pattern = pattern.replaceAllMapped(RegExp(r'\\w'), (match) => r'[\p{L}\p{N}_]');
  pattern = pattern.replaceAllMapped(RegExp(r'\\W'), (match) => r'[^\p{L}\p{N}_]');
  
  final regex = RegExp(
    pattern,
    caseSensitive: !options.ignoreCase,
    unicode: true,
  );

  final allMatches = <FileMatch>[];

  for (final p in paths) {
    await walk(p, options, (file) async {
      final match = await searchFile(file, regex, options);
      if (match != null && match.lines.isNotEmpty) {
        allMatches.add(match);
      }
    });
  }

  // Print results
  if (options.noHeading) {
    printNoHeading(allMatches, regex, options);
  } else {
    printWithHeading(allMatches, regex, options);
  }
}

Future<void> walk(
  String path,
  Options options,
  Future<void> Function(File) onFile,
) async {
  final type = FileSystemEntity.typeSync(path, followLinks: false);

  if (type == FileSystemEntityType.file) {
    await onFile(File(path));
    return;
  }

  if (type != FileSystemEntityType.directory) return;

  final dir = Directory(path);
  
  try {
    await for (final entity in dir.list(followLinks: false)) {
      // Get the basename of the file/directory
      final name = entity.uri.pathSegments.lastWhere(
        (segment) => segment.isNotEmpty,
        orElse: () => '',
      );

      if (entity is File) {
        // Skip hidden FILES (not directories) unless --hidden is set
        if (!options.hidden && name.startsWith('.')) {
          continue;
        }
        await onFile(entity);
      } else if (entity is Directory) {
        // Always recurse into directories, even hidden ones
        // (grep's --exclude only applies to files, not directories)
        await walk(entity.path, options, onFile);
      }
    }
  } catch (e) {
    // Skip directories we can't read
  }
}

Future<FileMatch?> searchFile(
  File file,
  RegExp regex,
  Options options,
) async {
  if (await isBinary(file)) return null;

  final beforeBuffer = <LineEntry>[];
  int afterRemaining = 0;
  int lineNo = 0;
  // Normalize path to use forward slashes like grep
  final normalizedPath = file.path.replaceAll(r'\', '/');
  final result = FileMatch(normalizedPath);
  final addedLines = <int>{};

  try {
    final stream = file
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());

    await for (final line in stream) {
      lineNo++;
      final isMatch = regex.hasMatch(line);

      if (isMatch) {
        // Add before context
        for (final ctx in beforeBuffer) {
          if (!addedLines.contains(ctx.number)) {
            result.lines.add(ctx);
            addedLines.add(ctx.number);
          }
        }
        beforeBuffer.clear();

        // Add match
        if (!addedLines.contains(lineNo)) {
          result.lines.add(LineEntry(lineNo, line, true));
          addedLines.add(lineNo);
        }
        
        afterRemaining = options.afterContext;
        continue;
      }

      if (afterRemaining > 0) {
        if (!addedLines.contains(lineNo)) {
          result.lines.add(LineEntry(lineNo, line, false));
          addedLines.add(lineNo);
        }
        afterRemaining--;
        continue;
      }

      if (options.beforeContext > 0) {
        beforeBuffer.add(LineEntry(lineNo, line, false));
        if (beforeBuffer.length > options.beforeContext) {
          beforeBuffer.removeAt(0);
        }
      }
    }
  } catch (e) {
    return null;
  }

  return result.lines.isEmpty ? null : result;
}

void printNoHeading(List<FileMatch> matches, RegExp regex, Options options) {
  final hasContext = options.beforeContext > 0 || options.afterContext > 0;
  String? lastFile;
  int? lastPrintedLine;
  
  for (final fileMatch in matches) {
    for (int i = 0; i < fileMatch.lines.length; i++) {
      final entry = fileMatch.lines[i];
      
      // Print separator when:
      // 1. We're using context AND
      // 2. Either switching files OR there's a gap in line numbers
      if (hasContext) {
        final switchedFile = lastFile != null && lastFile != fileMatch.path;
        final hasGap = lastPrintedLine != null && 
                       entry.number > lastPrintedLine + 1 &&
                       !switchedFile; // Don't print -- when switching files
        
        if ((switchedFile || hasGap) && lastFile != null) {
          stdout.writeln('--');
        }
      }
      
      final sep = entry.isMatch ? ':' : '-';
      final line = options.color && entry.isMatch 
          ? highlightMatch(entry.text, regex)
          : entry.text;
      
      stdout.writeln('${fileMatch.path}$sep${entry.number}$sep$line');
      lastFile = fileMatch.path;
      lastPrintedLine = entry.number;
    }
  }
}

void printWithHeading(List<FileMatch> matches, RegExp regex, Options options) {
  final hasContext = options.beforeContext > 0 || options.afterContext > 0;
  bool firstFile = true;
  
  for (final fileMatch in matches) {
    // Print separator between files (blank line or --)
    if (!firstFile) {
      if (hasContext) {
        stdout.writeln('--');
      } else {
        stdout.writeln();
      }
    }
    firstFile = false;
    
    stdout.writeln(fileMatch.path);
    
    int? lastPrintedLine;
    
    for (int i = 0; i < fileMatch.lines.length; i++) {
      final entry = fileMatch.lines[i];
      
      // Print separator only if using context and there's a gap within the same file
      if (hasContext && lastPrintedLine != null && entry.number > lastPrintedLine + 1) {
        stdout.writeln('--');
      }
      
      final sep = entry.isMatch ? ':' : '-';
      final line = options.color && entry.isMatch 
          ? highlightMatch(entry.text, regex)
          : entry.text;
      
      stdout.writeln('${entry.number}$sep$line');
      lastPrintedLine = entry.number;
    }
  }
}

String highlightMatch(String text, RegExp regex) {
  const red = '\x1b[0;31m';
  const reset = '\x1b[0m';
  
  return text.replaceAllMapped(regex, (match) {
    return '$red${match.group(0)}$reset';
  });
}

Future<bool> isBinary(File file) async {
  try {
    final raf = await file.open();
    // Read first 8KB to check for binary content
    final bytes = await raf.read(8192);
    await raf.close();
    
    if (bytes.isEmpty) return false;
    
    // Check for null bytes - primary binary indicator
    // A single null byte usually means binary file
    if (bytes.contains(0)) {
      return true;
    }
    
    return false;
  } catch (_) {
    return true;
  }
}

/*
elias@DESKTOP-2GP6ACT:~/seminar$ dart compile exe searcher.dart -o searcher
Generated: /home/elias/seminar/searcher
elias@DESKTOP-2GP6ACT:~/seminar$ python3.10 test.py -d test_data ./searcher
literal_linux...[OK]
literal_linux_hidden...[OK]
linux_literal_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -E -r PM_RESUME linux_literal_ignore_case...[OK]
linux_pattern_prefix...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r [A-Z]+_RESUME testlinux_pattern_prefix...[OK]
linux_pattern_prefix_with_context...running grep -C 3 --exclude=.* --line-number --with-filename -I --color=never -E -r linux_pattern_prefix_with_context...[OK]
linux_pattern_prefix_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -E -r [A-linux_pattern_prefix_ignore_case...[OK]
linux_pattern_suffix...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r PM_[A-Z]+ test_datlinux_pattern_suffix...[OK]
linux_pattern_suffix_with_context...running grep -B 2 -A 4 --exclude=.* --line-number --with-filename -I --color=never -linux_pattern_suffix_with_context...[OK]
linux_pattern_suffix_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -E -r PM_linux_pattern_suffix_ignore_case...[OK]
linux_word...[OK]
linux_word_with_heading...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r \wAh test_data/linux_word_with_heading...[OK]
linux_word_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -E -r \wAh test_datlinux_word_ignore_case...[OK]
linux_no_literal...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r \w{5}\s+\w{5}\s+\w{5}\linux_no_literal...[OK]
linux_no_literal_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -E -r \w{5}\slinux_no_literal_ignore_case...[OK]
linux_alternatives...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r ERR_SYS|PME_TURN_OFFlinux_alternatives...[OK]
linux_alternatives_with_heading...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r ERR_SYSlinux_alternatives_with_heading...[OK]
linux_alternatives_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -E -r ERR_Slinux_alternatives_ignore_case...running ./searcher -i --no-heading ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT test_dlinux_alternatives_ignore_case...[OK]
subtitles_literal...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r Sherlock Holmes test_subtitles_literal...[OK]
subtitles_literal_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -E -r Sherlosubtitles_literal_ignore_case...[OK]
subtitles_alternatives...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r Sherlock Holmes|subtitles_alternatives...running ./searcher --no-heading Sherlock Holmes|John Watson|Irene Adler|Inspector Lestrade|Profsubtitles_alternatives...[OK]
subtitles_alternatives_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -E -r Ssubtitles_alternatives_ignore_case...running ./searcher -i --no-heading Sherlock Holmes|John Watson|Irene Adler|Inspectosubtitles_alternatives_ignore_case...[OK]
subtitles_surrounding_words...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r \w+\s+Holmesubtitles_surrounding_words...[OK]
subtitles_surrounding_words_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -Esubtitles_surrounding_words_ignore_case...[OK]
subtitles_no_literal...running grep --exclude=.* --line-number --with-filename -I --color=never -E -r \w{5}\s+\w{5}\s+\wsubtitles_no_literal...running ./searcher --no-heading \w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5} test_data/subtitles.txt
subtitles_no_literal...[OK]
subtitles_no_literal_ignore_case...running grep -i --exclude=.* --line-number --with-filename -I --color=never -E -r \w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5} test_data/subtitles.txt

subtitles_no_literal_ignore_case...running ./searcher -i --no-heading \w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\wsubtitles_no_literal_ignore_case...[OK]
test result: OK. 25 passed; 0 failed; 0 skipped
 */