// Development entry point only: flutter run -t lib/preview.dart
// The shipped main.dart never imports this local, in-memory practice transport.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:uuid/uuid.dart';
import 'core/connection.dart';
import 'core/protocol.dart';
import 'game/controller.dart';
import 'game/game_screen.dart';
import 'game/model.dart';

const practiceScenarios = [
  'setup',
  'action',
  'discard',
  'robber',
  'free-roads',
  'waiting',
  'paused',
  'results',
  'victory',
];

class PreviewPort extends GamePort {
  PreviewPort(
    String scenario, {
    String url = const String.fromEnvironment(
      'PRACTICE_URL',
      defaultValue: 'http://127.0.0.1:3001',
    ),
  }) {
    final uri = Uri.parse(url);
    if (uri.scheme != 'http' ||
        !['localhost', '127.0.0.1', '10.0.2.2'].contains(uri.host)) {
      throw ArgumentError('Practice requires a local engine');
    }
    _socket = io.io(
      url,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .enableForceNew()
          .setAuth({'scenario': scenario, 'clientToken': const Uuid().v4()})
          .build(),
    );
    _socket.onConnect((_) => _emit('connected', true));
    _socket.onDisconnect((_) => _emit('connected', false));
    _socket.onConnectError((_) => _emit('connected', false));
    _socket.on('game.snapshot', (value) => _emit('snapshot', value));
    _socket.on('practice.effects', (value) {
      final effects = object(value);
      _emit('activity', (effects['activity'] as List).cast<String>());
      for (final card in effects['draws'] as List) {
        _emit('draw', card as String);
      }
    });
  }
  late io.Socket _socket;
  final _events = StreamController<MapEntry<String, dynamic>>.broadcast();
  bool _closed = false;
  void _emit(String name, dynamic value) {
    if (!_closed) _events.add(MapEntry(name, value));
  }

  @override
  Stream<MapEntry<String, dynamic>> get events => _events.stream;
  @override
  Future<void> connect() async {
    _socket.connect();
  }

  @override
  Future<JsonMap> send(JsonMap command) {
    final reply = Completer<JsonMap>();
    _socket.emitWithAck(
      'practice.command',
      command,
      ack: (value) {
        if (!reply.isCompleted) reply.complete(object(value));
      },
    );
    return reply.future.timeout(const Duration(seconds: 8));
  }

  @override
  void synchronize() => _socket.emit('practice.sync');
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _socket.dispose();
    _events.close();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(PreviewRoot(protocol: await Protocol.load()));
}

class PreviewRoot extends StatefulWidget {
  const PreviewRoot({super.key, required this.protocol});
  final Protocol protocol;
  @override
  State<PreviewRoot> createState() => _PreviewRootState();
}

class _PreviewRootState extends State<PreviewRoot> {
  String scenario = const String.fromEnvironment(
    'PRACTICE_SCENARIO',
    defaultValue: 'setup',
  );
  int generation = 0;
  late PreviewPort port;
  @override
  void initState() {
    super.initState();
    final requested = Uri.tryParse(
      '/?${Uri.base.fragment}',
    )?.queryParameters['practice'];
    if (practiceScenarios.contains(requested)) scenario = requested!;
    port = PreviewPort(scenario);
  }

  void reset(String next) {
    setState(() {
      scenario = next;
      generation++;
      port = PreviewPort(next);
    });
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    key: ValueKey(generation),
    overrides: [
      protocolProvider.overrideWithValue(widget.protocol),
      gamePortProvider.overrideWithValue(port),
    ],
    child: MaterialApp(
      title: 'Island Table practice',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff256f61)),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Local practice'),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Practice scenario',
              initialValue: scenario,
              onSelected: reset,
              itemBuilder: (_) => [
                for (final s in practiceScenarios)
                  PopupMenuItem(
                    value: s,
                    child: Text(words(s.replaceAll('-', '_'))),
                  ),
              ],
            ),
            IconButton(
              tooltip: 'Restart practice',
              onPressed: () => reset(scenario),
              icon: const Icon(Icons.restart_alt),
            ),
          ],
        ),
        body: GameScreen(
          createRematch: () async =>
              Uri.base.replace(fragment: 'practice=setup'),
        ),
      ),
    ),
  );
}
