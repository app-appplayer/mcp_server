/// Metrics collection for MCP server
library;

import 'dart:async';

/// Metric types
enum MetricType {
  counter,
  gauge,
  histogram,
  timer,
}

/// Base metric interface
abstract class Metric {
  final String name;
  final String description;
  final Map<String, String> labels;
  final MetricType type;
  
  Metric({
    required this.name,
    required this.description,
    required this.type,
    Map<String, String>? labels,
  }) : labels = labels ?? {};
  
  Map<String, dynamic> toJson();
  void reset();
}

/// Counter metric - monotonically increasing value
class Counter extends Metric {
  int _value = 0;
  
  Counter({
    required super.name,
    required super.description,
    super.labels,
  }) : super(
    type: MetricType.counter,
  );
  
  void increment([int amount = 1]) {
    _value += amount;
  }
  
  int get value => _value;
  
  @override
  void reset() {
    _value = 0;
  }
  
  @override
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': 'counter',
      'description': description,
      'value': _value,
      'labels': labels,
    };
  }
}

/// Gauge metric - value that can go up and down
class Gauge extends Metric {
  double _value = 0;
  
  Gauge({
    required super.name,
    required super.description,
    super.labels,
  }) : super(
    type: MetricType.gauge,
  );
  
  void set(double value) {
    _value = value;
  }
  
  void increment([double amount = 1]) {
    _value += amount;
  }
  
  void decrement([double amount = 1]) {
    _value -= amount;
  }
  
  double get value => _value;
  
  @override
  void reset() {
    _value = 0;
  }
  
  @override
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': 'gauge',
      'description': description,
      'value': _value,
      'labels': labels,
    };
  }
}

/// Histogram metric - distribution of values
class Histogram extends Metric {
  final List<double> _values = [];
  final List<double> buckets;
  Map<double, int>? _bucketCounts;
  
  Histogram({
    required super.name,
    required super.description,
    List<double>? buckets,
    super.labels,
  }) : buckets = buckets ?? _defaultBuckets,
       super(
    type: MetricType.histogram,
  );
  
  static final List<double> _defaultBuckets = [
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10
  ];
  
  void observe(double value) {
    _values.add(value);
    _bucketCounts = null; // Invalidate cache
  }
  
  int get count => _values.length;
  
  double get sum => _values.fold(0, (sum, value) => sum + value);
  
  double get mean => _values.isEmpty ? 0 : sum / count;
  
  double percentile(double p) {
    if (_values.isEmpty) return 0;
    
    final sorted = List<double>.from(_values)..sort();
    final index = (p * (sorted.length - 1)).round();
    return sorted[index];
  }
  
  Map<double, int> get bucketCounts {
    if (_bucketCounts != null) return _bucketCounts!;
    
    _bucketCounts = {};
    for (final bucket in buckets) {
      _bucketCounts![bucket] = _values.where((v) => v <= bucket).length;
    }
    _bucketCounts![double.infinity] = _values.length;
    
    return _bucketCounts!;
  }
  
  @override
  void reset() {
    _values.clear();
    _bucketCounts = null;
  }
  
  @override
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': 'histogram',
      'description': description,
      'count': count,
      'sum': sum,
      'mean': mean,
      'p50': percentile(0.5),
      'p90': percentile(0.9),
      'p95': percentile(0.95),
      'p99': percentile(0.99),
      'buckets': bucketCounts,
      'labels': labels,
    };
  }
}

/// Timer metric - tracks durations
class TimerMetric extends Metric {
  final Histogram _histogram;
  final Map<String, Stopwatch> _activeTimers = {};
  
  TimerMetric({
    required super.name,
    required super.description,
    super.labels,
  }) : _histogram = Histogram(
    name: name,
    description: description,
    labels: labels,
  ),
       super(
    type: MetricType.timer,
  );
  
  /// Start timing an operation
  void startTimer(String operationId) {
    _activeTimers[operationId] = Stopwatch()..start();
  }
  
  /// Stop timing and record the duration
  Duration? stopTimer(String operationId) {
    final timer = _activeTimers.remove(operationId);
    if (timer == null) return null;
    
    timer.stop();
    final duration = timer.elapsed;
    _histogram.observe(duration.inMicroseconds / 1000000.0); // Convert to seconds
    return duration;
  }
  
  /// Time a function execution
  Future<T> timeAsync<T>(Future<T> Function() operation) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await operation();
    } finally {
      stopwatch.stop();
      _histogram.observe(stopwatch.elapsedMicroseconds / 1000000.0);
    }
  }
  
  /// Time a synchronous function
  T timeSync<T>(T Function() operation) {
    final stopwatch = Stopwatch()..start();
    try {
      return operation();
    } finally {
      stopwatch.stop();
      _histogram.observe(stopwatch.elapsedMicroseconds / 1000000.0);
    }
  }
  
  @override
  void reset() {
    _histogram.reset();
    _activeTimers.clear();
  }
  
  @override
  Map<String, dynamic> toJson() {
    final histogramData = _histogram.toJson();
    histogramData['type'] = 'timer';
    histogramData['activeTimers'] = _activeTimers.length;
    return histogramData;
  }
}

/// Metrics collector for MCP server
class MetricsCollector {
  final Map<String, Metric> _metrics = {};
  final DateTime _startTime = DateTime.now();
  
  /// Register a new metric
  void register(Metric metric) {
    final key = _getMetricKey(metric.name, metric.labels);
    _metrics[key] = metric;
  }
  
  /// Get or create a counter
  Counter counter(String name, {String? description, Map<String, String>? labels}) {
    final key = _getMetricKey(name, labels);
    return _metrics.putIfAbsent(key, () => Counter(
      name: name,
      description: description ?? name,
      labels: labels,
    )) as Counter;
  }
  
  /// Get or create a gauge
  Gauge gauge(String name, {String? description, Map<String, String>? labels}) {
    final key = _getMetricKey(name, labels);
    return _metrics.putIfAbsent(key, () => Gauge(
      name: name,
      description: description ?? name,
      labels: labels,
    )) as Gauge;
  }
  
  /// Get or create a histogram
  Histogram histogram(String name, {String? description, List<double>? buckets, Map<String, String>? labels}) {
    final key = _getMetricKey(name, labels);
    return _metrics.putIfAbsent(key, () => Histogram(
      name: name,
      description: description ?? name,
      buckets: buckets,
      labels: labels,
    )) as Histogram;
  }
  
  /// Get or create a timer
  TimerMetric timer(String name, {String? description, Map<String, String>? labels}) {
    final key = _getMetricKey(name, labels);
    return _metrics.putIfAbsent(key, () => TimerMetric(
      name: name,
      description: description ?? name,
      labels: labels,
    )) as TimerMetric;
  }
  
  /// Get all metrics as JSON
  Map<String, dynamic> toJson() {
    final metrics = <String, dynamic>{};
    
    for (final entry in _metrics.entries) {
      metrics[entry.key] = entry.value.toJson();
    }
    
    return {
      'startTime': _startTime.toIso8601String(),
      'uptime': DateTime.now().difference(_startTime).inSeconds,
      'metrics': metrics,
    };
  }
  
  /// Reset all metrics
  void reset() {
    for (final metric in _metrics.values) {
      metric.reset();
    }
  }
  
  /// Reset specific metric
  void resetMetric(String name, {Map<String, String>? labels}) {
    final key = _getMetricKey(name, labels);
    _metrics[key]?.reset();
  }
  
  String _getMetricKey(String name, Map<String, String>? labels) {
    if (labels == null || labels.isEmpty) return name;
    
    final sortedLabels = labels.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    
    final labelStr = sortedLabels
        .map((e) => '${e.key}="${e.value}"')
        .join(',');
    
    return '$name{$labelStr}';
  }
}

/// Standard MCP server metrics
class StandardMetrics {
  final MetricsCollector collector;
  
  StandardMetrics(this.collector) {
    _registerStandardMetrics();
  }
  
  void _registerStandardMetrics() {
    // Request metrics
    collector.counter('mcp_requests_total', 
        description: 'Total number of requests');
    collector.counter('mcp_requests_success_total', 
        description: 'Total number of successful requests');
    collector.counter('mcp_requests_error_total', 
        description: 'Total number of failed requests');
    
    // Response time metrics
    collector.timer('mcp_request_duration_seconds',
        description: 'Request processing duration');
    
    // Connection metrics
    collector.gauge('mcp_connections_active',
        description: 'Number of active connections');
    collector.counter('mcp_connections_total',
        description: 'Total number of connections');
    
    // Resource metrics
    collector.gauge('mcp_tools_registered',
        description: 'Number of registered tools');
    collector.gauge('mcp_resources_registered',
        description: 'Number of registered resources');
    collector.gauge('mcp_prompts_registered',
        description: 'Number of registered prompts');
    
    // Rate limiting metrics
    collector.counter('mcp_rate_limit_exceeded_total',
        description: 'Number of rate limit violations');
  }
  
  /// Track request
  void trackRequest(String method, {Map<String, String>? labels}) {
    final fullLabels = {'method': method, ...?labels};
    collector.counter('mcp_requests_total', labels: fullLabels).increment();
  }
  
  /// Track successful request
  void trackSuccess(String method, {Map<String, String>? labels}) {
    final fullLabels = {'method': method, ...?labels};
    collector.counter('mcp_requests_success_total', labels: fullLabels).increment();
  }
  
  /// Track failed request
  void trackError(String method, int errorCode, {Map<String, String>? labels}) {
    final fullLabels = {
      'method': method,
      'error_code': errorCode.toString(),
      ...?labels
    };
    collector.counter('mcp_requests_error_total', labels: fullLabels).increment();
  }
  
  /// Start timing a request
  void startRequestTimer(String requestId, String method) {
    collector.timer('mcp_request_duration_seconds', 
        labels: {'method': method}).startTimer(requestId);
  }
  
  /// Stop timing a request
  Duration? stopRequestTimer(String requestId, String method) {
    return collector.timer('mcp_request_duration_seconds',
        labels: {'method': method}).stopTimer(requestId);
  }
}