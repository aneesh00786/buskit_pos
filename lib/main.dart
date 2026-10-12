import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/config/config_error_app.dart';
import 'core/desktop/instance_blocked_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  runApp(rootWidget(release: kReleaseMode));
}
