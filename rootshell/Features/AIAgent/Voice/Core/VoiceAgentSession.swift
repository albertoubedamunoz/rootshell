#if !CHINA_BUILD
//
//  VoiceAgentSession.swift
//  rootshell
//
//  Main coordinator for voice agent sessions.
//  Wires together WebSocket connection, audio pipeline, tool execution,
//  and approval flow into a unified voice interaction experience.
//

import AVFoundation
import Citadel
import Foundation
import Observation
import os.log

/// Consultation mode for the expert (Gemini Pro) model.
enum VoiceConsultationMode: String, Codable, CaseIterable, Sendable {
    case letFlashDecide = "let_flash_decide"
    case alwaysConsult = "always_consult"
    case neverConsult = "never_consult"

    var displayName: String {
        switch self {
        case .letFlashDecide: return "Let Flash Decide"
        case .alwaysConsult: return "Always Consult"
        case .neverConsult: return "Never Consult"
        }
    }

    var description: String {
        switch self {
        case .letFlashDecide: return "Flash model decides when to consult the expert"
        case .alwaysConsult: return "Always consult Gemini 3.1 Pro for every question"
        case .neverConsult: return "Flash-only mode for lowest latency"
        }
    }
}

/// Available Gemini Live API voices.
enum GeminiVoice: String, CaseIterable, Sendable {
    case zephyr = "Zephyr"
    case puck = "Puck"
    case charon = "Charon"
    case kore = "Kore"
    case fenrir = "Fenrir"
    case leda = "Leda"
    case orus = "Orus"
    case aoede = "Aoede"
    case callirrhoe = "Callirrhoe"
    case autonoe = "Autonoe"
    case enceladus = "Enceladus"
    case iapetus = "Iapetus"
    case umbriel = "Umbriel"
    case algieba = "Algieba"
    case despina = "Despina"
    case erinome = "Erinome"
    case algenib = "Algenib"
    case rasalgethi = "Rasalgethi"
    case laomedeia = "Laomedeia"
    case achernar = "Achernar"
    case alnilam = "Alnilam"
    case schedar = "Schedar"
    case gacrux = "Gacrux"
    case pulcherrima = "Pulcherrima"
    case achird = "Achird"
    case zubenelgenubi = "Zubenelgenubi"
    case vindemiatrix = "Vindemiatrix"
    case sadachbia = "Sadachbia"
    case sadaltager = "Sadaltager"
    case sulafat = "Sulafat"

    var displayName: String { rawValue }

    var voiceDescription: String {
        switch self {
        case .zephyr: return "Bright"
        case .puck: return "Upbeat"
        case .charon: return "Informative"
        case .kore: return "Firm"
        case .fenrir: return "Excitable"
        case .leda: return "Youthful"
        case .orus: return "Firm"
        case .aoede: return "Breezy"
        case .callirrhoe: return "Easy-going"
        case .autonoe: return "Bright"
        case .enceladus: return "Breathy"
        case .iapetus: return "Clear"
        case .umbriel: return "Easy-going"
        case .algieba: return "Smooth"
        case .despina: return "Smooth"
        case .erinome: return "Clear"
        case .algenib: return "Gravelly"
        case .rasalgethi: return "Informative"
        case .laomedeia: return "Upbeat"
        case .achernar: return "Soft"
        case .alnilam: return "Firm"
        case .schedar: return "Even"
        case .gacrux: return "Mature"
        case .pulcherrima: return "Forward"
        case .achird: return "Friendly"
        case .zubenelgenubi: return "Casual"
        case .vindemiatrix: return "Gentle"
        case .sadachbia: return "Lively"
        case .sadaltager: return "Knowledgeable"
        case .sulafat: return "Warm"
        }
    }
}

@Observable
@MainActor
final class VoiceAgentSession: Identifiable {

    // MARK: - Properties

    let id = UUID()

    @ObservationIgnored
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VoiceAgentSession")

    /// Current state of the voice session.
    private(set) var state: VoiceAgentState = .idle

    /// Running transcript of the conversation.
    private(set) var transcript: [VoiceAgentTranscriptEntry] = []

    /// Whether the microphone is muted.
    var isMuted = false {
        didSet { audioPipeline.setMuted(isMuted) }
    }

    /// Current input audio level (0.0 - 1.0).
    var inputLevel: Float { audioPipeline.inputLevel }

    /// Current output audio level (0.0 - 1.0).
    var outputLevel: Float { audioPipeline.outputLevel }

    /// Whether model audio is playing.
    var isModelSpeaking: Bool { audioPipeline.isPlaying }

    /// Pending tool call awaiting approval.
    private(set) var pendingApproval: VoiceAgentToolCall?

    // MARK: - Configuration

    var voiceName: GeminiVoice = .kore
    var consultationMode: VoiceConsultationMode = .letFlashDecide

    // MARK: - Private Components

    @ObservationIgnored
    private var connection: GeminiLiveConnection?

    @ObservationIgnored
    private let audioSessionManager = AudioSessionManager()

    @ObservationIgnored
    private let audioPipeline = VoiceAudioPipeline()

    @ObservationIgnored
    private let toolExecutor = VoiceAgentToolExecutor()

    @ObservationIgnored
    private var sshConfig: SSHConfig?

    @ObservationIgnored
    private var fingerprint: HostFingerprint?

    @ObservationIgnored
    private var sshExecutor: AIAgentExecutor?

    @ObservationIgnored
    private var activeToolTask: Task<Void, Never>?

    @ObservationIgnored
    private var reconnectTask: Task<Void, Never>?

    @ObservationIgnored
    private var reconnectAttempt = 0

    @ObservationIgnored
    private var queuedToolCalls: [VoiceAgentToolCall] = []

    @ObservationIgnored
    private var activeToolCallID: String?

    @ObservationIgnored
    private var sessionResumptionHandle: String?

    /// Minimum input level to forward audio while model is speaking.
    /// Suppresses AEC residual echo during the adaptive filter's convergence period
    /// while still allowing loud genuine speech (barge-in) through.
    @ObservationIgnored
    private static let bargeInThreshold: Float = 0.15

    /// Seconds after model stops speaking to keep the energy gate active,
    /// giving the AEC time to settle after playback ends.
    @ObservationIgnored
    private static let echoTailGuardSeconds: TimeInterval = 0.3

    /// Timestamp when model last stopped speaking (for tail guard).
    @ObservationIgnored
    private var lastModelSpeakingEnd: Date?

    @ObservationIgnored
    private var currentTurnHasOutputTranscription = false

    @ObservationIgnored
    private var currentInputTranscript = ""

    @ObservationIgnored
    private var currentOutputTranscript = ""

    @ObservationIgnored
    private var transcriptContentFiles: [URL] = []

    @ObservationIgnored
    private static let maxInlineToolTranscriptChars = 12_000

    @ObservationIgnored
    private static let largeToolTranscriptPreviewChars = 4_000

    /// The terminal view this session is attached to.
    @ObservationIgnored
    weak var terminalView: Ghostty.TerminalView? {
        didSet { toolExecutor.terminalView = terminalView }
    }

    // MARK: - Initialization

    init(sshConfig: SSHConfig? = nil, fingerprint: HostFingerprint? = nil) {
        self.sshConfig = sshConfig
        self.fingerprint = fingerprint
    }

    deinit {
        activeToolTask?.cancel()
        reconnectTask?.cancel()
    }

    // MARK: - Session Lifecycle

    func start() async {
        guard state == .idle || state.isConnected == false else { return }

        state = .connecting

        do {
            // Request microphone permission explicitly — on Mac Catalyst,
            // accessing AVAudioEngine.inputNode does not trigger the system
            // permission prompt the way it does on iOS, so the mic silently
            // returns zeros without this.
            let micGranted = await AVAudioApplication.requestRecordPermission()
            guard micGranted else {
                state = .error("Microphone access denied — grant permission in System Settings → Privacy & Security → Microphone")
                Self.logger.error("Microphone permission denied")
                return
            }

            // Activate audio session
            try audioSessionManager.activateForVoice()

            // Start unified audio pipeline (single engine for proper AEC)
            try audioPipeline.start()

            // Set up audio streaming with energy gating during model speech.
            // While the model is speaking (and briefly after), only forward audio
            // loud enough to be genuine speech — this suppresses AEC residual echo
            // that would otherwise trigger false interruptions before the adaptive
            // filter fully converges.
            audioPipeline.onAudioChunk = { [weak self] data in
                guard let self else { return }

                let isSpeaking = self.state == .speaking
                let isInTailGuard: Bool = {
                    guard let end = self.lastModelSpeakingEnd else { return false }
                    return Date().timeIntervalSince(end) < Self.echoTailGuardSeconds
                }()

                if isSpeaking || isInTailGuard {
                    guard self.audioPipeline.inputLevel > Self.bargeInThreshold else { return }
                }

                self.connection?.sendAudio(data)
            }

            // Connect to Gemini Live API
            let apiKey = AICredentialsManager.shared.loadGoogleAPIKey() ?? ""
            guard !apiKey.isEmpty else {
                state = .error("No Google API key configured")
                return
            }

            let conn = GeminiLiveConnection(apiKey: apiKey)
            conn.delegate = self
            self.connection = conn

            let setup = buildSetupMessage()
            try await conn.connect(setup: setup)

            Self.logger.info("Voice agent session started")

            // Connect SSH executor for execute_ssh_command tool (non-blocking)
            if let sshConfig {
                connectSSHExecutor(sshConfig: sshConfig)
            }

        } catch {
            state = .error(error.localizedDescription)
            cleanup()
            Self.logger.error("Failed to start voice session: \(error.localizedDescription)")
        }
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        cleanup()
        state = .idle
        Self.logger.info("Voice agent session stopped")
    }

    // MARK: - Approval Flow

    func approveToolCall() {
        guard let toolCall = pendingApproval else { return }
        pendingApproval = nil
        state = .executingTool(toolCall)
        executeToolCall(toolCall)
    }

    func rejectToolCall() {
        guard let toolCall = pendingApproval else { return }
        pendingApproval = nil
        state = .listening

        // Send rejection as tool response
        let rejection = "Tool call rejected by user."
        sendToolResponse(id: toolCall.id, name: toolCall.name, result: rejection)
        appendTranscript(.system, text: "Rejected: \(toolCall.displayDescription)")
        processNextToolCallIfNeeded()
    }

    // MARK: - Private: Setup

    private func buildSetupMessage() -> GeminiLiveSetup {
        let systemPrompt = buildSystemPrompt()

        // Build tool declarations, excluding consult_expert if never-consult mode
        var tools = VoiceAgentTools.functionDeclarations
        if consultationMode == .neverConsult {
            tools.removeAll { $0.name == "consult_expert" }
        }
        if AICredentialsManager.shared.webSearchEnabled {
            tools.append(contentsOf: VoiceAgentTools.webToolDeclarations)
        }

        return GeminiLiveSetup(
            setup: GeminiLiveSetup.SetupPayload(
                model: "models/\(GeminiLiveConnection.defaultModel)",
                generationConfig: GeminiLiveSetup.GenerationConfig(
                    responseModalities: ["AUDIO"],
                    speechConfig: GeminiLiveSetup.SpeechConfig(
                        voiceConfig: GeminiLiveSetup.VoiceConfig(
                            prebuiltVoiceConfig: GeminiLiveSetup.PrebuiltVoiceConfig(
                                voiceName: voiceName.rawValue
                            )
                        )
                    )
                ),
                systemInstruction: GeminiLiveSetup.SystemInstruction(
                    parts: [GeminiLiveSetup.TextPart(text: systemPrompt)]
                ),
                tools: [GeminiLiveSetup.ToolDeclaration(functionDeclarations: tools)],
                realtimeInputConfig: GeminiLiveSetup.RealtimeInputConfig(
                    activityHandling: "START_OF_ACTIVITY_INTERRUPTS",
                    automaticActivityDetection: GeminiLiveSetup.AutomaticActivityDetection(
                        disabled: nil,
                        startOfSpeechSensitivity: "START_SENSITIVITY_LOW",
                        prefixPaddingMs: 200,
                        endOfSpeechSensitivity: "END_SENSITIVITY_LOW",
                        silenceDurationMs: 700
                    )
                ),
                sessionResumption: GeminiLiveSetup.SessionResumptionConfig(
                    handle: sessionResumptionHandle
                ),
                contextWindowCompression: GeminiLiveSetup.ContextWindowCompressionConfig(
                    slidingWindow: GeminiLiveSetup.ContextWindowCompressionConfig.SlidingWindow()
                ),
                inputAudioTranscription: GeminiLiveSetup.AudioTranscriptionConfig(),
                outputAudioTranscription: GeminiLiveSetup.AudioTranscriptionConfig()
            )
        )
    }

    private func buildSystemPrompt() -> String {
        let isSSH = sshConfig != nil

        // Build the prompt following Google's recommended structure:
        // 1. Audio Profile (persona)
        // 2. Scene (environment context)
        // 3. Conversation flow (one-time greeting → ongoing loop)
        // 4. Tool invocation rules (ordered by frequency)
        // 5. Guardrails

        var prompt: String
        if isSSH {
            prompt = """
            # Audio Profile: Terminal Assistant
            You are a knowledgeable, concise voice assistant embedded in a terminal emulator app. \
            You help the user manage remote servers, debug issues, and run commands. \
            You speak in a direct, confident, and friendly tone.

            # Scene
            The user is running a terminal emulator on their device (iPad, iPhone, Mac, or Apple Vision Pro) \
            and is connected to a remote server via SSH. \
            They are speaking to you hands-free while working. You can see their terminal, type into it, \
            and execute commands in the background via a separate SSH connection.

            # Conversation Flow

            ## First Turn
            When you first hear the user speak, greet them briefly and ask how you can help.

            ## Ongoing Conversation
            - Keep every response short — one to three sentences. Progressively disclose detail only if asked.
            - Each response should add new information. Do not repeat back what the user just said.
            - Act, don't describe. Call tools immediately rather than explaining what you would do.
            - If you need terminal context, call get_scrollback first, then answer.

            # Tool Usage

            ## Running Commands
            Default to execute_ssh_command for all commands. It runs in the background via SSH and returns \
            structured output (stdout, stderr, exit code) without disturbing the user's visible terminal session.

            ## Inserting Text
            Use send_paste to insert text into the visible terminal. It preserves literal text and does not \
            press Enter automatically. Follow with send_keystrokes if you need to press Enter.

            ## Special Keys & Interactive Control
            Use send_keystrokes only when the task requires special keys or interactive terminal control: \
            pressing Enter after a paste, tab-completion, navigating a TUI, sending Ctrl+C, or when the user \
            explicitly says "type".

            ## TUI & Editor Navigation
            When a TUI application is active on the alternate screen (vim, nano, less, man, htop):
            - Always send {escape} first before vim/vi commands to ensure normal mode.
            - Vim save & quit: {escape}:wq{enter}
            - Vim quit without saving: {escape}:q!{enter}
            - Vim enter insert mode: send i, type or paste text, then {escape} to return to normal mode.
            - Exit less/man/git-log: send q
            - Cancel or interrupt anything: {ctrl+c}

            # Guardrails
            - Never give long monologues — the user is listening, not reading.
            - Never list out every step before doing it. Just do it and summarize the result.
            - If you are unsure about a destructive command, confirm with the user before executing.
            - Do not hallucinate file paths or command output. Use tools to verify.

            """
        } else {
            prompt = """
            # Audio Profile: Terminal Assistant
            You are a knowledgeable, concise voice assistant embedded in a terminal emulator app. \
            You help the user with their local shell, navigate files, and answer questions. \
            You speak in a direct, confident, and friendly tone.

            # Scene
            The user is running a terminal emulator on their device (iPad, iPhone, Mac, or Apple Vision Pro) \
            with a local shell. They are speaking to you hands-free while working.

            # Conversation Flow

            ## First Turn
            When you first hear the user speak, greet them briefly and ask how you can help.

            ## Ongoing Conversation
            - Keep every response short — one to three sentences. Progressively disclose detail only if asked.
            - Each response should add new information. Do not repeat back what the user just said.
            - Act, don't describe. Call tools immediately rather than explaining what you would do.
            - If you need terminal context, call get_scrollback first, then answer.

            # Tool Usage

            ## Inserting Text
            Use send_paste for commands, paths, quoted text, and multi-line content. It inserts literal text \
            and does not press Enter automatically.

            ## Special Keys & Interactive Control
            Use send_keystrokes for special keys and interactive control: pressing Enter after a paste, \
            tab-completion, navigating menus, TUI apps, Ctrl+C, or when the user explicitly says "type".

            ## TUI & Editor Navigation
            When a TUI application is active on the alternate screen (vim, nano, less, man, htop):
            - Always send {escape} first before vim/vi commands to ensure normal mode.
            - Vim save & quit: {escape}:wq{enter}
            - Vim quit without saving: {escape}:q!{enter}
            - Vim enter insert mode: send i, type or paste text, then {escape} to return to normal mode.
            - Exit less/man/git-log: send q
            - Cancel or interrupt anything: {ctrl+c}

            # Guardrails
            - Never give long monologues — the user is listening, not reading.
            - Never list out every step before doing it. Just do it and summarize the result.
            - If you are unsure about a destructive command, confirm with the user before executing.
            - Do not hallucinate file paths or command output. Use tools to verify.

            """
        }

        // Add host context
        if let fp = fingerprint {
            prompt += """
            # Host Information
            \(fp.summary())

            # Available Tools
            \(fp.toolsSummary())

            """
        } else if let ssh = sshConfig {
            prompt += """
            # Host Information
            - Host: \(ssh.host)
            - User: \(ssh.username)

            """
        }

        // Add web search guidance
        if AICredentialsManager.shared.webSearchEnabled {
            prompt += """
            # Web Search
            You can search the web and fetch pages. Use web_search when the user asks about documentation, \
            error messages, or current information. Use web_fetch to read a specific URL after finding it.

            """
        }

        // Add consultation guidance
        if consultationMode == .alwaysConsult {
            prompt += """
            # Expert Consultation
            You MUST call consult_expert for every substantive question before answering. \
            Relay the expert's analysis in your spoken response.

            """
        } else if consultationMode == .letFlashDecide {
            prompt += """
            # Expert Consultation
            You have a consult_expert tool for complex questions. Invoke it only when:
            - The question requires multi-step debugging or architecture analysis
            - You are uncertain about the correct approach
            - The user explicitly asks for a thorough or detailed analysis

            """
        }

        return prompt
    }

    // MARK: - Private: Tool Execution

    private func handleToolCalls(_ calls: [LiveToolCall]) {
        let approvalMode = AICredentialsManager.shared.approvalMode

        for call in calls {
            if queuedToolCalls.contains(where: { $0.id == call.id }) ||
                pendingApproval?.id == call.id ||
                activeToolCallID == call.id {
                continue
            }

            let needsApproval = VoiceAgentTools.requiresApproval(call.name, args: call.args, mode: approvalMode)
            let riskLevel = VoiceAgentTools.riskLevel(for: call.name, args: call.args)
            let description = VoiceAgentTools.describeToolCall(name: call.name, args: call.args)

            let toolCall = VoiceAgentToolCall(
                id: call.id,
                name: call.name,
                args: call.args,
                displayDescription: description,
                requiresApproval: needsApproval,
                riskLevel: riskLevel
            )

            queuedToolCalls.append(toolCall)
        }

        processNextToolCallIfNeeded()
    }

    private func executeToolCall(_ toolCall: VoiceAgentToolCall) {
        appendTranscript(.tool(name: toolCall.name), text: toolCall.displayDescription)
        activeToolCallID = toolCall.id

        if toolCall.name == "consult_expert" {
            state = .consultingExpert
        }

        activeToolTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.toolExecutor.execute(
                    LiveToolCall(id: toolCall.id, name: toolCall.name, args: toolCall.args)
                )
                try Task.checkCancellation()
                self.sendToolResponse(id: toolCall.id, name: toolCall.name, result: result)

                self.appendTranscript(
                    .tool(name: toolCall.name),
                    text: result,
                    spillLargeToolContentToDisk: true
                )
            } catch is CancellationError {
                self.appendTranscript(.system, text: "Cancelled: \(toolCall.displayDescription)")
            } catch {
                let errorResult = "Error: \(error.localizedDescription)"
                self.sendToolResponse(id: toolCall.id, name: toolCall.name, result: errorResult)
                self.appendTranscript(.system, text: "Tool error: \(error.localizedDescription)")
            }

            self.finishToolExecution(id: toolCall.id)
        }
    }

    private func sendToolResponse(id: String, name: String, result: String, scheduling: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.connection?.sendToolResponses([(id: id, name: name, result: result, scheduling: scheduling)])
            } catch {
                Self.logger.error("Failed to send tool response: \(error.localizedDescription)")
            }
        }
    }

    private func processNextToolCallIfNeeded() {
        guard pendingApproval == nil, activeToolTask == nil else { return }
        guard !queuedToolCalls.isEmpty else {
            if state != .speaking {
                state = .listening
            }
            return
        }

        let toolCall = queuedToolCalls.removeFirst()
        if toolCall.requiresApproval {
            pendingApproval = toolCall
            state = .awaitingApproval(toolCall)
            Self.logger.info("Tool approval required: \(toolCall.displayDescription)")
            appendTranscript(.system, text: "Approval needed: \(toolCall.displayDescription)")
            return
        }

        state = .executingTool(toolCall)
        executeToolCall(toolCall)
    }

    private func cancelToolCalls(ids: [String]) {
        guard !ids.isEmpty else { return }

        let idSet = Set(ids)
        let cancelledQueued = queuedToolCalls.filter { idSet.contains($0.id) }
        queuedToolCalls.removeAll { idSet.contains($0.id) }
        for toolCall in cancelledQueued {
            appendTranscript(.system, text: "Cancelled: \(toolCall.displayDescription)")
        }

        if let pendingApproval, idSet.contains(pendingApproval.id) {
            appendTranscript(.system, text: "Cancelled: \(pendingApproval.displayDescription)")
            self.pendingApproval = nil
        }

        if let activeToolCallID, idSet.contains(activeToolCallID) {
            activeToolTask?.cancel()
        } else {
            processNextToolCallIfNeeded()
        }
    }

    private func finishToolExecution(id: String) {
        guard activeToolCallID == id else { return }
        activeToolTask = nil
        activeToolCallID = nil
        if state != .speaking {
            state = .listening
        }
        processNextToolCallIfNeeded()
    }

    // MARK: - Private: Expert Consultation

    private func setupConsultExpert() {
        toolExecutor.onConsultExpert = { [weak self] question, context in
            guard let self else { throw GeminiLiveError.notConnected }

            // Build context for Pro model
            var fullContext = question
            if let ctx = context {
                fullContext += "\n\nContext:\n\(ctx)"
            }

            // Use existing GeminiProvider for REST API call
            let apiKey = AICredentialsManager.shared.loadGoogleAPIKey() ?? ""
            guard !apiKey.isEmpty else {
                return "Expert consultation unavailable: No API key"
            }

            let provider = GeminiProvider(
                apiKey: apiKey,
                selectedModelID: "gemini-3.1-pro-preview"
            )

            // Build messages for the Pro model
            var systemPrompt = "You are a technical expert consultant. Provide thorough, detailed analysis."
            if let fp = self.fingerprint {
                systemPrompt += "\n\nHost: \(fp.summary())"
            }

            let response = try await provider.sendMessage(
                messages: [
                    AIAgentMessage(role: .user, content: .text(fullContext))
                ],
                systemPrompt: systemPrompt,
                tools: []
            )

            switch response.content {
            case .text(let text):
                return text
            case .textAndToolCalls(let text, _):
                return text
            case .toolCalls:
                return "No text response from expert model"
            }
        }
    }

    // MARK: - Private: SSH Executor

    private func connectSSHExecutor(sshConfig: SSHConfig) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let executor = AIAgentExecutor(sshConfig: sshConfig)
                // No callback = strict: the saved key from the main terminal
                // session passes silently; unknown or changed keys reject.
                try await executor.connect()

                if let shell = self.fingerprint?.shell {
                    executor.sessionShell = shell
                }

                self.sshExecutor = executor
                self.toolExecutor.agentExecutor = executor
                Self.logger.info("SSH executor connected for voice agent")
            } catch {
                let desc = error.localizedDescription
                Self.logger.warning("SSH executor connection failed: \(desc)")
                if error is HostKeyRejectedError || error is InvalidHostKey {
                    let host = sshConfig.host
                    self.appendTranscript(.system, text: "SSH tools unavailable: \(host) has an unknown or changed host key. Connect to it in a terminal session once to trust it.")
                }
                // Non-fatal — send_keystrokes still works
            }
        }
    }

    // MARK: - Private: Helpers

    private func cleanup() {
        activeToolTask?.cancel()
        activeToolTask = nil
        activeToolCallID = nil
        audioPipeline.stop()
        audioSessionManager.deactivate()
        connection?.disconnect()
        connection = nil
        pendingApproval = nil
        queuedToolCalls.removeAll()
        currentTurnHasOutputTranscription = false
        currentInputTranscript = ""
        currentOutputTranscript = ""
        cleanupTranscriptContentFiles()

        if let executor = sshExecutor {
            Task { await executor.disconnect() }
        }
        sshExecutor = nil
        toolExecutor.agentExecutor = nil
    }

    private func appendTranscript(
        _ role: VoiceAgentTranscriptEntry.Role,
        text: String,
        spillLargeToolContentToDisk: Bool = false
    ) {
        guard let entry = makeTranscriptEntry(
            role: role,
            text: text,
            spillLargeToolContentToDisk: spillLargeToolContentToDisk
        ) else {
            return
        }
        transcript.append(entry)
    }

    private func upsertTranscript(_ role: VoiceAgentTranscriptEntry.Role, text: String) {
        guard let entry = makeTranscriptEntry(role: role, text: text) else { return }

        if let last = transcript.last,
           sameTranscriptRole(last.role, role),
           (entry.text.hasPrefix(last.text) || last.text.hasPrefix(entry.text)) {
            transcript[transcript.count - 1] = entry
        } else {
            transcript.append(entry)
        }
    }

    private func appendStreamingTranscript(
        _ role: VoiceAgentTranscriptEntry.Role,
        chunk: String,
        currentText: inout String
    ) {
        let normalizedChunk = chunk.replacingOccurrences(of: "\n", with: " ")
        guard !normalizedChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if currentText.isEmpty {
            currentText = normalizedChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if normalizedChunk.hasPrefix(currentText) {
            currentText = normalizedChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if currentText.hasPrefix(normalizedChunk.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return
        } else {
            currentText = mergeTranscriptText(currentText, with: normalizedChunk)
        }

        if let last = transcript.last, sameTranscriptRole(last.role, role) {
            transcript[transcript.count - 1] = VoiceAgentTranscriptEntry(role: role, text: currentText)
        } else {
            transcript.append(VoiceAgentTranscriptEntry(role: role, text: currentText))
        }
    }

    private func mergeTranscriptText(_ existing: String, with chunk: String) -> String {
        let trimmedLeading = chunk.trimmingCharacters(in: .newlines)
        guard !trimmedLeading.isEmpty else { return existing }

        if existing.hasSuffix(" ") || trimmedLeading.hasPrefix(" ") {
            return existing + trimmedLeading
        }

        if let first = trimmedLeading.first,
           ",.!?;:".contains(first) {
            return existing + trimmedLeading
        }

        return existing + " " + trimmedLeading.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sameTranscriptRole(_ lhs: VoiceAgentTranscriptEntry.Role, _ rhs: VoiceAgentTranscriptEntry.Role) -> Bool {
        switch (lhs, rhs) {
        case (.user, .user), (.assistant, .assistant), (.system, .system):
            return true
        case let (.tool(name: lhsName), .tool(name: rhsName)):
            return lhsName == rhsName
        default:
            return false
        }
    }

    private func makeTranscriptEntry(
        role: VoiceAgentTranscriptEntry.Role,
        text: String,
        spillLargeToolContentToDisk: Bool = false
    ) -> VoiceAgentTranscriptEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard spillLargeToolContentToDisk, trimmed.count > Self.maxInlineToolTranscriptChars else {
            return VoiceAgentTranscriptEntry(role: role, text: trimmed)
        }

        guard let fileURL = persistTranscriptContent(trimmed) else {
            let clipped = String(trimmed.prefix(Self.maxInlineToolTranscriptChars))
            return VoiceAgentTranscriptEntry(
                role: role,
                text: clipped + "\n\n[Output clipped for safety.]"
            )
        }

        let preview = String(trimmed.prefix(Self.largeToolTranscriptPreviewChars))
        let previewText = preview + "\n\n[Large output saved. Use Load Full Output to view the complete result.]"
        return VoiceAgentTranscriptEntry(
            role: role,
            text: previewText,
            fullContentFilePath: fileURL.path
        )
    }

    private func persistTranscriptContent(_ text: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceAgentToolOutput", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            transcriptContentFiles.append(fileURL)
            return fileURL
        } catch {
            Self.logger.error("Failed to persist transcript content: \(error.localizedDescription)")
            return nil
        }
    }

    private func cleanupTranscriptContentFiles() {
        guard !transcriptContentFiles.isEmpty else { return }

        for url in transcriptContentFiles {
            try? FileManager.default.removeItem(at: url)
        }
        transcriptContentFiles.removeAll()
    }
}

// MARK: - GeminiLiveConnectionDelegate

extension VoiceAgentSession: GeminiLiveConnectionDelegate {

    func connectionDidOpen() {
        state = .listening
        reconnectAttempt = 0
        setupConsultExpert()
        appendTranscript(.system, text: "Voice session started — speak to begin")
        Self.logger.info("Voice connection established, listening for audio")
    }

    func connectionDidClose(reason: String?) {
        let wasActive = state.isActive
        state = .disconnected(reason: reason)
        audioPipeline.stop()

        appendTranscript(.system, text: "Disconnected: \(reason ?? "unknown reason")")

        // Auto-reconnect if session was active and within time limit
        if wasActive {
            scheduleReconnect()
        }
    }

    func connectionDidReceive(message: GeminiLiveServerMessage) {
        switch message {
        case .audioData(let data):
            if state != .speaking {
                Self.logger.info("Model started speaking (\(data.count) bytes first chunk)")
                currentInputTranscript = ""
            }
            state = .speaking
            audioPipeline.scheduleAudio(data)

        case .textContent(let text):
            if !currentTurnHasOutputTranscription {
                Self.logger.info("Model text: \(text.prefix(100))")
                currentInputTranscript = ""
                appendStreamingTranscript(.assistant, chunk: text, currentText: &currentOutputTranscript)
            }

        case .inputTranscription(let text):
            appendStreamingTranscript(.user, chunk: text, currentText: &currentInputTranscript)

        case .outputTranscription(let text):
            currentTurnHasOutputTranscription = true
            currentInputTranscript = ""
            appendStreamingTranscript(.assistant, chunk: text, currentText: &currentOutputTranscript)

        case .generationComplete:
            Self.logger.info("Model generation complete")

        case .turnComplete:
            Self.logger.info("Turn complete, now listening")
            lastModelSpeakingEnd = Date()
            currentTurnHasOutputTranscription = false
            currentInputTranscript = ""
            currentOutputTranscript = ""
            state = .listening

        case .interrupted:
            Self.logger.info("Interrupted by user speech")
            lastModelSpeakingEnd = Date()
            currentTurnHasOutputTranscription = false
            currentOutputTranscript = ""
            audioPipeline.interruptPlayback()
            state = .listening

        case .toolCalls(let calls):
            handleToolCalls(calls)

        case .toolCallCancellation(let ids):
            cancelToolCalls(ids: ids)

        case .sessionResumptionUpdate(let newHandle, let resumable):
            if resumable, let newHandle, !newHandle.isEmpty {
                sessionResumptionHandle = newHandle
            }

        case .goAway(let timeLeft):
            let message = if let timeLeft, !timeLeft.isEmpty {
                "Connection refreshing soon (time left: \(timeLeft))"
            } else {
                "Connection refreshing soon"
            }
            appendTranscript(.system, text: message)

        case .error(let message):
            Self.logger.error("Live API error: \(message)")
            appendTranscript(.system, text: "Error: \(message)")

        case .setupComplete:
            break
        }
    }

    func connectionDidFail(error: Error) {
        state = .error(error.localizedDescription)
        cleanup()
        appendTranscript(.system, text: "Connection failed: \(error.localizedDescription)")
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        reconnectAttempt += 1
        guard reconnectAttempt <= 5 else {
            Self.logger.warning("Max reconnection attempts reached, giving up")
            state = .error("Connection lost after multiple retries")
            return
        }

        // Exponential backoff: 2s, 4s, 8s, 16s, 32s
        let delay = min(Double(1 << reconnectAttempt), 32.0)
        Self.logger.info("Scheduling reconnect attempt \(self.reconnectAttempt) in \(delay)s")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.appendTranscript(.system, text: "Reconnecting (attempt \(self.reconnectAttempt))...")
            await self.start()
        }
    }
}
#endif
