import Foundation

public enum FTPCommandVerb: Equatable, Sendable {
    case user
    case pass
    case pwd
    case cwd
    case cdup
    case quit
    case syst
    case type
    case noop
    case feat
    case pasv
    case epsv
    case port
    case list
    case nlst
    case mlsd
    case mlst
    case retr
    case stor
    case dele
    case mkd
    case rmd
    case rnfr
    case rnto
    case size
    case mdtm
    case unknown(String)
}

public struct FTPCommand: Equatable, Sendable {
    public let verb: FTPCommandVerb
    public let argument: String?
}

public enum FTPCommandParser {
    public enum ParseError: Error, Equatable {
        case emptyCommand
    }

    public static func parse(_ line: String) throws -> FTPCommand {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError.emptyCommand
        }

        let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" })
        let verbText: String
        let argument: String?

        if let firstSpace {
            verbText = String(trimmed[..<firstSpace])
            let tail = trimmed[firstSpace...].drop(while: { $0 == " " || $0 == "\t" })
            argument = tail.isEmpty ? nil : String(tail)
        } else {
            verbText = trimmed
            argument = nil
        }

        return FTPCommand(verb: parseVerb(verbText), argument: argument)
    }

    private static func parseVerb(_ text: String) -> FTPCommandVerb {
        switch text.uppercased() {
        case "USER": .user
        case "PASS": .pass
        case "PWD", "XPWD": .pwd
        case "CWD": .cwd
        case "CDUP": .cdup
        case "QUIT": .quit
        case "SYST": .syst
        case "TYPE": .type
        case "NOOP": .noop
        case "FEAT": .feat
        case "PASV": .pasv
        case "EPSV": .epsv
        case "PORT": .port
        case "LIST": .list
        case "NLST": .nlst
        case "MLSD": .mlsd
        case "MLST": .mlst
        case "RETR": .retr
        case "STOR": .stor
        case "DELE": .dele
        case "MKD": .mkd
        case "RMD": .rmd
        case "RNFR": .rnfr
        case "RNTO": .rnto
        case "SIZE": .size
        case "MDTM": .mdtm
        default: .unknown(text.uppercased())
        }
    }
}
