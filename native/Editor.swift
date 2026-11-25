import AppKit
import WebKit

func marginLabel(_ value: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let label = NSTextField(labelWithString:value)
    label.font = .systemFont(ofSize:size); label.textColor = color
    return label
}

func marginButton(_ title: String, symbol: String, target: AnyObject?, action: Selector) -> NSButton {
    let button = NSButton(title:title,target:target,action:action)
    button.bezelStyle = .rounded
    button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:title)
    button.imagePosition = .imageLeading
    return button
}

final class MarginMessageProxy: NSObject, WKScriptMessageHandler {
    weak var pane: MarginPane?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { pane?.receive(message.body) }
}

final class MarginTextView: NSTextView {
    var convertRichPaste: ((String, String, @escaping (String?) -> Void) -> Void)?
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        guard let convert = convertRichPaste, let html = board.string(forType:.html), !html.isEmpty else { super.paste(sender); return }
        convert(html,board.string(forType:.string) ?? "") { [weak self] markdown in
            guard let self else { return }
            if let markdown { self.insertText(markdown,replacementRange:self.selectedRange()) } else { self.pasteAsPlainText(sender) }
        }
    }
}

final class MarginPane: NSView, WKNavigationDelegate {
    let editor: NSTextView
    let sourceScroll: NSScrollView
    let preview: WKWebView
    let selector = NSSegmentedControl(labels:["원문 편집","미리보기"],trackingMode:.selectOne,target:nil,action:nil)
    var text = ""
    var loaded = false
    var onKindChanged: (() -> Void)?
    var onPreviewError: ((String) -> Void)?
    var onPreviewEdit: ((NSRange, String, String) -> Bool)? { didSet { updateFormatBar() } }
    private var editSequence = 0
    let formatBar = NSStackView()
    let blockPopup = NSPopUpButton()
    let styleControl = NSSegmentedControl()
    let insertControl = NSSegmentedControl()
    private let kindLabel = marginLabel("MARKDOWN",size:9)
    static let blockCommands = ["p","h1","h2","h3"]
    static let styleCommands = ["bold","italic","strike","code"]
    static let insertCommands = ["bullet","number","task","quote","codeblock","link","tag","rule"]

    init(kind: Int) {
        sourceScroll = NSScrollView()
        let textView = MarginTextView(frame:NSRect(x:0,y:0,width:500,height:500))
        editor = textView
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let proxy = MarginMessageProxy()
        config.userContentController.add(proxy,name:"margin")
        preview = WKWebView(frame:.zero,configuration:config)
        super.init(frame:.zero)
        proxy.pane = self
        textView.convertRichPaste = { [weak self] html, plain, done in
            guard let self else { done(nil); return }
            self.convertHTML(html,plain:plain,completion:done)
        }
        selector.selectedSegment = kind; selector.target = self; selector.action = #selector(changedKind)
        selector.segmentStyle = .texturedRounded
        blockPopup.addItems(withTitles:["본문","제목 1","제목 2","제목 3"])
        blockPopup.controlSize = .small; blockPopup.font = .systemFont(ofSize:11); blockPopup.toolTip = "문단 형식 (본문·제목)"
        blockPopup.target = self; blockPopup.action = #selector(changedBlock)
        func configure(_ control: NSSegmentedControl, _ items: [(String, String)], _ mode: NSSegmentedControl.SwitchTracking, _ action: Selector) {
            control.segmentCount = items.count; control.trackingMode = mode; control.controlSize = .small; control.segmentStyle = .texturedRounded
            for (index, item) in items.enumerated() {
                control.setImage(NSImage(systemSymbolName:item.0,accessibilityDescription:item.1),forSegment:index)
                control.setToolTip(item.1,forSegment:index); control.setWidth(27,forSegment:index)
            }
            control.target = self; control.action = action
        }
        configure(styleControl,[("bold","굵게"),("italic","기울임꼴"),("strikethrough","취소선"),("chevron.left.forwardslash.chevron.right","문장 내 코드")],.selectAny,#selector(changedStyle))
        configure(insertControl,[("list.bullet","글머리 기호 목록"),("list.number","번호 매기기 목록"),("checklist","체크박스 목록"),("text.quote","인용문"),("curlybraces","코드 블록"),("link","링크 삽입"),("tag","태그 추가"),("minus","구분선 삽입")],.momentary,#selector(changedInsert))
        for control in [blockPopup,styleControl,insertControl] as [NSControl] { control.refusesFirstResponder = true; formatBar.addArrangedSubview(control) }
        formatBar.orientation = .horizontal; formatBar.spacing = 6; formatBar.isHidden = true
        let header = NSStackView(views:[selector,formatBar,NSView(),kindLabel])
        header.setClippingResistancePriority(.defaultLow,for:.horizontal)
        header.orientation = .horizontal; header.spacing = 12
        editor.isRichText = false; editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.usesFindBar = true
        editor.textContainerInset = NSSize(width:26,height:24)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6
        editor.defaultParagraphStyle = paragraph
        sourceScroll.documentView = editor; sourceScroll.hasVerticalScroller = true
        sourceScroll.drawsBackground = true; sourceScroll.borderType = .noBorder
        preview.navigationDelegate = self
        for view in [header,sourceScroll,preview] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo:topAnchor,constant:10),header.leadingAnchor.constraint(equalTo:leadingAnchor,constant:16),header.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-16),header.heightAnchor.constraint(equalToConstant:30),
            sourceScroll.topAnchor.constraint(equalTo:header.bottomAnchor,constant:10),sourceScroll.leadingAnchor.constraint(equalTo:leadingAnchor),sourceScroll.trailingAnchor.constraint(equalTo:trailingAnchor),sourceScroll.bottomAnchor.constraint(equalTo:bottomAnchor),
            preview.topAnchor.constraint(equalTo:sourceScroll.topAnchor),preview.leadingAnchor.constraint(equalTo:leadingAnchor),preview.trailingAnchor.constraint(equalTo:trailingAnchor),preview.bottomAnchor.constraint(equalTo:bottomAnchor)
        ])
        if let html = Bundle.main.url(forResource:"preview",withExtension:"html"), let resources = Bundle.main.resourceURL { preview.loadFileURL(html,allowingReadAccessTo:resources) }
        setKind(kind)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc func changedKind() { setKind(selector.selectedSegment); onKindChanged?() }
    func setKind(_ value: Int) { selector.selectedSegment = value; sourceScroll.isHidden = value != 0; preview.isHidden = value != 1; updateFormatBar(); if value == 1 { render(text) } }
    func updateFormatBar() {
        formatBar.isHidden = !(selector.selectedSegment == 1 && onPreviewEdit != nil)
        kindLabel.isHidden = !formatBar.isHidden
    }
    func format(_ command: String) {
        guard loaded, command.range(of:"^[a-z0-9]+$",options:.regularExpression) != nil else { return }
        preview.evaluateJavaScript("window.marginFormat('\(command)')") { [weak self] _, error in
            guard let error else { return }
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            fputs("Preview error: \(detail)\n",stderr); self?.onPreviewError?(detail)
        }
    }
    @objc func changedBlock() { format(Self.blockCommands[max(0,blockPopup.indexOfSelectedItem)]) }
    @objc func changedStyle() { if Self.styleCommands.indices.contains(styleControl.selectedSegment) { format(Self.styleCommands[styleControl.selectedSegment]) } }
    @objc func changedInsert() { if Self.insertCommands.indices.contains(insertControl.selectedSegment) { format(Self.insertCommands[insertControl.selectedSegment]) } }
    func showFormatState(_ state: [String:Any]) {
        for (index, name) in Self.styleCommands.enumerated() { styleControl.setSelected(state[name] as? Bool == true,forSegment:index) }
        blockPopup.selectItem(at:Self.blockCommands.firstIndex(of:state["block"] as? String ?? "p") ?? 0)
    }
    func render(_ source: String, force: Bool = false) {
        text = source
        guard loaded, let data = try? JSONSerialization.data(withJSONObject:[source,onPreviewEdit != nil,editSequence,force] as [Any]), let json = String(data:data,encoding:.utf8) else { return }
        preview.evaluateJavaScript("window.marginRender(...\(json))") { [weak self] _, error in
            guard let error else { return }
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            let line = (error as NSError).userInfo["WKJavaScriptExceptionLineNumber"].map { " (preview.js:\($0))" } ?? ""
            fputs("Preview error: \(detail)\(line)\n",stderr); self?.onPreviewError?(detail + line)
        }
    }
    func convertHTML(_ html: String, plain: String, completion: @escaping (String?) -> Void) {
        guard loaded, let data = try? JSONSerialization.data(withJSONObject:[html,plain]), let json = String(data:data,encoding:.utf8) else { completion(nil); return }
        preview.evaluateJavaScript("window.marginConvertHTML(...\(json))") { result,_ in completion(result as? String) }
    }
    func receive(_ body: Any) {
        if let link = (body as? [String:Any])?["open"] as? String {
            if onPreviewEdit != nil, ReviewService.safeURL(link) != nil, let url = URL(string:link) { NSWorkspace.shared.open(url) }
            return
        }
        if let message = (body as? [String:Any])?["error"] as? String { fputs("Preview error: \(message)\n",stderr); onPreviewError?(message); return }
        if let state = (body as? [String:Any])?["state"] as? [String:Any] { showFormatState(state); return }
        guard let edit = body as? [String:Any], let sequence = edit["seq"] as? Int, let start = edit["start"] as? Int, let end = edit["end"] as? Int, let before = edit["before"] as? String, let replacement = edit["text"] as? String, start >= 0, end >= start else { return }
        editSequence = max(editSequence,sequence)
        if onPreviewEdit?(NSRange(location:start,length:end - start),before,replacement) != true { render(text,force:true) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; render(text) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, ReviewService.safeURL(url.absoluteString) != nil { NSWorkspace.shared.open(url); decisionHandler(.cancel); return }
        if let url = navigationAction.request.url, url.isFileURL, let root = Bundle.main.resourceURL, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
}

final class MarginWindowController: NSWindowController, NSTextViewDelegate {
    unowned let marginDocument: MarginDocument
    let panes = [MarginPane(kind:0),MarginPane(kind:1)]
    let split = NSSplitView()
    let sharedTextStorage = NSTextStorage()
    var pendingRender: DispatchWorkItem?
    let mode = NSSegmentedControl(labels:["원문 편집","미리보기","나란히 보기"],trackingMode:.selectOne,target:nil,action:nil)
    let status = marginLabel("자동저장 켜짐",size:11)
    let stats = marginLabel("",size:11)
    let auto = NSButton(checkboxWithTitle:"AI 자동 교정",target:nil,action:nil)
    let proposalArea = NSStackView()
    let proposalTitle = marginLabel("",size:13,color:.labelColor)
    let proposalText = NSTextView()
    let apply = NSButton(title:"적용  ⇥ Tab",target:nil,action:nil)
    let ghost = NSBox()
    let ghostText = marginLabel("",size:12,color:.systemGreen)
    var activeEditor: NSTextView
    var proposal: ReviewProposal?
    var pendingReview: DispatchWorkItem?
    var reviewTask: Task<Void,Never>?
    var reviewToken = UUID()
    var changingSources = false
    var accepting = false
    var settingsWindow: MarginSettingsController?
    var historyWindow: MarginHistoryController?

    init(document: MarginDocument) {
        marginDocument = document
        activeEditor = panes[0].editor
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1220,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.minSize = NSSize(width:800,height:560)
        window.title = "Margin"; window.titlebarAppearsTransparent = true
        window.isRestorable = false
        super.init(window:window)
        window.center()
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([root.topAnchor.constraint(equalTo:(window.contentLayoutGuide as! NSLayoutGuide).topAnchor),root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
        let header = NSStackView()
        header.orientation = .horizontal; header.spacing = 10; header.edgeInsets = NSEdgeInsets(top:10,left:18,bottom:10,right:18)
        let brand = marginLabel("margin",size:21,color:.labelColor); brand.font = .systemFont(ofSize:21,weight:.semibold)
        header.addArrangedSubview(brand)
        header.addArrangedSubview(marginButton("열기",symbol:"folder",target:self,action:#selector(openFile)))
        header.addArrangedSubview(marginButton("저장",symbol:"square.and.arrow.down",target:self,action:#selector(saveFile)))
        header.addArrangedSubview(marginButton("파일 다시 읽기",symbol:"arrow.clockwise",target:self,action:#selector(reopenOriginal)))
        header.addArrangedSubview(NSView())
        mode.selectedSegment = 2; mode.target = self; mode.action = #selector(viewModeChanged)
        header.addArrangedSubview(mode)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(marginButton("버전 기록",symbol:"clock.arrow.circlepath",target:self,action:#selector(showHistory)))
        header.addArrangedSubview(marginButton("AI 설정",symbol:"slider.horizontal.3",target:self,action:#selector(showSettings)))
        root.addArrangedSubview(header)
        split.isVertical = true; split.dividerStyle = .thin
        for pane in panes {
            split.addSubview(pane)
            pane.editor.layoutManager?.replaceTextStorage(sharedTextStorage)
            pane.editor.delegate = self
            pane.onKindChanged = { [weak self] in self?.updateGhost() }
            pane.onPreviewError = { [weak self] message in self?.setStatus("미리보기 오류 · " + message) }
            pane.onPreviewEdit = { [weak self, weak pane] range, before, replacement in
                guard let self, let pane else { return false }
                return self.applyPreviewEdit(pane,range:range,before:before,replacement:replacement)
            }
        }
        root.addArrangedSubview(split)
        split.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive = true
        proposalArea.orientation = .vertical; proposalArea.alignment = .leading; proposalArea.spacing = 7
        proposalArea.edgeInsets = NSEdgeInsets(top:12,left:24,bottom:12,right:24)
        let proposalHeader = NSStackView(views:[proposalTitle,NSView()])
        let reject = NSButton(title:"취소  Esc",target:self,action:#selector(rejectProposal)); reject.bezelStyle = .rounded
        apply.bezelStyle = .rounded; apply.target = self; apply.action = #selector(acceptProposal)
        proposalHeader.addArrangedSubview(reject); proposalHeader.addArrangedSubview(apply)
        proposalArea.addArrangedSubview(proposalHeader)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        proposalText.isEditable = false; proposalText.isRichText = true; proposalText.isSelectable = true
        proposalText.font = .systemFont(ofSize:12); proposalText.drawsBackground = false
        proposalText.isHorizontallyResizable = false; proposalText.textContainer?.widthTracksTextView = true
        scroll.documentView = proposalText
        proposalArea.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant:135).isActive = true
        root.addArrangedSubview(proposalArea); proposalArea.isHidden = true
        let footer = NSStackView(views:[status,NSView(),stats,auto,marginButton("이 문단 AI 교정",symbol:"sparkles",target:self,action:#selector(manualReview))])
        footer.orientation = .horizontal; footer.spacing = 14; footer.edgeInsets = NSEdgeInsets(top:8,left:20,bottom:8,right:20)
        auto.target = self; auto.action = #selector(toggleAuto)
        refreshAuto()
        root.addArrangedSubview(footer)
        for view in [header,split,proposalArea,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        proposalHeader.widthAnchor.constraint(equalTo:proposalArea.widthAnchor,constant:-48).isActive = true
        scroll.widthAnchor.constraint(equalTo:proposalHeader.widthAnchor).isActive = true
        status.lineBreakMode = .byTruncatingTail; status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        ghost.boxType = .custom; ghost.borderWidth = 0; ghost.cornerRadius = 5
        ghost.fillColor = NSColor.systemGreen.withAlphaComponent(0.09)
        ghost.contentView?.addSubview(ghostText); ghost.isHidden = true
        ghostText.lineBreakMode = .byTruncatingTail
        refreshSources()
        NotificationCenter.default.addObserver(self,selector:#selector(settingsChanged),name:Notification.Name("MarginAISettingsChanged"),object:nil)
        split.adjustSubviews()
        split.setPosition(600,ofDividerAt:0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // The divider set during init is discarded by the first on-screen layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.layoutIfNeeded(); self.setMode(self.mode.selectedSegment)
        }
    }
    var aiConnected: Bool { CredentialStore.exists(ReviewSettings.load().provider) }
    private var wantsAuto = false
    func refreshAuto() {
        let stored = UserDefaults.standard.object(forKey:"ai.auto") == nil || UserDefaults.standard.bool(forKey:"ai.auto")
        auto.state = aiConnected && stored ? .on : .off
    }
    @objc func settingsChanged() {
        cancelReview()
        if wantsAuto && aiConnected { UserDefaults.standard.set(true,forKey:"ai.auto") }
        wantsAuto = false
        refreshAuto()
        if auto.state == .on { scheduleReview() }
    }
    func setStatus(_ value: String) { status.stringValue = value; status.toolTip = value }
    func refreshSources(except origin: NSTextView? = nil) {
        changingSources = true
        if sharedTextStorage.string != marginDocument.source {
            sharedTextStorage.setAttributedString(NSAttributedString(string:marginDocument.source,attributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.labelColor]))
            for pane in panes {
                pane.editor.undoManager?.removeAllActions()
                let selection = pane.editor.selectedRange()
                pane.editor.setSelectedRange(NSRange(location:min(selection.location,(marginDocument.source as NSString).length),length:0))
            }
        }
        changingSources = false
        renderPreview(debounce:origin != nil)
        stats.stringValue = "\(marginDocument.source.count.formatted())자 · UTF-8"
    }
    func applyPreviewEdit(_ pane: MarginPane, range: NSRange, before: String, replacement: String) -> Bool {
        let current = marginDocument.source as NSString
        guard NSMaxRange(range) <= current.length, current.substring(with:range) == before, !pane.editor.hasMarkedText(), pane.editor.shouldChangeText(in:range,replacementString:replacement) else { return false }
        sharedTextStorage.replaceCharacters(in:range,with:NSAttributedString(string:replacement,attributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.labelColor]))
        pane.editor.didChangeText()
        return marginDocument.source == sharedTextStorage.string
    }
    func renderPreview(debounce: Bool = false) {
        pendingRender?.cancel()
        for pane in panes { pane.text = marginDocument.source }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for pane in self.panes where !pane.isHidden && pane.selector.selectedSegment == 1 { pane.render(self.marginDocument.source) }
        }
        pendingRender = work
        if debounce { DispatchQueue.main.asyncAfter(deadline:.now() + 0.15,execute:work) } else { work.perform() }
    }
    @objc func viewModeChanged() { setMode(mode.selectedSegment) }
    func setMode(_ value: Int) {
        mode.selectedSegment = value
        panes[0].isHidden = value == 1; panes[1].isHidden = value == 0
        if value == 0 { panes[0].setKind(0) }; if value == 1 { panes[1].setKind(1) }
        split.adjustSubviews()
        if value == 2 { split.setPosition(split.bounds.width / 2,ofDividerAt:0) }
        updateGhost()
    }
    @objc func openFile() { (NSApp.delegate as? MarginAppDelegate)?.openDocument(nil) }
    @objc func saveFile() { marginDocument.save(nil) }
    @objc func reopenOriginal() {
        do { try marginDocument.reopenOriginal(); setStatus("저장된 파일을 다시 불러왔어요. 이전 내용은 버전 기록에 남겨 두었어요.") }
        catch { setStatus(error.localizedDescription) }
    }
    @objc func showSettings() {
        cancelReview()
        settingsWindow = MarginSettingsController(parent:window!) { [weak self] in self?.cancelReview() }
        settingsWindow?.show()
    }
    @objc func showHistory() {
        setStatus("버전 기록을 불러오고 있어요…")
        do { try marginDocument.flush() } catch { setStatus("버전 기록 저장 실패 · " + error.localizedDescription); return }
        let record = marginDocument.record, store = marginDocument.store
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let versions = try store.summaries(record.id)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.historyWindow = MarginHistoryController(document:self.marginDocument,summaries:versions,parent:self.window!)
                    self.historyWindow?.show()
                    self.setStatus("버전 \(versions.count)개")
                }
            } catch { DispatchQueue.main.async { self?.setStatus("버전 기록 읽기 실패 · " + error.localizedDescription) } }
        }
    }
    func textDidChange(_ notification: Notification) {
        guard !changingSources, let editor = notification.object as? NSTextView else { return }
        activeEditor = editor
        marginDocument.source = editor.string
        cancelReview()
        marginDocument.edited(reason:accepting ? "AI 수정안 적용" : "자동저장")
        refreshSources(except:editor)
        if !accepting { scheduleReview() }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !changingSources, let editor = notification.object as? NSTextView else { return }
        activeEditor = editor
        if let proposal, !proposal.applies(to:marginDocument.source,revision:marginDocument.revision,selection:editor.selectedRange()) { cancelReview() }
        updateGhost()
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)), !textView.hasMarkedText() {
            if let proposal, proposal.actionable, proposal.applies(to:marginDocument.source,revision:marginDocument.revision,selection:textView.selectedRange()) { acceptProposal(); return true }
            cancelReview(); return false
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), proposal != nil { cancelReview(); return true }
        return false
    }
    @objc func toggleAuto() {
        guard aiConnected else {
            auto.state = .off; wantsAuto = true
            setStatus("먼저 AI 설정에서 API 키를 등록해 주세요.")
            showSettings(); return
        }
        wantsAuto = false
        UserDefaults.standard.set(auto.state == .on,forKey:"ai.auto"); cancelReview(); if auto.state == .on { scheduleReview() }
    }
    @objc func manualReview() { review() }
    func scheduleReview() {
        pendingReview?.cancel()
        guard auto.state == .on, !activeEditor.hasMarkedText() else { return }
        let work = DispatchWorkItem { [weak self] in self?.review(automatic:true) }
        pendingReview = work
        DispatchQueue.main.asyncAfter(deadline:.now() + 1.2,execute:work)
    }
    func cancelReview() {
        pendingReview?.cancel(); pendingReview = nil
        reviewTask?.cancel(); reviewTask = nil
        reviewToken = UUID(); proposal = nil
        proposalArea.isHidden = true; ghost.isHidden = true
    }
    func review(automatic: Bool = false) {
        guard !activeEditor.hasMarkedText(), let paragraph = MarginParagraph.find(in:marginDocument.source,cursor:activeEditor.selectedRange().location) else { if !automatic { setStatus("교정할 문단에 커서를 두세요.") }; return }
        let settings = ReviewSettings.load()
        guard CredentialStore.exists(settings.provider) else { if !automatic { showSettings() }; return }
        cancelReview()
        let token = reviewToken, revision = marginDocument.revision
        setStatus("AI가 문장·문법·사실을 확인하고 있어요…")
        reviewTask = Task { [weak self] in
            do {
                let provider = settings.provider
                guard let key = await Task.detached(priority:.userInitiated,operation:{ CredentialStore.load(provider) }).value else { throw MarginError.message("키체인에서 API 키를 읽지 못했어요. AI 설정에서 API 키를 다시 저장해 주세요.") }
                let result = try await ReviewService.request(paragraph:paragraph,revision:revision,settings:settings,key:key)
                guard let self, !Task.isCancelled, token == self.reviewToken, result.applies(to:self.marginDocument.source,revision:self.marginDocument.revision,selection:self.activeEditor.selectedRange()) else { return }
                if result.actionable || !result.facts.isEmpty || result.searchStatus == "failed" { self.showProposal(result) }
                else { self.setStatus("검토 결과 · 고칠 부분이 없어요.") }
            } catch {
                guard let self, !Task.isCancelled, token == self.reviewToken else { return }
                self.setStatus("AI 교정 실패 · " + error.localizedDescription)
            }
        }
    }
    func showProposal(_ value: ReviewProposal) {
        proposal = value
        let kind = ["grammar":"문법 교정","wording":"문장 다듬기","fact":"사실 확인","none":"검토 결과"][value.category] ?? "문장 검토"
        proposalTitle.stringValue = "✦ \(kind) · \(value.reason)"
        var details = "원문\n\(value.original)\n\n수정안\n\(value.replacement)"
        for fact in value.facts {
            let label = ["supported":"웹 검색 확인됨","contradicted":"사실 오류 수정","unverified":"근거 미확인"][fact.verdict] ?? "근거 미확인"
            details += "\n\n[\(label)] \(fact.claim)\n\(fact.explanation)"
            for source in fact.sources { details += "\n\(source.title) · \(source.url)" }
        }
        details += "\n\nAI 수정안 · 사실을 고친 부분은 출처를 직접 확인해 주세요."
        let attributed = NSMutableAttributedString(string:details,attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.labelColor])
        if let detector = try? NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in:details,range:NSRange(location:0,length:(details as NSString).length)) {
                if let url = match.url, ReviewService.safeURL(url.absoluteString) != nil { attributed.addAttribute(.link,value:url,range:match.range) }
            }
        }
        proposalText.textStorage?.setAttributedString(attributed)
        apply.isEnabled = value.actionable
        proposalArea.isHidden = false
        updateGhost()
    }
    func updateGhost() {
        guard let proposal, proposal.actionable, !activeEditor.enclosingScrollView!.isHidden, proposal.applies(to:marginDocument.source,revision:marginDocument.revision,selection:activeEditor.selectedRange()), let manager = activeEditor.layoutManager, let container = activeEditor.textContainer else { ghost.isHidden = true; return }
        if ghost.superview !== activeEditor { ghost.removeFromSuperview(); activeEditor.addSubview(ghost) }
        let range = activeEditor.selectedRange()
        let glyph = manager.glyphRange(forCharacterRange:NSRange(location:range.location,length:0),actualCharacterRange:nil)
        let rect = manager.boundingRect(forGlyphRange:glyph,in:container)
        let width = max(200,activeEditor.visibleRect.width - 56)
        ghost.frame = NSRect(x:activeEditor.visibleRect.minX + 26,y:rect.maxY + activeEditor.textContainerInset.height + 8,width:width,height:33)
        ghostText.frame = NSRect(x:10,y:8,width:width - 20,height:18)
        ghostText.stringValue = "✦  \(proposal.replacement.replacingOccurrences(of:"\n",with:" "))     ⇥ Tab"
        ghost.isHidden = false
    }
    @objc func acceptProposal() {
        guard let proposal, proposal.actionable, proposal.applies(to:marginDocument.source,revision:marginDocument.revision,selection:activeEditor.selectedRange()) else { cancelReview(); return }
        accepting = true
        window?.makeFirstResponder(activeEditor)
        activeEditor.insertText(proposal.replacement,replacementRange:proposal.range)
        accepting = false
        cancelReview()
    }
    @objc func rejectProposal() { cancelReview() }
}
