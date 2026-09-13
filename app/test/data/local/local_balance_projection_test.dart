import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';
import 'package:stoksync/core/identity/device_identity.dart';
import 'package:stoksync/data/local/local_balance_projection.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/stoksync_database.dart';

void main() {
  group('LocalBalanceProjection', () {
    test(
      'rebuild matches incremental balances for retained ledger movements',
      () async {
        final harness = _ProjectionHarness();
        addTearDown(harness.close);
        final products = harness.productRepository();
        final movements = harness.movementRepository();
        final coffee = await products.create(
          const ProductDraft(name: 'Coffee'),
        );
        final tea = await products.create(const ProductDraft(name: 'Tea'));

        final at10 = _timing(10);
        final at11 = _timing(11);
        final at12 = _timing(12);
        final at13 = _timing(13);
        final at14 = _timing(14);

        await movements.receive(
          productId: coffee.productId,
          quantity: 10,
          timing: at10,
        );
        await movements.issue(
          productId: coffee.productId,
          quantity: 3,
          timing: at11,
        );
        final adjustment = await movements.adjust(
          productId: coffee.productId,
          delta: 2,
          timing: at12,
        );
        await movements.reverse(
          originalMovementId: adjustment.movementId,
          timing: at13,
        );
        await movements.stocktake(
          productId: coffee.productId,
          countedQuantity: 5,
          timing: at14,
        );
        await movements.issue(
          productId: tea.productId,
          quantity: 4,
          timing: at12,
        );
        await movements.receive(
          productId: tea.productId,
          quantity: 1,
          timing: at10,
        );

        final incrementallyMaintained = await _balancesByProduct(
          harness.database,
        );
        expect(incrementallyMaintained[coffee.productId]!.qty, 5);
        expect(incrementallyMaintained[tea.productId]!.qty, -3);

        await harness.projection.rebuild();

        final rebuilt = await _balancesByProduct(harness.database);
        expect(rebuilt.keys.toSet(), incrementallyMaintained.keys.toSet());
        for (final productId in incrementallyMaintained.keys) {
          expect(
            rebuilt[productId]!.qty,
            incrementallyMaintained[productId]!.qty,
            reason: 'balance for $productId must equal the incremental result',
          );
          expect(
            rebuilt[productId]!.lastMovementAt,
            incrementallyMaintained[productId]!.lastMovementAt,
            reason: 'latest movement for $productId must be retained',
          );
        }
        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          hasLength(7),
        );
      },
    );

    test(
      'rebuild repairs projection rows without movements as zero balances',
      () async {
        final harness = _ProjectionHarness();
        addTearDown(harness.close);
        final product = await harness.productRepository().create(
          const ProductDraft(name: 'Flour'),
        );
        final zeroBalanceProduct = await harness.productRepository().create(
          const ProductDraft(name: 'Salt'),
        );
        final movementTime = DateTime.utc(2026, 9, 13, 10, 30);

        await harness.movementRepository().receive(
          productId: product.productId,
          quantity: 8,
          timing: MovementTiming(occurredAt: movementTime),
        );
        await (harness.database.update(
          harness.database.productBalances,
        )..where((row) => row.productId.equals(product.productId))).write(
          ProductBalancesCompanion(
            qty: const Value(999),
            lastMovementAt: Value(DateTime.utc(2026, 9, 14)),
          ),
        );
        await (harness.database.delete(harness.database.productBalances)..where(
              (row) => row.productId.equals(zeroBalanceProduct.productId),
            ))
            .go();

        await harness.projection.rebuild();

        final rebuilt = await _balancesByProduct(harness.database);
        expect(rebuilt[product.productId]!.qty, 8);
        expect(
          rebuilt[product.productId]!.lastMovementAt!.toUtc(),
          movementTime,
        );
        expect(rebuilt[zeroBalanceProduct.productId]!.qty, 0);
        expect(rebuilt[zeroBalanceProduct.productId]!.lastMovementAt, isNull);
      },
    );
  });
}

MovementTiming _timing(int minute) =>
    MovementTiming(occurredAt: DateTime.utc(2026, 9, 13, 10, minute));

Future<Map<String, ProductBalance>> _balancesByProduct(
  StokSyncDatabase database,
) async {
  final balances = await database.select(database.productBalances).get();
  return {for (final balance in balances) balance.productId: balance};
}

final class _ProjectionHarness {
  _ProjectionHarness()
    : database = StokSyncDatabase(NativeDatabase.memory()),
      identifierGenerator = _QueueIdentifierGenerator(
        List<String>.generate(40, _uuid),
      ),
      deviceIdentity = DeviceIdentity(
        secureStore: _MemorySecureStore(),
        identifierGenerator: _QueueIdentifierGenerator([_deviceId]),
      );

  final StokSyncDatabase database;
  final IdentifierGenerator identifierGenerator;
  final DeviceIdentity deviceIdentity;
  late final LocalBalanceProjection projection = LocalBalanceProjection(
    database: database,
    clock: () => DateTime.utc(2026, 9, 13, 11),
  );

  static const String _deviceId = '0192f200-0000-7000-8000-000000000001';

  LocalProductRepository productRepository() => LocalProductRepository(
    database: database,
    identifierGenerator: identifierGenerator,
    deviceIdentity: deviceIdentity,
    clock: () => DateTime.utc(2026, 9, 13, 11),
  );

  LocalStockMovementRepository movementRepository() =>
      LocalStockMovementRepository(
        database: database,
        identifierGenerator: identifierGenerator,
        deviceIdentity: deviceIdentity,
        clock: () => DateTime.utc(2026, 9, 13, 11),
      );

  Future<void> close() => database.close();
}

String _uuid(int index) {
  return '0192f200-${index.toRadixString(16).padLeft(4, '0')}-7000-8000-'
      '${index.toRadixString(16).padLeft(12, '0')}';
}

final class _QueueIdentifierGenerator implements IdentifierGenerator {
  _QueueIdentifierGenerator(this._identifiers);

  final List<String> _identifiers;

  @override
  String generate() {
    if (_identifiers.isEmpty) {
      throw StateError('No test identifiers remain.');
    }
    return _identifiers.removeAt(0);
  }
}

final class _MemorySecureStore implements SecureKeyValueStore {
  String? value;

  @override
  Future<String?> read(String key) => Future.value(value);

  @override
  Future<void> write({required String key, required String value}) async {
    this.value = value;
  }
}
