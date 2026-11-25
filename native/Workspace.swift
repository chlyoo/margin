import Foundation

enum WorkspaceRules {
    static let ignoredDirectories: Set<String> = [".git","node_modules","build",".build","DerivedData","dist","target",".venv","venv","__pycache__",".next",".cache","Pods",".idea",".gradle",".terraform"]
    static let maxBytes = 1_048_576
    static let maxFiles = 20000
    static func ignored(_ path: String) -> Bool { path.split(separator:"/").dropLast().contains { ignoredDirectories.contains(String($0)) } }
    static func secret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix(".env") || name == ".npmrc" || name == ".netrc" || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") { return true }
        if ["pem","key","p12","pfx","keystore","jks"].contains((name as NSString).pathExtension) { return true }
        return name.contains("credential") || name.contains("secret")
    }
    static func safe(_ path: String) -> Bool { !path.isEmpty && !path.hasPrefix("/") && !path.split(separator:"/",omittingEmptySubsequences:false).contains { $0 == ".." || $0.isEmpty } }
}

struct WorkspaceEntry: Equatable {
    let size: Int
    let modified: Date
    let text: String
}

/// What a workspace looked like at one moment. `tracked` is fixed at the first snapshot and only grows by newly created files,
/// so a file is never reported as deleted or created just because another file changed where the cap falls.
struct WorkspaceSnapshot {
    var entries: [String:WorkspaceEntry] = [:]
    var known: Set<String> = []
    var tracked: Set<String> = []
    var total: Int { known.count }
}

struct WorkspaceScanner {
    let root: URL
    let cap: Int
    init(root: URL, cap: Int = WorkspaceRules.maxFiles) { self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.cap = cap }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    /// Relative paths of the files a person would browse: no ignored build folders, capped in count.
    func list() -> [String] { Array(listAll().prefix(cap)) }

    /// Every browsable path, so callers can tell the person when the cap cut the workspace short.
    func listAll() -> [String] {
        let paths = (gitList() ?? walk()).filter { WorkspaceRules.safe($0) && !WorkspaceRules.ignored($0) }
        return Set(paths).sorted()
    }

    private func gitList() -> [String]? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/git")
        process.arguments = ["-C",root.path,"ls-files","-co","--exclude-standard","-z"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data.split(separator:0).compactMap { String(data:Data($0),encoding:.utf8) }
    }

    private func walk() -> [String] {
        var result: [String] = [], folders = [""]
        while let folder = folders.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath:folder.isEmpty ? root.path : root.path + "/" + folder) else { continue }
            for name in names {
                let path = folder.isEmpty ? name : folder + "/" + name
                var info = stat()
                guard lstat(root.path + "/" + path,&info) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFDIR { if !WorkspaceRules.ignoredDirectories.contains(name) { folders.append(path) } }
                else if info.st_mode & S_IFMT == S_IFREG { result.append(path) }
            }
            if result.count > WorkspaceRules.maxFiles * 4 { break }
        }
        return result
    }

    /// Size and modification time of a regular file, straight from `lstat`: a workspace has thousands of these to check per step.
    func stamp(_ path: String) -> (size: Int, modified: Date)? {
        var info = stat()
        guard lstat(root.path + "/" + path,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return (Int(info.st_size),Date(timeIntervalSince1970:Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000))
    }

    /// Text of every reviewable file. Secret-like, oversized and non-UTF-8 files are left out on purpose.
    func snapshot(previous: WorkspaceSnapshot? = nil) -> WorkspaceSnapshot {
        let all = listAll().filter { !WorkspaceRules.secret($0) }
        var result = WorkspaceSnapshot()
        result.known = Set(all)
        if let previous {
            result.tracked = Set(all.filter { previous.tracked.contains($0) })
            // New files join in listing order until the tracked set is twice the cap; a build that emits more stays listed but unread.
            for path in all where !previous.known.contains(path) { if result.tracked.count >= cap * 2 { break }; result.tracked.insert(path) }
        }
        else { result.tracked = Set(all.prefix(cap)) }
        for path in result.tracked {
            guard let stamp = stamp(path), stamp.size <= WorkspaceRules.maxBytes else { continue }
            if let old = previous?.entries[path], old.size == stamp.size, old.modified == stamp.modified { result.entries[path] = old; continue }
            guard let data = try? Data(contentsOf:url(path)), let text = String(data:data,encoding:.utf8) else { continue }
            result.entries[path] = WorkspaceEntry(size:stamp.size,modified:stamp.modified,text:text)
        }
        return result
    }
}

struct FileChange: Codable, Equatable {
    let path: String
    let before: String?
    let after: String?
}

struct AgentAction: Codable, Equatable {
    let tool: String
    let detail: String
}

struct AgentStep: Codable, Equatable {
    let id: String
    var reasoning: String
    var actions: [AgentAction]
    var changes: [FileChange]
    var decision = "pending"
}

enum AgentEvent: Equatable {
    case session(String)
    case text(String)
    case toolUse(id: String, tool: String, detail: String)
    case toolResult(id: String, failed: Bool)
    case finished(text: String, failed: Bool)
    case raw(String)
}

enum AgentStream {
    /// One line of `claude -p --output-format stream-json`. Lines that are not JSON come back as `.raw` so they stay visible.
    static func parse(_ line: String) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using:.utf8), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let type = object["type"] as? String else { return [.raw(trimmed)] }
        switch type {
        case "system":
            if object["subtype"] as? String == "init", let id = object["session_id"] as? String { return [.session(id)] }
            return []
        case "assistant", "user":
            guard let blocks = (object["message"] as? [String:Any])?["content"] as? [[String:Any]] else { return [] }
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text": return (block["text"] as? String).flatMap { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || type == "user" ? nil : .text($0) }
                case "thinking": return (block["thinking"] as? String).flatMap { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : .text($0) }
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                    let input = block["input"] as? [String:Any] ?? [:]
                    var detail = input["command"] as? String ?? input["file_path"] as? String ?? input["pattern"] as? String ?? ""
                    if detail.isEmpty, let data = try? JSONSerialization.data(withJSONObject:input,options:[.sortedKeys]) { detail = String(data:data,encoding:.utf8) ?? "" }
                    return .toolUse(id:id,tool:name,detail:String(detail.prefix(600)))
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { return nil }
                    return .toolResult(id:id,failed:block["is_error"] as? Bool == true)
                default: return nil
                }
            }
        case "result":
            return [.finished(text:object["result"] as? String ?? "",failed:object["is_error"] as? Bool == true)]
        default: return []
        }
    }
}

/// Turns the event stream plus what changed on disk into ordered steps.
/// Attribution is by disk state, not tool input, because agents also edit through shell commands.
/// With `background` set, every file read runs in order on one serial queue and results come back on the main queue,
/// so a large workspace never blocks the window. Without it everything runs inline, which the checks rely on.
final class StepRecorder {
    let scanner: WorkspaceScanner
    private(set) var steps: [AgentStep] = []
    private(set) var sessionID: String?
    private(set) var summary = ""
    /// Every reviewable path, as of the last finished scan.
    private(set) var paths: [String] = []
    private(set) var untracked = 0
    var total: Int { paths.count }
    private var snapshot = WorkspaceSnapshot()
    private var primed = false
    private var reasoning: [String] = []
    private var actions: [AgentAction] = []
    private var open: Set<String> = []
    private var mutating = false
    private var epoch = 0
    private let queue: DispatchQueue?
    var onStep: ((AgentStep) -> Void)?

    init(root: URL, steps: [AgentStep] = [], sessionID: String? = nil, background: Bool = false) {
        scanner = WorkspaceScanner(root:root)
        queue = background ? DispatchQueue(label:"com.peterlyoo.Margin.scan",qos:.userInitiated) : nil
        self.steps = steps; self.sessionID = sessionID
        io({ self.scan() }) { self.note($0) }
    }

    private func io<T>(_ work: @escaping () -> T, _ done: @escaping (T) -> Void) {
        guard let queue else { done(work()); return }
        queue.async { let value = work(); DispatchQueue.main.async { done(value) } }
    }
    private struct Scan { var changes: [FileChange]; var paths: [String]; var untracked: Int }
    /// Only ever runs on the I/O queue (or inline without one): `snapshot` and `primed` belong to it.
    private func scan() -> Scan {
        let current = scanner.snapshot(previous:primed ? snapshot : nil)
        var changes: [FileChange] = []
        if primed {
            for path in Set(snapshot.entries.keys).union(current.entries.keys).sorted() where snapshot.entries[path]?.text != current.entries[path]?.text {
                changes.append(FileChange(path:path,before:snapshot.entries[path]?.text,after:current.entries[path]?.text))
            }
        }
        snapshot = current; primed = true
        return Scan(changes:changes,paths:current.known.sorted(),untracked:current.known.count - current.tracked.count)
    }
    private func note(_ scan: Scan) { paths = scan.paths; untracked = scan.untracked }

    /// Runs `done` after every file read queued so far has finished.
    func whenIdle(_ done: @escaping () -> Void) { io({ () }) { done() } }

    /// Call before a run starts so edits made between runs are not blamed on the agent.
    func rebase(then: (() -> Void)? = nil) {
        reasoning = []; actions = []; open = []; mutating = false; epoch += 1
        io({ self.scan() }) { self.note($0); then?() }
    }

    /// Takes the current disk text of one file as the baseline, so an edit the person saved is not recorded as the agent's.
    func absorb(_ path: String) {
        guard !WorkspaceRules.secret(path) else { return }
        io({
            guard let stamp = self.scanner.stamp(path), stamp.size <= WorkspaceRules.maxBytes, let data = try? Data(contentsOf:self.scanner.url(path)), let text = String(data:data,encoding:.utf8) else { self.snapshot.entries[path] = nil; return }
            self.snapshot.known.insert(path); self.snapshot.tracked.insert(path)
            self.snapshot.entries[path] = WorkspaceEntry(size:stamp.size,modified:stamp.modified,text:text)
        }) { }
    }

    func decide(_ index: Int, _ decision: String) { if steps.indices.contains(index) { steps[index].decision = decision } }

    /// After one part of a change was undone on disk: the step keeps only what is still applied, so a later whole-step reject still matches.
    func dropHunk(step: Int, change: Int, after: String) {
        guard steps.indices.contains(step), steps[step].changes.indices.contains(change) else { return }
        let old = steps[step].changes[change]
        steps[step].changes[change] = FileChange(path:old.path,before:old.before,after:after)
        if steps[step].changes.allSatisfy({ $0.before == $0.after }) { steps[step].decision = "rejected" }
    }

    /// The reason shown for a step. Lines the agent marked with `WHY:` win; without any, everything it said is kept.
    static func reason(_ said: [String]) -> String {
        var marked: [String] = []
        for block in said {
            var open = false
            for line in block.components(separatedBy:"\n") {
                let trimmed = line.trimmingCharacters(in:.whitespaces)
                if let range = trimmed.range(of:"WHY:"), trimmed.distance(from:trimmed.startIndex,to:range.lowerBound) <= 4 {
                    marked.append(String(trimmed[range.upperBound...]).trimmingCharacters(in:.whitespaces)); open = true
                } else if open, !trimmed.isEmpty { marked[marked.count - 1] += " " + trimmed } else { open = false }
            }
        }
        marked.removeAll { $0.isEmpty }
        return marked.isEmpty ? said.joined(separator:"\n\n") : marked.joined(separator:"\n\n")
    }

    @discardableResult func feed(_ line: String) -> [AgentEvent] {
        let events = AgentStream.parse(line)
        for event in events { handle(event) }
        return events
    }

    func handle(_ event: AgentEvent) {
        switch event {
        case .session(let id): sessionID = id
        case .text(let value): reasoning.append(value.trimmingCharacters(in:.whitespacesAndNewlines))
        case .toolUse(let id, let tool, let detail):
            open.insert(id); actions.append(AgentAction(tool:tool,detail:detail))
            // Reading tools cannot change a file, so a batch made only of them needs no scan.
            if !["Read","Glob","Grep"].contains(tool) { mutating = true }
        case .toolResult(let id, _): open.remove(id); if open.isEmpty, mutating { capture() }
        case .finished(let text, _): open = []; capture(); summary = text
        case .raw: break
        }
    }

    /// Records whatever changed since the last capture as one step, with the reasons and tools seen up to this call.
    func capture(then: (() -> Void)? = nil) {
        let reason = reasoning, tools = actions, started = epoch
        reasoning = []; actions = []; mutating = false
        io({ self.scan() }) { scan in
            self.note(scan)
            if scan.changes.isEmpty {
                // Nothing changed: the reasons still belong to whatever change comes next.
                if started == self.epoch { self.reasoning = reason + self.reasoning; self.actions = tools + self.actions }
            } else {
                let step = AgentStep(id:UUID().uuidString,reasoning:Self.reason(reason),actions:tools,changes:scan.changes)
                self.steps.append(step)
                self.onStep?(step)
            }
            then?()
        }
    }
}

struct DiffLine: Equatable {
    let kind: Character
    let text: String
    let old: Int?
    let new: Int?
}

struct DiffHunk: Equatable {
    let oldStart: Int
    let oldLines: [String]
    let newStart: Int
    let newLines: [String]
}

enum LineDiff {
    static func lines(_ text: String) -> [String] { text.components(separatedBy:"\n") }

    static func script(before: String, after: String) -> [DiffLine] {
        let old = lines(before), new = lines(after)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from:old) {
            switch change { case .remove(let offset,_,_): removed.insert(offset); case .insert(let offset,_,_): inserted.insert(offset) }
        }
        var result: [DiffLine] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { result.append(DiffLine(kind:"-",text:old[i],old:i,new:nil)); i += 1 }
            else if j < new.count, inserted.contains(j) { result.append(DiffLine(kind:"+",text:new[j],old:nil,new:j)); j += 1 }
            else { result.append(DiffLine(kind:" ",text:i < old.count ? old[i] : new[j],old:i,new:j)); i += 1; j += 1 }
        }
        return result
    }

    static func hunks(before: String, after: String) -> [DiffHunk] {
        var result: [DiffHunk] = [], oldLines: [String] = [], newLines: [String] = [], oldStart = 0, newStart = 0, i = 0, j = 0, open = false
        for line in script(before:before,after:after) {
            if line.kind == " " {
                if open { result.append(DiffHunk(oldStart:oldStart,oldLines:oldLines,newStart:newStart,newLines:newLines)); oldLines = []; newLines = []; open = false }
                i += 1; j += 1; continue
            }
            if !open { open = true; oldStart = i; newStart = j }
            if line.kind == "-" { oldLines.append(line.text); i += 1 } else { newLines.append(line.text); j += 1 }
        }
        if open { result.append(DiffHunk(oldStart:oldStart,oldLines:oldLines,newStart:newStart,newLines:newLines)) }
        return result
    }

    /// Changed lines with `context` unchanged lines around them; `nil` marks a gap.
    static func unified(before: String, after: String, context: Int = 3) -> [DiffLine?] {
        let all = script(before:before,after:after)
        var keep = [Bool](repeating:false,count:all.count)
        for (index, line) in all.enumerated() where line.kind != " " {
            for near in max(0,index - context)...min(all.count - 1,index + context) { keep[near] = true }
        }
        var result: [DiffLine?] = [], last = -1
        for (index, line) in all.enumerated() where keep[index] {
            if last >= 0, index > last + 1 { result.append(nil) }
            result.append(line); last = index
        }
        return result
    }
}

enum StepReverter {
    /// The text that undoes `change` on top of `current`, or a failure when the step's result is no longer intact.
    /// `.success(nil)` means the file should not exist.
    static func reverted(current: String?, change: FileChange) -> Result<String?,MarginError> {
        let conflict = MarginError.message("\(change.path): 이 단계 이후에 같은 부분이 다시 바뀌어서 되돌릴 수 없어요. 파일은 그대로 두었어요.")
        if current == change.after { return .success(change.before) }
        guard let current, let before = change.before, let after = change.after else { return .failure(conflict) }
        let afterLines = LineDiff.lines(after)
        var lines = LineDiff.lines(current)
        var edits: [(range: Range<Int>, replacement: [String])] = []
        for hunk in LineDiff.hunks(before:before,after:after) {
            let lead = Array(afterLines[max(0,hunk.newStart - 3)..<hunk.newStart])
            let tailStart = hunk.newStart + hunk.newLines.count
            let tail = Array(afterLines[tailStart..<min(afterLines.count,tailStart + 3)])
            let needle = lead + hunk.newLines + tail
            guard !needle.isEmpty, needle.count <= lines.count else { return .failure(conflict) }
            let matches = (0...(lines.count - needle.count)).filter { Array(lines[$0..<($0 + needle.count)]) == needle }
            guard matches.count == 1 else { return .failure(conflict) }
            let start = matches[0] + lead.count
            edits.append((start..<(start + hunk.newLines.count),hunk.oldLines))
        }
        guard !edits.isEmpty else { return .failure(conflict) }
        for edit in edits.sorted(by:{ $0.range.lowerBound > $1.range.lowerBound }) { lines.replaceSubrange(edit.range,with:edit.replacement) }
        return .success(lines.joined(separator:"\n"))
    }

    /// Undoes every file change of a step, or none of them.
    static func reject(_ step: AgentStep, root: URL) throws {
        let scanner = WorkspaceScanner(root:root)
        var writes: [(URL, String?)] = []
        for change in step.changes {
            guard WorkspaceRules.safe(change.path) else { throw MarginError.message("\(change.path): 작업 공간 밖의 경로라서 되돌리지 않았어요.") }
            let url = scanner.url(change.path)
            let exists = FileManager.default.fileExists(atPath:url.path)
            let current = exists ? (try? Data(contentsOf:url)).flatMap { String(data:$0,encoding:.utf8) } : nil
            if exists && current == nil { throw MarginError.message("\(change.path): 파일을 읽지 못해서 되돌리지 않았어요.") }
            switch reverted(current:current,change:change) {
            case .success(let text): writes.append((url,text))
            case .failure(let error): throw error
            }
        }
        for (url, text) in writes {
            if let text {
                try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data(text.utf8).write(to:url,options:.atomic)
            } else if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        }
    }
}

struct AgentSession: Codable, Equatable {
    var id: String
    var root: String
    var createdAt: Date
    var prompts: [String]
    var steps: [AgentStep]
    var summary: String
    var agentSessionID: String?
}

struct SessionStore {
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    private func folder(_ root: String) -> URL { directory.appendingPathComponent(MarginHash.data(Data(root.utf8)).prefix(16).description,isDirectory:true) }
    func save(_ session: AgentSession) throws {
        guard UUID(uuidString:session.id) != nil else { throw MarginError.message("세션 ID가 올바르지 않아요.") }
        let target = folder(session.root)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to:target.appendingPathComponent(session.id + ".json"),options:.atomic)
    }
    func sessions(root: String) -> [AgentSession] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at:folder(root),includingPropertiesForKeys:nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? decoder.decode(AgentSession.self,from:Data(contentsOf:$0)) }.sorted { $0.createdAt > $1.createdAt }
    }
}
