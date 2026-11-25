import AppKit

final class MarginSettingsController: NSWindowController {
    let parent: NSWindow
    let provider = NSPopUpButton()
    let model = NSPopUpButton()
    static let suggestions = ["gateway":["anthropic/claude-sonnet-5.5","anthropic/claude-opus-5.5","anthropic/claude-fable-5.2","anthropic/claude-haiku-5.5"],"claude":["claude-sonnet-5-5","claude-opus-5-5","claude-fable-5-2","claude-haiku-5-5"]]
    private var gatewayModels: [String] = []
    let key = NSSecureTextField()
    let facts = NSButton(checkboxWithTitle:"웹 검색으로 사실 여부까지 확인",target:nil,action:nil)
    let status = marginLabel("",size:11)
    let completion: () -> Void
    init(parent: NSWindow, completion: @escaping () -> Void) {
        self.parent = parent; self.completion = completion
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:460,height:385),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title = "AI 설정"
        super.init(window:panel)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top:24,left:24,bottom:24,right:24)
        provider.addItems(withTitles:["Vercel AI Gateway","Claude API"])
        provider.target = self; provider.action = #selector(changedProvider)
        key.placeholderString = "새 API 키 입력 · 비워 두면 기존 키를 그대로 써요"
        let settings = ReviewSettings.load()
        provider.selectItem(at:settings.provider == "claude" ? 1 : 0); reloadModels(select:settings.model); facts.state = settings.facts ? .on : .off
        for view in [marginLabel("AI 서비스"),provider,marginLabel("AI 모델"),model,marginLabel("API 키 (macOS 키체인에 안전하게 보관)"),key,facts,status] { stack.addArrangedSubview(view) }
        let note = NSTextField(wrappingLabelWithString:"검토할 문단만 선택한 AI 서비스로 전송해요. 웹 검색 결과의 해석은 AI가 수행해요.")
        note.font = .systemFont(ofSize:11); note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        let actions = NSStackView(views:[NSView(),NSButton(title:"취소",target:self,action:#selector(cancel)),NSButton(title:"저장",target:self,action:#selector(save))]); actions.spacing = 8
        stack.addArrangedSubview(actions)
        panel.contentView = stack
        for view in [provider,model,key,note,actions] { view.widthAnchor.constraint(equalToConstant:412).isActive = true }
        changedProviderStatus()
        if (NSApp.delegate as? MarginAppDelegate)?.uiCheck != true { fetchGatewayModels() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var providerID: String { provider.indexOfSelectedItem == 1 ? "claude" : "gateway" }
    @objc func changedProvider() {
        reloadModels(select:UserDefaults.standard.string(forKey:"ai.model." + providerID) ?? Self.suggestions[providerID]![0])
        key.stringValue = ""; changedProviderStatus()
    }
    func reloadModels(select: String) {
        var names = Self.suggestions[providerID]!
        let extra = providerID == "gateway" ? gatewayModels.filter { !names.contains($0) } : []
        if !names.contains(select) && !extra.contains(select) { names.insert(select,at:0) }
        model.removeAllItems(); model.addItems(withTitles:names)
        if !extra.isEmpty { model.menu?.addItem(.separator()); model.addItems(withTitles:extra) }
        model.selectItem(withTitle:select)
    }
    // The gateway publishes its model list without credentials; the built-in suggestions stay when it is unreachable.
    func fetchGatewayModels() {
        guard let url = URL(string:"https://ai-gateway.vercel.sh/v1/models") else { return }
        URLSession.shared.dataTask(with:url) { [weak self] data,_,_ in
            guard let data, let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let items = root["data"] as? [[String:Any]] else { return }
            let names = items.compactMap { item -> String? in
                guard item["type"] as? String == "language", let id = item["id"] as? String, !id.hasSuffix("-batch"), id.range(of:"^[A-Za-z0-9_./:-]{1,150}$",options:.regularExpression) != nil else { return nil }
                return id
            }.sorted()
            DispatchQueue.main.async {
                guard let self, !names.isEmpty else { return }
                self.gatewayModels = names
                if self.providerID == "gateway" { self.reloadModels(select:self.model.titleOfSelectedItem ?? Self.suggestions["gateway"]![0]) }
            }
        }.resume()
    }
    func changedProviderStatus() {
        status.stringValue = CredentialStore.exists(providerID) ? "키체인에 API 키가 저장되어 있어요." : "저장된 API 키가 없어요."
    }
    func show() { parent.beginSheet(window!) }
    @objc func cancel() { key.stringValue = ""; parent.endSheet(window!); window?.close() }
    @objc func save() {
        do {
            guard let chosen = model.titleOfSelectedItem, chosen.range(of:"^[A-Za-z0-9_./:-]{1,150}$",options:.regularExpression) != nil else { throw MarginError.message("AI 모델을 선택해 주세요.") }
            if !key.stringValue.isEmpty { try CredentialStore.save(key.stringValue,provider:providerID) }
            ReviewSettings(provider:providerID,model:chosen,facts:facts.state == .on).save()
            key.stringValue = ""
            NotificationCenter.default.post(name:Notification.Name("MarginAISettingsChanged"),object:nil)
            completion(); parent.endSheet(window!); window?.close()
        } catch { status.stringValue = error.localizedDescription }
    }
}

final class MarginHistoryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    unowned let marginDocument: MarginDocument
    let parent: NSWindow
    let versions: [VersionSummary]
    var selectedVersion: SavedVersion?
    let table = NSTableView()
    let pane = MarginPane(kind:1)
    let descriptionLabel = marginLabel("",size:11)
    let restoreButton = NSButton(title:"이 버전으로 되돌리기",target:nil,action:nil)

    init(document: MarginDocument, summaries: [VersionSummary], parent: NSWindow) {
        self.marginDocument = document; self.versions = summaries; self.parent = parent
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:950,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title = "버전 기록 · " + document.record.name
        super.init(window:panel)
        panel.minSize = NSSize(width:750,height:500)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top:16,left:16,bottom:16,right:16)
        root.addArrangedSubview(marginLabel("자동저장 · 수동 저장 · AI 적용 · 복원 기록",size:13,color:.labelColor))
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("version")); column.title = "저장 시각과 기록 이유"; column.width = 230
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 52
        table.delegate = self; table.dataSource = self
        table.reloadData()
        table.allowsEmptySelection = false
        scroll.documentView = table
        split.addSubview(scroll); split.addSubview(pane)
        pane.editor.isEditable = false
        root.addArrangedSubview(split)
        root.addArrangedSubview(descriptionLabel)
        let close = NSButton(title:"닫기",target:self,action:#selector(closeSheet)); close.bezelStyle = .rounded
        restoreButton.target = self; restoreButton.action = #selector(restore); restoreButton.bezelStyle = .rounded
        let actions = NSStackView(views:[marginLabel("되돌리기 전의 현재 내용도 새 버전으로 남겨 두어요.",size:11),NSView(),close,restoreButton]); actions.spacing = 10
        root.addArrangedSubview(actions)
        panel.contentView = root
        split.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-32).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant:420).isActive = true
        actions.widthAnchor.constraint(equalTo:split.widthAnchor).isActive = true
        split.setPosition(250,ofDividerAt:0)
        if !versions.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); selectVersion() }
        else { restoreButton.isEnabled = false }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    convenience init(document: MarginDocument, versions: [SavedVersion], parent: NSWindow) {
        self.init(document:document,summaries:versions.map(VersionSummary.init),parent:parent)
    }
    func show() { parent.beginSheet(window!) }
    func numberOfRows(in tableView: NSTableView) -> Int { versions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let version = versions[row]
        let label = NSTextField(wrappingLabelWithString:version.createdAt.formatted(date:.abbreviated,time:.standard) + "\n" + version.reason)
        label.font = .systemFont(ofSize:11); label.maximumNumberOfLines = 2
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectVersion() }
    func selectVersion() {
        guard versions.indices.contains(table.selectedRow) else { return }
        do {
            let version = try marginDocument.store.version(marginDocument.record.id,versions[table.selectedRow].id)
            selectedVersion = version; restoreButton.isEnabled = true
            pane.editor.string = version.text; pane.render(version.text)
            descriptionLabel.stringValue = "\(version.createdAt.formatted()) · \(version.reason) · \(version.text.count.formatted())자"
        } catch {
            selectedVersion = nil; restoreButton.isEnabled = false
            descriptionLabel.stringValue = "이 버전을 불러오지 못했어요. 다른 버전은 열 수 있어요."
        }
    }
    @objc func closeSheet() { parent.endSheet(window!); window?.close() }
    @objc func restore() {
        guard let selectedVersion else { return }
        restoreButton.isEnabled = false
        do { try marginDocument.restore(selectedVersion); closeSheet() }
        catch { descriptionLabel.stringValue = "버전 복원 실패 · " + error.localizedDescription; restoreButton.isEnabled = true }
    }
}
