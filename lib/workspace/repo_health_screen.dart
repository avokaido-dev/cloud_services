import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../auth/auth_service.dart';

// ─── Data model ───────────────────────────────────────────────────────────────

class _Summary {
  const _Summary({
    this.critical = 0,
    this.high = 0,
    this.moderate = 0,
    this.low = 0,
    this.info = 0,
    this.total,
    this.score,
    this.passed,
  });

  final int critical;
  final int high;
  final int moderate;
  final int low;
  final int info;
  final int? total;
  final double? score;
  final bool? passed;

  int get effectiveTotal =>
      total ?? (critical + high + moderate + low + info);

  factory _Summary.fromMap(Map<String, dynamic> m) => _Summary(
        critical: (m['critical'] as num?)?.toInt() ?? 0,
        high: (m['high'] as num?)?.toInt() ?? 0,
        moderate: (m['moderate'] as num?)?.toInt() ?? 0,
        low: (m['low'] as num?)?.toInt() ?? 0,
        info: (m['info'] as num?)?.toInt() ?? 0,
        total: (m['total'] as num?)?.toInt(),
        score: (m['score'] as num?)?.toDouble(),
        passed: m['passed'] as bool?,
      );

  static const empty = _Summary();
}

class _Finding {
  const _Finding({
    required this.severity,
    required this.title,
    this.subject,
    this.location,
    this.installedVersion,
    this.fixedIn,
    this.url,
  });

  final String severity;
  final String title;
  final String? subject;
  final String? location;
  final String? installedVersion;
  final String? fixedIn;
  final String? url;

  factory _Finding.fromMap(Map<String, dynamic> m) => _Finding(
        severity: m['severity'] as String? ?? 'info',
        title: m['title'] as String? ?? '',
        subject: m['subject'] as String?,
        location: m['location'] as String?,
        installedVersion: m['installedVersion'] as String?,
        fixedIn: m['fixedIn'] as String?,
        url: m['url'] as String?,
      );

  int get severityOrder {
    switch (severity) {
      case 'critical':
        return 0;
      case 'high':
        return 1;
      case 'moderate':
        return 2;
      case 'low':
        return 3;
      default:
        return 4;
    }
  }
}

class _RepoCheck {
  const _RepoCheck({
    required this.id,
    required this.repo,
    required this.type,
    required this.category,
    required this.status,
    required this.runAt,
    required this.createdAt,
    required this.summary,
    required this.findings,
    this.toolVersion,
    this.errorMessage,
  });

  final String id;
  final String repo;
  final String type;
  final String category;
  final String status;
  final String runAt;
  final DateTime createdAt;
  final _Summary summary;
  final List<_Finding> findings;
  final String? toolVersion;
  final String? errorMessage;

  factory _RepoCheck.fromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final rawCreatedAt = d['createdAt'];
    final createdAt = rawCreatedAt is Timestamp
        ? rawCreatedAt.toDate()
        : DateTime.tryParse(d['runAt'] as String? ?? '') ?? DateTime.now();
    final rawSummary = d['summary'];
    final summary = rawSummary is Map<String, dynamic>
        ? _Summary.fromMap(rawSummary)
        : _Summary.empty;
    final rawFindings = d['findings'] as List<dynamic>? ?? [];
    final findings = rawFindings
        .whereType<Map<String, dynamic>>()
        .map(_Finding.fromMap)
        .toList();
    return _RepoCheck(
      id: doc.id,
      repo: d['repo'] as String? ?? '',
      type: d['type'] as String? ?? '',
      category: d['category'] as String? ?? '',
      status: d['status'] as String? ?? 'error',
      runAt: d['runAt'] as String? ?? '',
      createdAt: createdAt,
      summary: summary,
      findings: findings,
      toolVersion: d['toolVersion'] as String?,
      errorMessage: d['errorMessage'] as String?,
    );
  }

  int get statusOrder {
    switch (status) {
      case 'fail':
        return 0;
      case 'warn':
        return 1;
      case 'pass':
        return 2;
      default:
        return 3;
    }
  }
}

// ─── Aggregation ──────────────────────────────────────────────────────────────

class _WorkspaceAgg {
  _WorkspaceAgg(Map<String, _RepoCheck> latestByRepoType) {
    int crit = 0, hi = 0, mod = 0, lo = 0;
    final repoSet = <String>{};
    final failedRepos = <String>{};

    for (final c in latestByRepoType.values) {
      repoSet.add(c.repo);
      crit += c.summary.critical;
      hi += c.summary.high;
      mod += c.summary.moderate;
      lo += c.summary.low;
      if (c.status == 'fail') failedRepos.add(c.repo);
    }

    critical = crit;
    high = hi;
    moderate = mod;
    low = lo;
    repoCount = repoSet.length;
    failedRepoCount = failedRepos.length;
  }

  late final int critical;
  late final int high;
  late final int moderate;
  late final int low;
  late final int repoCount;
  late final int failedRepoCount;
}

// ─── Colours & formatting ─────────────────────────────────────────────────────

Color _statusColor(String status) {
  switch (status) {
    case 'fail':
      return Colors.red.shade700;
    case 'warn':
      return Colors.orange.shade700;
    case 'pass':
      return Colors.green.shade700;
    default:
      return Colors.grey.shade600;
  }
}

Color _severityColor(String severity) {
  switch (severity) {
    case 'critical':
      return Colors.red.shade800;
    case 'high':
      return Colors.orange.shade800;
    case 'moderate':
      return Colors.amber.shade700;
    case 'low':
      return Colors.yellow.shade800;
    case 'info':
      return Colors.blue.shade700;
    default:
      return Colors.grey.shade600;
  }
}

String _capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

String _timeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inDays >= 1) return '${diff.inDays}d ago';
  if (diff.inHours >= 1) return '${diff.inHours}h ago';
  if (diff.inMinutes >= 1) return '${diff.inMinutes}m ago';
  return 'just now';
}

const _seriesColors = [
  Color(0xFF1565C0),
  Color(0xFF2E7D32),
  Color(0xFF6A1B9A),
  Color(0xFFE65100),
  Color(0xFF00695C),
];

// ─── Screen ───────────────────────────────────────────────────────────────────

class RepoHealthScreen extends StatefulWidget {
  const RepoHealthScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<RepoHealthScreen> createState() => _RepoHealthScreenState();
}

class _RepoHealthScreenState extends State<RepoHealthScreen> {
  String? _selectedRepo;
  String? _selectedCategory;

  @override
  Widget build(BuildContext context) {
    final wsId = widget.auth.workspaceId;
    if (wsId == null) return const SizedBox.shrink();

    final overviewStream = FirebaseFirestore.instance
        .collection('workspaces')
        .doc(wsId)
        .collection('repoChecks')
        .orderBy('createdAt', descending: true)
        .limit(500)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: overviewStream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorCard(message: snap.error.toString());
        }

        final allChecks =
            (snap.data?.docs ?? []).map(_RepoCheck.fromDoc).toList();

        final categories = <String>{
          for (final c in allChecks)
            if (c.category.isNotEmpty) c.category,
        };

        final filtered = _selectedCategory == null
            ? allChecks
            : allChecks
                .where((c) => c.category == _selectedCategory)
                .toList();

        // Latest run per (repo, type) — docs are already desc by createdAt.
        final latestByRepoType = <String, _RepoCheck>{};
        for (final c in filtered) {
          latestByRepoType.putIfAbsent('${c.repo}__${c.type}', () => c);
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  if (_selectedRepo != null) ...[
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back to overview',
                      onPressed: () =>
                          setState(() => _selectedRepo = null),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      _selectedRepo ?? 'Repo Health',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Category filter chips
              if (categories.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: _selectedCategory == null,
                      onSelected: (_) =>
                          setState(() => _selectedCategory = null),
                    ),
                    for (final cat in (categories.toList()..sort()))
                      FilterChip(
                        label: Text(_capitalize(cat)),
                        selected: _selectedCategory == cat,
                        onSelected: (_) => setState(
                          () => _selectedCategory =
                              _selectedCategory == cat ? null : cat,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              // Main content
              if (allChecks.isEmpty)
                const _EmptyState()
              else if (_selectedRepo == null)
                _WorkspaceOverview(
                  latestByRepoType: latestByRepoType,
                  wsId: wsId,
                  onSelectRepo: (r) =>
                      setState(() => _selectedRepo = r),
                )
              else
                _RepoDetailView(
                  repo: _selectedRepo!,
                  wsId: wsId,
                  latestByType: {
                    for (final e in latestByRepoType.entries)
                      if (e.value.repo == _selectedRepo)
                        e.value.type: e.value,
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Workspace overview ───────────────────────────────────────────────────────

class _WorkspaceOverview extends StatelessWidget {
  const _WorkspaceOverview({
    required this.latestByRepoType,
    required this.wsId,
    required this.onSelectRepo,
  });

  final Map<String, _RepoCheck> latestByRepoType;
  final String wsId;
  final ValueChanged<String> onSelectRepo;

  @override
  Widget build(BuildContext context) {
    final agg = _WorkspaceAgg(latestByRepoType);

    final byRepo = <String, List<_RepoCheck>>{};
    for (final c in latestByRepoType.values) {
      (byRepo[c.repo] ??= []).add(c);
    }

    final repos = byRepo.keys.toList()
      ..sort((a, b) {
        final wa =
            byRepo[a]!.map((c) => c.statusOrder).reduce(math.min);
        final wb =
            byRepo[b]!.map((c) => c.statusOrder).reduce(math.min);
        if (wa != wb) return wa.compareTo(wb);
        return a.compareTo(b);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _SeverityTile(
              label: 'Critical',
              count: agg.critical,
              color: Colors.red.shade700,
            ),
            _SeverityTile(
              label: 'High',
              count: agg.high,
              color: Colors.orange.shade700,
            ),
            _SeverityTile(
              label: 'Moderate',
              count: agg.moderate,
              color: Colors.amber.shade700,
            ),
            _SeverityTile(
              label: 'Low',
              count: agg.low,
              color: Colors.yellow.shade800,
            ),
            _SeverityTile(
              label: 'Repos at risk',
              count: agg.failedRepoCount,
              suffix: 'of ${agg.repoCount}',
              color: agg.failedRepoCount > 0
                  ? Colors.red.shade700
                  : Colors.green.shade700,
            ),
          ],
        ),
        const SizedBox(height: 20),
        Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Repo')),
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('Critical'), numeric: true),
                DataColumn(label: Text('High'), numeric: true),
                DataColumn(label: Text('Moderate'), numeric: true),
                DataColumn(label: Text('Low'), numeric: true),
                DataColumn(label: Text('Last checked')),
                DataColumn(label: Text('')),
              ],
              rows: [
                for (final repo in repos)
                  _buildRepoRow(context, repo, byRepo[repo]!),
              ],
            ),
          ),
        ),
      ],
    );
  }

  DataRow _buildRepoRow(
      BuildContext context, String repo, List<_RepoCheck> checks) {
    final worstOrder =
        checks.map((c) => c.statusOrder).reduce(math.min);
    final statusLabel =
        const ['fail', 'warn', 'pass', 'error'][worstOrder.clamp(0, 3)];
    final critical =
        checks.fold(0, (s, c) => s + c.summary.critical);
    final high = checks.fold(0, (s, c) => s + c.summary.high);
    final moderate =
        checks.fold(0, (s, c) => s + c.summary.moderate);
    final low = checks.fold(0, (s, c) => s + c.summary.low);
    final latest =
        checks.reduce((a, b) => a.createdAt.isAfter(b.createdAt) ? a : b);

    TextStyle? warnStyle(int n, Color c) => n > 0
        ? TextStyle(color: c, fontWeight: FontWeight.w600)
        : null;

    return DataRow(
      cells: [
        DataCell(
          Text(repo,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          onTap: () => onSelectRepo(repo),
        ),
        DataCell(_StatusBadge(status: statusLabel)),
        DataCell(Text(critical.toString(),
            style: warnStyle(critical, Colors.red.shade700))),
        DataCell(Text(high.toString(),
            style: warnStyle(high, Colors.orange.shade700))),
        DataCell(Text(moderate.toString())),
        DataCell(Text(low.toString())),
        DataCell(Text(_timeAgo(latest.createdAt))),
        DataCell(
          TextButton(
            onPressed: () => onSelectRepo(repo),
            child: const Text('View'),
          ),
        ),
      ],
    );
  }
}

// ─── Per-repo detail ──────────────────────────────────────────────────────────

class _RepoDetailView extends StatefulWidget {
  const _RepoDetailView({
    required this.repo,
    required this.wsId,
    required this.latestByType,
  });

  final String repo;
  final String wsId;
  final Map<String, _RepoCheck> latestByType;

  @override
  State<_RepoDetailView> createState() => _RepoDetailViewState();
}

class _RepoDetailViewState extends State<_RepoDetailView> {
  late Stream<QuerySnapshot<Map<String, dynamic>>> _trendStream;

  @override
  void initState() {
    super.initState();
    _trendStream = _buildTrendStream();
  }

  @override
  void didUpdateWidget(_RepoDetailView old) {
    super.didUpdateWidget(old);
    if (old.repo != widget.repo || old.wsId != widget.wsId) {
      _trendStream = _buildTrendStream();
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _buildTrendStream() {
    final ninetyDaysAgo = Timestamp.fromDate(
      DateTime.now().subtract(const Duration(days: 90)),
    );
    // Composite index required: (repo ASC, createdAt ASC)
    return FirebaseFirestore.instance
        .collection('workspaces')
        .doc(widget.wsId)
        .collection('repoChecks')
        .where('repo', isEqualTo: widget.repo)
        .where('createdAt', isGreaterThan: ninetyDaysAgo)
        .orderBy('createdAt')
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    final types = widget.latestByType.keys.toList()..sort();
    final typeColors = {
      for (var i = 0; i < types.length; i++)
        types[i]: _seriesColors[i % _seriesColors.length],
    };

    final allFindings = <_Finding>[
      for (final c in widget.latestByType.values) ...c.findings,
    ]..sort((a, b) => a.severityOrder.compareTo(b.severityOrder));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Trend chart
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Total issues over time (90 days)',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _trendStream,
                  builder: (context, snap) {
                    if (snap.connectionState ==
                        ConnectionState.waiting) {
                      return const SizedBox(
                        height: 160,
                        child: Center(
                            child: CircularProgressIndicator()),
                      );
                    }
                    final trendChecks = (snap.data?.docs ?? [])
                        .map(_RepoCheck.fromDoc)
                        .toList();
                    if (trendChecks.isEmpty) {
                      return const SizedBox(
                        height: 80,
                        child: Center(
                          child: Text(
                            'No trend data in the last 90 days',
                            style:
                                TextStyle(color: Colors.black54),
                          ),
                        ),
                      );
                    }
                    final series = _buildSeries(trendChecks);
                    final colors = {
                      for (final k in series.keys)
                        k: typeColors[k] ??
                            _seriesColors[
                                series.keys.toList().indexOf(k) %
                                    _seriesColors.length],
                    };
                    return _TrendChart(
                        series: series, typeColors: colors);
                  },
                ),
                if (typeColors.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      for (final e in typeColors.entries)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 3,
                              color: e.value,
                            ),
                            const SizedBox(width: 4),
                            Text(e.key,
                                style:
                                    const TextStyle(fontSize: 12)),
                          ],
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Latest results per check type
        if (types.isNotEmpty) ...[
          const Text(
            'Latest results',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final type in types)
                _CheckCard(
                  check: widget.latestByType[type]!,
                  accentColor: typeColors[type]!,
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],

        // Top findings
        if (allFindings.isNotEmpty) ...[
          const Text(
            'Top findings',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < allFindings.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _FindingRow(finding: allFindings[i]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  // Group by type, bucket by day, keep max total per day.
  Map<String, List<_TrendPoint>> _buildSeries(
      List<_RepoCheck> checks) {
    final raw = <String, Map<DateTime, int>>{};
    for (final c in checks) {
      final day = DateTime(
          c.createdAt.year, c.createdAt.month, c.createdAt.day);
      final bucket = raw.putIfAbsent(c.type, () => {});
      bucket[day] =
          math.max(bucket[day] ?? 0, c.summary.effectiveTotal);
    }
    return {
      for (final e in raw.entries)
        e.key: (e.value.entries
            .map((p) => _TrendPoint(p.key, p.value))
            .toList()
          ..sort((a, b) => a.date.compareTo(b.date))),
    };
  }
}

// ─── Trend chart ─────────────────────────────────────────────────────────────

class _TrendPoint {
  const _TrendPoint(this.date, this.total);
  final DateTime date;
  final int total;
}

class _TrendChart extends StatelessWidget {
  const _TrendChart(
      {required this.series, required this.typeColors});
  final Map<String, List<_TrendPoint>> series;
  final Map<String, Color> typeColors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: LayoutBuilder(
        builder: (_, constraints) => CustomPaint(
          size: Size(constraints.maxWidth, 160),
          painter:
              _TrendPainter(series: series, typeColors: typeColors),
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter(
      {required this.series, required this.typeColors});
  final Map<String, List<_TrendPoint>> series;
  final Map<String, Color> typeColors;

  static const double _padL = 44;
  static const double _padR = 8;
  static const double _padT = 8;
  static const double _padB = 24;

  @override
  void paint(Canvas canvas, Size size) {
    if (series.isEmpty) return;

    final chartW = size.width - _padL - _padR;
    final chartH = size.height - _padT - _padB;

    DateTime? minDate, maxDate;
    int maxVal = 1;
    for (final pts in series.values) {
      for (final p in pts) {
        if (minDate == null || p.date.isBefore(minDate)) {
          minDate = p.date;
        }
        if (maxDate == null || p.date.isAfter(maxDate)) {
          maxDate = p.date;
        }
        if (p.total > maxVal) maxVal = p.total;
      }
    }
    if (minDate == null || maxDate == null) return;
    final minDateNN = minDate;
    final maxDateNN = maxDate;
    final spanDays =
        maxDateNN.difference(minDateNN).inDays.toDouble();
    final effectiveSpan = spanDays == 0 ? 1.0 : spanDays;

    final gridPaint = Paint()
      ..color = Colors.black12
      ..strokeWidth = 0.5;
    const labelStyle =
        TextStyle(fontSize: 10, color: Colors.black54);

    // Horizontal grid lines + Y labels
    for (var i = 0; i <= 4; i++) {
      final y = _padT + chartH - (chartH * i / 4);
      canvas.drawLine(
        Offset(_padL, y),
        Offset(_padL + chartW, y),
        gridPaint,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: (maxVal * i / 4).round().toString(),
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset(_padL - tp.width - 4, y - tp.height / 2));
    }

    // Series lines
    for (final entry in series.entries) {
      final pts = entry.value;
      if (pts.isEmpty) continue;
      final color = typeColors[entry.key] ?? Colors.blue;
      final linePaint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final dotPaint = Paint()..color = color;

      Offset? prev;
      for (final p in pts) {
        final dx = _padL +
            (p.date.difference(minDateNN).inDays /
                    effectiveSpan) *
                chartW;
        final dy =
            _padT + chartH - (p.total / maxVal) * chartH;
        final offset = Offset(dx, dy);
        if (prev != null) {
          canvas.drawLine(prev, offset, linePaint);
        }
        canvas.drawCircle(offset, 3, dotPaint);
        prev = offset;
      }
    }

    // X-axis date labels
    String fmt(DateTime d) => '${d.month}/${d.day}';
    final first = TextPainter(
      text:
          TextSpan(text: fmt(minDateNN), style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    first.paint(
        canvas, Offset(_padL, size.height - _padB + 4));

    if (spanDays > 0) {
      final last = TextPainter(
        text:
            TextSpan(text: fmt(maxDateNN), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      last.paint(
        canvas,
        Offset(
            _padL + chartW - last.width,
            size.height - _padB + 4),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.series != series || old.typeColors != typeColors;
}

// ─── Small widgets ────────────────────────────────────────────────────────────

class _SeverityTile extends StatelessWidget {
  const _SeverityTile({
    required this.label,
    required this.count,
    required this.color,
    this.suffix,
  });
  final String label;
  final int count;
  final Color color;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 148,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                    fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment:
                    CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    count.toString(),
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                  if (suffix != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      suffix!,
                      style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SeverityPill extends StatelessWidget {
  const _SeverityPill({required this.severity});
  final String severity;

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(severity);
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        severity.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  const _CheckCard(
      {required this.check, required this.accentColor});
  final _RepoCheck check;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final s = check.summary;
    return SizedBox(
      width: 260,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      check.type,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  _StatusBadge(status: check.status),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  if (s.critical > 0)
                    _SevCount(
                        label: 'Critical',
                        count: s.critical,
                        color: Colors.red.shade700),
                  if (s.high > 0)
                    _SevCount(
                        label: 'High',
                        count: s.high,
                        color: Colors.orange.shade700),
                  if (s.moderate > 0)
                    _SevCount(
                        label: 'Moderate',
                        count: s.moderate,
                        color: Colors.amber.shade700),
                  if (s.low > 0)
                    _SevCount(
                        label: 'Low',
                        count: s.low,
                        color: Colors.yellow.shade800),
                  if (s.critical == 0 &&
                      s.high == 0 &&
                      s.moderate == 0 &&
                      s.low == 0 &&
                      s.passed == null &&
                      s.score == null)
                    const Text('No issues found',
                        style: TextStyle(
                            fontSize: 13,
                            color: Colors.black54)),
                ],
              ),
              if (s.score != null) ...[
                const SizedBox(height: 4),
                Text('Score: ${s.score!.toStringAsFixed(0)}',
                    style: const TextStyle(fontSize: 13)),
              ],
              if (s.passed != null) ...[
                const SizedBox(height: 4),
                Text(
                  s.passed! ? '✓ Passed' : '✗ Failed',
                  style: TextStyle(
                    fontSize: 13,
                    color: s.passed!
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                  ),
                ),
              ],
              if (check.errorMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  check.errorMessage!,
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.red.shade600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                [
                  if (check.toolVersion != null)
                    check.toolVersion!,
                  _timeAgo(check.createdAt),
                ].join('  •  '),
                style: const TextStyle(
                    fontSize: 11, color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SevCount extends StatelessWidget {
  const _SevCount(
      {required this.label,
      required this.count,
      required this.color});
  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
        '$label: $count',
        style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color),
      );
}

class _FindingRow extends StatelessWidget {
  const _FindingRow({required this.finding});
  final _Finding finding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SeverityPill(severity: finding.severity),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (finding.subject != null)
                  Text(
                    finding.subject!,
                    style: const TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 13),
                  ),
                Text(finding.title,
                    style: const TextStyle(fontSize: 13)),
                if (finding.location != null)
                  Text(
                    finding.location!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.black54,
                      fontFamily: 'monospace',
                    ),
                  ),
                if (finding.installedVersion != null ||
                    finding.fixedIn != null)
                  Text(
                    [
                      if (finding.installedVersion != null)
                        'installed: ${finding.installedVersion}',
                      if (finding.fixedIn != null)
                        'fixed in: ${finding.fixedIn}',
                    ].join('  •  '),
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black54),
                  ),
              ],
            ),
          ),
          if (finding.url != null)
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 16),
              tooltip: 'View advisory',
              onPressed: () =>
                  web.window.open(finding.url!, '_blank'),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.health_and_safety_outlined,
                size: 48, color: Colors.black26),
            const SizedBox(height: 16),
            const Text(
              'No repo health checks yet',
              style: TextStyle(
                  fontSize: 16, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            const Text(
              'Checks run automatically when the desktop app syncs.\n'
              'Dependabot scans can be triggered manually once repos are active.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Card(
        color: Colors.red.shade50,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.error_outline,
                  color: Colors.red.shade700),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style:
                      TextStyle(color: Colors.red.shade700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
