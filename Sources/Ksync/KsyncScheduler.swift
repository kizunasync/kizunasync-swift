import Foundation
#if canImport(Network)
import Network
#endif

public enum KsyncWakeReason: String, Sendable {
  case poll
  case foreground
  case path
  case doorbell
}

/// Host scheduler: connectivity + foreground are OS concerns. The doorbell is a
/// callback the app wires from supabase-swift realtime. Refresh the user JWT
/// **before** `sync()` so a backgrounded session does not poll with a dead Bearer.
public final class KsyncScheduler: @unchecked Sendable {
  public var pollInterval: TimeInterval
  public var refreshSession: () async -> Bool
  public var sync: () async throws -> Void
  public var monitorPath: Bool

  private var timer: Timer?
  private var running = false
  private var inFlight = false
  private var trailing = false
  private let inFlightLock = NSLock()
#if canImport(Network)
  private var pathMonitor: NWPathMonitor?
#endif

  public init(
    pollInterval: TimeInterval = 15,
    monitorPath: Bool = true,
    refreshSession: @escaping () async -> Bool,
    sync: @escaping () async throws -> Void
  ) {
    self.pollInterval = pollInterval
    self.monitorPath = monitorPath
    self.refreshSession = refreshSession
    self.sync = sync
  }

  public func start() {
    guard !running else { return }
    running = true
    startTimer()
    startPathMonitor()
  }

  public func stop() {
    running = false
    timer?.invalidate()
    timer = nil
#if canImport(Network)
    pathMonitor?.cancel()
    pathMonitor = nil
#endif
  }

  public func wake(reason: KsyncWakeReason = .doorbell) {
    Task { await self.run(reason: reason) }
  }

  /// Call from SwiftUI `scenePhase == .active` (or UIKit foreground).
  public func notifyForeground() {
    wake(reason: .foreground)
  }

  public func notifyOnline() {
    wake(reason: .path)
  }

  private func startTimer() {
    timer?.invalidate()
    guard pollInterval > 0 else { return }
    let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
      self?.wake(reason: .poll)
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func startPathMonitor() {
    guard monitorPath else { return }
#if canImport(Network)
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      if path.status == .satisfied {
        self?.wake(reason: .path)
      }
    }
    monitor.start(queue: DispatchQueue(label: "io.ksync.path"))
    pathMonitor = monitor
#endif
  }

  private func run(reason: KsyncWakeReason) async {
    _ = reason
    guard tryBeginRun() else { return }
    defer {
      if finishRunAndTakeTrailing() {
        wake(reason: .doorbell)
      }
    }
    let hasSession = await refreshSession()
    guard hasSession else { return }
    try? await sync()
  }

  /// Synchronous so `run` never touches `inFlightLock` from an `async` context.
  private func tryBeginRun() -> Bool {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    if inFlight {
      trailing = true
      return false
    }
    inFlight = true
    return true
  }

  private func finishRunAndTakeTrailing() -> Bool {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    inFlight = false
    let runTrailing = trailing
    trailing = false
    return runTrailing
  }
}
