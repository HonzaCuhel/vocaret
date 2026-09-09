import XCTest
import JavaScriptCore
@testable import VocaretCore

final class CompanionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testMemoryRoundTripAndConcurrentEditProtection() throws {
        let store = CompanionStore(directory: directory)
        try store.saveMemory("# Paměť\nPiš česky. 日本語", replacing: "")
        XCTAssertEqual(try store.memory(), "# Paměť\nPiš česky. 日本語")
        try "External edit".write(to: store.memoryURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.saveMemory("overwrite", replacing: "# Paměť\nPiš česky. 日本語"))
        XCTAssertEqual(try store.memory(), "External edit")
        try store.saveMemory("", replacing: "External edit")
        XCTAssertEqual(try store.memory(), "")
    }

    func testHistoryBoundAndClearSurviveRelaunch() throws {
        let store = CompanionStore(directory: directory)
        let messages = (0..<100).map { ConversationMessage(role: "user", text: "Message \($0)") }
        try store.saveHistory(messages)
        XCTAssertEqual(try store.history().count, 80)
        XCTAssertEqual(try store.history().first?.text, "Message 20")
        try store.saveHistory([])
        XCTAssertEqual(try store.history(), [])
    }

    @MainActor func testPromptRetainsPriorTurnsAndLatestRequest() {
        let messages = [ConversationMessage(role: "user", text: "My project is an orchard."),
                        ConversationMessage(role: "assistant", text: "Which fruit?"),
                        ConversationMessage(role: "user", text: "Jablka a hrušky.")]
        let prompt = CompanionModel.prompt(messages: messages, memory: "Piš česky", memoryProposal: false)
        XCTAssertTrue(prompt.contains("orchard"))
        XCTAssertTrue(prompt.contains("Which fruit?"))
        XCTAssertTrue(prompt.contains("Jablka a hrušky"))
        XCTAssertTrue(prompt.contains("Piš česky"))
        let bounded = CompanionModel.prompt(messages: [.init(role: "user", text: String(repeating: "x", count: 50_000))] + messages,
                                           memory: "", memoryProposal: true)
        XCTAssertTrue(bounded.contains("Earlier messages were omitted"))
        XCTAssertTrue(bounded.contains("complete replacement Markdown"))
        XCTAssertFalse(bounded.contains(String(repeating: "x", count: 100)))
    }

    func testAgentArgumentsDoNotBypassPermissions() {
        let output = directory.appendingPathComponent("reply")
        let codex = CompanionAgentRunner.arguments(agent: .codex, output: output)
        XCTAssertTrue(codex.contains("read-only"))
        XCTAssertTrue(codex.contains("--ignore-user-config"))
        let claude = CompanionAgentRunner.arguments(agent: .claude, output: output)
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(claude.contains("{\"disableAllHooks\":true}"))
        XCTAssertFalse((codex + claude).contains(where: { $0.contains("dangerously") }))
    }

    func testRunnerHandlesStdinAndExitFailure() async throws {
        let executable = directory.appendingPathComponent("fake-agent")
        try "#!/bin/sh\ncat\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let reply = try await CompanionAgentRunner.run(agent: .claude, executable: executable, prompt: "Ahoj $(touch nope) `whoami`", timeout: 2)
        XCTAssertEqual(reply, "Ahoj $(touch nope) `whoami`")
        try "#!/bin/sh\nexit 7\n".write(to: executable, atomically: true, encoding: .utf8)
        do {
            _ = try await CompanionAgentRunner.run(agent: .claude, executable: executable, prompt: "hello", timeout: 2)
            XCTFail("Expected process error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("CLI failed")) }
    }

    func testRunnerTimeoutIsBounded() async throws {
        let executable = directory.appendingPathComponent("fake-agent")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = Date()
        do {
            _ = try await CompanionAgentRunner.run(agent: .claude, executable: executable, prompt: "hello", timeout: 0.2)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testYouTubePauseResumeOwnership() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("""
        var location = {hostname:'www.youtube.com'};
        var plays = 0;
        var video = {paused:false, ended:false, currentSrc:'video-A', currentTime:12,
                     pause:function(){this.paused=true;}, play:function(){plays++;this.paused=false;return {catch:function(){}};}};
        var document = {querySelectorAll:function(){return [video];}};
        """)
        func pause(_ token: String = "owner") { js.evaluateScript(BrowserMediaScripts.javascript(pausing: true, token: token)) }
        func resume(_ token: String = "owner") { js.evaluateScript(BrowserMediaScripts.javascript(pausing: false, token: token)) }
        pause(); XCTAssertTrue(js.evaluateScript("video.paused").toBool())
        resume("other"); XCTAssertEqual(js.evaluateScript("plays").toInt32(), 0)
        resume(); XCTAssertEqual(js.evaluateScript("plays").toInt32(), 1)
        resume(); XCTAssertEqual(js.evaluateScript("plays").toInt32(), 1)
        // Initially paused video must stay paused.
        js.evaluateScript("video.paused=true")
        pause(); resume(); XCTAssertEqual(js.evaluateScript("plays").toInt32(), 1)
        // Navigation/source replacement invalidates ownership.
        js.evaluateScript("video.paused=false")
        pause(); js.evaluateScript("video.currentSrc='video-B'"); resume()
        XCTAssertEqual(js.evaluateScript("plays").toInt32(), 1)
        // Seeking manually invalidates resumption.
        js.evaluateScript("video.paused=false")
        pause(); js.evaluateScript("video.currentTime=50"); resume()
        XCTAssertEqual(js.evaluateScript("plays").toInt32(), 1)
        // Other websites, including a spoofed suffix, are never paused.
        js.evaluateScript("location.hostname='youtube.com.example.org';video.paused=false")
        pause(); XCTAssertFalse(js.evaluateScript("video.paused").toBool())
        XCTAssertNil(js.exception)
    }
    func testInstalledAgentConversationAndMemoryProposal() async throws {
        guard ProcessInfo.processInfo.environment["VOCARET_AGENT_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in live CLI test; uses the signed-in account")
        }
        for agent in CompanionAgent.allCases {
            let executable = try XCTUnwrap(agent.executable)
            let messages = [ConversationMessage(role: "user", text: "Our fictional test project code is ORCHARD-217."),
                            ConversationMessage(role: "assistant", text: "Understood."),
                            ConversationMessage(role: "user", text: "Reply with only the project code and my preferred language from memory.")]
            let prompt = await CompanionModel.prompt(messages: messages, memory: "Preferred language: Czech", memoryProposal: false)
            let reply = try await CompanionAgentRunner.run(agent: agent, executable: executable, prompt: prompt, timeout: 90)
            XCTAssertTrue(reply.contains("ORCHARD-217"), "\(agent): lost prior turn")
            XCTAssertTrue(reply.lowercased().contains("czech") || reply.lowercased().contains("če"), "\(agent): lost memory")
            let edit = await CompanionModel.prompt(messages: [.init(role: "user", text: "Add project code ORCHARD-217 to memory. Keep the existing language preference.")],
                                                   memory: "Preferred language: Czech", memoryProposal: true)
            let proposal = try await CompanionAgentRunner.run(agent: agent, executable: executable, prompt: edit, timeout: 90)
            XCTAssertTrue(proposal.contains("ORCHARD-217"))
            XCTAssertTrue(proposal.lowercased().contains("czech") || proposal.lowercased().contains("če"))
            print("Verified \(agent.title): conversation context and memory proposal")
        }
    }

    func testBrowserAppleScriptsCompile() async throws {
        for browser in BrowserMediaScripts.browsers.prefix(2) {
            for pausing in [true, false] {
                let source = directory.appendingPathComponent("media.applescript")
                try BrowserMediaScripts.script(browser: browser, pausing: pausing, token: "test-token")
                    .write(to: source, atomically: true, encoding: .utf8)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
                process.arguments = ["-o", directory.appendingPathComponent("media.scpt").path, source.path]
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                let deadline = Date().addingTimeInterval(8)
                while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
                if process.isRunning { process.terminate(); XCTFail("AppleScript compiler timed out"); return }
                process.waitUntilExit()
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(process.terminationStatus, 0, "\(browser.name): \(message)")
            }
        }
    }

    @MainActor func testRememberRequiresExplicitSaveAndPreservesExistingMemory() throws {
        let model = CompanionModel(directory: directory)
        try model.store.saveMemory("# Memory\nPiš česky.", replacing: "")
        model.noteDictation("  Projekt se jmenuje Sad.  ")
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.editingMemory)
        XCTAssertEqual(try model.store.memory(), "# Memory\nPiš česky.")
        model.rememberLastDictation()
        XCTAssertEqual(model.memoryDraft, "# Memory\nPiš česky.\n\nProjekt se jmenuje Sad.")
        XCTAssertTrue(model.editingMemory)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(try model.store.memory(), "# Memory\nPiš česky.")
        model.saveMemory()
        XCTAssertEqual(try model.store.memory(), model.memoryDraft)
        XCTAssertFalse(model.editingMemory)
        XCTAssertFalse(model.expanded)
    }

    @MainActor func testRememberEmptyBusyCaptureAndCancelDoNotWriteMemory() throws {
        let model = CompanionModel(directory: directory)
        model.noteDictation(" \n ")
        model.rememberLastDictation()
        XCTAssertFalse(model.editingMemory)
        model.noteDictation("Remember me")
        model.capturing = true
        model.rememberLastDictation()
        XCTAssertFalse(model.editingMemory)
        model.capturing = false
        model.busy = true
        model.rememberLastDictation()
        XCTAssertFalse(model.editingMemory)
        model.busy = false
        model.rememberLastDictation()
        model.closeMemory()
        XCTAssertEqual(try model.store.memory(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.store.memoryURL.path))
        XCTAssertFalse(model.expanded)
    }

}
