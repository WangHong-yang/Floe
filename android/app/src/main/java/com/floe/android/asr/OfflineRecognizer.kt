package com.floe.android.asr

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineRecognizer
import com.k2fsa.sherpa.onnx.OnlineRecognizerConfig
import com.k2fsa.sherpa.onnx.OnlineStream
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext

/**
 * A service-lifetime model with one short-lived utterance at a time.
 * Native work is confined to a worker; only active capture touches AudioRecord.
 * The worker waits without polling between sessions; no stream or inference runs while idle.
 * Call prepare before start. Callbacks run on main. No audio or transcript history is persisted.
 * Bindings verified against sherpa-onnx v2.0.1 OnlineRecognizer.kt and OnlineStream.kt.
 */
class OfflineRecognizer(context: Context) {
    private val assets = context.applicationContext.assets
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "Floe-ASR") }.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + worker)
    private val lock = Any()
    private var closed = false
    private var closingRequested = false
    private var ownsModelLease = false
    private var prepared = false
    private var session: Session? = null
    private var generation = 0L
    private var recognizer: OnlineRecognizer? = null
    private val closedResult = CompletableDeferred<Unit>()

    private class Session(
        val generation: Long,
        val onPartial: (String) -> Unit,
        val onError: (Throwable) -> Unit,
        val onStarted: () -> Unit,
        val onStopped: () -> Unit,
    ) {
        val signal = RecordingSignal()
        val audio = Channel<FloatArray>(64)
        val result = CompletableDeferred<Result<String>>()
        val stoppedPosted = AtomicBoolean(false)
    }

    suspend fun prepare() = withContext(worker) {
        synchronized(lock) { check(!closingRequested) { "Recognizer is closing" } }
        if (recognizer == null) {
            // A rapidly re-enabled service waits for its predecessor to free native memory.
            // At most one service-lifetime model is allocated in this process.
            modelLease.lock()
            ownsModelLease = true
            synchronized(lock) { check(!closingRequested) { "Recognizer was stopped while waiting" } }
            val config = OnlineRecognizerConfig(
                featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
                modelConfig = OnlineModelConfig(
                    transducer = OnlineTransducerModelConfig(
                        encoder = "model/encoder.int8.onnx",
                        decoder = "model/decoder.onnx",
                        joiner = "model/joiner.int8.onnx",
                    ),
                    tokens = "model/tokens.txt",
                    // v2.0.1 exposes no Kotlin session spinning switch. One ORT
                    // thread runs on our worker without idle native pool workers.
                    // Keep the model resident; do not trade heat for reloads.
                    numThreads = 1,
                    provider = "cpu",
                ),
                decodingMethod = "greedy_search",
                enableEndpoint = false,
            )
            recognizer = OnlineRecognizer(assetManager = assets, config = config)
        }
        synchronized(lock) {
            check(!closingRequested) { "Recognizer was stopped while loading" }
            prepared = true
        }
    }

    fun start(onPartial: (String) -> Unit, onError: (Throwable) -> Unit, onStarted: () -> Unit, onStopped: () -> Unit) {
        synchronized(lock) {
            check(!closingRequested) { "Recognizer is closing" }
            check(prepared) { "Call prepare before recording" }
            check(session == null) { "Recording is already active" }
            val next = Session(++generation, onPartial, onError, onStarted, onStopped)
            session = next
            scope.launch { runSession(next) }
        }
    }

    fun requestFinish() {
        synchronized(lock) { session?.signal?.finish() }
    }

    suspend fun finish(): String {
        val current = synchronized(lock) { session } ?: return ""
        current.signal.finish()
        return withContext(NonCancellable) {
            try { current.result.await().getOrThrow() }
            finally { clearSession(current) }
        }
    }

    /** Signals without waiting, including while a service lifecycle mutex is awaiting finish. */
    fun requestCancel() {
        synchronized(lock) { session?.signal?.cancel() }
    }

    suspend fun cancel() {
        val current = synchronized(lock) { session?.also { it.signal.cancel() } } ?: return
        withContext(NonCancellable) {
            try { current.result.await() }
            finally { clearSession(current) }
        }
    }

    // The result is retained until consumed, including when capture fails before finish.
    // A newer session can never be cleared by an older cleanup or callback.
    private fun clearSession(current: Session) {
        synchronized(lock) { if (session === current) session = null }
    }

    /** Prevent pending preparation or callbacks from doing more work before close can await it. */
    fun requestClose() {
        synchronized(lock) {
            closingRequested = true
            session?.signal?.cancel()
        }
    }

    suspend fun close() = withContext(NonCancellable) {
        val first = synchronized(lock) {
            if (closed) false else { closed = true; closingRequested = true; true }
        }
        if (!first) {
            closedResult.await()
            return@withContext
        }
        try {
            // withContext supplies a CoroutineScope receiver: an unqualified cancel()
            // resolves to CoroutineScope.cancel and cancels cleanup itself.
            this@OfflineRecognizer.cancel()
            withContext(worker) {
                try { recognizer?.release() }
                finally {
                    recognizer = null
                    synchronized(lock) { prepared = false; session = null }
                    if (ownsModelLease) { ownsModelLease = false; modelLease.unlock() }
                }
            }
        } finally {
            scope.cancel()
            worker.close()
            closedResult.complete(Unit)
        }
    }

    private suspend fun runSession(current: Session) {
        var stream: OnlineStream? = null
        var outcome: Result<String> = Result.success("")
        var reader: Job? = null
        try {
            val engine = checkNotNull(recognizer)
            if (current.signal.state != RecordingSignal.State.CANCELLED) {
                stream = engine.createStream()
                // Native stream setup must succeed before microphone ownership begins.
                if (current.signal.state == RecordingSignal.State.RECORDING) {
                    reader = scope.launch(Dispatchers.IO) { capture(current) }
                } else {
                    current.audio.close()
                }
                var previous = ""
                for (samples in current.audio) {
                    if (current.signal.state == RecordingSignal.State.CANCELLED) break
                    stream.acceptWaveform(samples, SAMPLE_RATE)
                    decodeReady(engine, stream, current.signal)
                    val text = engine.getResult(stream).text.trim()
                    if (text != previous) {
                        previous = text
                        main.post {
                            val deliver = synchronized(lock) { session === current && !closingRequested }
                            if (deliver && current.signal.state == RecordingSignal.State.RECORDING) current.onPartial(text)
                        }
                    }
                }
                if (current.signal.state != RecordingSignal.State.CANCELLED) {
                    // Same 500 ms right context as Mac, then declare end of input.
                    stream.acceptWaveform(FloatArray(8000), SAMPLE_RATE)
                    decodeReady(engine, stream, current.signal)
                    stream.inputFinished()
                    decodeReady(engine, stream, current.signal)
                    outcome = Result.success(engine.getResult(stream).text.trim())
                }
            }
        } catch (error: Throwable) {
            if (current.signal.state != RecordingSignal.State.CANCELLED) {
                outcome = Result.failure(error)
                main.post {
                    val deliver = synchronized(lock) { !closingRequested && session === current && generation == current.generation }
                    if (deliver && current.signal.state != RecordingSignal.State.CANCELLED) current.onError(error)
                }
            }
        } finally {
            current.signal.finish()
            withContext(NonCancellable) {
                // On decode/setup failure, interrupt capture instead of draining more
                // audio. Await AudioRecord.stop/release even if this job was cancelled.
                // On normal finish the reader has already closed the audio channel.
                reader?.cancelAndJoin()
                notifyStopped(current)
                current.audio.cancel()
                try { stream?.release() }
                catch (error: Throwable) { outcome = Result.failure(error) }
                finally {
                    // finish/cancel consumes this result and detaches the utterance, not the model.
                    if (current.signal.state == RecordingSignal.State.CANCELLED) outcome = Result.success("")
                    current.result.complete(outcome)
                }
            }
        }
    }

    private fun decodeReady(engine: OnlineRecognizer, stream: OnlineStream, signal: RecordingSignal) {
        while (signal.state != RecordingSignal.State.CANCELLED && engine.isReady(stream)) engine.decode(stream)
    }

    @SuppressLint("MissingPermission") // Foreground service checks RECORD_AUDIO first.
    private suspend fun capture(current: Session) {
        var recorder: AudioRecord? = null
        var failure: Throwable? = null
        try {
            if (current.signal.state != RecordingSignal.State.RECORDING) return
            val minimum = AudioRecord.getMinBufferSize(
                SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            )
            check(minimum > 0) { "This device does not support 16 kHz microphone capture" }
            val input = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                .setAudioFormat(AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(minimum * 2, SAMPLE_RATE * 2))
                .build()
            recorder = input
            check(input.state == AudioRecord.STATE_INITIALIZED) { "Microphone could not initialize" }
            if (current.signal.state != RecordingSignal.State.RECORDING) return
            currentCoroutineContext().ensureActive()
            input.startRecording()
            check(input.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Microphone could not start" }
            main.post {
                val deliver = synchronized(lock) { session === current && !closingRequested }
                if (deliver && current.signal.state == RecordingSignal.State.RECORDING) current.onStarted()
            }
            val pcm = ShortArray(1600)
            var filled = 0
            while (current.signal.state == RecordingSignal.State.RECORDING) {
                currentCoroutineContext().ensureActive()
                val count = input.read(pcm, filled, pcm.size - filled, AudioRecord.READ_NON_BLOCKING)
                check(count >= 0) { "Microphone read failed ($count)" }
                filled += count
                if (filled == pcm.size) {
                    enqueue(current, pcm, filled)
                    filled = 0
                }
                if (count == 0) delay(10)
            }
            // Drain already captured audio without keeping the microphone open for decoding.
            if (current.signal.state == RecordingSignal.State.FINISHING) {
                if (filled > 0) enqueue(current, pcm, filled)
                var remaining = SAMPLE_RATE
                while (remaining > 0 && current.signal.state == RecordingSignal.State.FINISHING) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(pcm, 0, minOf(pcm.size, remaining), AudioRecord.READ_NON_BLOCKING)
                    if (count <= 0) break
                    enqueue(current, pcm, count)
                    remaining -= count
                }
            }
        } catch (error: Throwable) {
            failure = error
        } finally {
            try {
                recorder?.let {
                    try {
                        if (it.recordingState == AudioRecord.RECORDSTATE_RECORDING) it.stop()
                    } finally { it.release() }
                }
            } catch (error: Throwable) {
                if (failure == null) failure = error
            } finally {
                current.audio.close(failure)
                notifyStopped(current)
            }
        }
    }

    /** Exactly once, including stream startup failure or cancellation before capture runs. */
    private fun notifyStopped(current: Session) {
        if (!current.stoppedPosted.compareAndSet(false, true)) return
        // Cleanup is not a UI update: deliver even during close or after the
        // utterance is detached. The caller releases only this session's exact
        // microphone-service ticket, never a newer session's ticket.
        main.post { current.onStopped() }
    }

    private fun enqueue(current: Session, pcm: ShortArray, count: Int) {
        check(current.audio.trySend(pcm16ToFloat(pcm, count)).isSuccess) {
            "Speech processing could not keep up. Please try a shorter recording."
        }
    }

    private companion object {
        const val SAMPLE_RATE = 16000
        val modelLease = Mutex()
    }
}
