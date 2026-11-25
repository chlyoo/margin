/**
 Implements:
   - FR-IDE-9: Pseudo-terminal tab: screen model, process on a PTY, view with keyboard, Hangul input, selection and scrollback
 */
import AppKit

struct TermStyle: Equatable {
    /// -1 is the default colour, 0...255 the palette, 0x1000000 | rgb a direct colour.
    var fg: Int32 = -1
    var bg: Int32 = -1
    var bold = false, dim = false, italic = false, underline = false, inverse = false
}

struct TermCell: Equatable {
    var text = " "
    var style = TermStyle()
    /// 2 for a double-width character, 0 for the cell its right half occupies.
    var width: UInt8 = 1
}

/// What an xterm-256color program expects of the screen. Sequence set taken from `infocmp xterm-256color`.
final class TerminalScreen {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var lines: [[TermCell]]
    private(set) var scrollback: [[TermCell]] = []
    private(set) var x = 0, y = 0
    private(set) var alt = false
    private(set) var appCursor = false, cursorVisible = true, bracketedPaste = false, mouseReporting = false
    private(set) var title = ""
    var maxScrollback = 5000
    var onResponse: ((String) -> Void)?
    var onBell: (() -> Void)?

    private var style = TermStyle()
    private var pendingWrap = false
    private var top = 0, bottom: Int
    private var autowrap = true, insertMode = false, originMode = false
    private var saved: (x: Int, y: Int, style: TermStyle, graphics: [Bool], shifted: Bool)?
    private var primary: (lines: [[TermCell]], x: Int, y: Int)?
    private var graphics = [false,false], shifted = false
    private var tabs: Set<Int> = []
    private var lastPrinted: Unicode.Scalar?

    private enum State { case ground, escape, csi, osc, oscEscape, string, stringEscape, charset(Int), skipOne }
    private var state = State.ground
    private var sequence = ""
    private var utf8: [UInt8] = []

    init(cols: Int, rows: Int) {
        self.cols = max(cols,2); self.rows = max(rows,1); bottom = max(rows,1) - 1
        lines = Array(repeating:Array(repeating:TermCell(),count:max(cols,2)),count:max(rows,1))
    }

    private var blank: TermCell { var cell = TermCell(); cell.style.bg = style.bg; return cell }
    private func blankLine() -> [TermCell] { Array(repeating:blank,count:cols) }

    func text(row: Int) -> String { Self.text(lines[row]) }
    static func text(_ line: [TermCell]) -> String {
        var result = ""
        for cell in line where cell.width != 0 { result += cell.text }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }
    var screenText: String { (0..<rows).map { text(row:$0) }.joined(separator:"\n") }

    static func width(_ scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v < 0x300 { return 1 }
        if (0x1160...0x11FF).contains(v) || (0x200B...0x200F).contains(v) || (0xFE00...0xFE0F).contains(v) || v == 0x2060 || v == 0xFEFF || (0xE0100...0xE01EF).contains(v) { return 0 }
        switch scalar.properties.generalCategory { case .nonspacingMark, .enclosingMark: return 0; default: break }
        if (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) || (0x3041...0x33FF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
            || (0xA000...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v) || (0x1F900...0x1F9FF).contains(v) || (0x20000...0x3FFFD).contains(v) { return 2 }
        return 1
    }

    // MARK: Input

    func feed(_ data: Data) {
        for byte in data {
            if utf8.isEmpty, byte < 0x80 { handle(Unicode.Scalar(byte)); continue }
            utf8.append(byte)
            let lead = utf8[0]
            let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            if need == 1 || (utf8.count > 1 && byte & 0xC0 != 0x80) {
                // Not UTF-8: show a replacement and start over with this byte.
                let retry = utf8.count > 1 ? byte : nil
                utf8 = []; handle("\u{FFFD}")
                if let retry { feed(Data([retry])) }
                continue
            }
            if utf8.count == need {
                let scalar = String(decoding:utf8,as:UTF8.self).unicodeScalars.first ?? "\u{FFFD}"
                utf8 = []; handle(scalar)
            }
        }
    }
    func feed(_ text: String) { feed(Data(text.utf8)) }

    private func handle(_ scalar: Unicode.Scalar) {
        let v = scalar.value
        switch state {
        case .ground:
            if v == 0x1B { state = .escape } else if v < 0x20 || v == 0x7F { control(v) } else { put(scalar) }
        case .escape:
            state = .ground
            switch scalar {
            case "[": sequence = ""; state = .csi
            case "]": sequence = ""; state = .osc
            case "P", "_", "^", "X": state = .string
            case "(": state = .charset(0)
            case ")": state = .charset(1)
            case "*", "+", "#", "%", " ": state = .skipOne
            case "7": saveCursor()
            case "8": restoreCursor()
            case "D": lineFeed()
            case "E": x = 0; pendingWrap = false; lineFeed()
            case "M": reverseIndex()
            case "H": tabs.insert(x)
            case "c": reset()
            default: if v == 0x1B { state = .escape } else if v < 0x20 { control(v) }
            }
        case .csi:
            if v == 0x1B { state = .escape } else if v < 0x20 { control(v) }
            else if (0x40...0x7E).contains(v) { state = .ground; csi(sequence,scalar) }
            else if sequence.count < 256 { sequence.unicodeScalars.append(scalar) }
        case .osc:
            if v == 0x07 { state = .ground; osc(sequence) } else if v == 0x1B { state = .oscEscape }
            else if sequence.count < 4096 { sequence.unicodeScalars.append(scalar) }
        case .oscEscape:
            state = .ground; osc(sequence)
            if scalar != "\\" { state = .escape; handle(scalar) }
        case .string:
            if v == 0x1B { state = .stringEscape } else if v == 0x07 { state = .ground }
        case .stringEscape:
            state = scalar == "\\" ? .ground : .string
        case .charset(let index):
            state = .ground; graphics[index] = scalar == "0"
        case .skipOne:
            state = .ground
        }
    }

    private func control(_ v: UInt32) {
        switch v {
        case 0x07: onBell?()
        case 0x08: if pendingWrap { pendingWrap = false } else if x > 0 { x -= 1 }
        case 0x09: pendingWrap = false; x = nextTab(x)
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: x = 0; pendingWrap = false
        case 0x0E: shifted = true
        case 0x0F: shifted = false
        default: break
        }
    }
    private func nextTab(_ from: Int) -> Int {
        var column = from + 1
        while column < cols - 1, !(tabs.isEmpty ? column % 8 == 0 : tabs.contains(column)) { column += 1 }
        return min(column,cols - 1)
    }
    private func previousTab(_ from: Int) -> Int {
        var column = from - 1
        while column > 0, !(tabs.isEmpty ? column % 8 == 0 : tabs.contains(column)) { column -= 1 }
        return max(column,0)
    }

    private static let lineDrawing: [Character:String] = ["`":"◆","a":"▒","f":"°","g":"±","j":"┘","k":"┐","l":"┌","m":"└","n":"┼","o":"⎺","p":"⎻","q":"─","r":"⎼","s":"⎽","t":"├","u":"┤","v":"┴","w":"┬","x":"│","y":"≤","z":"≥","{":"π","|":"≠","}":"£","~":"·"]

    /// A double-width character must never be left half overwritten.
    private func detach(_ column: Int, _ row: Int) {
        guard column >= 0, column < cols else { return }
        if lines[row][column].width == 0, column > 0 { lines[row][column - 1] = blank; lines[row][column] = blank }
        else if lines[row][column].width == 2, column + 1 < cols { lines[row][column + 1] = blank }
    }

    private func put(_ scalar: Unicode.Scalar) {
        let width = Self.width(scalar)
        if width == 0 {
            let column = pendingWrap ? x : x - 1
            guard column >= 0 else { return }
            let target = lines[y][column].width == 0 && column > 0 ? column - 1 : column
            lines[y][target].text.unicodeScalars.append(scalar)
            return
        }
        if pendingWrap, autowrap { x = 0; pendingWrap = false; lineFeed() }
        if width == 2, x == cols - 1 {
            guard autowrap else { return }
            detach(x,y); lines[y][x] = blank; x = 0; lineFeed()
        }
        var text = String(Character(scalar))
        if graphics[shifted ? 1 : 0], let drawn = text.first.flatMap({ Self.lineDrawing[$0] }) { text = drawn }
        if insertMode {
            detach(x,y)
            lines[y].insert(contentsOf:Array(repeating:blank,count:width),at:x); lines[y].removeLast(width)
            if let last = lines[y].last, last.width == 2 { lines[y][cols - 1] = blank }
        }
        detach(x,y); if width == 2 { detach(x + 1,y) }
        lines[y][x] = TermCell(text:text,style:style,width:UInt8(width))
        if width == 2 { lines[y][x + 1] = TermCell(text:"",style:style,width:0) }
        lastPrinted = scalar
        x += width
        if x >= cols { x = cols - 1; pendingWrap = true }
    }

    private func lineFeed() {
        pendingWrap = false
        if y == bottom { scrollUp(1) } else if y < rows - 1 { y += 1 }
    }
    private func reverseIndex() {
        pendingWrap = false
        if y == top { scrollDown(1) } else if y > 0 { y -= 1 }
    }
    private func scrollUp(_ count: Int) {
        for _ in 0..<min(max(count,1),bottom - top + 1) {
            let line = lines.remove(at:top)
            if !alt, top == 0 {
                scrollback.append(line)
                if scrollback.count > maxScrollback { scrollback.removeFirst(scrollback.count - maxScrollback) }
            }
            lines.insert(blankLine(),at:bottom)
        }
    }
    private func scrollDown(_ count: Int) {
        for _ in 0..<min(max(count,1),bottom - top + 1) { lines.remove(at:bottom); lines.insert(blankLine(),at:top) }
    }

    private func saveCursor() { saved = (x,y,style,graphics,shifted) }
    private func restoreCursor() {
        guard let saved else { x = 0; y = 0; return }
        x = min(saved.x,cols - 1); y = min(saved.y,rows - 1); style = saved.style; graphics = saved.graphics; shifted = saved.shifted; pendingWrap = false
    }
    private func reset() {
        let keep = (cols,rows)
        alt = false; primary = nil; scrollback = []; style = TermStyle(); x = 0; y = 0; top = 0; bottom = keep.1 - 1
        autowrap = true; insertMode = false; originMode = false; appCursor = false; cursorVisible = true; bracketedPaste = false; mouseReporting = false
        graphics = [false,false]; shifted = false; tabs = []; saved = nil; pendingWrap = false
        lines = Array(repeating:Array(repeating:TermCell(),count:keep.0),count:keep.1)
    }

    private func osc(_ text: String) {
        if text.hasPrefix("0;") || text.hasPrefix("2;") { title = String(text.dropFirst(2)) }
    }

    private func moveTo(row: Int, column: Int) {
        let low = originMode ? top : 0, high = originMode ? bottom : rows - 1
        y = min(max(row + (originMode ? top : 0),low),high); x = min(max(column,0),cols - 1); pendingWrap = false
    }

    private func csi(_ raw: String, _ final: Unicode.Scalar) {
        let isPrivate = raw.hasPrefix("?"), secondary = raw.hasPrefix(">")
        let body = raw.drop { "?>=<!".contains($0) }
        let intermediate = body.last.map { " !\"$'".contains($0) } == true
        let numbers = body.filter { $0.isNumber || $0 == ";" || $0 == ":" }.split(omittingEmptySubsequences:false,whereSeparator: { $0 == ";" || $0 == ":" }).map { Int($0) ?? 0 }
        func n(_ index: Int, _ fallback: Int = 1) -> Int { index < numbers.count && numbers[index] > 0 ? numbers[index] : fallback }
        if intermediate {
            if final == "p", raw.hasPrefix("!") { let keepAlt = alt; style = TermStyle(); insertMode = false; originMode = false; autowrap = true; cursorVisible = true; top = 0; bottom = rows - 1; alt = keepAlt }
            return
        }
        switch final {
        case "A": y = max(y - n(0),y >= top ? top : 0); pendingWrap = false
        case "B", "e": y = min(y + n(0),y <= bottom ? bottom : rows - 1); pendingWrap = false
        case "C", "a": x = min(x + n(0),cols - 1); pendingWrap = false
        case "D": x = max(x - n(0),0); pendingWrap = false
        case "E": y = min(y + n(0),y <= bottom ? bottom : rows - 1); x = 0; pendingWrap = false
        case "F": y = max(y - n(0),y >= top ? top : 0); x = 0; pendingWrap = false
        case "G", "`": x = min(n(0) - 1,cols - 1); pendingWrap = false
        case "H", "f": moveTo(row:n(0) - 1,column:n(1) - 1)
        case "d": moveTo(row:n(0) - 1,column:x)
        case "I": for _ in 0..<n(0) { x = nextTab(x) }
        case "Z": for _ in 0..<n(0) { x = previousTab(x) }
        case "J":
            let mode = numbers.first ?? 0
            if mode == 0 { eraseLine(from:x,to:cols - 1); if y + 1 < rows { for row in (y + 1)..<rows { lines[row] = blankLine() } } }
            else if mode == 1 { eraseLine(from:0,to:x); for row in 0..<y { lines[row] = blankLine() } }
            else { for row in 0..<rows { lines[row] = blankLine() }; if mode == 3 { scrollback = [] } }
            pendingWrap = false
        case "K":
            let mode = numbers.first ?? 0
            if mode == 0 { eraseLine(from:x,to:cols - 1) } else if mode == 1 { eraseLine(from:0,to:x) } else { eraseLine(from:0,to:cols - 1) }
            pendingWrap = false
        case "L":
            guard y >= top, y <= bottom else { break }
            for _ in 0..<min(n(0),bottom - y + 1) { lines.remove(at:bottom); lines.insert(blankLine(),at:y) }
            x = 0; pendingWrap = false
        case "M":
            guard y >= top, y <= bottom else { break }
            for _ in 0..<min(n(0),bottom - y + 1) { lines.remove(at:y); lines.insert(blankLine(),at:bottom) }
            x = 0; pendingWrap = false
        case "P":
            let count = min(n(0),cols - x)
            detach(x,y); detach(x + count,y)
            lines[y].removeSubrange(x..<(x + count)); lines[y].append(contentsOf:Array(repeating:blank,count:count)); pendingWrap = false
        case "@":
            let count = min(n(0),cols - x)
            detach(x,y)
            lines[y].insert(contentsOf:Array(repeating:blank,count:count),at:x); lines[y].removeLast(count)
            if let last = lines[y].last, last.width == 2 { lines[y][cols - 1] = blank }
            pendingWrap = false
        case "X": eraseLine(from:x,to:min(x + n(0) - 1,cols - 1)); pendingWrap = false
        case "S": scrollUp(n(0))
        case "T": scrollDown(n(0))
        case "b": if let lastPrinted { for _ in 0..<min(n(0),cols * rows) { put(lastPrinted) } }
        case "g": if (numbers.first ?? 0) == 3 { tabs = [] } else { tabs.remove(x) }
        case "r":
            let first = n(0) - 1, last = (numbers.count > 1 && numbers[1] > 0 ? numbers[1] : rows) - 1
            if first < last, last < rows { top = first; bottom = last } else { top = 0; bottom = rows - 1 }
            moveTo(row:0,column:0)
        case "s": saveCursor()
        case "u": restoreCursor()
        case "m": sgr(numbers.isEmpty ? [0] : numbers, colon: body.contains(":"))
        case "h", "l":
            let on = final == "h"
            for mode in numbers { if isPrivate { privateMode(mode,on) } else if mode == 4 { insertMode = on } }
        case "n":
            if (numbers.first ?? 0) == 6 { onResponse?("\u{1B}[\(y - (originMode ? top : 0) + 1);\(x + 1)R") } else if (numbers.first ?? 0) == 5 { onResponse?("\u{1B}[0n") }
        case "c":
            if secondary { onResponse?("\u{1B}[>0;276;0c") } else if !raw.hasPrefix("=") { onResponse?("\u{1B}[?1;2c") }
        default: break
        }
    }

    private func eraseLine(from: Int, to: Int) {
        guard from <= to else { return }
        detach(from,y); detach(to,y)
        for column in from...to { lines[y][column] = blank }
    }

    private func privateMode(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1: appCursor = on
        case 6: originMode = on; moveTo(row:0,column:0)
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 1000, 1002, 1003: mouseReporting = on
        case 2004: bracketedPaste = on
        case 47, 1047: switchScreen(on,clear:mode == 1047)
        case 1048: if on { saveCursor() } else { restoreCursor() }
        case 1049: if on { saveCursor(); switchScreen(true,clear:true) } else { switchScreen(false,clear:false); restoreCursor() }
        default: break
        }
    }
    private func switchScreen(_ toAlt: Bool, clear: Bool) {
        guard toAlt != alt else { return }
        if toAlt {
            primary = (lines,x,y); alt = true
            if clear { lines = Array(repeating:Array(repeating:TermCell(),count:cols),count:rows) }
        } else {
            alt = false
            if let primary { lines = primary.lines; x = min(primary.x,cols - 1); y = min(primary.y,rows - 1) }
            primary = nil
        }
        top = 0; bottom = rows - 1; pendingWrap = false
    }

    private func sgr(_ codes: [Int], colon: Bool) {
        var index = 0
        func colour() -> Int32? {
            guard index + 1 < codes.count else { index = codes.count; return nil }
            if codes[index + 1] == 5, index + 2 < codes.count { let value = Int32(min(max(codes[index + 2],0),255)); index += 2; return value }
            if codes[index + 1] == 2 {
                // The colon form may carry an empty colour-space field before the three components.
                let start = colon && codes.count - index >= 6 ? index + 3 : index + 2
                guard start + 2 < codes.count else { index = codes.count; return nil }
                let value = Int32(0x1000000 | (min(max(codes[start],0),255) << 16) | (min(max(codes[start + 1],0),255) << 8) | min(max(codes[start + 2],0),255))
                index = start + 2; return value
            }
            return nil
        }
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style = TermStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 21, 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.fg = Int32(code - 30)
            case 38: if let value = colour() { style.fg = value }
            case 39: style.fg = -1
            case 40...47: style.bg = Int32(code - 40)
            case 48: if let value = colour() { style.bg = value }
            case 49: style.bg = -1
            case 90...97: style.fg = Int32(code - 90 + 8)
            case 100...107: style.bg = Int32(code - 100 + 8)
            default: break
            }
            index += 1
        }
    }

    // MARK: Size

    func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(newCols,2), newRows = max(newRows,1)
        guard newCols != cols || newRows != rows else { return }
        func fit(_ source: [[TermCell]], keepCursorRow: Int?, history: Bool) -> (lines: [[TermCell]], removedTop: Int) {
            var result = source.map { line -> [TermCell] in
                var line = line
                if line.count > newCols { line.removeLast(line.count - newCols); if line.last?.width == 2 { line[newCols - 1] = TermCell() } }
                else { line.append(contentsOf:Array(repeating:TermCell(),count:newCols - line.count)) }
                return line
            }
            var removed = 0
            while result.count > newRows {
                // Shrinking drops empty lines below the cursor first, then pushes the top into history.
                if let row = keepCursorRow, result.count - 1 > row - removed, Self.text(result[result.count - 1]).isEmpty { result.removeLast(); continue }
                let line = result.removeFirst(); removed += 1
                if history { scrollback.append(line) }
            }
            while result.count < newRows { result.append(Array(repeating:TermCell(),count:newCols)) }
            return (result,removed)
        }
        if alt, let saved = primary {
            let fitted = fit(saved.lines,keepCursorRow:saved.y,history:true)
            primary = (fitted.lines,min(saved.x,newCols - 1),min(max(saved.y - fitted.removedTop,0),newRows - 1))
            lines = fit(lines,keepCursorRow:nil,history:false).lines
            y = min(y,newRows - 1)
        } else {
            let fitted = fit(lines,keepCursorRow:y,history:!alt)
            lines = fitted.lines; y = min(max(y - fitted.removedTop,0),newRows - 1)
        }
        if scrollback.count > maxScrollback { scrollback.removeFirst(scrollback.count - maxScrollback) }
        scrollback = scrollback.map { line in line.count == newCols ? line : (line.count > newCols ? Array(line.prefix(newCols)) : line + Array(repeating:TermCell(),count:newCols - line.count)) }
        cols = newCols; rows = newRows; x = min(x,cols - 1); top = 0; bottom = rows - 1; pendingWrap = false
    }
}

/// A child process whose stdin, stdout and stderr are one pseudo-terminal, in its own session so the terminal is its controlling one.
final class PTYSession {
    private(set) var master: Int32 = -1
    private(set) var pid: pid_t = 0
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label:"com.peterlyoo.Margin.pty")
    private let writer = DispatchQueue(label:"com.peterlyoo.Margin.pty.write")
    private let lock = NSLock()
    private var paused = false
    private var buffered = Data()
    private var scheduled = false
    private var finished = false
    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    var isRunning: Bool { pid > 0 && !finished }

    static let setWindowSize: UInt = 0x80087467
    static let setControllingTerminal: UInt = 0x20007461
    static let trampoline = "--pty-exec"

    /// Runs in the freshly spawned child: arguments are `<self> --pty-exec <program> <argv0> [args...]`.
    static func becomeProgram() -> Never {
        _ = ioctl(0,setControllingTerminal,0)
        let arguments = Array(CommandLine.arguments.dropFirst(3))
        let argv = arguments.map { strdup($0) } + [nil]
        execv(CommandLine.arguments[2],argv)
        fputs("margin: \(CommandLine.arguments[2]): \(String(cString:strerror(errno)))\n",stderr)
        exit(127)
    }

    static func environment(_ extra: [String:String] = [:]) -> [String:String] {
        var result = ProcessInfo.processInfo.environment
        for key in ["NO_COLOR","PAGER","GIT_PAGER","TERM_PROGRAM_VERSION","TERM_SESSION_ID"] { result.removeValue(forKey:key) }
        result["TERM"] = "xterm-256color"; result["COLORTERM"] = "truecolor"; result["TERM_PROGRAM"] = "Margin"
        // A Finder launch has no locale; without one the shell and vim treat Hangul as bytes.
        if result["LC_ALL"] == nil, result["LC_CTYPE"] == nil, result["LANG"] == nil { result["LC_CTYPE"] = "UTF-8" }
        return result.merging(extra) { _, new in new }
    }

    /// Opens the pair and starts the program. Returns the master descriptor and the child's pid.
    static func spawn(executable: String, arguments: [String], directory: URL, environment: [String:String], cols: Int, rows: Int) throws -> (master: Int32, pid: pid_t) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { close(master) }
            throw MarginError.message("터미널 장치를 열지 못했어요 (errno \(errno)).")
        }
        let slavePath = String(cString:name)
        _ = fcntl(master,F_SETFD,FD_CLOEXEC)
        var size = winsize(ws_row:UInt16(max(rows,1)),ws_col:UInt16(max(cols,2)),ws_xpixel:0,ws_ypixel:0)
        _ = ioctl(master,setWindowSize,&size)
        let slave = open(slavePath,O_RDWR | O_NOCTTY)
        if slave >= 0 {
            var attributes = termios()
            if tcgetattr(slave,&attributes) == 0 { attributes.c_iflag |= tcflag_t(IUTF8); _ = tcsetattr(slave,TCSANOW,&attributes) }
            // On macOS the size set through the master before the other end is open is lost.
            _ = ioctl(slave,setWindowSize,&size)
        }
        defer { if slave >= 0 { close(slave) } }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions,0,slavePath,O_RDWR,0)
        posix_spawn_file_actions_adddup2(&actions,0,1)
        posix_spawn_file_actions_adddup2(&actions,0,2)
        posix_spawn_file_actions_addchdir_np(&actions,directory.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for number in 1..<32 where number != SIGKILL && number != SIGSTOP { sigaddset(&defaults,Int32(number)) }
        posix_spawnattr_setsigdefault(&attributes,&defaults)
        posix_spawnattr_setsigmask(&attributes,&mask)
        // SETSID (0x0400) makes the child a session leader, so the terminal it opens as fd 0 becomes its controlling terminal.
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | 0x0400 | POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard let own = Bundle.main.executablePath else { close(master); throw MarginError.message("앱 실행 파일 경로를 알 수 없어요.") }
        let argv = ([own,trampoline,executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid,own,&actions,&attributes,argv,envp)
        guard status == 0 else { close(master); throw MarginError.message("\(executable)을(를) 실행하지 못했어요 (\(String(cString:strerror(status)))).") }
        return (master,pid)
    }

    func start(executable: String, arguments: [String], directory: URL, environment: [String:String], cols: Int, rows: Int) throws {
        signal(SIGPIPE,SIG_IGN)
        let pair = try Self.spawn(executable:executable,arguments:arguments,directory:directory,environment:environment,cols:cols,rows:rows)
        master = pair.master; pid = pair.pid
        let descriptor = master, child = pid
        let reader = DispatchSource.makeReadSource(fileDescriptor:descriptor,queue:queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        source = reader
        reader.resume()
        DispatchQueue.global(qos:.utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(child,&status,0) < 0, errno == EINTR {}
            let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            self?.queue.async {
                guard let self else { return }
                // Whatever the program wrote before it ended is still in the pipe.
                while self.readAvailable() {}
                self.lock.lock(); let resume = self.paused; self.paused = false; self.lock.unlock()
                if resume { self.source?.resume() }
                self.source?.cancel(); self.source = nil
                DispatchQueue.main.async {
                    self.flush(); self.finished = true
                    if self.master >= 0 { close(self.master); self.master = -1 }
                    self.onExit?(code)
                }
            }
        }
    }

    @discardableResult private func readAvailable() -> Bool {
        guard master >= 0 else { return false }
        var ready = pollfd(fd:master,events:Int16(POLLIN),revents:0)
        guard poll(&ready,1,0) > 0, ready.revents & Int16(POLLIN) != 0 else { return false }
        var bytes = [UInt8](repeating:0,count:65536)
        let count = read(master,&bytes,bytes.count)
        guard count > 0 else { return false }
        lock.lock()
        buffered.append(contentsOf:bytes[0..<count])
        let needsSchedule = !scheduled; scheduled = true
        // The screen is updated on the main thread. When it falls behind, reading stops and the program waits, as with any slow terminal.
        let pause = buffered.count > 1_048_576 && !paused && source != nil
        if pause { paused = true }
        lock.unlock()
        if pause { source?.suspend() }
        if needsSchedule { DispatchQueue.main.async { [weak self] in self?.flush() } }
        return true
    }
    private func flush() {
        lock.lock(); let data = buffered; buffered = Data(); scheduled = false; lock.unlock()
        if !data.isEmpty { onData?(data) }
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let resume = self.paused; self.paused = false; self.lock.unlock()
            if resume { self.source?.resume() }
        }
    }

    func write(_ data: Data) {
        guard master >= 0, !finished, !data.isEmpty else { return }
        let descriptor = master
        writer.async {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor,buffer.baseAddress! + offset,buffer.count - offset)
                    if written > 0 { offset += written } else if errno != EINTR && errno != EAGAIN { break }
                }
            }
        }
    }
    func write(_ text: String) { write(Data(text.utf8)) }

    func resize(cols: Int, rows: Int) {
        guard master >= 0 else { return }
        var size = winsize(ws_row:UInt16(max(rows,1)),ws_col:UInt16(max(cols,2)),ws_xpixel:0,ws_ypixel:0)
        _ = ioctl(master,Self.setWindowSize,&size)
    }

    func stop() {
        guard pid > 0, !finished else { return }
        let child = pid
        kill(-child,SIGHUP); kill(child,SIGHUP)
        DispatchQueue.global().asyncAfter(deadline:.now() + 1.5) { [weak self] in
            if self?.finished != true { kill(-child,SIGKILL); kill(child,SIGKILL) }
        }
    }

    /// Runs a program to its end without a run loop, for the checks. `keys` are written once the screen has been quiet for a moment, one entry at a time.
    static func capture(executable: String, arguments: [String], directory: URL, cols: Int = 80, rows: Int = 24, keys: [String] = [], resizeTo: (cols: Int, rows: Int)? = nil, timeout: TimeInterval = 20) throws -> (screen: TerminalScreen, status: Int32, sawAlt: Bool) {
        signal(SIGPIPE,SIG_IGN)
        let pair = try spawn(executable:executable,arguments:arguments,directory:directory,environment:environment(),cols:cols,rows:rows)
        defer { close(pair.master) }
        let screen = TerminalScreen(cols:cols,rows:rows)
        func send(_ text: String) { let bytes = Array(text.utf8); _ = Darwin.write(pair.master,bytes,bytes.count) }
        screen.onResponse = { send($0) }
        var pending = keys, status: Int32 = 0, sawAlt = false, exited = false, quietSince = Date(), resized = resizeTo == nil
        let deadline = Date().addingTimeInterval(timeout)
        var bytes = [UInt8](repeating:0,count:65536)
        while Date() < deadline {
            var ready = pollfd(fd:pair.master,events:Int16(POLLIN),revents:0)
            if poll(&ready,1,50) > 0, ready.revents & Int16(POLLIN) != 0 {
                let count = read(pair.master,&bytes,bytes.count)
                if count > 0 { screen.feed(Data(bytes[0..<count])); sawAlt = sawAlt || screen.alt; quietSince = Date(); continue }
            }
            if exited { break }
            if waitpid(pair.pid,&status,WNOHANG) == pair.pid { exited = true; continue }
            if Date().timeIntervalSince(quietSince) > 0.4 {
                if !resized, let size = resizeTo {
                    resized = true
                    var value = winsize(ws_row:UInt16(size.rows),ws_col:UInt16(size.cols),ws_xpixel:0,ws_ypixel:0)
                    _ = ioctl(pair.master,setWindowSize,&value); screen.resize(cols:size.cols,rows:size.rows); quietSince = Date()
                } else if !pending.isEmpty { send(pending.removeFirst()); quietSince = Date() }
            }
        }
        if !exited { kill(-pair.pid,SIGKILL); kill(pair.pid,SIGKILL); while waitpid(pair.pid,&status,0) < 0, errno == EINTR {}; return (screen,-1,sawAlt) }
        return (screen,(status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F),sawAlt)
    }
}

final class TerminalView: NSView, NSTextInputClient {
    private(set) var screen = TerminalScreen(cols:80,rows:24)
    private(set) var session: PTYSession?
    let directory: URL
    var onActivity: (() -> Void)?
    /// Prompts and `ls` replacements print icon glyphs that only a Nerd Font has; one that is installed is used as the fallback.
    private static func withIcons(_ base: NSFont) -> NSFont {
        guard let family = NSFontManager.shared.availableFontFamilies.first(where: { $0.contains("Nerd Font Mono") }) ?? NSFontManager.shared.availableFontFamilies.first(where: { $0.contains("Nerd Font") }) else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList:[NSFontDescriptor(fontAttributes:[.family:family])]])
        return NSFont(descriptor:descriptor,size:base.pointSize) ?? base
    }
    private let font = TerminalView.withIcons(NSFont.monospacedSystemFont(ofSize:12.5,weight:.regular))
    private let boldFont = TerminalView.withIcons(NSFont.monospacedSystemFont(ofSize:12.5,weight:.semibold))
    private let cell: NSSize
    private let inset: CGFloat = 6
    private var scrollOffset = 0
    private var marked = ""
    private var selection: (start: (line: Int, column: Int), end: (line: Int, column: Int))?
    private var wheel: CGFloat = 0
    private(set) var exitStatus: Int32?

    init(directory: URL) {
        self.directory = directory
        let advance = ("W" as NSString).size(withAttributes:[.font:font]).width
        cell = NSSize(width:advance,height:ceil(font.ascender - font.descender + font.leading) + 2)
        super.init(frame:NSRect(x:0,y:0,width:600,height:240))
        configure()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func configure() {
        screen.onResponse = { [weak self] in self?.session?.write($0) }
        screen.onBell = { NSSound.beep() }
    }

    var isRunning: Bool { session?.isRunning == true }

    /// Starts the person's login shell in the workspace folder.
    func start(executable: String? = nil, arguments: [String]? = nil) {
        guard !isRunning else { return }
        let shell = executable ?? ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath:$0) ? $0 : nil } ?? "/bin/zsh"
        let pty = PTYSession()
        pty.onData = { [weak self] data in
            guard let self else { return }
            self.screen.feed(data); self.needsDisplay = true; self.onActivity?()
        }
        pty.onExit = { [weak self] status in
            guard let self else { return }
            self.exitStatus = status
            self.screen.feed("\r\n\u{1B}[0;2m[프로세스가 끝났어요 (종료 코드 \(status)). Enter를 누르면 셸을 다시 시작해요.]\u{1B}[0m\r\n")
            self.needsDisplay = true; self.onActivity?()
        }
        exitStatus = nil
        do {
            // A leading dash in argv[0] is how a shell is told it is a login shell.
            try pty.start(executable:shell,arguments:arguments ?? ["-" + (shell as NSString).lastPathComponent],directory:directory,environment:PTYSession.environment(),cols:screen.cols,rows:screen.rows)
            session = pty
        } catch { screen.feed("\u{1B}[31m" + error.localizedDescription + "\u{1B}[0m\r\n"); needsDisplay = true }
    }
    func stop() { session?.stop() }
    func send(_ text: String) { scrollOffset = 0; session?.write(text) }

    // MARK: Layout and drawing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let cols = max(Int((newSize.width - inset * 2) / cell.width),20), rows = max(Int((newSize.height - inset) / cell.height),4)
        guard cols != screen.cols || rows != screen.rows else { return }
        screen.resize(cols:cols,rows:rows); session?.resize(cols:cols,rows:rows)
        scrollOffset = min(scrollOffset,screen.scrollback.count); needsDisplay = true
    }

    private static let ansi: [(CGFloat, CGFloat, CGFloat)] = [(0,0,0),(194,54,33),(37,188,36),(173,173,39),(73,46,225),(211,56,211),(51,187,200),(203,204,205),(129,131,131),(252,57,31),(49,231,34),(234,236,35),(88,51,255),(249,53,248),(20,240,240),(233,235,235)]
    static func colour(_ value: Int32) -> NSColor? {
        if value < 0 { return nil }
        if value & 0x1000000 != 0 { return NSColor(srgbRed:CGFloat((value >> 16) & 0xFF) / 255,green:CGFloat((value >> 8) & 0xFF) / 255,blue:CGFloat(value & 0xFF) / 255,alpha:1) }
        if value < 16 { let c = ansi[Int(value)]; return NSColor(srgbRed:c.0 / 255,green:c.1 / 255,blue:c.2 / 255,alpha:1) }
        if value < 232 {
            let index = Int(value) - 16, steps: [CGFloat] = [0,95,135,175,215,255]
            return NSColor(srgbRed:steps[index / 36] / 255,green:steps[(index / 6) % 6] / 255,blue:steps[index % 6] / 255,alpha:1)
        }
        let grey = CGFloat(8 + (Int(value) - 232) * 10) / 255
        return NSColor(srgbRed:grey,green:grey,blue:grey,alpha:1)
    }

    private func line(_ row: Int) -> [TermCell] {
        let index = screen.scrollback.count - scrollOffset + row
        return index < screen.scrollback.count ? screen.scrollback[index] : screen.lines[index - screen.scrollback.count]
    }
    private func selected(_ absolute: Int, _ column: Int) -> Bool {
        guard let selection else { return false }
        var a = selection.start, b = selection.end
        if (a.line,a.column) > (b.line,b.column) { swap(&a,&b) }
        return (absolute,column) >= (a.line,a.column) && (absolute,column) < (b.line,b.column)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor.textBackgroundColor, foreground = NSColor.textColor
        background.setFill(); bounds.fill()
        for row in 0..<screen.rows {
            let cells = line(row), originY = inset + CGFloat(row) * cell.height
            guard originY < dirtyRect.maxY, originY + cell.height > dirtyRect.minY else { continue }
            let absolute = screen.scrollback.count - scrollOffset + row
            var column = 0
            while column < cells.count {
                let first = cells[column]
                if first.width == 0 { column += 1; continue }
                let isSelected = selected(absolute,column)
                // Plain ASCII in one style is drawn as one run; anything else gets its own cell so wide glyphs stay on the grid.
                var end = column + 1, text = first.text
                let simple = first.width == 1 && first.text.utf8.count == 1
                if simple { while end < cells.count, cells[end].style == first.style, cells[end].width == 1, cells[end].text.utf8.count == 1, selected(absolute,end) == isSelected { text += cells[end].text; end += 1 } }
                else if first.width == 2 { end = column + 2 }
                var fg = Self.colour(first.style.fg) ?? foreground, bg = Self.colour(first.style.bg)
                if first.style.inverse { let old = fg; fg = bg ?? background; bg = old }
                if isSelected { bg = NSColor.selectedTextBackgroundColor; fg = NSColor.selectedTextColor }
                if first.style.dim { fg = fg.withAlphaComponent(0.6) }
                let rect = NSRect(x:inset + CGFloat(column) * cell.width,y:originY,width:CGFloat(end - column) * cell.width,height:cell.height)
                if let bg { bg.setFill(); rect.fill() }
                if text.contains(where: { $0 != " " }) || first.style.underline {
                    var attributes: [NSAttributedString.Key:Any] = [.font:first.style.bold ? boldFont : font,.foregroundColor:fg]
                    if first.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if first.style.italic { attributes[.obliqueness] = 0.18 }
                    (text as NSString).draw(at:NSPoint(x:rect.minX,y:originY + 1),withAttributes:attributes)
                }
                column = end
            }
        }
        if scrollOffset == 0, screen.cursorVisible || !marked.isEmpty {
            let rect = NSRect(x:inset + CGFloat(screen.x) * cell.width,y:inset + CGFloat(screen.y) * cell.height,width:cell.width,height:cell.height)
            if !marked.isEmpty {
                let attributes: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:foreground,.underlineStyle:NSUnderlineStyle.single.rawValue,.backgroundColor:background]
                (marked as NSString).draw(at:NSPoint(x:rect.minX,y:rect.minY + 1),withAttributes:attributes)
            } else if window?.firstResponder === self, window?.isKeyWindow == true {
                foreground.withAlphaComponent(0.45).setFill(); rect.fill()
            } else {
                foreground.withAlphaComponent(0.6).setStroke(); NSBezierPath(rect:rect.insetBy(dx:0.5,dy:0.5)).stroke()
            }
        }
    }

    // MARK: Keyboard

    private static let functionKeys: [UInt16:String] = [122:"\u{1B}OP",120:"\u{1B}OQ",99:"\u{1B}OR",118:"\u{1B}OS",96:"\u{1B}[15~",97:"\u{1B}[17~",98:"\u{1B}[18~",100:"\u{1B}[19~",101:"\u{1B}[20~",109:"\u{1B}[21~",103:"\u{1B}[23~",111:"\u{1B}[24~",117:"\u{1B}[3~",116:"\u{1B}[5~",121:"\u{1B}[6~",114:"\u{1B}[2~"]

    private static let usLayout: [UInt16:String] = [0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",31:"o",32:"u",34:"i",35:"p",37:"l",38:"j",40:"k",45:"n",46:"m",33:"[",30:"]",42:"\\",49:" ",27:"-",44:"/"]

    /// The bytes a key sends, or nil when the key is ordinary text for the input method.
    static func bytes(keyCode: UInt16, characters: String?, shift: Bool, control: Bool, option: Bool, appCursor: Bool) -> String? {
        let modifier = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)
        func arrow(_ letter: String) -> String { modifier > 1 ? "\u{1B}[1;\(modifier)\(letter)" : (appCursor ? "\u{1B}O" : "\u{1B}[") + letter }
        switch keyCode {
        case 36, 76: return option ? "\u{1B}\r" : "\r"
        case 48: return shift ? "\u{1B}[Z" : "\t"
        case 51: return option ? "\u{1B}\u{7F}" : "\u{7F}"
        case 53: return "\u{1B}"
        case 126: return arrow("A")
        case 125: return arrow("B")
        case 124: return option && !shift && !control ? "\u{1B}f" : arrow("C")
        case 123: return option && !shift && !control ? "\u{1B}b" : arrow("D")
        case 115: return arrow("H")
        case 119: return arrow("F")
        default: break
        }
        if let sequence = functionKeys[keyCode] { return sequence }
        // With a Hangul input source the key's character is a jamo; Control and Option combinations go by the key's position instead.
        var characters = characters
        if control || option, characters?.unicodeScalars.first?.isASCII != true, let letter = usLayout[keyCode] { characters = letter }
        guard let scalar = characters?.unicodeScalars.first, characters?.unicodeScalars.count == 1 else { return nil }
        if control {
            let v = scalar.value
            switch v {
            case 0x61...0x7A: return String(Unicode.Scalar(v - 0x60)!)
            case 0x41...0x5A: return String(Unicode.Scalar(v - 0x40)!)
            case 0x40, 0x20, 0x32: return "\u{0}"
            case 0x5B, 0x33: return "\u{1B}"
            case 0x5C, 0x34: return "\u{1C}"
            case 0x5D, 0x35: return "\u{1D}"
            case 0x5E, 0x36: return "\u{1E}"
            case 0x5F, 0x2F, 0x37, 0x2D: return "\u{1F}"
            case 0x3F, 0x38: return "\u{7F}"
            default: return nil
            }
        }
        if option, scalar.isASCII, scalar.value >= 0x20 { return "\u{1B}" + String(scalar) }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command) { super.keyDown(with:event); return }
        if !marked.isEmpty { inputContext?.handleEvent(event); return }
        if exitStatus != nil, event.keyCode == 36 { screen = TerminalScreen(cols:screen.cols,rows:screen.rows); configure(); scrollOffset = 0; selection = nil; start(); needsDisplay = true; return }
        if flags.contains(.shift), event.keyCode == 116 || event.keyCode == 121 { scroll(by:event.keyCode == 116 ? screen.rows - 1 : 1 - screen.rows); return }
        if let text = Self.bytes(keyCode:event.keyCode,characters:event.charactersIgnoringModifiers,shift:flags.contains(.shift),control:flags.contains(.control),option:flags.contains(.option),appCursor:screen.appCursor) {
            selection = nil; send(text); return
        }
        inputContext?.handleEvent(event)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = ""; selection = nil; needsDisplay = true
        send(text)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""; needsDisplay = true
    }
    func unmarkText() { marked = ""; needsDisplay = true }
    func selectedRange() -> NSRange { NSRange(location:NSNotFound,length:0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location:NSNotFound,length:0) : NSRange(location:0,length:(marked as NSString).length) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = NSRect(x:inset + CGFloat(screen.x) * cell.width,y:inset + CGFloat(screen.y) * cell.height,width:cell.width,height:cell.height)
        return window?.convertToScreen(convert(rect,to:nil)) ?? rect
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {
        // Reached when the input method hands a key back, for example Return right after a composed syllable.
        switch selector {
        case #selector(insertNewline(_:)): send("\r")
        case #selector(insertTab(_:)): send("\t")
        case #selector(deleteBackward(_:)): send("\u{7F}")
        case #selector(cancelOperation(_:)): send("\u{1B}")
        default: break
        }
    }

    // MARK: Scrolling, selection, clipboard

    private func scroll(by lines: Int) {
        scrollOffset = min(max(scrollOffset + lines,0),screen.scrollback.count); needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        wheel += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cell.height : event.scrollingDeltaY
        let lines = Int(wheel)
        guard lines != 0 else { return }
        wheel -= CGFloat(lines)
        if screen.alt {
            // Full-screen programs have no history of ours; the wheel moves their own view.
            let key = Self.bytes(keyCode:lines > 0 ? 126 : 125,characters:nil,shift:false,control:false,option:false,appCursor:screen.appCursor) ?? ""
            session?.write(String(repeating:key,count:min(abs(lines),20)))
        } else { scroll(by:lines) }
    }
    private func position(_ event: NSEvent) -> (line: Int, column: Int) {
        let point = convert(event.locationInWindow,from:nil)
        let row = min(max(Int((point.y - inset) / cell.height),0),screen.rows - 1)
        let column = min(max(Int((point.x - inset) / cell.width + 0.5),0),screen.cols)
        return (screen.scrollback.count - scrollOffset + row,column)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let at = position(event)
        if event.clickCount == 2 {
            let cells = line(at.line - (screen.scrollback.count - scrollOffset))
            func word(_ index: Int) -> Bool { index >= 0 && index < cells.count && cells[index].text != " " && !cells[index].text.isEmpty || (index >= 0 && index < cells.count && cells[index].width == 0) }
            var low = min(at.column,cells.count - 1), high = low
            guard word(low) else { selection = nil; needsDisplay = true; return }
            while word(low - 1) { low -= 1 }
            while word(high + 1) { high += 1 }
            selection = ((at.line,low),(at.line,high + 1))
        } else { selection = (at,at) }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = selection?.start else { return }
        selection = (start,position(event)); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let selection, selection.start == selection.end { self.selection = nil; needsDisplay = true }
    }

    var selectedText: String? {
        guard let selection else { return nil }
        var a = selection.start, b = selection.end
        if (a.line,a.column) > (b.line,b.column) { swap(&a,&b) }
        let all = screen.scrollback + screen.lines
        var parts: [String] = []
        for index in a.line...min(b.line,all.count - 1) {
            let cells = all[index], from = index == a.line ? min(a.column,cells.count) : 0, to = index == b.line ? min(b.column,cells.count) : cells.count
            parts.append(from < to ? TerminalScreen.text(Array(cells[from..<to])) : "")
        }
        let text = parts.joined(separator:"\n")
        return text.isEmpty ? nil : text
    }
    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string)
    }
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType:.string), !text.isEmpty else { return }
        let body = text.replacingOccurrences(of:"\r\n",with:"\r").replacingOccurrences(of:"\n",with:"\r")
        send(screen.bracketedPaste ? "\u{1B}[200~" + body.replacingOccurrences(of:"\u{1B}",with:"") + "\u{1B}[201~" : body)
    }
    override func selectAll(_ sender: Any?) {
        selection = ((0,0),(screen.scrollback.count + screen.rows - 1,screen.cols)); needsDisplay = true
    }
}
