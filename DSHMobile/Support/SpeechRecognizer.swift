// ============================================================================
//  SpeechRecognizer.swift — 语音输入（SFSpeechRecognizer + AVAudioEngine）
//  ----------------------------------------------------------------------------
//  把语音实时转写为文本，供聊天输入栏使用。
//  需要 Info.plist 声明：
//    · NSSpeechRecognitionUsageDescription（语音识别权限）
//    · NSMicrophoneUsageDescription（麦克风权限）
//  采用 on-device 识别（默认），无需额外 entitlement。
// ============================================================================
import Foundation
import AVFoundation
import Speech

/// 语音识别器：启动后持续转写，直到用户手动停止。
/// 所有回调都在主线程（@MainActor）。
@MainActor
final class SpeechRecognizer: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// 识别出的完整文本（用户可在此基础上编辑）
    @Published private(set) var transcript = ""
    /// 识别过程中的"临时"片段（是否真的结束未知）
    @Published private(set) var interimText = ""

    /// 每次有新的最终结果时回调（主线程）
    var onFinalResult: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    /// 请求授权（首次使用会弹系统权限框）。返回是否已授权（含 provisional）。
    func requestAuthorization() async -> Bool {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        // 麦克风权限也一并请求（听写需要录音）
        let micGranted = await requestMicPermission()
        switch status {
        case .authorized, .restricted:
            // restricted 也放行，让引擎决定
            return micGranted
        default:
            return false
        }
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// 开始听写；先请求授权，失败则置 failed 状态。
    func start() async {
        guard await requestAuthorization() else {
            state = .failed("需要语音识别与麦克风权限才能使用语音输入")
            return
        }
        // 确保上一个识别任务已停止
        stopEngine()

        do {
            try startEngine()
            state = .listening
        } catch {
            state = .failed("无法启动录音：\(error.localizedDescription)")
        }
    }

    private func startEngine() throws {
        // 用系统默认 locale 的识别器
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError.unavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.transcript = text
                        self.interimText = ""
                        self.onFinalResult?(text)
                    } else {
                        self.interimText = text
                    }
                }
                if error != nil {
                    // 非主动停止导致的错误
                    if self.state == .listening {
                        self.state = .failed("语音识别出错")
                        self.stopEngine()
                    }
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// 停止听写并返回最终文本（若为空则返回上次的 final）
    func stop() -> String {
        let result = transcript
        stopEngine()
        if state == .listening { state = .idle }
        return result
    }

    /// 重置为初始状态（下次 start 重新听写）
    func reset() {
        stopEngine()
        transcript = ""
        interimText = ""
        state = .idle
    }

    private func stopEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    enum SpeechError: Error {
        case unavailable
    }
}
