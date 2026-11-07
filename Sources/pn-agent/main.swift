// pn-agent — run by agent CLIs that ProjectN starts. Two modes:
//
//   pn-agent hook   Claude Code PreToolUse hook. Reads the tool call (JSON) on stdin, asks ProjectN for a decision
//                   (which may wait for the orchestrator agent or for you), prints allow / deny / ask.
//   pn-agent mcp    stdio MCP server exposing ProjectN's agent tools (ask, delegate_task, wait_for_tasks, …).
//
// Both talk to the running app at 127.0.0.1:$PROJECTN_AGENT_PORT with the task's $PROJECTN_AGENT_TOKEN
// (environment only, never on the command line). If ProjectN can't be reached, the hook answers "ask",
// so the CLI falls back to its own permission prompt — never to an automatic allow.

import Foundation

let env = ProcessInfo.processInfo.environment

/// One request/response round trip: a JSON line out, a JSON line back.
func bridge(_ request: [String: Any]) -> [String: Any]? {
    guard let portString = env["PROJECTN_AGENT_PORT"], let port = UInt16(portString),
          let token = env["PROJECTN_AGENT_TOKEN"], !token.isEmpty else { return nil }
    var req = request
    req["token"] = token
    guard var data = try? JSONSerialization.data(withJSONObject: req) else { return nil }
    data.append(0x0A)

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard ok == 0 else { return nil }
    var sent = 0
    while sent < data.count {
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, data.count - sent) }
        if n <= 0 { return nil }
        sent += n
    }
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        response.append(contentsOf: buf[0..<n])
        if response.last == 0x0A { break }
    }
    return try? JSONSerialization.jsonObject(with: response) as? [String: Any]
}

func emit(_ obj: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

// MARK: hook

func runHook() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let payload = (try? JSONSerialization.jsonObject(with: input)) ?? [:]
    let response = bridge(["op": "hook", "payload": payload])
    let decision = (response?["decision"] as? String).flatMap { ["allow", "deny", "ask"].contains($0) ? $0 : nil } ?? "ask"
    let reason = response?["reason"] as? String ?? "ProjectN isn't reachable; asking in the terminal."
    emit(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": decision,
                                 "permissionDecisionReason": reason]])
}

// MARK: mcp (newline-delimited JSON-RPC 2.0 over stdio)

func runMCP() {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty, let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        let method = msg["method"] as? String ?? ""
        guard let id = msg["id"] else { continue }   // notifications need no reply
        let params = msg["params"] as? [String: Any] ?? [:]
        var result: [String: Any]?
        var error: [String: Any]?
        switch method {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "projectn", "version": "1.0"],
                      "instructions": "ProjectN agent tools: ask questions, delegate work to other agents, follow their tasks."]
        case "ping":
            result = [:]
        case "tools/list":
            let r = bridge(["op": "tools"])
            result = ["tools": r?["tools"] as? [[String: Any]] ?? []]
        case "tools/call":
            let r = bridge(["op": "call", "name": params["name"] as? String ?? "", "arguments": params["arguments"] ?? [:]])
            let text = r?["text"] as? String ?? "ProjectN isn't reachable."
            result = ["content": [["type": "text", "text": text]], "isError": r == nil || (r?["isError"] as? Bool ?? false)]
        default:
            error = ["code": -32601, "message": "Method not found: \(method)"]
        }
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error { reply["error"] = error } else { reply["result"] = result ?? [:] }
        emit(reply)
    }
}

switch CommandLine.arguments.dropFirst().first {
case "hook": runHook()
case "mcp": runMCP()
default:
    FileHandle.standardError.write(Data("usage: pn-agent hook | mcp\n".utf8))
    exit(2)
}
