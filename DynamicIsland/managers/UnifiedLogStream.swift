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

import Foundation
import os

/// Live tail of the unified log for one predicate, delivered as parsed ndjson events.
///
/// `OSLogStore` cannot stream and needs admin rights for other processes' entries, so
/// like `SystemTimerBridge` this shells out to `/usr/bin/log stream`. Keep predicates
/// tight (subsystem + message text): logd filters before anything reaches us, which is
/// what keeps an idle stream at ~0% CPU.
final class UnifiedLogStream {
    typealias EventHandler = ([String: Any]) -> Void

    private let predicate: String
    private let level: String
    private let queue: DispatchQueue
    private let handler: EventHandler
    private let logger: os.Logger

    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var restartWorkItem: DispatchWorkItem?
    private var restartAttempts = 0
    private var isStopping = false

    /// Backlog cap; a stalled consumer must never grow memory without bound.
    private let maxBufferBytes = 512 * 1024

    /// - Parameters:
    ///   - predicate: `log stream --predicate` expression.
    ///   - level: `default`, `info` or `debug`. Info-level messages are not persisted by
    ///     macOS for most subsystems, so this stream is often the only way to see them.
    ///   - queue: serial queue the handler and all internal state run on.
    init(predicate: String, level: String = "info", queue: DispatchQueue, category: String, handler: @escaping EventHandler) {
        self.predicate = predicate
        self.level = level
        self.queue = queue
        self.handler = handler
        self.logger = os.Logger(subsystem: "dev.adityatiwari.artNotch", category: category)
    }

    deinit {
        stopNow()
    }

    func start() {
        queue.async { [weak self] in
            self?.startNow()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopNow()
        }
    }

    // MARK: - Lifecycle (on `queue`)

    private func startNow() {
        if let process, process.isRunning { return }
        isStopping = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", level, "--predicate", predicate]
        process.qualityOfService = .utility

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.queue.async { [weak self] in
                self?.consume(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.handleTermination()
            }
        }

        do {
            try process.run()
            self.process = process
            self.pipe = pipe
            restartAttempts = 0
            logger.log("log stream started (pid \(process.processIdentifier, privacy: .public))")
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            logger.error("log stream failed to launch: \(error.localizedDescription, privacy: .public)")
            scheduleRestart()
        }
    }

    private func stopNow() {
        isStopping = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        process = nil
        pipe = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func handleTermination() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        pipe = nil
        buffer.removeAll(keepingCapacity: false)
        guard !isStopping else { return }
        logger.error("log stream exited; restarting")
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !isStopping, restartWorkItem == nil else { return }
        let delay = min(60.0, pow(2.0, Double(min(restartAttempts, 6))))
        restartAttempts += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.startNow()
        }
        restartWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        if buffer.count > maxBufferBytes {
            logger.error("log stream backlog exceeded \(self.maxBufferBytes, privacy: .public) bytes; dropping it")
            buffer.removeAll(keepingCapacity: false)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            // The first line ("Filtering the log data using ...") is plain text, not JSON.
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handler(object)
        }
    }

    // MARK: - Housekeeping

    /// `log stream` children outlive a parent that was SIGKILLed or crashed: launchd adopts
    /// them and they idle forever (seven were found from earlier artNotch runs). Kill any
    /// whose command line carries one of our predicate markers and whose parent is launchd.
    static func reapOrphans(markers: [String]) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]),
                  ppid == 1 else { continue }
            let command = parts[2]
            guard command.hasPrefix("/usr/bin/log stream"),
                  markers.contains(where: { command.contains($0) }) else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// One-shot `log show` for the same predicate style, parsed like the stream.
    static func show(predicate: String, last: String, level: String = "info") -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        var arguments = ["show", "--last", last, "--style", "ndjson", "--predicate", predicate]
        if level == "info" { arguments.append("--info") }
        if level == "debug" { arguments.append("--debug") }
        process.arguments = arguments
        process.qualityOfService = .utility
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.split(separator: 0x0A).compactMap { line in
            try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        }
    }
}
