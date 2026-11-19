//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(tvOS)
import XCTest

/// End-to-end tests for the native (`AVPlayerViewController`) tvOS player.
///
/// The UI is driven with the Siri Remote, and the Jellyfin server's session API is used as the oracle
/// for what is actually playing: item, play state, and the selected audio and subtitle streams.
///
/// Configure with environment variables (prefix with `TEST_RUNNER_` when using `xcodebuild test`):
/// - `JF_SERVER` (default `http://localhost:8096`)
/// - `JF_USER` (default `demo`, must not have a password) - the account the app signs in with
/// - `JF_ADMIN_USER` / `JF_ADMIN_PASSWORD` (default `tester` / `tester`) - used to read sessions
final class NativePlaybackTests: XCTestCase {

    private var server: Server!
    private var app: XCUIApplication!
    private var robot: Robot!

    override func setUp() async throws {
        continueAfterFailure = false

        let environment = ProcessInfo.processInfo.environment
        server = try await Server.connect(
            url: environment["JF_SERVER"] ?? "http://localhost:8096",
            username: environment["JF_ADMIN_USER"] ?? "tester",
            password: environment["JF_ADMIN_PASSWORD"] ?? "tester"
        )
    }

    @MainActor
    private func launchSignedIn() {
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        robot = Robot(app: app)

        if robot.button(L10n.connect).waitForExistence(timeout: 10) {
            let environment = ProcessInfo.processInfo.environment
            robot.signIn(to: server.url, username: environment["JF_USER"] ?? "demo")
        }

        robot.home()
    }

    // MARK: - Movie: transport controls, audio, subtitles, resume

    @MainActor
    func testMoviePlaybackAudioSubtitlesAndResume() async throws {
        launchSignedIn()

        robot.media().library("Movies").item("Test Movie")
        attach("Movie detail")
        robot.play()

        let started = try await server.waitForSession(named: "Test Movie") { $0.positionSeconds > 1 && !$0.isPaused }
        attach("Playing")
        XCTAssertEqual(started.audioStreamIndex, 1, "Expected the default English audio track")

        // The system transport bar must be the AVPlayerViewController one (no Swiftfin overlay).
        XCTAssertFalse(app.otherElements["playbackElapsedTime"].exists)

        // Play / pause from the remote reaches the server.
        XCUIRemote.shared.press(.playPause)
        _ = try await server.waitForSession(named: "Test Movie") { $0.isPaused }
        attach("Paused")
        XCUIRemote.shared.press(.playPause)
        _ = try await server.waitForSession(named: "Test Movie") { !$0.isPaused }

        // Subtitles: choose Spanish from the Jellyfin subtitle menu in the transport bar.
        try chooseFromTransportMenu(L10n.subtitles, option: "Spanish")
        let spanish = try await server.waitForSession(named: "Test Movie", timeout: 60) { $0.subtitleStreamIndex == 4 }
        XCTAssertGreaterThan(spanish.positionSeconds, 1, "Changing subtitles must keep the playback position")
        attach("Spanish subtitles")

        // Audio: switch to the Japanese 5.1 track (requires the server to rebuild the stream).
        try chooseFromTransportMenu(L10n.audio, option: "Japanese")
        let japanese = try await server.waitForSession(named: "Test Movie", timeout: 60) {
            $0.audioStreamIndex == 2 && !$0.isPaused && $0.positionSeconds > 1
        }
        XCTAssertEqual(japanese.subtitleStreamIndex, 4, "Changing audio must keep the subtitle selection")
        attach("Japanese audio")

        // Subtitles off.
        try chooseFromTransportMenu(L10n.subtitles, option: L10n.off)
        _ = try await server.waitForSession(named: "Test Movie", timeout: 60) { ($0.subtitleStreamIndex ?? -1) < 0 }

        // Leaving the player with the Menu button stops playback and records the resume point.
        let position = try await server.waitForSession(named: "Test Movie") { $0.positionSeconds > 5 }.positionSeconds
        dismissPlayer()
        try await server.waitForNoSession(named: "Test Movie")

        let resume = try await server.resumePositionSeconds(itemNamed: "Test Movie")
        XCTAssertGreaterThan(resume, position - 10, "Resume position was not saved")
        attach("After dismiss")
    }

    // MARK: - Episodes: Next Episode contextual action and queue

    @MainActor
    func testEpisodeNextEpisodeAction() async throws {
        launchSignedIn()

        robot.media().library("Shows")
        let series = robot.buttons(containing: "test show").firstMatch.exists
            ? robot.buttons(containing: "test show").firstMatch
            : robot.largest(robot.buttons(containing: "Test Show"))
        robot.tap(series)
        attach("Series")

        // Play the first episode from the series page.
        robot.play()
        let first = try await server.waitForSession(type: "Episode") { $0.positionSeconds > 1 }
        attach("Episode playing")

        // Jump close to the end so "Next Episode" appears.
        let target = max(0, first.runtimeSeconds - 25)
        try await server.seek(sessionID: first.sessionID, toSeconds: target)

        // Fall back to the remote's skip forward (+10s per click) if the remote seek command was not honored.
        for _ in 0 ..< 20 {
            let current = try await server.waitForSession(id: first.itemID) { _ in true }
            guard current.positionSeconds < target - 2 else { break }

            XCUIRemote.shared.press(.right)
            try await Task.sleep(for: .seconds(1.5))
        }

        _ = try await server.waitForSession(id: first.itemID) { $0.positionSeconds >= target - 2 }

        let next = app.buttons[L10n.nextEpisode]
        XCTAssertTrue(next.waitForExistence(timeout: 20), "Next Episode action did not appear near the end")
        attach("Next Episode action")
        robot.tap(next)

        let second = try await server.waitForSession(type: "Episode", timeout: 60) {
            $0.itemID != first.itemID && $0.positionSeconds > 1
        }
        XCTAssertNotEqual(second.itemID, first.itemID)
        attach("Next episode playing")

        dismissPlayer()
        try await server.waitForNoSession(id: second.itemID)
    }

    // MARK: - UI helpers

    @MainActor
    private func showTransportBar() {
        XCUIRemote.shared.press(.select)
        sleep(1)
    }

    /// Opens one of the custom transport bar menus (Subtitles, Audio, ...) and selects an option.
    @MainActor
    private func chooseFromTransportMenu(_ menu: String, option: String) throws {
        showTransportBar()

        let menuButton = app.buttons[menu].firstMatch

        if !menuButton.waitForExistence(timeout: 5) {
            print(app.debugDescription)
            XCTFail("Transport bar menu \(menu) not found")
            return
        }

        // The transport bar menus sit below the progress bar.
        robot.focus(menuButton)
        XCUIRemote.shared.press(.select)
        sleep(1)

        let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", option)).firstMatch

        if !choice.waitForExistence(timeout: 5) {
            print(app.debugDescription)
            XCTFail("Option \(option) not found in \(menu)")
            return
        }

        attach("\(menu) menu")
        robot.focus(choice)
        XCUIRemote.shared.press(.select)
        sleep(1)

        // Hide the transport bar again.
        XCUIRemote.shared.press(.menu)
        sleep(1)
    }

    @MainActor
    private func dismissPlayer() {
        // First Menu press hides any visible controls, the next ones leave the player.
        for _ in 0 ..< 3 {
            XCUIRemote.shared.press(.menu)
            sleep(2)

            if robot.buttons(labeled: L10n.play).firstMatch.exists {
                return
            }
        }
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// MARK: - Jellyfin server oracle

private struct Server {

    struct Session {

        let sessionID: String
        let itemID: String
        let itemName: String
        let itemType: String
        let positionSeconds: Double
        let runtimeSeconds: Double
        let isPaused: Bool
        let audioStreamIndex: Int?
        let subtitleStreamIndex: Int?
    }

    let url: String
    let token: String

    static func connect(url: String, username: String, password: String) async throws -> Server {
        var request = URLRequest(url: URL(string: "\(url)/Users/AuthenticateByName")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            #"MediaBrowser Client="SwiftfinUITests", Device="Simulator", DeviceId="swiftfin-ui-tests", Version="1.0""#,
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let token = try XCTUnwrap(json["AccessToken"] as? String, "Unable to sign in to \(url) as \(username)")

        return Server(url: url, token: token)
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any? {
        var request = URLRequest(url: URL(string: "\(url)\(path)")!)
        request.httpMethod = method
        request.setValue(#"MediaBrowser Token="\#(token)""#, forHTTPHeaderField: "Authorization")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }

    /// Sessions of the app under test that are currently playing something.
    func sessions() async throws -> [Session] {
        let values = try await request("/Sessions?activeWithinSeconds=60") as? [[String: Any]] ?? []

        return values.compactMap { session in
            guard (session["Client"] as? String)?.contains("SwiftfinUITests") != true,
                  let item = session["NowPlayingItem"] as? [String: Any],
                  let state = session["PlayState"] as? [String: Any] else { return nil }

            return Session(
                sessionID: session["Id"] as? String ?? "",
                itemID: item["Id"] as? String ?? "",
                itemName: item["Name"] as? String ?? "",
                itemType: item["Type"] as? String ?? "",
                positionSeconds: Double(state["PositionTicks"] as? Int ?? 0) / 10_000_000,
                runtimeSeconds: Double(item["RunTimeTicks"] as? Int ?? 0) / 10_000_000,
                isPaused: state["IsPaused"] as? Bool ?? false,
                audioStreamIndex: state["AudioStreamIndex"] as? Int,
                subtitleStreamIndex: state["SubtitleStreamIndex"] as? Int
            )
        }
    }

    @discardableResult
    func waitForSession(
        named name: String? = nil,
        type: String? = nil,
        id: String? = nil,
        timeout: TimeInterval = 45,
        file: StaticString = #filePath,
        line: UInt = #line,
        where predicate: (Session) -> Bool = { _ in true }
    ) async throws -> Session {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [Session] = []

        while Date() < deadline {
            last = try await sessions()

            if let match = last.first(where: {
                (name == nil || $0.itemName == name)
                    && (type == nil || $0.itemType == type)
                    && (id == nil || $0.itemID == id)
                    && predicate($0)
            }) {
                return match
            }

            try await Task.sleep(for: .seconds(1))
        }

        XCTFail("Timed out waiting for session \(name ?? type ?? id ?? "?"). Last: \(last)", file: file, line: line)
        throw CancellationError()
    }

    func waitForSession(id: String, timeout: TimeInterval = 45, where predicate: (Session) -> Bool) async throws -> Session {
        try await waitForSession(named: nil, type: nil, id: id, timeout: timeout, where: predicate)
    }

    func waitForNoSession(named name: String? = nil, id: String? = nil, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let playing = try await sessions().contains { (name == nil || $0.itemName == name) && (id == nil || $0.itemID == id) }

            if !playing {
                return
            }

            try await Task.sleep(for: .seconds(1))
        }

        XCTFail("Playback of \(name ?? id ?? "?") did not stop")
    }

    func seek(sessionID: String, toSeconds seconds: Double) async throws {
        let ticks = Int(seconds * 10_000_000)
        _ = try await request("/Sessions/\(sessionID)/Playing/Seek?seekPositionTicks=\(ticks)", method: "POST")
    }

    func resumePositionSeconds(itemNamed name: String) async throws -> Double {
        let users = try await request("/Users") as? [[String: Any]] ?? []
        let demo = try XCTUnwrap(users.first { ($0["Name"] as? String) == (ProcessInfo.processInfo.environment["JF_USER"] ?? "demo") })
        let userID = try XCTUnwrap(demo["Id"] as? String)

        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let result = try await request("/Items?userId=\(userID)&recursive=true&searchTerm=\(encoded)&fields=UserData") as? [String: Any]
        let items = result?["Items"] as? [[String: Any]] ?? []
        let item = try XCTUnwrap(items.first { ($0["Name"] as? String) == name })
        let userData = item["UserData"] as? [String: Any]

        return Double(userData?["PlaybackPositionTicks"] as? Int ?? 0) / 10_000_000
    }
}
#endif
