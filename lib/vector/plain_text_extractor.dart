import 'dart:convert';
import 'package:aq_schema/aq_schema.dart';

/// Extracts plain text from text/* content types.
final class PlainTextExtractor implements IContentExtractor {
  @override
  final String id = 'plain-text-v1';
  @override
  final String version = '1';
  @override
  final Set<String> supportedContentTypes = const {
    'text/plain',
    'text/markdown',
    'text/html',
  };

  @override
  Future<ExtractedContent> extract(
    List<int> bytes,
    String contentType,
    Map<String, dynamic> meta,
  ) async {
    return ExtractedContent(
      artifactId: meta['artifactId'] as String,
      tenantId: meta['tenantId'] as String,
      ownerId: meta['ownerId'] as String,
      modality: 'text',
      text: utf8.decode(bytes),
      meta: meta,
    );
  }
}
