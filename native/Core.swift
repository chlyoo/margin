import Foundation
import CryptoKit

enum MarginError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

enum MarginHash {
    static func data(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
}

struct DocumentFormat: Codable, Equatable {
    var eol = "\n"
    var bom = false
    static func decode(_ data: Data) throws -> (text: String, format: DocumentFormat) {
        let bom = data.starts(with: [0xef, 0xbb, 0xbf])
        guard let raw = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8) else { throw MarginError.message("UTF-8 형식의 텍스트 파일만 열 수 있어요.") }
        let match = raw.range(of: "\r\n|\r|\n", options: .regularExpression)
        let eol = match.map { String(raw[$0]) } ?? "\n"
        return (raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), DocumentFormat(eol: eol, bom: bom))
    }
    func encode(_ text: String) -> Data { Data(((bom ? "\u{feff}" : "") + text.replacingOccurrences(of: "\n", with: eol)).utf8) }
}

struct DocumentRecord: Codable {
    var id: String
    var path: String?
    var name: String
    var versions: [String]
    var updatedAt: Date
    var summaries: [VersionSummary]? = nil
}

struct VersionSummary: Codable {
    var id: String
    var createdAt: Date
    var reason: String
    var characterCount: Int
    init(_ version: SavedVersion) { id = version.id; createdAt = version.createdAt; reason = version.reason; characterCount = version.text.count }
}

struct SavedVersion: Codable {
    var id: String
    var createdAt: Date
    var reason: String
    var text: String
    var format: DocumentFormat
    var hash: String
}

final class VersionStore {
    let root: URL
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL) throws {
        self.root = root
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func applicationStore() throws -> VersionStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try VersionStore(root: base.appendingPathComponent("com.peterlyoo.Margin", isDirectory: true).appendingPathComponent("Documents", isDirectory: true))
    }

    private func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw MarginError.message("문서 기록 ID가 올바르지 않아요.") }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    func records() throws -> [DocumentRecord] {
        lock.lock(); defer { lock.unlock() }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { try? decoder.decode(DocumentRecord.self, from: Data(contentsOf: $0.appendingPathComponent("record.json"))) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(path: String?, name: String) throws -> DocumentRecord {
        lock.lock(); defer { lock.unlock() }
        if let path, let existing = try records().first(where: { $0.path == path }) { return existing }
        let record = DocumentRecord(id: UUID().uuidString, path: path, name: name, versions: [], updatedAt: Date())
        let dir = try directory(record.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(record).write(to: dir.appendingPathComponent("record.json"), options: .atomic)
        return record
    }

    func currentRecord(_ id: String) throws -> DocumentRecord {
        try decoder.decode(DocumentRecord.self, from: Data(contentsOf: try directory(id).appendingPathComponent("record.json")))
    }

    func version(_ documentID: String, _ versionID: String) throws -> SavedVersion {
        lock.lock(); defer { lock.unlock() }
        guard UUID(uuidString: versionID) != nil else { throw MarginError.message("버전 ID가 올바르지 않아요.") }
        let item = try decoder.decode(SavedVersion.self, from: Data(contentsOf: try directory(documentID).appendingPathComponent(versionID + ".json")))
        guard item.hash == MarginHash.data(item.format.encode(item.text)) else { throw MarginError.message("버전 기록 파일이 손상되어 열 수 없어요.") }
        return item
    }

    func latest(_ documentID: String) throws -> SavedVersion? {
        lock.lock(); defer { lock.unlock() }
        for id in try currentRecord(documentID).versions.reversed() {
            if let readable = try? version(documentID,id) { return readable }
        }
        return nil
    }

    func versions(_ documentID: String) throws -> [SavedVersion] {
        lock.lock(); defer { lock.unlock() }
        return try currentRecord(documentID).versions.reversed().compactMap { try? version(documentID, $0) }
    }

    func summaries(_ documentID: String) throws -> [VersionSummary] {
        lock.lock(); defer { lock.unlock() }
        let record = try currentRecord(documentID)
        if let summaries = record.summaries { return Array(summaries.reversed()) }
        return try versions(documentID).map(VersionSummary.init)
    }

    @discardableResult
    func save(record: DocumentRecord, text: String, format: DocumentFormat, reason: String) throws -> SavedVersion {
        lock.lock(); defer { lock.unlock() }
        let dir = try directory(record.id)
        if !FileManager.default.fileExists(atPath:dir.appendingPathComponent("record.json").path) {
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try encoder.encode(record).write(to:dir.appendingPathComponent("record.json"),options:.atomic)
        }
        var current = try currentRecord(record.id)
        if current.summaries == nil { current.summaries = try versions(record.id).reversed().map(VersionSummary.init) }
        let hash = MarginHash.data(format.encode(text))
        if let last = try latest(record.id), last.hash == hash {
            current.name = record.name; current.path = record.path
            try encoder.encode(current).write(to: try directory(record.id).appendingPathComponent("record.json"), options: .atomic)
            return last
        }
        let snapshot = SavedVersion(id: UUID().uuidString, createdAt: Date(), reason: reason, text: text, format: format, hash: hash)
        // Publish the record pointer only after the immutable snapshot exists.
        try encoder.encode(snapshot).write(to: dir.appendingPathComponent(snapshot.id + ".json"), options: .atomic)
        current.name = record.name; current.path = record.path; current.updatedAt = snapshot.createdAt
        current.versions.append(snapshot.id)
        current.summaries?.append(VersionSummary(snapshot))
        try encoder.encode(current).write(to: dir.appendingPathComponent("record.json"), options: .atomic)
        return snapshot
    }

    func restore(record: DocumentRecord, versionID: String, current: String, format: DocumentFormat) throws -> SavedVersion {
        lock.lock(); defer { lock.unlock() }
        let target = try version(record.id, versionID)
        try save(record: record, text: current, format: format, reason: "복원 전 현재 내용 백업")
        return try save(record: record, text: target.text, format: target.format, reason: "이전 버전으로 복원")
    }
}

enum FileGuard {
    static func validate(_ url: URL, expected: String?) throws {
        guard let expected else { return }
        let current = try? Data(contentsOf: url)
        guard let current, MarginHash.data(current) == expected else { throw MarginError.message("다른 프로그램에서 이 파일을 수정했어요. 덮어쓰지 않도록 자동저장을 멈추고 현재 내용은 버전 기록에 남겨 두었어요. 다른 이름으로 저장하거나 파일을 다시 읽어 오세요.") }
    }
}

struct MarginParagraph {
    let range: NSRange
    let text: String
    static func find(in text: String, cursor: Int) -> MarginParagraph? {
        let source = text as NSString
        let lines = text.components(separatedBy: "\n")
        var offset = 0, target: Int?
        var offsets: [Int] = []
        var fence: (Character, Int)?
        for (index, line) in lines.enumerated() {
            offsets.append(offset)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let first = trimmed.first
            let run = first.map { marker in trimmed.prefix(while: { $0 == marker }).count } ?? 0
            let marker = (first == "`" || first == "~") && run >= 3
            let inside = fence != nil
            if marker, let first {
                if let active = fence {
                    if first == active.0 && run >= active.1 && trimmed.count == run { fence = nil }
                } else { fence = (first, run) }
            }
            let length = (line as NSString).length
            if cursor >= offset && cursor <= offset + length {
                if inside || marker || trimmed.isEmpty || line.hasPrefix("    ") || line.hasPrefix("\t") { return nil }
                target = index; break
            }
            offset += length + 1
        }
        guard let index = target else { return nil }
        var first = index, last = index
        while first > 0 && !lines[first - 1].trimmingCharacters(in: .whitespaces).isEmpty { first -= 1 }
        while last + 1 < lines.count && !lines[last + 1].trimmingCharacters(in: .whitespaces).isEmpty { last += 1 }
        let end = offsets[index] + (lines[index...last].joined(separator: "\n") as NSString).length
        let range = NSRange(location: offsets[first], length: end - offsets[first])
        let value = source.substring(with: range)
        guard range.length <= 6000, !value.contains("```"), !value.contains("~~~") else { return nil }
        return MarginParagraph(range: range, text: value)
    }
}

struct ReviewSource: Codable { var url: String; var title: String }
struct ReviewFact: Codable { var claim: String; var verdict: String; var explanation: String; var sources: [ReviewSource] }
struct ReviewProposal {
    var range: NSRange
    var original: String
    var replacement: String
    var reason: String
    var category: String
    var facts: [ReviewFact]
    var searchStatus: String
    var revision: Int
    var actionable: Bool { original != replacement }
    func applies(to text: String, revision: Int, selection: NSRange) -> Bool {
        let source = text as NSString
        return self.revision == revision && NSMaxRange(range) <= source.length && selection.location >= range.location && NSMaxRange(selection) <= NSMaxRange(range) && source.substring(with: range) == original
    }
}
