/**
 Implements:
   - FR-MD-3: Native file encoding and restoration
   - FR-MD-4: Native paragraph and stale/cursor guards
   - FR-MD-5: Native factual provenance parser
   - FR-MD-7: Durable autosave, error and conflict handling
   - FR-MD-8: Immutable history and restore preserving current edits
   - FR-IDE-1: Workspace listing hides ignored and secret-like files
   - FR-IDE-2: Agent run recorded as ordered steps from disk changes
   - FR-IDE-3: Step diff, reject restores exact bytes, conflicting reject refuses
   - FR-IDE-6: Recorded sessions persist
   - FR-IDE-8: Formatter run, minimal edit, indent rules
   - FR-IDE-9: Terminal screen model and real programs on a PTY
   - NFR-IDE-1: Recorded stream replay, no live AI
 */
import Foundation

enum MarginChecks {
    static func run() throws -> [String: Any] {
        var checks: [String] = []
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            if try !condition() { throw MarginError.message("Check failed: \(name)") }
            checks.append(name)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VersionStore(root: root)
        let record = try store.record(path: nil, name: "검증.md")
        let raw = Data([0xef, 0xbb, 0xbf]) + Data("# 제목\r\n\r\n원래 문장입니다.\r\n".utf8)
        let decoded = try DocumentFormat.decode(raw)
        try check(decoded.text == "# 제목\n\n원래 문장입니다.\n", "LF editor offsets")
        try check(decoded.format.encode(decoded.text) == raw, "CRLF and UTF8 BOM round trip")
        let first = try store.save(record: record, text: decoded.text, format: decoded.format, reason: "열기")
        let duplicate = try store.save(record: record, text: decoded.text, format: decoded.format, reason: "자동저장")
        try check(first.id == duplicate.id, "unchanged autosave creates no duplicate version")
        let second = try store.save(record: record, text: "새 문장입니다.", format: decoded.format, reason: "자동저장")
        let reopened = try VersionStore(root: root)
        try check(try reopened.latest(record.id)?.text == "새 문장입니다.", "durable autosave reopens from disk")
        let restored = try reopened.restore(record: record, versionID: first.id, current: "아직 저장하지 않은 문장입니다.", format: decoded.format)
        try check(restored.text == decoded.text, "restore selects requested version")
        let history = try reopened.versions(record.id)
        try check(history.count == 4, "restore appends instead of erasing history")
        try check(history.contains(where: { $0.text == "아직 저장하지 않은 문장입니다." }), "restore preserves unsaved current source")
        try check(history.contains(where: { $0.id == second.id }), "older version remains immutable")
        let paragraph = MarginParagraph.find(in: decoded.text, cursor: (decoded.text as NSString).range(of: "원래").location)!
        try check(paragraph.text == "원래 문장입니다.", "UTF16 current paragraph")
        try check(MarginParagraph.find(in: "```js\nsecret()\n```", cursor: 9) == nil, "code excluded from AI")
        let proposal = ReviewProposal(range: paragraph.range, original: paragraph.text, replacement: "고친 문장입니다.", reason: "표현", category: "wording", facts: [], searchStatus: "disabled", revision: 2)
        try check(proposal.applies(to: decoded.text, revision: 2, selection: paragraph.range), "current proposal applies")
        try check(!proposal.applies(to: decoded.text, revision: 3, selection: paragraph.range), "stale revision rejected")
        try check(!proposal.applies(to: decoded.text, revision: 2, selection: NSRange(location: 0, length: 0)), "remote cursor cannot accept proposal")
        let file = root.appendingPathComponent("original.md")
        try Data("original".utf8).write(to: file)
        let baseline = MarginHash.data(try Data(contentsOf: file))
        try FileGuard.validate(file, expected: baseline)
        try Data("external edit".utf8).write(to: file)
        var conflict = false
        do { try FileGuard.validate(file, expected: baseline) } catch { conflict = true }
        try check(conflict, "external change blocks autosave overwrite")
        let blockedRoot = root.appendingPathComponent("not-directory")
        try Data().write(to: blockedRoot)
        var failed = false
        do { _ = try VersionStore(root: blockedRoot) } catch { failed = true }
        try check(failed, "disk failure is reported")
        let factParagraph = MarginParagraph(range:NSRange(location:0,length:17),text:"서울은 일본의 수도입니다.")
        let json: [String:Any] = ["replacement":"서울은 대한민국의 수도입니다.","reason":"사실 수정","category":"fact","factChecks":[["claim":factParagraph.text,"verdict":"contradicted","explanation":"서울은 대한민국의 수도예요.","sourceUrls":["https://www.seoul.go.kr/"]]]]
        let rawJSON = String(data:try JSONSerialization.data(withJSONObject:json),encoding:.utf8)!
        let evidence: [String:Any] = ["type":"web_search_tool_result","content":[["type":"web_search_result","url":"https://www.seoul.go.kr/","title":"서울시"]]]
        let backed = try JSONSerialization.data(withJSONObject:["content":[evidence,["type":"text","text":rawJSON]]])
        let result = try ReviewService.parse(backed,paragraph:factParagraph,revision:1,facts:true)
        try check(result.actionable && result.facts.first?.sources.count == 1, "native factual edit uses provider evidence")
        let unsupported = try JSONSerialization.data(withJSONObject:["content":[["type":"text","text":rawJSON]]])
        let unverified = try ReviewService.parse(unsupported,paragraph:factParagraph,revision:1,facts:true)
        try check(!unverified.actionable && unverified.facts.first?.verdict == "unverified", "invented factual sources cannot authorize native edit")
        try check(ReviewService.safeURL("javascript:alert(1)") == nil, "unsafe evidence links rejected")
        let damaged = try store.record(path: nil, name: "손상.md")
        let healthy = try store.save(record: damaged, text: "첫 버전", format: DocumentFormat(), reason: "자동저장")
        let broken = try store.save(record: damaged, text: "둘째 버전", format: DocumentFormat(), reason: "자동저장")
        try Data("{".utf8).write(to: root.appendingPathComponent(damaged.id).appendingPathComponent(broken.id + ".json"))
        try check(try store.latest(damaged.id)?.id == healthy.id, "corrupt latest version falls back to readable version")
        let after = try store.save(record: damaged, text: "셋째 버전", format: DocumentFormat(), reason: "자동저장")
        try check(try store.latest(damaged.id)?.id == after.id && store.versions(damaged.id).count == 2, "save continues after corrupt version")
        try check(try store.summaries(damaged.id).count == 3 && (try? store.version(damaged.id, broken.id)) == nil, "history lists corrupt version without loading it")
        try workspaceChecks(root: root, check: check)
        return ["pass": true, "count": checks.count, "checks": checks, "live_ai_calls": "not-run"]
    }

    /// Stand-in formatters, so the checks do not depend on what is installed on this machine.
    static func formatChecks(root: URL, check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        let tools = root.appendingPathComponent("format-tools"), space = root.appendingPathComponent("format-space")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: space, withIntermediateDirectories: true)
        func tool(_ name: String, _ script: String) throws {
            let url = tools.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try tool("black", "printf 'via-black %s\\n' \"$3\"; cat")
        let search = [tools.path, "/usr/bin", "/bin"]
        try check(CodeFormatter.format("x=1\n", path: "pkg/a.py", directory: space, search: search) == .formatted("via-black pkg/a.py\nx=1\n", tool: "black"), "the formatter gets the text on stdin and the file's workspace path, and the second choice is used when the first is missing")
        try tool("ruff", "tr -s ' ' | sed 's/ *= */ = /'")
        try check(CodeFormatter.format("x   =1\n", path: "a.py", directory: space, search: search) == .formatted("x = 1\n", tool: "ruff") && CodeFormatter.format("x = 1\n", path: "a.py", directory: space, search: search) == .unchanged(tool: "ruff"), "the first listed formatter wins and already formatted text is reported unchanged")
        try tool("gofmt", "cat >/dev/null; echo 'a.go:1:1: expected declaration' >&2; exit 2")
        var refused = false
        if case .failed(let message) = CodeFormatter.format("func {\n", path: "a.go", directory: space, search: search) { refused = message.contains("expected declaration") && message.contains("2") }
        try check(refused, "a formatter that fails changes nothing and reports its message")
        try tool("rustfmt", "sleep 30")
        var slow = false
        let started = Date()
        if case .failed = CodeFormatter.format("fn main(){}\n", path: "a.rs", directory: space, search: search, timeout: 1) { slow = Date().timeIntervalSince(started) < 10 }
        try check(slow, "a formatter that hangs is stopped at the time limit")
        try check(CodeFormatter.format("a\n", path: "a.lua", directory: space, search: search) == .unavailable(["stylua"]) && CodeFormatter.format("a\n", path: "a.xyz", directory: space, search: search) == .unavailable([]), "a missing formatter is named, an unknown file type has none")
        let large = String(repeating: "value = 1\n", count: 120_000)
        try tool("prettier", "cat")
        try check(CodeFormatter.format(large, path: "big.md", directory: space, search: search) == .unchanged(tool: "prettier"), "a 1 MB file passes through the pipes without blocking")
        let edit = CodeFormatter.edit(before: "a = 1\nb=😀2\nc = 3\n", after: "a = 1\nb = 😀2\nc = 3\n")
        try check(edit.range == NSRange(location: 7, length: 1) && edit.replacement == " = " && ("a = 1\nb=😀2\nc = 3\n" as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == "a = 1\nb = 😀2\nc = 3\n", "only the changed middle of the text is replaced")
        let python = "def f(a):\n    if a:\n        return 1\n"
        try check(CodeIndent.unit(python, path: "a.py") == "    " && CodeIndent.unit("", path: "a.go") == "\t" && CodeIndent.unit("a:\n  b: 1\n", path: "a.yml") == "  " && CodeIndent.newline(python, at: 19, unit: "    ") == "\n        " && CodeIndent.newline(python, at: 36, unit: "    ") == "\n        ", "Enter keeps the indent and adds a level after a line that opens a block")
        let shifted = CodeIndent.shift("a\n  b\nc\n", selection: NSRange(location: 0, length: 5), unit: "  ", outdent: false)
        let back = CodeIndent.shift("  a\n    b\nc\n", selection: NSRange(location: 0, length: 9), unit: "  ", outdent: true)
        try check(shifted.replacement == "  a\n    b\n" && shifted.range == NSRange(location: 0, length: 6) && back.replacement == "a\n  b\n", "Tab and Shift-Tab move every selected line by one level")
    }

    static func terminalChecks(root: URL, check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        let e = "\u{1B}"
        var screen = TerminalScreen(cols: 20, rows: 5)
        screen.feed("hello\r\nworld\(e)[1;1HJ\(e)[2;3H\(e)[K")
        try check(screen.text(row: 0) == "Jello" && screen.text(row: 1) == "wo" && screen.x == 2 && screen.y == 1, "cursor addressing and erase to end of line")
        screen = TerminalScreen(cols: 10, rows: 3)
        screen.feed("0123456789ab")
        try check(screen.text(row: 0) == "0123456789" && screen.text(row: 1) == "ab" && screen.x == 2, "text wraps at the right edge only when the next character arrives")
        screen = TerminalScreen(cols: 10, rows: 5)
        screen.feed("top\r\n\(e)[2;4r\(e)[2;1Ha\r\nb\r\nc\r\nd\(e)[r")
        try check(screen.screenText == "top\nb\nc\nd\n" && screen.scrollback.isEmpty, "a scroll region scrolls only its own lines and keeps them out of history")
        screen = TerminalScreen(cols: 20, rows: 4)
        screen.feed("primary\(e)[?1049h\(e)[2J\(e)[Hfull screen\(e)[?1049l!")
        try check(screen.screenText == "primary!\n\n\n" && !screen.alt, "leaving the alternate screen restores the earlier screen and cursor")
        screen = TerminalScreen(cols: 20, rows: 2)
        screen.feed("\(e)[1;31;48;5;200mX\(e)[0;38;2;1;2;3mY\(e)[7mZ\(e)[m ")
        try check(screen.lines[0][0].style == TermStyle(fg: 1, bg: 200, bold: true) && screen.lines[0][1].style.fg == 0x1000000 | 0x010203 && screen.lines[0][2].style.inverse && screen.lines[0][3].style == TermStyle(), "colours and attributes: 16, 256 and direct colour")
        screen = TerminalScreen(cols: 6, rows: 3)
        screen.feed("한a")
        let wide = screen.lines[0][0].width == 2 && screen.lines[0][1].width == 0 && screen.lines[0][2].text == "a" && screen.x == 3
        screen.feed("\(e)[1;2Hb")
        let halved = screen.lines[0][0].text == " " && screen.lines[0][1].text == "b" && screen.text(row: 0) == " ba"
        screen.feed("\(e)[1;6H글")
        try check(wide && halved && screen.text(row: 1) == "글" && screen.x == 2 && screen.y == 1, "a Hangul syllable takes two cells, is never left half overwritten, and wraps whole")
        screen = TerminalScreen(cols: 20, rows: 3)
        var answers: [String] = []
        screen.onResponse = { answers.append($0) }
        screen.feed("\(e)[2;5H\(e)[6n\(e)[c\(e)(0qx\(e)(Bq")
        try check(answers == ["\(e)[2;5R", "\(e)[?1;2c"] && screen.text(row: 1) == "    ─│q", "position and identity queries are answered, line-drawing characters are mapped")
        screen = TerminalScreen(cols: 10, rows: 3)
        screen.feed("abcdef\(e)[1;3H\(e)[2P")
        let deleted = screen.text(row: 0) == "abef"
        screen.feed("\(e)[2@\r\n1\r\n2\(e)[2;1H\(e)[L")
        try check(deleted && screen.screenText == "ab  ef\n\n1", "insert and delete of characters and lines")
        screen = TerminalScreen(cols: 10, rows: 3)
        screen.feed("1\r\n2\r\n3\r\n4\r\n5")
        let history = screen.scrollback.map { TerminalScreen.text($0) } == ["1", "2"] && screen.screenText == "3\n4\n5"
        screen.resize(cols: 8, rows: 2)
        try check(history && screen.scrollback.count == 3 && screen.screenText == "4\n5" && screen.y == 1, "lines scrolled off the top are kept, and shrinking moves more into history")
        screen = TerminalScreen(cols: 10, rows: 2)
        let bytes = Array("한글".utf8)
        screen.feed(Data(bytes[0..<2])); screen.feed(Data(bytes[2..<4])); screen.feed(Data(bytes[4...]))
        try check(screen.text(row: 0) == "한글", "a character split across two reads is put back together")
        try check(TerminalView.bytes(keyCode: 126, characters: nil, shift: false, control: false, option: false, appCursor: true) == "\(e)OA" && TerminalView.bytes(keyCode: 126, characters: nil, shift: false, control: false, option: false, appCursor: false) == "\(e)[A"
            && TerminalView.bytes(keyCode: 8, characters: "c", shift: false, control: true, option: false, appCursor: false) == "\u{3}" && TerminalView.bytes(keyCode: 123, characters: nil, shift: false, control: false, option: true, appCursor: false) == "\(e)b"
            && TerminalView.bytes(keyCode: 48, characters: "\t", shift: true, control: false, option: false, appCursor: false) == "\(e)[Z" && TerminalView.bytes(keyCode: 0, characters: "a", shift: false, control: false, option: false, appCursor: false) == nil
            && TerminalView.bytes(keyCode: 8, characters: "ㅊ", shift: false, control: true, option: false, appCursor: false) == "\u{3}" && TerminalView.bytes(keyCode: 8, characters: "ㅊ", shift: false, control: false, option: false, appCursor: false) == nil, "keys map to the bytes a terminal program expects; plain letters go to the input method")

        let space = root.appendingPathComponent("terminal-space")
        try FileManager.default.createDirectory(at: space, withIntermediateDirectories: true)
        let sized = try PTYSession.capture(executable: "/bin/sh", arguments: ["sh", "-c", "tty; stty size; pwd"], directory: space, cols: 100, rows: 30)
        try check(sized.status == 0 && sized.screen.screenText.contains("/dev/ttys") && sized.screen.screenText.contains("30 100") && sized.screen.screenText.contains("terminal-space"), "the program runs on a real terminal device of the given size, in the workspace folder")
        let interrupted = try PTYSession.capture(executable: "/bin/zsh", arguments: ["zsh", "-fc", "sleep 100"], directory: space, keys: ["\u{3}"], timeout: 15)
        try check(interrupted.status == 130, "Ctrl-C interrupts the running program")
        let shell = try PTYSession.capture(executable: "/bin/zsh", arguments: ["-zsh", "-f", "-i"], directory: space, keys: ["echo $((6*7)) 한글\r", "exit\r"], timeout: 15)
        try check(shell.status == 0 && shell.screen.screenText.contains("42 한글") && !shell.screen.screenText.contains("tty pgrp") && !shell.screen.screenText.contains("job control"), "an interactive shell has job control and echoes Hangul")
        let resized = try PTYSession.capture(executable: "/bin/sh", arguments: ["sh", "-c", "sleep 1.5; stty size"], directory: space, resizeTo: (120, 40))
        try check(resized.status == 0 && resized.screen.screenText.contains("40 120"), "a size change reaches the program")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/vim") {
            let edited = try PTYSession.capture(executable: "/usr/bin/vim", arguments: ["vim", "-u", "NONE", "-N", "-i", "NONE", "note.txt"], directory: space, keys: ["ihello 한글\u{1B}", ":wq\r"], timeout: 20)
            let written = (try? String(contentsOf: space.appendingPathComponent("note.txt"), encoding: .utf8)) ?? ""
            try check(edited.status == 0 && edited.sawAlt && !edited.screen.alt && written == "hello 한글\n", "vim runs full screen, takes keys, writes the file, and the earlier screen comes back")
        }
        try Data((1...200).map { "line \($0)" }.joined(separator: "\n").utf8).write(to: space.appendingPathComponent("long.txt"))
        let paged = try PTYSession.capture(executable: "/usr/bin/less", arguments: ["less", "long.txt"], directory: space, keys: ["G", "q"], timeout: 15)
        try check(paged.status == 0 && paged.sawAlt && !paged.screen.alt, "less pages a file full screen and quits cleanly")
    }

    static func fixtureLines() throws -> [String] {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("fixtures/agent-stream.jsonl") else { throw MarginError.message("fixture missing") }
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    static let fixtureCalc = "def add(a, b):\n    return a - b\n\nprint(add(2, 3))\n"
    static let fixtureReadme = "# probe\n\nadd 함수 설명.\n"

    static func makeFixtureWorkspace(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data(fixtureCalc.utf8).write(to: root.appendingPathComponent("calc.py"))
        try Data(fixtureReadme.utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("TOKEN=not-a-real-value\n".utf8).write(to: root.appendingPathComponent(".env"))
        try Data("module.exports = 1\n".utf8).write(to: root.appendingPathComponent("node_modules/pkg/index.js"))
    }

    /// The file edits the agent made for one line of the recorded stream, applied just before the matching tool result, as they were in the real run.
    static func fixtureEffects(root: URL, line: String, tools: inout [String: AgentAction]) throws {
        for event in AgentStream.parse(line) {
            if case let .toolUse(id, tool, detail) = event { tools[id] = AgentAction(tool: tool, detail: detail) }
            if case let .toolResult(id, _) = event, let action = tools[id] {
                if action.tool == "Edit" { try Data(fixtureCalc.replacingOccurrences(of: "a - b", with: "a + b").utf8).write(to: root.appendingPathComponent("calc.py")) }
                if action.detail.contains("sed -i") {
                    try Data((fixtureReadme + "add(a, b)는 두 수의 합을 반환합니다.\n").utf8).write(to: root.appendingPathComponent("README.md"))
                    try Data("TOKEN=changed\n".utf8).write(to: root.appendingPathComponent(".env"))
                }
            }
        }
    }

    static func replayFixture(root: URL, feed: (String) -> [AgentEvent]) throws {
        var tools: [String: AgentAction] = [:]
        for line in try fixtureLines() {
            try fixtureEffects(root: root, line: line, tools: &tools)
            _ = feed(line)
        }
    }

    static func workspaceChecks(root: URL, check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        let space = root.appendingPathComponent("workspace")
        try makeFixtureWorkspace(space)
        let scanner = WorkspaceScanner(root: space)
        let listed = scanner.list()
        try check(listed.contains("calc.py") && listed.contains("README.md") && !listed.contains { $0.hasPrefix("node_modules/") }, "workspace listing hides ignored build folders")
        try check(scanner.snapshot().entries[".env"] == nil && scanner.snapshot().entries["calc.py"]?.text == fixtureCalc, "secret-like files are never snapshotted")
        let recorder = StepRecorder(root: space)
        var raw = 0
        try replayFixture(root: space) { line in
            let events = recorder.feed(line)
            raw += events.filter { if case .raw = $0 { return true }; return false }.count
            return events
        }
        let steps = recorder.steps
        try check(steps.count == 2 && steps[0].changes.map(\.path) == ["calc.py"] && steps[1].changes.map(\.path) == ["README.md"], "agent run becomes ordered steps, one per changing tool batch")
        try check(steps.first?.reasoning.contains("a - b") == true && steps.first?.reasoning.contains("현재 내용을 확인") == true, "step carries the reasoning stated since the previous step")
        try check(steps.last?.actions.contains { $0.tool == "Bash" && $0.detail.contains("sed -i") } == true && steps.last?.changes.first?.after?.hasSuffix("반환합니다.\n") == true, "shell-command edits are captured from disk")
        try check(recorder.sessionID == "fixture-session" && !recorder.summary.isEmpty && raw == 1, "session id, summary and non-JSON lines survive parsing")
        let hunks = LineDiff.hunks(before: fixtureCalc, after: steps[0].changes[0].after ?? "")
        try check(hunks == [DiffHunk(oldStart: 1, oldLines: ["    return a - b"], newStart: 1, newLines: ["    return a + b"])], "line diff isolates the changed line")
        try StepReverter.reject(steps[1], root: space)
        try check(try Data(contentsOf: space.appendingPathComponent("README.md")) == Data(fixtureReadme.utf8), "reject restores exact previous bytes")
        let base = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let first = base.replacingOccurrences(of: "line 2\n", with: "line two\n"), second = first.replacingOccurrences(of: "line 11\n", with: "line eleven\n")
        let early = FileChange(path: "notes.txt", before: base, after: first)
        if case let .success(text) = StepReverter.reverted(current: second, change: early) { try check(text == base.replacingOccurrences(of: "line 11\n", with: "line eleven\n"), "earlier step reverts under a later independent edit") }
        else { try check(false, "earlier step reverts under a later independent edit") }
        let clash = first.replacingOccurrences(of: "line two\n", with: "line 2 again\n")
        try Data(clash.utf8).write(to: space.appendingPathComponent("notes.txt"))
        var refused = false
        do { try StepReverter.reject(AgentStep(id: UUID().uuidString, reasoning: "", actions: [], changes: [early, FileChange(path: "calc.py", before: fixtureCalc, after: steps[0].changes[0].after)]), root: space) } catch { refused = true }
        try check(refused && (try String(contentsOf: space.appendingPathComponent("notes.txt"), encoding: .utf8)) == clash && (try String(contentsOf: space.appendingPathComponent("calc.py"), encoding: .utf8)).contains("a + b"), "conflicting reject refuses and writes nothing")
        try Data("new\n".utf8).write(to: space.appendingPathComponent("made.txt"))
        try StepReverter.reject(AgentStep(id: UUID().uuidString, reasoning: "", actions: [], changes: [FileChange(path: "made.txt", before: nil, after: "new\n")]), root: space)
        try check(!FileManager.default.fileExists(atPath: space.appendingPathComponent("made.txt").path), "rejecting a created file removes it")
        var outside = false
        do { try StepReverter.reject(AgentStep(id: UUID().uuidString, reasoning: "", actions: [], changes: [FileChange(path: "../escape.txt", before: "x", after: nil)]), root: space) } catch { outside = true }
        try check(outside && !FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path), "paths outside the workspace are refused")
        let crowded = root.appendingPathComponent("crowded")
        try FileManager.default.createDirectory(at: crowded, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] { try Data("\(name)\n".utf8).write(to: crowded.appendingPathComponent(name)) }
        let capped = WorkspaceScanner(root: crowded, cap: 3)
        let opening = capped.snapshot()
        try Data("new\n".utf8).write(to: crowded.appendingPathComponent("0new.txt"))
        let later = capped.snapshot(previous: opening)
        try check(opening.entries.keys.sorted() == ["a.txt", "b.txt", "c.txt"] && later.entries.keys.sorted() == ["0new.txt", "a.txt", "b.txt", "c.txt"] && later.known.count == 5, "a file past the cap is never reported as deleted or created when another file appears")
        for index in 0..<6 { try Data("n\n".utf8).write(to: crowded.appendingPathComponent("1new\(index).txt")) }
        let flooded = capped.snapshot(previous: later)
        try check(flooded.tracked.count == 6 && flooded.known.count == 11 && flooded.tracked.isSuperset(of: later.tracked), "newly created files stop being tracked at twice the cap")
        try formatChecks(root: root, check: check)
        try terminalChecks(root: root, check: check)
        let nodes = StudioNode.tree(["src/a.swift", "src", "src/deep/b.swift", "README.md", "src/deep/c.swift"])
        try check(nodes.map(\.name) == ["src", "README.md", "src"] && nodes[0].isDirectory && nodes[0].children.map(\.name) == ["deep", "a.swift"] && nodes[0].children[0].children.count == 2 && !nodes[2].isDirectory, "the tree groups files under one node per folder")
        let quiet = StepRecorder(root: crowded)
        quiet.handle(.text("읽기만 합니다."))
        quiet.handle(.toolUse(id: "r1", tool: "Read", detail: "a.txt"))
        try Data("edited meanwhile\n".utf8).write(to: crowded.appendingPathComponent("a.txt"))
        quiet.handle(.toolResult(id: "r1", failed: false))
        let skipped = quiet.steps.isEmpty
        quiet.handle(.finished(text: "끝", failed: false))
        try check(skipped && quiet.steps.count == 1 && quiet.steps[0].reasoning == "읽기만 합니다.", "a batch of reading tools triggers no scan, and the end of the run still records what changed")
        try check(StepRecorder.reason(["SDLC는 생략합니다. 먼저 파일을 확인하겠습니다.", "WHY: add가 뺄셈을 하고 있어서\n덧셈으로 고칩니다.\n\n이제 편집합니다."]) == "add가 뺄셈을 하고 있어서 덧셈으로 고칩니다." && StepRecorder.reason(["표시 없이 말한 이유"]) == "표시 없이 말한 이유", "only the marked reason is kept for a step, and unmarked text is kept when there is no mark")
        try Data(base.utf8).write(to: space.appendingPathComponent("parts.txt"))
        let partial = StepRecorder(root: space)
        partial.handle(.toolUse(id: "p1", tool: "Edit", detail: "parts.txt"))
        try Data(second.utf8).write(to: space.appendingPathComponent("parts.txt"))
        partial.handle(.toolResult(id: "p1", failed: false))
        let kept = base.replacingOccurrences(of: "line 2\n", with: "line two\n")
        try StepReverter.reject(AgentStep(id: "", reasoning: "", actions: [], changes: [FileChange(path: "parts.txt", before: kept, after: second)]), root: space)
        partial.dropHunk(step: 0, change: 0, after: kept)
        let half = try String(contentsOf: space.appendingPathComponent("parts.txt"), encoding: .utf8)
        try StepReverter.reject(partial.steps[0], root: space)
        try check(half == kept && partial.steps[0].decision == "pending" && (try String(contentsOf: space.appendingPathComponent("parts.txt"), encoding: .utf8)) == base, "one part of a step is undone alone, and the rest still rejects cleanly afterwards")
        let sessions = try SessionStore(directory: root.appendingPathComponent("sessions"))
        var session = AgentSession(id: UUID().uuidString, root: space.path, createdAt: Date(timeIntervalSince1970: 1_800_000_000), prompts: ["고쳐 줘"], steps: steps, summary: recorder.summary, agentSessionID: recorder.sessionID)
        session.steps[0].decision = "accepted"
        try sessions.save(session)
        try check(sessions.sessions(root: space.path) == [session] && sessions.sessions(root: "/elsewhere").isEmpty, "recorded session persists per workspace with decisions")
    }
}
