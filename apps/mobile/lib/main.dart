import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/config.dart';
import 'core/connection.dart';
import 'lobby/lobby_screen.dart';
import 'core/protocol.dart';
import 'core/secure_session_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const config = AppConfig.environment();
  try {
    final protocol = await Protocol.load();
    if (config.isConfigured) {
      await Supabase.initialize(
        url: config.supabaseUrl,
        publishableKey: config.anonKey,
        debug: false,
        authOptions: FlutterAuthClientOptions(
          localStorage: kIsWeb
              ? null
              : SecureSessionStorage(
                  'island-table-${Uri.parse(config.supabaseUrl).host}-session',
                ),
        ),
      );
    }
    runApp(
      ProviderScope(
        overrides: [protocolProvider.overrideWithValue(protocol)],
        child: const IslandTableApp(),
      ),
    );
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'Unable to start. Check local configuration and reopen the app.',
            ),
          ),
        ),
      ),
    );
  }
}

class IslandTableApp extends StatelessWidget {
  const IslandTableApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Catan',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff256f61)),
      useMaterial3: true,
    ),
    home: const LobbyScreen(),
  );
}
