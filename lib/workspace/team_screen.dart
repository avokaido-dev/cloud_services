import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_service.dart';

/// Invite + list + revoke teammates for the current workspace.
class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  final _emailController = TextEditingController();
  final _nameController = TextEditingController();
  bool _sending = false;
  bool _loading = true;
  String? _error;
  String? _revokingInviteId;
  _InviteResult? _lastInvite;
  List<_PendingInvite> _pendingInvites = const [];
  List<_Member> _members = const [];

  @override
  void initState() {
    super.initState();
    _refreshAll();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    setState(() => _loading = true);
    if (!widget.auth.isOrgAdmin) {
      setState(() {
        _members = const [];
        _pendingInvites = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    try {
      final membersResult = await FirebaseFunctions.instance
          .httpsCallable('listWorkspaceMembers')
          .call<Map<String, dynamic>>();
      final rawMembers = (membersResult.data['members'] as List?) ?? const [];
      final rawInvites =
          ((await FirebaseFunctions.instance
                      .httpsCallable('listWorkspaceInvites')
                      .call<Map<String, dynamic>>())
                  .data['invites']
              as List?) ??
          const [];

      _members = rawMembers
          .map((m) => _Member.fromJson(Map<String, dynamic>.from(m as Map)))
          .toList();
      _pendingInvites = rawInvites
          .map(
            (i) => _PendingInvite.fromJson(Map<String, dynamic>.from(i as Map)),
          )
          .toList();
      _error = null;
    } on FirebaseFunctionsException catch (e) {
      _error = e.message ?? e.code;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _invite() async {
    final email = _emailController.text.trim();
    final invitedName = _nameController.text.trim();
    final wsId = widget.auth.workspaceId;
    if (email.isEmpty || invitedName.isEmpty || wsId == null) return;
    setState(() {
      _sending = true;
      _error = null;
      _lastInvite = null;
    });
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('sendInvite')
          .call<Map<String, dynamic>>({
            'email': email,
            'workspaceId': wsId,
            'invitedName': invitedName,
            'inviterName':
                widget.auth.user?.displayName?.trim().isNotEmpty == true
                ? widget.auth.user!.displayName!.trim()
                : widget.auth.user?.email,
          });
      setState(() {
        _lastInvite = _InviteResult(
          email: email,
          invitedName: invitedName,
          signInLink: result.data['signInLink'] as String?,
          newlyCreated: result.data['newlyCreated'] as bool? ?? false,
        );
        _emailController.clear();
        _nameController.clear();
      });
      await _refreshAll();
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _remove(_Member member) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from workspace?'),
        content: Text(
          '${member.email ?? member.uid} will lose access to this workspace.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFunctions.instance
          .httpsCallable('removeWorkspaceMember')
          .call<Map<String, dynamic>>({'uid': member.uid});
      await _refreshAll();
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = e.message ?? e.code);
    }
  }

  Future<void> _revokeInvite(_PendingInvite invite) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke invite?'),
        content: Text(
          'The invitation for ${invite.invitedNameOrEmail} will stop working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _revokingInviteId = invite.inviteId;
      _error = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('revokeWorkspaceInvite')
          .call<Map<String, dynamic>>({'inviteId': invite.inviteId});
      await _refreshAll();
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } finally {
      if (mounted) setState(() => _revokingInviteId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManage = widget.auth.isOrgAdmin;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Team',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          if (canManage) ...[_buildInviteCard(), const SizedBox(height: 24)],
          Row(
            children: [
              const Text(
                'People',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _refreshAll,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: !canManage
                ? const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Only organisation admins can manage team members and invites.',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ),
                  )
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      _buildPendingInvitesSection(),
                      const SizedBox(height: 24),
                      _buildMembersSection(canManage),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildInviteCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Invite a teammate',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'We create a passwordless sign-in link, send it through '
              'SendGrid, and keep the invite revocable for 7 days.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Invited person name',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.emailAddress,
                    onSubmitted: (_) => _invite(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _sending ? null : _invite,
                  child: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send invite'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            if (_lastInvite != null) ...[
              const SizedBox(height: 12),
              _InviteResultCard(result: _lastInvite!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPendingInvitesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Pending invites',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Text(
              '${_pendingInvites.length}',
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_pendingInvites.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No pending invites right now.',
                style: TextStyle(color: Colors.black54),
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: _pendingInvites
                  .map(
                    (invite) => Column(
                      children: [
                        ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.mark_email_unread_outlined),
                          ),
                          title: Text(invite.invitedNameOrEmail),
                          subtitle: Text(
                            '${invite.email}\n'
                            'Organisation: ${invite.organisationName}\n'
                            'Invited by: ${invite.inviterName ?? 'Unknown'}\n'
                            'Expires: ${invite.expiresAtFormatted()}',
                          ),
                          isThreeLine: true,
                          trailing: TextButton.icon(
                            onPressed: _revokingInviteId == invite.inviteId
                                ? null
                                : () => _revokeInvite(invite),
                            icon: _revokingInviteId == invite.inviteId
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.cancel_outlined,
                                    color: Colors.red,
                                  ),
                            label: const Text('Revoke'),
                          ),
                        ),
                        if (invite != _pendingInvites.last)
                          const Divider(height: 1),
                      ],
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
      ],
    );
  }

  Widget _buildMembersSection(bool canManage) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Members',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Text(
              '${_members.length}',
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_members.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Just you so far.',
                style: TextStyle(color: Colors.black54),
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: _members
                  .map(
                    (member) => Column(
                      children: [
                        ListTile(
                          leading: CircleAvatar(
                            child: Icon(
                              member.workspaceRole == 'admin'
                                  ? Icons.shield_outlined
                                  : Icons.person_outline,
                              size: 20,
                            ),
                          ),
                          title: Row(
                            children: [
                              Flexible(child: Text(member.email ?? member.uid)),
                              if (member.uid == widget.auth.user?.uid) ...[
                                const SizedBox(width: 8),
                                const Chip(
                                  label: Text(
                                    'You',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                              if (member.workspaceRole == 'admin') ...[
                                const SizedBox(width: 8),
                                const Chip(
                                  label: Text(
                                    'Org admin',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ],
                          ),
                          subtitle: member.joinedAt == null
                              ? null
                              : Text('Joined ${member.joinedAtFormatted()}'),
                          trailing:
                              (canManage && member.uid != widget.auth.user?.uid)
                              ? IconButton(
                                  tooltip: 'Remove',
                                  onPressed: () => _remove(member),
                                  icon: const Icon(
                                    Icons.person_remove,
                                    color: Colors.red,
                                  ),
                                )
                              : null,
                        ),
                        if (member != _members.last) const Divider(height: 1),
                      ],
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
      ],
    );
  }
}

class _InviteResult {
  const _InviteResult({
    required this.email,
    required this.invitedName,
    required this.signInLink,
    required this.newlyCreated,
  });

  final String email;
  final String invitedName;
  final String? signInLink;
  final bool newlyCreated;
}

class _InviteResultCard extends StatelessWidget {
  const _InviteResultCard({required this.result});
  final _InviteResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.mark_email_read_outlined,
                size: 18,
                color: Colors.green,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.newlyCreated
                      ? 'Invited ${result.invitedName} (${result.email}). '
                            'A Firebase account was created and the SendGrid '
                            'invite email was queued.'
                      : 'Invited ${result.invitedName} (${result.email}). '
                            'They already had a Firebase account, and the '
                            'SendGrid invite email was queued.',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          if (result.signInLink != null) ...[
            const SizedBox(height: 12),
            const Text(
              'Manual fallback link',
              style: TextStyle(fontSize: 11.5, color: Colors.black54),
            ),
            const SizedBox(height: 6),
            SelectableText(
              result.signInLink!,
              style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
              maxLines: 3,
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: result.signInLink!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Sign-in link copied')),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy link'),
            ),
          ],
        ],
      ),
    );
  }
}

class _PendingInvite {
  const _PendingInvite({
    required this.inviteId,
    required this.email,
    this.invitedName,
    this.inviterName,
    required this.organisationName,
    this.createdAt,
    this.expiresAt,
  });

  final String inviteId;
  final String email;
  final String? invitedName;
  final String? inviterName;
  final String organisationName;
  final int? createdAt;
  final int? expiresAt;

  String get invitedNameOrEmail =>
      invitedName?.trim().isNotEmpty == true ? invitedName!.trim() : email;

  factory _PendingInvite.fromJson(Map<String, dynamic> json) => _PendingInvite(
    inviteId: json['inviteId'] as String,
    email: json['email'] as String,
    invitedName: json['invitedName'] as String?,
    inviterName: json['inviterName'] as String?,
    organisationName: json['organisationName'] as String? ?? 'Avokaido',
    createdAt: (json['createdAt'] as num?)?.toInt(),
    expiresAt: (json['expiresAt'] as num?)?.toInt(),
  );

  String expiresAtFormatted() => _formatDate(expiresAt);
}

class _Member {
  const _Member({
    required this.uid,
    this.email,
    this.workspaceRole = 'member',
    this.joinedAt,
  });

  final String uid;
  final String? email;
  final String workspaceRole;
  final int? joinedAt;

  factory _Member.fromJson(Map<String, dynamic> json) => _Member(
    uid: json['uid'] as String,
    email: json['email'] as String?,
    workspaceRole: (json['workspaceRole'] as String?) ?? 'member',
    joinedAt: (json['joinedAt'] as num?)?.toInt(),
  );

  String joinedAtFormatted() => _formatDate(joinedAt);
}

String _formatDate(int? millis) {
  if (millis == null) return '—';
  return DateTime.fromMillisecondsSinceEpoch(
    millis,
  ).toLocal().toIso8601String().split('T').first;
}
