import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';

import 'net.dart';

/// Fetches an external subtitle and cleans it before playback:
///   * parses SRT or WebVTT (both HH:MM:SS and MM:SS timestamp forms),
///   * clamps each line's end to the next line's start, so a new line
///     always replaces the previous one instead of stacking,
///   * hands back a plain SRT string to load via SubtitleTrack.data().
///
/// Every external subtitle goes through here, so subtitles look and
/// behave identically on every platform. If anything fails, the caller
/// falls back to loading the URL directly - worst case is prior behaviour.
class SubPrep {
  static final RegExp _time = RegExp(
      r'(\d{1,2}:\d{2}(?::\d{2})?)[.,](\d{1,3})\s*-->\s*'
      r'(\d{1,2}:\d{2}(?::\d{2})?)[.,](\d{1,3})');

  static int? _ms(String clock, String milli) {
    final p = clock.split(':').map(int.tryParse).toList();
    int h, m, s;
    if (p.length == 3) {
      if (p.any((e) => e == null)) return null;
      h = p[0]!;
      m = p[1]!;
      s = p[2]!;
    } else if (p.length == 2) {
      if (p.any((e) => e == null)) return null;
      h = 0;
      m = p[0]!;
      s = p[1]!;
    } else {
      return null;
    }
    final frac = (milli + '000').substring(0, 3);
    return ((h * 3600 + m * 60 + s) * 1000) + int.parse(frac);
  }

  /// Returns cleaned SRT text, or null if it couldn't be prepared.
  static Future<String?> prepare(String url,
      {Map<String, String> headers = const {}, bool isLocal = false}) async {
    try {
      String content;
      if (isLocal) {
        content = await File(url.replaceFirst('file:///', '')).readAsString();
      } else {
        final res = await http
            .get(Uri.parse(url), headers: Net.withUa(headers))
            .timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) return null;
        content = utf8.decode(res.bodyBytes, allowMalformed: true);
      }
      final cues = _parse(content);
      if (cues.isEmpty) return null;
      _clamp(cues);
      return _toSrt(cues);
    } catch (_) {
      return null;
    }
  }

  static List<List<Object>> _parse(String raw) {
    var content = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (content.toUpperCase().startsWith('WEBVTT')) {
      final nl = content.indexOf('\n\n');
      content = nl >= 0 ? content.substring(nl + 2) : content;
    }
    final cues = <List<Object>>[];
    for (final block in content.split(RegExp(r'\n\s*\n'))) {
      final lines =
          block.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) continue;
      var ti = 0;
      if (!lines[0].contains('-->') &&
          lines.length > 1 &&
          lines[1].contains('-->')) {
        ti = 1;
      }
      if (ti >= lines.length) continue;
      final m = _time.firstMatch(lines[ti]);
      if (m == null) continue;
      final a = _ms(m.group(1)!, m.group(2)!);
      final b = _ms(m.group(3)!, m.group(4)!);
      if (a == null || b == null || b <= a) continue;
      final text = lines.sublist(ti + 1).join('\n').trim();
      if (text.isEmpty) continue;
      cues.add([a, b, text]);
    }
    return cues;
  }

  /// Shorten a line so it ends when the next one starts (staggered speech);
  /// never touch two lines that start together (a sign plus dialogue) and
  /// never create a zero-length line.
  static void _clamp(List<List<Object>> cues) {
    cues.sort((x, y) {
      final c = (x[0] as int).compareTo(y[0] as int);
      return c != 0 ? c : (x[1] as int).compareTo(y[1] as int);
    });
    for (var i = 0; i < cues.length - 1; i++) {
      final end = cues[i][1] as int;
      final start = cues[i][0] as int;
      final next = cues[i + 1][0] as int;
      if (end > next && next > start) cues[i][1] = next;
    }
  }

  static String _fmt(int t) {
    final h = t ~/ 3600000;
    t %= 3600000;
    final m = t ~/ 60000;
    t %= 60000;
    final s = t ~/ 1000;
    final ms = t % 1000;
    String p(int v, int w) => v.toString().padLeft(w, '0');
    return '${p(h, 2)}:${p(m, 2)}:${p(s, 2)},${p(ms, 3)}';
  }

  static String _toSrt(List<List<Object>> cues) {
    final b = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      b.writeln(i + 1);
      b.writeln('${_fmt(cues[i][0] as int)} --> ${_fmt(cues[i][1] as int)}');
      b.writeln(cues[i][2] as String);
      b.writeln();
    }
    return b.toString();
  }
}
