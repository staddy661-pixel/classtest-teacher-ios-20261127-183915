import AudioToolbox
import Combine
import Darwin
import Foundation

final class LocalHTTPServer: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: Int = 8000
    @Published private(set) var endpoints: [NetworkEndpoint] = []
    @Published private(set) var lastError: String? = nil

    let db = Database()
    let tunnel = CloudflareTunnelManager()
    private var broker = EventBroker()
    private var listenFD: Int32 = -1
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "com.classtest.teacher.accept", qos: .userInitiated)
    private var localAuthToken: String = ""
    private let tunnelHeaders = ["cf-connecting-ip", "cf-ray", "x-forwarded-for", "x-forwarded-host"]

    init() {
        Darwin.signal(SIGPIPE, SIG_IGN)
        refreshEndpoints()
    }

    deinit {
        stop()
    }

    func refreshEndpoints() {
        let eps = NetworkUtils.getLocalEndpoints()
        DispatchQueue.main.async {
            self.endpoints = eps
        }
    }

    func ensureLocalAuthToken() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        if localAuthToken.isEmpty || !db.isTeacherTokenValid(localAuthToken) {
            localAuthToken = db.issueLocalTeacherToken()
        }
        return localAuthToken
    }

    var primaryStudentURL: String {
        let ip = endpoints.first?.ip ?? NetworkUtils.getLocalIPs().first ?? "127.0.0.1"
        return "http://\(ip):\(port)"
    }

    var localAutoLoginTeacherURL: String {
        let tok = ensureLocalAuthToken()
        return "http://127.0.0.1:\(port)/api/auth/auto?t=\(tok)"
    }

    func start(preferredPort: Int = 8000) -> Bool {
        stateLock.lock()
        if listenFD >= 0 {
            stateLock.unlock()
            return true
        }

        var boundFD: Int32 = -1
        var boundPort: Int = preferredPort

        for candidate in preferredPort..<(preferredPort + 15) {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { continue }

            var yes: Int32 = 1
            Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(candidate)).bigEndian
            addr.sin_addr = in_addr(s_addr: in_addr_t(0))

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 && Darwin.listen(fd, 64) == 0 {
                boundFD = fd
                boundPort = candidate
                break
            } else {
                Darwin.close(fd)
            }
        }

        if boundFD < 0 {
            stateLock.unlock()
            DispatchQueue.main.async {
                self.lastError = "Не удалось открыть порт 8000–8014"
                self.isRunning = false
            }
            return false
        }

        self.listenFD = boundFD
        self.broker = EventBroker()
        let eps = NetworkUtils.getLocalEndpoints()
        stateLock.unlock()

        DispatchQueue.main.async {
            self.port = boundPort
            self.endpoints = eps
            self.lastError = nil
            self.isRunning = true
        }

        acceptQueue.async { [weak self] in
            self?.acceptLoop(serverFD: boundFD)
        }
        return true
    }

    func stop() {
        tunnel.stop()
        stateLock.lock()
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        broker.stopAll()

        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    private func acceptLoop(serverFD: Int32) {
        while true {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverFD, $0, &len)
                }
            }
            if clientFD < 0 {
                stateLock.lock()
                let stillOpen = (listenFD == serverFD)
                stateLock.unlock()
                if !stillOpen { break }
                continue
            }

            var yes: Int32 = 1
            Darwin.setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleConnection(fd: clientFD)
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    private func readRequest(fd: Int32) -> HTTPRequest? {
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let sep = Data("\r\n\r\n".utf8)
        var headerEndRange: Range<Data.Index>? = nil

        while headerEndRange == nil {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer.append(chunk, count: n)
            headerEndRange = buffer.range(of: sep)
            if buffer.count > 128 * 1024 { return nil }
        }

        guard let range = headerEndRange else { return nil }
        let headerData = buffer.subdata(in: 0..<range.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .isoLatin1) else {
            return nil
        }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { return nil }
        let parts = reqLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        var body = buffer.subdata(in: range.upperBound..<buffer.count)
        if contentLength > 20 * 1024 * 1024 { return nil }

        while body.count < contentLength {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            body.append(chunk, count: n)
        }
        if body.count > contentLength && contentLength > 0 {
            body = body.subdata(in: 0..<contentLength)
        }

        let comps = URLComponents(string: "http://localhost" + rawTarget)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: method, path: comps?.path ?? rawTarget, query: query, headers: headers, body: body)
    }

    private func sendAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Internal Server Error"
        }
    }

    private func sendBytes(fd: Int32, status: Int, body: Data, contentType: String, extraHeaders: [String: String] = [:]) {
        var hdr = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        hdr += "Content-Type: \(contentType)\r\n"
        hdr += "Content-Length: \(body.count)\r\n"
        hdr += "Cache-Control: no-store\r\n"
        hdr += "Connection: close\r\n"
        for (k, v) in extraHeaders { hdr += "\(k): \(v)\r\n" }
        hdr += "\r\n"
        var full = Data(hdr.utf8)
        full.append(body)
        sendAll(fd: fd, data: full)
    }

    private func sendJSON(fd: Int32, status: Int = 200, obj: Any, extraHeaders: [String: String] = [:]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
        sendBytes(fd: fd, status: status, body: data, contentType: "application/json; charset=utf-8", extraHeaders: extraHeaders)
    }

    private func parseBodyJSON(_ data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    private func teacherToken(from req: HTTPRequest) -> String {
        if let cookieHdr = req.headers["cookie"] {
            for part in cookieHdr.split(separator: ";") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ct_auth=") {
                    return String(trimmed.dropFirst("ct_auth=".count))
                }
            }
        }
        return req.headers["x-teacher-token"] ?? ""
    }

    private func isTeacherAuthed(_ req: HTTPRequest) -> Bool {
        db.isTeacherTokenValid(teacherToken(from: req))
    }

    private func requireTeacher(fd: Int32, req: HTTPRequest) -> Bool {
        if !isTeacherAuthed(req) {
            sendJSON(fd: fd, status: 401, obj: ["error": "Требуется авторизация"])
            return false
        }
        return true
    }

    private func serveStatic(fd: Int32, fileName: String) {
        let cleanName = URL(fileURLWithPath: fileName).lastPathComponent
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("WebStatic"),
              let data = try? Data(contentsOf: root.appendingPathComponent(cleanName)) else {
            sendJSON(fd: fd, status: 404, obj: ["error": "Not found"])
            return
        }
        let ext = URL(fileURLWithPath: cleanName).pathExtension.lowercased()
        let ctype: String
        switch ext {
        case "html": ctype = "text/html; charset=utf-8"
        case "css": ctype = "text/css; charset=utf-8"
        case "js": ctype = "application/javascript; charset=utf-8"
        case "svg": ctype = "image/svg+xml; charset=utf-8"
        case "png": ctype = "image/png"
        default: ctype = "application/octet-stream"
        }
        sendBytes(fd: fd, status: 200, body: data, contentType: ctype)
    }

    private func isViaTunnel(_ req: HTTPRequest) -> Bool {
        for h in tunnelHeaders {
            if let v = req.headers[h], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    private func tunnelBlocked(fd: Int32, req: HTTPRequest) -> Bool {
        if !isViaTunnel(req) { return false }
        let p = req.path
        if p == "/" || p == "/index.html" || p == "/static/student.js" || p == "/static/styles.css"
            || p.hasPrefix("/api/student/") || p == "/api/events/student" {
            return false
        }
        sendJSON(fd: fd, status: 403, obj: ["error": "Недоступно через интернет-ссылку"])
        return true
    }

    private func handleConnection(fd: Int32) {
        guard let req = readRequest(fd: fd) else {
            Darwin.close(fd)
            return
        }

        if tunnelBlocked(fd: fd, req: req) {
            Darwin.close(fd)
            return
        }

        if req.method == "GET" && req.path == "/api/events/teacher" {
            if !requireTeacher(fd: fd, req: req) {
                Darwin.close(fd)
                return
            }
            handleSSE(fd: fd, isTeacher: true, studentToken: nil)
            return
        }
        if req.method == "GET" && req.path == "/api/events/student" {
            let tok = req.query["token"]
            handleSSE(fd: fd, isTeacher: false, studentToken: (tok?.isEmpty == false) ? tok : nil)
            return
        }

        defer { Darwin.close(fd) }

        switch req.method {
        case "GET": routeGET(fd: fd, req: req)
        case "POST": routePOST(fd: fd, req: req)
        case "PUT": routePUT(fd: fd, req: req)
        case "DELETE": routeDELETE(fd: fd, req: req)
        default: sendJSON(fd: fd, status: 405, obj: ["error": "Method not allowed"])
        }
    }

    private func handleSSE(fd: Int32, isTeacher: Bool, studentToken: String?) {
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n: connected\n\n"
        let client = SSEClient(fd: fd, isTeacher: isTeacher, studentToken: studentToken)
        guard client.sendRaw(hdr) else {
            client.closeSocket()
            return
        }
        if isTeacher { broker.addTeacher(client) } else { broker.addStudent(client) }
    }

    private func pathId(from path: String, index: Int) -> Int? {
        let segs = path.split(separator: "/")
        return index < segs.count ? Int(segs[index]) : nil
    }

    private func routeGET(fd: Int32, req: HTTPRequest) {
        let path = req.path

        if path == "/" || path == "/index.html" { return serveStatic(fd: fd, fileName: "index.html") }
        if path == "/teacher" || path == "/teacher/" || path == "/teacher.html" { return serveStatic(fd: fd, fileName: "teacher.html") }
        if path.hasPrefix("/static/") { return serveStatic(fd: fd, fileName: String(path.dropFirst("/static/".count))) }

        // Авто-вход для встроенного WebView на iPhone учителя по секретному локальному токену
        if path == "/api/auth/auto" {
            let tok = (req.query["t"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if db.isTeacherTokenValid(tok) {
                return sendBytes(
                    fd: fd,
                    status: 302,
                    body: Data(),
                    contentType: "text/plain; charset=utf-8",
                    extraHeaders: [
                        "Set-Cookie": "ct_auth=\(tok); Path=/; HttpOnly; SameSite=Lax",
                        "Location": "/teacher"
                    ]
                )
            }
            return sendBytes(fd: fd, status: 302, body: Data(), contentType: "text/plain", extraHeaders: ["Location": "/teacher"])
        }

        if path == "/api/qr" {
            let text = (req.query["text"]?.isEmpty == false) ? req.query["text"]! : primaryStudentURL
            return sendBytes(fd: fd, status: 200, body: NetworkUtils.generateQRPNG(text: text), contentType: "image/png")
        }
        if path == "/api/auth/me" {
            return sendJSON(fd: fd, obj: ["authenticated": isTeacherAuthed(req)])
        }
        if path == "/api/student/status" {
            let tok = (req.query["token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return sendJSON(fd: fd, obj: db.getStudentStatus(token: tok))
        }

        if path == "/teacher/import" {
            return sendBytes(fd: fd, status: 200, body: Data(DocxImporter.importPageHTML.utf8), contentType: "text/html; charset=utf-8")
        }

        if !requireTeacher(fd: fd, req: req) { return }

        if path == "/api/tests/docx-template" {
            return sendBytes(
                fd: fd,
                status: 200,
                body: DocxImporter.buildTemplate(),
                contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                extraHeaders: ["Content-Disposition": "attachment; filename=\"test_template.docx\""]
            )
        }
        if path == "/api/network" {
            let ips = NetworkUtils.getLocalIPs()
            refreshEndpoints()
            return sendJSON(fd: fd, obj: [
                "ips": ips,
                "port": port,
                "public_url": tunnel.publicURL,
                "tunnel_status": tunnel.status
            ])
        }
        if path == "/api/groups" { return sendJSON(fd: fd, obj: ["groups": db.listGroups()]) }
        if path == "/api/tests" { return sendJSON(fd: fd, obj: ["tests": db.listTests()]) }
        if path == "/api/session/active" { return sendJSON(fd: fd, obj: db.getActiveSessionPayload()) }
        if path.hasPrefix("/api/attempts/") && path.hasSuffix("/details") {
            guard let aid = pathId(from: path, index: 2) else { return sendJSON(fd: fd, status: 400, obj: ["error": "Invalid id"]) }
            guard let details = db.attemptDetails(id: aid) else { return sendJSON(fd: fd, status: 404, obj: ["error": "Not found"]) }
            return sendJSON(fd: fd, obj: details)
        }
        if path == "/api/journal" {
            return sendJSON(fd: fd, obj: db.getJournal(
                groupFilter: (req.query["group"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                testFilter: (req.query["test"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                search: (req.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        if path == "/api/journal/export" {
            let csvData = db.exportJournalCSV(
                groupFilter: (req.query["group"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                testFilter: (req.query["test"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let stamp = NetworkUtils.nowISO().replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "_")
            return sendBytes(fd: fd, status: 200, body: csvData, contentType: "text/csv; charset=utf-8", extraHeaders: ["Content-Disposition": "attachment; filename=\"vedomost_\(stamp).csv\""])
        }
        if path == "/api/settings" { return sendJSON(fd: fd, obj: db.getSettingsDict()) }
        if path == "/api/backup" {
            let stamp = NetworkUtils.nowISO().replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "_")
            return sendBytes(fd: fd, status: 200, body: db.backupData(), contentType: "application/octet-stream", extraHeaders: ["Content-Disposition": "attachment; filename=\"classtest_backup_\(stamp).db\""])
        }
        sendJSON(fd: fd, status: 404, obj: ["error": "Not found"])
    }

    private func routePOST(fd: Int32, req: HTTPRequest) {
        let path = req.path
        let data = parseBodyJSON(req.body)

        if path == "/api/auth/login" {
            guard let tok = db.loginTeacher(password: (data["password"] as? String) ?? "") else {
                return sendJSON(fd: fd, status: 401, obj: ["error": "Неверный пароль"])
            }
            return sendJSON(fd: fd, obj: ["ok": true], extraHeaders: ["Set-Cookie": "ct_auth=\(tok); Path=/; HttpOnly; SameSite=Lax"])
        }
        if path == "/api/auth/logout" {
            db.logoutTeacher(token: teacherToken(from: req))
            return sendJSON(fd: fd, obj: ["ok": true], extraHeaders: ["Set-Cookie": "ct_auth=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"])
        }

        if path == "/api/student/join" {
            let res = db.studentJoin(name: (data["student_name"] as? String) ?? "")
            if let err = res.error { return sendJSON(fd: fd, status: 400, obj: ["error": err]) }
            if let ev = res.teacherEvent { broker.emitTeacher(event: "attempt_update", data: ev) }
            return sendJSON(fd: fd, obj: res.response)
        }
        if path == "/api/student/progress" {
            let tok = ((data["token"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tok.isEmpty, let answers = data["answers"] as? [String: Any] else { return sendJSON(fd: fd, status: 400, obj: ["error": "Bad request"]) }
            let res = db.studentProgress(token: tok, answers: answers)
            if let ev = res.teacherEvent { broker.emitTeacher(event: "attempt_update", data: ev) }
            return sendJSON(fd: fd, obj: ["ok": res.ok])
        }
        if path == "/api/student/submit" {
            let tok = ((data["token"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if tok.isEmpty { return sendJSON(fd: fd, status: 400, obj: ["error": "Missing token"]) }
            let res = db.studentSubmit(token: tok, answers: data["answers"] as? [String: Any])
            if res.notFound { return sendJSON(fd: fd, status: 404, obj: ["error": "Not found"]) }
            if let ev = res.teacherEvent { broker.emitTeacher(event: "attempt_update", data: ev) }
            return sendJSON(fd: fd, obj: res.response)
        }
        if path == "/api/student/violation" {
            let tok = ((data["token"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if tok.isEmpty { return sendJSON(fd: fd, status: 400, obj: ["ok": false]) }
            let res = db.studentViolation(token: tok, reason: (data["reason"] as? String) ?? "Выход из окна теста", answers: data["answers"] as? [String: Any])
            if let att = res.teacherAttempt { broker.emitTeacher(event: "attempt_update", data: att) }
            if let alert = res.alert {
                broker.emitTeacher(event: "violation_alert", data: alert)
                if (db.getSettingsDict()["sound_enabled"] as? Bool) ?? true {
                    DispatchQueue.main.async { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
                }
            }
            return sendJSON(fd: fd, obj: res.response)
        }

        if !requireTeacher(fd: fd, req: req) { return }

        if path == "/api/groups" {
            let name = (data["name"] as? String) ?? ""
            let students = ((data["students"] as? [Any]) ?? []).map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let res = db.createGroup(name: name, students: students)
            if let err = res.error { return sendJSON(fd: fd, status: 400, obj: ["error": err]) }
            return sendJSON(fd: fd, status: 201, obj: ["id": res.id ?? 0, "name": name, "students": students])
        }
        if path == "/api/tests" {
            let res = db.saveTest(data, testId: nil)
            if let err = res.error { return sendJSON(fd: fd, status: 400, obj: ["error": err]) }
            return sendJSON(fd: fd, obj: ["id": res.id ?? 0, "ok": true])
        }
        if path == "/api/tests/import-docx" {
            let filename = (req.query["filename"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let titleOverride = (req.query["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let parsed = try DocxImporter.parseDocxTest(raw: req.body, filename: filename, titleOverride: titleOverride)
                let qs = (parsed["questions"] as? [[String: Any]]) ?? []
                if qs.isEmpty {
                    let warns = (parsed["warnings"] as? [String]) ?? []
                    let msg = warns.isEmpty
                        ? "В файле не найдено ни одного вопроса. Ожидается формат: «1. Текст вопроса» и варианты «А) …»."
                        : "Вопросы не распознаны: " + warns.prefix(3).joined(separator: "; ")
                    return sendJSON(fd: fd, status: 400, obj: ["error": msg, "warnings": warns])
                }
                let res = db.saveTest(parsed, testId: nil)
                if let err = res.error { return sendJSON(fd: fd, status: 400, obj: ["error": err]) }
                return sendJSON(fd: fd, obj: [
                    "ok": true,
                    "id": res.id ?? 0,
                    "title": parsed["title"] ?? "",
                    "questions_count": qs.count,
                    "warnings": parsed["warnings"] ?? []
                ])
            } catch {
                return sendJSON(fd: fd, status: 400, obj: ["error": error.localizedDescription])
            }
        }
        if path.hasPrefix("/api/tests/") && path.hasSuffix("/duplicate") {
            guard let tid = pathId(from: path, index: 2) else { return sendJSON(fd: fd, status: 400, obj: ["error": "Invalid id"]) }
            guard let newId = db.duplicateTest(id: tid) else { return sendJSON(fd: fd, status: 404, obj: ["error": "Тест не найден"]) }
            return sendJSON(fd: fd, obj: ["id": newId, "ok": true])
        }
        if path == "/api/session/start" {
            let res = db.startSession(data)
            if let err = res.error { return sendJSON(fd: fd, status: 400, obj: ["error": err]) }
            let sid = res.sessionId ?? 0
            broker.emitStudents(event: "session_changed", data: ["active": true, "session_id": sid])
            broker.emitTeacher(event: "session_changed", data: ["active": true, "session_id": sid])
            return sendJSON(fd: fd, obj: ["ok": true, "session_id": sid])
        }
        if path == "/api/session/stop" {
            if let sid = db.stopActiveSession() {
                broker.emitStudents(event: "session_ended", data: ["session_id": sid])
                broker.emitTeacher(event: "session_changed", data: ["active": false])
            }
            return sendJSON(fd: fd, obj: ["ok": true])
        }
        if path.hasPrefix("/api/attempts/") && path.hasSuffix("/unblock") {
            guard let aid = pathId(from: path, index: 2) else { return sendJSON(fd: fd, status: 400, obj: ["error": "Invalid id"]) }
            let res = db.unblockAttempt(id: aid)
            if let err = res.error { return sendJSON(fd: fd, status: 400, obj: ["error": err]) }
            if let att = res.teacherAttempt { broker.emitTeacher(event: "attempt_update", data: att) }
            if let stTok = res.studentToken { broker.emitStudents(event: "unblock", data: ["ok": true], token: stTok) }
            return sendJSON(fd: fd, obj: ["ok": true])
        }
        if path.hasPrefix("/api/attempts/") && path.hasSuffix("/dismiss") {
            guard let aid = pathId(from: path, index: 2) else { return sendJSON(fd: fd, status: 400, obj: ["error": "Invalid id"]) }
            if let att = db.dismissAlert(attemptId: aid) { broker.emitTeacher(event: "attempt_update", data: att) }
            return sendJSON(fd: fd, obj: ["ok": true])
        }
        if path.hasPrefix("/api/attempts/") && path.hasSuffix("/grade") {
            guard let aid = pathId(from: path, index: 2) else { return sendJSON(fd: fd, status: 400, obj: ["error": "Invalid id"]) }
            let grade = ((data["grade"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let att = db.setManualGrade(attemptId: aid, grade: grade) { broker.emitTeacher(event: "attempt_update", data: att) }
            return sendJSON(fd: fd, obj: ["ok": true])
        }
        if path == "/api/settings" {
            db.updateSettings(data)
            return sendJSON(fd: fd, obj: ["ok": true])
        }
        if path == "/api/settings/password" {
            if let err = db.updatePassword(oldPw: (data["old_password"] as? String) ?? "", newPw: (data["new_password"] as? String) ?? "") {
                return sendJSON(fd: fd, status: 400, obj: ["error": err])
            }
            return sendJSON(fd: fd, obj: ["ok": true])
        }
        sendJSON(fd: fd, status: 404, obj: ["error": "Not found"])
    }

    private func routePUT(fd: Int32, req: HTTPRequest) {
        if !requireTeacher(fd: fd, req: req) { return }
        let path = req.path
        let data = parseBodyJSON(req.body)

        if path.hasPrefix("/api/groups/") {
            guard let gid = pathId(from: path, index: 2) else { return sendJSON(fd: fd, status: 400, obj: ["error": "Invalid id"]) }
            let students = ((data["students"] as? [Any]) ?? []).map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if let err = db.updateGroup(id: gid, name: (data["name"] as? String) ?? "", students: students) {
                return sendJSON(fd: fd, status: 400, obj: ["error": err])
            }
            return sendJSON(fd: fd, obj: ["ok": true])
        }
        if path.hasPrefix("/api/tests/") {
            guard let tid = pathId(from: path, index: 2) else { return sendJSON(fd: fd, status: 400, obj: ["error": "Invalid id"]) }
            let res = db.saveTest(data, testId: tid)
            if let err = res.error { return sendJSON(fd: fd, status: 400, obj: ["error": err]) }
            return sendJSON(fd: fd, obj: ["id": tid, "ok": true])
        }
        sendJSON(fd: fd, status: 404, obj: ["error": "Not found"])
    }

    private func routeDELETE(fd: Int32, req: HTTPRequest) {
        if !requireTeacher(fd: fd, req: req) { return }
        let path = req.path
        if path.hasPrefix("/api/groups/"), let gid = pathId(from: path, index: 2) { db.deleteGroup(id: gid); return sendJSON(fd: fd, obj: ["ok": true]) }
        if path.hasPrefix("/api/tests/"), let tid = pathId(from: path, index: 2) { db.deleteTest(id: tid); return sendJSON(fd: fd, obj: ["ok": true]) }
        if path.hasPrefix("/api/attempts/"), let aid = pathId(from: path, index: 2) { db.deleteAttempt(id: aid); return sendJSON(fd: fd, obj: ["ok": true]) }
        sendJSON(fd: fd, status: 404, obj: ["error": "Not found"])
    }
}
