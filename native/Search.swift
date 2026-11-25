import AppKit

struct SearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

struct SearchHit: Equatable {
    let path: String
    let line: Int
    let range: NSRange
    let preview: String
}

enum WorkspaceSearch {
    static let maxHits = 5000

    static func pattern(_ query: String, _ options: SearchOptions) throws -> NSRegularExpression {
        var body = options.regex ? query : NSRegularExpression.escapedPattern(for:query)
        if options.wholeWord { body = "\\b(?:" + body + ")\\b" }
        return try NSRegularExpression(pattern:body,options:options.caseSensitive ? [.anchorsMatchLines] : [.caseInsensitive,.anchorsMatchLines])
    }

    /// Ranges index the LF-normalised text the editors hold, so a hit opens at the same offsets.
    static func hits(in text: String, path: String, pattern: NSRegularExpression, limit: Int = maxHits) -> [SearchHit] {
        let ns = text as NSString
        var result: [SearchHit] = []
        var line = 1, scanned = 0
        pattern.enumerateMatches(in:text,range:NSRange(location:0,length:ns.length)) { match, _, stop in
            guard let range = match?.range, range.length > 0 else { return }
            while scanned < range.location {
                let next = ns.range(of:"\n",options:[],range:NSRange(location:scanned,length:range.location - scanned))
                if next.location == NSNotFound { scanned = range.location } else { line += 1; scanned = next.location + 1 }
            }
            let lineRange = ns.lineRange(for:NSRange(location:range.location,length:0))
            let preview = ns.substring(with:lineRange).trimmingCharacters(in:.newlines)
            result.append(SearchHit(path:path,line:line,range:range,preview:String(preview.prefix(240))))
            if result.count >= limit { stop.pointee = true }
        }
        return result
    }

    /// File mask is a regex matched anywhere in the workspace-relative path, case-insensitively; empty means every file.
    static func mask(_ text: String) throws -> NSRegularExpression? {
        text.trimmingCharacters(in:.whitespaces).isEmpty ? nil : try NSRegularExpression(pattern:text.trimmingCharacters(in:.whitespaces),options:[.caseInsensitive])
    }
    static func matches(_ mask: NSRegularExpression?, _ path: String) -> Bool {
        guard let mask else { return true }
        return mask.firstMatch(in:path,range:NSRange(location:0,length:(path as NSString).length)) != nil
    }

    static func run(root: URL, paths: [String], pattern: NSRegularExpression, mask: NSRegularExpression? = nil, cancelled: () -> Bool = { false }) -> (hits: [SearchHit], files: Int, scanned: Int) {
        var all: [SearchHit] = [], files = 0
        var scanned = 0
        for path in paths where WorkspaceRules.safe(path) && !WorkspaceRules.secret(path) && matches(mask,path) {
            scanned += 1
            if cancelled() || all.count >= maxHits { break }
            let url = root.appendingPathComponent(path)
            guard let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= WorkspaceRules.maxBytes,
                  let data = try? Data(contentsOf:url), let decoded = try? DocumentFormat.decode(data) else { continue }
            let found = hits(in:decoded.text,path:path,pattern:pattern,limit:maxHits - all.count)
            if !found.isEmpty { files += 1; all += found }
        }
        return (all,files,scanned)
    }
}

final class SearchResultTable: NSTableView {
    var onOpen: (() -> Void)?
    override func keyDown(with event: NSEvent) { if event.keyCode == 36 || event.keyCode == 76 { onOpen?() } else { super.keyDown(with:event) } }
}

/// Sublime-style "Find in Files" for one workspace window.
final class WorkspaceSearchController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let field = NSSearchField()
    let maskField = NSTextField()
    let caseBox = NSButton(checkboxWithTitle:"대소문자 구분 (Aa)",target:nil,action:nil)
    let wordBox = NSButton(checkboxWithTitle:"단어 단위",target:nil,action:nil)
    let regexBox = NSButton(checkboxWithTitle:"정규식 (.*)",target:nil,action:nil)
    let table = SearchResultTable()
    let summary = marginLabel("검색어를 입력하고 Enter를 누르세요.",size:11)
    private(set) var hits: [SearchHit] = []
    private var generation = 0
    private let root: URL
    private let paths: () -> [String]
    private let open: (SearchHit) -> Void
    var finished: (() -> Void)?

    init(root: URL, paths: @escaping () -> [String], open: @escaping (SearchHit) -> Void) {
        self.root = root; self.paths = paths; self.open = open
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:460),styleMask:[.titled,.closable,.resizable,.utilityWindow],backing:.buffered,defer:false)
        panel.title = "파일에서 찾기 · " + root.lastPathComponent; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = true
        panel.minSize = NSSize(width:480,height:260)
        super.init(window:panel)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        guard let content = window?.contentView else { return }
        field.placeholderString = "찾을 내용"; field.target = self; field.action = #selector(search); field.delegate = self
        field.sendsSearchStringImmediately = false; field.sendsWholeSearchString = true
        for box in [caseBox,wordBox,regexBox] { box.target = self; box.action = #selector(search); box.controlSize = .small }
        caseBox.state = UserDefaults.standard.bool(forKey:"search.case") ? .on : .off
        wordBox.state = UserDefaults.standard.bool(forKey:"search.word") ? .on : .off
        regexBox.state = UserDefaults.standard.bool(forKey:"search.regex") ? .on : .off
        maskField.placeholderString = "파일 마스크 (정규식, 예: \\.(py|md)$ 또는 ^src/)"; maskField.target = self; maskField.action = #selector(search)
        maskField.stringValue = UserDefaults.standard.string(forKey:"search.mask") ?? ""; maskField.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        maskField.toolTip = "폴더 기준 상대 경로에 정규식으로 맞춰 봐요(대소문자 무시). 비워 두면 모든 파일을 찾아요."
        let options = NSStackView(views:[caseBox,wordBox,regexBox,NSView(),summary]); options.orientation = .horizontal; options.spacing = 14
        summary.lineBreakMode = .byTruncatingTail; summary.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("hit")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 20; table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.onOpen = { [weak self] in self?.openSelected() }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        for view in [field,maskField,options,scroll] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo:content.topAnchor,constant:12),field.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:12),field.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-12),
            maskField.topAnchor.constraint(equalTo:field.bottomAnchor,constant:8),maskField.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:12),maskField.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-12),
            options.topAnchor.constraint(equalTo:maskField.bottomAnchor,constant:8),options.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:12),options.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-12),
            scroll.topAnchor.constraint(equalTo:options.bottomAnchor,constant:8),scroll.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:12),scroll.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-12),scroll.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-12)
        ])
    }

    func present(over parent: NSWindow?, query: String?) {
        if let query, !query.isEmpty { field.stringValue = query }
        if let parent, let window, !window.isVisible {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x:frame.midX - window.frame.width / 2,y:frame.midY - window.frame.height / 2))
        }
        showWindow(nil); window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var options: SearchOptions { SearchOptions(caseSensitive:caseBox.state == .on,wholeWord:wordBox.state == .on,regex:regexBox.state == .on) }

    @objc func search() {
        UserDefaults.standard.set(caseBox.state == .on,forKey:"search.case")
        UserDefaults.standard.set(wordBox.state == .on,forKey:"search.word")
        UserDefaults.standard.set(regexBox.state == .on,forKey:"search.regex")
        UserDefaults.standard.set(maskField.stringValue,forKey:"search.mask")
        generation += 1
        let token = generation, query = field.stringValue
        guard !query.isEmpty else { hits = []; table.reloadData(); summary.stringValue = "검색어를 입력하고 Enter를 누르세요."; finished?(); return }
        let pattern: NSRegularExpression
        do { pattern = try WorkspaceSearch.pattern(query,options) } catch {
            hits = []; table.reloadData(); summary.stringValue = "검색 정규식 오류: " + error.localizedDescription; finished?(); return
        }
        let mask: NSRegularExpression?
        do { mask = try WorkspaceSearch.mask(maskField.stringValue) } catch {
            hits = []; table.reloadData(); summary.stringValue = "파일 마스크 정규식 오류: " + error.localizedDescription; finished?(); return
        }
        summary.stringValue = "찾는 중…"
        let root = self.root, paths = self.paths()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = WorkspaceSearch.run(root:root,paths:paths,pattern:pattern,mask:mask) { [weak self] in self.map { $0.generation != token } ?? true }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.hits = result.hits; self.table.reloadData()
                let capped = result.hits.count >= WorkspaceSearch.maxHits ? " (앞의 \(WorkspaceSearch.maxHits)개만 표시)" : ""
                self.summary.stringValue = result.hits.isEmpty ? "\(result.scanned)개 파일에서 찾지 못했어요." : "\(result.scanned)개 중 \(result.files)개 파일에서 \(result.hits.count)개 찾음\(capped) · Enter나 더블클릭으로 열기"
                if !result.hits.isEmpty { self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
                self.finished?()
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)) where !hits.isEmpty:
            window?.makeFirstResponder(table)
            if table.selectedRow < 0 { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(); return true
        default: return false
        }
    }

    @objc func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard hits.indices.contains(row) else { return }
        open(hits[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hit = hits[row]
        let text = NSMutableAttributedString(string:"\(hit.path):\(hit.line)  ",attributes:[.foregroundColor:NSColor.secondaryLabelColor,.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular)])
        text.append(NSAttributedString(string:hit.preview.trimmingCharacters(in:.whitespaces),attributes:[.foregroundColor:NSColor.labelColor,.font:NSFont.monospacedSystemFont(ofSize:11.5,weight:.regular)]))
        let label = NSTextField(labelWithAttributedString:text); label.lineBreakMode = .byTruncatingTail
        return label
    }
}

extension NSTextView {
    static func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem { let item = NSMenuItem(); item.tag = action.rawValue; return item }

    /// ⌘F as in Sublime: a one-line selection becomes the search string before the find bar opens.
    @objc func marginShowFind(_ sender: Any?) {
        let selected = selectedRange()
        if selected.length > 0, !(string as NSString).substring(with:selected).contains("\n") {
            performTextFinderAction(NSTextView.finderItem(.setSearchString))
        }
        performTextFinderAction(NSTextView.finderItem(.showFindInterface))
    }
}
