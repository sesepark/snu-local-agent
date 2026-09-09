import Foundation
import Compression

// MARK: - 압축 풀기

/// Raw DEFLATE, which is what both containers below store their bytes in.
///
/// Apple's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) with no zlib wrapper —
/// the name is misleading. HWP 5.x section streams are exactly that; a zip entry
/// with method 8 is too. The two-byte zlib header only shows up on files written
/// by tools that add it, so `zlib(_:)` strips it and calls the same engine.
enum Inflate {
    /// Growing the buffer rather than trusting a declared size: the zip central
    /// directory can lie, and an HWP stream declares nothing at all.
    static func raw(_ data: Data, hint: Int = 0) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data()
        output.reserveCapacity(max(hint, data.count * 4, 64 * 1024))
        // The scratch buffer the decoder writes into each round.
        let chunk = 256 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { destination.deallocate() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw AgentError.processFailed("압축을 풀 준비를 하지 못했습니다.")
        }
        defer { compression_stream_destroy(stream) }

        var status = COMPRESSION_STATUS_OK
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = data.count
            repeat {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = chunk
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 { output.append(destination, count: produced) }
                if status == COMPRESSION_STATUS_ERROR {
                    throw AgentError.processFailed("압축을 푸는 중에 깨진 자료를 만났습니다.")
                }
                // 100 MB of text out of one stream means the input is not what it
                // claims to be. Stop rather than fill memory.
                guard output.count < 100 * 1024 * 1024 else {
                    throw AgentError.processFailed("압축을 푼 내용이 너무 큽니다.")
                }
            } while status == COMPRESSION_STATUS_OK
        }
        return output
    }

    /// The same thing for a stream that carries the two-byte RFC 1950 header.
    static func zlib(_ data: Data) throws -> Data {
        guard data.count > 2, data[data.startIndex] & 0x0F == 8 else { return try raw(data) }
        return try raw(data.dropFirst(2))
    }
}

// MARK: - 바이트 읽기

/// Little-endian reads with the bounds check written once.
///
/// Every format below is a pile of fixed-size fields at computed offsets, and a
/// document that is truncated or simply not what its extension claims will send
/// one of those offsets past the end. Returning `nil` there keeps the parsers
/// free of range arithmetic at every field.
struct ByteReader {
    let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    func u64(_ offset: Int) -> UInt64? {
        guard let low = u32(offset), let high = u32(offset + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }

    func slice(_ offset: Int, _ length: Int) -> [UInt8]? {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else { return nil }
        return Array(bytes[offset ..< offset + length])
    }

    /// UTF-16LE, stopping at the first NUL. Directory entry names are stored
    /// padded to a fixed width, so the declared length includes the terminator.
    func utf16(_ offset: Int, bytes length: Int) -> String? {
        guard let raw = slice(offset, length) else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(length / 2)
        for index in stride(from: 0, to: raw.count - 1, by: 2) {
            let unit = UInt16(raw[index]) | UInt16(raw[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }
}

// MARK: - OLE 복합 문서

/// The Microsoft Compound File container: a FAT filesystem inside one file.
///
/// HWP 5.x is stored in it — `FileHeader`, `DocInfo`, `BodyText/Section0` and
/// friends are streams in a little directory tree. Old `.doc`/`.xls`/`.ppt` use
/// the same container, which is why the format check that follows looks at the
/// signature inside `FileHeader` rather than trusting the outer magic.
struct CompoundFile {
    private let reader: ByteReader
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: [UInt8]
    /// Path (`BodyText/Section0`) to the entry, lower-cased key kept alongside so
    /// a stream can be found regardless of how the writer cased it.
    private(set) var streams: [String: (start: UInt32, size: Int, mini: Bool)] = [:]

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    static func looksLikeCompoundFile(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return [UInt8](data.prefix(8)) == signature
    }

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF

    init(_ data: Data) throws {
        let reader = ByteReader(data)
        guard Self.looksLikeCompoundFile(data) else {
            throw AgentError.processFailed("복합 문서가 아닙니다.")
        }
        guard let sectorShift = reader.u16(30), let miniShift = reader.u16(32),
              sectorShift >= 7, sectorShift <= 12, miniShift >= 2, miniShift < sectorShift
        else { throw AgentError.processFailed("복합 문서의 머리말이 깨져 있습니다.") }
        let sectorSize = 1 << Int(sectorShift)

        // The DIFAT: 109 FAT sector numbers live in the header, the rest in a
        // chain of sectors whose last slot points at the next one.
        var fatSectors: [UInt32] = []
        for index in 0 ..< 109 {
            guard let sector = reader.u32(76 + index * 4), sector != Self.freeSector else { break }
            fatSectors.append(sector)
        }
        var difat = reader.u32(68) ?? Self.endOfChain
        var difatGuard = 0
        let perSector = sectorSize / 4
        while difat != Self.endOfChain, difat != Self.freeSector, difatGuard < 4096 {
            difatGuard += 1
            let base = (Int(difat) + 1) * sectorSize
            for index in 0 ..< (perSector - 1) {
                guard let sector = reader.u32(base + index * 4), sector != Self.freeSector else { continue }
                fatSectors.append(sector)
            }
            difat = reader.u32(base + (perSector - 1) * 4) ?? Self.endOfChain
        }

        var table: [UInt32] = []
        table.reserveCapacity(fatSectors.count * perSector)
        for sector in fatSectors {
            let base = (Int(sector) + 1) * sectorSize
            for index in 0 ..< perSector { table.append(reader.u32(base + index * 4) ?? Self.freeSector) }
        }

        // The directory is itself a stream in the FAT, and its first entry (the
        // root) owns the mini stream that small streams are cut out of.
        let directorySectors = Self.chain(from: reader.u32(48) ?? Self.endOfChain, in: table)
        var directory: [UInt8] = []
        for sector in directorySectors {
            guard let block = reader.slice((Int(sector) + 1) * sectorSize, sectorSize) else { break }
            directory.append(contentsOf: block)
        }
        let entries = ByteReader(directory)

        var miniChain: [UInt8] = []
        var miniFATTable: [UInt32] = []
        if let rootStart = entries.u32(116), let rootSize = entries.u64(120), rootStart != Self.endOfChain {
            for sector in Self.chain(from: rootStart, in: table) {
                guard let block = reader.slice((Int(sector) + 1) * sectorSize, sectorSize) else { break }
                miniChain.append(contentsOf: block)
            }
            if miniChain.count > Int(rootSize) { miniChain.removeLast(miniChain.count - Int(rootSize)) }
            for sector in Self.chain(from: reader.u32(60) ?? Self.endOfChain, in: table) {
                let base = (Int(sector) + 1) * sectorSize
                for index in 0 ..< perSector { miniFATTable.append(reader.u32(base + index * 4) ?? Self.freeSector) }
            }
        }

        self.reader = reader
        self.sectorSize = sectorSize
        miniSectorSize = 1 << Int(miniShift)
        miniCutoff = Int(reader.u32(56) ?? 4096)
        fat = table
        miniStream = miniChain
        miniFAT = miniFATTable

        // Walk the red-black tree of directory entries, carrying the folder path
        // down so `BodyText/Section0` comes out with its full name.
        let entryCount = directory.count / 128
        var visited = Set<Int>()
        var queue: [(index: Int, prefix: String)] = []
        if let rootChild = entries.u32(76), rootChild != Self.freeSector { queue.append((Int(rootChild), "")) }
        while let item = queue.popLast() {
            guard item.index >= 0, item.index < entryCount, visited.insert(item.index).inserted else { continue }
            let base = item.index * 128
            guard let nameLength = entries.u16(base + 64), let type = entries.u8(base + 66) else { continue }
            let name = entries.utf16(base, bytes: min(Int(nameLength), 64)) ?? ""
            let path = item.prefix.isEmpty ? name : "\(item.prefix)/\(name)"
            if let left = entries.u32(base + 68), left != Self.freeSector { queue.append((Int(left), item.prefix)) }
            if let right = entries.u32(base + 72), right != Self.freeSector { queue.append((Int(right), item.prefix)) }
            switch type {
            case 1: // storage: a folder, whose children hang off `child`
                if let child = entries.u32(base + 76), child != Self.freeSector { queue.append((Int(child), path)) }
            case 2: // stream
                guard let start = entries.u32(base + 116), let size = entries.u64(120 + base) else { continue }
                let length = Int(min(size, UInt64(Int.max)))
                streams[path.lowercased()] = (start, length, length < miniCutoff)
            default:
                continue
            }
        }
    }

    private static func chain(from start: UInt32, in table: [UInt32]) -> [UInt32] {
        var sectors: [UInt32] = []
        var sector = start
        // A corrupt FAT can point back into the chain; the visited set is what
        // keeps this from spinning forever on a malformed file.
        var seen = Set<UInt32>()
        while sector != endOfChain, sector != freeSector, sector < UInt32(table.count), seen.insert(sector).inserted {
            sectors.append(sector)
            sector = table[Int(sector)]
        }
        return sectors
    }

    func contains(_ path: String) -> Bool { streams[path.lowercased()] != nil }

    /// Every path in the file, in the original casing-insensitive keys.
    var paths: [String] { streams.keys.sorted() }

    func read(_ path: String) throws -> Data {
        guard let entry = streams[path.lowercased()] else {
            throw AgentError.processFailed("문서 안에서 \(path)을 찾지 못했습니다.")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(entry.size)
        if entry.mini {
            for sector in Self.chain(from: entry.start, in: miniFAT) {
                let base = Int(sector) * miniSectorSize
                guard base + miniSectorSize <= miniStream.count else { break }
                bytes.append(contentsOf: miniStream[base ..< base + miniSectorSize])
            }
        } else {
            for sector in Self.chain(from: entry.start, in: fat) {
                guard let block = reader.slice((Int(sector) + 1) * sectorSize, sectorSize) else { break }
                bytes.append(contentsOf: block)
            }
        }
        if bytes.count > entry.size { bytes.removeLast(bytes.count - entry.size) }
        return Data(bytes)
    }
}

// MARK: - ZIP

/// Just enough of the zip container to read a document out of one.
///
/// HWPX, like ODF and OOXML, is a zip of XML. Reading the central directory
/// rather than scanning for local headers is what makes the entry list reliable:
/// a local header may declare zero sizes and defer them to a trailing descriptor,
/// but the central directory always carries the real numbers.
struct ZipArchive {
    struct Entry {
        let name: String
        let compressed: [UInt8]
        let method: UInt16
        let size: Int
    }

    private var entries: [String: Entry] = [:]
    private(set) var names: [String] = []

    static func looksLikeZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let head = [UInt8](data.prefix(4))
        return head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04
    }

    init(_ data: Data) throws {
        let reader = ByteReader(data)
        // The end-of-central-directory record sits at the tail, after a comment
        // of up to 64 KB, so it has to be searched for backwards.
        var end = -1
        let lowest = max(0, reader.count - 66_000)
        var index = reader.count - 22
        while index >= lowest {
            if reader.u32(index) == 0x0605_4B50 { end = index; break }
            index -= 1
        }
        guard end >= 0, let count = reader.u16(end + 10), let directoryOffset = reader.u32(end + 16) else {
            throw AgentError.processFailed("압축 목록을 읽지 못했습니다.")
        }
        guard directoryOffset != 0xFFFF_FFFF else {
            throw AgentError.processFailed("ZIP64 형식은 아직 읽지 못합니다.")
        }

        var cursor = Int(directoryOffset)
        for _ in 0 ..< Int(count) {
            guard reader.u32(cursor) == 0x0201_4B50,
                  let method = reader.u16(cursor + 10),
                  let compressedSize = reader.u32(cursor + 20),
                  let uncompressedSize = reader.u32(cursor + 24),
                  let nameLength = reader.u16(cursor + 28),
                  let extraLength = reader.u16(cursor + 30),
                  let commentLength = reader.u16(cursor + 32),
                  let localOffset = reader.u32(cursor + 42),
                  let nameBytes = reader.slice(cursor + 46, Int(nameLength))
            else { break }
            let name = String(decoding: nameBytes, as: UTF8.self)

            // The local header repeats the name and extra fields, and its own
            // lengths are the ones that locate the data — they can differ from
            // the central directory's.
            let local = Int(localOffset)
            if reader.u32(local) == 0x0403_4B50,
               let localNameLength = reader.u16(local + 26),
               let localExtraLength = reader.u16(local + 28),
               let payload = reader.slice(
                   local + 30 + Int(localNameLength) + Int(localExtraLength), Int(compressedSize)
               ) {
                let entry = Entry(name: name, compressed: payload, method: method, size: Int(uncompressedSize))
                entries[name] = entry
                names.append(name)
            }
            cursor += 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        guard !names.isEmpty else { throw AgentError.processFailed("압축 안이 비어 있습니다.") }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else {
            throw AgentError.processFailed("압축 안에서 \(name)을 찾지 못했습니다.")
        }
        switch entry.method {
        case 0: return Data(entry.compressed)
        case 8: return try Inflate.raw(Data(entry.compressed), hint: entry.size)
        default: throw AgentError.processFailed("아직 읽지 못하는 압축 방식입니다.")
        }
    }

    func text(_ name: String) throws -> String {
        String(decoding: try read(name), as: UTF8.self)
    }
}
