import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/repository.dart';

const serverUrlKey = 'server_url';
const serverTokenKey = 'server_token';
const lastSyncKey = 'last_sync';
const lastSyncErrorKey = 'last_sync_error';
String predictionKey(String date) => 'prediction:$date';

class Prediction {
  Prediction({required this.date, required this.probability, required this.model, required this.trainingDays});
  final String date;
  final double probability;
  final String model;
  final int trainingDays;

  factory Prediction.fromJson(Map<String, dynamic> j) => Prediction(
    date: j['date'] as String,
    probability: (j['p_mit_done'] as num).toDouble(),
    model: j['model'] as String,
    trainingDays: j['n_training_days'] as int,
  );

  Map<String, dynamic> toJson() => {
    'date': date,
    'p_mit_done': probability,
    'model': model,
    'n_training_days': trainingDays,
  };
}

/// Pushes local changes to the home server (last-write-wins on updated_at).
/// The phone stays the source of truth: if the server is off, changes simply
/// wait until the next successful push.
class SyncService {
  SyncService(this.repo, {http.Client? client}) : _client = client ?? http.Client();

  final Repository repo;
  final http.Client _client;
  bool _busy = false;

  Future<({Uri base, String token})?> _config() async {
    final url = await repo.getSetting(serverUrlKey);
    final token = await repo.getSetting(serverTokenKey);
    if (url == null || url.isEmpty || token == null || token.isEmpty) return null;
    return (base: Uri.parse(url.endsWith('/') ? url : '$url/'), token: token);
  }

  Map<String, String> _headers(String token) => {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  /// Returns null on success (or when sync isn't configured), else an error.
  Future<String?> push() async {
    final cfg = await _config();
    if (cfg == null || _busy) return null;
    _busy = true;
    try {
      final cursor = await repo.getSetting(syncCursorKey);
      final batch = await repo.pendingChanges(cursor);
      if (!batch.isEmpty) {
        final res = await _client
            .post(
              cfg.base.resolve('sync/push'),
              headers: _headers(cfg.token),
              body: jsonEncode({'rows': batch.rows, 'deletes': batch.deletes}),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}: ${res.body}');
        await repo.markPushed(batch);
      }
      await repo.setSetting(lastSyncKey, isoUtc(DateTime.now()));
      await repo.setSetting(lastSyncErrorKey, '');
      return null;
    } catch (e) {
      final msg = e.toString();
      await repo.setSetting(lastSyncErrorKey, msg);
      return msg;
    } finally {
      _busy = false;
    }
  }

  /// Asks the server's model how likely the MIT on [date] is to get done.
  /// Cached locally so the number still shows when the server is off.
  Future<Prediction?> prediction(String date) async {
    final cached = await repo.getSetting(predictionKey(date));
    final cfg = await _config();
    if (cfg != null) {
      try {
        final res = await _client
            .get(cfg.base.resolve('predictions/$date'), headers: _headers(cfg.token))
            .timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          await repo.setSetting(predictionKey(date), res.body);
          return Prediction.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
        }
      } catch (_) {
        // Fall through to the cached value.
      }
    }
    return cached == null ? null : Prediction.fromJson(jsonDecode(cached) as Map<String, dynamic>);
  }

  /// Pulls everything from the server into an empty phone database.
  Future<int> restore() async {
    final cfg = await _config();
    if (cfg == null) throw StateError('Set the server URL and token first');
    final res = await _client.get(cfg.base.resolve('sync/pull'), headers: _headers(cfg.token));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}: ${res.body}');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final rows = {
      for (final e in (body['rows'] as Map<String, dynamic>).entries)
        e.key: [for (final r in e.value as List) Map<String, Object?>.from(r as Map)],
    };
    return repo.restore(rows);
  }

  /// Null when the server answered with the right token, else a reason a
  /// person can act on.
  Future<String?> ping() async {
    final cfg = await _config();
    if (cfg == null) return 'Enter both the server URL and the token.';
    if (!cfg.base.hasScheme || cfg.base.host.isEmpty) {
      return 'The URL must look like https://your-pc.tailXXXX.ts.net';
    }
    try {
      final res = await _client
          .get(cfg.base.resolve('health'), headers: _headers(cfg.token))
          .timeout(const Duration(seconds: 8));
      return switch (res.statusCode) {
        200 => null,
        401 => 'The server answered but rejected the token. Copy TELOS_TOKEN from deploy/.env exactly.',
        _ => 'The server answered with HTTP ${res.statusCode}. Is something else running on that port?',
      };
    } on TimeoutException {
      return 'No answer within 8 s. Is Tailscale on (phone and PC), and is the PC awake?';
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('Connection refused')) {
        return 'The PC is reachable but nothing is listening on that port. Run "docker compose ps" on the PC.';
      }
      if (msg.contains('Failed host lookup')) return 'Unknown host name. Check the URL, or use the Tailscale IP.';
      if (msg.contains('Network is unreachable') || msg.contains('No route to host')) {
        return 'Cannot reach that address. Turn Tailscale on, on the phone.';
      }
      return msg;
    }
  }

  /// True when [url] would travel outside Tailscale's encrypted tunnel.
  static bool isInsecure(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.scheme != 'http') return false;
    final host = u.host;
    if (host.endsWith('.ts.net') || host == 'localhost' || host == '127.0.0.1') return false;
    final parts = host.split('.').map(int.tryParse).toList();
    // Tailscale addresses are 100.64.0.0/10.
    final isTailscale = parts.length == 4 && parts[0] == 100 && parts[1] != null && parts[1]! >= 64 && parts[1]! < 128;
    return !isTailscale;
  }
}
