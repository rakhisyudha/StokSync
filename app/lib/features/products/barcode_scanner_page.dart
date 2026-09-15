import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../data/local/local_query_providers.dart';

/// Barcode formats used by the product scanner.
///
/// The list intentionally excludes [BarcodeFormat.all] so the camera does not
/// spend work recognizing formats that are not useful for product identifiers.
const List<BarcodeFormat> allowedProductBarcodeFormats = <BarcodeFormat>[
  BarcodeFormat.code128,
  BarcodeFormat.code39,
  BarcodeFormat.code93,
  BarcodeFormat.codabar,
  BarcodeFormat.dataMatrix,
  BarcodeFormat.ean13,
  BarcodeFormat.ean8,
  BarcodeFormat.itf,
  BarcodeFormat.qrCode,
  BarcodeFormat.upcA,
  BarcodeFormat.upcE,
];

typedef BarcodeScannerBuilder =
    Widget Function(
      BuildContext context,
      ValueChanged<BarcodeCapture> onDetect,
    );

typedef MatchedProductPageBuilder = Widget Function(String productId);
typedef CreateProductPageBuilder = Widget Function(String barcode);

/// Returns the first usable value from a scanner capture.
String? extractScannedBarcode(BarcodeCapture capture) {
  for (final barcode in capture.barcodes) {
    final rawValue = normalizeScannedBarcode(barcode.rawValue);
    if (rawValue != null) {
      return rawValue;
    }

    final displayValue = normalizeScannedBarcode(barcode.displayValue);
    if (displayValue != null) {
      return displayValue;
    }
  }
  return null;
}

/// Normalizes scanner values while preserving the barcode's case and contents.
String? normalizeScannedBarcode(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

/// Finds an active local product whose barcode exactly matches [barcode].
ProductInventory? findActiveProductByBarcode(
  Iterable<ProductInventory> products,
  String barcode,
) {
  final normalizedBarcode = normalizeScannedBarcode(barcode);
  if (normalizedBarcode == null) {
    return null;
  }

  for (final inventory in products) {
    final product = inventory.product;
    if (product.deletedAt == null &&
        normalizeScannedBarcode(product.barcode) == normalizedBarcode) {
      return inventory;
    }
  }
  return null;
}

/// Prevents repeated camera frames from handling the same code in one window.
final class BarcodeReadDebouncer {
  BarcodeReadDebouncer({
    this.window = const Duration(milliseconds: 1200),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       assert(window >= Duration.zero);

  final Duration window;
  final DateTime Function() _clock;
  String? _lastBarcode;
  DateTime? _lastAcceptedAt;

  /// Returns true when [barcode] is new or outside the duplicate-read window.
  bool shouldAccept(String barcode) {
    final normalizedBarcode = normalizeScannedBarcode(barcode);
    if (normalizedBarcode == null) {
      return false;
    }

    final now = _clock();
    final elapsed = _lastAcceptedAt == null
        ? null
        : now.difference(_lastAcceptedAt!);
    final isDuplicate =
        _lastBarcode == normalizedBarcode &&
        elapsed != null &&
        elapsed >= Duration.zero &&
        elapsed < window;
    if (isDuplicate) {
      return false;
    }

    _lastBarcode = normalizedBarcode;
    _lastAcceptedAt = now;
    return true;
  }

  /// Allows a cancelled scan flow to accept the next camera read immediately.
  void reset() {
    _lastBarcode = null;
    _lastAcceptedAt = null;
  }
}

/// Local-first barcode scanner route.
class BarcodeScannerPage extends ConsumerStatefulWidget {
  const BarcodeScannerPage({
    super.key,
    required this.matchedProductPageBuilder,
    required this.createProductPageBuilder,
    this.scannerBuilder,
    this.debounceWindow = const Duration(milliseconds: 1200),
  });

  final MatchedProductPageBuilder matchedProductPageBuilder;
  final CreateProductPageBuilder createProductPageBuilder;
  final BarcodeScannerBuilder? scannerBuilder;
  final Duration debounceWindow;

  @override
  ConsumerState<BarcodeScannerPage> createState() => _BarcodeScannerPageState();
}

class _BarcodeScannerPageState extends ConsumerState<BarcodeScannerPage> {
  late final BarcodeReadDebouncer _debouncer = BarcodeReadDebouncer(
    window: widget.debounceWindow,
  );
  var _isHandlingScan = false;

  @override
  Widget build(BuildContext context) {
    final activeProducts = ref.watch(activeProductsProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Scan barcode or QR code'),
            Text(
              'Match or create a local product',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: colorScheme.surfaceTint,
      ),
      body: activeProducts.when(
        loading: () => const _ScannerStatus(
          title: 'Loading local catalog…',
          message: 'The camera will be ready when local products are loaded.',
          icon: Icons.inventory_2_outlined,
        ),
        error: (_, _) => const _ScannerStatus(
          title: 'Local catalog unavailable',
          message: 'Close this screen and try again after local data is ready.',
          icon: Icons.inventory_2_outlined,
          isError: true,
        ),
        data: (products) => _buildScanner(context, products),
      ),
    );
  }

  Widget _buildScanner(
    BuildContext context,
    List<ProductInventory> activeProducts,
  ) {
    final scannerBuilder = widget.scannerBuilder ?? buildDefaultBarcodeScanner;
    return Stack(
      fit: StackFit.expand,
      children: [
        scannerBuilder(
          context,
          (capture) => _handleCapture(capture, activeProducts),
        ),
        Positioned.fill(
          child: _ScannerOverlay(key: const Key('scanner-overlay')),
        ),
      ],
    );
  }

  void _handleCapture(
    BarcodeCapture capture,
    List<ProductInventory> activeProducts,
  ) {
    if (_isHandlingScan) {
      return;
    }

    final barcode = extractScannedBarcode(capture);
    if (barcode == null || !_debouncer.shouldAccept(barcode)) {
      return;
    }

    _isHandlingScan = true;
    unawaited(_handleBarcode(barcode, activeProducts));
  }

  Future<void> _handleBarcode(
    String barcode,
    List<ProductInventory> activeProducts,
  ) async {
    final matchingProduct = findActiveProductByBarcode(activeProducts, barcode);
    if (!mounted) {
      return;
    }

    if (matchingProduct != null) {
      return Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(
          builder: (_) =>
              widget.matchedProductPageBuilder(matchingProduct.product.id),
        ),
      );
    }

    final shouldCreate = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Product not found'),
        content: Text(
          'No active product uses barcode “$barcode”. Create a local product with this barcode?',
        ),
        actions: [
          TextButton(
            key: const Key('cancel-barcode-product-button'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('create-product-from-barcode-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Create product'),
          ),
        ],
      ),
    );

    if (!mounted) {
      return;
    }
    if (shouldCreate != true) {
      _isHandlingScan = false;
      _debouncer.reset();
      return;
    }

    return Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute(
        builder: (_) => widget.createProductPageBuilder(barcode),
      ),
    );
  }
}

/// Provides camera guidance without obscuring the camera preview.
final class _ScannerOverlay extends StatelessWidget {
  const _ScannerOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Semantics(
      container: true,
      label: 'Barcode scanner guidance',
      child: IgnorePointer(
        child: SafeArea(
          minimum: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            children: [
              _ScannerOverlayPanel(
                key: const Key('scanner-overlay-badge'),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.qr_code_scanner, color: colorScheme.primary),
                    const SizedBox(width: 10),
                    Text(
                      'Scan a barcode or QR code',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.86,
                    child: AspectRatio(
                      aspectRatio: 1.7,
                      child: DecoratedBox(
                        key: const Key('scanner-frame'),
                        decoration: BoxDecoration(
                          // Camera guidance uses only theme-derived translucent
                          // surfaces so it stays legible without a second palette.
                          color: colorScheme.surface.withValues(alpha: 0.08),
                          border: Border.all(
                            color: colorScheme.primary,
                            width: 3,
                          ),
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: colorScheme.shadow.withValues(alpha: 0.55),
                              blurRadius: 12,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _ScannerOverlayPanel(
                key: const Key('scanner-instructions'),
                child: Text(
                  'Point the camera at a product barcode or QR code.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ScannerOverlayPanel extends StatelessWidget {
  const _ScannerOverlayPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.94),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: child,
      ),
    );
  }
}

/// Displays the scanner camera and requests permission through mobile_scanner.
class BarcodeCameraView extends StatefulWidget {
  const BarcodeCameraView({super.key, required this.onDetect});

  final ValueChanged<BarcodeCapture> onDetect;

  @override
  State<BarcodeCameraView> createState() => _BarcodeCameraViewState();
}

class _BarcodeCameraViewState extends State<BarcodeCameraView> {
  late final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 500,
    formats: allowedProductBarcodeFormats,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return MobileScanner(
      key: const Key('mobile-scanner'),
      controller: _controller,
      onDetect: widget.onDetect,
      placeholderBuilder: (_) => ColoredBox(
        key: const Key('scanner-camera-placeholder'),
        color: colorScheme.surface,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Starting camera…',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      errorBuilder: (context, error) =>
          BarcodeScannerErrorView(error: error, onRetry: _retry),
    );
  }

  void _retry() {
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }
}

/// Default scanner builder, exposed so the page can be tested with an injected
/// scanner widget without loading a camera platform implementation.
Widget buildDefaultBarcodeScanner(
  BuildContext context,
  ValueChanged<BarcodeCapture> onDetect,
) {
  return BarcodeCameraView(onDetect: onDetect);
}

/// Provides an actionable explanation for camera permission and setup errors.
class BarcodeScannerErrorView extends StatelessWidget {
  const BarcodeScannerErrorView({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final MobileScannerException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ColoredBox(
      color: colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              key: const Key('scanner-error-panel'),
              color: colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.camera_alt_outlined,
                      color: colorScheme.onErrorContainer,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      scannerErrorTitle(error.errorCode),
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      scannerErrorMessage(error.errorCode),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onErrorContainer,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const Key('scanner-retry-button'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String scannerErrorTitle(MobileScannerErrorCode errorCode) {
  return switch (errorCode) {
    MobileScannerErrorCode.permissionDenied => 'Camera permission required',
    MobileScannerErrorCode.unsupported => 'Camera scanning unavailable',
    _ => 'Could not start camera',
  };
}

String scannerErrorMessage(MobileScannerErrorCode errorCode) {
  return switch (errorCode) {
    MobileScannerErrorCode.permissionDenied =>
      'Allow camera access in device settings, then try again.',
    MobileScannerErrorCode.unsupported =>
      'This device does not provide a supported camera scanner.',
    _ => 'Check camera availability and try again.',
  };
}

final class _ScannerStatus extends StatelessWidget {
  const _ScannerStatus({
    required this.title,
    required this.message,
    required this.icon,
    this.isError = false,
  });

  final String title;
  final String message;
  final IconData icon;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final containerColor = isError
        ? colorScheme.errorContainer
        : colorScheme.surfaceContainerHighest;
    final contentColor = isError
        ? colorScheme.onErrorContainer
        : colorScheme.onSurface;

    return ColoredBox(
      color: colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Card(
            key: Key(
              isError ? 'scanner-catalog-error' : 'scanner-catalog-loading',
            ),
            color: containerColor,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isError) ...[
                    CircularProgressIndicator(color: colorScheme.primary),
                    const SizedBox(height: 20),
                  ],
                  Icon(icon, color: contentColor, size: 40),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: contentColor,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isError
                          ? colorScheme.onErrorContainer
                          : colorScheme.onSurfaceVariant,
                    ),
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
