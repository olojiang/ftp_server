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
