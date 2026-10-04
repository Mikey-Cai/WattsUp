import Foundation
import WattsUpCore
import WidgetKit

/// Writes the widget's JSON into the App Group container and nudges WidgetKit.
/// Used only from the sampling queue.
final class WidgetSnapshotWriter {
    private let policy = WidgetWritePolicy()
    private var lastWrite: Date?
    private var lastReload: Date?
    private var lastPressure: String?
    private var reportedFailure = false

    func write(_ snapshot: WidgetSnapshot, force: Bool) {
        let now = Date()
        guard force || policy.shouldWrite(now: now, lastWrite: lastWrite) else { return }
        guard let url = WidgetSnapshot.fileURL() else {
            if !reportedFailure {
                NSLog("WattsUp: App Group container %@ is unavailable; the widget cannot be updated.",
                      WidgetSnapshot.appGroupIdentifier ?? "(this build has no App Group)")
                reportedFailure = true
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshot.encoded().write(to: url, options: [.atomic])
            lastWrite = now
        } catch {
            if !reportedFailure {
                NSLog("WattsUp: writing widget snapshot failed: %@", "\(error)")
                reportedFailure = true
            }
            return
        }
        if policy.shouldReload(now: now, lastReload: lastReload, previousPressure: lastPressure, pressure: snapshot.pressure) {
            lastReload = now
            DispatchQueue.main.async {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
            }
        }
        lastPressure = snapshot.pressure
    }
}

/// Asks WidgetKit whether a WattsUp widget is on the desktop, so background
/// sampling only runs when someone can see its result.
@MainActor
final class WidgetPresenceMonitor {
    private var timer: Timer?
    var onChange: ((Bool) -> Void)?

    func start() {
        check()
        let timer = Timer(timeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            let installed: Bool
            switch result {
            case .success(let widgets):
                installed = widgets.contains { $0.kind == WidgetSnapshot.widgetKind }
            case .failure:
                installed = false
            }
            DispatchQueue.main.async { self?.onChange?(installed) }
        }
    }
}
