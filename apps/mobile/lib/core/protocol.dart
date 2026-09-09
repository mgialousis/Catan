import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:json_schema/json_schema.dart';

class Protocol {
  Protocol(this.document);
  final Map<String, dynamic> document;
  final Map<String, JsonSchema> _validators = {};
  static Future<Protocol> load() async => Protocol(
    jsonDecode(await rootBundle.loadString('assets/protocol/v1.json'))
        as Map<String, dynamic>,
  );
  bool accepts(String name, Object? value) {
    final definitions = document['definitions'] as Map<String, dynamic>;
    if (!definitions.containsKey(name)) return false;
    final schema = _validators.putIfAbsent(
      name,
      () => JsonSchema.create({...document, r'$ref': '#/definitions/$name'}),
    );
    return schema.validate(value, validateFormats: true).isValid;
  }
}

class ServerHello {
  const ServerHello({
    required this.serverTime,
    required this.heartbeatIntervalMs,
  });
  final DateTime serverTime;
  final int heartbeatIntervalMs;
  static ServerHello parse(Object? value, Protocol protocol) {
    if (!protocol.accepts('serverHello', value)) {
      throw const FormatException('Incompatible server response');
    }
    final json = Map<String, dynamic>.from(value as Map);
    return ServerHello(
      serverTime: DateTime.parse(json['serverTime'] as String),
      heartbeatIntervalMs: json['heartbeatIntervalMs'] as int,
    );
  }
}
