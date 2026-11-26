import AppKit
import WebKit
import UniformTypeIdentifiers

@main
enum MarginMain {
    static func main() {
        // First thing, before any thread exists: the terminal tab starts this binary as a session leader on the PTY,
        // it takes the PTY as its controlling terminal (macOS needs the explicit call) and becomes the requested program.
        if CommandLine.arguments.count > 3, CommandLine.arguments[1] == PTYSession.trampoline { PTYSession.becomeProgram() }
        do {
            if CommandLine.arguments.contains("--check") {
                let result = try MarginChecks.run()
                print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
                return
            }
            if let index = CommandLine.arguments.firstIndex(of:"--scan-json"), CommandLine.arguments.indices.contains(index + 1) {
                // Diagnostic: how large a workspace is and how long listing and snapshotting it take.
                let scanner = WorkspaceScanner(root:URL(fileURLWithPath:CommandLine.arguments[index + 1]))
                var clock = Date()
                let all = scanner.listAll(); let listed = Date().timeIntervalSince(clock); clock = Date()
                let first = scanner.snapshot(); let cold = Date().timeIntervalSince(clock); clock = Date()
                _ = scanner.snapshot(previous:first); let warm = Date().timeIntervalSince(clock); clock = Date()
                _ = StudioNode.tree(all); let tree = Date().timeIntervalSince(clock)
                let state: [String:Any] = ["files":all.count,"cap":WorkspaceRules.maxFiles,"truncated":all.count > WorkspaceRules.maxFiles,"snapshotted":first.entries.count,"list_ms":Int(listed * 1000),"first_snapshot_ms":Int(cold * 1000),"repeat_snapshot_ms":Int(warm * 1000),"tree_ms":Int(tree * 1000)]
                print(String(data:try JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
                return
            }
            if CommandLine.arguments.contains("--state-json") && !CommandLine.arguments.contains("--ui-check") && !CommandLine.arguments.contains("--quit-check") {
                let store = try VersionStore.applicationStore()
                let records = try store.records()
                let state: [String:Any] = ["app":"Margin","surface":"native-AppKit","bundle":Bundle.main.bundleURL.path,"executable":Bundle.main.executableURL?.path ?? "", "storage":store.root.path,"documents":records.map { ["id":$0.id,"name":$0.name,"version_count":$0.versions.count] },"autosave_debounce_ms":1000,"history":"immutable snapshots; restore appends","ai_keys":"Keychain; never in version files","localhost_server_required":false]
                print(String(data:try JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
                return
            }
            let delegate = try MarginAppDelegate(uiCheck:CommandLine.arguments.contains("--ui-check") || CommandLine.arguments.contains("--quit-check") || CommandLine.arguments.contains("--preview-json") || CommandLine.arguments.contains("--workspace-run") || CommandLine.arguments.contains("--live-check") || CommandLine.arguments.contains("--format-run") || CommandLine.arguments.contains("--terminal-run"))
            let app = NSApplication.shared
            app.delegate = delegate
            app.setActivationPolicy(delegate.uiCheck && !CommandLine.arguments.contains("--live-check") ? .accessory : .regular)
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            fputs("Margin: \(error.localizedDescription)\n",stderr)
            exit(1)
        }
    }
}

/// A stock table in its own window, used by the live check to tell what posted clicks can and cannot prove.
final class PlainTableProbe: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let window = NSWindow(contentRect:NSRect(x:80,y:80,width:260,height:160),styleMask:[.titled],backing:.buffered,defer:false)
    func show() {
        table.addTableColumn(NSTableColumn(identifier:NSUserInterfaceItemIdentifier("c"))); table.headerView = nil; table.dataSource = self; table.delegate = self
        let scroll = NSScrollView(frame:window.contentView?.bounds ?? .zero); scroll.documentView = table; scroll.autoresizingMask = [.width,.height]
        window.contentView?.addSubview(scroll); window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { 4 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSTextField(labelWithString:"row \(row)") }
    func click(row: Int) {
        let rect = table.rect(ofRow:row), location = table.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            if let event = NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event,atStart:false) }
        }
    }
    func close() { window.close() }
}

final class MarginAppDelegate: NSObject, NSApplicationDelegate {
    let store: VersionStore
    let uiCheck: Bool
    var documents: [MarginDocument] = []
    var studios: [StudioWindowController] = []
    private var checkStudio: StudioWindowController?
    private var checkRoot: URL?
    private var quitCheckDocument: MarginDocument?
    private var regression: [String:Bool] = [:]
    private var regressionUntitled: MarginDocument?
    private var checkStage = "launch"

    init(uiCheck: Bool) throws {
        self.uiCheck = uiCheck
        if uiCheck {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-ui-" + UUID().uuidString)
            checkRoot = root
            store = try VersionStore(root:root)
        } else { store = try VersionStore.applicationStore() }
        super.init()
        CredentialStore.keychainEnabled = !uiCheck
        MarginDocument.defaultStore = store
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu(); installChords()
        NSDocumentController.shared.autosavingDelay = 1
        if documents.isEmpty && studios.isEmpty {
            do {
                if !uiCheck, let record = try store.records().first(where: { !$0.versions.isEmpty }), let latest = try store.latest(record.id) {
                    let doc = MarginDocument(store:store,record:record)
                    doc.source = latest.text; doc.format = latest.format
                    if let path = record.path, let data = try? Data(contentsOf:URL(fileURLWithPath:path)), MarginHash.data(data) == latest.hash {
                        doc.fileURL = URL(fileURLWithPath:path); doc.expectedDiskHash = latest.hash
                    }
                    add(doc)
                    doc.controller?.setStatus(doc.fileURL == nil && record.path != nil ? "원본 파일이 다른 곳에서 변경되어 임시 복구본을 열었어요. 파일 다시 읽기나 다른 이름으로 저장을 선택해 주세요." : doc.fileURL == nil ? "마지막 자동저장 내용을 불러왔어요." : "자동저장본 불러옴")
                } else { newDocument(nil) }
                if CommandLine.arguments.contains("--live-check") { runLiveCheck() }
                else if CommandLine.arguments.contains("--workspace-run") { runWorkspaceRun() }
                else if CommandLine.arguments.contains("--format-run") { runFormatRun() }
                else if CommandLine.arguments.contains("--terminal-run") { runTerminalRun() }
                else if CommandLine.arguments.contains("--preview-json") { runPreviewCheck() }
                else if CommandLine.arguments.contains("--quit-check") { runQuitCheck() }
                else if uiCheck { runUICheck() }
                else {
                    if let index = CommandLine.arguments.firstIndex(of:"--workspace"), CommandLine.arguments.indices.contains(index + 1) { openWorkspace(URL(fileURLWithPath:CommandLine.arguments[index + 1])) }
                    NSApp.activate(ignoringOtherApps:true)
                }
            } catch { showError(error) }
        }
    }

    func add(_ document: MarginDocument) {
        documents.append(document)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        if !uiCheck { document.showWindows() }
    }

    @objc func newDocument(_ sender: Any?) {
        do {
            let record = try store.record(path:nil,name:"제목 없음.md")
            let document = MarginDocument(store:store,record:record)
            document.source = "# 새 문서\n\n"
            try document.persistNow(reason:"새 문서")
            add(document)
        } catch { showError(error) }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension:"md") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { for url in panel.urls { open(url) } }
    }

    @objc func openWorkspacePanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "폴더 열기"
        if panel.runModal() == .OK, let url = panel.url { openWorkspace(url) }
    }

    func openWorkspace(_ url: URL) {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = studios.first(where: { $0.root == root }) { existing.showWindow(nil); return }
        let studio = StudioWindowController(root:root,sessions:try? SessionStore(directory:store.root.appendingPathComponent("agent-sessions",isDirectory:true)),background:!uiCheck || CommandLine.arguments.contains("--live-check") || CommandLine.arguments.contains("--workspace-run") || CommandLine.arguments.contains("--format-run") || CommandLine.arguments.contains("--terminal-run"))
        studios.append(studio)
        if !uiCheck { studio.showWindow(nil) }
    }

    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath:url.path,isDirectory:&isDirectory), isDirectory.boolValue { openWorkspace(url); return }
        do {
            if let existing = documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL || ($0.fileURL == nil && $0.record.path == url.standardizedFileURL.path) }) { existing.showWindows(); return }
            let data = try Data(contentsOf:url,options:.mappedIfSafe)
            guard data.count <= 2 * 1024 * 1024 else { throw MarginError.message("2MB 이하의 Markdown 파일만 열 수 있어요.") }
            let decoded = try DocumentFormat.decode(data)
            let record = try store.record(path:url.standardizedFileURL.path,name:url.lastPathComponent)
            let document = MarginDocument(store:store,record:record)
            document.source = decoded.text; document.format = decoded.format
            document.fileURL = url; document.expectedDiskHash = MarginHash.data(data)
            try document.persistNow(reason:"파일 열기")
            if !uiCheck { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
            add(document)
        } catch { showError(error) }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // AppKit also hands over command-line words that are not files (an instruction text, a flag value). Those must not raise an alert.
        if !uiCheck { for name in Self.openable(filenames) { open(URL(fileURLWithPath:name)) } }
        sender.reply(toOpenOrPrint:.success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newDocument(nil) }; return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for studio in studios { studio.shutdown() }
        do { for document in documents { document.controller?.cancelReview(); try document.flush() } }
        catch { showError(error); return .terminateCancel }
        let changed = documents.filter { $0.fileURL != nil && $0.isDocumentEdited }
        guard !changed.isEmpty else { return .terminateNow }
        func finish(_ index: Int) {
            guard index < changed.count else { sender.reply(toApplicationShouldTerminate:true); return }
            changed[index].autosave(withImplicitCancellability:false) { error in
                if let error { self.showError(error); sender.reply(toApplicationShouldTerminate:false) }
                else { finish(index + 1) }
            }
        }
        DispatchQueue.main.async { finish(0) }
        return .terminateLater
    }

    static func openable(_ names: [String]) -> [String] { names.filter { FileManager.default.fileExists(atPath:$0) } }
    func showError(_ error: Error) { if uiCheck { fputs("Margin: \(error.localizedDescription)\n",stderr) } else { NSAlert(error:error).runModal() } }

    // Diagnostic: render a Markdown file headlessly and print what the preview produced.
    func runPreviewCheck() {
        guard let index = CommandLine.arguments.firstIndex(of:"--preview-json"), CommandLine.arguments.indices.contains(index + 1), let document = documents.last, let controller = document.controller,
              let data = try? Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[index + 1])), let decoded = try? DocumentFormat.decode(data) else { fputs("Preview check: cannot read the file\n",stderr); exit(1) }
        DispatchQueue.global().asyncAfter(deadline:.now() + 30) { fputs("Preview check timed out\n",stderr); exit(1) }
        controller.auto.state = .off
        document.record.name = URL(fileURLWithPath:CommandLine.arguments[index + 1]).lastPathComponent
        document.source = decoded.text; controller.refreshSources(); controller.setMode(2)
        DispatchQueue.main.asyncAfter(deadline:.now() + 3) {
            controller.panes[1].preview.evaluateJavaScript("(()=>{const root=document.querySelector('#document');return {plain:!!root.querySelector('pre.plain'),blocks:root.querySelectorAll('section.block').length,locked:root.querySelectorAll('section.locked').length,characters:root.textContent.length,lineBreaks:root.querySelectorAll('br').length,tags:root.querySelectorAll('.tag').length,editable:root.contentEditable,lockedText:[...root.querySelectorAll('section.locked')].map(node=>node.textContent.slice(0,60))}})()") { result,error in
                var receipt = result as? [String:Any] ?? [:]
                if let error { receipt["error"] = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription }
                receipt["status"] = controller.status.stringValue; receipt["source_characters"] = decoded.text.count
                receipt["pass"] = error == nil && ((receipt["blocks"] as? Int ?? 0) > 0 || receipt["plain"] as? Bool == true)
                print(String(data:try! JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
                if let root = self.checkRoot { try? FileManager.default.removeItem(at:root) }
                exit(receipt["pass"] as? Bool == true ? 0 : 1)
            }
        }
    }

    // Diagnostic: run one real instruction through the workspace window and print the recorded steps.
    // Usage: --terminal-run <folder> <text to type, \r for Enter> [--wait <seconds>] [--snapshot <png>]. Opens the terminal tab on the real login shell.
    private func runTerminalRun() {
        guard let index = CommandLine.arguments.firstIndex(of:"--terminal-run"), CommandLine.arguments.indices.contains(index + 2) else { fputs("Usage: --terminal-run <folder> <text>\n",stderr); exit(1) }
        func argument(_ name: String) -> String? { CommandLine.arguments.firstIndex(of:name).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } }
        openWorkspace(URL(fileURLWithPath:CommandLine.arguments[index + 1]))
        guard let studio = studios.last else { exit(1) }
        studio.showTerminal(nil)
        let typed = CommandLine.arguments[index + 2].replacingOccurrences(of:"\\r",with:"\r").replacingOccurrences(of:"\\e",with:"\u{1B}")
        let wait = argument("--wait").flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline:.now() + 3) {
            studio.terminal.send(typed)
            DispatchQueue.main.asyncAfter(deadline:.now() + wait) {
                let screen = studio.terminal.screen
                if let path = argument("--snapshot"), let content = studio.window?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                    content.cacheDisplay(in:content.bounds,to:bitmap)
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path))
                }
                let result: [String:Any] = ["screen":screen.screenText,"alt":screen.alt,"cols":screen.cols,"rows":screen.rows,"running":studio.terminal.isRunning,"title":screen.title,"history_lines":screen.scrollback.count]
                print(String(data:(try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])) ?? Data(),encoding:.utf8) ?? "")
                studio.shutdown()
                DispatchQueue.main.asyncAfter(deadline:.now() + 0.5) { exit(0) }
            }
        }
    }

    // Usage: --format-run <folder> <file inside it>. Runs the real installed formatter the way the menu command does and prints what happened.
    private func runFormatRun() {
        guard let index = CommandLine.arguments.firstIndex(of:"--format-run"), CommandLine.arguments.indices.contains(index + 2) else { fputs("Usage: --format-run <folder> <file>\n",stderr); exit(1) }
        openWorkspace(URL(fileURLWithPath:CommandLine.arguments[index + 1]))
        let path = CommandLine.arguments[index + 2]
        guard let studio = studios.last, studio.openFile(path) else { fputs("Format run: \(studios.last?.status.stringValue ?? "no window")\n",stderr); exit(1) }
        let before = (try? String(contentsOf:studio.scanner.url(path),encoding:.utf8)) ?? ""
        studio.formatDocument(nil)
        let started = Date()
        func poll() {
            if studio.formatting, Date().timeIntervalSince(started) < 40 { DispatchQueue.main.asyncAfter(deadline:.now() + 0.2) { poll() }; return }
            let after = (try? String(contentsOf:studio.scanner.url(path),encoding:.utf8)) ?? ""
            let result: [String:Any] = ["status":studio.status.stringValue,"changed_on_disk":before != after,"disk":after,"path_env":ProcessInfo.processInfo.environment["PATH"] ?? "","seconds":Date().timeIntervalSince(started)]
            print(String(data:(try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])) ?? Data(),encoding:.utf8) ?? "")
            exit(0)
        }
        poll()
    }

    // Usage: --workspace-run <folder> <instruction> [--snapshot <png>]. This makes a real Claude call.
    func runWorkspaceRun() {
        guard let index = CommandLine.arguments.firstIndex(of:"--workspace-run"), CommandLine.arguments.indices.contains(index + 2) else { fputs("Usage: --workspace-run <folder> <instruction>\n",stderr); exit(1) }
        openWorkspace(URL(fileURLWithPath:CommandLine.arguments[index + 1]))
        guard let studio = studios.last, studio.runAgent(CommandLine.arguments[index + 2]) else { fputs("Workspace run: \(studios.last?.status.stringValue ?? "no window")\n",stderr); exit(1) }
        let started = Date()
        func argument(_ name: String) -> String? { CommandLine.arguments.firstIndex(of:name).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } }
        var followUp = argument("--then"), firstSession: String?, resumed: Bool?, stopCheck = argument("--stop-check"), stopped: Bool?
        func poll() {
            if studio.agentRunning, Date().timeIntervalSince(started) < 540 { DispatchQueue.main.asyncAfter(deadline:.now() + 0.5) { poll() }; return }
            if !studio.agentRunning, let next = followUp {
                followUp = nil; firstSession = studio.recorder.sessionID
                if studio.runAgent(next) { resumed = false; poll(); return }
            }
            if resumed == false { resumed = firstSession != nil && studio.recorder.sessionID == firstSession && studio.session.prompts.count == 2 }
            if !studio.agentRunning, let last = stopCheck {
                stopCheck = nil
                if studio.runAgent(last) {
                    DispatchQueue.main.asyncAfter(deadline:.now() + 12) {
                        studio.stop()
                        DispatchQueue.main.asyncAfter(deadline:.now() + 6) { stopped = !studio.agentRunning; poll() }
                    }
                    return
                }
            }
            let finished = !studio.agentRunning
            if !finished { studio.shutdown() }
            let steps = studio.recorder.steps.map { step -> [String:Any] in
                ["reasoning":step.reasoning,"actions":step.actions.map { "\($0.tool): \($0.detail.prefix(120))" },"files":step.changes.map(\.path),"hunks":step.changes.map { LineDiff.hunks(before:$0.before ?? "",after:$0.after ?? "").count }]
            }
            let receipt: [String:Any] = ["finished":finished,"seconds":Int(Date().timeIntervalSince(started)),"steps":steps,"status":studio.status.stringValue,"session":studio.recorder.sessionID != nil,"resumed_same_session":resumed as Any? ?? NSNull(),"stopped_within_6s":stopped as Any? ?? NSNull(),"prompts":studio.session.prompts.count,"log_tail":String(studio.logText.suffix(1200))]
            if let at = CommandLine.arguments.firstIndex(of:"--snapshot"), CommandLine.arguments.indices.contains(at + 1), let content = studio.window?.contentView {
                studio.tabs.selectedSegment = 1; studio.changedTab(); studio.selectStep(0)
                content.layoutSubtreeIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                    content.cacheDisplay(in:content.bounds,to:bitmap)
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:CommandLine.arguments[at + 1]))
                }
            }
            print(String(data:try! JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
            if let root = self.checkRoot { try? FileManager.default.removeItem(at:root) }
            exit(finished && !steps.isEmpty ? 0 : 1)
        }
        poll()
    }

    // Diagnostic: drive a real, visible workspace window through this app's own event queue.
    // Mouse and key events are posted with NSApp.postEvent, so they pass the same dispatch a person's input does. No Claude call.
    func runLiveCheck() {
        guard let root = checkRoot else { exit(1) }
        DispatchQueue.global().asyncAfter(deadline:.now() + 120) { fputs("Live check timed out at \(self.checkStage)\n",stderr); exit(1) }
        let space = root.appendingPathComponent("live")
        do { try MarginChecks.makeFixtureWorkspace(space) } catch { fputs("Live check: \(error.localizedDescription)\n",stderr); exit(1) }
        openWorkspace(space)
        guard let studio = studios.last, let window = studio.window else { exit(1) }
        studio.showWindow(nil); NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil)
        var result: [String:Any] = [:]
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        func click(_ view: NSView, _ point: NSPoint? = nil) {
            let location = view.convert(point ?? NSPoint(x:view.bounds.midX,y:view.bounds.midY),to:nil)
            if CommandLine.arguments.contains("--trace") { fputs("click \(self.checkStage): \(type(of:view)) at \(location) hit=\(window.contentView?.hitTest(location).map { String(describing:type(of:$0)) } ?? "nil") rows=\(studio.outline.numberOfRows) first=\(window.firstResponder.map { String(describing:type(of:$0)) } ?? "nil")\n",stderr) }
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                if let event = NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:now(),windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event,atStart:false) }
            }
        }
        func key(_ code: UInt16, _ characters: String) {
            for type in [NSEvent.EventType.keyDown,.keyUp] {
                if let event = NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:now(),windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code) { NSApp.postEvent(event,atStart:false) }
            }
        }
        func inInput() -> Bool { (window.firstResponder as? NSTextView)?.delegate === studio.input }
        func row(_ name: String) -> NSRect { studio.outline.rect(ofRow:(0..<studio.outline.numberOfRows).first { (studio.outline.item(atRow:$0) as? StudioNode)?.name == name } ?? 0) }
        func replay() {
            try? Data(MarginChecks.fixtureCalc.utf8).write(to:space.appendingPathComponent("calc.py"))
            try? Data(MarginChecks.fixtureReadme.utf8).write(to:space.appendingPathComponent("README.md"))
            studio.newSession()
            // As in a real run, the next line arrives only after the scan for the previous one has finished.
            let lines = (try? MarginChecks.fixtureLines()) ?? []
            var tools: [String:AgentAction] = [:]
            func next(_ index: Int) {
                guard index < lines.count else { return }
                try? MarginChecks.fixtureEffects(root:space,line:lines[index],tools:&tools)
                studio.ingest(lines[index])
                studio.recorder.whenIdle { next(index + 1) }
            }
            studio.recorder.whenIdle { next(0) }
        }
        func decisions() -> [String] { studio.recorder.steps.map(\.decision) }
        func disk(_ name: String) -> String { (try? String(contentsOf:space.appendingPathComponent(name),encoding:.utf8)) ?? "" }
        var steps: [(String, Double, () -> Void)] = []
        func step(_ name: String, wait: Double = 0.5, _ action: @escaping () -> Void) { steps.append((name,wait,action)) }
        // Row selection in tables and focus in text views poll the physical mouse, so posted clicks cannot prove them. A stock table is clicked the same way as a control.
        var limits: [String:Any] = [:]
        let plain = PlainTableProbe()
        step("window") { limits["window_was_key_at_start"] = window.isKeyWindow; limits["app_was_active_at_start"] = NSApp.isActive; plain.show() }
        step("stock table") { plain.click(row:2) }
        step("claude panel") { limits["stock_table_row_click_selects"] = plain.table.selectedRow == 2; plain.close(); window.makeKeyAndOrderFront(nil); studio.setClaude(hidden:false) }
        step("input focus") { click(studio.input) }
        step("typing") { result["click_focuses_input"] = inInput(); key(18,"1"); key(19,"2"); key(20,"3") }
        step("typed",wait:2.5) { result["typing_goes_to_claude_input"] = studio.input.stringValue == "123"; studio.input.stringValue = ""; click(studio.outline,NSPoint(x:60,y:row("README.md").midY)) }
        step("file opened") { limits["tree_row_click_opens_file"] = studio.openPath == "README.md"; studio.openFile("README.md"); click(studio.tabs,NSPoint(x:studio.tabs.bounds.width * 0.75,y:studio.tabs.bounds.midY)) }
        step("review tab") { result["click_switches_to_review_tab"] = !studio.reviewArea.isHidden && window.firstResponder === studio.stepsTable; click(studio.input) }
        step("type while steps arrive") { key(18,"1"); key(19,"2") }
        step("steps arrive") { replay() }
        step("focus kept") {
            result["focus_and_tab_stay_when_steps_arrive"] = inInput() && studio.input.stringValue == "12" && studio.recorder.steps.count == 2 && !studio.reviewArea.isHidden
            result["newest_step_and_its_file_followed"] = studio.selectedStep == 1 && studio.openPath == "README.md" && (studio.outline.item(atRow:studio.outline.selectedRow) as? StudioNode)?.path == "README.md"
            key(51,"\u{7F}"); key(51,"\u{7F}")
        }
        step("tab with empty input") { result["backspace_in_input_edits_text_only"] = studio.input.stringValue.isEmpty && decisions() == ["pending","pending"]; studio.selectStep(0); key(48,"\t") }
        step("tab from input") { result["tab_from_empty_input_accepts"] = decisions() == ["accepted","pending"] && inInput(); click(studio.stepsTable,NSPoint(x:40,y:studio.stepsTable.rect(ofRow:0).midY)) }
        step("row click") { limits["step_row_click_selects"] = studio.selectedStep == 0; window.makeFirstResponder(studio.stepsTable); studio.selectStep(1); key(126,"\u{F700}") }
        step("arrow up") { result["arrow_up_moves_step_and_file_follows"] = studio.selectedStep == 0 && studio.openPath == "calc.py" && !studio.reviewArea.isHidden && window.firstResponder === studio.stepsTable; key(125,"\u{F701}") }
        step("arrow down") { result["arrow_down_moves_step_and_file_follows"] = studio.selectedStep == 1 && studio.openPath == "README.md"; key(51,"\u{7F}") }
        step("delete in list") { result["delete_in_step_list_rejects_and_restores"] = decisions().last == "rejected" && disk("README.md") == MarginChecks.fixtureReadme; replay() }
        step("reason click") { studio.selectStep(0); click(studio.reasonText) }
        step("tab in reason") { limits["text_pane_click_takes_focus"] = window.firstResponder === studio.reasonText; window.makeFirstResponder(studio.reasonText); key(48,"\t") }
        step("diff focus") { result["tab_in_reason_pane_accepts"] = decisions() == ["accepted","pending"]; window.makeFirstResponder(studio.diffText) }
        step("delete in diff") { key(51,"\u{7F}") }
        step("replay for buttons") { result["delete_in_diff_pane_rejects"] = decisions() == ["accepted","rejected"]; replay() }
        step("accept button") { studio.selectStep(0); click(studio.acceptButton) }
        step("reject button") { result["accept_button_click"] = decisions() == ["accepted","pending"]; click(studio.rejectButton) }
        step("follow off") { result["reject_button_click"] = decisions() == ["accepted","rejected"] && disk("README.md") == MarginChecks.fixtureReadme; click(studio.followBox) }
        step("follow off check") { studio.selectStep(0) }
        step("files tab") { result["follow_checkbox_off_keeps_file"] = studio.followBox.state == .off && studio.openPath == "README.md"; click(studio.followBox); click(studio.tabs,NSPoint(x:studio.tabs.bounds.width * 0.2,y:studio.tabs.bounds.midY)) }
        step("open code") { result["click_switches_to_file_tab"] = !studio.fileArea.isHidden; studio.openFile("calc.py"); window.makeFirstResponder(studio.codePane.editor); studio.codePane.editor.setSelectedRange(NSRange(location:0,length:0)) }
        step("type in editor",wait:2) { key(18,"1"); key(19,"2") }
        step("autosave") { result["typing_in_code_view_autosaves"] = disk("calc.py").hasPrefix("12def add"); if CommandLine.arguments.contains("--trace") { fputs("editor: \(studio.codePane.editor.string.prefix(20).debugDescription) disk=\(disk("calc.py").prefix(20).debugDescription) title=\(studio.fileTitle.stringValue) status=\(studio.status.stringValue) first=\(String(describing:window.firstResponder)) key=\(window.isKeyWindow)\n",stderr) }; result["posted_click_limits"] = limits }
        func run(_ index: Int) {
            guard index < steps.count else {
                result["pass"] = !result.contains { ($0.value as? Bool) == false }
                result["event_path"] = "NSApp.postEvent into this app's own queue; no physical pointer or keyboard"
                if let at = CommandLine.arguments.firstIndex(of:"--snapshot"), CommandLine.arguments.indices.contains(at + 1), let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                    content.cacheDisplay(in:content.bounds,to:bitmap)
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:CommandLine.arguments[at + 1]))
                }
                print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
                studio.shutdown()
                try? FileManager.default.removeItem(at:root)
                exit(result["pass"] as? Bool == true ? 0 : 1)
            }
            if CommandLine.arguments.contains("--trace") { fputs("after \(self.checkStage): outlineRow=\(studio.outline.selectedRow) stepRow=\(studio.stepsTable.selectedRow) open=\(studio.openPath ?? "-") first=\(window.firstResponder.map { String(describing:type(of:$0)) } ?? "nil") decisions=\(decisions())\n",stderr) }
            checkStage = steps[index].0
            steps[index].2()
            DispatchQueue.main.asyncAfter(deadline:.now() + steps[index].1) { run(index + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline:.now() + 1) { run(0) }
    }

    func runQuitCheck() {
        guard let doc = documents.last, let controller = doc.controller, let root = checkRoot else { exit(1) }
        quitCheckDocument = doc
        do {
            controller.auto.state = .off
            doc.source = "# 종료 전\n"; controller.refreshSources()
            let url = root.appendingPathComponent("quit.md")
            let bytes = doc.format.encode(doc.source); try bytes.write(to:url)
            doc.fileURL = url; doc.expectedDiskHash = MarginHash.data(bytes)
            controller.activeEditor.setSelectedRange(NSRange(location:(doc.source as NSString).length,length:0))
            controller.activeEditor.insertText("종료 직전 편집",replacementRange:controller.activeEditor.selectedRange())
            DispatchQueue.main.async { NSApp.terminate(nil) }
            DispatchQueue.main.asyncAfter(deadline:.now() + 10) { fputs("Quit check timed out\n",stderr); exit(1) }
        } catch { fputs("Quit check: \(error.localizedDescription)\n",stderr); exit(1) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard CommandLine.arguments.contains("--quit-check") else { return }
        guard let doc = quitCheckDocument else { fputs("Quit check has no document\n",stderr); exit(1) }
        let disk = doc.fileURL.flatMap { try? Data(contentsOf:$0) }
        let recovered = try? store.latest(doc.record.id)
        let pass = disk == doc.format.encode(doc.source) && recovered?.text == doc.source && doc.source.contains("종료 직전 편집")
        let receipt: [String:Any] = ["pass":pass,"quit_before_debounce":true,"original_saved":disk == doc.format.encode(doc.source),"recovery_saved":recovered?.text == doc.source]
        print(String(data:try! JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
        if let root = checkRoot { try? FileManager.default.removeItem(at:root) }
        if !pass { exit(1) }
    }

    func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"Margin 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let file = NSMenu(title:"파일"); fileItem.submenu = file
        let new = file.addItem(withTitle:"새 문서",action:#selector(newDocument(_:)),keyEquivalent:"n"); new.target = self
        let open = file.addItem(withTitle:"열기…",action:#selector(openDocument(_:)),keyEquivalent:"o"); open.target = self
        let folder = file.addItem(withTitle:"폴더 열기…",action:#selector(openWorkspacePanel(_:)),keyEquivalent:"O"); folder.target = self; folder.keyEquivalentModifierMask = [.command,.shift]
        file.addItem(.separator())
        file.addItem(withTitle:"저장",action:#selector(NSDocument.save(_:)),keyEquivalent:"s")
        let saveAs = file.addItem(withTitle:"다른 이름으로 저장…",action:#selector(NSDocument.saveAs(_:)),keyEquivalent:"S"); saveAs.keyEquivalentModifierMask = [.command,.shift]
        file.addItem(withTitle:"닫기",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title:"편집"); editItem.submenu = edit
        edit.addItem(withTitle:"실행 취소",action:Selector(("undo:")),keyEquivalent:"z")
        let redo = edit.addItem(withTitle:"다시 실행",action:Selector(("redo:")),keyEquivalent:"Z"); redo.keyEquivalentModifierMask = [.command,.shift]
        edit.addItem(.separator())
        edit.addItem(withTitle:"오려두기",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"복사하기",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"붙여넣기",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"전체 선택",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        edit.addItem(.separator())
        let format = edit.addItem(withTitle:"코드 정리",action:#selector(StudioWindowController.formatDocument(_:)),keyEquivalent:"l"); format.keyEquivalentModifierMask = [.command,.option]
        let findItem = NSMenuItem(); menu.addItem(findItem)
        let find = NSMenu(title:"찾기"); findItem.submenu = find
        find.addItem(withTitle:"찾기…",action:#selector(NSTextView.marginShowFind(_:)),keyEquivalent:"f")
        func finder(_ title: String, _ action: NSTextFinder.Action, _ key: String, _ mask: NSEvent.ModifierFlags) {
            let item = find.addItem(withTitle:title,action:#selector(NSTextView.performFindPanelAction(_:)),keyEquivalent:key)
            item.tag = action.rawValue; item.keyEquivalentModifierMask = mask
        }
        finder("찾아 바꾸기…",.showReplaceInterface,"f",[.command,.option])
        finder("다음 찾기",.nextMatch,"g",[.command])
        finder("이전 찾기",.previousMatch,"G",[.command,.shift])
        finder("일치 항목 모두 선택",.selectAll,"g",[.command,.control])
        finder("선택 영역으로 찾기",.setSearchString,"e",[.command])
        find.addItem(withTitle:"선택 영역으로 스크롤",action:#selector(NSText.centerSelectionInVisibleArea(_:)),keyEquivalent:"j")
        find.addItem(.separator())
        let inFiles = find.addItem(withTitle:"파일에서 찾기…",action:#selector(StudioWindowController.findInWorkspace(_:)),keyEquivalent:"F"); inFiles.keyEquivalentModifierMask = [.command,.shift]
        let viewItem = NSMenuItem(); menu.addItem(viewItem)
        let view = NSMenu(title:"보기"); viewItem.submenu = view
        view.addItem(withTitle:"사이드바 표시/숨기기  (⌘K ⌘B)",action:#selector(StudioWindowController.toggleSidebar(_:)),keyEquivalent:"")
        let claude = view.addItem(withTitle:"Claude 패널 표시/숨기기",action:#selector(StudioWindowController.toggleClaude(_:)),keyEquivalent:"b"); claude.keyEquivalentModifierMask = [.command,.option]
        let terminal = view.addItem(withTitle:"터미널 표시/숨기기",action:#selector(StudioWindowController.showTerminal(_:)),keyEquivalent:"`"); terminal.keyEquivalentModifierMask = [.control]
        NSApp.mainMenu = menu
    }

    private var chordStarted: TimeInterval?
    /// Sublime's two-stroke shortcuts: ⌘K then ⌘B toggles the workspace sidebar. Key codes keep it working under Hangul input.
    func installChords() {
        NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in self?.chord(event) ?? event }
    }
    func chord(_ event: NSEvent, in target: StudioWindowController? = nil) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command,.shift,.option,.control])
        let started = chordStarted; chordStarted = nil
        guard mods == [.command], let studio = target ?? studios.first(where:{ $0.window === NSApp.mainWindow }) else { return event }
        if let started, event.timestamp - started < 2, event.keyCode == 11 { studio.toggleSidebar(nil); return nil }
        if event.keyCode == 40 { chordStarted = event.timestamp; return nil }
        return event
    }

    func runRegressionChecks(root: URL) {
        let type = "net.daringfireball.markdown"
        do {
            let untitled = MarginDocument(store:store,record:try store.record(path:nil,name:"제목 없음.md"))
            untitled.source = "# 이름 없는 문서\n"
            try untitled.persistNow(reason:"새 문서")
            try untitled.writeSafely(to:root.appendingPathComponent("elsewhere.md"),ofType:type,for:.autosaveElsewhereOperation)
            try untitled.writeSafely(to:root.appendingPathComponent("copy.md"),ofType:type,for:.saveToOperation)
            let storedUntitled = try store.currentRecord(untitled.record.id)
            regression["untitled_autosave_keeps_identity"] = untitled.record.path == nil && untitled.expectedDiskHash == nil && storedUntitled.path == nil
            regressionUntitled = untitled
            regression["untitled_system_autosave_keeps_identity"] = false
            untitled.updateChangeCount(.changeDone)
            untitled.autosave(withImplicitCancellability:false) { [weak self] error in
                guard let self else { return }
                let stored = try? self.store.currentRecord(untitled.record.id)
                self.regression["untitled_system_autosave_keeps_identity"] = error == nil && untitled.fileURL == nil && untitled.record.path == nil && stored != nil && stored?.path == nil
                for url in [untitled.autosavedContentsFileURL,untitled.fileURL].compactMap({ $0 }) where url.path.contains("Autosave Information") { try? FileManager.default.removeItem(at:url) }
            }
            let file = root.appendingPathComponent("reopen.md")
            try Data("# 다시 열기\n".utf8).write(to:file)
            let same: (MarginDocument) -> Bool = { $0.fileURL?.standardizedFileURL == file.standardizedFileURL }
            open(file)
            guard let first = documents.first(where:same) else { throw MarginError.message("regression fixture did not open") }
            first.close()
            let released = !documents.contains { $0 === first }
            open(file)
            guard let second = documents.first(where:same) else { regression["close_then_reopen"] = false; return }
            regression["close_then_reopen"] = released && second !== first && second.controller != nil && second.record.id == first.record.id
            let diskHash = second.expectedDiskHash
            try second.writeSafely(to:root.appendingPathComponent("copy2.md"),ofType:type,for:.saveToOperation)
            regression["save_copy_keeps_identity"] = second.record.path == file.standardizedFileURL.path && second.expectedDiskHash == diskHash && diskHash != nil
            try Data("external".utf8).write(to:file)
            let unsaved = "저장하지 않은 현재 내용\n"
            second.source = unsaved
            var blocked = false
            do { try second.writeSafely(to:file,ofType:type,for:.saveOperation) } catch { blocked = true }
            let preserved = try store.latest(second.record.id)?.text, disk = try Data(contentsOf:file)
            regression["manual_save_conflict_preserves_current"] = blocked && preserved == unsaved && disk == Data("external".utf8)
            let pending = "충돌 이후 다시 고친 내용\n"
            second.source = pending
            try second.reopenOriginal()
            let kept = try store.versions(second.record.id)
            regression["reopen_original_preserves_current"] = second.source == "external" && kept.contains { $0.text == unsaved } && kept.contains { $0.text == pending }
            let recovered = MarginDocument(store:store,record:second.record)
            second.close()
            documents.append(recovered)
            open(file)
            regression["recovered_copy_blocks_duplicate_open"] = documents.filter { $0.record.id == recovered.record.id }.count == 1
            documents.removeAll { $0 === recovered }
        } catch {
            fputs("Regression check: \(error.localizedDescription)\n",stderr)
            regression["regression_error"] = false
        }
    }

    /// Implements: FR-IDE-1, FR-IDE-2, FR-IDE-3, FR-IDE-4, FR-IDE-5, FR-IDE-6, FR-IDE-10, FR-IDE-11, FR-IDE-12, FR-IDE-13, NFR-IDE-1
    func runStudioChecks(root: URL) {
        let names = ["launch_words_that_are_not_files_raise_no_alert","folder_path_opens_one_workspace","workspace_tree_hides_ignored_and_secret","code_view_opens_and_saves","markdown_opens_in_rendered_pane","agent_steps_replayed_in_order","accept_advances_reject_restores","conflicting_reject_refuses","claude_panel_toggles_with_opt_cmd_b","agent_launch_is_explicit","reload_keeps_tab_and_focus","step_selection_follows_file","tab_in_empty_input_accepts","same_step_redraw_keeps_reading_position","part_reject_undoes_one_block","format_command_is_one_undoable_saved_edit","terminal_panel_toggles_with_ctrl_backtick","new_session_shows_itself","terminal_keys_reach_the_program","terminal_stop_ends_the_shell","find_menu_opens_find_bar","find_in_files_options_and_reveal","sidebar_toggles_with_cmd_k_b","claude_log_reads_as_conversation","empty_area_shows_next_step_and_shortcuts","claude_panel_starts_closed","panel_buttons_show_open_state","folder_double_click_toggles_contents"]
        for name in names { regression[name] = false }
        do {
            let space = root.appendingPathComponent("studio")
            try MarginChecks.makeFixtureWorkspace(space)
            try FileManager.default.createDirectory(at:space.appendingPathComponent("sub"),withIntermediateDirectories:true)
            try Data("let x = 1 // one\n".utf8).write(to:space.appendingPathComponent("sub/tool.swift"))
            let documentsBefore = documents.count
            application(NSApp,openFiles:["README.md에 한 줄 추가해 줘",space.appendingPathComponent("missing.md").path])
            regression["launch_words_that_are_not_files_raise_no_alert"] = Self.openable(["README.md에 한 줄 추가해 줘",space.appendingPathComponent("missing.md").path,space.appendingPathComponent("calc.py").path]) == [space.appendingPathComponent("calc.py").path] && documents.count == documentsBefore && NSApp.modalWindow == nil
            let folder = root.appendingPathComponent("cli")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            open(folder); open(folder)
            regression["folder_path_opens_one_workspace"] = studios.filter { $0.root == folder.standardizedFileURL.resolvingSymlinksInPath() }.count == 1 && documents.count == documentsBefore
            UserDefaults.standard.removeObject(forKey:"studio.claudeHidden")
            openWorkspace(space)
            guard let studio = studios.last else { return }
            checkStudio = studio
            studio.window?.contentView?.layoutSubtreeIfNeeded()
            regression["claude_panel_starts_closed"] = studio.claudeHidden && studio.claudeToggle.state == .off
            let emptyFirst = !studio.emptyState.isHidden && !studio.formatButton.isEnabled && studio.fileTitle.stringValue.isEmpty
            let menuItems = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
            func glyphs(_ item: NSMenuItem) -> String {
                let mask = item.keyEquivalentModifierMask
                return (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "") + (mask.contains(.shift) ? "⇧" : "") + (mask.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
            }
            let shortcutsReal = StudioWindowController.emptyShortcuts.allSatisfy { key, _ in menuItems.contains { !$0.keyEquivalent.isEmpty && glyphs($0) == key } || menuItems.contains { $0.title.contains("(" + key + ")") } }
            let top = studio.nodes.map(\.name)
            regression["workspace_tree_hides_ignored_and_secret"] = top.contains("calc.py") && top.contains("README.md") && top.contains("sub") && !top.contains("node_modules") && !top.contains(".env") && studio.outline.numberOfRows == top.count && !studio.openFile(".env")
            let subRow = (0..<studio.outline.numberOfRows).first { (studio.outline.item(atRow:$0) as? StudioNode)?.path == "sub" } ?? -1
            var folderToggles = false
            if subRow >= 0, let sub = studio.outline.item(atRow:subRow) as? StudioNode, let action = studio.outline.doubleAction {
                studio.outline.selectRowIndexes(IndexSet(integer:subRow),byExtendingSelection:false)
                let wasClosed = !studio.outline.isItemExpanded(sub)
                NSApp.sendAction(action,to:studio.outline.target,from:studio.outline)
                let expanded = studio.outline.isItemExpanded(sub) && studio.outline.numberOfRows > top.count
                NSApp.sendAction(action,to:studio.outline.target,from:studio.outline)
                folderToggles = wasClosed && expanded && !studio.outline.isItemExpanded(sub) && studio.outline.numberOfRows == top.count
            }
            regression["folder_double_click_toggles_contents"] = folderToggles
            let opened = studio.openFile("sub/tool.swift")
            regression["empty_area_shows_next_step_and_shortcuts"] = emptyFirst && shortcutsReal && studio.emptyState.isHidden && studio.formatButton.isEnabled
            if regression["empty_area_shows_next_step_and_shortcuts"] != true { fputs("Empty state: first=\(emptyFirst) shortcuts=\(shortcutsReal) hiddenAfter=\(studio.emptyState.isHidden)\n",stderr) }
            let coloured = (studio.codePane.editor.textStorage?.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor) == NSColor.systemPink
            studio.codePane.editor.setSelectedRange(NSRange(location:(studio.codePane.editor.string as NSString).length,length:0))
            studio.codePane.editor.insertText("let y = 2\n",replacementRange:studio.codePane.editor.selectedRange())
            studio.flushSave()
            let saved = try String(contentsOf:space.appendingPathComponent("sub/tool.swift"),encoding:.utf8)
            try Data("changed elsewhere\n".utf8).write(to:space.appendingPathComponent("sub/tool.swift"))
            studio.codePane.editor.insertText("let z = 3\n",replacementRange:studio.codePane.editor.selectedRange())
            studio.flushSave()
            let guarded = try String(contentsOf:space.appendingPathComponent("sub/tool.swift"),encoding:.utf8) == "changed elsewhere\n"
            regression["code_view_opens_and_saves"] = opened && coloured && !studio.codePane.isHidden && studio.markdownPane.isHidden && studio.codePane.scroll.verticalRulerView is LineRuler && saved == "let x = 1 // one\nlet y = 2\n" && guarded
            if regression["code_view_opens_and_saves"] != true { fputs("Code view: opened=\(opened) coloured=\(coloured) saved=\(saved.debugDescription) guarded=\(guarded)\n",stderr) }
            try Data("let x = 1 // one\n".utf8).write(to:space.appendingPathComponent("sub/tool.swift"))
            let markdown = studio.openFile("README.md")
            regression["markdown_opens_in_rendered_pane"] = markdown && !studio.markdownPane.isHidden && studio.codePane.isHidden && studio.markdownPane.editor.string == MarginChecks.fixtureReadme && studio.markdownPane.selector.selectedSegment == 1 && !studio.markdownPane.formatBar.isHidden
            studio.newSession()
            studio.tabs.selectedSegment = 1; studio.showTab()
            studio.window?.makeFirstResponder(studio.input)
            try MarginChecks.replayFixture(root:space) { studio.ingest($0) }
            let steps = studio.recorder.steps
            regression["reload_keeps_tab_and_focus"] = studio.tabs.selectedSegment == 1 && !studio.reviewArea.isHidden && (studio.window?.firstResponder as? NSTextView)?.delegate === studio.input
            let followedNewest = studio.selectedStep == 1 && studio.openPath == "README.md" && (studio.outline.item(atRow:studio.outline.selectedRow) as? StudioNode)?.path == "README.md"
            studio.selectStep(0)
            regression["step_selection_follows_file"] = followedNewest && studio.openPath == "calc.py" && (studio.outline.item(atRow:studio.outline.selectedRow) as? StudioNode)?.path == "calc.py" && studio.codePane.editor.selectedRange().location == 15 && studio.tabs.selectedSegment == 1
            if regression["step_selection_follows_file"] != true { fputs("Follow: newest=\(followedNewest) open=\(studio.openPath ?? "-") caret=\(studio.codePane.editor.selectedRange())\n",stderr) }
            studio.diffText.setSelectedRange(NSRange(location:3,length:2))
            studio.reloadSteps()
            regression["same_step_redraw_keeps_reading_position"] = studio.diffText.selectedRange() == NSRange(location:3,length:2)
            let diff = studio.diffText.string, reason = studio.reasonText.string
            regression["agent_steps_replayed_in_order"] = steps.count == 2 && steps.first?.changes.map(\.path) == ["calc.py"] && steps.last?.changes.map(\.path) == ["README.md"] && studio.stepsTable.numberOfRows == 2
                && diff.contains("- ") && diff.contains("return a - b") && diff.contains("+     return a + b") && reason.contains("a - b") && reason.contains("⏵ Edit")
                && studio.markdownPane.editor.string.hasSuffix("반환합니다.\n") && studio.logText.contains("● 변경 2 · README.md") && studio.logText.contains("this line is not JSON")
            if regression["agent_steps_replayed_in_order"] != true { fputs("Replay: steps=\(steps.count) rows=\(studio.stepsTable.numberOfRows) diff=\(diff.debugDescription)\n",stderr) }
            let typed = NSTextView(); typed.string = "다음 지시"
            let keptTyping = !studio.control(studio.input,textView:typed,doCommandBy:#selector(NSResponder.insertTab(_:))) && studio.recorder.steps[0].decision == "pending"
            regression["tab_in_empty_input_accepts"] = keptTyping && studio.control(studio.input,textView:NSTextView(),doCommandBy:#selector(NSResponder.insertTab(_:))) && !studio.control(studio.input,textView:NSTextView(),doCommandBy:#selector(NSResponder.deleteBackward(_:)))
            let advanced = studio.recorder.steps[0].decision == "accepted" && studio.selectedStep == 1
            studio.rejectStep()
            let restored = try Data(contentsOf:space.appendingPathComponent("README.md")) == Data(MarginChecks.fixtureReadme.utf8)
            let stored = (try? SessionStore(directory:store.root.appendingPathComponent("agent-sessions",isDirectory:true)))?.sessions(root:studio.root.path).first
            regression["accept_advances_reject_restores"] = advanced && restored && studio.recorder.steps[1].decision == "rejected" && studio.markdownPane.editor.string == MarginChecks.fixtureReadme && stored?.steps.map(\.decision) == ["accepted","rejected"] && stored?.agentSessionID == "fixture-session"
            let clash = MarginChecks.fixtureCalc.replacingOccurrences(of:"a - b",with:"a * b")
            try Data(clash.utf8).write(to:space.appendingPathComponent("calc.py"))
            studio.selectStep(0)
            let before = studio.recorder.steps[0].decision
            studio.tabs.selectedSegment = 1; studio.changedTab()
            studio.window?.makeFirstResponder(studio.stepsTable)
            func press(_ code: UInt16) {
                guard let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:studio.window?.windowNumber ?? 0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code) else { return }
                studio.window?.firstResponder?.keyDown(with:event)
            }
            press(51)
            let tableKeys = studio.window?.firstResponder === studio.stepsTable && studio.status.stringValue.contains("되돌릴 수 없어요") && before == "accepted"
            let untouched = try String(contentsOf:space.appendingPathComponent("calc.py"),encoding:.utf8)
            regression["conflicting_reject_refuses"] = tableKeys && untouched == clash && studio.recorder.steps[0].decision == "accepted" && studio.status.stringValue.contains("되돌릴 수 없어요")
            let base = (1...12).map { "line \($0)" }.joined(separator:"\n") + "\n"
            try Data(base.utf8).write(to:space.appendingPathComponent("parts.txt"))
            studio.newSession()
            studio.recorder.handle(.text("먼저 살펴봅니다.\n\nWHY: 두 군데의 표기를 바꿉니다."))
            studio.recorder.handle(.toolUse(id:"p1",tool:"Edit",detail:"parts.txt"))
            try Data(base.replacingOccurrences(of:"line 2\n",with:"line two\n").replacingOccurrences(of:"line 11\n",with:"line eleven\n").utf8).write(to:space.appendingPathComponent("parts.txt"))
            studio.recorder.handle(.toolResult(id:"p1",failed:false))
            studio.window?.makeFirstResponder(studio.stepsTable)
            func strike(_ code: UInt16, shift: Bool = false) {
                guard let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:shift ? [.shift] : [],timestamp:0,windowNumber:studio.window?.windowNumber ?? 0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code) else { return }
                studio.window?.firstResponder?.keyDown(with:event)
            }
            let offered = studio.recorder.steps.count == 1 && studio.selectedStep == 0 && !studio.partButton.isHidden && studio.reasonText.string.hasPrefix("두 군데의 표기를 바꿉니다.") && studio.counter.stringValue.contains("부분 1/2")
            strike(124)
            let moved = studio.partFocus == 1 && studio.diffText.string.contains("▌  11 + line eleven") && !studio.diffText.string.contains("▌   2 + line two")
            strike(51,shift:true)
            let half = try String(contentsOf:space.appendingPathComponent("parts.txt"),encoding:.utf8)
            let partly = half == base.replacingOccurrences(of:"line 2\n",with:"line two\n") && studio.recorder.steps[0].decision == "pending" && studio.partButton.isHidden && !studio.diffText.string.contains("eleven")
            strike(51)
            regression["part_reject_undoes_one_block"] = offered && moved && partly && (try String(contentsOf:space.appendingPathComponent("parts.txt"),encoding:.utf8)) == base && studio.recorder.steps[0].decision == "rejected"
            let toolFolder = root.appendingPathComponent("format-bin")
            try FileManager.default.createDirectory(at:toolFolder,withIntermediateDirectories:true)
            try Data("#!/bin/sh\nsed 's/ *= */ = /'\n".utf8).write(to:toolFolder.appendingPathComponent("ruff"))
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:toolFolder.appendingPathComponent("ruff").path)
            try Data("a=1\nb = 2\nc=3\n".utf8).write(to:space.appendingPathComponent("messy.py"))
            studio.formatSearch = [toolFolder.path,"/usr/bin","/bin"]
            let messyOpened = studio.openFile("messy.py")
            studio.formatDocument(nil)
            let formattedText = studio.codePane.editor.string, formattedDisk = try String(contentsOf:space.appendingPathComponent("messy.py"),encoding:.utf8)
            studio.codePane.editor.undoManager?.undo()
            regression["format_command_is_one_undoable_saved_edit"] = messyOpened && formattedText == "a = 1\nb = 2\nc = 3\n" && formattedDisk == formattedText && studio.codePane.editor.string == "a=1\nb = 2\nc=3\n" && studio.status.stringValue.contains("ruff")
            if regression["format_command_is_one_undoable_saved_edit"] != true { fputs("Format: opened=\(messyOpened) text=\(formattedText.debugDescription) disk=\(formattedDisk.debugDescription) undo=\(studio.codePane.editor.string.debugDescription) status=\(studio.status.stringValue)\n",stderr) }
            studio.flushSave()
            // A plain shell, so the check does not depend on the person's own shell configuration.
            studio.terminal.start(executable:"/bin/sh",arguments:["sh"])
            studio.setClaude(hidden:false)
            studio.showTerminal(nil)
            let terminalOpened = !studio.terminal.isHidden && studio.terminal.isRunning && studio.window?.firstResponder === studio.terminal && !studio.claudeHidden
            let terminalButtonOn = studio.terminalToggle.state == .on && studio.claudeToggle.state == .on
            studio.showTerminal(nil)
            let terminalClosed = studio.terminal.isHidden && studio.terminal.isRunning && studio.window?.firstResponder !== studio.terminal
            let terminalButtonOff = studio.terminalToggle.state == .off
            studio.setClaude(hidden:true)
            studio.newSession()
            regression["new_session_shows_itself"] = !studio.claudeHidden && studio.terminal.isRunning && studio.logText.contains("새 세션") && studio.recorder.steps.isEmpty && studio.recorder.sessionID == nil
            studio.showTerminal(nil)
            regression["terminal_panel_toggles_with_ctrl_backtick"] = terminalOpened && terminalClosed && !studio.terminal.isHidden && studio.window?.firstResponder === studio.terminal
            func settle(_ seconds: TimeInterval, until done: () -> Bool = { false }) { let end = Date().addingTimeInterval(seconds); while Date() < end, !done() { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) } }
            func press(_ code: UInt16, _ characters: String, _ plain: String, _ flags: NSEvent.ModifierFlags = []) {
                if let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:studio.window?.windowNumber ?? 0,context:nil,characters:characters,charactersIgnoringModifiers:plain,isARepeat:false,keyCode:code) { studio.terminal.keyDown(with:event) }
            }
            let shellPid = studio.terminal.session?.pid ?? 0
            settle(0.6)
            studio.terminal.insertText("sleep 100",replacementRange:NSRange(location:NSNotFound,length:0)); press(36,"\r","\r")
            settle(0.6)
            press(8,"\u{3}","ㅊ",.control)
            settle(0.4)
            studio.terminal.insertText("echo done-$? ",replacementRange:NSRange(location:NSNotFound,length:0))
            studio.terminal.setMarkedText("ㅎ",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            let composing = studio.terminal.hasMarkedText()
            studio.terminal.insertText("한",replacementRange:NSRange(location:NSNotFound,length:0)); press(36,"\r","\r")
            settle(3) { studio.terminal.screen.screenText.contains("\ndone-130 한") }
            regression["terminal_keys_reach_the_program"] = composing && !studio.terminal.hasMarkedText() && studio.terminal.screen.screenText.contains("\ndone-130 한")
            if regression["terminal_keys_reach_the_program"] != true { fputs("Terminal keys: \(studio.terminal.screen.screenText.debugDescription)\n",stderr) }
            studio.setTerminal(hidden:true); studio.terminal.stop()
            settle(3) { kill(shellPid,0) != 0 }
            regression["terminal_stop_ends_the_shell"] = shellPid > 0 && kill(shellPid,0) != 0 && !studio.terminal.isRunning
            if regression["part_reject_undoes_one_block"] != true { fputs("Part: offered=\(offered) moved=\(moved) partly=\(partly) counter=\(studio.counter.stringValue) diff=\(studio.diffText.string.debugDescription)\n",stderr) }
            let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
            let findKey = items.first { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == [.command] }
            try Data("let x = 1 // one\nlet y = 2\n".utf8).write(to:space.appendingPathComponent("sub/tool.swift"))
            studio.openFile("sub/tool.swift"); studio.window?.makeFirstResponder(studio.codePane.editor)
            studio.codePane.editor.setSelectedRange(NSRange(location:0,length:3))
            studio.codePane.editor.marginShowFind(nil)
            regression["find_menu_opens_find_bar"] = findKey?.action == #selector(NSTextView.marginShowFind(_:)) && studio.codePane.scroll.isFindBarVisible
                && items.contains { $0.keyEquivalent == "F" && $0.action == #selector(StudioWindowController.findInWorkspace(_:)) }
            let text = "Let x = 1\nlet total = 2\nlettuce\n"
            func count(_ query: String, _ options: SearchOptions) -> [Int] { ((try? WorkspaceSearch.pattern(query,options)).map { WorkspaceSearch.hits(in:text,path:"t",pattern:$0) } ?? []).map(\.line) }
            let plain = count("let",SearchOptions()), cased = count("let",SearchOptions(caseSensitive:true)), word = count("let",SearchOptions(wholeWord:true)), regex = count("^let\\s+\\w+",SearchOptions(caseSensitive:true,regex:true))
            let badRegex = (try? WorkspaceSearch.pattern("(",SearchOptions(regex:true))) == nil
            let tree = WorkspaceSearch.run(root:studio.root,paths:studio.recorder.paths + [".env"],pattern:try WorkspaceSearch.pattern("let y",SearchOptions()))
            let hit = tree.hits.first
            let anyLet = try WorkspaceSearch.pattern("let",SearchOptions())
            let masked = WorkspaceSearch.run(root:studio.root,paths:studio.recorder.paths,pattern:anyLet,mask:try WorkspaceSearch.mask("^SUB/.*\\.swift$"))
            let maskedOut = WorkspaceSearch.run(root:studio.root,paths:studio.recorder.paths,pattern:anyLet,mask:try WorkspaceSearch.mask("\\.md$"))
            let maskOK = masked.scanned == 1 && Set(masked.hits.map(\.path)) == ["sub/tool.swift"] && maskedOut.hits.allSatisfy { $0.path.hasSuffix(".md") } && (try? WorkspaceSearch.mask("[")) == nil && (try? WorkspaceSearch.mask("  ")) == .some(nil)
            let revealed = hit.map { studio.reveal($0) } ?? false
            let selected = (studio.codePane.editor.string as NSString).substring(with:studio.codePane.editor.selectedRange())
            regression["find_in_files_options_and_reveal"] = plain == [1,2,3] && cased == [2,3] && word == [1,2] && regex == [2] && badRegex
                && maskOK && tree.hits.count == 1 && hit?.path == "sub/tool.swift" && hit?.line == 2 && revealed && studio.openPath == "sub/tool.swift" && selected == "let y"
            if regression["find_in_files_options_and_reveal"] != true { fputs("Search: plain=\(plain) cased=\(cased) word=\(word) regex=\(regex) mask=\(maskOK) tree=\(tree.hits) selected=\(selected.debugDescription)\n",stderr) }
            func cmd(_ code: UInt16, _ c: String) -> NSEvent { NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,characters:c,charactersIgnoringModifiers:c,isARepeat:false,keyCode:code)! }
            studio.setSidebar(hidden:false)
            let swallowedK = chord(cmd(40,"k"),in:studio) == nil, swallowedB = chord(cmd(11,"b"),in:studio) == nil
            let hidden = studio.sidebarHidden
            let pasteAfterK = chord(cmd(40,"k"),in:studio) == nil && chord(cmd(9,"v"),in:studio) != nil && studio.sidebarHidden
            _ = chord(cmd(40,"k"),in:studio); _ = chord(cmd(11,"b"),in:studio)
            let shown = !studio.sidebarHidden
            let plainB = chord(cmd(11,"b"),in:studio) != nil && !studio.sidebarHidden
            regression["sidebar_toggles_with_cmd_k_b"] = swallowedK && swallowedB && hidden && pasteAfterK && shown && plainB
            UserDefaults.standard.removeObject(forKey:"studio.sidebarHidden")
            try Data("let x = 1 // one\n".utf8).write(to:space.appendingPathComponent("sub/tool.swift"))
            let launch = AgentLauncher.arguments(prompt:"고쳐 줘",resume:"sid",allowShell:false)
            regression["agent_launch_is_explicit"] = launch.contains("stream-json") && launch.contains("acceptEdits") && launch.contains("sid") && !launch.contains { $0.contains("Bash") || $0.contains("dangerously") } && AgentLauncher.arguments(prompt:"x",resume:nil,allowShell:true).contains { $0.contains("Bash") }
            let menuKeys = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
            let claudeKey = menuKeys.contains { $0.keyEquivalent == "b" && $0.keyEquivalentModifierMask == [.command,.option] && $0.action == #selector(StudioWindowController.toggleClaude(_:)) }
            let terminalKey = menuKeys.contains { $0.keyEquivalent == "`" && $0.keyEquivalentModifierMask == [.control] && $0.action == #selector(StudioWindowController.showTerminal(_:)) }
            studio.setClaude(hidden:false); studio.window?.makeFirstResponder(studio.input)
            studio.toggleClaude(nil)
            let claudeClosed = studio.claudeHidden && UserDefaults.standard.bool(forKey:"studio.claudeHidden") && !((studio.window?.firstResponder as? NSView)?.isDescendant(of:studio.claudePanel) ?? false)
            let claudeButtonOff = studio.claudeToggle.state == .off
            studio.toggleClaude(nil)
            regression["panel_buttons_show_open_state"] = terminalButtonOn && terminalButtonOff && claudeButtonOff && studio.claudeToggle.state == .on
            let claudeOpened = !studio.claudeHidden && (studio.window?.firstResponder as? NSTextView)?.delegate === studio.input && studio.claudePanel.frame.width > 100
            regression["claude_panel_toggles_with_opt_cmd_b"] = claudeKey && terminalKey && claudeClosed && claudeOpened
            if regression["claude_panel_toggles_with_opt_cmd_b"] != true { fputs("Claude panel: keys=\(claudeKey)/\(terminalKey) closed=\(claudeClosed) opened=\(claudeOpened) width=\(studio.claudePanel.frame.width)\n",stderr) }
            UserDefaults.standard.removeObject(forKey:"studio.claudeHidden")
            let rendered = LogMarkdown.render("## 제목\n- **굵게** 와 `code`\n```\nlet a = 1\n```",size:13)
            func font(at text: String) -> NSFont? { let at = (rendered.string as NSString).range(of:text).location; return at == NSNotFound ? nil : rendered.attribute(.font,at:at,effectiveRange:nil) as? NSFont }
            let markdownOK = rendered.string == "제목\n•  굵게 와 code\nlet a = 1" && font(at:"제목")?.pointSize == 14 && font(at:"굵게")?.fontDescriptor.symbolicTraits.contains(.bold) == true
                && font(at:"code")?.isFixedPitch == true && font(at:"let a")?.isFixedPitch == true
            studio.newSession(); studio.setClaude(hidden:false)
            studio.ingest(#"{"type":"assistant","message":{"content":[{"type":"text","text":"첫 줄 `x`"}]}}"#)
            let conversation = studio.logText.contains("Claude\n첫 줄 x")
            regression["claude_log_reads_as_conversation"] = markdownOK && conversation
            if regression["claude_log_reads_as_conversation"] != true { fputs("Log: markdown=\(markdownOK) \(rendered.string.debugDescription) log=\(studio.logText.suffix(120).debugDescription)\n",stderr) }
        } catch { fputs("Workspace check: \(error.localizedDescription)\n",stderr) }
    }

    func runUICheck() {
        guard let document = documents.last, let controller = document.controller else { exit(1) }
        // A stalled check must fail loudly and name the stage instead of hanging.
        DispatchQueue.global().asyncAfter(deadline:.now() + 40) { fputs("UI check timed out at stage: \(self.checkStage)\n",stderr); exit(1) }
        checkStage = "document regressions"
        runRegressionChecks(root:checkRoot!)
        checkStage = "workspace"
        runStudioChecks(root:checkRoot!)
        checkStage = "settings sheet"
        let settingsSheet = MarginSettingsController(parent:controller.window!) {}
        settingsSheet.provider.selectItem(at:0); settingsSheet.changedProvider()
        let gatewayChoices = settingsSheet.model.itemTitles
        settingsSheet.provider.selectItem(at:1); settingsSheet.changedProvider()
        regression["model_picker_offers_choices"] = gatewayChoices.contains("anthropic/claude-sonnet-5.5") && gatewayChoices.count >= 4 && settingsSheet.model.itemTitles.contains("claude-sonnet-5-5") && settingsSheet.model.indexOfSelectedItem >= 0
        if regression["model_picker_offers_choices"] != true { fputs("Model picker: \(gatewayChoices) / \(settingsSheet.model.itemTitles) selected=\(settingsSheet.model.indexOfSelectedItem)\n",stderr) }
        controller.refreshAuto()
        regression["auto_review_requires_connection"] = controller.aiConnected || controller.auto.state == .off
        regression["checks_do_not_touch_keychain"] = !CredentialStore.keychainEnabled
        regression["format_bar_only_on_editable_preview"] = controller.panes[0].formatBar.isHidden && !controller.panes[1].formatBar.isHidden
        controller.auto.state = .off
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.setMode(0)
        let sourceMode = !controller.panes[0].isHidden && controller.panes[1].isHidden
        controller.setMode(1)
        let previewMode = controller.panes[0].isHidden && !controller.panes[1].isHidden
        controller.panes[0].setKind(1); controller.panes[1].setKind(0)
        let independent = controller.panes[0].sourceScroll.isHidden && controller.panes[1].preview.isHidden
        controller.panes[0].setKind(0); controller.panes[1].setKind(1)
        controller.setMode(2)
        checkStage = "tab and undo"
        let target = "원래 문장입니다."
        document.source = "# 제목\n\n" + target
        controller.refreshSources()
        let range = (document.source as NSString).range(of:target)
        controller.activeEditor.setSelectedRange(range)
        let proposal = ReviewProposal(range:range,original:target,replacement:"고친 문장입니다.",reason:"검증",category:"wording",facts:[],searchStatus:"disabled",revision:document.revision)
        controller.showProposal(proposal)
        let tabHandled = controller.textView(controller.activeEditor,doCommandBy:#selector(NSResponder.insertTab(_:)))
        let tabApplied = tabHandled && document.source.contains("고친 문장입니다.")
        let canUndo = controller.activeEditor.undoManager?.canUndo == true
        controller.activeEditor.undoManager?.undo()
        let undoWorked = document.source.contains(target)
        document.source = "# Native check\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- [x] ready\n\n```js\nconst x = 1;\n```\n\n<script>window.bad=true</script>"
        let file = checkRoot!.appendingPathComponent("autosave.md")
        do {
            let bytes = document.format.encode(document.source)
            try bytes.write(to:file)
            document.fileURL = file; document.expectedDiskHash = MarginHash.data(bytes)
        } catch { fputs("UI fixture: \(error.localizedDescription)\n",stderr); exit(1) }
        controller.refreshSources()
        controller.setMode(2)
        controller.activeEditor.setSelectedRange(NSRange(location:(document.source as NSString).length,length:0))
        controller.activeEditor.insertText("\n\n자동저장 검증입니다.",replacementRange:controller.activeEditor.selectedRange())
        controller.renderPreview()
        checkStage = "waiting for first preview render"
        DispatchQueue.main.asyncAfter(deadline:.now() + 3) {
            self.checkStage = "preview edit script"
            let beforeEdit = document.source
            let pasteFixture = "[\"<meta charset='utf-8'><b style=\\\"font-weight:normal;\\\" id=\\\"docs-internal-guid-1\\\"><h1 dir=\\\"ltr\\\"><span style=\\\"font-weight:400\\\">제목</span></h1><p dir=\\\"ltr\\\"><span style=\\\"font-weight:700\\\">굵게</span><span> 와 </span><span style=\\\"font-style:italic\\\">기울임</span><span> 그리고 </span><a href=\\\"https://example.com\\\"><span style=\\\"text-decoration:underline\\\">링크</span></a></p><ul><li dir=\\\"ltr\\\"><p dir=\\\"ltr\\\"><span>하나</span></p></li><ul><li><p><span>중첩</span></p></li></ul><li><p><span>둘</span></p></li></ul><div dir=\\\"ltr\\\"><table><tbody><tr><td><p><span>A</span></p></td><td><p><span>B</span></p></td></tr><tr><td><p><span>1</span></p></td><td><p><span>2</span></p></td></tr></tbody></table></div></b>\", \"제목\\n굵게 와 기울임 그리고 링크\\n하나\\n중첩\\n둘\\nA\\tB\\n1\\t2\"]"
            let pasteExpected = "# 제목\n\n**굵게** 와 *기울임* 그리고 [링크](https://example.com)\n\n- 하나\n  - 중첩\n- 둘\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
            let codeFixture = "[\"<div style=\\\"font-family: Menlo, monospace; white-space: pre;\\\"><div><span style=\\\"color:#0000ff\\\">let</span> x = 1</div><div>print(x)</div></div>\", \"let x = 1\\nprint(x)\"]"
            let roundTripFixture = "\"# 제목 *강조* `code`\\n\\n본문 **굵게** _기울임_ ~~취소~~ [링크](https://example.com \\\"설명\\\") https://example.com snake_case #태그 2 \\\\* 3 \\\\[대괄호\\\\]  \\n줄바꿈 뒤 문장\\n\\n1. 하나\\n2. 둘\\n   - 중첩 **항목**\\n   - [ ] 할 일\\n3. 셋\\n\\n5. 다섯\\n6. 여섯\\n\\n- 느슨한 항목\\n\\n- 둘째 문단 항목\\n\\n> 인용문 `코드`\\n>\\n> - 인용 안 목록\\n\\n```swift\\nlet x = 1\\n\\nprint(x)\\n```\\n\\n    들여쓴 코드\\n\\n| 왼쪽 | 가운데 | 오른쪽 |\\n| :--- | :---: | ---: |\\n| a \\\\| b | **c** | `d` |\\n\\n---\\n\\n![그림](https://example.com/a.png) 뒤 문장\\n\\n## 둘째 제목\\n\\n\\\\# 제목 아님\\n\\n1\\\\. 목록 아님\\n\""
            let editScript = "(()=>{const root=document.querySelector('#document');const para=[...root.querySelectorAll('section.block')].pop()?.querySelector('p');const box=root.querySelector('input[type=checkbox]');if(!para||!box||para.textContent!=='자동저장 검증입니다.'||root.contentEditable!=='true')return false;para.firstChild.nodeValue='미리보기에서 고쳤습니다.';root.dispatchEvent(new InputEvent('input',{bubbles:true}));box.checked=false;box.dispatchEvent(new Event('change',{bubbles:true}));const range=document.createRange();range.selectNodeContents(para);range.collapse(false);getSelection().removeAllRanges();getSelection().addRange(range);document.execCommand('insertLineBreak');document.execCommand('insertText',false,'둘째 줄 #태그');range.selectNodeContents(para);range.collapse(false);getSelection().removeAllRanges();getSelection().addRange(range);const data=new DataTransfer();data.setData('text/html','<span style=\"font-weight:700\">붙임</span>');data.setData('text/plain','붙임');root.dispatchEvent(new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true}));const head=root.querySelector('h1');range.selectNodeContents(head);getSelection().removeAllRanges();getSelection().addRange(range);const rendered=!!head&&window.marginFormat('italic')===true&&window.marginFormat('h2')===true;const cell=[...root.querySelectorAll('th')].pop();range.selectNodeContents(cell);getSelection().removeAllRanges();getSelection().addRange(range);const chipped=window.marginFormat('tag')===true&&!!cell.querySelector('.tag');root.dispatchEvent(new FocusEvent('focusout',{bubbles:true}));const itemText=[...root.querySelector('li').childNodes].find(node=>node.nodeType===3);range.setStart(itemText,itemText.nodeValue.indexOf('ready'));range.setEnd(itemText,itemText.nodeValue.length);getSelection().removeAllRanges();getSelection().addRange(range);const address=new DataTransfer();address.setData('text/plain','https://example.com');root.dispatchEvent(new ClipboardEvent('paste',{clipboardData:address,bubbles:true,cancelable:true}));const linked=!!root.querySelector('li a[href]');return rendered&&chipped&&linked})()"
            controller.panes[1].preview.evaluateJavaScript(editScript) { opened,_ in
            DispatchQueue.main.asyncAfter(deadline:.now() + 2.5) {
            let expected = beforeEdit.replacingOccurrences(of:"자동저장 검증입니다.",with:"미리보기에서 고쳤습니다.\n둘째 줄 #태그**붙임**").replacingOccurrences(of:"- [x] ready",with:"- [ ] [ready](https://example.com)").replacingOccurrences(of:"# Native check",with:"## *Native check*").replacingOccurrences(of:"| A | B |",with:"| A | #B |")
            self.checkStage = "preview verification"
            if document.source != expected { fputs("Preview edit source: \(document.source.suffix(80))\n",stderr) }
            self.regression["preview_edit_updates_source"] = opened as? Bool == true && expected != beforeEdit && document.source == expected && controller.panes[0].editor.string == expected
            let plainCheck = #"(()=>{const s=source,e=editable,t='{\n  "key": "<b>값</b>"\n}\n# not a heading';window.marginRender(t,true,0,true,true);const p=document.querySelector('#document pre.plain');const ok=!!p&&p.textContent===t&&!document.querySelector('#document h1')&&document.querySelector('#document').contentEditable==='false';window.marginRender(s,e,0,true,false);return ok&&!document.querySelector('#document pre.plain')})()"#
            controller.panes[1].preview.evaluateJavaScript("({heading:document.querySelector('h1,h2')?.textContent,table:!!document.querySelector('td'),tasks:!!document.querySelector('input[type=checkbox]'),code:!!document.querySelector('.token.keyword'),safe:!window.bad,edited:document.querySelector('#document').textContent.includes('미리보기에서 고쳤습니다.')&&!document.querySelector('input:checked')&&document.querySelectorAll('section.block').length>3,paste:window.marginConvertHTML(..."+pasteFixture+"),codePaste:window.marginConvertHTML(..."+codeFixture+")===null,tags:(()=>{const box=document.createElement('div');box.append(clean(marked.parse('글 #태그 #a/b #123 a#b https://x.com/#no `#code` \\\\#esc')));return [...box.querySelectorAll('.tag')].map(node=>node.textContent).join(',')})(),chip:!!document.querySelector('#document .tag'),lineBreak:!!document.querySelector('#document p br'),roundtrip:window.marginRoundTrip("+roundTripFixture+"),plain:"+plainCheck+"})") { result,error in
                self.checkStage = "autosave, history and restore"
                let value = result as? [String:Any] ?? [:]
                self.regression["preview_edit_rerenders"] = value["edited"] as? Bool == true
                let jsonDocument = MarginDocument(), mdDocument = MarginDocument()
                jsonDocument.record.name = "settings.json"; mdDocument.record.name = "노트.md"
                self.regression["non_markdown_preview_shows_text_as_is"] = value["plain"] as? Bool == true && jsonDocument.isPlainText && !mdDocument.isPlainText
                if self.regression["non_markdown_preview_shows_text_as_is"] != true { fputs("Plain preview: js=\(value["plain"] ?? "nil") json=\(jsonDocument.isPlainText) md=\(mdDocument.isPlainText)\n",stderr) }
                self.regression["rich_paste_converts_to_markdown"] = value["paste"] as? String == pasteExpected && value["codePaste"] as? Bool == true
                if self.regression["rich_paste_converts_to_markdown"] != true { fputs("Rich paste: \(value["paste"] ?? "nil") code=\(value["codePaste"] ?? "nil")\n",stderr) }
                self.regression["tags_render_as_chips"] = value["tags"] as? String == "#태그,#a/b" && value["chip"] as? Bool == true
                if self.regression["tags_render_as_chips"] != true { fputs("Tags: \(value["tags"] ?? "nil") chip=\(value["chip"] ?? "nil")\n",stderr) }
                self.regression["soft_line_break_in_preview"] = value["lineBreak"] as? Bool == true
                let roundTrip = value["roundtrip"] as? [String:Any] ?? [:]
                self.regression["preview_serializer_roundtrip"] = (roundTrip["blocks"] as? Int ?? 0) >= 12 && (roundTrip["locked"] as? [String])?.isEmpty == true
                if self.regression["preview_serializer_roundtrip"] != true { fputs("Round trip: \(roundTrip)\n",stderr) }
                let latest = try? self.store.latest(document.record.id)
                let original = try? Data(contentsOf:file)
                let autosave = latest?.text == document.source
                let originalSaved = original == document.format.encode(document.source)
                let layout = controller.panes.allSatisfy { $0.bounds.width > 250 && $0.bounds.height > 250 }
                var historyOK = false, restoreOK = false
                do {
                    let versions = try self.store.versions(document.record.id)
                    let history = MarginHistoryController(document:document,versions:versions,parent:controller.window!)
                    historyOK = history.table.numberOfRows == versions.count && history.pane.editor.string == versions.first?.text
                    if let oldest = versions.last {
                        let current = document.source
                        try document.restore(oldest)
                        let undoCleared = controller.activeEditor.undoManager?.canUndo == false
                        controller.activeEditor.undoManager?.undo()
                        self.regression["restore_then_undo_safe"] = undoCleared && document.source == oldest.text && controller.activeEditor.string == oldest.text
                        let retained = try self.store.versions(document.record.id)
                        restoreOK = document.source == oldest.text && retained.contains { $0.text == current }
                        document.source = current; try document.flush(); controller.refreshSources()
                    }
                } catch { historyOK = false; restoreOK = false }
                let pass = error == nil && value["heading"] as? String == "Native check" && value["table"] as? Bool == true && value["tasks"] as? Bool == true && value["code"] as? Bool == true && value["safe"] as? Bool == true && controller.panes.count == 2 && sourceMode && previewMode && independent && tabApplied && canUndo && undoWorked && autosave && originalSaved && layout && historyOK && restoreOK && self.regression.count == 47 && self.regression.values.allSatisfy { $0 }
                let receipt: [String:Any] = ["pass":pass,"native_editor_class":String(describing:type(of:controller.panes[0].editor)),"split_panels":controller.panes.count,"source_mode":sourceMode,"preview_mode":previewMode,"independent_panes":independent,"native_tab_apply":tabApplied,"native_undo":undoWorked,"durable_autosave":autosave,"original_file_autosave":originalSaved,"history_panel":historyOK,"native_restore":restoreOK,"layout":layout,"pane_frames":controller.panes.map { NSStringFromRect($0.frame) },"save_status":controller.status.stringValue,"preview":value,"regressions":self.regression,"bundle":Bundle.main.bundleURL.path,"localhost_server_required":false]
                func finish() {
                    print(String(data:try! JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
                    if let root = self.checkRoot { try? FileManager.default.removeItem(at:root) }
                    exit(pass ? 0 : 1)
                }
                if let index = CommandLine.arguments.firstIndex(of:"--snapshot"), CommandLine.arguments.indices.contains(index + 1), let content = controller.window?.contentView {
                    controller.panes[1].preview.takeSnapshot(with:nil) { image,_ in
                        if let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                            content.cacheDisplay(in:content.bounds,to:bitmap)
                            let composed = NSImage(size:content.bounds.size); composed.addRepresentation(bitmap)
                            if let image {
                                composed.lockFocus()
                                image.draw(in:controller.panes[1].preview.convert(controller.panes[1].preview.bounds,to:content))
                                composed.unlockFocus()
                            }
                            if let data = composed.tiffRepresentation, let representation = NSBitmapImageRep(data:data), let png = representation.representation(using:.png,properties:[:]) { try? png.write(to:URL(fileURLWithPath:CommandLine.arguments[index + 1])) }
                        }
                        finish()
                    }
                } else { finish() }
            }
            }
            }
        }
    }
}

@objc(MarginDocument)
final class MarginDocument: NSDocument {
    static var defaultStore: VersionStore!
    var source = ""
    var format = DocumentFormat()
    var revision = 0
    var expectedDiskHash: String?
    let store: VersionStore
    var record: DocumentRecord
    var controller: MarginWindowController? { windowControllers.first as? MarginWindowController }
    static let markdownExtensions: Set<String> = ["md","markdown","mdown","mkd","mkdn","mdx",""]
    /// Files that are not Markdown (JSON, YAML, code, text) preview as their own text instead of being parsed as Markdown.
    var isPlainText: Bool { !Self.markdownExtensions.contains((fileURL?.pathExtension ?? (record.name as NSString).pathExtension).lowercased()) }
    private let saveQueue = DispatchQueue(label:"com.peterlyoo.Margin.autosave")
    private var pendingSave: DispatchWorkItem?
    private var closed = false

    override convenience init() {
        let record = DocumentRecord(id:UUID().uuidString,path:nil,name:"제목 없음.md",versions:[],updatedAt:Date())
        self.init(store:Self.defaultStore,record:record)
    }

    init(store: VersionStore, record: DocumentRecord) {
        self.store = store; self.record = record
        super.init()
        fileType = "net.daringfireball.markdown"
    }
    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { true }
    override func makeWindowControllers() {
        let controller = MarginWindowController(document:self)
        addWindowController(controller)
    }
    override func data(ofType typeName: String) throws -> Data { format.encode(source) }
    override func read(from data: Data, ofType typeName: String) throws {
        let value = try DocumentFormat.decode(data)
        source = value.text; format = value.format; expectedDiskHash = MarginHash.data(data)
        revision += 1; controller?.cancelReview(); controller?.refreshSources()
    }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        try persistNow(reason:saveOperation == .autosaveInPlaceOperation ? "자동저장" : "파일 저장")
        if fileURL?.standardizedFileURL == url.standardizedFileURL { try FileGuard.validate(url,expected:expectedDiskHash) }
        try super.writeSafely(to:url,ofType:typeName,for:saveOperation)
        if [.saveOperation,.saveAsOperation,.autosaveInPlaceOperation,.autosaveAsOperation].contains(saveOperation) {
            expectedDiskHash = MarginHash.data(try Data(contentsOf:url))
            record.path = url.standardizedFileURL.path; record.name = url.lastPathComponent
            try store.save(record:record,text:source,format:format,reason:"파일 저장")
        }
    }
    func edited(reason: String = "자동저장") {
        revision += 1
        updateChangeCount(.changeDone)
        controller?.setStatus("저장하고 있어요…")
        pendingSave?.cancel()
        let capturedText = source, capturedFormat = format, capturedRevision = revision
        var capturedRecord = record
        capturedRecord.path = fileURL?.standardizedFileURL.path ?? record.path
        capturedRecord.name = fileURL?.lastPathComponent ?? record.name
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                _ = try self.store.save(record:capturedRecord,text:capturedText,format:capturedFormat,reason:reason)
                DispatchQueue.main.async {
                    guard !self.closed, self.revision == capturedRevision else { return }
                    if self.fileURL != nil {
                        self.autosave(withImplicitCancellability:false) { error in
                            guard self.revision == capturedRevision else { return }
                            self.controller?.setStatus(error.map { "원본 파일 저장 중단 · " + $0.localizedDescription } ?? "자동저장 완료 · 원본 파일과 버전 기록")
                        }
                    } else { self.controller?.setStatus("자동저장 완료 · 임시 복구본과 버전 기록") }
                }
            } catch { DispatchQueue.main.async { if !self.closed && self.revision == capturedRevision { self.controller?.setStatus("자동저장 실패 · " + error.localizedDescription) } } }
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline:.now() + 1,execute:work)
    }
    func persistNow(reason: String) throws {
        var metadata = record
        metadata.path = fileURL?.standardizedFileURL.path ?? record.path
        metadata.name = fileURL?.lastPathComponent ?? record.name
        try store.save(record:metadata,text:source,format:format,reason:reason)
    }
    func flush() throws {
        pendingSave?.cancel()
        saveQueue.sync {}
        try persistNow(reason:"앱 종료 전 자동저장")
    }
    override func close() {
        do { try flush() }
        catch { presentError(error); return }
        closed = true
        controller?.cancelReview()
        super.close()
        (NSApp.delegate as? MarginAppDelegate)?.documents.removeAll { $0 === self }
    }
    func restore(_ version: SavedVersion) throws {
        try flush()
        let restored = try store.restore(record:record,versionID:version.id,current:source,format:format)
        source = restored.text; format = restored.format
        controller?.cancelReview(); controller?.refreshSources()
        edited(reason:"이전 버전으로 복원")
    }
    func reopenOriginal() throws {
        guard let path = fileURL?.path ?? record.path else { throw MarginError.message("저장된 원본 파일이 없어요.") }
        try flush()
        let url = URL(fileURLWithPath:path)
        try read(from:Data(contentsOf:url),ofType:"net.daringfireball.markdown")
        fileURL = url; record.path = url.standardizedFileURL.path; record.name = url.lastPathComponent
        fileModificationDate = (try? FileManager.default.attributesOfItem(atPath:url.path))?[.modificationDate] as? Date
        updateChangeCount(.changeCleared)
        try persistNow(reason:"저장된 파일 다시 읽기")
    }
}
