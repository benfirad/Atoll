/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Ruflo Multi-Agent Swarm Menu Bar Integration.
 */

import SwiftUI
import Defaults

public struct RufloMenuBarMenu: View {
    @ObservedObject private var manager = RufloManager.shared
    @ObservedObject private var coordinator = DynamicIslandViewCoordinator.shared

    public init() {}

    public var body: some View {
        Group {
            Text("⚡ Ruflo Multi-Agent Swarm")
                .font(.headline)

            let isRunning = manager.telemetry.isDaemonRunning
            Text("Durum: \(isRunning ? "🟢 Çalışıyor (Aktif)" : "⚪ Beklemede (Offline)")")
            Text("Aktif Ajanlar: \(manager.telemetry.activeWorkersCount)")
            Text("Toplam Görev İcrası: \(manager.telemetry.totalRuns)")
            Text("Swarm Vektör Hafızası: \(manager.telemetry.memoryEntriesCount) kayıt")
            Text("Çalışma Süresi: \(manager.telemetry.uptimeString)")

            Divider()

            if manager.telemetry.isDaemonRunning {
                Button("⏹️ Swarm Daemon'u Durdur") {
                    manager.stopDaemon()
                }
            } else {
                Button("▶️ Swarm Daemon'u Başlat") {
                    manager.startDaemon()
                }
            }

            Button("🎯 Çentikte Aç (Dynamic Island)") {
                openRufloInNotch()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("🔄 Swarm Telemetrisini Yenile") {
                manager.refresh()
            }

            if manager.telemetry.activeWorkersCount > 0 {
                Divider()
                Text("Aktif Ajanlar:")
                ForEach(manager.telemetry.workers.filter { $0.isRunning }) { worker in
                    Button("⚡ \(worker.type.capitalized): \(worker.runCount) görev | \(String(format: "%.1f", worker.averageDurationMs))ms") {
                        openRufloInNotch()
                    }
                }
            }

            Divider()

            if manager.telemetry.activeWorkersCount > 0 {
                Button("⏹️ Tüm İşçileri Durdur (Terminate All)", role: .destructive) {
                    manager.terminateAllWorkers()
                }
            }

            Button("⚙️ Atoll Ayarları…") {
                SettingsWindowController.shared.showWindow()
            }
        }
    }

    private func openRufloInNotch() {
        guard let appDelegate = AppDelegate.shared else { return }
        appDelegate.cancelPendingNotchAutoClose()
        withAnimation(.smooth) {
            coordinator.currentView = .ruflo
        }
        appDelegate.vm.open()
    }
}
