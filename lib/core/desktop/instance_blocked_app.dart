import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'single_instance.dart';

/// Phase 6ZA — claims the offline storage for this process on desktop before
/// the POS starts (see [SingleInstanceLock]). Null on Android / iOS (no guard
/// needed). Never throws: anything unexpected is [InstanceOwnership.failed].
Future<InstanceClaim?> claimDesktopInstance({TargetPlatform? platform}) async {
  if (!SingleInstanceLock.appliesTo(platform ?? defaultTargetPlatform))
    return null;
  try {
    return await SingleInstanceLock.acquire(
      await getApplicationSupportDirectory(),
    );
  } catch (e) {
    return InstanceClaim(InstanceOwnership.failed, detail: '$e');
  }
}

/// Shown INSTEAD of the POS when this copy does not own the offline storage.
/// Nothing is opened, read or written, and nothing is sent anywhere.
class InstanceBlockedApp extends StatelessWidget {
  const InstanceBlockedApp({super.key, required this.claim});

  final InstanceClaim claim;

  static const alreadyRunningTitle =
      'ThriveWoo POS is already open on this computer';
  static const alreadyRunningMessage =
      'Only one copy of the POS can run at a time, so sales saved on this computer are never written twice. '
      'Switch to the window that is already open, or close it and start the POS again.';
  static const checkFailedTitle = 'ThriveWoo POS could not start';
  static const checkFailedMessage =
      'The POS could not check its storage on this computer, so it did not start (nothing was changed). '
      'Close any other copy of the POS and try again. If this keeps happening, contact your administrator.';

  @override
  Widget build(BuildContext context) {
    final running = claim.ownership == InstanceOwnership.heldElsewhere;
    return MaterialApp(
      title: 'ThriveWoo POS',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      running ? Icons.filter_none : Icons.error_outline,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      running ? alreadyRunningTitle : checkFailedTitle,
                      key: const Key('instance-blocked-title'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      running ? alreadyRunningMessage : checkFailedMessage,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
