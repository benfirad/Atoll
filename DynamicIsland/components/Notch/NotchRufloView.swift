//
//  NotchRufloView.swift
//  Atoll (DynamicIsland)
//
//  Created for Ruflo Multi-Agent Swarm Integration.
//

import SwiftUI
import Defaults

struct NotchRufloView: View {
    @ObservedObject private var manager = RufloManager.shared
    @EnvironmentObject private var vm: DynamicIslandViewModel

    var body: some View {
        VStack(spacing: 12) {
            // Header Bar
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.cyan)

                    Text("RUFLO SWARM")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }

                Spacer()

                // Status Badge & Daemon Control
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(manager.telemetry.isDaemonRunning ? Color.green : Color.red)
                            .frame(width: 7, height: 7)

                        Text(manager.telemetry.isDaemonRunning ? "ACTIVE" : "OFFLINE")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(manager.telemetry.isDaemonRunning ? .green : .red)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())

                    Button(action: {
                        if manager.telemetry.isDaemonRunning {
                            manager.stopDaemon()
                        } else {
                            manager.startDaemon()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: manager.telemetry.isDaemonRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 9))
                            Text(manager.telemetry.isDaemonRunning ? "Durdur" : "Başlat")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(manager.telemetry.isDaemonRunning ? .red.opacity(0.9) : .green.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                // Uptime
                Text(manager.telemetry.uptimeString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Workers Grid
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(manager.telemetry.workers) { worker in
                        RufloWorkerCard(worker: worker) {
                            manager.triggerWorker(type: worker.type)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 150)

            // Footer / Stats Bar
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundColor(.cyan)
                    Text("Workers: \(manager.telemetry.workers.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }

                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Total Runs: \(manager.telemetry.totalRuns)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }

                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text("AgentDB: Active")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                Button(action: {
                    manager.refresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(width: max(460, vm.closedNotchSize.width + 160))
        .background(Color.black.opacity(0.4))
    }
}

private struct RufloWorkerCard: View {
    let worker: RufloWorkerState
    let onTrigger: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(worker.isRunning ? Color.cyan : (worker.enabled ? Color.green.opacity(0.7) : Color.gray.opacity(0.4)))
                        .frame(width: 6, height: 6)

                    Text(worker.type.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }

                Text(worker.description)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(worker.runCount) runs")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))

                if worker.isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Button(action: onTrigger) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.cyan.opacity(0.8))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
    }
}
