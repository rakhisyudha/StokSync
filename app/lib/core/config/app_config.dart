/// Runtime configuration for the Flutter client.
///
/// The API URL is supplied with `--dart-define=STOKSYNC_API_BASE_URL=...` in
/// deployed builds. The loopback default is convenient for desktop/iOS
/// simulator development; Android emulators should use `10.0.2.2` instead.
final class StokSyncAppConfig {
  StokSyncAppConfig._();

  static const apiBaseUrlEnvironmentKey = 'STOKSYNC_API_BASE_URL';
  static const _defaultApiBaseUrl = 'http://127.0.0.1:8080';

  static Uri get apiBaseUri {
    const configured = String.fromEnvironment(
      apiBaseUrlEnvironmentKey,
      defaultValue: _defaultApiBaseUrl,
    );
    final value = configured.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw StateError(
        '$apiBaseUrlEnvironmentKey must be an absolute HTTP or HTTPS URL',
      );
    }
    return uri;
  }
}
