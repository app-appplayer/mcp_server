/// Rate limiting middleware for MCP server
library;

import 'dart:collection';
import 'package:meta/meta.dart';

/// Rate limit configuration
@immutable
class RateLimitConfig {
  /// Maximum number of requests per window
  final int maxRequests;
  
  /// Time window duration
  final Duration windowDuration;
  
  /// Whether to apply rate limit per session or globally
  final bool perSession;
  
  /// Optional custom key extractor for rate limiting
  final String Function(Map<String, dynamic>)? keyExtractor;
  
  const RateLimitConfig({
    required this.maxRequests,
    required this.windowDuration,
    this.perSession = true,
    this.keyExtractor,
  });
  
  /// Default rate limit: 100 requests per minute
  static const RateLimitConfig defaultConfig = RateLimitConfig(
    maxRequests: 100,
    windowDuration: Duration(minutes: 1),
  );
  
  /// Strict rate limit: 10 requests per minute
  static const RateLimitConfig strict = RateLimitConfig(
    maxRequests: 10,
    windowDuration: Duration(minutes: 1),
  );
}

/// Rate limit result
@immutable
class RateLimitResult {
  /// Whether the request is allowed
  final bool allowed;
  
  /// Number of remaining requests in current window
  final int remaining;
  
  /// When the current window resets (UTC)
  final DateTime resetTime;
  
  /// Retry after duration if rate limited
  final Duration? retryAfter;
  
  const RateLimitResult({
    required this.allowed,
    required this.remaining,
    required this.resetTime,
    this.retryAfter,
  });
}

/// Token bucket for rate limiting
class TokenBucket {
  final int capacity;
  final Duration refillDuration;
  int _tokens;
  DateTime _lastRefill;
  
  TokenBucket({
    required this.capacity,
    required this.refillDuration,
  }) : _tokens = capacity,
       _lastRefill = DateTime.now();
  
  /// Try to consume a token
  bool tryConsume() {
    _refill();
    if (_tokens > 0) {
      _tokens--;
      return true;
    }
    return false;
  }
  
  /// Get current token count
  int get tokens {
    _refill();
    return _tokens;
  }
  
  /// Get time until next token
  Duration get timeUntilNextToken {
    final elapsed = DateTime.now().difference(_lastRefill);
    final tokensToAdd = elapsed.inMilliseconds / refillDuration.inMilliseconds;
    if (tokensToAdd >= 1) {
      return Duration.zero;
    }
    final remainingMs = refillDuration.inMilliseconds * (1 - tokensToAdd);
    return Duration(milliseconds: remainingMs.round());
  }
  
  void _refill() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastRefill);
    final tokensToAdd = (elapsed.inMilliseconds / refillDuration.inMilliseconds).floor();
    
    if (tokensToAdd > 0) {
      _tokens = (_tokens + tokensToAdd).clamp(0, capacity);
      _lastRefill = now;
    }
  }
}

/// Sliding window rate limiter
class SlidingWindowRateLimiter {
  final int maxRequests;
  final Duration windowDuration;
  final Queue<DateTime> _requestTimes = Queue<DateTime>();
  
  SlidingWindowRateLimiter({
    required this.maxRequests,
    required this.windowDuration,
  });
  
  RateLimitResult checkLimit() {
    final now = DateTime.now();
    
    // Remove expired entries
    while (_requestTimes.isNotEmpty && 
           now.difference(_requestTimes.first) > windowDuration) {
      _requestTimes.removeFirst();
    }
    
    // Check if we can accept this request
    if (_requestTimes.length < maxRequests) {
      _requestTimes.addLast(now);
      final resetTime = _requestTimes.isEmpty 
          ? now.add(windowDuration)
          : _requestTimes.first.add(windowDuration);
          
      return RateLimitResult(
        allowed: true,
        remaining: maxRequests - _requestTimes.length,
        resetTime: resetTime,
      );
    } else {
      // Rate limited
      final oldestRequest = _requestTimes.first;
      final resetTime = oldestRequest.add(windowDuration);
      final retryAfter = resetTime.difference(now);
      
      return RateLimitResult(
        allowed: false,
        remaining: 0,
        resetTime: resetTime,
        retryAfter: retryAfter,
      );
    }
  }
}

/// Rate limiter for MCP server
class RateLimiter {
  final Map<String, RateLimitConfig> _methodConfigs = {};
  final Map<String, SlidingWindowRateLimiter> _limiters = {};
  final RateLimitConfig _defaultConfig;
  
  RateLimiter({
    RateLimitConfig? defaultConfig,
    Map<String, RateLimitConfig>? methodConfigs,
  }) : _defaultConfig = defaultConfig ?? RateLimitConfig.defaultConfig {
    if (methodConfigs != null) {
      _methodConfigs.addAll(methodConfigs);
    }
  }
  
  /// Configure rate limit for specific method
  void configureMethod(String method, RateLimitConfig config) {
    _methodConfigs[method] = config;
  }
  
  /// Check if request is allowed
  RateLimitResult checkLimit({
    required String sessionId,
    required String method,
    Map<String, dynamic>? params,
  }) {
    final config = _methodConfigs[method] ?? _defaultConfig;
    
    // Generate rate limit key
    String key;
    if (config.keyExtractor != null && params != null) {
      key = config.keyExtractor!(params);
    } else if (config.perSession) {
      key = '$sessionId:$method';
    } else {
      key = 'global:$method';
    }
    
    // Get or create limiter
    final limiter = _limiters.putIfAbsent(
      key,
      () => SlidingWindowRateLimiter(
        maxRequests: config.maxRequests,
        windowDuration: config.windowDuration,
      ),
    );
    
    return limiter.checkLimit();
  }
  
  /// Reset limits for a session
  void resetSession(String sessionId) {
    _limiters.removeWhere((key, _) => key.startsWith('$sessionId:'));
  }
  
  /// Get current stats
  Map<String, dynamic> getStats() {
    final stats = <String, dynamic>{};
    
    for (final entry in _limiters.entries) {
      final parts = entry.key.split(':');
      final sessionOrGlobal = parts[0];
      final method = parts.length > 1 ? parts[1] : 'unknown';
      
      final result = entry.value.checkLimit();
      stats[entry.key] = {
        'method': method,
        'session': sessionOrGlobal != 'global' ? sessionOrGlobal : null,
        'remaining': result.remaining,
        'resetTime': result.resetTime.toIso8601String(),
      };
    }
    
    return stats;
  }
}

/// Rate limit headers
class RateLimitHeaders {
  static const String limit = 'X-RateLimit-Limit';
  static const String remaining = 'X-RateLimit-Remaining';
  static const String reset = 'X-RateLimit-Reset';
  static const String retryAfter = 'Retry-After';
  
  /// Generate rate limit headers
  static Map<String, String> fromResult(RateLimitResult result, int limit) {
    final headers = <String, String>{
      RateLimitHeaders.limit: limit.toString(),
      RateLimitHeaders.remaining: result.remaining.toString(),
      RateLimitHeaders.reset: (result.resetTime.millisecondsSinceEpoch ~/ 1000).toString(),
    };
    
    if (result.retryAfter != null) {
      headers[RateLimitHeaders.retryAfter] = result.retryAfter!.inSeconds.toString();
    }
    
    return headers;
  }
}