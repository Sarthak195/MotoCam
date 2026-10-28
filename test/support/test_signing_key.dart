// A P-256 key generated with pointycastle that stands in for the phone's
// Android Keystore key in tests, plus DER helpers to build well-formed and
// malformed signatures.

import 'dart:convert';
import 'dart:typed_data';

import 'package:motocam/core/ride_file/ride_telemetry_codec.dart';
import 'package:pointycastle/export.dart';

/// Order of the P-256 base point.
final BigInt p256Order = ECCurve_secp256r1().n;

/// A test P-256 key pair.
class TestSigningKey {
  TestSigningKey._(this.privateKey, this.publicKey);

  /// Generates a key from [seed] (deterministic).
  factory TestSigningKey.generate(int seed) {
    final random = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(List<int>.filled(32, seed))));
    final generator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(ECCurve_secp256r1()),
          random,
        ),
      );
    final pair = generator.generateKeyPair();
    return TestSigningKey._(pair.privateKey, pair.publicKey);
  }

  /// The private key.
  final ECPrivateKey privateKey;

  /// The public key.
  final ECPublicKey publicKey;

  /// X.509 SubjectPublicKeyInfo DER, as Android's `PublicKey.getEncoded`.
  Uint8List get spkiDer => Uint8List.fromList(<int>[
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, //
    0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, //
    0x42, 0x00, 0x04,
    ..._fixed32(publicKey.Q!.x!.toBigInteger()!),
    ..._fixed32(publicKey.Q!.y!.toBigInteger()!),
  ]);

  /// Base64 of [spkiDer].
  String get publicKeyBase64 => base64.encode(spkiDer);

  /// The keyId of this key.
  String get keyId => rideSigningKeyIdOf(spkiDer);

  /// Raw ECDSA signature of the UTF-8 bytes of [payloadHash], with a low S
  /// or, with [highS], the equivalent high S.
  ECSignature signRaw(String payloadHash, {bool highS = false}) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(privateKey));
    final signature =
        signer.generateSignature(Uint8List.fromList(utf8.encode(payloadHash)))
            as ECSignature;
    final lowS = signature.s > p256Order >> 1
        ? p256Order - signature.s
        : signature.s;
    return ECSignature(signature.r, highS ? p256Order - lowS : lowS);
  }

  /// The signature the phone would return for [payloadHash].
  RideSignatureData sign(String payloadHash, {bool highS = false}) {
    final raw = signRaw(payloadHash, highS: highS);
    return RideSignatureData(
      alg: rideSignatureAlgorithmEs256,
      keyId: keyId,
      publicKey: publicKeyBase64,
      sig: base64.encode(derSignature(raw.r, raw.s)),
    );
  }

  /// A [RidePayloadSigner] that signs with this key.
  Future<RideSignatureData?> signer(String payloadHash) async =>
      sign(payloadHash);
}

/// Strict DER of SEQUENCE { INTEGER r, INTEGER s }.
Uint8List derSignature(BigInt r, BigInt s) {
  final body = <int>[...derInteger(r), ...derInteger(s)];
  return Uint8List.fromList(<int>[0x30, body.length, ...body]);
}

/// Minimal DER INTEGER encoding of a non-negative [value].
List<int> derInteger(BigInt value) {
  var bytes = _unsigned(value);
  if (bytes.isEmpty) {
    bytes = <int>[0];
  }
  if (bytes.first & 0x80 != 0) {
    bytes = <int>[0, ...bytes];
  }
  return <int>[0x02, bytes.length, ...bytes];
}

List<int> _unsigned(BigInt value) {
  final bytes = <int>[];
  var rest = value;
  while (rest > BigInt.zero) {
    bytes.insert(0, (rest & BigInt.from(0xff)).toInt());
    rest = rest >> 8;
  }
  return bytes;
}

List<int> _fixed32(BigInt value) {
  final bytes = _unsigned(value);
  return <int>[...List<int>.filled(32 - bytes.length, 0), ...bytes];
}
