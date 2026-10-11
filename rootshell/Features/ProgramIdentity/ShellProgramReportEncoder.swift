//
//  ShellProgramReportEncoder.swift
//  rootshell
//
//  The OSC 7501 records `ShellProgramReports` reads, for the built-in iOS
//  shell to describe the command it runs. scripts/shell-integration-demo.sh
//  (and .fish) sends the same records from any shell that sources it.
//

import Foundation

nonisolated enum ShellProgramReportEncoder {
    /// The title limit is 192 decoded bytes; stay clear of it.
    static let maxCommandLineBytes = 180

    static func commandStarted(commandLine: String) -> String? {
        let words = ProgramNameNormalizer.words(of: commandLine)
        guard let first = words.first,
              let name = ProgramNameNormalizer.normalize(name: first, arguments: words) else { return nil }
        let app = String(name.unicodeScalars.filter(isAppScalar).prefix(32))
        guard !app.isEmpty else { return nil }
        let title = Data(truncated(commandLine, toBytes: maxCommandLineBytes).utf8).base64EncodedString()
        return "\u{1B}]7501;state=working:id=\(ShellProgramReports.commandID):app=\(app):title=\(title)\u{1B}\\"
    }

    static let commandEnded = "\u{1B}]7501;state=clear:id=\(ShellProgramReports.commandID)\u{1B}\\"

    /// `[A-Za-z0-9_.+-]`, the protocol's `app` alphabet.
    private static func isAppScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_.+-".unicodeScalars.contains(scalar))
    }

    /// Cuts on a character boundary; control characters would void the report.
    private static func truncated(_ text: String, toBytes limit: Int) -> String {
        var result = ""
        var bytes = 0
        for character in text where !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            let size = character.utf8.count
            guard bytes + size <= limit else { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}
