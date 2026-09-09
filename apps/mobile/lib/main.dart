import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/config.dart';
import 'core/connection.dart';
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
    title: 'Island Table',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff256f61)),
      useMaterial3: true,
    ),
    home: const ConnectionScreen(),
  );
}

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});
  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(connectionProvider.notifier).resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(configProvider).isConfigured;
    final connection = ref.watch(connectionProvider);
    final busy = [
      ConnectionStatus.authenticating,
      ConnectionStatus.connecting,
    ].contains(connection.status);
    final connected = connection.status == ConnectionStatus.connected;
    return Scaffold(
      backgroundColor: const Color(0xfff5f2e9),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.landscape_rounded,
                    size: 88,
                    color: Color(0xff256f61),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Island Table',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'A little island. Your favourite people.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Icon(
                            connected ? Icons.check_circle_outline : Icons.wifi,
                            size: 32,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            configured
                                ? connection.message
                                : 'Local setup is needed. Follow the README to configure the app.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          if (busy)
                            const CircularProgressIndicator()
                          else if (!connected)
                            FilledButton.icon(
                              onPressed: configured
                                  ? () => ref
                                        .read(connectionProvider.notifier)
                                        .connect()
                                  : null,
                              icon: const Icon(Icons.arrow_forward),
                              label: const Text('Connect as guest'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Connection preview · Private rooms are coming next.',
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
