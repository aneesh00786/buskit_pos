import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/config/config_error_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Phase 17E: a release build without a valid HTTPS server address shows a
  // configuration error instead of starting (debug builds are unchanged).
  runApp(rootWidget(release: kReleaseMode));
}
