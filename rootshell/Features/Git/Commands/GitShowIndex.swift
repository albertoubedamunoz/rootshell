#if !targetEnvironment(macCatalyst)

import Foundation

/// `git show-index [<indexfile>]` — read a pack index file and list entries.
enum GitShowIndex: GitSubcommand {
    static var helpText: String {
        "usage: git show-index < <packindex-file>\r\n\r\n    Show packed archive index\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Parse args — expect a filename
        var indexPath: String?

        for arg in args {
            if !arg.hasPrefix("-") {
                indexPath = arg
            }
        }

        guard let indexPath else {
            output("usage: git show-index <indexfile>\r\n")
            output("\r\n")
            output("Reads a .idx file and lists: offset hash\r\n")
            return 1
        }

        guard FileManager.default.fileExists(atPath: indexPath) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: cannot open '\(indexPath)'\r\n"))
            return 128
        }

        // Parse the .idx file using raw format parsing
        // Pack index v2 format:
        //   - 4-byte magic: \377tOc
        //   - 4-byte version: 2
        //   - 256 * 4-byte fanout table
        //   - N * 20-byte SHA1 hashes
        //   - N * 4-byte CRC32
        //   - N * 4-byte offsets (or 8-byte for large packs)

        guard let fileData = FileManager.default.contents(atPath: indexPath) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: failed to read '\(indexPath)'\r\n"))
            return 128
        }

        guard fileData.count >= 1032 else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: index file too small\r\n"))
            return 128
        }

        return fileData.withUnsafeBytes { rawBuf -> Int32 in
            let ptr = rawBuf.baseAddress!

            // Check magic and version
            let magic = ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let version = UInt32(bigEndian: ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self))

            // Magic: 0xff744f63 ("\377tOc")
            let expectedMagic = UInt32(0xff744f63)
            guard UInt32(bigEndian: magic) == expectedMagic, version == 2 else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: not a valid pack index v2 file\r\n"))
                return 128
            }

            // Fanout table: 256 entries of 4 bytes each, starting at offset 8
            let fanoutBase = 8
            let totalObjects = UInt32(bigEndian: ptr.loadUnaligned(fromByteOffset: fanoutBase + 255 * 4, as: UInt32.self))

            let objectCount = Int(totalObjects)

            // SHA1 table starts after fanout
            let sha1Base = fanoutBase + 256 * 4  // 1032
            // CRC32 table starts after SHA1s
            let crcBase = sha1Base + objectCount * 20
            // Offset table starts after CRC32s
            let offsetBase = crcBase + objectCount * 4

            // Verify we have enough data
            let minSize = offsetBase + objectCount * 4
            guard fileData.count >= minSize else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: index file truncated\r\n"))
                return 128
            }

            var out = GitOutput(write: output)

            for i in 0..<objectCount {
                // Read offset (4 bytes, big-endian)
                let offset = UInt32(bigEndian: ptr.loadUnaligned(fromByteOffset: offsetBase + i * 4, as: UInt32.self))

                // Read SHA1 (20 bytes)
                let sha1Offset = sha1Base + i * 20
                var hexStr = ""
                for j in 0..<20 {
                    let byte = ptr.load(fromByteOffset: sha1Offset + j, as: UInt8.self)
                    hexStr += String(format: "%02x", byte)
                }

                out.raw(GitStyle.fg(GitStyle.dimColor, String(format: "%8d", offset)))
                out.raw(" ")
                out.raw(GitStyle.fg(GitStyle.hash, hexStr))
                out.line()
            }

            out.flush()
            return 0
        }
    }
}

#endif
