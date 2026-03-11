// Provider.swift — GeminiCLIProvider
// AIProvider implementation that runs the Gemini CLI as a subprocess with
// `--output-format stream-json` (headless/JSONL mode).

import Foundation
import ChorographPluginSDK

actor GeminiCLIProvider: AIProvider {

    // MARK: - Identity

    nonisolated let id: ProviderID = "gemini-cli"
    nonisolated let displayName: String = "Gemini CLI"
    nonisolated let supportsSymbolSearch: Bool = false

    // MARK: - Configuration

    static let defaultBinaryPath: String = {
        let homebrew = "/opt/homebrew/bin/gemini"
        let legacy   = "/usr/local/bin/gemini"
        return FileManager.default.fileExists(atPath: homebrew) ? homebrew : legacy
    }()

    var binaryPath: String {
        get { UserDefaults.standard.string(forKey: "geminiCLIPath") ?? Self.defaultBinaryPath }
        set { UserDefaults.standard.set(newValue, forKey: "geminiCLIPath") }
    }

    var selectedModel: String? {
        get { UserDefaults.standard.string(forKey: "geminiModel") }
        set { UserDefaults.standard.set(newValue, forKey: "geminiModel") }
    }

    // MARK: - Internal state

    private let localAuth: LocalAuthManager
    private var eventContinuation: AsyncStream<any ProviderEvent>.Continuation?
    private var isStopped = false

    private var activeProcesses: [String: Process] = [:]
    private var sessionResults: [String: String] = [:]

    var shimSocketPath: String = ""
    var shimDirPath: String = ""

    // MARK: - Init

    init(localAuth: LocalAuthManager = LocalAuthManager()) {
        self.localAuth = localAuth
    }

    // MARK: - Health

    func health() async -> ProviderHealth {
        let result = await localAuth.validate(binaryPath: binaryPath)
        return ProviderHealth(
            isReachable: result.isValid,
            version: result.version,
            detail: result.errorMessage,
            activeModel: nil
        )
    }

    // MARK: - Sessions

    func createSession(title: String?) async throws -> ProviderSession {
        let validation = await localAuth.validate(binaryPath: binaryPath)
        guard validation.isValid else {
            throw ProviderError.binaryNotFound(binaryPath)
        }
        let id = UUID().uuidString
        sessionResults[id] = ""
        return ProviderSession(id: id, title: title)
    }

    func sendMessage(sessionID: String, text: String) async throws {
        let path = binaryPath
        let validation = await localAuth.validate(binaryPath: path)
        guard validation.isValid else {
            throw ProviderError.binaryNotFound(path)
        }

        let continuation = self.eventContinuation
        Task {
            await self.runGeminiProcess(
                sessionID: sessionID,
                prompt: text,
                binaryPath: path,
                continuation: continuation
            )
        }
    }

    func abortSession(id: String) async throws {
        activeProcesses[id]?.terminate()
        activeProcesses.removeValue(forKey: id)
        eventContinuation?.yield(TurnFinishedEvent(sessionID: id))
    }

    func fetchLastAssistantText(sessionID: String) async throws -> String {
        sessionResults[sessionID] ?? ""
    }

    func availableModels() async throws -> [ProviderModel] {
        do {
            return try await ModelsDevClient.shared.models(
                forProvider: "google",
                filter: ModelsDevClient.geminiCLIFilter
            )
        } catch {
            return [
                ProviderModel(id: "gemini-2.5-pro",  displayName: "Gemini 2.5 Pro"),
                ProviderModel(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash"),
            ]
        }
    }

    func setSelectedModel(_ modelID: String?) {
        selectedModel = modelID
    }

    func setShimEnvironment(socketPath: String, shimDirPath: String) {
        self.shimSocketPath = socketPath
        self.shimDirPath    = shimDirPath
    }

    // MARK: - Event stream

    func eventStream() -> AsyncStream<any ProviderEvent> {
        isStopped = false
        var capturedCont: AsyncStream<any ProviderEvent>.Continuation?
        let stream = AsyncStream<any ProviderEvent> { cont in
            capturedCont = cont
        }
        self.eventContinuation = capturedCont
        capturedCont?.yield(ConnectedEvent())
        return stream
    }

    func stopEventStream() {
        isStopped = true
        for process in activeProcesses.values { process.terminate() }
        activeProcesses.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Subprocess execution

    private func runGeminiProcess(
        sessionID: String,
        prompt: String,
        binaryPath: String,
        continuation: AsyncStream<any ProviderEvent>.Continuation?
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        var args: [String] = [
            "--prompt", prompt,
            "--output-format", "stream-json",
            "--yolo"
        ]
        if let model = selectedModel {
            args += ["--model", model]
        }
        process.arguments = args

        let workDir = UserDefaults.standard.string(forKey: "serverDirectory")
            ?? FileManager.default.currentDirectoryPath
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let pipe    = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = errPipe
        process.standardInput  = FileHandle.nullDevice

        activeProcesses[sessionID] = process

        if !shimSocketPath.isEmpty, !shimDirPath.isEmpty {
            var env = ProcessInfo.processInfo.environment
            let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = shimDirPath + ":" + existingPath
            env["CHOROGRAPH_SHIM_SOCKET"] = shimSocketPath
            env["CHOROGRAPH_REAL_BASH"] = "/bin/bash"
            process.environment = env
        }

        let outputStream = AsyncStream<Data> { cont in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.finish()
                } else {
                    cont.yield(data)
                }
            }
        }

        let errorStream = AsyncStream<Data> { cont in
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.finish()
                } else {
                    cont.yield(data)
                }
            }
        }

        Task {
            var stderrBuffer = ""
            for await chunk in errorStream {
                guard let text = String(data: chunk, encoding: .utf8) else { continue }
                stderrBuffer += text
                while let newlineRange = stderrBuffer.range(of: "\n") {
                    let line = String(stderrBuffer[stderrBuffer.startIndex..<newlineRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    stderrBuffer = String(stderrBuffer[newlineRange.upperBound...])
                    if !line.isEmpty { continuation?.yield(ErrorEvent(line)) }
                }
            }
            let remaining = stderrBuffer.trimmingCharacters(in: .whitespaces)
            if !remaining.isEmpty { continuation?.yield(ErrorEvent(remaining)) }
        }

        do {
            try process.run()
        } catch {
            continuation?.yield(ErrorEvent("Failed to launch Gemini CLI: \(error.localizedDescription)"))
            continuation?.yield(TurnFinishedEvent(sessionID: sessionID))
            activeProcesses.removeValue(forKey: sessionID)
            return
        }

        var lineBuffer = ""
        for await chunk in outputStream {
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            lineBuffer += text
            while let newlineRange = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
                lineBuffer = String(lineBuffer[newlineRange.upperBound...])
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    handleJSONLLine(line, sessionID: sessionID, continuation: continuation)
                }
            }
        }
        if !lineBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            handleJSONLLine(lineBuffer, sessionID: sessionID, continuation: continuation)
        }

        process.waitUntilExit()
        activeProcesses.removeValue(forKey: sessionID)

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            let errMsg: String
            switch exitCode {
            case 42: errMsg = "Input error (exit 42) — check your prompt."
            case 53: errMsg = "Turn limit exceeded (exit 53)."
            default: errMsg = "Gemini CLI exited with code \(exitCode)."
            }
            continuation?.yield(ErrorEvent(errMsg))
        }
        let finalText = sessionResults[sessionID] ?? ""
        continuation?.yield(AssistantReplyEvent(sessionID: sessionID, text: finalText))
        continuation?.yield(TurnFinishedEvent(sessionID: sessionID))
    }

    // MARK: - JSONL parsing

    func handleJSONLLine(
        _ line: String,
        sessionID: String,
        continuation: AsyncStream<any ProviderEvent>.Continuation?
    ) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "init":
            if let model = json["model"] as? String {
                continuation?.yield(InfoEvent("gemini: \(model)"))
            }

        case "message":
            guard (json["role"] as? String) == "assistant",
                  let content = json["content"] as? String else { break }
            var existing = sessionResults[sessionID] ?? ""
            existing += content
            sessionResults[sessionID] = existing

        case "tool_use":
            let toolName = (json["tool_name"] ?? json["name"]) as? String
            let input    = (json["parameters"] ?? json["input"]) as? [String: Any]
            if let toolName, let input {
                if let event = geminiToolEvent(toolName: toolName, input: input) {
                    continuation?.yield(event)
                } else {
                    let stringInput = input.mapValues { "\($0)" }
                    continuation?.yield(ToolCallEvent(name: toolName, input: stringInput))
                }
            } else if let toolName {
                continuation?.yield(ToolCallEvent(name: toolName, input: [:]))
            }

        case "tool_result":
            break

        case "error":
            if let msg = json["message"] as? String {
                continuation?.yield(ErrorEvent("gemini: \(msg)"))
            }

        case "result":
            if let status = json["status"] as? String, status != "success" {
                continuation?.yield(ErrorEvent("gemini finished: \(status)"))
            }

        default:
            continuation?.yield(OtherEvent(type: type))
        }
    }

    func geminiToolEvent(toolName: String, input: [String: Any]) -> (any ProviderEvent)? {
        switch toolName {
        case "read_file":
            let path = (input["absolute_path"] ?? input["path"] ?? input["file_path"]) as? String
            guard let p = path else { return nil }
            return ReadFileEvent(path: resolvedAbsolutePath(p))

        case "write_file":
            let path = (input["absolute_path"] ?? input["path"] ?? input["file_path"]) as? String
            guard let p = path else { return nil }
            return WriteFileEvent(path: resolvedAbsolutePath(p))

        case "replace", "edit_file":
            let path = (input["absolute_path"] ?? input["file_path"] ?? input["path"]) as? String
            guard let p = path else { return nil }
            return PatchFileEvent(path: resolvedAbsolutePath(p))

        default:
            return nil
        }
    }

    private func resolvedAbsolutePath(_ path: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        let workDir = UserDefaults.standard.string(forKey: "serverDirectory")
            ?? FileManager.default.currentDirectoryPath
        return (workDir as NSString).appendingPathComponent(path)
    }
}
