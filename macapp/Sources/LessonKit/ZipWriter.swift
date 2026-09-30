import Foundation
import Compression

/// Minimal ZIP writer for the Word export — no third-party dependencies.
///
/// Uses Apple's Compression framework: COMPRESSION_ZLIB emits a raw DEFLATE
/// stream (RFC 1951), which is exactly what ZIP method 8 stores. Document
/// parts are small (a few hundred KB), so everything is built in memory.
public enum ZipWriter {
    /// Build a zip archive from name → content pairs, in the given order.
    public static func archive(parts: [(name: String, content: Data)]) throws -> Data {
        var local: Data = Data()
        var central: Data = Data()
        var entries: [(crc: UInt32, compressedSize: Int, uncompressedSize: Int, offset: Int, name: String)] = []

        for part in parts {
            let crc = crc32(part.content)
            let compressed = try deflate(part.content)
            let nameBytes = Data(part.name.utf8)
            let offset = local.count

            var header = LocalFileHeader()
            header.crc32 = crc.littleEndian
            header.compressedSize = UInt32(compressed.count).littleEndian
            header.uncompressedSize = UInt32(part.content.count).littleEndian
            header.fileNameLength = UInt16(nameBytes.count).littleEndian

            local.append(header.raw)
            local.append(nameBytes)
            local.append(compressed)

            entries.append((crc, compressed.count, part.content.count, offset, part.name))
        }

        for entry in entries {
            var record = CentralDirectoryRecord()
            record.crc32 = entry.crc.littleEndian
            record.compressedSize = UInt32(entry.compressedSize).littleEndian
            record.uncompressedSize = UInt32(entry.uncompressedSize).littleEndian
            record.fileNameLength = UInt16(entry.name.utf8.count).littleEndian
            record.localHeaderOffset = UInt32(entry.offset).littleEndian
            central.append(record.raw)
            central.append(Data(entry.name.utf8))
        }

        var eocd = EndOfCentralDirectory()
        eocd.entryCount = UInt16(entries.count).littleEndian
        eocd.totalEntryCount = UInt16(entries.count).littleEndian
        eocd.centralDirectorySize = UInt32(central.count).littleEndian
        eocd.centralDirectoryOffset = UInt32(local.count).littleEndian

        var out = local
        out.append(central)
        out.append(eocd.raw)
        return out
    }

    /// Raw DEFLATE via Apple Compression. Must be called with the output
    /// capacity trick: dst_capacity unknown up-front, so retry with growing
    /// buffers (docx parts are far below 256 KB in practice; 4x headroom is
    /// plenty and XML compresses ~10x).
    static func deflate(_ input: Data) throws -> Data {
        let bufferSize = max(input.count + input.count / 2, 1024)
        var output = Data(count: bufferSize)
        let result = output.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(
                    outPtr.bindMemory(to: UInt8.self).baseAddress!, bufferSize,
                    inPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard result > 0 else {
            throw NSError(domain: "ZipWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not compress the Word document parts."])
        }
        return output.prefix(result)
    }

    // MARK: - CRC32 (IEEE 802.3, the zip standard)

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - Fixed-layout struct helpers

    /// DOS timestamp fixed at build time is fine for generated documents.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x21 // 1980-01-01

    struct LocalFileHeader {
        var signature: UInt32 = 0x04034b50
        var versionNeeded: UInt16 = 20
        var flags: UInt16 = 0
        var compressionMethod: UInt16 = 8
        var modTime: UInt16 = ZipWriter.dosTime
        var modDate: UInt16 = ZipWriter.dosDate
        var crc32: UInt32 = 0
        var compressedSize: UInt32 = 0
        var uncompressedSize: UInt32 = 0
        var fileNameLength: UInt16 = 0
        var extraLength: UInt16 = 0

        var raw: Data {
            var d = Data()
            d.append_le(signature)                                                 // u32
            d.append_le(versionNeeded, flags, compressionMethod, modTime, modDate) // u16
            d.append_le(crc32, compressedSize, uncompressedSize)                   // u32
            d.append_le(fileNameLength, extraLength)                               // u16
            return d
        }
    }

    struct CentralDirectoryRecord {
        var signature: UInt32 = 0x02014b50
        var versionMadeBy: UInt16 = 20
        var versionNeeded: UInt16 = 20
        var flags: UInt16 = 0
        var compressionMethod: UInt16 = 8
        var modTime: UInt16 = ZipWriter.dosTime
        var modDate: UInt16 = ZipWriter.dosDate
        var crc32: UInt32 = 0
        var compressedSize: UInt32 = 0
        var uncompressedSize: UInt32 = 0
        var fileNameLength: UInt16 = 0
        var extraLength: UInt16 = 0
        var commentLength: UInt16 = 0
        var diskNumberStart: UInt16 = 0
        var internalAttributes: UInt16 = 0
        var externalAttributes: UInt32 = 0
        var localHeaderOffset: UInt32 = 0

        var raw: Data {
            var d = Data()
            d.append_le(signature)                                                 // u32
            d.append_le(versionMadeBy, versionNeeded, flags, compressionMethod, modTime, modDate) // u16
            d.append_le(crc32, compressedSize, uncompressedSize)                   // u32
            d.append_le(fileNameLength, extraLength, commentLength, diskNumberStart, internalAttributes) // u16
            d.append_le(externalAttributes, localHeaderOffset)                     // u32
            return d
        }
    }

    struct EndOfCentralDirectory {
        var signature: UInt32 = 0x06054b50
        var diskNumber: UInt16 = 0
        var diskWithCentralDirectory: UInt16 = 0
        var entryCount: UInt16 = 0
        var totalEntryCount: UInt16 = 0
        var centralDirectorySize: UInt32 = 0
        var centralDirectoryOffset: UInt32 = 0
        var commentLength: UInt16 = 0

        var raw: Data {
            var d = Data()
            d.append_le(signature)                                                 // u32
            d.append_le(diskNumber, diskWithCentralDirectory, entryCount, totalEntryCount) // u16
            d.append_le(centralDirectorySize, centralDirectoryOffset)              // u32
            d.append_le(commentLength)                                             // u16
            return d
        }
    }
}

private extension Data {
    mutating func append_le(_ values: UInt16...) {
        for v in values {
            append(UInt8(v & 0xFF))
            append(UInt8((v >> 8) & 0xFF))
        }
    }

    mutating func append_le(_ values: UInt32...) {
        for v in values {
            append(UInt8(v & 0xFF))
            append(UInt8((v >> 8) & 0xFF))
            append(UInt8((v >> 16) & 0xFF))
            append(UInt8((v >> 24) & 0xFF))
        }
    }
}
