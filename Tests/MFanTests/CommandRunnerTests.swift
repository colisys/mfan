import XCTest
@testable import MFan

final class CommandRunnerTests: XCTestCase {
    func testScriptUsesBundledCLIAndEscapesArguments() {
        let script = CommandRunner.authorizationScript(
            cli: URL(fileURLWithPath: "/Applications/My App.app/Contents/MacOS/fanctl"),
            arguments: ["set", "0", "6200", "30"])
        XCTAssertEqual(script, "do shell script \"'/Applications/My App.app/Contents/MacOS/fanctl' 'set' '0' '6200' '30'\" with administrator privileges")
    }

    func testSuccessfulScript() throws {
        try CommandRunner.run(script: "return 1")
    }

    func testBackgroundAuthorizationScriptReturnsImmediately() {
        let script = CommandRunner.authorizationScript(
            cli: URL(fileURLWithPath: "/Applications/MFan.app/Contents/MacOS/fanctl"),
            arguments: ["serve", "/tmp/mfan/control.sock"],
            background: true,
            backgroundLogPath: "/tmp/mfan/control.log"
        )
        XCTAssertEqual(
            script,
            "do shell script \"'/Applications/MFan.app/Contents/MacOS/fanctl' 'serve' '/tmp/mfan/control.sock' </dev/null >>'/tmp/mfan/control.log' 2>&1 &\" with administrator privileges"
        )
    }

    func testScriptErrorIsReported() {
        XCTAssertThrowsError(try CommandRunner.run(script: "error \"test failure\" number 42")) {
            XCTAssertTrue($0.localizedDescription.contains("test failure"))
        }
    }

    func testCancellationIsReported() {
        XCTAssertThrowsError(try CommandRunner.run(script: "error number -128")) {
            XCTAssertTrue($0.localizedDescription.contains("管理员授权已取消"))
        }
    }

    func testCommandsCompleteSeriallyOffMainThread() {
        let runner = CommandRunner()
        let first = expectation(description: "First command")
        let second = expectation(description: "Second command")
        runner.submit(script: "delay 0.2\nreturn 1") { result in
            XCTAssertFalse(Thread.isMainThread)
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            first.fulfill()
        }
        runner.submit(script: "return 2") { result in
            XCTAssertFalse(Thread.isMainThread)
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            second.fulfill()
        }
        wait(for: [first, second], timeout: 10, enforceOrder: true)
    }
}
