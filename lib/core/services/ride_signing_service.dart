import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ride_file/ride_telemetry_codec.dart';
import '../diagnostics/diagnostic_log.dart';

/// This phone's ride signing key as the native side reports it.
@immutable
class RideSigningKey {
  /// Creates a key description.
  const RideSigningKey({required this.keyId, required this.publicKey});

  /// First 16 hex characters of the SHA-256 of [publicKey]'s DER (display
  /// and logs only; never compared).
  final String keyId;

  /// Base64 X.509 SubjectPublicKeyInfo DER of the key.
  final String publicKey;
}

/// Dart side of the `com.example.motocam/integrity` channel: this phone's
/// Android Keystore key that signs ride envelopes (see `RideSigner.kt`).
///
/// Every call returns `null` instead of failing: in tests
/// (`MissingPluginException`), on a `PlatformException`, on a malformed
/// reply and after [timeout]. Use it on the UI isolate only.
class RideSigningService {
  /// Creates a service on [channel] with a per-call [timeout]. The app uses
  /// [instance].
  RideSigningService({
    MethodChannel channel = const MethodChannel(channelName),
    this.timeout = const Duration(seconds: 5),
  }) : _channel = channel;

  /// The app's service.
  static final RideSigningService instance = RideSigningService();

  /// Name of the integrity method channel.
  static const String channelName = 'com.example.motocam/integrity';

  final MethodChannel _channel;

  /// How long one channel call may take before it counts as failed.
  final Duration timeout;

  Future<RideSigningKey?>? _sessionKey;

  /// This phone's signing key (the native side creates it on first use),
  /// or `null` when it cannot be read.
  Future<RideSigningKey?> getSigningKey() async {
    final reply = await _invoke('getSigningKey', null);
    final keyId = reply?['keyId'];
    final publicKey = reply?['publicKey'];
    if (keyId is! String ||
        publicKey is! String ||
        decodeStrictBase64(publicKey) == null) {
      return null;
    }
    return RideSigningKey(keyId: keyId, publicKey: publicKey);
  }

  /// [getSigningKey], read once per app session: the first successful
  /// answer is kept, a failure is retried on the next call.
  Future<RideSigningKey?> sessionSigningKey() {
    return _sessionKey ??= getSigningKey().then((key) {
      if (key == null) {
        _sessionKey = null;
      }
      return key;
    });
  }

  /// Signs [payloadHash] (64 lowercase hex characters), or returns `null`.
  /// A [RidePayloadSigner].
  Future<RideSignatureData?> signPayloadHash(String payloadHash) async {
    final reply = await _invoke('signPayloadHash', <String, Object?>{
      'payloadHash': payloadHash,
    });
    if (reply == null) {
      return null;
    }
    final alg = reply['alg'];
    final keyId = reply['keyId'];
    final publicKey = reply['publicKey'];
    final sig = reply['sig'];
    if (alg is! String ||
        keyId is! String ||
        publicKey is! String ||
        sig is! String) {
      return null;
    }
    return RideSignatureData(
      alg: alg,
      keyId: keyId,
      publicKey: publicKey,
      sig: sig,
    );
  }

  Future<Map<dynamic, dynamic>?> _invoke(
    String method,
    Map<String, Object?>? arguments,
  ) async {
    try {
      return await _channel
          .invokeMethod<Map<dynamic, dynamic>>(method, arguments)
          .timeout(timeout);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrintError('signing', 'Ride signing: $method failed: ${error.code}');
      return null;
    } on TimeoutException {
      debugPrintError('signing', 'Ride signing: $method timed out');
      return null;
    } catch (error) {
      debugPrintError('signing', 'Ride signing: $method failed: $error');
      return null;
    }
  }
}

/// What [SignedRideRegistry] holds for one key: the registered
/// `rideSessionId`s and the segment file names (no directory) of those
/// rides.
typedef SignedRideRegistrations = ({
  Set<String> rideSessionIds,
  Set<String> segmentFileNames,
});

/// The rides this install wrote signed, kept in SharedPreferences under
/// [prefsKey] as a JSON object: `keyFingerprint` (the SHA-256 hex of the
/// key's DER), `rideSessionIds` (a list of strings) and, optional (older
/// values lack it), `segmentFileNames` (an object from `rideSessionId` to
/// the list of that ride's segment file names).
///
/// It is consulted only for this phone's current key: a list stored for
/// another key reads as empty and is replaced by the next [add]. Use it on
/// the UI isolate only.
class SignedRideRegistry {
  /// Creates a registry. The app uses [instance].
  SignedRideRegistry();

  /// The app's registry.
  static final SignedRideRegistry instance = SignedRideRegistry();

  /// SharedPreferences key of the registry.
  static const String prefsKey = 'signed_ride_registry';

  Future<void> _queue = Future<void>.value();

  /// The `rideSessionId`s registered for [publicKey] (base64 DER), or an
  /// empty set when the registry belongs to another key or cannot be read.
  Future<Set<String>> idsFor(String publicKey) async =>
      (await registrationsFor(publicKey)).rideSessionIds;

  /// Everything registered for [publicKey] (base64 DER): empty when the
  /// registry belongs to another key or cannot be read.
  Future<SignedRideRegistrations> registrationsFor(String publicKey) async {
    final empty = (rideSessionIds: <String>{}, segmentFileNames: <String>{});
    try {
      await _queue;
      final stored = _read(await SharedPreferences.getInstance());
      final fingerprint = rideSigningKeyFingerprintOf(publicKey);
      if (stored == null || fingerprint != stored.fingerprint) {
        return empty;
      }
      return (
        rideSessionIds: stored.ids,
        segmentFileNames: <String>{
          for (final names in stored.segments.values) ...names,
        },
      );
    } catch (_) {
      return empty;
    }
  }

  /// Registers [rideSessionId], with its [segmentFileNames] (file names
  /// without a directory), as written signed with [publicKey]. Call it
  /// only after the signed file was written.
  Future<void> add(
    String publicKey,
    String rideSessionId, {
    Iterable<String> segmentFileNames = const <String>[],
  }) {
    final names = segmentFileNames.toList();
    return _update((ids, segments) {
      ids.add(rideSessionId);
      if (names.isEmpty) {
        segments.remove(rideSessionId);
      } else {
        segments[rideSessionId] = names;
      }
    }, publicKey: publicKey);
  }

  /// Removes [rideSessionId] and its segment file names (the ride was
  /// deleted in the app). With a [telemetryFileName] (the deleted file's
  /// name, no directory) nothing is removed unless it is the ride's own
  /// name (`rideTelemetryFileNameFor`), so deleting a copy or a decoy that
  /// carries a registered id leaves the real ride registered.
  Future<void> remove(String rideSessionId, {String? telemetryFileName}) {
    if (telemetryFileName != null &&
        telemetryFileName != rideTelemetryFileNameFor(rideSessionId)) {
      return Future<void>.value();
    }
    return _update((ids, segments) {
      ids.remove(rideSessionId);
      segments.remove(rideSessionId);
    });
  }

  Future<void> _update(
    void Function(Set<String> ids, Map<String, List<String>> segments) change, {
    String? publicKey,
  }) {
    final next = _queue.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final stored = _read(prefs);
        final fingerprint = publicKey == null
            ? stored?.fingerprint
            : rideSigningKeyFingerprintOf(publicKey);
        if (fingerprint == null) {
          return;
        }
        final sameKey = stored != null && stored.fingerprint == fingerprint;
        final ids = sameKey ? stored.ids : <String>{};
        final segments = sameKey ? stored.segments : <String, List<String>>{};
        change(ids, segments);
        segments.removeWhere((id, _) => !ids.contains(id));
        await prefs.setString(
          prefsKey,
          jsonEncode(<String, Object?>{
            'keyFingerprint': fingerprint,
            'rideSessionIds': ids.toList()..sort(),
            if (segments.isNotEmpty) 'segmentFileNames': segments,
          }),
        );
      } catch (error) {
        debugPrintError(
          'signing',
          'Signed ride registry: update failed: $error',
        );
      }
    });
    _queue = next;
    return next;
  }

  static ({
    String fingerprint,
    Set<String> ids,
    Map<String, List<String>> segments,
  })?
  _read(SharedPreferences prefs) {
    final raw = prefs.getString(prefsKey);
    if (raw == null) {
      return null;
    }
    try {
      final json = jsonDecode(raw);
      if (json is! Map) {
        return null;
      }
      final fingerprint = json['keyFingerprint'];
      final ids = json['rideSessionIds'];
      if (fingerprint is! String || ids is! List) {
        return null;
      }
      final rawSegments = json['segmentFileNames'];
      final segments = <String, List<String>>{};
      if (rawSegments is Map) {
        for (final entry in rawSegments.entries) {
          final id = entry.key;
          final names = entry.value;
          if (id is String && names is List) {
            segments[id] = names.whereType<String>().toList();
          }
        }
      }
      return (
        fingerprint: fingerprint,
        ids: ids.whereType<String>().toSet(),
        segments: segments,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Builds the [RideSignerContext] for this session on the UI isolate: this
/// phone's key ([RideSigningService.sessionSigningKey]) and, only when it is
/// known, the rides registered for it (their ids, telemetry file names and
/// segment file names).
Future<RideSignerContext> loadRideSignerContext({
  RideSigningService? service,
  SignedRideRegistry? registry,
}) async {
  final key = await (service ?? RideSigningService.instance)
      .sessionSigningKey();
  if (key == null) {
    return const RideSignerContext(thisDevicePublicKey: null);
  }
  final registered = await (registry ?? SignedRideRegistry.instance)
      .registrationsFor(key.publicKey);
  return RideSignerContext(
    thisDevicePublicKey: key.publicKey,
    signedRideIds: registered.rideSessionIds,
    signedTelemetryFileNames: <String>{
      for (final id in registered.rideSessionIds) rideTelemetryFileNameFor(id),
    },
    signedSegmentFileNames: registered.segmentFileNames,
  );
}
