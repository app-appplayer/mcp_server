/// Transport-level compression for MCP server
library;

import 'dart:convert';
import 'dart:io';

/// Compression types supported
enum CompressionType {
  none,
  gzip,
  deflate,
}

/// Compression configuration
class CompressionConfig {
  /// Minimum size in bytes before compression is applied
  final int minSize;
  
  /// Compression level (1-9, where 9 is maximum compression)
  final int level;
  
  /// Compression type to use
  final CompressionType type;
  
  /// Content types to compress (regex patterns)
  final List<RegExp> compressibleTypes;
  
  CompressionConfig({
    this.minSize = 1024, // 1KB
    this.level = 6,
    this.type = CompressionType.gzip,
    List<String>? compressibleTypes,
  }) : compressibleTypes = compressibleTypes != null
      ? compressibleTypes.map((pattern) => RegExp(pattern)).toList()
      : [
          // JSON responses
          RegExp(r'application/json'),
          RegExp(r'application/.*\+json'),
          // Text responses
          RegExp(r'text/.*'),
          // SSE streams
          RegExp(r'text/event-stream'),
        ];
  
  /// Default compression configuration
  static final CompressionConfig defaultConfig = CompressionConfig();
  
  /// Check if content type should be compressed
  bool shouldCompress(String? contentType) {
    if (contentType == null || type == CompressionType.none) return false;
    
    return compressibleTypes.any((pattern) => pattern.hasMatch(contentType));
  }
}

/// Compression middleware for MCP server
class CompressionMiddleware {
  final CompressionConfig config;
  
  CompressionMiddleware({
    CompressionConfig? config,
  }) : config = config ?? CompressionConfig.defaultConfig;
  
  /// Compress data if applicable
  CompressedData? compress(List<int> data, String? contentType) {
    if (!config.shouldCompress(contentType)) {
      return null;
    }
    
    if (data.length < config.minSize) {
      return null;
    }
    
    switch (config.type) {
      case CompressionType.gzip:
        return _gzipCompress(data);
      case CompressionType.deflate:
        return _deflateCompress(data);
      case CompressionType.none:
        return null;
    }
  }
  
  /// Decompress data
  List<int> decompress(List<int> data, CompressionType type) {
    switch (type) {
      case CompressionType.gzip:
        return gzip.decode(data);
      case CompressionType.deflate:
        return zlib.decode(data);
      case CompressionType.none:
        return data;
    }
  }
  
  /// Compress using gzip
  CompressedData _gzipCompress(List<int> data) {
    final compressed = gzip.encode(data);
    return CompressedData(
      data: compressed,
      type: CompressionType.gzip,
      originalSize: data.length,
      compressedSize: compressed.length,
    );
  }
  
  /// Compress using deflate
  CompressedData _deflateCompress(List<int> data) {
    final compressed = zlib.encode(data);
    return CompressedData(
      data: compressed,
      type: CompressionType.deflate,
      originalSize: data.length,
      compressedSize: compressed.length,
    );
  }
  
  /// Get compression headers
  Map<String, String> getCompressionHeaders(CompressionType type) {
    switch (type) {
      case CompressionType.gzip:
        return {'Content-Encoding': 'gzip'};
      case CompressionType.deflate:
        return {'Content-Encoding': 'deflate'};
      case CompressionType.none:
        return {};
    }
  }
  
  /// Parse Accept-Encoding header
  Set<CompressionType> parseAcceptEncoding(String? acceptEncoding) {
    if (acceptEncoding == null || acceptEncoding.isEmpty) {
      return {CompressionType.none};
    }
    
    final types = <CompressionType>{};
    final encodings = acceptEncoding.toLowerCase().split(',');
    
    for (final encoding in encodings) {
      final trimmed = encoding.trim();
      if (trimmed.contains('gzip')) {
        types.add(CompressionType.gzip);
      } else if (trimmed.contains('deflate')) {
        types.add(CompressionType.deflate);
      }
    }
    
    if (types.isEmpty) {
      types.add(CompressionType.none);
    }
    
    return types;
  }
  
  /// Select best compression type based on client preferences
  CompressionType selectCompressionType(String? acceptEncoding) {
    final accepted = parseAcceptEncoding(acceptEncoding);
    
    // Prefer gzip if both are accepted
    if (accepted.contains(CompressionType.gzip) && 
        config.type == CompressionType.gzip) {
      return CompressionType.gzip;
    }
    
    if (accepted.contains(CompressionType.deflate) && 
        (config.type == CompressionType.deflate || 
         config.type == CompressionType.gzip)) {
      return CompressionType.deflate;
    }
    
    return CompressionType.none;
  }
}

/// Compressed data result
class CompressedData {
  final List<int> data;
  final CompressionType type;
  final int originalSize;
  final int compressedSize;
  
  CompressedData({
    required this.data,
    required this.type,
    required this.originalSize,
    required this.compressedSize,
  });
  
  /// Compression ratio (0-1, where 0 is no compression)
  double get compressionRatio => 1 - (compressedSize / originalSize);
  
  /// Whether compression was beneficial
  bool get worthCompressing => compressedSize < originalSize;
}

/// Stream compression for SSE
class StreamCompression {
  final CompressionConfig config;
  final CompressionType type;
  
  StreamCompression({
    required this.config,
    required this.type,
  }) {
    if (type != CompressionType.none && 
        type != CompressionType.gzip && 
        type != CompressionType.deflate) {
      throw ArgumentError('Invalid compression type for streaming: $type');
    }
  }
  
  /// Transform a stream of strings to compressed bytes
  Stream<List<int>> compressStream(Stream<String> input) {
    if (type == CompressionType.none) {
      return input.map((s) => utf8.encode(s));
    }
    
    return input
        .map((s) => utf8.encode(s))
        .asyncExpand((bytes) => Stream.value(
          type == CompressionType.gzip 
              ? gzip.encode(bytes)
              : zlib.encode(bytes)
        ));
  }
  
  /// Compress a single chunk
  List<int> compressChunk(String chunk) {
    final bytes = utf8.encode(chunk);
    if (type == CompressionType.none) {
      return bytes;
    }
    
    return type == CompressionType.gzip 
        ? gzip.encode(bytes)
        : zlib.encode(bytes);
  }
}