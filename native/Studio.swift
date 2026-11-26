import AppKit
import WebKit

final class StudioNode {
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [StudioNode] = []
    init(name: String, path: String, isDirectory: Bool) { self.name = name; self.path = path; self.isDirectory = isDirectory }

    static func tree(_ paths: [String]) -> [StudioNode] {
        let root = StudioNode(name:"",path:"",isDirectory:true)
        var folders: [String:StudioNode] = [:]
        for path in paths {
            var node = root
            let parts = path.split(separator:"/").map(String.init)
            for (index, part) in parts.enumerated() {
                let folder = index < parts.count - 1
                let key = parts[0...index].joined(separator:"/")
                if folder, let existing = folders[key] { node = existing; continue }
                let child = StudioNode(name:part,path:key,isDirectory:folder)
                if folder { folders[key] = child }
                node.children.append(child); node = child
            }
        }
        func sort(_ node: StudioNode) {
            node.children.sort { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            node.children.forEach(sort)
        }
        sort(root)
        return root.children
    }
}

enum CodeHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize:12.5,weight:.regular)
    static let hashComments: Set<String> = ["py","rb","sh","bash","zsh","yml","yaml","toml","tf","pl","r","conf","ini","dockerfile","makefile","mk"]
    static let plain: Set<String> = ["txt","log","csv","json","lock"]
    static let keywords: Set<String> = ["as","async","await","break","case","catch","class","const","continue","def","default","defer","do","elif","else","enum","except","export","extension","extends","false","final","finally","fn","for","from","func","function","guard","if","impl","implements","import","in","init","interface","is","let","match","mut","new","nil","None","not","null","or","and","override","package","pass","private","protocol","pub","public","raise","return","self","static","struct","super","switch","then","this","throw","throws","true","True","False","try","type","typealias","use","val","var","void","where","while","with","yield","fi","done","esac","local","lambda","go","chan","select","range","map","namespace","using","template","typename","virtual","unsigned","int","long","float","double","char","bool","string"]
    private static let slash = try! NSRegularExpression(pattern:"(\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'|`(?:\\\\.|[^`\\\\])*`)|(//[^\\n]*|/\\*[\\s\\S]*?\\*/)")
    private static let hash = try! NSRegularExpression(pattern:"(\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*')|(#[^\\n]*)")
    private static let words = try! NSRegularExpression(pattern:"\\b(?:[A-Za-z_][A-Za-z0-9_]*|[0-9][0-9A-Fa-fx_.]*)\\b")

    static func apply(_ storage: NSTextStorage, path: String) {
        let text = storage.string as NSString, whole = NSRange(location:0,length:text.length)
        storage.beginEditing()
        storage.setAttributes([.font:font,.foregroundColor:NSColor.labelColor],range:whole)
        let name = (path as NSString).lastPathComponent.lowercased()
        let kind = (name as NSString).pathExtension.isEmpty ? name : (name as NSString).pathExtension
        if !plain.contains(kind), text.length <= 300_000 {
            for match in words.matches(in:storage.string,range:whole) {
                let word = text.substring(with:match.range)
                if word.first?.isNumber == true { storage.addAttribute(.foregroundColor,value:NSColor.systemOrange,range:match.range) }
                else if keywords.contains(word) { storage.addAttribute(.foregroundColor,value:NSColor.systemPink,range:match.range) }
            }
            for match in (hashComments.contains(kind) ? hash : slash).matches(in:storage.string,range:whole) {
                storage.addAttribute(.foregroundColor,value:match.range(at:1).location != NSNotFound ? NSColor.systemRed : NSColor.secondaryLabelColor,range:match.range)
            }
        }
        storage.endEditing()
    }
}

final class LineRuler: NSRulerView {
    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView:scrollView,orientation:.verticalRuler)
        clientView = textView; ruleThickness = 46
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = clientView as? NSTextView, let manager = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:NSColor.tertiaryLabelColor]
        let visible = manager.characterRange(forGlyphRange:manager.glyphRange(forBoundingRect:view.visibleRect,in:container),actualGlyphRange:nil)
        var number = 1
        text.enumerateSubstrings(in:NSRange(location:0,length:visible.location),options:[.byLines,.substringNotRequired]) { _,_,_,_ in number += 1 }
        var index = text.lineRange(for:NSRange(location:min(visible.location,text.length),length:0)).location
        if index < visible.location { number -= 1 }
        while true {
            let line = text.lineRange(for:NSRange(location:index,length:0))
            let fragment = index < text.length ? manager.lineFragmentRect(forGlyphAt:manager.glyphIndexForCharacter(at:index),effectiveRange:nil) : manager.extraLineFragmentRect
            let label = "\(number)" as NSString, size = label.size(withAttributes:attributes)
            label.draw(at:NSPoint(x:ruleThickness - size.width - 8,y:fragment.minY + view.textContainerInset.height - view.visibleRect.minY + (fragment.height - size.height) / 2),withAttributes:attributes)
            number += 1; index = NSMaxRange(line)
            if index >= text.length || index > NSMaxRange(visible) || line.length == 0 { break }
        }
    }
}

final class CodePane: NSView {
    let scroll = NSScrollView()
    let editor = NSTextView(frame:NSRect(x:0,y:0,width:600,height:400))
    private(set) var ruler: LineRuler!
    private var pending: DispatchWorkItem?
    var path = ""

    init() {
        super.init(frame:.zero)
        _ = editor.layoutManager
        editor.isRichText = false; editor.allowsUndo = true; editor.usesFindBar = true
        editor.font = CodeHighlighter.font; editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.textContainerInset = NSSize(width:6,height:10)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true; editor.autoresizingMask = []
        editor.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .noBorder
        ruler = LineRuler(textView:editor,scrollView:scroll)
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector:#selector(redraw),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
        NotificationCenter.default.addObserver(self,selector:#selector(changed),name:NSText.didChangeNotification,object:editor)
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo:topAnchor),scroll.leadingAnchor.constraint(equalTo:leadingAnchor),scroll.trailingAnchor.constraint(equalTo:trailingAnchor),scroll.bottomAnchor.constraint(equalTo:bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc func redraw() { ruler.needsDisplay = true }
    @objc func changed() {
        redraw(); pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline:.now() + 0.25,execute:work)
    }
    func highlight() {
        guard let storage = editor.textStorage, !editor.hasMarkedText() else { return }
        CodeHighlighter.apply(storage,path:path)
    }
    func load(_ text: String, path: String) {
        self.path = path
        editor.string = text; editor.undoManager?.removeAllActions()
        highlight(); redraw()
    }
}

final class ReviewTextView: NSTextView {
    var onKey: ((UInt16, Bool) -> Bool)?
    override func keyDown(with event: NSEvent) { if onKey?(event.keyCode,event.modifierFlags.contains(.shift)) != true { super.keyDown(with:event) } }
}

/// The step list keeps its own arrow-key navigation; only accept and reject are taken over.
final class ReviewTable: NSTableView {
    var onKey: ((UInt16, Bool) -> Bool)?
    override func keyDown(with event: NSEvent) { if ![48,51,117,123,124].contains(event.keyCode) || onKey?(event.keyCode,event.modifierFlags.contains(.shift)) != true { super.keyDown(with:event) } }
}

final class StudioWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    let root: URL
    let scanner: WorkspaceScanner
    let sessions: SessionStore?
    private(set) var recorder: StepRecorder
    private(set) var session: AgentSession
    private(set) var nodes: [StudioNode] = []
    let outline = NSOutlineView()
    let tabs = NSSegmentedControl(labels:["파일","변경 따라가기"],trackingMode:.selectOne,target:nil,action:nil)
    let fileArea = NSView(), reviewArea = NSView()
    let fileTitle = marginLabel("",size:12)
    /// Shown in the file area until a file is open: what to do next and the shortcuts that do it.
    let emptyState = NSStackView()
    private(set) var formatButton: NSButton!
    private(set) var terminalToggle: NSButton!
    private(set) var claudeToggle: NSButton!
    let markdownPane = MarginPane(kind:1)
    let codePane = CodePane()
    let stepsTable = ReviewTable()
    let reasonText = ReviewTextView()
    let diffText = ReviewTextView()
    let counter = marginLabel("",size:12,color:.labelColor)
    let acceptButton = NSButton(title:"수락  ⇥ Tab",target:nil,action:nil)
    let rejectButton = NSButton(title:"거절  ⌫ Delete",target:nil,action:nil)
    let partButton = NSButton(title:"이 부분만 거절  ⇧⌫",target:nil,action:nil)
    private(set) var partFocus = 0
    let log = NSTextView()
    let input = NSTextField()
    let allowShell = NSButton(checkboxWithTitle:"Claude의 셸 명령 허용",target:nil,action:nil)
    let followBox = NSButton(checkboxWithTitle:"파일 따라가기",target:nil,action:nil)
    let stopButton = NSButton(title:"중지",target:nil,action:nil)
    let status = marginLabel("",size:11)
    let terminal: TerminalView
    /// Right side panel: the Claude log and instruction line. ⌥⌘B.
    let claudePanel = NSView()
    private let mainSplit = NSSplitView()
    private let centerSplit = NSSplitView()
    private var sidebar: NSView?
    private var sidebarWidth: CGFloat = 230
    private var claudeWidth: CGFloat = 380
    private var terminalHeight: CGFloat = 260
    private(set) var searchPanel: WorkspaceSearchController?
    private var terminalQuiet: DispatchWorkItem?
    /// Folders searched for formatters; nil means the person's own. Set by the checks.
    var formatSearch: [String]?
    private var agent: LineProcess?
    private(set) var openPath: String?
    private var openFormat = DocumentFormat()
    private var diskHash: String?
    private var dirty = false
    private var loading = false
    private var pendingSave: DispatchWorkItem?
    private var pendingRender: DispatchWorkItem?
    private var warnedTruncation = false
    private var stopRequested = false
    private var startupNoise: [String] = []
    private var sawStream = false
    private var shownStep: String?
    private var following = false
    var selectedStep: Int? { stepsTable.selectedRow >= 0 ? stepsTable.selectedRow : nil }
    var agentRunning: Bool { agent != nil || starting }

    let background: Bool
    private var starting = false
    init(root: URL, sessions: SessionStore?, background: Bool = true) {
        self.background = background
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        scanner = WorkspaceScanner(root:self.root)
        self.sessions = sessions
        if let saved = sessions?.sessions(root:self.root.path).first {
            session = saved
            recorder = StepRecorder(root:self.root,steps:saved.steps,sessionID:saved.agentSessionID,background:background)
        } else {
            session = AgentSession(id:UUID().uuidString,root:self.root.path,createdAt:Date(),prompts:[],steps:[],summary:"",agentSessionID:nil)
            recorder = StepRecorder(root:self.root,background:background)
        }
        terminal = TerminalView(directory:self.root)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:860),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.minSize = NSSize(width:900,height:600); window.title = "Margin · " + self.root.lastPathComponent; window.isRestorable = false
        super.init(window:window)
        window.delegate = self; window.center()
        build()
        recorder.onStep = { [weak self] step in self?.stepAdded(step) }
        reloadSteps()
        recorder.whenIdle { [weak self] in self?.refreshTree() }
        setStatus(recorder.steps.isEmpty ? "오른쪽 Claude 패널(⌥⌘B)에 지시를 적으면 Claude가 이 폴더에서 작업하고, 변경을 단계별로 기록해요." : "지난 세션의 변경 \(recorder.steps.count)단계를 불러왔어요.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func fill(_ view: NSView, in parent: NSView, top: NSLayoutYAxisAnchor? = nil, bottom: NSLayoutYAxisAnchor? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if view.superview !== parent { parent.addSubview(view) }
        NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo:top ?? parent.topAnchor),view.leadingAnchor.constraint(equalTo:parent.leadingAnchor),view.trailingAnchor.constraint(equalTo:parent.trailingAnchor),view.bottomAnchor.constraint(equalTo:bottom ?? parent.bottomAnchor)])
    }
    private func scrolling(_ view: NSView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        return scroll
    }
    private func readOnly(_ view: NSTextView, font: NSFont) {
        view.isEditable = false; view.isSelectable = true; view.isRichText = true; view.font = font
        view.textContainerInset = NSSize(width:10,height:8); view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true; view.backgroundColor = .textBackgroundColor
        view.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let main = mainSplit; main.isVertical = true; main.dividerStyle = .thin
        status.lineBreakMode = .byTruncatingTail; status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        terminalToggle = marginButton("터미널  ⌃`",symbol:"terminal",target:self,action:#selector(showTerminal(_:)))
        terminalToggle.toolTip = "이 폴더에서 여는 실제 터미널을 아래에 열고 닫아요(vim, top 등 사용 가능)."
        claudeToggle = marginButton("Claude  ⌥⌘B",symbol:"sparkles",target:self,action:#selector(toggleClaude(_:)))
        claudeToggle.toolTip = "Claude에게 일을 시키는 오른쪽 패널을 열고 닫아요."
        for button in [terminalToggle!,claudeToggle!] { button.controlSize = .small; button.bezelStyle = .recessed; button.setButtonType(.pushOnPushOff) }
        let statusBar = NSStackView(views:[status,NSView(),terminalToggle!,claudeToggle!])
        statusBar.orientation = .horizontal; statusBar.spacing = 8; statusBar.edgeInsets = NSEdgeInsets(top:0,left:12,bottom:0,right:8)
        statusBar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(statusBar)
        NSLayoutConstraint.activate([statusBar.leadingAnchor.constraint(equalTo:content.leadingAnchor),statusBar.trailingAnchor.constraint(equalTo:content.trailingAnchor),statusBar.bottomAnchor.constraint(equalTo:content.bottomAnchor),statusBar.heightAnchor.constraint(equalToConstant:26)])
        fill(main,in:content,bottom:statusBar.topAnchor)
        // File tree
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("name")); column.resizingMask = .autoresizingMask
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil; outline.rowHeight = 22
        outline.dataSource = self; outline.delegate = self; outline.style = .sourceList
        outline.target = self; outline.doubleAction = #selector(toggleFolder(_:))
        let side = scrolling(outline)
        main.addSubview(side); sidebar = side
        let right = centerSplit; right.isVertical = false; right.dividerStyle = .thin
        main.addSubview(right)
        // Upper: tabs + file or review
        let upper = NSView()
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changedTab); tabs.segmentStyle = .texturedRounded
        formatButton = marginButton("코드 정리",symbol:"wand.and.stars",target:self,action:#selector(formatDocument(_:))); formatButton.isEnabled = false
        formatButton.toolTip = "열린 파일을 그 언어의 정리 도구(Python은 ruff 등)로 정리해요. ⌥⌘L"
        let bar = NSStackView(views:[tabs,fileTitle,NSView(),formatButton!])
        bar.orientation = .horizontal; bar.spacing = 12; bar.edgeInsets = NSEdgeInsets(top:8,left:12,bottom:8,right:12)
        bar.translatesAutoresizingMaskIntoConstraints = false; upper.addSubview(bar)
        fileTitle.lineBreakMode = .byTruncatingMiddle; fileTitle.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        NSLayoutConstraint.activate([bar.topAnchor.constraint(equalTo:upper.topAnchor),bar.leadingAnchor.constraint(equalTo:upper.leadingAnchor),bar.trailingAnchor.constraint(equalTo:upper.trailingAnchor),bar.heightAnchor.constraint(equalToConstant:44)])
        fill(fileArea,in:upper,top:bar.bottomAnchor); fill(reviewArea,in:upper,top:bar.bottomAnchor)
        fill(markdownPane,in:fileArea); fill(codePane,in:fileArea)
        markdownPane.isHidden = true; codePane.isHidden = true
        buildEmptyState()
        markdownPane.editor.delegate = self; codePane.editor.delegate = self
        markdownPane.onKindChanged = { [weak self] in self?.renderMarkdown() }
        markdownPane.onPreviewError = { [weak self] message in self?.setStatus("미리보기 오류 · " + message) }
        markdownPane.onPreviewEdit = { [weak self] range, before, replacement in self?.applyPreviewEdit(range:range,before:before,replacement:replacement) ?? false }
        // Review: steps | reason + diff + buttons
        let review = NSSplitView(); review.isVertical = true; review.dividerStyle = .thin
        fill(review,in:reviewArea)
        let stepColumn = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("step")); stepColumn.resizingMask = .autoresizingMask
        stepsTable.addTableColumn(stepColumn); stepsTable.headerView = nil; stepsTable.rowHeight = 40
        stepsTable.dataSource = self; stepsTable.delegate = self; stepsTable.allowsEmptySelection = true
        review.addSubview(scrolling(stepsTable))
        let detail = NSView(); review.addSubview(detail)
        readOnly(reasonText,font:.systemFont(ofSize:13)); readOnly(diffText,font:CodeHighlighter.font)
        diffText.onKey = { [weak self] code, shift in self?.reviewKey(code,shift) ?? false }
        reasonText.onKey = { [weak self] code, shift in self?.reviewKey(code,shift) ?? false }
        partButton.target = self; partButton.action = #selector(rejectPart); partButton.bezelStyle = .rounded
        partButton.toolTip = "한 단계가 여러 군데를 고쳤을 때, ←/→로 고른 한 군데만 되돌려요."
        followBox.state = UserDefaults.standard.object(forKey:"studio.follow") == nil || UserDefaults.standard.bool(forKey:"studio.follow") ? .on : .off
        followBox.target = self; followBox.action = #selector(changedFollow)
        followBox.toolTip = "단계를 넘길 때 그 단계가 고친 파일을 왼쪽 목록과 파일 탭에서 함께 열어요. Claude가 작업하는 동안에는 새 단계를 따라가요."
        stepsTable.onKey = { [weak self] code, shift in self?.reviewKey(code,shift) ?? false }
        let reasonScroll = scrolling(reasonText), diffScroll = scrolling(diffText)
        acceptButton.target = self; acceptButton.action = #selector(acceptStep); acceptButton.bezelStyle = .rounded
        rejectButton.target = self; rejectButton.action = #selector(rejectStep); rejectButton.bezelStyle = .rounded
        let buttons = NSStackView(views:[marginButton("이전",symbol:"chevron.up",target:self,action:#selector(previousStep)),marginButton("다음",symbol:"chevron.down",target:self,action:#selector(nextStep)),counter,NSView(),followBox,marginButton("파일 열기",symbol:"doc.text",target:self,action:#selector(openStepFile)),partButton,rejectButton,acceptButton])
        buttons.orientation = .horizontal; buttons.spacing = 10; buttons.edgeInsets = NSEdgeInsets(top:8,left:12,bottom:8,right:12)
        for view in [reasonScroll,diffScroll,buttons] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; detail.addSubview(view) }
        NSLayoutConstraint.activate([
            reasonScroll.topAnchor.constraint(equalTo:detail.topAnchor),reasonScroll.leadingAnchor.constraint(equalTo:detail.leadingAnchor),reasonScroll.trailingAnchor.constraint(equalTo:detail.trailingAnchor),reasonScroll.heightAnchor.constraint(equalTo:detail.heightAnchor,multiplier:0.26),
            diffScroll.topAnchor.constraint(equalTo:reasonScroll.bottomAnchor,constant:1),diffScroll.leadingAnchor.constraint(equalTo:detail.leadingAnchor),diffScroll.trailingAnchor.constraint(equalTo:detail.trailingAnchor),diffScroll.bottomAnchor.constraint(equalTo:buttons.topAnchor),
            buttons.leadingAnchor.constraint(equalTo:detail.leadingAnchor),buttons.trailingAnchor.constraint(equalTo:detail.trailingAnchor),buttons.bottomAnchor.constraint(equalTo:detail.bottomAnchor),buttons.heightAnchor.constraint(equalToConstant:44)
        ])
        reviewArea.isHidden = true
        right.addSubview(upper)
        // Bottom panel: the terminal, hidden until ⌃`.
        terminal.isHidden = true
        terminal.onActivity = { [weak self] in self?.terminalActivity() }
        right.addSubview(terminal)
        // Right panel: Claude log + instruction line
        let panel = claudePanel
        readOnly(log,font:.systemFont(ofSize:13)); log.textContainerInset = NSSize(width:14,height:12)
        let logScroll = scrolling(log)
        input.placeholderString = "Claude에게 시킬 일을 적고 Enter를 누르세요."
        input.target = self; input.action = #selector(send); input.font = .systemFont(ofSize:13); input.delegate = self
        allowShell.state = UserDefaults.standard.object(forKey:"studio.allowShell") == nil || UserDefaults.standard.bool(forKey:"studio.allowShell") ? .on : .off
        allowShell.target = self; allowShell.action = #selector(changedAllowShell); allowShell.controlSize = .small
        stopButton.target = self; stopButton.action = #selector(stop); stopButton.bezelStyle = .rounded; stopButton.isEnabled = false
        let head = NSStackView(views:[marginLabel("Claude",size:13,color:.labelColor),NSView(),marginButton("새 세션",symbol:"plus.bubble",target:self,action:#selector(newSession))])
        head.orientation = .horizontal; head.spacing = 8; head.edgeInsets = NSEdgeInsets(top:6,left:12,bottom:6,right:8)
        let line = NSStackView(views:[input,stopButton])
        line.orientation = .horizontal; line.spacing = 8; line.edgeInsets = NSEdgeInsets(top:6,left:10,bottom:4,right:10)
        let foot = NSStackView(views:[allowShell,NSView()])
        foot.orientation = .horizontal; foot.edgeInsets = NSEdgeInsets(top:0,left:12,bottom:6,right:12)
        for view in [head,logScroll,line,foot] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(view) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo:panel.topAnchor),head.leadingAnchor.constraint(equalTo:panel.leadingAnchor),head.trailingAnchor.constraint(equalTo:panel.trailingAnchor),head.heightAnchor.constraint(equalToConstant:44),
            logScroll.topAnchor.constraint(equalTo:head.bottomAnchor),logScroll.leadingAnchor.constraint(equalTo:panel.leadingAnchor),logScroll.trailingAnchor.constraint(equalTo:panel.trailingAnchor),logScroll.bottomAnchor.constraint(equalTo:line.topAnchor),
            line.leadingAnchor.constraint(equalTo:panel.leadingAnchor),line.trailingAnchor.constraint(equalTo:panel.trailingAnchor),line.heightAnchor.constraint(equalToConstant:36),line.bottomAnchor.constraint(equalTo:foot.topAnchor),
            foot.leadingAnchor.constraint(equalTo:panel.leadingAnchor),foot.trailingAnchor.constraint(equalTo:panel.trailingAnchor),foot.bottomAnchor.constraint(equalTo:panel.bottomAnchor),foot.heightAnchor.constraint(equalToConstant:24)
        ])
        main.addSubview(panel)
        content.layoutSubtreeIfNeeded()
        main.setPosition(230,ofDividerAt:0); main.setPosition(main.bounds.width - claudeWidth,ofDividerAt:1); review.setPosition(270,ofDividerAt:0)
        if UserDefaults.standard.bool(forKey:"studio.sidebarHidden") { side.isHidden = true; main.adjustSubviews() }
        // Panels come when called: Claude starts closed until the person opens it once with ⌥⌘B.
        if UserDefaults.standard.object(forKey:"studio.claudeHidden") == nil || UserDefaults.standard.bool(forKey:"studio.claudeHidden") { panel.isHidden = true; main.adjustSubviews() }
        syncToggles()
        main.setHoldingPriority(.defaultHigh,forSubviewAt:0); main.setHoldingPriority(.defaultHigh,forSubviewAt:2); right.setHoldingPriority(.defaultHigh,forSubviewAt:1); review.setHoldingPriority(.defaultHigh,forSubviewAt:0)
    }

    private func buildEmptyState() {
        let title = marginLabel("왼쪽 목록에서 파일을 고르세요",size:17,color:.labelColor)
        let grid = NSGridView(views:StudioWindowController.emptyShortcuts.map { key, what in
            let keyLabel = marginLabel(key,size:13,color:.secondaryLabelColor); keyLabel.font = .monospacedSystemFont(ofSize:13,weight:.medium); keyLabel.alignment = .right
            return [keyLabel,marginLabel(what,size:13,color:.secondaryLabelColor)]
        })
        grid.rowSpacing = 8; grid.columnSpacing = 16; grid.column(at:0).xPlacement = .trailing
        emptyState.setViews([title,grid],in:.center)
        emptyState.orientation = .vertical; emptyState.alignment = .centerX; emptyState.spacing = 20
        emptyState.translatesAutoresizingMaskIntoConstraints = false; fileArea.addSubview(emptyState)
        NSLayoutConstraint.activate([emptyState.centerXAnchor.constraint(equalTo:fileArea.centerXAnchor),emptyState.centerYAnchor.constraint(equalTo:fileArea.centerYAnchor,constant:-40)])
    }
    /// Only shortcuts the app already has; each borrowed from the tool it came from.
    static let emptyShortcuts: [(String,String)] = [("⌘K ⌘B","파일 목록 표시/숨기기"),("⌘F","이 파일에서 찾기"),("⇧⌘F","폴더 전체에서 찾기"),("⌃`","터미널"),("⌥⌘B","Claude 패널"),("⌥⌘L","코드 정리")]
    /// The status bar buttons show which panel is open, and the file controls only work with a file open.
    func syncToggles() {
        terminalToggle.state = terminal.isHidden ? .off : .on
        claudeToggle.state = claudePanel.isHidden ? .off : .on
        formatButton.isEnabled = openPath != nil
        emptyState.isHidden = openPath != nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        DispatchQueue.main.async { [weak self] in
            guard let self, let content = self.window?.contentView else { return }
            content.layoutSubtreeIfNeeded()
            if !self.sidebarHidden { self.mainSplit.setPosition(self.sidebarWidth,ofDividerAt:0) }
            self.placeClaude()
        }
    }

    // MARK: Sidebar and search

    var sidebarHidden: Bool { sidebar?.isHidden ?? false }
    /// ⌘K ⌘B, as in Sublime Text.
    @objc func toggleSidebar(_ sender: Any?) { setSidebar(hidden:!sidebarHidden) }
    func setSidebar(hidden: Bool) {
        guard let sidebar, sidebar.isHidden != hidden else { return }
        if hidden {
            if sidebar.frame.width > 40 { sidebarWidth = sidebar.frame.width }
            if window?.firstResponder === outline { window?.makeFirstResponder(isMarkdown && markdownPane.selector.selectedSegment == 1 ? nil : activeEditor) }
            sidebar.isHidden = true; mainSplit.adjustSubviews()
        } else {
            sidebar.isHidden = false; mainSplit.adjustSubviews(); mainSplit.setPosition(sidebarWidth,ofDividerAt:0)
        }
        UserDefaults.standard.set(hidden,forKey:"studio.sidebarHidden")
    }

    var claudeHidden: Bool { claudePanel.isHidden }
    /// ⌥⌘B, as VS Code's secondary side bar: opens the Claude panel on the instruction line, or closes it.
    @objc func toggleClaude(_ sender: Any?) {
        if claudeHidden { setClaude(hidden:false); window?.makeFirstResponder(input) } else { setClaude(hidden:true) }
        syncToggles()
    }
    func setClaude(hidden: Bool) {
        guard claudePanel.isHidden != hidden else { return }
        if hidden {
            if claudePanel.frame.width > 80 { claudeWidth = claudePanel.frame.width }
            if let view = window?.firstResponder as? NSView, view.isDescendant(of:claudePanel) { focusMain() }
            claudePanel.isHidden = true; mainSplit.adjustSubviews()
        } else {
            claudePanel.isHidden = false; mainSplit.adjustSubviews(); placeClaude()
        }
        UserDefaults.standard.set(hidden,forKey:"studio.claudeHidden")
        syncToggles()
    }
    private func placeClaude() {
        guard !claudeHidden else { return }
        mainSplit.setPosition(mainSplit.bounds.width - claudeWidth - mainSplit.dividerThickness,ofDividerAt:1)
    }
    var terminalHidden: Bool { terminal.isHidden }
    /// ⌃`, as in VS Code: opens the terminal panel, focuses it, or closes it when it already has focus.
    @objc func showTerminal(_ sender: Any?) {
        if terminal.isHidden { setTerminal(hidden:false) }
        else if window?.firstResponder === terminal { setTerminal(hidden:true) }
        else { window?.makeFirstResponder(terminal) }
        syncToggles()
    }
    func setTerminal(hidden: Bool) {
        guard terminal.isHidden != hidden else { return }
        if hidden {
            if terminal.frame.height > 60 { terminalHeight = terminal.frame.height }
            if window?.firstResponder === terminal { focusMain() }
            terminal.isHidden = true; centerSplit.adjustSubviews()
        } else {
            terminal.isHidden = false; centerSplit.adjustSubviews()
            centerSplit.setPosition(centerSplit.bounds.height - terminalHeight,ofDividerAt:0)
            window?.contentView?.layoutSubtreeIfNeeded()
            if !terminal.isRunning, terminal.exitStatus == nil { terminal.start() }
            window?.makeFirstResponder(terminal)
        }
        syncToggles()
    }
    private func focusMain() {
        if !reviewArea.isHidden { window?.makeFirstResponder(stepsTable) }
        else if openPath == nil || (isMarkdown && markdownPane.selector.selectedSegment == 1) { window?.makeFirstResponder(outline) }
        else { window?.makeFirstResponder(activeEditor) }
    }

    /// ⌘F when no editor has focus (tree, log, markdown preview): show the source and its find bar.
    @objc func marginShowFind(_ sender: Any?) {
        guard openPath != nil else { findInWorkspace(sender); return }
        if tabs.selectedSegment != 0 { tabs.selectedSegment = 0; showTab() }
        if isMarkdown, markdownPane.selector.selectedSegment != 0 { markdownPane.setKind(0) }
        window?.makeFirstResponder(activeEditor)
        activeEditor.marginShowFind(sender)
    }

    /// ⇧⌘F: Sublime's Find in Files over this workspace.
    @objc func findInWorkspace(_ sender: Any?) {
        if searchPanel == nil {
            searchPanel = WorkspaceSearchController(root:root,paths:{ [weak self] in self?.recorder.paths ?? [] }) { [weak self] hit in self?.reveal(hit) }
        }
        var query: String?
        if let editor = window?.firstResponder as? NSTextView, editor === activeEditor, editor.selectedRange().length > 0 {
            let text = (editor.string as NSString).substring(with:editor.selectedRange())
            if !text.contains("\n") { query = text }
        }
        searchPanel?.present(over:window,query:query)
    }

    @discardableResult func reveal(_ hit: SearchHit) -> Bool {
        guard openPath == hit.path || openFile(hit.path) else { return false }
        if tabs.selectedSegment != 0 { tabs.selectedSegment = 0; showTab() }
        if isMarkdown, markdownPane.selector.selectedSegment != 0 { markdownPane.setKind(0) }
        let editor = activeEditor
        guard NSMaxRange(hit.range) <= (editor.string as NSString).length else { return false }
        selectInTree(hit.path)
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(editor)
        editor.setSelectedRange(hit.range); editor.scrollRangeToVisible(hit.range); editor.showFindIndicator(for:hit.range)
        return true
    }
    private func selectInTree(_ path: String) {
        var parts = path.split(separator:"/").map(String.init), list = nodes, item: StudioNode?
        var prefix = ""
        while !parts.isEmpty {
            prefix = prefix.isEmpty ? parts.removeFirst() : prefix + "/" + parts.removeFirst()
            guard let node = list.first(where:{ $0.path == prefix }) else { return }
            item = node
            if node.isDirectory { outline.expandItem(node); list = node.children }
        }
        guard let item else { return }
        let row = outline.row(forItem:item)
        if row >= 0 { following = true; outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); outline.scrollRowToVisible(row); following = false }
    }

    /// Tool details name files by absolute path; inside the workspace the relative path is what the person recognises.
    func short(_ detail: String) -> String {
        let line = detail.split(separator:"\n").first.map(String.init) ?? ""
        return line.replacingOccurrences(of:"/private" + root.path + "/",with:"").replacingOccurrences(of:root.path + "/",with:"")
    }
    func setStatus(_ value: String) { status.stringValue = value; status.toolTip = value }

    // MARK: File tree

    func refreshTree() {
        let expanded = Set((0..<outline.numberOfRows).compactMap { outline.item(atRow:$0) as? StudioNode }.filter { outline.isItemExpanded($0) }.map(\.path))
        let all = recorder.paths
        if recorder.untracked > 0, !warnedTruncation {
            warnedTruncation = true
            append("파일이 \(recorder.total)개라서, 처음 열 때 이름순으로 앞의 \(WorkspaceRules.maxFiles)개와 그 뒤에 새로 생긴 파일만 변경을 기록해요. 나머지 \(recorder.untracked)개는 Claude가 고쳐도 단계로 남지 않아요. 더 좁은 하위 폴더를 열어 주세요.",color:.systemRed)
        }
        nodes = StudioNode.tree(all)
        outline.reloadData()
        func restore(_ list: [StudioNode]) { for node in list where expanded.contains(node.path) { outline.expandItem(node); restore(node.children) } }
        restore(nodes)
    }
    @objc func toggleFolder(_ sender: Any?) {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow:row) as? StudioNode, node.isDirectory else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? StudioNode)?.children ?? nodes).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? StudioNode)?.children ?? nodes)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? StudioNode)?.isDirectory == true }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? StudioNode else { return nil }
        let touched = !node.isDirectory && recorder.steps.contains { step in step.decision == "pending" && step.changes.contains { $0.path == node.path } }
        let cell = NSTableCellView()
        let image = NSImageView(image:NSImage(systemSymbolName:node.isDirectory ? "folder" : "doc.text",accessibilityDescription:nil) ?? NSImage())
        let label = marginLabel(node.name + (touched ? "  ●" : ""),size:12,color:touched ? .systemOrange : .labelColor)
        label.lineBreakMode = .byTruncatingMiddle
        let row = NSStackView(views:[image,label]); row.orientation = .horizontal; row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo:cell.leadingAnchor),row.trailingAnchor.constraint(lessThanOrEqualTo:cell.trailingAnchor),row.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !following, let node = outline.item(atRow:outline.selectedRow) as? StudioNode, !node.isDirectory else { return }
        openFile(node.path)
    }

    // MARK: File view

    private var isMarkdown: Bool { ["md","markdown"].contains(((openPath ?? "") as NSString).pathExtension.lowercased()) }
    private var activeEditor: NSTextView { isMarkdown ? markdownPane.editor : codePane.editor }

    @discardableResult func openFile(_ path: String, reveal: Bool = true) -> Bool {
        flushSave()
        guard WorkspaceRules.safe(path), !WorkspaceRules.secret(path) else { setStatus("\(path): 비밀 값이 들어 있을 수 있는 파일이라 열지 않았어요."); return false }
        guard let data = try? Data(contentsOf:scanner.url(path)), data.count <= WorkspaceRules.maxBytes, let decoded = try? DocumentFormat.decode(data) else {
            setStatus("\(path): 1MB를 넘거나 UTF-8 텍스트가 아니라서 열지 않았어요."); return false
        }
        openPath = path; openFormat = decoded.format; diskHash = MarginHash.data(data); dirty = false
        loading = true
        markdownPane.isHidden = !isMarkdown; codePane.isHidden = isMarkdown
        if isMarkdown {
            markdownPane.editor.textStorage?.setAttributedString(NSAttributedString(string:decoded.text,attributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.labelColor]))
            markdownPane.editor.undoManager?.removeAllActions()
            markdownPane.text = decoded.text; renderMarkdown()
        } else { codePane.load(decoded.text,path:path) }
        loading = false
        fileTitle.stringValue = path
        syncToggles()
        if reveal { tabs.selectedSegment = 0; showTab() }
        return true
    }
    private func renderMarkdown() { if !markdownPane.isHidden, markdownPane.selector.selectedSegment == 1 { markdownPane.render(markdownPane.editor.string) } }
    private func applyPreviewEdit(range: NSRange, before: String, replacement: String) -> Bool {
        let editor = markdownPane.editor, current = editor.string as NSString
        guard NSMaxRange(range) <= current.length, current.substring(with:range) == before, !editor.hasMarkedText(), editor.shouldChangeText(in:range,replacementString:replacement) else { return false }
        editor.textStorage?.replaceCharacters(in:range,with:NSAttributedString(string:replacement,attributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.labelColor]))
        editor.didChangeText()
        return true
    }
    func textDidChange(_ notification: Notification) {
        guard !loading, let editor = notification.object as? NSTextView, editor === activeEditor, openPath != nil else { return }
        dirty = true
        fileTitle.stringValue = (openPath ?? "") + "  · 저장 전"
        if isMarkdown {
            markdownPane.text = editor.string
            pendingRender?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.renderMarkdown() }
            pendingRender = work
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.15,execute:work)
        }
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.flushSave() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline:.now() + 1,execute:save)
    }
    /// Writes the open file if it has unsaved edits. Refuses when the file changed on disk underneath the editor.
    func flushSave() {
        pendingSave?.cancel(); pendingSave = nil
        guard dirty, let path = openPath else { return }
        let url = scanner.url(path)
        do {
            try FileGuard.validate(url,expected:diskHash)
            let data = openFormat.encode(activeEditor.string)
            try data.write(to:url,options:.atomic)
            diskHash = MarginHash.data(data); dirty = false
            fileTitle.stringValue = path
            // An edit the person made is not the agent's: keep it out of the next recorded step.
            recorder.absorb(path)
        } catch { fileTitle.stringValue = path + "  · 저장 안 됨"; setStatus("\(path) 저장 중단 · " + error.localizedDescription) }
    }
    @objc func save(_ sender: Any?) { flushSave() }

    private(set) var formatting = false
    /// Runs the language's formatter on the editor text. The result is applied only if the text is still the one that was sent.
    @objc func formatDocument(_ sender: Any?) {
        guard let path = openPath else { setStatus("정리할 파일을 먼저 열어 주세요."); return }
        guard !formatting else { return }
        let editor = activeEditor, text = editor.string, directory = root, search = formatSearch
        guard !CodeFormatter.tools(for:path).isEmpty else { setStatus("\(path): 이 종류의 파일을 정리하는 도구는 아직 연결되어 있지 않아요."); return }
        formatting = true
        setStatus("\(path) 정리 중…")
        let work = { [weak self] in
            let outcome = CodeFormatter.format(text,path:path,directory:directory,search:search)
            let finish = { [weak self] in
                guard let self else { return }
                self.formatting = false
                self.applyFormat(outcome,path:path,sent:text)
            }
            if self?.background == true { DispatchQueue.main.async(execute:finish) } else { finish() }
        }
        if background { DispatchQueue.global(qos:.userInitiated).async(execute:work) } else { work() }
    }
    private func applyFormat(_ outcome: FormatOutcome, path: String, sent: String) {
        switch outcome {
        case .unavailable(let names): setStatus(names.isEmpty ? "\(path): 정리 도구가 없어요." : "\(path): 정리 도구를 찾지 못했어요. 다음 중 하나를 설치하면 사용해요 · " + names.joined(separator:", "))
        case .failed(let message): setStatus("정리하지 않았어요 · " + message)
        case .unchanged(let tool): setStatus("\(path): 이미 정리된 상태예요 (\(tool)).")
        case .formatted(let output, let tool):
            let editor = activeEditor
            guard openPath == path, editor.string == sent, !editor.hasMarkedText() else { setStatus("정리하는 동안 내용이 바뀌어서 적용하지 않았어요. 다시 실행해 주세요."); return }
            let edit = CodeFormatter.edit(before:sent,after:output)
            let old = sent as NSString, caret = editor.selectedRange().location
            let line = old.substring(to:min(caret,old.length)).components(separatedBy:"\n").count - 1
            guard editor.shouldChangeText(in:edit.range,replacementString:edit.replacement) else { return }
            editor.textStorage?.replaceCharacters(in:edit.range,with:edit.replacement)
            editor.didChangeText()
            let new = editor.string as NSString
            var location = 0, index = 0
            while index < line, location < new.length { location = NSMaxRange(new.lineRange(for:NSRange(location:location,length:0))); index += 1 }
            editor.setSelectedRange(NSRange(location:min(location,new.length),length:0)); editor.scrollRangeToVisible(editor.selectedRange())
            if !isMarkdown { codePane.highlight() }
            flushSave()
            setStatus(dirty ? "\(path): 정리했지만 저장하지 못했어요." : "\(path): \(tool)(으)로 정리하고 저장했어요. ⌘Z로 되돌릴 수 있어요.")
        }
    }
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === codePane.editor, !textView.hasMarkedText(), let path = openPath else { return false }
        let unit = CodeIndent.unit(textView.string,path:path), selection = textView.selectedRange()
        func replace(_ range: NSRange, _ text: String, select: NSRange) -> Bool {
            guard textView.shouldChangeText(in:range,replacementString:text) else { return true }
            textView.textStorage?.replaceCharacters(in:range,with:text); textView.didChangeText(); textView.setSelectedRange(select)
            textView.scrollRangeToVisible(select)
            return true
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = CodeIndent.newline(textView.string,at:selection.location,unit:unit)
            return replace(selection,text,select:NSRange(location:selection.location + (text as NSString).length,length:0))
        case #selector(NSResponder.insertTab(_:)):
            if selection.length == 0 || !(textView.string as NSString).substring(with:selection).contains("\n") { return replace(selection,unit,select:NSRange(location:selection.location + (unit as NSString).length,length:0)) }
            let shift = CodeIndent.shift(textView.string,selection:selection,unit:unit,outdent:false)
            return replace(shift.range,shift.replacement,select:shift.selection)
        case #selector(NSResponder.insertBacktab(_:)):
            let shift = CodeIndent.shift(textView.string,selection:selection,unit:unit,outdent:true)
            let removed = shift.range.length - (shift.replacement as NSString).length
            return replace(shift.range,shift.replacement,select:selection.length == 0 ? NSRange(location:max(shift.range.location,selection.location - removed),length:0) : shift.selection)
        default: return false
        }
    }
    func reloadOpenFileIfClean() {
        guard let path = openPath, !dirty, let data = try? Data(contentsOf:scanner.url(path)), MarginHash.data(data) != diskHash else { return }
        let selection = activeEditor.selectedRange(), kind = markdownPane.selector.selectedSegment
        // Reloading must not move the tab or the keyboard focus: the person may be typing an instruction.
        if openFile(path,reveal:false) {
            markdownPane.setKind(kind)
            activeEditor.setSelectedRange(NSRange(location:min(selection.location,(activeEditor.string as NSString).length),length:0))
        }
    }
    func showTab() { fileArea.isHidden = tabs.selectedSegment != 0; reviewArea.isHidden = tabs.selectedSegment != 1 }
    @objc func changedTab() { showTab(); if tabs.selectedSegment == 1 { window?.makeFirstResponder(stepsTable) } }
    @objc func changedFollow() { UserDefaults.standard.set(followBox.state == .on,forKey:"studio.follow"); if followBox.state == .on, let index = selectedStep { follow(recorder.steps[index]) } }

    private func node(_ path: String, in list: [StudioNode]) -> [StudioNode]? {
        for item in list {
            if item.path == path { return [item] }
            if item.isDirectory, path.hasPrefix(item.path + "/"), let rest = node(path,in:item.children) { return [item] + rest }
        }
        return nil
    }
    /// Shows the file a step changed in the tree and the file tab, at the first changed line, without moving the tab or the focus.
    func follow(_ step: AgentStep) {
        guard followBox.state == .on, let change = step.changes.first(where: { $0.after != nil }) ?? step.changes.first else { return }
        flushSave()
        guard !dirty else { return }
        following = true; defer { following = false }
        if let chain = node(change.path,in:nodes), let last = chain.last {
            for parent in chain.dropLast() { outline.expandItem(parent) }
            let row = outline.row(forItem:last)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); outline.scrollRowToVisible(row) }
        }
        // Someone typing in the file view keeps their file; the tree still shows where the step landed.
        if let editor = window?.firstResponder as? NSTextView, editor === activeEditor, openPath != change.path { return }
        guard FileManager.default.fileExists(atPath:scanner.url(change.path).path), openFile(change.path,reveal:false) else { return }
        let target = LineDiff.hunks(before:change.before ?? "",after:change.after ?? "").first?.newStart ?? 0
        let text = activeEditor.string as NSString
        var location = 0, line = 0
        while line < target, location < text.length { location = NSMaxRange(text.lineRange(for:NSRange(location:location,length:0))); line += 1 }
        let range = text.lineRange(for:NSRange(location:min(location,text.length),length:0))
        activeEditor.setSelectedRange(NSRange(location:range.location,length:0)); activeEditor.scrollRangeToVisible(range)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Tab is the accept key. With nothing typed it must not just walk the focus away from the instruction line.
        guard selector == #selector(NSResponder.insertTab(_:)), control === input, textView.string.isEmpty, !reviewArea.isHidden, let index = selectedStep, recorder.steps[index].decision == "pending" else { return false }
        acceptStep(); return true
    }

    // MARK: Step review

    func reloadSteps() {
        let selected = stepsTable.selectedRow
        stepsTable.reloadData()
        let pending = recorder.steps.filter { $0.decision == "pending" }.count
        tabs.setLabel(pending == 0 ? "변경 따라가기" : "변경 따라가기 · 확인 전 \(pending)",forSegment:1)
        if recorder.steps.indices.contains(selected) { selectStep(selected) } else if !recorder.steps.isEmpty { selectStep(recorder.steps.firstIndex { $0.decision == "pending" } ?? 0) } else { showStep() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { recorder.steps.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let step = recorder.steps[row]
        let mark = ["accepted":"✓","rejected":"✕"][step.decision] ?? "•"
        let color: NSColor = step.decision == "accepted" ? .systemGreen : step.decision == "rejected" ? .systemRed : .labelColor
        let title = marginLabel("\(mark) \(row + 1). " + step.changes.map { ($0.path as NSString).lastPathComponent }.joined(separator:", "),size:12,color:color)
        let first = step.reasoning.split(separator:"\n").last.map(String.init) ?? "이유를 말하지 않았어요."
        let reason = marginLabel(first,size:10.5)
        for label in [title,reason] { label.lineBreakMode = .byTruncatingTail }
        let stack = NSStackView(views:[title,reason]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 1
        let cell = NSTableCellView(); stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:6),stack.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),stack.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showStep() }
    func selectStep(_ index: Int) {
        guard recorder.steps.indices.contains(index) else { return }
        stepsTable.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false); stepsTable.scrollRowToVisible(index)
        showStep()
    }
    /// The separately rejectable parts of a step: each changed block of each file that existed before and after.
    static func parts(_ step: AgentStep) -> [(change: Int, hunk: DiffHunk)] {
        step.changes.enumerated().flatMap { index, change -> [(change: Int, hunk: DiffHunk)] in
            guard let before = change.before, let after = change.after else { return [] }
            return LineDiff.hunks(before:before,after:after).map { (index,$0) }
        }
    }
    /// `focus` is the part to mark; the returned location is where it starts in the text.
    static func diffText(for step: AgentStep, focus: Int? = nil) -> (text: NSAttributedString, focus: Int?) {
        let result = NSMutableAttributedString()
        let font = CodeHighlighter.font, bold = NSFont.monospacedSystemFont(ofSize:12.5,weight:.semibold)
        let marked = focus.flatMap { index -> (change: Int, hunk: DiffHunk)? in let all = parts(step); return all.count > 1 && all.indices.contains(index) ? all[index] : nil }
        var location: Int?
        for (index, change) in step.changes.enumerated() {
            let kind = change.before == nil ? "  새 파일" : change.after == nil ? "  삭제됨" : change.before == change.after ? "  되돌림" : ""
            result.append(NSAttributedString(string:change.path + kind + "\n",attributes:[.font:bold,.foregroundColor:NSColor.labelColor,.backgroundColor:NSColor.quaternaryLabelColor]))
            for line in LineDiff.unified(before:change.before ?? "",after:change.after ?? "") {
                guard let line else { result.append(NSAttributedString(string:"     ⋯\n",attributes:[.font:font,.foregroundColor:NSColor.tertiaryLabelColor])); continue }
                // A missing file is not an empty line: skip the phantom line the empty side would add.
                if (change.before == nil && line.kind == "-") || (change.after == nil && line.kind == "+") { continue }
                var focused = false
                if let marked, marked.change == index {
                    if line.kind == "-", let old = line.old { focused = old >= marked.hunk.oldStart && old < marked.hunk.oldStart + marked.hunk.oldLines.count }
                    if line.kind == "+", let new = line.new { focused = new >= marked.hunk.newStart && new < marked.hunk.newStart + marked.hunk.newLines.count }
                }
                if focused, location == nil { location = result.length }
                let number = String(format:"%4d",(line.new ?? line.old ?? 0) + 1)
                let alpha: CGFloat = focused ? 0.36 : 0.16
                let background: NSColor = line.kind == "+" ? NSColor.systemGreen.withAlphaComponent(alpha) : line.kind == "-" ? NSColor.systemRed.withAlphaComponent(alpha) : .clear
                result.append(NSAttributedString(string:"\(focused ? "▌" : " ")\(number) \(line.kind) \(line.text)\n",attributes:[.font:font,.foregroundColor:NSColor.labelColor,.backgroundColor:background]))
            }
            result.append(NSAttributedString(string:"\n",attributes:[.font:font]))
        }
        return (result,location)
    }
    private func renderDiff(_ step: AgentStep) {
        let drawn = Self.diffText(for:step,focus:partFocus)
        diffText.textStorage?.setAttributedString(drawn.text)
        if let location = drawn.focus { diffText.scrollRangeToVisible(NSRange(location:location,length:0)) } else { diffText.scrollToBeginningOfDocument(nil) }
    }
    func showStep() {
        guard let index = selectedStep, recorder.steps.indices.contains(index) else {
            reasonText.string = recorder.steps.isEmpty ? "아직 기록된 변경이 없어요. 오른쪽 Claude 패널(⌥⌘B)에서 일을 시키면, 파일이 바뀔 때마다 이유와 함께 한 단계씩 여기에 쌓여요." : ""
            diffText.textStorage?.setAttributedString(NSAttributedString()); counter.stringValue = ""; shownStep = nil
            acceptButton.isEnabled = false; rejectButton.isEnabled = false; partButton.isHidden = true; return
        }
        let step = recorder.steps[index]
        // Redrawing the same step would throw away the reading position each time another step arrives.
        if shownStep != step.id {
            shownStep = step.id; partFocus = 0
            let reason = NSMutableAttributedString(string:step.reasoning.isEmpty ? "Claude가 이 변경의 이유를 말하지 않았어요." : step.reasoning,attributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.labelColor])
            if !step.actions.isEmpty {
                let actions = step.actions.map { "⏵ \($0.tool)  \(short($0.detail))" }.joined(separator:"\n")
                reason.append(NSAttributedString(string:"\n\n실행한 도구\n" + actions,attributes:[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]))
            }
            reasonText.textStorage?.setAttributedString(reason)
            renderDiff(step)
            follow(step)
        }
        let state = ["accepted":"수락함","rejected":"거절하고 되돌림"][step.decision] ?? "확인 전"
        let count = Self.parts(step).count
        counter.stringValue = "\(index + 1) / \(recorder.steps.count) · \(state)" + (count > 1 ? " · 부분 \(partFocus + 1)/\(count)  ←/→" : "")
        acceptButton.isEnabled = step.decision == "pending"; rejectButton.isEnabled = step.decision != "rejected"
        partButton.isHidden = count < 2 || step.decision == "rejected"
    }
    private func movePart(_ delta: Int) -> Bool {
        guard let index = selectedStep else { return false }
        let count = Self.parts(recorder.steps[index]).count
        guard count > 1 else { return false }
        partFocus = min(max(partFocus + delta,0),count - 1)
        renderDiff(recorder.steps[index]); showStep()
        return true
    }
    private func reviewKey(_ code: UInt16, _ shift: Bool = false) -> Bool {
        switch code {
        case 48: acceptStep(); return true
        case 51, 117: if shift { rejectPart() } else { rejectStep() }; return true
        case 124: return movePart(1)
        case 123: return movePart(-1)
        case 125, 38: nextStep(); return true
        case 126, 40: previousStep(); return true
        default: return false
        }
    }
    /// Undoes one changed block of the selected step and leaves the rest of the step applied.
    @objc func rejectPart() {
        guard let index = selectedStep, recorder.steps[index].decision != "rejected" else { return }
        guard !agentRunning else { setStatus("Claude가 작업 중일 때는 거절할 수 없어요. 끝난 뒤에 다시 눌러 주세요."); return }
        let parts = Self.parts(recorder.steps[index])
        guard parts.count > 1, parts.indices.contains(partFocus) else { rejectStep(); return }
        flushSave()
        guard !dirty else { return }
        let part = parts[partFocus], change = recorder.steps[index].changes[part.change]
        guard let after = change.after else { return }
        var lines = LineDiff.lines(after)
        lines.replaceSubrange(part.hunk.newStart..<(part.hunk.newStart + part.hunk.newLines.count),with:part.hunk.oldLines)
        let kept = lines.joined(separator:"\n")
        do {
            try StepReverter.reject(AgentStep(id:"",reasoning:"",actions:[],changes:[FileChange(path:change.path,before:kept,after:after)]),root:root)
            recorder.dropHunk(step:index,change:part.change,after:kept); persist()
            setStatus("\(index + 1)단계에서 고른 부분만 되돌렸어요. 나머지 변경은 그대로예요.")
            partFocus = min(partFocus,max(0,parts.count - 2))
            renderDiff(recorder.steps[index]); stepsTable.reloadData(forRowIndexes:IndexSet(integer:index),columnIndexes:IndexSet(integer:0)); showStep()
            reloadOpenFileIfClean()
            recorder.rebase { [weak self] in self?.refreshTree() }
        } catch { setStatus(error.localizedDescription); NSSound.beep() }
    }
    @objc func nextStep() { if let index = selectedStep { selectStep(index + 1) } else { selectStep(0) } }
    @objc func previousStep() { if let index = selectedStep { selectStep(index - 1) } }
    private func advance(from index: Int) {
        let later = recorder.steps.indices.first { $0 > index && recorder.steps[$0].decision == "pending" }
        let target = later ?? recorder.steps.indices.first { recorder.steps[$0].decision == "pending" } ?? index
        reloadSteps(); selectStep(target); outline.reloadData()
    }
    @objc func acceptStep() {
        guard let index = selectedStep, recorder.steps[index].decision == "pending" else { return }
        recorder.decide(index,"accepted"); persist()
        setStatus("\(index + 1)단계를 수락했어요.")
        advance(from:index)
    }
    @objc func rejectStep() {
        guard let index = selectedStep, recorder.steps[index].decision != "rejected" else { return }
        guard !agentRunning else { setStatus("Claude가 작업 중일 때는 거절할 수 없어요. 끝난 뒤에 다시 눌러 주세요."); return }
        flushSave()
        guard !dirty else { return }
        do {
            try StepReverter.reject(recorder.steps[index],root:root)
            recorder.decide(index,"rejected"); persist()
            setStatus("\(index + 1)단계를 거절하고 파일을 그 전 내용으로 되돌렸어요.")
            reloadOpenFileIfClean(); advance(from:index)
            recorder.rebase { [weak self] in self?.refreshTree() }
        } catch { setStatus(error.localizedDescription); NSSound.beep() }
    }
    @objc func openStepFile() {
        guard let index = selectedStep, let path = recorder.steps[index].changes.first(where: { $0.after != nil })?.path else { return }
        openFile(path)
    }
    private func stepAdded(_ step: AgentStep) {
        append("● 변경 \(recorder.steps.count) · " + step.changes.map(\.path).joined(separator:", "),color:.systemGreen)
        // Someone reading the newest step, or nothing yet, is following the run: move on with it. Anyone reviewing an older step stays put.
        let atTail = stepsTable.selectedRow < 0 || stepsTable.selectedRow == recorder.steps.count - 2
        persist(); refreshTree(); reloadSteps(); reloadOpenFileIfClean()
        if atTail, followBox.state == .on { selectStep(recorder.steps.count - 1) }
    }
    private func persist() {
        session.steps = recorder.steps; session.summary = recorder.summary; session.agentSessionID = recorder.sessionID
        do { try sessions?.save(session) } catch { setStatus("세션 저장 실패 · " + error.localizedDescription) }
    }
    @objc func newSession() {
        guard !agentRunning else { setStatus("Claude가 작업 중이에요. 끝나거나 중지한 뒤에 새 세션을 시작해 주세요."); return }
        session = AgentSession(id:UUID().uuidString,root:root.path,createdAt:Date(),prompts:[],steps:[],summary:"",agentSessionID:nil)
        recorder = StepRecorder(root:root,background:background)
        recorder.onStep = { [weak self] step in self?.stepAdded(step) }
        log.string = ""; lastLogKind = nil; shownStep = nil; warnedTruncation = false; reloadSteps()
        recorder.whenIdle { [weak self] in self?.refreshTree() }
        // The session line goes to the Claude log; with that panel closed, nothing on screen would change.
        setClaude(hidden:false)
        append("＋ 새 세션 · 다음 지시부터 Claude가 이전 대화를 이어받지 않아요.",color:.systemBlue)
        window?.makeFirstResponder(input)
        setStatus("새 세션을 시작했어요. 지난 세션의 기록은 지우지 않았어요.")
    }

    // MARK: Agent

    private enum LogKind { case prompt, reply, tool, note }
    private var lastLogKind: LogKind?
    /// The log reads as a conversation: the person's instruction and Claude's reply in body text under a name, tools and notes small and grey.
    private func append(_ text: String, color: NSColor = .secondaryLabelColor, kind: LogKind = .note) {
        guard let storage = log.textStorage else { return }
        func style(before: CGFloat, after: CGFloat, indent: CGFloat = 0, line: CGFloat = 2) -> NSParagraphStyle {
            let value = NSMutableParagraphStyle(); value.paragraphSpacingBefore = before; value.paragraphSpacing = after
            value.firstLineHeadIndent = indent; value.headIndent = indent; value.lineSpacing = line
            return value
        }
        func header(_ name: String, _ tint: NSColor) -> NSAttributedString {
            NSAttributedString(string:name + "\n",attributes:[.font:NSFont.systemFont(ofSize:11,weight:.semibold),.foregroundColor:tint,.paragraphStyle:style(before:storage.length == 0 ? 0 : 14,after:3)])
        }
        let piece = NSMutableAttributedString()
        switch kind {
        case .prompt:
            piece.append(header("나",.systemBlue))
            piece.append(NSAttributedString(string:text + "\n",attributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:NSColor.labelColor,.paragraphStyle:style(before:0,after:4,line:3)]))
        case .reply:
            if lastLogKind != .reply && lastLogKind != .tool { piece.append(header("Claude",.systemPurple)) }
            let body = LogMarkdown.render(text,size:13)
            body.addAttribute(.paragraphStyle,value:style(before:2,after:6,line:3),range:NSRange(location:0,length:body.length))
            piece.append(body); piece.append(NSAttributedString(string:"\n"))
        case .tool:
            piece.append(NSAttributedString(string:text + "\n",attributes:[.font:NSFont.monospacedSystemFont(ofSize:10.5,weight:.regular),.foregroundColor:color,.paragraphStyle:style(before:1,after:1,indent:8,line:1)]))
        case .note:
            piece.append(NSAttributedString(string:text + "\n",attributes:[.font:NSFont.systemFont(ofSize:11.5),.foregroundColor:color,.paragraphStyle:style(before:5,after:3,line:2)]))
        }
        if kind != .note { lastLogKind = kind }
        storage.append(piece)
        if storage.length > 400_000 { storage.deleteCharacters(in:NSRange(location:0,length:storage.length - 300_000)) }
        log.scrollToEndOfDocument(nil)
    }
    var logText: String { log.string }
    /// Commands typed in the terminal change files too. Once its output has been quiet for a while, the tree and the open file catch up.
    private func terminalActivity() {
        terminalQuiet?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.agentRunning else { return }
            self.reloadOpenFileIfClean()
            self.recorder.rebase { [weak self] in self?.refreshTree() }
        }
        terminalQuiet = work
        DispatchQueue.main.asyncAfter(deadline:.now() + 2,execute:work)
    }
    @objc func changedAllowShell() { UserDefaults.standard.set(allowShell.state == .on,forKey:"studio.allowShell") }
    @objc func send() {
        let text = input.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if runAgent(text) { input.stringValue = "" }
    }
    /// Feeds one line of the agent's stream. Recorded runs are replayed through the same path.
    @discardableResult func ingest(_ line: String) -> [AgentEvent] {
        let events = recorder.feed(line)
        for event in events {
            switch event {
            case .text(let value): append(value,kind:.reply)
            case .toolUse(_, let tool, let detail): append("⏵ \(tool)  \(short(detail))",color:.secondaryLabelColor,kind:.tool)
            case .toolResult(_, let failed): if failed { append("  ↳ 도구 실행 실패",color:.systemRed,kind:.tool) }
            case .finished(_, let failed): append(failed ? "■ 오류로 끝났어요." : "■ 작업을 마쳤어요.",color:failed ? .systemRed : .secondaryLabelColor)
            case .raw(let value): append(value,color:.tertiaryLabelColor)
            case .session: break
            }
        }
        return events
    }
    @discardableResult func runAgent(_ prompt: String) -> Bool {
        guard !agentRunning else { setStatus("Claude가 아직 작업 중이에요. 끝난 뒤에 다음 지시를 보내 주세요."); return false }
        flushSave()
        session.prompts.append(prompt)
        append(prompt,kind:.prompt)
        starting = true; stopRequested = false; sawStream = false; startupNoise = []
        stopButton.isEnabled = true
        setStatus("Claude가 작업하고 있어요…")
        // The baseline is read first, so what changed before this run is never recorded as Claude's.
        recorder.rebase { [weak self] in self?.launch(prompt) }
        return true
    }
    private func launch(_ prompt: String) {
        starting = false
        guard !stopRequested else { stopButton.isEnabled = false; setStatus("Claude 작업을 시작하기 전에 중지했어요."); return }
        append("Claude 설정 폴더 · " + (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? "기본(~/.claude). 이 앱을 띄운 환경에 CLAUDE_CONFIG_DIR이 없어요."),color:.tertiaryLabelColor)
        let process = AgentLauncher.process(prompt:prompt,resume:recorder.sessionID,allowShell:allowShell.state == .on,directory:root)
        process.onLine = { [weak self] line, isError in
            guard let self else { return }
            // The login shell prints its own start-up messages before Claude starts; show them only if Claude never does.
            if isError, !self.sawStream { self.startupNoise.append(ShellRunner.plain(line)); return }
            if isError { self.append(ShellRunner.plain(line),color:.tertiaryLabelColor) } else { self.sawStream = true; self.ingest(line) }
        }
        process.onExit = { [weak self] code in
            // The run counts as going on until its last change is recorded; a reject in between would be read as Claude's edit.
            self?.recorder.capture {
                guard let self else { return }
                self.agent = nil; self.stopButton.isEnabled = false
                self.persist()
                if !self.sawStream { for line in self.startupNoise where !line.isEmpty { self.append(line,color:.tertiaryLabelColor) } }
                if self.stopRequested { self.setStatus("Claude 작업을 중지했어요. 그때까지 바뀐 내용은 단계로 남아 있어요."); return }
                let pending = self.recorder.steps.filter { $0.decision == "pending" }.count
                self.setStatus(code == 0 ? (pending == 0 ? "Claude가 작업을 마쳤어요. 바뀐 파일은 없어요." : "Claude가 작업을 마쳤어요. '변경 따라가기'에서 \(pending)단계를 순서대로 확인해 보세요.") : "Claude 실행이 종료 코드 \(code)로 끝났어요. Claude 패널의 기록을 확인해 주세요.")
            }
        }
        do { try process.start() } catch { stopButton.isEnabled = false; setStatus("Claude를 실행하지 못했어요 · " + error.localizedDescription); return }
        agent = process
    }
    @objc func stop() {
        if agentRunning { stopRequested = true; agent?.stop(); append("■ 중지를 요청했어요.",color:.systemRed) }
    }
    func shutdown() { flushSave(); stopRequested = true; agent?.stop(); terminalQuiet?.cancel(); terminal.stop() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        flushSave()
        if dirty { return false }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        shutdown()
        (NSApp.delegate as? MarginAppDelegate)?.studios.removeAll { $0 === self }
    }
}

/// Claude writes Markdown. The log shows its headings, lists, code blocks and inline emphasis instead of the raw marks.
enum LogMarkdown {
    static func render(_ text: String, size: CGFloat) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize:size), mono = NSFont.monospacedSystemFont(ofSize:size - 1.5,weight:.regular)
        var inFence = false
        let lines = text.trimmingCharacters(in:.newlines).components(separatedBy:"\n")
        for raw in lines {
            let end = result.length == 0 ? "" : "\n"
            if raw.trimmingCharacters(in:.whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                result.append(NSAttributedString(string:end + raw,attributes:[.font:mono,.foregroundColor:NSColor.labelColor,.backgroundColor:NSColor.quaternaryLabelColor.withAlphaComponent(0.25)]))
                continue
            }
            var line = raw, font = body
            if let match = line.range(of:#"^#{1,6}\s+"#,options:.regularExpression) {
                line.removeSubrange(match); font = .systemFont(ofSize:size + 1,weight:.semibold)
            } else if let match = line.range(of:#"^(\s*)[-*+]\s+"#,options:.regularExpression) {
                let indent = String(line[match].prefix { $0 == " " })
                line.replaceSubrange(match,with:indent + "•  ")
            }
            result.append(NSAttributedString(string:end)); result.append(inline(line,font:font,mono:mono))
        }
        return result
    }
    static func inline(_ text: String, font: NSFont, mono: NSFont) -> NSAttributedString {
        let plain: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:NSColor.labelColor]
        guard let parsed = try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace)) else { return NSAttributedString(string:text,attributes:plain) }
        let result = NSMutableAttributedString(string:"")
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes = plain
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attributes[.font] = mono; attributes[.foregroundColor] = NSColor.systemPink
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.25)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty { attributes[.font] = NSFont(descriptor:font.fontDescriptor.withSymbolicTraits(traits),size:font.pointSize) ?? font }
            }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string:piece,attributes:attributes))
        }
        return result
    }
}
