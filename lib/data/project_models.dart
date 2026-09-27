import 'dart:convert';
import 'dart:ui';

/// Mercury projects: a linked GitHub repo with its own Hermes agent, memory and
/// kanban board. Hermes does the work; these are the read models the app shows.

/// Where a task is, in the words the app shows.
enum TaskPhase {
  queued('Queued'),
  working('Working'),
  review('In review'),
  ciRetry('Fixing CI'),
  ready('Ready to test'),
  needsYou('Needs you'),
  merged('Merged'),
  closed('Closed'),
  done('Done'),
  cancelled('Cancelled');

  const TaskPhase(this.label);
  final String label;

  static TaskPhase parse(String? s) => switch (s) {
        'queued' => queued,
        'working' => working,
        'review' => review,
        'ci_retry' => ciRetry,
        'ready' => ready,
        'needs_you' => needsYou,
        'merged' => merged,
        'closed' => closed,
        'done' => done,
        'cancelled' => cancelled,
        _ => queued,
      };

  /// The name the scripts and the bridge use (`ci_retry`, `needs_you`), not the
  /// Dart camelCase one — this goes back to Hermes in an intent payload.
  String get wire => switch (this) {
        TaskPhase.ciRetry => 'ci_retry',
        TaskPhase.needsYou => 'needs_you',
        _ => name,
      };

  bool get isActive => this == queued || this == working || this == review || this == ciRetry;

  /// The work is over: merged, closed, done or cancelled.
  bool get isFinished => !isActive && this != ready;
}

/// A project's headline state, most urgent first.
enum ProjectStatus {
  needsYou('Needs you'),
  ready('Ready to test'),
  working('Working'),
  queued('Queued'),
  idle('Idle');

  const ProjectStatus(this.label);
  final String label;

  static ProjectStatus parse(String? s) => switch (s) {
        'needs_you' => needsYou,
        'ready' => ready,
        'working' => working,
        'queued' => queued,
        _ => idle,
      };
}

class ProjectTask {
  final String id;
  final String title;
  final TaskPhase phase;
  final int? issue;
  final String? issueUrl;
  final int? prNumber;
  final String? prUrl;
  final String? ci; // green | red | pending | none
  final List<String> failingChecks;
  final String? apk; // server path of the debug APK built for the PR head
  final String? coder;
  final String? branch;
  final String? blockedReason;
  final DateTime? mergedAt;
  final DateTime? updatedAt;

  const ProjectTask({
    required this.id,
    required this.title,
    required this.phase,
    this.issue,
    this.issueUrl,
    this.prNumber,
    this.prUrl,
    this.ci,
    this.failingChecks = const [],
    this.apk,
    this.coder,
    this.branch,
    this.blockedReason,
    this.mergedAt,
    this.updatedAt,
  });

  factory ProjectTask.fromJson(Map<String, dynamic> j) => ProjectTask(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        phase: TaskPhase.parse(j['phase'] as String?),
        issue: (j['issue'] as num?)?.toInt(),
        issueUrl: j['issueUrl'] as String?,
        prNumber: (j['prNumber'] as num?)?.toInt(),
        prUrl: j['prUrl'] as String?,
        ci: j['ci'] as String?,
        failingChecks: ((j['failingChecks'] as List?) ?? const []).map((e) => e.toString()).toList(),
        apk: j['apk'] as String?,
        coder: j['coder'] as String?,
        branch: j['branch'] as String?,
        blockedReason: j['blockedReason'] as String?,
        mergedAt: DateTime.tryParse((j['mergedAt'] ?? '').toString()),
        updatedAt: DateTime.tryParse((j['updatedAt'] ?? '').toString()),
      );

  bool get canRetry => phase == TaskPhase.needsYou;
  bool get canCancel => phase == TaskPhase.queued;

  /// Tap-through: every task has a detail page, including finished ones.
  /// Suggesting an edit only makes sense once something exists to change.
  bool get canSuggestEdit => phase != TaskPhase.cancelled && phase != TaskPhase.queued;

  /// A follow-up issue is for work that already landed (or was refused).
  bool get canFileFollowUp => phase.isFinished;
}

class Project {
  final String id;
  final String name;
  final String repo;
  final String profile;
  final String coder; // claude | agy
  final String gates;
  final String defaultBranch;
  final ProjectStatus status;
  final int needsYou;
  final int ready;
  final int working;
  final int queued;
  final bool awake;
  final ProjectTask? lastTask;
  final List<ProjectTask> tasks; // filled by the detail call only
  final Color color;

  const Project({
    required this.id,
    required this.name,
    required this.repo,
    required this.profile,
    this.coder = 'claude',
    this.gates = '',
    this.defaultBranch = 'main',
    this.status = ProjectStatus.idle,
    this.needsYou = 0,
    this.ready = 0,
    this.working = 0,
    this.queued = 0,
    this.awake = false,
    this.lastTask,
    this.tasks = const [],
    this.color = const Color(0xFF6750A4),
  });

  factory Project.fromJson(Map<String, dynamic> j) {
    final counts = (j['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
    int n(String k) => (counts[k] as num?)?.toInt() ?? 0;
    final last = j['lastTask'];
    return Project(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] ?? j['id'] ?? '').toString(),
      repo: (j['repo'] ?? '').toString(),
      profile: (j['profile'] ?? '').toString(),
      coder: (j['coder'] ?? 'claude').toString(),
      gates: (j['gates'] ?? '').toString(),
      defaultBranch: (j['defaultBranch'] ?? 'main').toString(),
      status: ProjectStatus.parse(j['status'] as String?),
      needsYou: n('needs_you'),
      ready: n('ready'),
      working: n('working'),
      queued: n('queued'),
      awake: j['awake'] == true,
      lastTask: last is Map ? ProjectTask.fromJson(last.cast<String, dynamic>()) : null,
      tasks: ((j['tasks'] as List?) ?? const [])
          .map((t) => ProjectTask.fromJson((t as Map).cast<String, dynamic>()))
          .toList(),
      color: Color((j['color'] as num?)?.toInt() ?? 0xFF6750A4),
    );
  }

  String get coderLabel => coderName(coder);
}

String coderName(String? coder) => switch (coder) {
      'agy' => 'Antigravity',
      'hermes' => 'Hermes',
      _ => 'Claude Code',
    };

/// A repo the host's GitHub login can see (for the link sheet).
class GithubRepo {
  final String repo;
  final String description;
  final String? language;
  final bool private;
  final String? linkedAs;
  const GithubRepo({
    required this.repo,
    this.description = '',
    this.language,
    this.private = false,
    this.linkedAs,
  });

  factory GithubRepo.fromJson(Map<String, dynamic> j) => GithubRepo(
        repo: (j['repo'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        language: j['language'] as String?,
        private: j['private'] == true,
        linkedAs: j['linkedAs'] as String?,
      );

  String get name => repo.contains('/') ? repo.split('/').last : repo;
}

/// The issue a Plan-mode chat produced: a fenced ```issue-draft JSON block at the
/// end of the agent's reply (see hermes/skills/issue-planner).
class IssueDraft {
  final String title;
  final String body;
  final List<String> acceptance;
  final List<String> labels;
  const IssueDraft({
    required this.title,
    this.body = '',
    this.acceptance = const [],
    this.labels = const [],
  });

  static final _block = RegExp(r'```issue-draft\s*\n?([\s\S]*?)```');

  /// The last well-formed draft in [text], or null.
  static IssueDraft? tryParse(String text) {
    IssueDraft? found;
    for (final m in _block.allMatches(text)) {
      try {
        final j = jsonDecode(m.group(1)!.trim());
        if (j is! Map) continue;
        final title = (j['title'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        List<String> list(Object? v) =>
            ((v as List?) ?? const []).map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList();
        found = IssueDraft(
          title: title,
          body: (j['body'] ?? '').toString(),
          acceptance: list(j['acceptance']),
          labels: list(j['labels']),
        );
      } on FormatException {
        continue;
      }
    }
    return found;
  }

  /// [text] with draft blocks removed, for the chat bubble (the card shows them).
  static String strip(String text) => text.replaceAll(_block, '').trimRight();

  IssueDraft copyWith({String? title, String? body, List<String>? acceptance}) => IssueDraft(
        title: title ?? this.title,
        body: body ?? this.body,
        acceptance: acceptance ?? this.acceptance,
        labels: labels,
      );

  Map<String, dynamic> toJson() =>
      {'title': title, 'body': body, 'acceptance': acceptance, 'labels': labels};
}

/// Something Hermes told the phone (ready, needs you, info).
class ProjectEvent {
  final String id;
  final DateTime at;
  final String kind;
  final String project;
  final String? task;
  final String title;
  final String body;
  final String? url;
  final String? apk;
  const ProjectEvent({
    required this.id,
    required this.at,
    required this.kind,
    required this.project,
    required this.title,
    this.task,
    this.body = '',
    this.url,
    this.apk,
  });

  factory ProjectEvent.fromJson(Map<String, dynamic> j) => ProjectEvent(
        id: (j['id'] ?? '').toString(),
        at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
        kind: (j['kind'] ?? 'info').toString(),
        project: (j['project'] ?? '').toString(),
        task: j['task'] as String?,
        title: (j['title'] ?? '').toString(),
        body: (j['body'] ?? '').toString(),
        url: j['url'] as String?,
        apk: j['apk'] as String?,
      );
}

class AgentProcess {
  final int pid;
  final String kind; // gateway | worker | coder | code_task | bridge | interactive
  final String? profile;
  final int rssMb;
  final int ageSec;
  const AgentProcess({
    required this.pid,
    required this.kind,
    this.profile,
    this.rssMb = 0,
    this.ageSec = 0,
  });

  factory AgentProcess.fromJson(Map<String, dynamic> j) => AgentProcess(
        pid: (j['pid'] as num?)?.toInt() ?? 0,
        kind: (j['kind'] ?? '').toString(),
        profile: j['profile'] as String?,
        rssMb: (j['rssMb'] as num?)?.toInt() ?? 0,
        ageSec: (j['ageSec'] as num?)?.toInt() ?? 0,
      );
}

class AgentSnapshot {
  final int memAvailableMb;
  final List<AgentProcess> processes;
  const AgentSnapshot({required this.memAvailableMb, this.processes = const []});

  factory AgentSnapshot.fromJson(Map<String, dynamic> j) => AgentSnapshot(
        memAvailableMb: (j['memAvailableMb'] as num?)?.toInt() ?? 0,
        processes: ((j['processes'] as List?) ?? const [])
            .map((p) => AgentProcess.fromJson((p as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// Hermes' answer to something the app asked it to do.
class IntentResult {
  final String sessionId;
  final String reply;
  const IntentResult({required this.sessionId, required this.reply});
}

/// A note you jotted on a project. Deliberately not [MemoryEntry]: memory is
/// injected into the agent's prompt on every turn, so it costs tokens forever
/// and can steer the agent. A note is inert — it never reaches a model until you
/// tap "Ask the agent" on it.
class ProjectNote {
  final String id;
  final String text;
  final DateTime at;
  final DateTime? updatedAt;
  const ProjectNote({
    required this.id,
    required this.text,
    required this.at,
    this.updatedAt,
  });

  factory ProjectNote.fromJson(Map<String, dynamic> j) {
    final edited = (j['updatedAt'] ?? '').toString();
    return ProjectNote(
      id: (j['id'] ?? '').toString(),
      text: (j['text'] ?? '').toString(),
      at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
      updatedAt: edited.isEmpty ? null : DateTime.tryParse(edited),
    );
  }
}
