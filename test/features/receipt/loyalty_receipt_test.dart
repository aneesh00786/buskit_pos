import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/receipt/models/receipt_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const cash = PaymentLine(
  method: TenderMethod.cash,
  amountMilli: 112000,
  tenderedMilli: 120000,
);

CompletedSale sale({Map<String, dynamic>? loyalty}) => CompletedSale.fromJson(
  completedJson(total: 112, tax: 12, subtotal: 100, loyalty: loyalty),
)!;

void main() {
  group('ReceiptFormatter loyalty fields', () {
    test('no loyalty on the sale leaves every loyalty field null', () {
      final r = ReceiptFormatter.build(sale: sale());
      expect(
        (r.pointsEarned, r.cashbackEarned, r.walletRedeemed),
        (null, null, null),
      );
    });

    test(
      'zero earned/redeemed amounts are also left null — no fabricated zeros',
      () {
        final r = ReceiptFormatter.build(
          sale: sale(
            loyalty: loyaltySaleInfoJson(
              pointsEarned: 0,
              cashbackEarned: 0,
              walletRedeemed: 0,
            ),
          ),
        );
        expect(
          (r.pointsEarned, r.cashbackEarned, r.walletRedeemed),
          (null, null, null),
        );
      },
    );

    test('non-zero figures are formatted with the correct sign', () {
      final r = ReceiptFormatter.build(
        sale: sale(
          loyalty: loyaltySaleInfoJson(
            pointsEarned: 120,
            cashbackEarned: 12.5,
            walletRedeemed: 10,
          ),
        ),
      );
      expect(r.pointsEarned, '+120');
      expect(r.cashbackEarned, '+12.50');
      expect(r.walletRedeemed, '-10.00');
    });
  });

  group('ReceiptText loyalty lines', () {
    test(
      'printed lines include points/cashback earned and wallet redeemed',
      () {
        final r = ReceiptFormatter.build(
          sale: sale(
            loyalty: loyaltySaleInfoJson(
              pointsEarned: 120,
              cashbackEarned: 12.5,
              walletRedeemed: 10,
            ),
          ),
        );
        final lines = r.toLines();
        expect(
          lines.any(
            (l) => l.contains('Wallet redeemed') && l.contains('-10.00'),
          ),
          isTrue,
        );
        expect(
          lines.any((l) => l.contains('Points earned') && l.contains('+120')),
          isTrue,
        );
        expect(
          lines.any(
            (l) => l.contains('Cashback earned') && l.contains('+12.50'),
          ),
          isTrue,
        );
      },
    );

    test('no loyalty lines at all when the sale has none', () {
      final r = ReceiptFormatter.build(sale: sale());
      final lines = r.toLines();
      expect(lines.any((l) => l.contains('Points earned')), isFalse);
      expect(lines.any((l) => l.contains('Cashback earned')), isFalse);
      expect(lines.any((l) => l.contains('Wallet redeemed')), isFalse);
    });
  });
}
