import 'package:connectivity_plus/connectivity_plus.dart';

/// App-side adapter exposing OS connectivity notifications as wakeup hints.
abstract interface class ConnectivityHintSource {
  Stream<Object?> get hints;
}

/// Wraps `connectivity_plus` without treating its values as proof of service
/// reachability. The coordinator performs the actual health check afterward.
final class ConnectivityPlusHintSource implements ConnectivityHintSource {
  ConnectivityPlusHintSource({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Stream<Object?> get hints {
    return _connectivity.onConnectivityChanged.map<Object?>((event) => event);
  }
}
