/// Tasks extension (`io.modelcontextprotocol/tasks`, MCP 2026-07-28).
///
/// Tasks graduate a request from synchronous to "call-now, fetch-later": the
/// server MAY answer a request (e.g. `tools/call`) with a [CreateTaskResult]
/// (`Result & Task`, flat, `resultType: "task"`) instead of a standard result.
/// The client then tracks it via `tasks/get` / `tasks/update` / `tasks/cancel`
/// (`tasks/list` is intentionally absent — it cannot be scoped safely without
/// sessions). Delivered as a negotiated extension; dormant unless the tasks
/// extension is advertised in `capabilities.extensions`.
///
/// Shapes mirror `modelcontextprotocol/ext-tasks` `schema/draft/schema.ts`.
library;

/// Reverse-DNS identifier for the tasks extension, used as a key in
/// `capabilities.extensions`. Its value is an empty settings object.
const String tasksExtensionId = 'io.modelcontextprotocol/tasks';

/// Lifecycle status of a [Task].
enum TaskStatus {
  /// The request is currently being processed.
  working,

  /// The task is waiting for input (elicitation or sampling).
  inputRequired,

  /// The request completed successfully and results are available.
  completed,

  /// The request failed due to a JSON-RPC error during execution.
  failed,

  /// The request was cancelled before completion.
  cancelled;

  /// The wire string per the ext-tasks schema.
  String get wire => switch (this) {
        TaskStatus.working => 'working',
        TaskStatus.inputRequired => 'input_required',
        TaskStatus.completed => 'completed',
        TaskStatus.failed => 'failed',
        TaskStatus.cancelled => 'cancelled',
      };

  /// Whether this is a terminal status (no further transitions).
  bool get isTerminal =>
      this == TaskStatus.completed ||
      this == TaskStatus.failed ||
      this == TaskStatus.cancelled;

  static TaskStatus fromWire(String s) => switch (s) {
        'working' => TaskStatus.working,
        'input_required' => TaskStatus.inputRequired,
        'completed' => TaskStatus.completed,
        'failed' => TaskStatus.failed,
        'cancelled' => TaskStatus.cancelled,
        _ => throw ArgumentError('Unknown task status: $s'),
      };
}

/// State of an asynchronous task (ext-tasks `Task` / `DetailedTask`).
///
/// The optional variant fields carry status-specific detail inlined by
/// `tasks/get` and `notifications/tasks`: [inputRequests] for
/// `input_required`, [result] for `completed`, [error] for `failed`.
class Task {
  final String taskId;
  final TaskStatus status;
  final String? statusMessage;

  /// ISO 8601 creation timestamp.
  final String createdAt;

  /// ISO 8601 last-update timestamp.
  final String lastUpdatedAt;

  /// TTL from creation in integer ms; null = unlimited. MAY change over life.
  final int? ttlMs;

  /// Suggested polling interval in integer ms; clients SHOULD honor it.
  final int? pollIntervalMs;

  /// `input_required`: server→client requests keyed by id (values are the
  /// raw `CreateMessageRequest`/`ListRootsRequest`/`ElicitRequest` maps).
  final Map<String, dynamic>? inputRequests;

  /// `completed`: the terminal result payload.
  final Map<String, dynamic>? result;

  /// `failed`: the JSON-RPC error object.
  final Map<String, dynamic>? error;

  const Task({
    required this.taskId,
    required this.status,
    required this.createdAt,
    required this.lastUpdatedAt,
    this.statusMessage,
    this.ttlMs,
    this.pollIntervalMs,
    this.inputRequests,
    this.result,
    this.error,
  });

  /// Base `Task` fields (no status-specific detail). `ttlMs` is always
  /// present per the schema (`number | null`).
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'taskId': taskId,
      'status': status.wire,
      'createdAt': createdAt,
      'lastUpdatedAt': lastUpdatedAt,
      'ttlMs': ttlMs,
    };
    if (statusMessage != null) json['statusMessage'] = statusMessage;
    if (pollIntervalMs != null) json['pollIntervalMs'] = pollIntervalMs;
    return json;
  }

  /// `DetailedTask` — base fields plus status-specific detail, used by
  /// `tasks/get` and `notifications/tasks`.
  Map<String, dynamic> toDetailedJson() {
    final json = toJson();
    if (inputRequests != null) json['inputRequests'] = inputRequests;
    if (result != null) json['result'] = result;
    if (error != null) json['error'] = error;
    return json;
  }

  factory Task.fromJson(Map<String, dynamic> json) => Task(
        taskId: json['taskId'] as String,
        status: TaskStatus.fromWire(json['status'] as String),
        createdAt: json['createdAt'] as String,
        lastUpdatedAt: json['lastUpdatedAt'] as String,
        statusMessage: json['statusMessage'] as String?,
        ttlMs: json['ttlMs'] as int?,
        pollIntervalMs: json['pollIntervalMs'] as int?,
        inputRequests: (json['inputRequests'] as Map?)
            ?.map((k, v) => MapEntry(k as String, v)),
        result: (json['result'] as Map?)?.cast<String, dynamic>(),
        error: (json['error'] as Map?)?.cast<String, dynamic>(),
      );

  Task copyWith({
    TaskStatus? status,
    String? statusMessage,
    String? lastUpdatedAt,
    int? ttlMs,
    int? pollIntervalMs,
    Map<String, dynamic>? inputRequests,
    Map<String, dynamic>? result,
    Map<String, dynamic>? error,
  }) =>
      Task(
        taskId: taskId,
        status: status ?? this.status,
        createdAt: createdAt,
        lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
        statusMessage: statusMessage ?? this.statusMessage,
        ttlMs: ttlMs ?? this.ttlMs,
        pollIntervalMs: pollIntervalMs ?? this.pollIntervalMs,
        inputRequests: inputRequests ?? this.inputRequests,
        result: result ?? this.result,
        error: error ?? this.error,
      );

  /// `CreateTaskResult` = `Result & Task` (flat) with `resultType: "task"` —
  /// the value a server returns in lieu of a standard result when it elects to
  /// process the request as a task. [meta] merges into the result `_meta`.
  Map<String, dynamic> toCreateTaskResult({Map<String, dynamic>? meta}) => {
        ...toJson(),
        'resultType': 'task',
        if (meta != null) '_meta': meta,
      };
}
