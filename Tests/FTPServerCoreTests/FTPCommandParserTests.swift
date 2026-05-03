import Testing
@testable import FTPServerCore

@Suite("FTP command parser")
struct FTPCommandParserTests {
    @Test("parses mixed-case commands and normalizes the verb")
    func parsesMixedCaseCommands() throws {
        let command = try FTPCommandParser.parse("uSeR hunter")

        #expect(command.verb == .user)
        #expect(command.argument == "hunter")
    }

    @Test("parses extended passive mode")
    func parsesExtendedPassiveMode() throws {
        let command = try FTPCommandParser.parse("EPSV")

        #expect(command.verb == .epsv)
        #expect(command.argument == nil)
    }

    @Test("parses machine listings and rename commands")
    func parsesMachineListingsAndRenameCommands() throws {
        #expect(try FTPCommandParser.parse("MLSD").verb == .mlsd)
        #expect(try FTPCommandParser.parse("MLST hello.txt").verb == .mlst)
        #expect(try FTPCommandParser.parse("RNFR old").verb == .rnfr)
        #expect(try FTPCommandParser.parse("RNTO new").verb == .rnto)
        #expect(try FTPCommandParser.parse("REST 42").verb == .rest)
        #expect(try FTPCommandParser.parse("ABOR").verb == .abor)
    }

    @Test("preserves spaces inside command arguments")
    func preservesArgumentSpaces() throws {
        let command = try FTPCommandParser.parse("CWD folder with spaces")

        #expect(command.verb == .cwd)
        #expect(command.argument == "folder with spaces")
    }

    @Test("rejects blank commands")
    func rejectsBlankCommands() {
        #expect(throws: FTPCommandParser.ParseError.emptyCommand) {
            try FTPCommandParser.parse("   ")
        }
    }
}
