/// 2026-07-28 Multi-Round-Trip (MRTR) + subscription types (SEP-2577).
///
/// On the stateless path there is no live server→client channel, so a server
/// that needs input from the client (sampling / roots / elicitation) returns
/// an [InputRequiredResult] (result kind `input_required`) INSTEAD of pushing a
/// request. The client fulfills the embedded input requests, then re-issues the
/// ORIGINAL request carrying the matching input responses plus the opaque
/// `requestState`. This continues until a terminal (`complete`) result.
///
/// Every type here traces to the draft schema (`schema/draft/schema.ts`):
/// `Result.resultType` / `ResultType`, `InputRequiredResult`, `InputRequests`,
/// `InputResponses`, `InputResponseRequestParams`, `SubscriptionFilter`. See
/// `docs/STATELESS-COEXISTENCE-DESIGN.md` §3.3/§3.4.
///
/// All of this is additive and version-gated — it is produced only on the
/// stateless (2026-07-28) path; the legacy handshake/SSE-push path is untouched.
library;

/// Draft `ResultType` discriminator values (`schema.ts` `ResultType`).
///
/// The draft `Result` carries `resultType` on every 2026-07-28 result. When a
/// client receives a result from an earlier revision (which omits the field) it
/// MUST treat the absent value as [complete].
class McpResultType {
  McpResultType._();

  /// The wire key on a `Result` object.
  static const String key = 'resultType';

  /// `"complete"` — the request finished; the result holds the final content.
  static const String complete = 'complete';

  /// `"input_required"` — the result is an [InputRequiredResult] and the client
  /// must provide more input before retrying the original request.
  static const String inputRequired = 'input_required';

  /// `"task"` — the server elected to process the request asynchronously and
  /// the result is a `CreateTaskResult` (`Result & Task`, flat). The client
  /// tracks it via `tasks/get` / `tasks/update` / `tasks/cancel`. Tasks
  /// extension (`io.modelcontextprotocol/tasks`), MCP 2026-07-28.
  static const String task = 'task';
}

/// Draft `InputRequiredResult` — sent by the server to signal that additional
/// input is needed before the original request can complete.
///
/// At least one of [inputRequests] / [requestState] MUST be present
/// (`requestState`-only = load-shedding / backpressure). Each [inputRequests]
/// value is a server→client request object `{ "method": ..., "params": ... }`
/// (`CreateMessageRequest` | `ListRootsRequest` | `ElicitRequest`). Keys are
/// server-assigned identifiers the client echoes back in its `inputResponses`.
class InputRequiredResult {
  /// Server-issued requests the client must fulfill first, keyed by a
  /// server-assigned identifier. `null` for a `requestState`-only result.
  final Map<String, Map<String, dynamic>>? inputRequests;

  /// Opaque state blob passed back to the server on retry. The CLIENT MUST NOT
  /// interpret it; it is echoed verbatim in `InputResponseRequestParams`.
  final String? requestState;

  InputRequiredResult({this.inputRequests, this.requestState})
      : assert(inputRequests != null || requestState != null,
            'InputRequiredResult requires inputRequests or requestState');

  /// Emits the schema shape, stamping `resultType: "input_required"`.
  Map<String, dynamic> toJson() => <String, dynamic>{
        McpResultType.key: McpResultType.inputRequired,
        if (inputRequests != null) 'inputRequests': inputRequests,
        if (requestState != null) 'requestState': requestState,
      };

  factory InputRequiredResult.fromJson(Map<String, dynamic> json) {
    final raw = json['inputRequests'];
    Map<String, Map<String, dynamic>>? reqs;
    if (raw is Map) {
      reqs = <String, Map<String, dynamic>>{};
      raw.forEach((k, v) {
        if (v is Map) reqs![k as String] = Map<String, dynamic>.from(v);
      });
    }
    return InputRequiredResult(
      inputRequests: reqs,
      requestState: json['requestState'] as String?,
    );
  }

  /// Build an `elicitation/create` input-request object for [inputRequests].
  static Map<String, dynamic> elicitRequest({
    required String message,
    required Map<String, dynamic> requestedSchema,
  }) =>
      <String, dynamic>{
        'method': 'elicitation/create',
        'params': <String, dynamic>{
          'message': message,
          'requestedSchema': requestedSchema,
        },
      };

  /// Build a `sampling/createMessage` input-request object.
  static Map<String, dynamic> samplingRequest(Map<String, dynamic> params) =>
      <String, dynamic>{
        'method': 'sampling/createMessage',
        'params': params,
      };

  /// Build a `roots/list` input-request object.
  static Map<String, dynamic> rootsRequest() => <String, dynamic>{
        'method': 'roots/list',
        'params': const <String, dynamic>{},
      };
}

/// Server-side helpers for the re-issued request's `InputResponseRequestParams`
/// (`inputResponses` + `requestState`).
///
/// A tool/prompt/resource handler signature cannot change (additive rule), so on
/// the stateless path the server injects the re-issued request's MRTR fields into
/// the handler `arguments` map under these reserved reverse-DNS keys. They are
/// present ONLY on a stateless retry that carried them, so a first-round call (or
/// any legacy call) never sees them.
class McpMrtr {
  McpMrtr._();

  /// Reserved argument key carrying `InputResponseRequestParams.inputResponses`
  /// (`{ key: InputResponse }`) into a handler on a stateless retry.
  static const String argInputResponses =
      'io.modelcontextprotocol/inputResponses';

  /// Reserved argument key carrying `InputResponseRequestParams.requestState`
  /// (the opaque blob the server previously issued) into a handler on a retry.
  static const String argRequestState =
      'io.modelcontextprotocol/requestState';

  /// Read the injected `inputResponses` map from a handler's [arguments].
  static Map<String, dynamic>? readInputResponses(Map<String, dynamic> args) {
    final v = args[argInputResponses];
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  /// Read the injected opaque `requestState` from a handler's [arguments].
  static String? readRequestState(Map<String, dynamic> args) {
    final v = args[argRequestState];
    return v is String ? v : null;
  }
}

/// Draft `SubscriptionFilter` — the opt-in set of notification types a client
/// requests on a `subscriptions/listen` stream. The server MUST NOT deliver a
/// notification type the client did not request here.
class SubscriptionFilter {
  final bool toolsListChanged;
  final bool promptsListChanged;
  final bool resourcesListChanged;

  /// Resource URIs to receive `notifications/resources/updated` for (replaces
  /// the former `resources/subscribe` RPC).
  final List<String> resourceSubscriptions;

  const SubscriptionFilter({
    this.toolsListChanged = false,
    this.promptsListChanged = false,
    this.resourcesListChanged = false,
    this.resourceSubscriptions = const <String>[],
  });

  factory SubscriptionFilter.fromJson(Map<String, dynamic> json) {
    final subs = json['resourceSubscriptions'];
    return SubscriptionFilter(
      toolsListChanged: json['toolsListChanged'] == true,
      promptsListChanged: json['promptsListChanged'] == true,
      resourcesListChanged: json['resourcesListChanged'] == true,
      resourceSubscriptions: subs is List
          ? subs.map((e) => e.toString()).toList(growable: false)
          : const <String>[],
    );
  }

  /// Emits only the honored/requested fields (booleans only when true, URIs only
  /// when non-empty) — matching the acknowledged-subset shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (toolsListChanged) 'toolsListChanged': true,
        if (promptsListChanged) 'promptsListChanged': true,
        if (resourcesListChanged) 'resourcesListChanged': true,
        if (resourceSubscriptions.isNotEmpty)
          'resourceSubscriptions': resourceSubscriptions,
      };

  /// Whether this filter opted into the given notification [method]. For
  /// `notifications/resources/updated`, [uri] must be in [resourceSubscriptions].
  bool allows(String method, {String? uri}) {
    switch (method) {
      case 'notifications/tools/list_changed':
        return toolsListChanged;
      case 'notifications/prompts/list_changed':
        return promptsListChanged;
      case 'notifications/resources/list_changed':
        return resourcesListChanged;
      case 'notifications/resources/updated':
        return uri != null && resourceSubscriptions.contains(uri);
      default:
        return false;
    }
  }

  bool get isEmpty =>
      !toolsListChanged &&
      !promptsListChanged &&
      !resourcesListChanged &&
      resourceSubscriptions.isEmpty;

  /// The subset of this filter the server can actually honor, given which
  /// capabilities it advertises. Unsupported types are dropped from the
  /// acknowledged set (schema: an unsupported requested type is omitted).
  SubscriptionFilter honoredBy({
    required bool hasTools,
    required bool hasPrompts,
    required bool hasResources,
  }) =>
      SubscriptionFilter(
        toolsListChanged: toolsListChanged && hasTools,
        promptsListChanged: promptsListChanged && hasPrompts,
        resourcesListChanged: resourcesListChanged && hasResources,
        resourceSubscriptions:
            hasResources ? resourceSubscriptions : const <String>[],
      );
}
