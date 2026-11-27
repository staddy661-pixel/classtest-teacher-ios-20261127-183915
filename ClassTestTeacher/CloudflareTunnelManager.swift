import Combine
import Foundation

final class CloudflareTunnelManager: ObservableObject {
    @Published private(set) var status: String = "off" // off | starting | ready | failed
    @Published private(set) var publicURL: String = ""

    private var pollTimer: Timer?
    private var startedAt: Date?

    deinit {
        stop()
    }

    func start(port: Int) {
        stop()
        status = "starting"
        publicURL = ""
        startedAt = Date()

        StartCloudflaredTunnel(Int32(port))

        DispatchQueue.main.async { [weak self] in
            self?.pollTimer?.invalidate()
            self?.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refreshFromBridge()
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
        }
        StopCloudflaredTunnel()
        DispatchQueue.main.async { [weak self] in
            self?.status = "off"
            self?.publicURL = ""
            self?.startedAt = nil
        }
    }

    private func refreshFromBridge() {
        var statusBuf = [CChar](repeating: 0, count: 64)
        GetCloudflaredStatus(&statusBuf, Int32(statusBuf.count))
        let newStatus = String(cString: statusBuf)

        var urlBuf = [CChar](repeating: 0, count: 512)
        GetCloudflaredURL(&urlBuf, Int32(urlBuf.count))
        let newURL = String(cString: urlBuf)

        if !newURL.isEmpty {
            publicURL = newURL
            status = "ready"
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }

        if newStatus == "failed" {
            status = "failed"
            publicURL = ""
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }

        if let startedAt, Date().timeIntervalSince(startedAt) > 60, status == "starting" {
            status = "failed"
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
}
