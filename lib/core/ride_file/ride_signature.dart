/// The device signature of a version 3 integrity envelope: its value
/// types, strict decoding of the signer's P-256 public key and DER ECDSA
/// signature, verification, and the rule that decides who signed a ride.
///
/// The phone signs the envelope's `payloadHash` with a non-exportable
/// Android Keystore key (channel `com.example.motocam/integrity`). The
/// signature shows that the files were not changed by anyone without that
/// key; it does not prove the footage is genuine (a rooted phone or a
/// modified app can sign anything).
///
/// Everything here is pure Dart and runs on any isolate. Part of the
/// ride-file codec; import it through `ride_telemetry_codec.dart`.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/api.dart' show PublicKeyParameter;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

/// Value of the signature's `alg` field: ECDSA on P-256 with SHA-256.
const String rideSignatureAlgorithmEs256 = 'ES256';

/// DER prefix of an X.509 SubjectPublicKeyInfo for an EC P-256 key with an
/// uncompressed point: SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 },
/// BIT STRING (0 unused bits, 0x04 || X || Y) }.
const List<int> _p256SpkiPrefix = <int>[
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, //
  0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, //
  0x42, 0x00, 0x04,
];

/// Length of a P-256 SubjectPublicKeyInfo DER with an uncompressed point.
const int _p256SpkiLength = 91;

/// Longest base64 string read for a public key or a signature. A P-256
/// SubjectPublicKeyInfo is 124 characters and a DER signature at most 96;
/// anything much longer is rejected before decoding.
const int _maxSignatureFieldLength = 256;

// P-256 (secp256r1) field prime and curve coefficients, from SEC 2.
final BigInt _p256P = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);
final BigInt _p256A = BigInt.parse(
  'ffffffff00000001000000000000000000000000fffffffffffffffffffffffc',
  radix: 16,
);
final BigInt _p256B = BigInt.parse(
  '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
  radix: 16,
);

/// A signature as the phone returns it and as it is stored under
/// `integrity.signature`: every field is a string.
@immutable
class RideSignatureData {
  /// Creates a signature value.
  const RideSignatureData({
    required this.alg,
    required this.keyId,
    required this.publicKey,
    required this.sig,
  });

  /// Algorithm, [rideSignatureAlgorithmEs256].
  final String alg;

  /// First 16 lowercase hex characters of the SHA-256 of the public key
  /// DER ([rideSigningKeyIdOf]); for display and logs only.
  final String keyId;

  /// Base64 of the signer's X.509 SubjectPublicKeyInfo DER.
  final String publicKey;

  /// Base64 of the DER ECDSA signature over the UTF-8 bytes of the
  /// lowercase `payloadHash` hex string.
  final String sig;

  /// The value stored under `integrity.signature`.
  Map<String, String> toJson() => <String, String>{
    'alg': alg,
    'keyId': keyId,
    'publicKey': publicKey,
    'sig': sig,
  };
}

/// Signs a ride's `payloadHash` (64 lowercase hex characters) with this
/// phone's key, or returns `null` when signing is unavailable or failed.
typedef RidePayloadSigner =
    Future<RideSignatureData?> Function(String payloadHash);

/// What a ride file's signature says, independent of which phone reads it
/// (so it can be cached per file version).
@immutable
class RideSignatureFacts {
  /// Creates signature facts.
  const RideSignatureFacts({
    required this.signerPublicKey,
    required this.valid,
  });

  /// Canonical base64 of the signer's SubjectPublicKeyInfo DER, or `null`
  /// when the stored key could not be decoded.
  final String? signerPublicKey;

  /// Whether the signature verified over the stored `payloadHash` with
  /// [signerPublicKey] and its `keyId` matched the key.
  final bool valid;

  @override
  bool operator ==(Object other) =>
      other is RideSignatureFacts &&
      other.signerPublicKey == signerPublicKey &&
      other.valid == valid;

  @override
  int get hashCode => Object.hash(signerPublicKey, valid);

  @override
  String toString() => 'RideSignatureFacts($signerPublicKey, $valid)';
}

/// Result of [verifyRideSignature]: the [facts] and the integrity issues
/// found (empty when the signature is valid).
typedef RideSignatureCheck = ({RideSignatureFacts facts, List<String> issues});

/// Who signed a ride, as far as this phone can tell.
enum RideSignedBy {
  /// No valid signature (unsigned, or the signature failed its check).
  none,

  /// A valid signature by this phone's current key (full key bytes equal).
  thisDevice,

  /// A valid signature by a key known to differ from this phone's key:
  /// another phone, or this phone before a reinstall.
  otherKey,

  /// A valid signature, but this phone's key could not be read (iOS, a
  /// Keystore error), so the signer is unknown.
  unknownSigner,
}

/// What the reading phone knows: its own public key and the rides this
/// install wrote signed. Built on the UI isolate (platform channel and
/// SharedPreferences) and passed into the history isolate and playback;
/// all fields cross isolate boundaries.
///
/// A ride is matched to the registry by its `rideSessionId` and also by
/// its telemetry file name and segment file names, so editing the id in
/// the JSON does not take a ride out of the check.
@immutable
class RideSignerContext {
  /// Creates a signer context.
  const RideSignerContext({
    required this.thisDevicePublicKey,
    this.signedRideIds = const <String>{},
    this.signedTelemetryFileNames = const <String>{},
    this.signedSegmentFileNames = const <String>{},
  });

  /// Base64 SubjectPublicKeyInfo DER of this phone's signing key, or `null`
  /// when it could not be read.
  final String? thisDevicePublicKey;

  /// `rideSessionId`s this install wrote signed with
  /// [thisDevicePublicKey]; empty when that key is unknown.
  final Set<String> signedRideIds;

  /// Telemetry file names (`ride_<id>.telemetry.json`, no directory) of
  /// the rides in [signedRideIds]; empty when that key is unknown.
  final Set<String> signedTelemetryFileNames;

  /// Segment file names (no directory) of the rides this install wrote
  /// signed with [thisDevicePublicKey]; empty when that key is unknown.
  final Set<String> signedSegmentFileNames;
}

/// The keyId of a public key: the first 16 lowercase hex characters of the
/// SHA-256 of its SubjectPublicKeyInfo DER.
String rideSigningKeyIdOf(List<int> publicKeyDer) =>
    crypto.sha256.convert(publicKeyDer).toString().substring(0, 16);

/// The full SHA-256 hex of a public key's SubjectPublicKeyInfo DER given
/// as base64, or `null` when [publicKeyBase64] is not strict base64.
String? rideSigningKeyFingerprintOf(String publicKeyBase64) {
  final der = decodeStrictBase64(publicKeyBase64);
  return der == null ? null : crypto.sha256.convert(der).toString();
}

/// Decodes [value] only when it is canonical padded standard base64 (the
/// form `base64Encode` writes) and at most [maxLength] characters long;
/// otherwise returns `null`.
Uint8List? decodeStrictBase64(
  String value, {
  int maxLength = _maxSignatureFieldLength,
}) {
  if (value.isEmpty || value.length > maxLength) {
    return null;
  }
  try {
    final bytes = base64.decode(value);
    return base64.encode(bytes) == value ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// Whether [a] and [b] are the same public key: both strict base64 of
/// byte-for-byte equal DER. Never compares keyIds.
bool sameRideSigningKey(String? a, String? b) {
  if (a == null || b == null) {
    return false;
  }
  final left = decodeStrictBase64(a);
  final right = decodeStrictBase64(b);
  return left != null && right != null && listEquals(left, right);
}

/// Parses a P-256 SubjectPublicKeyInfo DER with an uncompressed point on
/// the curve, or returns `null` for anything else.
ECPublicKey? decodeP256PublicKey(List<int> der) {
  if (der.length != _p256SpkiLength) {
    return null;
  }
  for (var i = 0; i < _p256SpkiPrefix.length; i++) {
    if (der[i] != _p256SpkiPrefix[i]) {
      return null;
    }
  }
  final x = _unsignedBigInt(der, _p256SpkiPrefix.length, 32);
  final y = _unsignedBigInt(der, _p256SpkiPrefix.length + 32, 32);
  if (x >= _p256P || y >= _p256P) {
    return null;
  }
  final lhs = (y * y) % _p256P;
  final rhs = (x * x * x + _p256A * x + _p256B) % _p256P;
  if (lhs != rhs) {
    return null;
  }
  final domain = ECCurve_secp256r1();
  return ECPublicKey(domain.curve.createPoint(x, y), domain);
}

/// Parses a strict DER ECDSA signature, SEQUENCE { INTEGER r, INTEGER s },
/// with short-form lengths, minimal positive integers and no trailing
/// bytes, or returns `null`. Range checks against the curve order are left
/// to the verifier.
ECSignature? decodeDerEcdsaSignature(List<int> der) {
  if (der.length < 8 || der.length > 72 || der[0] != 0x30) {
    return null;
  }
  if (der[1] != der.length - 2) {
    return null;
  }
  var offset = 2;
  BigInt? readInteger() {
    if (offset + 2 > der.length || der[offset] != 0x02) {
      return null;
    }
    final length = der[offset + 1];
    final start = offset + 2;
    if (length == 0 || length > 33 || start + length > der.length) {
      return null;
    }
    // Negative, or a leading zero byte that is not needed.
    if (der[start] & 0x80 != 0) {
      return null;
    }
    if (length > 1 && der[start] == 0 && der[start + 1] & 0x80 == 0) {
      return null;
    }
    offset = start + length;
    return _unsignedBigInt(der, start, length);
  }

  final r = readInteger();
  if (r == null) {
    return null;
  }
  final s = readInteger();
  if (s == null || offset != der.length) {
    return null;
  }
  return ECSignature(r, s);
}

/// Checks a version 3 envelope's `signature` value [rawSignature] against
/// the envelope's stored [payloadHash] (lowercase hex).
///
/// Issues: `unsupported-signature-alg:<alg>` (any `alg` other than
/// [rideSignatureAlgorithmEs256]), `signature-key-mismatch` (`keyId` is not
/// the key's id) and `signature-invalid` (anything malformed, or a
/// signature that does not verify). Never throws. Both low-S and high-S
/// signatures are accepted, as Android Keystore does not normalise S.
RideSignatureCheck verifyRideSignature(
  Object? rawSignature,
  String payloadHash,
) {
  const invalidFacts = RideSignatureFacts(signerPublicKey: null, valid: false);
  if (rawSignature is! Map) {
    return (facts: invalidFacts, issues: const <String>['signature-invalid']);
  }
  final alg = rawSignature['alg'];
  if (alg != rideSignatureAlgorithmEs256) {
    return (
      facts: invalidFacts,
      issues: <String>['unsupported-signature-alg:$alg'],
    );
  }

  final rawKey = rawSignature['publicKey'];
  final keyDer = rawKey is String ? decodeStrictBase64(rawKey) : null;
  final publicKey = keyDer == null ? null : decodeP256PublicKey(keyDer);
  if (keyDer == null || publicKey == null) {
    return (facts: invalidFacts, issues: const <String>['signature-invalid']);
  }
  final signerPublicKey = base64.encode(keyDer);

  final issues = <String>[];
  if (rawSignature['keyId'] != rideSigningKeyIdOf(keyDer)) {
    issues.add('signature-key-mismatch');
  }

  final rawSig = rawSignature['sig'];
  final sigDer = rawSig is String ? decodeStrictBase64(rawSig) : null;
  final signature = sigDer == null ? null : decodeDerEcdsaSignature(sigDer);
  if (signature == null ||
      !_verifyEs256(publicKey, utf8.encode(payloadHash), signature)) {
    issues.add('signature-invalid');
  }

  return (
    facts: RideSignatureFacts(
      signerPublicKey: signerPublicKey,
      valid: issues.isEmpty,
    ),
    issues: issues,
  );
}

/// Whether [signature] (a [RideSignatureData] from the phone) is a valid
/// signature of [payloadHash]. The writer checks the phone's answer with it
/// before storing a signature.
bool isValidRideSignature(RideSignatureData signature, String payloadHash) =>
    verifyRideSignature(signature.toJson(), payloadHash).facts.valid;

/// Decides who signed a ride from its [facts] (`null` when the file has no
/// signature) and [context], and whether the ride's signature was removed:
/// `true` when the ride is in the registry of this phone's current key but
/// the file is unsigned or validly signed by a key known to differ. Never
/// reports a removal while this phone's key is unknown.
///
/// A ride is in the registry when its [rideSessionId], its
/// [telemetryFileName] or any of its [segmentFileNames] (file names
/// without a directory) is registered. Pass [segmentFileNames] only for a
/// ride read from a telemetry file.
({RideSignedBy signedBy, bool signatureRemoved}) resolveRideSigner({
  required RideSignatureFacts? facts,
  required String? rideSessionId,
  required RideSignerContext context,
  String? telemetryFileName,
  Iterable<String> segmentFileNames = const <String>[],
}) {
  final deviceKey = context.thisDevicePublicKey;
  final RideSignedBy signedBy;
  if (facts == null || !facts.valid) {
    signedBy = RideSignedBy.none;
  } else if (deviceKey == null) {
    signedBy = RideSignedBy.unknownSigner;
  } else if (sameRideSigningKey(facts.signerPublicKey, deviceKey)) {
    signedBy = RideSignedBy.thisDevice;
  } else {
    signedBy = RideSignedBy.otherKey;
  }

  final registered =
      deviceKey != null &&
      ((rideSessionId != null &&
              context.signedRideIds.contains(rideSessionId)) ||
          (telemetryFileName != null &&
              context.signedTelemetryFileNames.contains(telemetryFileName)) ||
          segmentFileNames.any(context.signedSegmentFileNames.contains));
  final signatureRemoved =
      registered && (facts == null || signedBy == RideSignedBy.otherKey);
  return (signedBy: signedBy, signatureRemoved: signatureRemoved);
}

bool _verifyEs256(
  ECPublicKey publicKey,
  List<int> message,
  ECSignature signature,
) {
  try {
    final signer = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(publicKey));
    return signer.verifySignature(Uint8List.fromList(message), signature);
  } catch (_) {
    return false;
  }
}

BigInt _unsignedBigInt(List<int> bytes, int start, int length) {
  var value = BigInt.zero;
  for (var i = start; i < start + length; i++) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}
