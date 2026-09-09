import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// One file part of a decoded multipart body.
class MultipartFilePart {
  final String filename;
  final List<int> bytes;
  const MultipartFilePart(this.filename, this.bytes);
}

/// The fields and file parts of a `multipart/form-data` request body, decoded
/// by hand so tests assert the wire shape rather than what the client thinks
/// it sent. `MockClient` finalizes a `MultipartRequest` into a plain
/// [http.Request] whose body is the encoded form; this reads it back.
class MultipartBody {
  final Map<String, String> fields;
  final Map<String, MultipartFilePart> files;
  const MultipartBody(this.fields, this.files);

  static MultipartBody of(http.Request request) {
    final contentType = request.headers['content-type'] ?? '';
    expect(contentType, startsWith('multipart/form-data'));
    final boundary = RegExp(
      r'boundary=(.+)$',
    ).firstMatch(contentType)!.group(1)!;
    final body = request.bodyBytes;
    final delimiter = utf8.encode('--$boundary');
    final fields = <String, String>{};
    final files = <String, MultipartFilePart>{};

    // Split on the delimiter; the first chunk is the preamble, the last the
    // closing `--`.
    final chunks = <List<int>>[];
    var start = 0;
    for (var i = 0; i + delimiter.length <= body.length; i++) {
      var match = true;
      for (var j = 0; j < delimiter.length; j++) {
        if (body[i + j] != delimiter[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        chunks.add(body.sublist(start, i));
        start = i + delimiter.length;
        i = start - 1;
      }
    }
    for (final chunk in chunks.skip(1)) {
      // Each part is CRLF, headers, CRLFCRLF, content, CRLF.
      final text = latin1.decode(chunk);
      final headerEnd = text.indexOf('\r\n\r\n');
      if (headerEnd < 0) continue;
      final headers = text.substring(0, headerEnd);
      final content = chunk.sublist(headerEnd + 4, chunk.length - 2);
      final name = RegExp(r'name="([^"]+)"').firstMatch(headers)?.group(1);
      if (name == null) continue;
      final filename = RegExp(
        r'filename="([^"]+)"',
      ).firstMatch(headers)?.group(1);
      if (filename != null) {
        files[name] = MultipartFilePart(filename, content);
      } else {
        fields[name] = utf8.decode(content);
      }
    }
    return MultipartBody(fields, files);
  }
}
