/// Phase 18A — hardware-neutral weighing scale: one reading and its exact
/// conversion to a sale weight.
///
/// Units. A reading carries its value as exact integer thousandths of its own
/// [ScaleUnit] ([ScaleReading.valueMilli]: 1250 g -> 1250000, 1.25 kg ->
/// 1250). A POS sale weight is in KILOGRAMS with at most 3 decimal places
/// (backend services/pos/posQuantity.js, lib/core/utils/quantity.dart), i.e.
/// whole grams. A reading is converted exactly or refused — never rounded.
/// Pounds and ounces have no exact gram value, so they are refused (enter the
/// weight manually) until a business rule for them exists.
library;

import '../../core/utils/quantity.dart';

enum ScaleUnit { gram, kilogram, pound, ounce }

extension ScaleUnitLabel on ScaleUnit {
  String get symbol => switch (this) {
    ScaleUnit.gram => 'g',
    ScaleUnit.kilogram => 'kg',
    ScaleUnit.pound => 'lb',
    ScaleUnit.ounce => 'oz',
  };
}

/// What the scale reports alongside (or instead of) a weight.
enum ScaleReadingStatus {
  /// Settled weight.
  stable,

  /// Still moving.
  unstable,

  /// Above the scale's capacity.
  overload,

  /// Below zero / under range.
  underload,

  /// The scale sent something that is not a weight.
  invalid,
}

class ScaleReading {
  const ScaleReading({
    required this.valueMilli,
    required this.unit,
    required this.status,
    required this.at,
  });

  /// Exact thousandths of [unit]; null when the scale sent no usable number.
  final int? valueMilli;
  final ScaleUnit unit;
  final ScaleReadingStatus status;

  /// When the reading arrived (used to ignore stale readings).
  final DateTime at;

  /// For drivers that receive decimal text ("1.250", "250", "-0.004"): the
  /// value is parsed exactly; more than 3 decimal places in [unit] (or
  /// anything that is not a decimal number) gives an [ScaleReadingStatus.invalid]
  /// reading — never a rounded one.
  factory ScaleReading.fromText(
    String text, {
    required ScaleUnit unit,
    required bool stable,
    required DateTime at,
  }) {
    final m = RegExp(r'^(-?)(\d{1,9})(?:\.(\d{1,3}))?$')
        .firstMatch(text.trim());
    if (m == null) {
      return ScaleReading(
        valueMilli: null,
        unit: unit,
        status: ScaleReadingStatus.invalid,
        at: at,
      );
    }
    final milli =
        int.parse(m.group(2)!) * 1000 +
        int.parse((m.group(3) ?? '').padRight(3, '0'));
    return ScaleReading(
      valueMilli: m.group(1) == '-' ? -milli : milli,
      unit: unit,
      status: stable ? ScaleReadingStatus.stable : ScaleReadingStatus.unstable,
      at: at,
    );
  }

  bool get isStable => status == ScaleReadingStatus.stable;

  /// "1.250 kg", "250.000 g" — the reading as the scale reported it.
  String get displayText {
    final v = valueMilli;
    if (v == null) return '—';
    final sign = v < 0 ? '-' : '';
    final a = v.abs();
    return '$sign${a ~/ 1000}.${(a % 1000).toString().padLeft(3, '0')} ${unit.symbol}';
  }
}

/// A reading converted for a WEIGHT sale line: [kgMilli] (exact thousandths
/// of a kilogram) when usable, otherwise [problem] (cashier-facing).
class ScaleSaleWeight {
  const ScaleSaleWeight._(this.kgMilli, this.problem);
  const ScaleSaleWeight.ok(int kgMilli) : this._(kgMilli, null);
  const ScaleSaleWeight.refused(String problem) : this._(null, problem);

  final int? kgMilli;
  final String? problem;
  bool get isOk => kgMilli != null;

  /// The quantity to use, in the same form manual entry produces.
  num? get quantity => kgMilli == null ? null : quantityFromMilli(kgMilli!);

  /// The text manual entry would show ("1.250").
  String? get text =>
      kgMilli == null ? null : formatQuantity(quantity!, weight: true);
}

/// Converts [reading] for a WEIGHT sale line, or says why it cannot be used.
/// Only a stable, positive reading in an exactly convertible unit within the
/// POS weight range is accepted.
ScaleSaleWeight saleWeightFrom(ScaleReading? reading) {
  if (reading == null) {
    return const ScaleSaleWeight.refused('No reading from the scale.');
  }
  switch (reading.status) {
    case ScaleReadingStatus.unstable:
      return const ScaleSaleWeight.refused('Waiting for the weight to settle.');
    case ScaleReadingStatus.overload:
      return const ScaleSaleWeight.refused('The scale is overloaded.');
    case ScaleReadingStatus.underload:
      return const ScaleSaleWeight.refused(
        'The scale reads below zero. Zero the scale.',
      );
    case ScaleReadingStatus.invalid:
      return const ScaleSaleWeight.refused(
        'The scale sent an invalid reading.',
      );
    case ScaleReadingStatus.stable:
      break;
  }
  final v = reading.valueMilli;
  if (v == null) {
    return const ScaleSaleWeight.refused('The scale sent an invalid reading.');
  }
  if (v <= 0) {
    return const ScaleSaleWeight.refused(
      'Place the item on the scale (the weight is zero).',
    );
  }
  final int kgMilli;
  switch (reading.unit) {
    case ScaleUnit.kilogram:
      kgMilli = v;
    case ScaleUnit.gram:
      // thousandths of a gram -> thousandths of a kilogram (= grams).
      if (v % 1000 != 0) {
        return const ScaleSaleWeight.refused(
          'The scale weight has more than 3 decimal places in kg. Enter the weight manually.',
        );
      }
      kgMilli = v ~/ 1000;
    case ScaleUnit.pound:
    case ScaleUnit.ounce:
      return ScaleSaleWeight.refused(
        'The scale reports in ${reading.unit.symbol}; only g and kg are supported. Enter the weight in kg manually.',
      );
  }
  if (kgMilli > maxQuantityMilli) {
    return const ScaleSaleWeight.refused(
      'The weight is above the POS maximum.',
    );
  }
  if (quantityError('WEIGHT', quantityFromMilli(kgMilli)) != null) {
    return const ScaleSaleWeight.refused(
      'The scale weight cannot be used. Enter the weight manually.',
    );
  }
  return ScaleSaleWeight.ok(kgMilli);
}
