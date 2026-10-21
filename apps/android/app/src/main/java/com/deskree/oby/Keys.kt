package com.deskree.oby

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.suspendCancellableCoroutine
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.time.Instant
import java.time.temporal.ChronoUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * This phone's publishing key (apps/shared/DeviceKey.swift on the iPhone): a P-256 key in Android
 * Keystore, made in StrongBox when the phone has one, that signs only after a strong biometric for
 * that one signature (the Face ID of the iPhone), and is invalidated when a new fingerprint or face
 * is enrolled, as `.biometryCurrentSet` is. The private key never leaves the Keystore.
 */
object DeviceKey {
    private const val ALIAS = "publish-key"
    private val keystore get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun isAvailable(context: Context) = BiometricManager.from(context).canAuthenticate(BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

    /** The public half as the runner takes it: X9.63 (65 bytes, uncompressed), base64. Making it asks nothing. */
    fun publicKey(): String {
        val key = keystore.getCertificate(ALIAS)?.publicKey as? ECPublicKey ?: make()
        fun bytes(n: java.math.BigInteger) = n.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it }
        return Base64.encodeToString(byteArrayOf(4) + bytes(key.w.affineX) + bytes(key.w.affineY), Base64.NO_WRAP)
    }

    private fun make(): ECPublicKey {
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            .setInvalidatedByBiometricEnrollment(true)
            .setIsStrongBoxBacked(strongBox)
            .build()
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        val pair = runCatching { generator.initialize(spec(true)); generator.generateKeyPair() }
            .getOrElse { generator.initialize(spec(false)); generator.generateKeyPair() }
        return pair.public as ECPublicKey
    }

    /** Signs one publish: the biometric prompt shows the exact action, and nothing is signed without it. */
    suspend fun approve(activity: FragmentActivity, job: String, action: String, device: String): Approval {
        val signedAt = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()
        val signature = sign(activity, Approval.message(job, action, signedAt), action)
        return Approval(device, action, signedAt, signature)
    }

    /** ECDSA P-256 with SHA-256, DER, base64: what the runner checks. */
    private suspend fun sign(activity: FragmentActivity, message: ByteArray, reason: String): String {
        if (keystore.getKey(ALIAS, null) == null) make()
        val signature = Signature.getInstance("SHA256withECDSA").apply {
            try { initSign(keystore.getKey(ALIAS, null) as PrivateKey) } catch (e: android.security.keystore.KeyPermanentlyInvalidatedException) {
                // A new fingerprint or face: the key goes, and the next one registers again.
                keystore.deleteEntry(ALIAS)
                throw RunnerError("A new fingerprint or face was added, so the publishing key was reset. Publish again to register a new one.")
            }
        }
        val signed = suspendCancellableCoroutine { done ->
            val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    done.resume(result.cryptoObject?.signature ?: signature)
                }
                override fun onAuthenticationError(code: Int, message: CharSequence) {
                    done.resumeWithException(RunnerError(message.toString()))
                }
            })
            prompt.authenticate(BiometricPrompt.PromptInfo.Builder()
                .setTitle("Publish with Oby")
                .setSubtitle(reason)
                .setNegativeButtonText("Not now")
                .setAllowedAuthenticators(BIOMETRIC_STRONG)
                .build(), BiometricPrompt.CryptoObject(signature))
        }
        signed.update(message)
        return Base64.encodeToString(signed.sign(), Base64.NO_WRAP)
    }
}

/**
 * This phone's device token for the linked Mac's gateway: encrypted with an AES key that lives in
 * Android Keystore and never leaves it (the iPhone's keychain item), the ciphertext in the app's
 * private preferences, out of backups. Nothing else ever sees it.
 */
object GatewayTokenStore {
    private const val ALIAS = "gateway-token-key"
    private const val PREF = "gateway.token"
    /** Read once, then kept in memory: every request and route reads it. */
    @Volatile private var cached: String? = null

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        return generator.generateKey()
    }

    fun read(context: Context): String? {
        cached?.let { return it }
        val saved = Store.prefs(context).getString(PREF, null) ?: return null
        return runCatching {
            val bytes = Base64.decode(saved, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
            String(cipher.doFinal(bytes, 12, bytes.size - 12))
        }.getOrNull()?.also { cached = it }
    }

    fun save(context: Context, token: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(token.toByteArray())
        if (!Store.prefs(context).edit().putString(PREF, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()) {
            throw RunnerError("The phone couldn't keep the Mac's device token.")
        }
        cached = token
    }

    fun remove(context: Context) { cached = null; Store.prefs(context).edit().remove(PREF).apply() }
}
