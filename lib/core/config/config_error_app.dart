import 'package:flutter/material.dart';

import 'app_config.dart';
import '../../app.dart';

/// Phase 17E — the root widget: the POS app, or (release builds only) a
/// configuration error screen when the build has no valid HTTPS server
/// address. Nothing is sent anywhere in that case.
Widget rootWidget({required bool release, String baseUrl = AppConfig.baseUrl}) {
  final problem = release ? AppConfig.releaseBaseUrlProblem(baseUrl) : null;
  return problem == null ? const PosApp() : ConfigErrorApp(problem: problem);
}

/// Shown instead of the POS when a release build is misconfigured.
class ConfigErrorApp extends StatelessWidget {
  const ConfigErrorApp({super.key, required this.problem});

  final String problem;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ThriveWoo POS',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.settings_ethernet, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'This ThriveWoo POS build is not configured',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Text(problem, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  const Text(
                    "Ask your administrator for a build made with the store server's HTTPS address.",
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
