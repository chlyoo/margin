import Foundation

/// Runs one process and delivers its output line by line on the main queue, in order.
final class LineProcess {
    private let process = Process()
    private let queue = DispatchQueue(label:"com.peterlyoo.Margin.process")
    private var buffers: [Bool:Data] = [false:Data(),true:Data()]
    private var stopped = false
    var onLine: ((String, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    var isRunning: Bool { process.isRunning }

    init(executable: String, arguments: [String], directory: URL, environment: [String:String] = [:]) {
        process.executableURL = URL(fileURLWithPath:executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        for (pipe, isError) in [(output,false),(errors,true)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self, !data.isEmpty else { return }
                self.queue.async { self.consume(data,isError) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            for (pipe, isError) in [(output,false),(errors,true)] {
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                self.queue.async { self.consume(rest,isError,flush:true) }
            }
            self.queue.async { DispatchQueue.main.async { self.onExit?(finished.terminationStatus) } }
        }
        try process.run()
    }

    private func consume(_ data: Data, _ isError: Bool, flush: Bool = false) {
        var buffer = buffers[isError] ?? Data()
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(of:0x0A) {
            lines.append(String(decoding:buffer[buffer.startIndex..<index],as:UTF8.self))
            buffer = Data(buffer[buffer.index(after:index)...])
        }
        if flush, !buffer.isEmpty { lines.append(String(decoding:buffer,as:UTF8.self)); buffer = Data() }
        buffers[isError] = buffer
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { for line in lines { self.onLine?(line,isError) } }
    }

    func stop() {
        guard process.isRunning, !stopped else { return }
        stopped = true
        process.terminate()
        let target = process
        DispatchQueue.global().asyncAfter(deadline:.now() + 3) { if target.isRunning { kill(target.processIdentifier,SIGKILL) } }
    }
}

enum AgentLauncher {
    static let reasonPrompt = "Before every file change, write one line that starts with `WHY:` and says, in one or two plain sentences in the person's language, why this change is needed and what it does. The person reviews your work one change at a time, in order, and sees only that line next to the change, so each reason must stand on its own."

    static func arguments(prompt: String, resume: String?, allowShell: Bool) -> [String] {
        var result = ["-p",prompt,"--output-format","stream-json","--verbose","--permission-mode","acceptEdits",
                      "--allowedTools",allowShell ? "Read,Glob,Grep,Edit,Write,Bash" : "Read,Glob,Grep,Edit,Write","--append-system-prompt",reasonPrompt]
        if let resume { result += ["--resume",resume] }
        return result
    }

    /// Claude Code is started through the person's interactive login shell so the account configuration they set there applies.
    static func process(prompt: String, resume: String?, allowShell: Bool, directory: URL) -> LineProcess {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath:$0) ? $0 : nil } ?? "/bin/zsh"
        let command = "exec \"$(whence -p claude || command -v claude || echo claude)\" \"$@\""
        return LineProcess(executable:shell,arguments:["-lic",command,"margin-agent"] + arguments(prompt:prompt,resume:resume,allowShell:allowShell),directory:directory)
    }
}

/// A line-oriented shell for the workspace. Not a TTY: full-screen programs will not work.
final class ShellRunner {
    private(set) var directory: URL
    private var running: LineProcess?
    private let marker = "__margin_cwd_" + UUID().uuidString.prefix(8) + "__"
    var isRunning: Bool { running != nil }

    init(directory: URL) { self.directory = directory }

    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of:"\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",with:"",options:.regularExpression)
            .replacingOccurrences(of:"\u{1B}\\[[0-9;?]*[ -/]*[@-~]",with:"",options:.regularExpression)
            .replacingOccurrences(of:"\r",with:"")
    }

    func run(_ command: String, output: @escaping (String, Bool) -> Void, done: @escaping (Int32) -> Void) throws {
        guard running == nil else { throw MarginError.message("앞선 명령이 아직 실행 중이에요.") }
        let script = command + "\n__margin_status=$?\nprintf '\\n%s%s\\n' '\(marker)' \"$PWD\"\nexit $__margin_status"
        let process = LineProcess(executable:"/bin/zsh",arguments:["-lc",script],directory:directory,environment:["TERM":"dumb","NO_COLOR":"1","PAGER":"cat","GIT_PAGER":"cat"])
        var pendingBlank = false
        process.onLine = { [weak self] line, isError in
            guard let self else { return }
            if !isError, line.hasPrefix(self.marker) {
                let path = String(line.dropFirst(self.marker.count))
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath:path,isDirectory:&isDirectory), isDirectory.boolValue { self.directory = URL(fileURLWithPath:path) }
                pendingBlank = false; return
            }
            // The blank line printed just before the marker is ours, not the command's.
            if pendingBlank { output("",false); pendingBlank = false }
            if !isError, line.isEmpty { pendingBlank = true; return }
            output(Self.plain(line),isError)
        }
        process.onExit = { [weak self] status in self?.running = nil; done(status) }
        running = process
        do { try process.start() } catch { running = nil; throw error }
    }

    func stop() { running?.stop() }
}
