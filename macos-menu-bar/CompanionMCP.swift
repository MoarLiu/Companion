import Foundation

@main
enum CompanionMCP {
    fileprivate static let version = "0.1.0"

    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--version") {
            print("CompanionMCP \(version)")
            return
        }
        if arguments.contains("--self-test") {
            runSelfTest()
            return
        }

        let server = CompanionMCPServer(registry: .defaultRegistry())
        server.run()
    }

    private static func runSelfTest() {
        let registry = CompanionWorkflowToolRegistry.defaultRegistry()
        let required = Set([
            "companion.focusReview.generate",
            "companion.journal.appendToday",
            "companion.asset.upload",
            "companion.pomodoro.startFocus",
            "companion.reminder.createBatch",
            "companion.reminder.create",
            "companion.reminder.parseDraft"
        ])
        let available = Set(registry.descriptors().map(\.id))
        let missing = required.subtracting(available)
        guard missing.isEmpty else {
            fputs("CompanionMCP self-test failed: missing tools \(missing.sorted().joined(separator: ", "))\n", stderr)
            exit(1)
        }

        let result = registry.invoke(CompanionWorkflowToolInvocation(
            toolID: "companion.reminder.parseDraft",
            arguments: ["text": .string("30分钟后 喝水")],
            dryRun: true,
            caller: "self-test"
        ))
        guard result.status == .succeeded else {
            fputs("CompanionMCP self-test failed: reminder parser returned \(result.status.rawValue)\n", stderr)
            exit(1)
        }

        print("CompanionMCP self-test OK (\(available.count) tools)")
    }
}

private final class CompanionMCPServer {
    private let registry: CompanionWorkflowToolRegistry
    private let approvalQueue: CompanionExternalToolCallQueue
    private let auditLog: CompanionMCPAuditLog
    private let runStore: CompanionWorkflowRunStore
    private let requestQueue = DispatchQueue(label: "com.crazyjal.companion.mcp.requests", qos: .utility, attributes: .concurrent)
    private var shouldExit = false
    private let approvalTimeout: TimeInterval = 120

    init(
        registry: CompanionWorkflowToolRegistry,
        approvalQueue: CompanionExternalToolCallQueue = CompanionExternalToolCallQueue(),
        auditLog: CompanionMCPAuditLog = CompanionMCPAuditLog(),
        runStore: CompanionWorkflowRunStore = CompanionWorkflowRunStore()
    ) {
        self.registry = registry
        self.approvalQueue = approvalQueue
        self.auditLog = auditLog
        self.runStore = runStore
    }

    func run() {
        while !shouldExit, let message = CompanionMCPFraming.readMessage() {
            guard let request = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
                CompanionMCPFraming.write(error: -32700, message: "Parse error", id: nil)
                continue
            }

            handle(request)
        }
    }

    private func handle(_ request: [String: Any]) {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            if id != nil {
                CompanionMCPFraming.write(error: -32600, message: "Invalid request", id: id)
            }
            return
        }

        if method == "notifications/initialized" {
            return
        }
        if method == "exit" {
            shouldExit = true
            return
        }

        guard id != nil else {
            return
        }

        switch method {
        case "initialize":
            respondInitialize(id: id)
        case "tools/list":
            respondToolsList(id: id)
        case "tools/call":
            requestQueue.async { [self] in
                respondToolsCall(request: request, id: id)
            }
        case "resources/list":
            CompanionMCPFraming.write(result: ["resources": []], id: id)
        case "prompts/list":
            CompanionMCPFraming.write(result: ["prompts": []], id: id)
        case "shutdown":
            shouldExit = true
            CompanionMCPFraming.write(result: NSNull(), id: id)
        default:
            CompanionMCPFraming.write(error: -32601, message: "Method not found: \(method)", id: id)
        }
    }

    private func respondInitialize(id: Any?) {
        CompanionMCPFraming.write(result: [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [
                    "listChanged": false
                ]
            ],
            "serverInfo": [
                "name": "CompanionMCP",
                "version": CompanionMCPServer.versionString
            ]
        ], id: id)
    }

    private func respondToolsList(id: Any?) {
        let tools = registry.descriptors().map { descriptor in
            [
                "name": descriptor.id,
                "description": "\(descriptor.description) Risk: \(descriptor.risk.rawValue). Approval: \(descriptor.approvalMode.rawValue).",
                "inputSchema": CompanionJSONValue.object(descriptor.inputSchema).anyValue
            ] as [String: Any]
        }
        CompanionMCPFraming.write(result: ["tools": tools], id: id)
    }

    private func respondToolsCall(request: [String: Any], id: Any?) {
        guard let params = request["params"] as? [String: Any],
              let name = params["name"] as? String
        else {
            CompanionMCPFraming.write(error: -32602, message: "tools/call requires params.name", id: id)
            return
        }

        guard let descriptor = registry.descriptor(for: name) else {
            CompanionMCPFraming.write(error: -32602, message: "Unknown Companion tool: \(name)", id: id)
            return
        }

        let rawArguments = params["arguments"] as? [String: Any] ?? [:]
        var arguments = rawArguments.mapValues(CompanionJSONValue.fromAny)
        let dryRun = arguments["dryRun"]?.boolValue ?? arguments["dry_run"]?.boolValue ?? false
        arguments["dryRun"] = .bool(dryRun)

        guard descriptor.risk == .readOnly || dryRun else {
            respondApprovedToolCall(
                name: name,
                descriptor: descriptor,
                arguments: arguments,
                id: id
            )
            return
        }

        let runID = runStore.startMCPToolRun(
            caller: "mcp-stdio",
            toolID: name,
            toolTitle: descriptor.title,
            risk: descriptor.risk,
            arguments: arguments,
            status: .running
        )
        let result = registry.invoke(CompanionWorkflowToolInvocation(
            toolID: name,
            arguments: arguments,
            dryRun: dryRun,
            caller: "mcp-stdio"
        ))
        runStore.finish(id: runID, result: result)
        respondAuditedToolResult(
            result,
            descriptor: descriptor,
            arguments: arguments,
            dryRun: dryRun,
            id: id
        )
    }

    private func respondApprovedToolCall(
        name: String,
        descriptor: CompanionWorkflowToolDescriptor,
        arguments: CompanionJSONObject,
        id: Any?
    ) {
        guard approvalQueue.hasFreshHeartbeat() else {
            let runID = runStore.startMCPToolRun(
                caller: "mcp-stdio",
                toolID: name,
                toolTitle: descriptor.title,
                risk: descriptor.risk,
                arguments: arguments,
                status: .blocked
            )
            let result = CompanionWorkflowToolResult.blocked(
                code: "companion_not_running",
                message: "Start Companion and approve this local tool call from the menu bar app.",
                output: [
                    "tool": .string(name),
                    "requiresCompanionApp": .bool(true),
                    "dryRunAvailable": .bool(true)
                ]
            )
            runStore.finish(id: runID, result: result)
            respondAuditedToolResult(
                result,
                descriptor: descriptor,
                arguments: arguments,
                dryRun: false,
                id: id
            )
            return
        }

        var pendingRunID: UUID?
        do {
            let runID = runStore.startMCPToolRun(
                caller: "mcp-stdio",
                toolID: name,
                toolTitle: descriptor.title,
                risk: descriptor.risk,
                arguments: arguments,
                status: .awaitingApproval
            )
            pendingRunID = runID
            let record = try approvalQueue.enqueue(
                toolID: name,
                toolTitle: descriptor.title,
                risk: descriptor.risk,
                arguments: arguments,
                caller: "mcp-stdio",
                timeout: approvalTimeout,
                runID: runID
            )
            guard let completed = approvalQueue.waitForTerminalRecord(
                id: record.id,
                timeout: approvalTimeout + 2
            ) else {
                let result = CompanionWorkflowToolResult.denied(
                    code: "approval_timeout",
                    message: "Companion did not return an approval result before the request timed out.",
                    output: [
                        "tool": .string(name),
                        "approvalTimedOut": .bool(true)
                    ]
                )
                runStore.finish(id: runID, result: result)
                respondAuditedToolResult(
                    result,
                    descriptor: descriptor,
                    arguments: arguments,
                    dryRun: false,
                    id: id
                )
                return
            }

            if let result = completed.result {
                let needsLocalAudit = runStore.run(id: runID)?.finishedAt == nil
                runStore.finish(id: runID, result: result)
                approvalQueue.deleteRecord(id: completed.id)
                if needsLocalAudit {
                    respondAuditedToolResult(
                        result,
                        descriptor: descriptor,
                        arguments: arguments,
                        dryRun: false,
                        id: id
                    )
                } else {
                    respondToolResult(result, id: id)
                }
                return
            }

            let result: CompanionWorkflowToolResult
            switch completed.status {
            case .denied:
                result = .denied(code: "approval_denied", message: completed.statusMessage ?? "Companion local approval was denied.")
            case .expired:
                result = .denied(code: "approval_expired", message: completed.statusMessage ?? "Companion local approval expired.")
            default:
                result = .failed(code: "approval_failed", message: completed.statusMessage ?? "Companion local approval did not produce a result.")
            }
            approvalQueue.deleteRecord(id: completed.id)
            runStore.finish(id: runID, result: result)
            respondAuditedToolResult(
                result,
                descriptor: descriptor,
                arguments: arguments,
                dryRun: false,
                id: id
            )
        } catch {
            let result = CompanionWorkflowToolResult.failed(code: "approval_queue_failed", message: error.localizedDescription)
            if let pendingRunID {
                runStore.finish(id: pendingRunID, result: result)
            }
            respondAuditedToolResult(
                result,
                descriptor: descriptor,
                arguments: arguments,
                dryRun: false,
                id: id
            )
        }
    }

    private func respondAuditedToolResult(
        _ result: CompanionWorkflowToolResult,
        descriptor: CompanionWorkflowToolDescriptor,
        arguments: CompanionJSONObject,
        dryRun: Bool,
        id: Any?
    ) {
        auditLog.append(
            caller: "mcp-stdio",
            toolID: descriptor.id,
            risk: descriptor.risk,
            arguments: arguments,
            dryRun: dryRun,
            result: result
        )
        respondToolResult(result, id: id)
    }

    private func respondToolResult(_ result: CompanionWorkflowToolResult, id: Any?) {
        var payload: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": result.userMessage ?? result.outputSummary
                ]
            ],
            "structuredContent": CompanionJSONValue.object(result.output).anyValue,
            "isError": result.status == .failed
                || result.status == .blocked
                || result.status == .denied
        ]
        if !result.missingInputs.isEmpty {
            payload["missingInputs"] = result.missingInputs.map { missing in
                [
                    "key": missing.key,
                    "title": missing.title,
                    "message": missing.message
                ]
            }
        }
        if let error = result.error {
            var errorPayload: [String: Any] = [
                "code": error.code,
                "message": error.message
            ]
            if let recoverySuggestion = error.recoverySuggestion {
                errorPayload["recoverySuggestion"] = recoverySuggestion
            }
            payload["error"] = errorPayload
        }
        CompanionMCPFraming.write(result: payload, id: id)
    }

    private static var versionString: String {
        CompanionMCP.version
    }
}

private enum CompanionMCPFraming {
    private static let outputLock = NSLock()
    private static var inputBuffer = Data()

    static func readMessage() -> Data? {
        while true {
            if let newlineIndex = inputBuffer.firstIndex(of: 10) {
                var line = Data(inputBuffer[..<newlineIndex])
                inputBuffer.removeSubrange(...newlineIndex)
                if line.last == 13 {
                    line.removeLast()
                }
                if line.isEmpty {
                    continue
                }
                return line
            }

            let chunk = FileHandle.standardInput.readData(ofLength: 4096)
            if chunk.isEmpty {
                guard !inputBuffer.isEmpty else { return nil }
                var line = inputBuffer
                inputBuffer.removeAll(keepingCapacity: false)
                if line.last == 13 {
                    line.removeLast()
                }
                return line.isEmpty ? nil : line
            }
            inputBuffer.append(chunk)
        }
    }

    static func write(result: Any, id: Any?) {
        writeObject([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ])
    }

    static func write(error code: Int, message: String, id: Any?) {
        writeObject([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private static func writeObject(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            return
        }
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
