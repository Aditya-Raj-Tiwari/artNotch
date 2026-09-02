/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import ApplicationServices
import Combine
import Defaults
import Foundation
import os

/// Brings Raycast Focus sessions into the notch.
///
/// Raycast has no API for Focus, so this uses the three things it does expose (all verified
/// against Raycast 2.1.3):
/// - deeplinks `raycast://focus/start` and `raycast://focus/complete` to start and end a
///   session (there is no pause/resume deeplink; `toggle` completes a running session),
/// - its unified-log messages ("Starting Focus session" / "Tearing down Focus session" in
///   subsystem `com.raycast.macos`), streamed live, to learn about sessions started anywhere,
/// - the floating Focus Bar, read through Accessibility, for the remaining time (which
///   follows Raycast's own pauses) and to pick up a session already running at launch.
///
/// Sessions are mirrored into `TimerManager` as an external timer, so the live activity,
/// the timer tab and the lock-screen widget render them without extra code. Raycast itself
/// does the app and website blocking.
final class RaycastFocusManager: ObservableObject {
    static let shared = RaycastFocusManager()
    static let raycastBundleIdentifier = "com.raycast.macos"

    struct Session: Equatable {
        var id: String?
        var goal: String
        var mode: RaycastFocusBlockMode
        /// nil for "No limit" sessions.
        var duration: TimeInterval?
        var startedAt: Date
        var blockedApps: [String]
        var blockedWebsites: [String]
        var presentation: String?
        /// Found through the Focus Bar rather than the log: only the remaining time is known.
        var discoveredFromPanel: Bool

        var isOpenEnded: Bool { duration == nil }
    }

    private struct StartRequest {
        let goal: String
        let duration: TimeInterval?
        let categoryIds: [String]
        let mode: RaycastFocusBlockMode
    }

    private struct FocusBarReading {
        var goal: String?
        var timeText: String?
    }

    @Published private(set) var session: Session?
    /// Raycast pauses are inferred from the Focus Bar's countdown standing still.
    @Published private(set) var isPaused = false
    @Published private(set) var isRaycastInstalled = false
    @Published private(set) var isStartPending = false
    @Published private(set) var lastError: String?

    var isAvailable: Bool {
        isRaycastInstalled && Defaults[.raycastFocusIntegration]
    }

    private let logger = os.Logger(subsystem: "dev.adityatiwari.artNotch", category: "RaycastFocus")
    private let queue = DispatchQueue(label: "dev.adityatiwari.artNotch.raycastFocus", qos: .utility)
    private var stream: UnifiedLogStream?
    private var ticker: DispatchSourceTimer?
    private var panelTimer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    private var pendingStart: StartRequest?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var didStart = false

    // Countdown anchor: remaining time at `anchorDate`. Every Focus Bar reading re-anchors it,
    // so the notch follows Raycast's pauses and edits instead of drifting on its own clock.
    private var anchorRemaining: TimeInterval = 0
    private var anchorDate = Date()
    private var lastPanelText: String?
    private var lastPanelChange = Date()
    /// Raycast switches the Focus Bar from MM:SS to HH:MM above one hour.
    private var panelReadsHoursMinutes = false

    private static let logPredicate = "subsystem == \"com.raycast.macos\""
        + " AND (eventMessage CONTAINS \"Focus session\" OR eventMessage CONTAINS \"focus deeplink\")"
    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    private init() {}

    // MARK: - Lifecycle (main thread)

    func start() {
        guard !didStart else { return }
        didStart = true
        refreshInstallState()

        Defaults.publisher(.raycastFocusIntegration, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyEnabledState() }
            .store(in: &cancellables)

        // Raycast may be installed or reinstalled while we run.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier == Self.raycastBundleIdentifier }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshInstallState()
                self?.applyEnabledState()
            }
            .store(in: &cancellables)

        applyEnabledState()
    }

    private func refreshInstallState() {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.raycastBundleIdentifier) != nil
        if installed != isRaycastInstalled {
            isRaycastInstalled = installed
        }
    }

    private func applyEnabledState() {
        if isAvailable {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        guard stream == nil else { return }
        let stream = UnifiedLogStream(
            predicate: Self.logPredicate,
            level: "info",
            queue: queue,
            category: "RaycastFocus"
        ) { [weak self] event in
            self?.handleLogEvent(event)
        }
        stream.start()
        self.stream = stream
        schedulePanelTimer()
        logger.log("Monitoring Raycast Focus sessions")
    }

    private func stopMonitoring() {
        stream?.stop()
        stream = nil
        panelTimer?.cancel()
        panelTimer = nil
        if session != nil {
            endSession(reason: "monitoring disabled", completed: false)
        }
    }

    // MARK: - Control

    /// Starts a Raycast Focus session. A running session is completed first; Raycast refuses
    /// to start a second one and the new request is sent once the teardown is logged.
    func startSession(goal: String, duration: TimeInterval?, categoryIds: [String], mode: RaycastFocusBlockMode) {
        guard isAvailable else {
            lastError = String(localized: "Raycast is not installed.")
            return
        }
        let request = StartRequest(goal: goal, duration: duration, categoryIds: categoryIds, mode: mode)
        lastError = nil
        Defaults[.raycastFocusLastGoal] = goal
        if session != nil {
            pendingStart = request
            completeSession()
            return
        }
        send(request)
    }

    func completeSession() {
        guard let url = URL(string: "raycast://focus/complete") else { return }
        open(url)
    }

    private func send(_ request: StartRequest) {
        var components = URLComponents()
        components.scheme = "raycast"
        components.host = "focus"
        components.path = "/start"
        var items: [URLQueryItem] = []
        let goal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty {
            items.append(URLQueryItem(name: "goal", value: goal))
        }
        if let duration = request.duration, duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        if !request.categoryIds.isEmpty {
            items.append(URLQueryItem(name: "categories", value: request.categoryIds.joined(separator: ",")))
        }
        items.append(URLQueryItem(name: "mode", value: request.mode.rawValue))
        components.queryItems = items
        guard let url = components.url else { return }

        // The Focus session is what the user asked for; a plain countdown yields to it.
        if TimerManager.shared.hasManualTimerRunning {
            TimerManager.shared.forceStopTimer()
        }

        isStartPending = true
        open(url)

        startTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isStartPending else { return }
            self.isStartPending = false
            self.lastError = String(localized: "Raycast didn't start the session. Is Raycast running?")
        }
        startTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
        logger.log("Requested Focus session (\(goal, privacy: .public))")
    }

    private func open(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.isStartPending = false
                self?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Log events (on `queue`)

    private func handleLogEvent(_ event: [String: Any]) {
        guard let message = event["eventMessage"] as? String else { return }
        let timestamp = (event["timestamp"] as? String).flatMap(Self.logTimestampFormatter.date) ?? Date()

        if message.hasPrefix("Starting Focus session") {
            let fields = Self.parseFields(message)
            let goal = fields["Title"].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Focus")
            let session = Session(
                id: nil,
                goal: goal,
                mode: RaycastFocusBlockMode(rawValue: fields["Mode"]?.lowercased() ?? "") ?? .block,
                duration: Self.parseDuration(fields["Duration"]),
                startedAt: timestamp,
                blockedApps: Self.parseList(fields["Blocked Apps"]),
                blockedWebsites: Self.parseList(fields["Blocked Websites"]),
                presentation: nil,
                discoveredFromPanel: false
            )
            DispatchQueue.main.async { self.beginSession(session) }
        } else if message.contains("Focus session started {") {
            let id = Self.captureQuoted("id", in: message)
            let presentation = Self.captureQuoted("presentation", in: message)
            let mode = Self.captureQuoted("mode", in: message)
            DispatchQueue.main.async {
                guard var current = self.session else { return }
                if let id { current.id = id }
                if let presentation { current.presentation = presentation }
                if mode == "noLimit" { current.duration = nil }
                self.session = current
            }
        } else if message.hasPrefix("Tearing down Focus session") {
            let reason = Self.parseFields(message)["Reason"] ?? "ended"
            DispatchQueue.main.async { self.endSession(reason: reason, completed: reason == "completed") }
        } else if message.contains("Focus session completed {") {
            DispatchQueue.main.async {
                if self.session != nil {
                    self.endSession(reason: "completed", completed: true)
                }
            }
        } else if message.contains("Cannot start a focus deeplink session while another session is active") {
            DispatchQueue.main.async {
                self.isStartPending = false
                self.lastError = String(localized: "Raycast already has a Focus session running.")
            }
        } else if message.contains("Some focus deeplink categories could not be resolved") {
            let missing = Self.captureQuotedList("missingCategoryIds", in: message)
            DispatchQueue.main.async {
                self.lastError = String(localized: "Raycast doesn't know these categories: ") + missing.joined(separator: ", ")
            }
        } else if message.contains("Failed to start focus session") {
            DispatchQueue.main.async {
                self.isStartPending = false
                self.lastError = String(localized: "Raycast couldn't start the session.")
            }
        }
    }

    // MARK: - Session state (main thread)

    private func beginSession(_ newSession: Session) {
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        isStartPending = false
        lastError = nil

        session = newSession
        isPaused = false
        lastPanelText = nil
        lastPanelChange = Date()
        panelReadsHoursMinutes = false
        anchorRemaining = newSession.duration ?? 0
        anchorDate = newSession.startedAt

        let timerManager = TimerManager.shared
        if timerManager.hasManualTimerRunning {
            timerManager.forceStopTimer()
        }
        adoptIntoTimerManager()
        startTicker()
        schedulePanelTimer()

        let durationDescription = newSession.duration.map { "\(Int($0))s" } ?? "no limit"
        logger.log("Focus session started: \(newSession.goal, privacy: .public) (\(durationDescription, privacy: .public), \(newSession.blockedApps.count) apps, \(newSession.blockedWebsites.count) sites)")
    }

    private func endSession(reason: String, completed: Bool) {
        guard let ended = session else { return }
        session = nil
        isPaused = false
        stopTicker()
        schedulePanelTimer()

        let timerManager = TimerManager.shared
        if completed && !ended.isOpenEnded {
            timerManager.completeExternalTimer(owner: .raycastFocus)
        } else {
            timerManager.endExternalTimer(owner: .raycastFocus, triggerSmoothClose: true)
        }
        if completed {
            timerManager.scheduleAutoBreakIfNeeded(after: 3.5, completedName: ended.goal)
        }
        logger.log("Focus session ended (\(reason, privacy: .public))")

        if let pending = pendingStart {
            pendingStart = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.send(pending)
            }
        }
    }

    private func adoptIntoTimerManager() {
        guard let session else { return }
        let timerManager = TimerManager.shared
        let adopted = timerManager.adoptExternalTimer(
            owner: .raycastFocus,
            name: session.goal,
            totalDuration: session.duration ?? 0,
            remaining: max(0, currentRemaining()),
            elapsed: session.isOpenEnded ? Date().timeIntervalSince(session.startedAt) : nil,
            isPaused: isPaused,
            isOpenEnded: session.isOpenEnded
        )
        if !adopted {
            logger.log("TimerManager busy; the Focus session is not mirrored yet")
        }
    }

    private func currentRemaining() -> TimeInterval {
        isPaused ? anchorRemaining : anchorRemaining - Date().timeIntervalSince(anchorDate)
    }

    // MARK: - Ticking (main thread, only while a session runs)

    private func startTicker() {
        stopTicker()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard let session else { return }
        let timerManager = TimerManager.shared
        guard timerManager.isExternalTimerActive(for: .raycastFocus) else {
            // A manual countdown displaced the mirror; take the slot back once it is free.
            adoptIntoTimerManager()
            return
        }

        if session.isOpenEnded {
            timerManager.updateExternalTimer(
                owner: .raycastFocus,
                remaining: 0,
                totalDuration: nil,
                isPaused: isPaused,
                name: session.goal,
                elapsed: Date().timeIntervalSince(session.startedAt)
            )
            return
        }

        let remaining = currentRemaining()
        timerManager.updateExternalTimer(
            owner: .raycastFocus,
            remaining: max(0, remaining),
            totalDuration: session.duration,
            isPaused: isPaused,
            name: session.goal
        )
        if remaining < -20 {
            // Raycast tears a finished session down within a second; not seeing it means the
            // log event was lost, so close the mirror rather than sit on 0:00.
            endSession(reason: "expired without a teardown event", completed: true)
        }
    }

    // MARK: - Focus Bar (Accessibility)

    /// 2 s while a session runs (pause detection, drift correction); every 30 s otherwise to
    /// notice a session we never saw start, such as one running before artNotch launched.
    private func schedulePanelTimer() {
        panelTimer?.cancel()
        panelTimer = nil
        guard stream != nil else { return }
        let interval: TimeInterval = session == nil ? 30 : 2
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.readFocusBar() }
        timer.resume()
        panelTimer = timer
    }

    private func readFocusBar() {
        guard AXIsProcessTrusted(),
              let raycast = NSRunningApplication.runningApplications(withBundleIdentifier: Self.raycastBundleIdentifier).first else {
            return
        }
        let application = AXUIElementCreateApplication(raycast.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        let reading = Self.readFocusBar(in: application)
        DispatchQueue.main.async { [weak self] in
            self?.handleFocusBarReading(reading)
        }
    }

    private func handleFocusBarReading(_ reading: FocusBarReading?) {
        guard Defaults[.raycastFocusIntegration], let reading else { return }
        guard let current = session else {
            discoverSession(from: reading)
            return
        }
        guard !current.isOpenEnded, let text = reading.timeText, let clock = Self.parseClock(text) else { return }
        applyPanelClock(clock, text: text)
    }

    /// A session already running when artNotch launched (or whose start we missed). Only the
    /// remaining time is visible, so it doubles as the total.
    private func discoverSession(from reading: FocusBarReading) {
        let now = Date()
        var duration: TimeInterval?
        if let text = reading.timeText, let clock = Self.parseClock(text) {
            duration = TimeInterval(clock.first * 60 + clock.second)
        }
        lastPanelText = reading.timeText
        lastPanelChange = now
        beginSession(Session(
            id: nil,
            goal: reading.goal ?? String(localized: "Focus"),
            mode: .block,
            duration: duration,
            startedAt: now,
            blockedApps: [],
            blockedWebsites: [],
            presentation: "panel",
            discoveredFromPanel: true
        ))
        panelReadsHoursMinutes = false
        logger.log("Adopted a Focus session already running (read from the Focus Bar)")
    }

    private func applyPanelClock(_ clock: (first: Int, second: Int), text: String) {
        let now = Date()
        let changed = text != lastPanelText
        if changed {
            lastPanelText = text
            lastPanelChange = now
        }
        let estimate = currentRemaining()

        if !panelReadsHoursMinutes {
            let asMinutesSeconds = TimeInterval(clock.first * 60 + clock.second)
            let asHoursMinutes = TimeInterval(clock.first * 3600 + clock.second * 60)
            if abs(asHoursMinutes - estimate) < abs(asMinutesSeconds - estimate) {
                panelReadsHoursMinutes = true
            } else if session?.discoveredFromPanel == true, !changed, !isPaused,
                      now.timeIntervalSince(lastPanelChange) > 5.5 {
                // No estimate to compare against for a discovered session: MM:SS would have
                // ticked three times by now, so this is HH:MM.
                panelReadsHoursMinutes = true
                anchorRemaining = asHoursMinutes + 30
                anchorDate = now
                if var current = session {
                    current.duration = max(current.duration ?? 0, asHoursMinutes + 30)
                    session = current
                }
            }
        }

        if panelReadsHoursMinutes {
            let lower = TimeInterval(clock.first * 3600 + clock.second * 60)
            let upper = lower + 59
            if changed {
                if isPaused { setPaused(false) }
                if estimate < lower || estimate > upper {
                    anchorRemaining = upper
                    anchorDate = now
                }
            } else if estimate < lower - 75 {
                setPaused(true)
                anchorRemaining = lower + 30
                anchorDate = now
            } else if estimate > upper + 75 {
                anchorRemaining = upper
                anchorDate = now
            }
            return
        }

        let remaining = TimeInterval(clock.first * 60 + clock.second)
        if changed {
            if isPaused { setPaused(false) }
            anchorRemaining = remaining + 0.5
            anchorDate = now
        } else if remaining > 0, !isPaused, now.timeIntervalSince(lastPanelChange) > 3.5 {
            setPaused(true)
            anchorRemaining = remaining
            anchorDate = now
        }
    }

    private func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        logger.log("Focus session \(paused ? "paused" : "resumed", privacy: .public) (Focus Bar countdown \(paused ? "stopped" : "ticking", privacy: .public))")
    }

    private static func readFocusBar(in application: AXUIElement) -> FocusBarReading? {
        guard let windows: [AXUIElement] = copyAttribute(kAXWindowsAttribute, of: application) else { return nil }
        for window in windows {
            var texts: [String] = []
            var buttons: [String] = []
            collect(window, depth: 0, texts: &texts, buttons: &buttons)
            // Only the Focus Bar has Pause/Resume next to Complete. The "Focus session is up"
            // notice that follows an expired session offers Restart/Complete/Dismiss instead
            // and must not be mistaken for a running session.
            guard buttons.contains("Complete"),
                  buttons.contains(where: { $0 == "Pause" || $0 == "Resume" }) else { continue }
            let time = texts.first { parseClock($0) != nil }
            let goal = texts.first { $0 != time && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return FocusBarReading(goal: goal, timeText: time)
        }
        return nil
    }

    private static func collect(_ element: AXUIElement, depth: Int, texts: inout [String], buttons: inout [String]) {
        // The clock sits one level deeper than the goal and the buttons (depth 7 in Raycast 2.1.3).
        guard depth < 10 else { return }
        let role: String = copyAttribute(kAXRoleAttribute, of: element) ?? ""
        if role == kAXStaticTextRole, let value: String = copyAttribute(kAXValueAttribute, of: element) {
            texts.append(value)
        } else if role == kAXButtonRole, let title: String = copyAttribute(kAXTitleAttribute, of: element) {
            buttons.append(title)
        }
        guard let children: [AXUIElement] = copyAttribute(kAXChildrenAttribute, of: element) else { return }
        for child in children {
            collect(child, depth: depth + 1, texts: &texts, buttons: &buttons)
        }
    }

    private static func copyAttribute<T>(_ attribute: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else {
            return nil
        }
        return value as? T
    }

    // MARK: - Parsing

    /// Raycast logs `Key: value` lines under the message headline.
    private static func parseFields(_ message: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in message.split(separator: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.range(of: ":") else { continue }
            let key = String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return fields
    }

    /// "180" is seconds; "No limit" (or anything unparseable) is open-ended.
    private static func parseDuration(_ text: String?) -> TimeInterval? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = TimeInterval(text), seconds > 0 { return seconds }
        return nil
    }

    private static func parseList(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The Focus Bar's clock is two digit groups. The separator is not a plain colon (the web
    /// view pads it with invisible formatting characters), so split on anything non-numeric.
    private static func parseClock(_ text: String) -> (first: Int, second: Int)? {
        let groups = text.split(whereSeparator: { !$0.isNumber })
        guard groups.count == 2,
              groups[0].count <= 2,
              groups[1].count == 2,
              let first = Int(groups[0]),
              let second = Int(groups[1]) else { return nil }
        return (first, second)
    }

    /// Extracts `key: "value"` from Raycast's node-style log objects.
    private static func captureQuoted(_ key: String, in message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: key)):\\s*\"([^\"]*)\""),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return String(message[range])
    }

    /// Extracts `key: [ "a", "b" ]`.
    private static func captureQuotedList(_ key: String, in message: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: key)):\\s*\\[([^\\]]*)\\]"),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return [] }
        let body = message[range]
        guard let itemRegex = try? NSRegularExpression(pattern: "\"([^\"]*)\"") else { return [] }
        return itemRegex.matches(in: String(body), range: NSRange(body.startIndex..., in: body)).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]) }
        }
    }
}
