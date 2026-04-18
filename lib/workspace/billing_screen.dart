import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../auth/auth_service.dart';

/// Admin-only billing screen. Shows Stripe subscription status, payment
/// method, and invoice history. Provides entry points to start billing and
/// to open the Stripe Customer Portal.
class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  bool _ensuringCustomer = false;
  bool _startingSubscription = false;
  bool _openingPortal = false;
  String? _error;
  String? _notice;

  Future<void> _ensureCustomer() async {
    final wsId = widget.auth.workspaceId;
    if (wsId == null) return;
    setState(() {
      _ensuringCustomer = true;
      _error = null;
      _notice = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('ensureStripeCustomer')
          .call<Map<String, dynamic>>({'workspaceId': wsId});
      setState(() => _notice = 'Stripe customer ready.');
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = e.message ?? 'Could not create Stripe customer.');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _ensuringCustomer = false);
    }
  }

  Future<void> _startSubscription() async {
    final wsId = widget.auth.workspaceId;
    if (wsId == null) return;
    setState(() {
      _startingSubscription = true;
      _error = null;
      _notice = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('startStripeSubscription')
          .call<Map<String, dynamic>>({'workspaceId': wsId});
      setState(() => _notice = 'Subscription activated.');
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'failed-precondition' &&
          (e.message?.contains('ensureStripeCustomer') ?? false)) {
        setState(() => _error =
            'Create the Stripe customer first, then try again.');
      } else {
        setState(() => _error = e.message ?? 'Could not start subscription.');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _startingSubscription = false);
    }
  }

  Future<void> _openPortal() async {
    final wsId = widget.auth.workspaceId;
    if (wsId == null) return;
    setState(() {
      _openingPortal = true;
      _error = null;
      _notice = null;
    });
    try {
      final returnUrl = web.window.location.href;
      final result = await FirebaseFunctions.instance
          .httpsCallable('createBillingPortalSession')
          .call<Map<String, dynamic>>({
        'workspaceId': wsId,
        'returnUrl': returnUrl,
      });
      final url = result.data['url'] as String?;
      if (url != null) {
        web.window.open(url, '_self');
      }
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = e.message ?? 'Could not open billing portal.');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _openingPortal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wsId = widget.auth.workspaceId;
    if (wsId == null) return const SizedBox.shrink();

    final billingStream = FirebaseFirestore.instance
        .doc('workspaces/$wsId/billing/stripe')
        .snapshots();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Billing',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Stripe-managed subscription. Avokaido charges a flat 2% '
            'platform fee on top of your provider AI spend.',
            style: TextStyle(color: Colors.black54, fontSize: 13),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            _Banner(text: _error!, color: Colors.red.shade50, onClose: () {
              setState(() => _error = null);
            }),
          if (_notice != null)
            _Banner(
              text: _notice!,
              color: Colors.green.shade50,
              onClose: () => setState(() => _notice = null),
            ),
          const SizedBox(height: 8),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: billingStream,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final data = snap.data?.data();
              return _SubscriptionCard(
                data: data,
                ensuring: _ensuringCustomer,
                starting: _startingSubscription,
                opening: _openingPortal,
                onEnsureCustomer: _ensureCustomer,
                onStartSubscription: _startSubscription,
                onOpenPortal: _openPortal,
              );
            },
          ),
          const SizedBox(height: 24),
          const Text(
            'Invoices',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _InvoicesList(workspaceId: wsId),
        ],
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({
    required this.data,
    required this.ensuring,
    required this.starting,
    required this.opening,
    required this.onEnsureCustomer,
    required this.onStartSubscription,
    required this.onOpenPortal,
  });

  final Map<String, dynamic>? data;
  final bool ensuring;
  final bool starting;
  final bool opening;
  final VoidCallback onEnsureCustomer;
  final VoidCallback onStartSubscription;
  final VoidCallback onOpenPortal;

  @override
  Widget build(BuildContext context) {
    final customerId = data?['customerId'] as String?;
    final subscriptionId = data?['subscriptionId'] as String?;
    final status = data?['subscriptionStatus'] as String?;
    final hasPaymentMethod = data?['hasPaymentMethod'] as bool? ?? false;
    final cancelAtPeriodEnd = data?['cancelAtPeriodEnd'] as bool? ?? false;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black.withAlpha(20)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusChip(
                status: status,
                hasCustomer: customerId != null,
                hasSubscription: subscriptionId != null,
              ),
              const SizedBox(width: 12),
              if (cancelAtPeriodEnd)
                const Chip(
                  label: Text('Cancels at period end',
                      style: TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Color(0xFFFFF3E0),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _KeyValueRow('Stripe customer', customerId ?? '—'),
          _KeyValueRow('Subscription', subscriptionId ?? '—'),
          _KeyValueRow(
            'Payment method',
            hasPaymentMethod ? 'On file' : 'Not yet added',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (customerId == null)
                FilledButton.icon(
                  onPressed: ensuring ? null : onEnsureCustomer,
                  icon: ensuring
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.person_add_outlined),
                  label: const Text('Create Stripe customer'),
                ),
              if (customerId != null && subscriptionId == null)
                FilledButton.icon(
                  onPressed: starting ? null : onStartSubscription,
                  icon: starting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_circle_outline),
                  label: const Text('Start subscription'),
                ),
              if (customerId != null)
                OutlinedButton.icon(
                  onPressed: opening ? null : onOpenPortal,
                  icon: opening
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.open_in_new),
                  label: Text(hasPaymentMethod
                      ? 'Manage billing in Stripe'
                      : 'Add payment method'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.status,
    required this.hasCustomer,
    required this.hasSubscription,
  });

  final String? status;
  final bool hasCustomer;
  final bool hasSubscription;

  @override
  Widget build(BuildContext context) {
    String label;
    Color bg;
    Color fg;
    if (!hasCustomer) {
      label = 'Not set up';
      bg = Colors.grey.shade200;
      fg = Colors.black87;
    } else if (!hasSubscription) {
      label = 'No subscription';
      bg = const Color(0xFFFFF3E0);
      fg = const Color(0xFFB26A00);
    } else {
      switch (status) {
        case 'active':
        case 'trialing':
          label = status == 'trialing' ? 'Trialing' : 'Active';
          bg = const Color(0xFFE8F5E9);
          fg = const Color(0xFF1B5E20);
          break;
        case 'past_due':
          label = 'Past due';
          bg = const Color(0xFFFFEBEE);
          fg = const Color(0xFFB71C1C);
          break;
        case 'canceled':
        case 'unpaid':
        case 'incomplete':
        case 'incomplete_expired':
          label = status!.replaceAll('_', ' ');
          bg = const Color(0xFFFFEBEE);
          fg = const Color(0xFFB71C1C);
          break;
        default:
          label = status ?? 'Unknown';
          bg = Colors.grey.shade200;
          fg = Colors.black87;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow(this.k, this.v);
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              k,
              style: const TextStyle(
                  color: Colors.black54, fontSize: 13, height: 1.4),
            ),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.color,
    required this.onClose,
  });
  final String text;
  final Color color;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          IconButton(
            iconSize: 18,
            padding: EdgeInsets.zero,
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _InvoicesList extends StatelessWidget {
  const _InvoicesList({required this.workspaceId});
  final String workspaceId;

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('workspaces')
        .doc(workspaceId)
        .collection('invoices')
        .orderBy('periodEnd', descending: true)
        .limit(24)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.black.withAlpha(16)),
            ),
            child: const Text(
              'No invoices yet. They will appear here after the first '
              'monthly billing cycle closes.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          );
        }
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.black.withAlpha(20)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              for (var i = 0; i < docs.length; i++)
                _InvoiceRow(
                  data: docs[i].data(),
                  isLast: i == docs.length - 1,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _InvoiceRow extends StatelessWidget {
  const _InvoiceRow({required this.data, required this.isLast});
  final Map<String, dynamic> data;
  final bool isLast;

  String _formatMoney(num? cents, String? currency) {
    if (cents == null) return '—';
    final amount = cents / 100;
    final sym = switch ((currency ?? 'usd').toLowerCase()) {
      'usd' => '\$',
      'eur' => '€',
      'gbp' => '£',
      _ => '',
    };
    return '$sym${amount.toStringAsFixed(2)}';
  }

  String _formatPeriod(int? start, int? end) {
    String fmt(int s) {
      final d = DateTime.fromMillisecondsSinceEpoch(s * 1000).toUtc();
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }
    if (start == null || end == null) return '—';
    return '${fmt(start)} → ${fmt(end)}';
  }

  @override
  Widget build(BuildContext context) {
    final status = data['status'] as String? ?? 'unknown';
    final amountDueCents = data['amountDueCents'] as num?;
    final amountPaidCents = data['amountPaidCents'] as num?;
    final currency = data['currency'] as String?;
    final hostedUrl = data['hostedInvoiceUrl'] as String?;
    final pdfUrl = data['invoicePdf'] as String?;
    final period = _formatPeriod(
      data['periodStart'] as int?,
      data['periodEnd'] as int?,
    );
    final amount = status == 'paid'
        ? _formatMoney(amountPaidCents, currency)
        : _formatMoney(amountDueCents, currency);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: Colors.black.withAlpha(12))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  period,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    color: status == 'paid'
                        ? const Color(0xFF1B5E20)
                        : status == 'open' || status == 'uncollectible'
                            ? const Color(0xFFB71C1C)
                            : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(
              amount,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: 'Open in Stripe',
            onPressed: hostedUrl == null
                ? null
                : () => web.window.open(hostedUrl, '_blank'),
            icon: const Icon(Icons.open_in_new, size: 18),
          ),
          IconButton(
            tooltip: 'Download PDF',
            onPressed: pdfUrl == null
                ? null
                : () => web.window.open(pdfUrl, '_blank'),
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
          ),
        ],
      ),
    );
  }
}
