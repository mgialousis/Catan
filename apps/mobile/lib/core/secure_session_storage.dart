import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Native refresh tokens use Keychain/Android encrypted storage. Web uses SDK storage.
class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage(this.key);
  final String key;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: key);
  @override
  Future<String?> accessToken() => _storage.read(key: key);
  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => _storage.delete(key: key);
}
