class AppConfig {
  const AppConfig({
    required this.apiUrl,
    required this.supabaseUrl,
    required this.anonKey,
  });
  const AppConfig.environment()
    : apiUrl = const String.fromEnvironment('API_URL'),
      supabaseUrl = const String.fromEnvironment('SUPABASE_URL'),
      anonKey = const String.fromEnvironment('SUPABASE_ANON_KEY');
  final String apiUrl;
  final String supabaseUrl;
  final String anonKey;
  bool get isConfigured =>
      apiUrl.isNotEmpty && supabaseUrl.isNotEmpty && anonKey.isNotEmpty;
}
