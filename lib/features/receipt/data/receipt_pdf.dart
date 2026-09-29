import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/receipt.dart';
import '../models/receipt_formatter.dart';

/// A receipt as a PDF sized for an 80 mm roll (monospace text).
Future<Uint8List> buildReceiptPdf(
  ReceiptData receipt, {
  int columns = 42,
}) async {
  final lines = receipt.toLines(columns: columns);
  const fontSize = 8.0;
  const lineHeight = 10.5;
  final doc = pw.Document(title: 'Receipt ${receipt.orderNumber}');
  final font = pw.Font.courier();
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(
        80 * PdfPageFormat.mm,
        lines.length * lineHeight + 40,
        marginAll: 4 * PdfPageFormat.mm,
      ),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            pw.Text(
              l.isEmpty ? ' ' : l,
              style: pw.TextStyle(
                font: font,
                fontSize: fontSize,
                height: lineHeight / fontSize,
              ),
            ),
        ],
      ),
    ),
  );
  return doc.save();
}

/// Hands a PDF to the device's print engine / print queue.
abstract class PdfPrinter {
  /// True if the job was sent, false if the user cancelled the print dialog.
  Future<bool> printPdf(Uint8List bytes, {required String name});
}

class SystemPdfPrinter implements PdfPrinter {
  const SystemPdfPrinter();
  @override
  Future<bool> printPdf(Uint8List bytes, {required String name}) =>
      Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
}
