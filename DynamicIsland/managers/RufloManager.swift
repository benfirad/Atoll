//
//  RufloManager.swift
//  Atoll (DynamicIsland)
//
//  Created for Ruflo Multi-Agent Swarm Integration.
//

import Foundation
import Combine
import SwiftUI
import Defaults

public struct RufloWorkerState: Identifiable, Codable, Equatable {
    public var id: String { type }
    public let type: String
    public let description: String
    public let runCount: Int
    public let successCount: Int
    public let failureCount: Int
    public let averageDurationMs: Double
    public let isRunning: Bool
    public let enabled: Bool
    public let priority: String
}

public struct RufloTelemetry: Equatable {
    public var isDaemonRunning: Bool = false
    public var startedAt: Date? = nil
    public var uptimeString: String = "Offline"
    public var activeWorkersCount: Int = 0
    public var totalRuns: Int = 0
    public var workers: [RufloWorkerState] = []
    public var memoryEntriesCount: Int = 0
    public var lastUpdate: Date = Date()
}

@MainActor
public final class RufloManager: ObservableObject {
    public static let shared = RufloManager()

    @Published public private(set) var telemetry = RufloTelemetry()
    @Published public var isRefreshing: Bool = false

    private var refreshTimer: Timer?
    private let daemonStateURL = URL(fileURLWithPath: "/Users/kai/Documents/antigravity/ruflo/.claude-flow/daemon-state.json")
    private let memoryDBURL = URL(fileURLWithPath: "/Users/kai/Documents/antigravity/ruflo/.swarm/memory.db")

    private init() {
        startPolling()
    }

    public func startPolling() {
        refreshTimer?.invalidate()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    public func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    public func refresh() {
        guard FileManager.default.fileExists(atPath: daemonStateURL.path) else {
            telemetry.isDaemonRunning = false
            telemetry.uptimeString = "Offline"
            return
        }

        do {
            let data = try Data(contentsOf: daemonStateURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let running = json["running"] as? Bool ?? false
            var workersList: [RufloWorkerState] = []
            var activeCount = 0
            var totalRunsCount = 0

            let configDict = json["config"] as? [String: Any] ?? [:]
            let configWorkers = configDict["workers"] as? [[String: Any]] ?? []
            var workerMetaByType: [String: (desc: String, prio: String, enabled: Bool)] = [:]
            for w in configWorkers {
                if let type = w["type"] as? String {
                    let desc = w["description"] as? String ?? type.capitalized
                    let prio = w["priority"] as? String ?? "normal"
                    let enabled = w["enabled"] as? Bool ?? true
                    workerMetaByType[type] = (desc, prio, enabled)
                }
            }

            let workersDict = json["workers"] as? [String: Any] ?? [:]
            for (type, val) in workersDict {
                guard let wInfo = val as? [String: Any] else { continue }
                let runCount = wInfo["runCount"] as? Int ?? 0
                let successCount = wInfo["successCount"] as? Int ?? 0
                let failureCount = wInfo["failureCount"] as? Int ?? 0
                let avgDur = wInfo["averageDurationMs"] as? Double ?? 0
                let isRunning = wInfo["isRunning"] as? Bool ?? false

                if isRunning { activeCount += 1 }
                totalRunsCount += runCount

                let meta = workerMetaByType[type] ?? (type.capitalized, "normal", true)
                workersList.append(
                    RufloWorkerState(
                        type: type,
                        description: meta.desc,
                        runCount: runCount,
                        successCount: successCount,
                        failureCount: failureCount,
                        averageDurationMs: avgDur,
                        isRunning: isRunning,
                        enabled: meta.enabled,
                        priority: meta.prio
                    )
                )
            }

            workersList.sort { $0.type < $1.type }

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var startDate: Date? = nil
            if let startedStr = json["startedAt"] as? String {
                startDate = isoFormatter.date(from: startedStr)
            }

            let uptimeStr: String
            if running, let start = startDate {
                let interval = Int(Date().timeIntervalSince(start))
                let hours = interval / 3600
                let minutes = (interval % 3600) / 60
                uptimeStr = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
            } else if running {
                uptimeStr = "Active"
            } else {
                uptimeStr = "Stopped"
            }

            var updated = RufloTelemetry()
            updated.isDaemonRunning = running
            updated.startedAt = startDate
            updated.uptimeString = uptimeStr
            updated.activeWorkersCount = activeCount
            updated.totalRuns = totalRunsCount
            updated.workers = workersList
            updated.lastUpdate = Date()

            self.telemetry = updated
        } catch {
            print("RufloManager: Error reading daemon state: \(error)")
        }
    }

    public func triggerWorker(type: String) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Users/kai/.local/bin/ruflo")
            process.arguments = ["worker-dispatch", "--type", type]
            try? process.run()
        }
    }

    public func terminateAllWorkers() {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Users/kai/.local/bin/ruflo")
            process.arguments = ["agent", "terminate", "--all"]
            try? process.run()
        }
    }
}
