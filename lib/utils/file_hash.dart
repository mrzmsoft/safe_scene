import 'dart:io';

import 'package:crypto/crypto.dart';

/// Streaming SHA-256 helpers used to verify a media file against the
/// `media_hash` recorded in a `.safe(.json)` rule set.
///
/// The scanner engine writes its hash as lowercase hex (`digest.hexdigest()` in
/// Python); [Digest.toString] from package:crypto also produces lowercase hex,
/// so the two are directly comparable.

/// A minimal [Sink] that captures the single [Digest] produced by a chunked
/// SHA-256 conversion.
class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

Future<String> sha256FileHex(String path, {int chunkSize = 1 << 20}) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  final stream = File(path).openRead();
  try {
    await for (final chunk in stream) {
      input.add(chunk);
    }
    input.close();
  } catch (_) {
    input.close();
    rethrow;
  }
  return sink.digest!.toString();
}

/// Computes the hex digest of a single [String] (mainly for tests).
String sha256StringHex(String value) => sha256.convert(value.codeUnits).toString();
