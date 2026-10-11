import Foundation

// oby-mcp: Oby's runner as an MCP server over stdio, for Claude Code, Claude Desktop and any
// assistant that speaks MCP (docs/mcp.md). A JSON-RPC message per line in, one per line out.

/// Writes one line at a time, so answers to calls that run at once don't interleave.
actor Output {
    func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// Reads the client's lines until it hangs up; each call runs at once, so a `wait` holds up nothing.
func serve() async {
    let server = Server(runner: .http(RunnerAPI.url()))
    let output = Output()
    let lines = AsyncStream<String> { stream in
        Thread.detachNewThread {
            // Split on \n only (AGENTS.md: Foundation's lines break inside JSON strings too).
            while let line = readLine(strippingNewline: true) { stream.yield(line) }
            stream.finish()
        }
    }
    await withTaskGroup(of: Void.self) { group in
        for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            group.addTask {
                if let reply = await server.handle(line) { await output.write(reply) }
            }
        }
    }
}

await serve()
