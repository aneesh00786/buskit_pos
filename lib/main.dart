import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/config/config_error_app.dart';
import 'core/desktop/instance_blocked_app.dart';
import 'core/platform/landscape_lock.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // TEMPORARY (testing): Android asks for landscape before the first frame
  // (iOS uses Info.plist). No effect on desktop.
  await applyLandscapeLock();
  // Phase 6ZA: on desktop, only one copy of the POS may own this computer's
  // offline storage; another copy shows a blocking screen instead of
  // starting. Android / iOS: no claim (null), the app starts as before.
  final claim = await claimDesktopInstance();
  if (claim != null && !claim.acquired) {
    runApp(InstanceBlockedApp(claim: claim));
    return;
  }
  // Phase 17E: a release build without a valid HTTPS server address shows a
  // configuration error instead of starting (debug builds are unchanged).
  // TEMPORARY (testing): fills a portrait screen in landscape on Android /
  // iOS when the OS will not turn it (iPadOS 26). No effect on desktop.
  runApp(ForcedLandscape(child: rootWidget(release: kReleaseMode)));
}
