import Darwin
import Foundation

final class SSEClient {
    let id = UUID()
    let fd: Int32
    let isTeacher: Bool
    let studentToken: String?
    private let writeLock = NSLock()
    private var closed = false

    init(fd: Int32, isTeacher: Bool, studentToken: String?) {
        self.fd = fd
        self.isTeacher = isTeacher
        self.studentToken = studentToken
    }

    func sendRaw(_ text: String) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        if closed { return false }
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if written <= 0 {
                closed = true
                return false
            }
            offset += written
        }
        return true
    }

    func closeSocket() {
        writeLock.lock()
        let already = closed
        closed = true
        writeLock.unlock()
        if !already {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

final class EventBroker {
    private let lock = NSLock()
    private var teacherClients: [UUID: SSEClient] = [:]
    private var studentClients: [UUID: SSEClient] = [:]
    private var pingTimer: DispatchSourceTimer?

    init() {
        startPingTimer()
    }

    deinit {
        stopAll()
    }

    private func startPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            self?.sendPingAll()
        }
        timer.resume()
        pingTimer = timer
    }

    func addTeacher(_ client: SSEClient) {
        lock.lock()
        teacherClients[client.id] = client
        lock.unlock()
    }

    func addStudent(_ client: SSEClient) {
        lock.lock()
        studentClients[client.id] = client
        lock.unlock()
    }

    func remove(_ client: SSEClient) {
        lock.lock()
        teacherClients.removeValue(forKey: client.id)
        studentClients.removeValue(forKey: client.id)
        lock.unlock()
        client.closeSocket()
    }

    func stopAll() {
        pingTimer?.cancel()
        pingTimer = nil
        lock.lock()
        let all = Array(teacherClients.values) + Array(studentClients.values)
        teacherClients.removeAll()
        studentClients.removeAll()
        lock.unlock()
        for c in all {
            c.closeSocket()
        }
    }

    private func formatSSE(event: String, payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "event: \(event)\ndata: \(jsonStr)\n\n"
    }

    func emitTeacher(event: String, data: [String: Any]) {
        let msg = formatSSE(event: event, payload: data)
        if msg.isEmpty { return }
        lock.lock()
        let targets = Array(teacherClients.values)
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for client in targets {
                if !client.sendRaw(msg) {
                    self?.remove(client)
                }
            }
        }
    }

    func emitStudents(event: String, data: [String: Any], token: String? = nil) {
        let msg = formatSSE(event: event, payload: data)
        if msg.isEmpty { return }
        lock.lock()
        let targets = studentClients.values.filter { token == nil || $0.studentToken == token }
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for client in targets {
                if !client.sendRaw(msg) {
                    self?.remove(client)
                }
            }
        }
    }

    private func sendPingAll() {
        lock.lock()
        let all = Array(teacherClients.values) + Array(studentClients.values)
        lock.unlock()
        for client in all {
            if !client.sendRaw(": ping\n\n") {
                remove(client)
            }
        }
    }
}
