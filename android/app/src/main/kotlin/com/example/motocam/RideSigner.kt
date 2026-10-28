package com.example.motocam

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Signs ride integrity envelopes with a device-bound Android Keystore key
 * (channel `com.example.motocam/integrity`, F032).
 *
 * The key is EC P-256 under alias [KEY_ALIAS], created on first use, never
 * exportable, StrongBox-backed when the phone has StrongBox (API 28+) and
 * TEE-backed otherwise. It needs no user authentication and is usable while
 * the phone is locked, because rides are saved from the lock screen (stop
 * from the notification). Uninstalling the app deletes it, so a reinstall
 * starts with a new key.
 *
 * Methods:
 * - `getSigningKey` returns `{keyId, publicKey}`.
 * - `signPayloadHash({payloadHash})` returns `{alg, keyId, publicKey, sig}`:
 *   `sig` is the base64 DER ECDSA signature (SHA256withECDSA) over the UTF-8
 *   bytes of the lowercase payloadHash hex string.
 *
 * `publicKey` is the base64 X.509 SubjectPublicKeyInfo DER and `keyId` the
 * first 16 hex characters of its SHA-256 (display and logs only). Keystore
 * work runs on one background thread, so the key is created once even when
 * calls overlap or the activity is recreated; replies are posted to the main thread. Failures reply with
 * an error code and never throw out of the handler.
 */
class RideSigner private constructor() : MethodChannel.MethodCallHandler {
    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "getSigningKey" -> runInBackground(result, "KEY_UNAVAILABLE") {
                val publicKey = publicKeyDer()
                mapOf(
                    "keyId" to keyIdOf(publicKey),
                    "publicKey" to base64(publicKey),
                )
            }
            "signPayloadHash" -> {
                val payloadHash = call.argument<String>("payloadHash")
                if (payloadHash == null || !PAYLOAD_HASH.matches(payloadHash)) {
                    result.error(
                        "INVALID_ARGS",
                        "payloadHash must be 64 lowercase hex characters",
                        null,
                    )
                    return
                }
                runInBackground(result, "SIGNING_FAILED") {
                    val entry = loadOrCreateKey()
                    val signature = Signature.getInstance("SHA256withECDSA").run {
                        initSign(entry.first)
                        update(payloadHash.toByteArray(Charsets.UTF_8))
                        sign()
                    }
                    mapOf(
                        "alg" to "ES256",
                        "keyId" to keyIdOf(entry.second),
                        "publicKey" to base64(entry.second),
                        "sig" to base64(signature),
                    )
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun runInBackground(
        result: MethodChannel.Result,
        errorCode: String,
        work: () -> Map<String, String>,
    ) {
        try {
            executor.execute {
                try {
                    val reply = work()
                    mainHandler.post { result.success(reply) }
                } catch (e: Throwable) {
                    Log.w(TAG, "Ride signing key operation failed", e)
                    mainHandler.post {
                        result.error(errorCode, e.message ?: e.javaClass.simpleName, null)
                    }
                }
            }
        } catch (e: Exception) {
            result.error(errorCode, e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun publicKeyDer(): ByteArray = loadOrCreateKey().second

    /**
     * Returns the private key and its public key's SubjectPublicKeyInfo DER,
     * creating the key pair first when the alias does not exist. Runs on
     * [executor] only, so creation never races.
     */
    private fun loadOrCreateKey(): Pair<PrivateKey, ByteArray> {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        if (!keyStore.containsAlias(KEY_ALIAS)) {
            generateKey()
        }
        val entry = keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("Alias $KEY_ALIAS holds no private key")
        return Pair(entry.privateKey, entry.certificate.publicKey.encoded)
    }

    private fun generateKey() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                generateKey(strongBox = true)
                return
            } catch (e: Exception) {
                // StrongBoxUnavailableException, or a StrongBox that fails
                // to generate: fall back to the TEE.
                Log.i(TAG, "StrongBox key unavailable, using the TEE: ${e.javaClass.simpleName}")
            }
        }
        generateKey(strongBox = false)
    }

    private fun generateKey(strongBox: Boolean) {
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(false)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE).run {
            initialize(builder.build())
            generateKeyPair()
        }
    }

    private fun keyIdOf(publicKeyDer: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(publicKeyDer)
            .joinToString("") { "%02x".format(it) }
            .substring(0, 16)

    private fun base64(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP)

    companion object {
        const val CHANNEL = "com.example.motocam/integrity"
        const val KEY_ALIAS = "motocam_ride_signing_v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TAG = "RideSigner"
        private val PAYLOAD_HASH = Regex("^[0-9a-f]{64}$")

        // One thread for every engine's handler, so the key is created once
        // even when an activity is recreated while a call is running.
        private val executor: ExecutorService = Executors.newSingleThreadExecutor()
        private val mainHandler = Handler(Looper.getMainLooper())

        /** Registers the integrity channel on [messenger]. */
        fun register(messenger: BinaryMessenger) {
            MethodChannel(messenger, CHANNEL).setMethodCallHandler(RideSigner())
        }
    }
}
