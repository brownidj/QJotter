import 'package:flutter/material.dart';

/// A compact sync signal with accessible details and a pending-record count.
class SyncIndicator extends StatelessWidget {
  const SyncIndicator({
    super.key,
    required this.pendingRecords,
    required this.confirmed,
    required this.status,
  });

  final int pendingRecords;
  final bool confirmed;
  final String status;

  @override
  Widget build(BuildContext context) {
    final pending = pendingRecords > 0;
    final description = pending
        ? '$pendingRecords ${pendingRecords == 1 ? 'note' : 'notes'} waiting to sync with the server.\n$status'
        : confirmed
        ? 'All notes synced with the server'
        : 'Sync with the server has not been confirmed.\n$status';
    final color = pending
        ? const Color(0xFFF59E0B)
        : confirmed
        ? const Color(0xFF22A447)
        : const Color(0xFF858E8A);
    return Tooltip(
      message: description,
      child: Semantics(
        label: 'Server sync',
        value: description,
        liveRegion: true,
        excludeSemantics: true,
        child: Center(
          child: AnimatedContainer(
            key: const ValueKey('server-sync-led'),
            duration: const Duration(milliseconds: 150),
            width: pending ? 32 : 10,
            height: pending ? 32 : 10,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 4),
              ],
            ),
            child: pending
                ? Text(
                    '$pendingRecords',
                    style: const TextStyle(
                      color: Color(0xFF422006),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
