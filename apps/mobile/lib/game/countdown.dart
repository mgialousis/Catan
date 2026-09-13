import 'dart:async';
import 'package:flutter/material.dart';

/// Uses elapsed monotonic time. Changing the phone's wall clock cannot change a turn.
class EstimatedServerClock {
  EstimatedServerClock(this.elapsedMilliseconds);
  final int Function() elapsedMilliseconds;
  int? _serverMilliseconds;
  int _observedAt = 0;
  int? get now => _serverMilliseconds == null
      ? null
      : _serverMilliseconds! + elapsedMilliseconds() - _observedAt;
  void observe(String serverTime) {
    final incoming = DateTime.parse(serverTime).millisecondsSinceEpoch;
    final existing = now;
    _serverMilliseconds = existing != null && existing > incoming
        ? existing
        : incoming;
    _observedAt = elapsedMilliseconds();
  }

  int secondsLeft(String deadline) =>
      ((DateTime.parse(deadline).millisecondsSinceEpoch - now!) / 1000)
          .ceil()
          .clamp(0, 180);
}

class GameCountdown extends StatefulWidget {
  const GameCountdown({
    super.key,
    required this.serverTime,
    required this.deadline,
    required this.discard,
  });
  final String serverTime, deadline;
  final bool discard;
  @override
  State<GameCountdown> createState() => _GameCountdownState();
}

class _GameCountdownState extends State<GameCountdown> {
  final _elapsed = Stopwatch()..start();
  late final EstimatedServerClock _clock;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _clock = EstimatedServerClock(() => _elapsed.elapsedMilliseconds)
      ..observe(widget.serverTime);
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(GameCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverTime != oldWidget.serverTime) {
      _clock.observe(widget.serverTime);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _elapsed.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = _clock.secondsLeft(widget.deadline);
    return Text(
      left == 0
          ? 'Time is up · waiting for the server'
          : '${widget.discard ? 'Your discard' : 'Turn time'} · ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}',
      key: const Key('game-countdown'),
      style: TextStyle(
        fontWeight: FontWeight.w600,
        color: left <= 10 ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}
