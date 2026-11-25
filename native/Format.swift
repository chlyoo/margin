/**
 Implements:
   - FR-IDE-8: Language formatter run on the open file; indent on Enter, Tab and Shift-Tab
 */
import Foundation

struct FormatTool {
    let name: String
    /// Arguments for a run that reads the text on stdin and writes the result on stdout. The parameter is the file's path inside the workspace.
    let arguments: (String) -> [String]
}

enum FormatOutcome: Equatable {
    case formatted(String, tool: String)
    case unchanged(tool: String)
    case unavailable([String])
    case failed(String)
}

enum CodeFormatter {
    private static let prettier = FormatTool(name:"prettier") { ["--stdin-filepath",$0] }
    private static let clang = FormatTool(name:"clang-format") { ["--assume-filename=" + $0] }
    static let table: [(extensions: Set<String>, tools: [FormatTool])] = [
        (["py","pyi"],[FormatTool(name:"ruff") { ["format","--stdin-filename",$0,"-"] },FormatTool(name:"black") { ["-q","--stdin-filename",$0,"-"] }]),
        (["go"],[FormatTool(name:"gofmt") { _ in [] }]),
        (["rs"],[FormatTool(name:"rustfmt") { _ in ["--emit","stdout","--edition","2021"] }]),
        (["swift"],[FormatTool(name:"swift-format") { ["format","--assume-filename",$0] }]),
        (["json"],[prettier,FormatTool(name:"jq") { _ in ["."] }]),
        (["js","jsx","mjs","cjs","ts","tsx","jsonc","css","scss","less","html","vue","yaml","yml","md","markdown","graphql"],[prettier]),
        (["sh","bash"],[FormatTool(name:"shfmt") { ["-filename",$0] }]),
        (["c","h","cc","cpp","cxx","hpp","m","mm","java","proto"],[clang]),
        (["lua"],[FormatTool(name:"stylua") { ["--stdin-filepath",$0,"-"] }]),
        (["tf","tfvars"],[FormatTool(name:"terraform") { _ in ["fmt","-"] }]),
        (["toml"],[FormatTool(name:"taplo") { _ in ["format","-"] }]),
    ]

    static func tools(for path: String) -> [FormatTool] {
        let kind = (path as NSString).pathExtension.lowercased()
        return table.first { $0.extensions.contains(kind) }?.tools ?? []
    }

    static var commonDirectories: [String] {
        let home = NSHomeDirectory()
        return [home + "/.local/bin","/opt/homebrew/bin","/usr/local/bin",home + "/.cargo/bin",home + "/go/bin",home + "/.pyenv/shims","/usr/bin","/bin"]
    }
    private static let lock = NSLock()
    private static var located: [String:String] = [:]
    private static var shellPath: [String]?

    /// The app is usually started by Finder, whose PATH has none of the person's tool folders. Their login shell knows them.
    private static func loginPath() -> [String] {
        lock.lock(); let known = shellPath; lock.unlock()
        if let known { return known }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath:$0) ? $0 : nil } ?? "/bin/zsh"
        let marker = "__margin_path__"
        let result = run(shell,["-lic","printf '\\n\(marker)%s\\n' \"$PATH\""],input:Data(),directory:URL(fileURLWithPath:NSHomeDirectory()),environment:[:],timeout:8)
        let line = String(decoding:result.output,as:UTF8.self).components(separatedBy:"\n").last { $0.hasPrefix(marker) } ?? ""
        let found = line.dropFirst(marker.count).split(separator:":").map(String.init).filter { $0.hasPrefix("/") }
        lock.lock(); shellPath = found; lock.unlock()
        return found
    }

    static func locate(_ name: String, search: [String]? = nil) -> String? {
        if let search { return search.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath:$0) } }
        lock.lock(); let known = located[name]; lock.unlock()
        if let known, FileManager.default.isExecutableFile(atPath:known) { return known }
        var found = commonDirectories.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath:$0) }
            ?? loginPath().map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath:$0) }
        if found == nil, FileManager.default.isExecutableFile(atPath:"/usr/bin/xcrun") {
            // Tools that ship inside Xcode are on no PATH.
            let result = run("/usr/bin/xcrun",["--find",name],input:Data(),directory:URL(fileURLWithPath:NSHomeDirectory()),environment:[:],timeout:8)
            let path = String(decoding:result.output,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            if result.status == 0, FileManager.default.isExecutableFile(atPath:path) { found = path }
        }
        lock.lock(); located[name] = found; lock.unlock()
        return found
    }

    struct RunResult { var status: Int32; var output: Data; var errors: Data; var timedOut: Bool }

    /// Feeds stdin and drains both pipes on separate threads: a formatter that writes before it finishes reading would otherwise block forever.
    static func run(_ executable: String, _ arguments: [String], input: Data, directory: URL, environment: [String:String], timeout: TimeInterval) -> RunResult {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath:executable); process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { return RunResult(status:-1,output:Data(),errors:Data(error.localizedDescription.utf8),timedOut:false) }
        var output = Data(), errors = Data()
        let group = DispatchGroup(), queue = DispatchQueue(label:"com.peterlyoo.Margin.format",attributes:.concurrent)
        queue.async(group:group) { output = stdout.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group:group) { errors = stderr.fileHandleForReading.readDataToEndOfFile() }
        queue.async {
            signal(SIGPIPE,SIG_IGN)
            try? stdin.fileHandleForWriting.write(contentsOf:input)
            try? stdin.fileHandleForWriting.close()
        }
        let exited = DispatchSemaphore(value:0)
        queue.async { process.waitUntilExit(); exited.signal() }
        var timedOut = false
        if exited.wait(timeout:.now() + timeout) == .timedOut {
            timedOut = true
            kill(process.processIdentifier,SIGKILL)
            exited.wait()
        }
        _ = group.wait(timeout:.now() + 2)
        return RunResult(status:process.terminationStatus,output:output,errors:errors,timedOut:timedOut)
    }

    /// Blocking; call it off the main thread. `path` is relative to `directory`, so the formatter finds the project's own configuration.
    static func format(_ text: String, path: String, directory: URL, search: [String]? = nil, timeout: TimeInterval = 20) -> FormatOutcome {
        let candidates = tools(for:path)
        guard !candidates.isEmpty else { return .unavailable([]) }
        guard let tool = candidates.first(where: { locate($0.name,search:search) != nil }), let executable = locate(tool.name,search:search) else { return .unavailable(candidates.map(\.name)) }
        let folders = [(executable as NSString).deletingLastPathComponent] + (search ?? commonDirectories + loginPath())
        var seen = Set<String>()
        let path_ = folders.filter { seen.insert($0).inserted }.joined(separator:":")
        let result = run(executable,tool.arguments(path),input:Data(text.utf8),directory:directory,environment:["PATH":path_],timeout:timeout)
        if result.timedOut { return .failed("\(tool.name)이(가) \(Int(timeout))초 안에 끝나지 않았어요.") }
        guard result.status == 0, let output = String(data:result.output,encoding:.utf8), !output.isEmpty || text.isEmpty else {
            let message = String(decoding:result.errors,as:UTF8.self).split(separator:"\n").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }.prefix(3).joined(separator:" · ")
            return .failed("\(tool.name) 종료 코드 \(result.status)" + (message.isEmpty ? "" : " · " + message))
        }
        return output == text ? .unchanged(tool:tool.name) : .formatted(output,tool:tool.name)
    }

    /// The smallest replacement that turns `before` into `after`, in UTF-16 units, never cutting a surrogate pair.
    static func edit(before: String, after: String) -> (range: NSRange, replacement: String) {
        let a = Array(before.utf16), b = Array(after.utf16)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        if head > 0, UTF16.isLeadSurrogate(a[head - 1]) { head -= 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        if tail > 0, UTF16.isTrailSurrogate(a[a.count - tail]) { tail -= 1 }
        return (NSRange(location:head,length:a.count - head - tail),String(decoding:b[head..<(b.count - tail)],as:UTF16.self))
    }
}

enum CodeIndent {
    /// Tabs when the file already indents with tabs (or the language requires them), otherwise the width of its first indented line.
    static func unit(_ text: String, path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased(), kind = (name as NSString).pathExtension
        for line in text.split(separator:"\n",omittingEmptySubsequences:true).prefix(2000) {
            if line.hasPrefix("\t") { return "\t" }
            let spaces = line.prefix { $0 == " " }.count
            if spaces >= 2, spaces < line.count { return String(repeating:" ",count:min(spaces,8)) }
        }
        if kind == "go" || name == "makefile" || kind == "mk" { return "\t" }
        return ["js","jsx","ts","tsx","json","yaml","yml","html","css","scss","rb","lua"].contains(kind) ? "  " : "    "
    }

    /// What Enter inserts at `location`: a newline, the current line's indent, and one more level after a line that opens a block.
    static func newline(_ text: String, at location: Int, unit: String) -> String {
        let string = text as NSString, safe = min(max(location,0),string.length)
        let line = string.lineRange(for:NSRange(location:safe,length:0))
        let before = string.substring(with:NSRange(location:line.location,length:safe - line.location))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let trimmed = before.trimmingCharacters(in:.whitespaces)
        let opens = [":","{","(","["].contains { trimmed.hasSuffix($0) }
        return "\n" + indent + (opens ? unit : "")
    }

    /// Indents or outdents every line the selection touches. Returns the replaced range, its new text and the new selection.
    static func shift(_ text: String, selection: NSRange, unit: String, outdent: Bool) -> (range: NSRange, replacement: String, selection: NSRange) {
        let string = text as NSString
        let lines = string.lineRange(for:selection)
        let block = string.substring(with:lines)
        let ending = block.hasSuffix("\n")
        var parts = block.components(separatedBy:"\n")
        if ending { parts.removeLast() }
        parts = parts.map { line in
            if !outdent { return line.isEmpty ? line : unit + line }
            if line.hasPrefix(unit) { return String(line.dropFirst(unit.count)) }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(min(line.prefix { $0 == " " }.count,unit.count)))
        }
        let replacement = parts.joined(separator:"\n") + (ending ? "\n" : "")
        return (lines,replacement,NSRange(location:lines.location,length:(replacement as NSString).length - (ending ? 1 : 0)))
    }
}
