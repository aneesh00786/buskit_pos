import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../data/report_service.dart';
import '../export/report_csv.dart';
import '../export/report_file_sharer.dart';
import '../models/retail_report.dart';

enum ReportStatus { idle, loading, loaded, error }

/// Phase 14F-B — loads one report at a time for the applied period. Read
/// only. The period is either the store's today (no dates sent — the server
/// decides the business date) or an inclusive From–To range.
class ReportsController extends ChangeNotifier {
  ReportsController(
    this._service, {
    required this.kinds,
    ReportFileSharer? sharer,
  }) : _sharer = sharer ?? const PlatformReportFileSharer(),
       kind = kinds.isEmpty ? ReportKind.products : kinds.first;

  final ReportService _service;
  final ReportFileSharer _sharer;

  /// The reports this staff member may open (others hidden).
  final List<ReportKind> kinds;
  ReportKind kind;

  /// Backend limit on a period, in days.
  static const maxRangeDays = 366;

  DateTime? draftFrom;
  DateTime? draftTo;
  String? _from; // applied
  String? _to;
  String? validation;

  ReportStatus _status = ReportStatus.idle;
  RetailReport? _report;
  ApiException? _error;
  int _generation = 0;
  bool _disposed = false;

  bool _exporting = false;
  String? _exportError;

  ReportStatus get status => _status;
  bool get exporting => _exporting;
  String? get exportError => _exportError;

  /// Phase 14F-C — only a loaded report with rows can be exported.
  bool get canExport =>
      _status == ReportStatus.loaded &&
      _report != null &&
      !_report!.isEmpty &&
      !_exporting;
  RetailReport? get report => _report;
  ApiException? get error => _error;
  String? get appliedFrom => _from;
  String? get appliedTo => _to;

  static String iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void setFrom(DateTime? d) {
    draftFrom = d;
    validation = null;
    _notify();
  }

  void setTo(DateTime? d) {
    draftTo = d;
    validation = null;
    _notify();
  }

  /// Validates the drafted dates and reloads; an invalid range is refused
  /// with a message and NO request.
  Future<void> apply() async {
    final f = draftFrom;
    final t = draftTo;
    if ((f == null) != (t == null)) {
      validation = 'Choose both a From and a To date (or neither for today).';
      _notify();
      return;
    }
    if (f != null && t != null) {
      // UTC calendar dates: a daylight-saving change must not shift the count.
      final from = DateTime.utc(f.year, f.month, f.day);
      final to = DateTime.utc(t.year, t.month, t.day);
      if (to.isBefore(from)) {
        validation = 'The To date must not be before the From date.';
        _notify();
        return;
      }
      if (to.difference(from).inDays + 1 > maxRangeDays) {
        validation = 'Choose a period of at most $maxRangeDays days.';
        _notify();
        return;
      }
      _from = iso(from);
      _to = iso(to);
    } else {
      _from = null;
      _to = null;
    }
    validation = null;
    await load();
  }

  /// Back to the store's today.
  Future<void> today() {
    draftFrom = null;
    draftTo = null;
    return apply();
  }

  Future<void> select(ReportKind k) {
    if (k == kind && _status != ReportStatus.error) return Future.value();
    kind = k;
    return load();
  }

  Future<void> load() async {
    final gen = ++_generation;
    _status = ReportStatus.loading;
    _error = null;
    _exportError = null;
    _report = null;
    _notify();
    try {
      final r = await _service.fetch(kind, from: _from, to: _to);
      if (gen != _generation) return;
      _report = r;
      _status = ReportStatus.loaded;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _error = e.withMessage(describeApiError(e));
      _status = ReportStatus.error;
    } finally {
      if (gen == _generation) _notify();
    }
  }

  /// Phase 14F-C — exports the report ON SCREEN (the selected tab and the
  /// applied period) as CSV: the server's rows and totals, unchanged. No new
  /// request, nothing recalculated. Returns true when handed to the share
  /// sheet.
  Future<bool> exportCsv({Rect? origin}) async {
    final r = _report;
    if (!canExport || r == null) return false;
    final k = kind;
    _exporting = true;
    _exportError = null;
    _notify();
    try {
      await _sharer.share(
        filename: reportFileName(k, r),
        bytes: reportCsvBytes(k, r),
        mimeType: 'text/csv',
        origin: origin,
      );
      return true;
    } catch (e) {
      _exportError = e is ReportShareUnavailable
          ? e.toString()
          : 'The CSV could not be exported. Please try again.';
      return false;
    } finally {
      _exporting = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
