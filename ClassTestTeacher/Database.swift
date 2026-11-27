import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Database {
    let dbURL: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    static let defaultScale10: [[String: Any]] = [
        ["grade": "10", "min": 95],
        ["grade": "9", "min": 88],
        ["grade": "8", "min": 80],
        ["grade": "7", "min": 70],
        ["grade": "6", "min": 60],
        ["grade": "5", "min": 50],
        ["grade": "4", "min": 40],
        ["grade": "3", "min": 25],
        ["grade": "2", "min": 15],
        ["grade": "1", "min": 0]
    ]

    static let defaultScale5: [[String: Any]] = [
        ["grade": "5", "min": 85],
        ["grade": "4", "min": 70],
        ["grade": "3", "min": 50],
        ["grade": "2", "min": 0]
    ]

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.dbURL = docs.appendingPathComponent("classtest.db")
        openAndInit()
    }

    deinit {
        lock.lock()
        if let db { sqlite3_close(db) }
        db = nil
        lock.unlock()
    }

    private func openAndInit() {
        lock.lock()
        defer { lock.unlock() }

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &db, flags, nil) != SQLITE_OK {
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")

        let schema = """
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS auth_tokens (
            token TEXT PRIMARY KEY,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            students_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            time_limit INTEGER NOT NULL DEFAULT 0,
            grading_scale TEXT NOT NULL DEFAULT 'default',
            shuffle_questions INTEGER NOT NULL DEFAULT 0,
            shuffle_options INTEGER NOT NULL DEFAULT 0,
            questions_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            test_id INTEGER,
            test_title TEXT NOT NULL,
            group_id INTEGER,
            group_name TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            time_limit INTEGER NOT NULL DEFAULT 0,
            violation_action TEXT NOT NULL DEFAULT 'grade',
            violation_grade TEXT NOT NULL DEFAULT '2',
            require_fullscreen INTEGER NOT NULL DEFAULT 0,
            block_printscreen INTEGER NOT NULL DEFAULT 1,
            grading_scale TEXT NOT NULL DEFAULT '10',
            questions_snapshot_json TEXT NOT NULL,
            shuffle_questions INTEGER NOT NULL DEFAULT 0,
            shuffle_options INTEGER NOT NULL DEFAULT 0,
            started_at TEXT NOT NULL,
            ended_at TEXT
        );
        CREATE TABLE IF NOT EXISTS attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            student_name TEXT NOT NULL,
            student_name_norm TEXT NOT NULL,
            token TEXT UNIQUE NOT NULL,
            status TEXT NOT NULL DEFAULT 'in_progress',
            answers_json TEXT NOT NULL DEFAULT '{}',
            question_order_json TEXT NOT NULL DEFAULT '[]',
            option_orders_json TEXT NOT NULL DEFAULT '{}',
            score REAL NOT NULL DEFAULT 0,
            max_score REAL NOT NULL DEFAULT 0,
            percent REAL NOT NULL DEFAULT 0,
            grade TEXT NOT NULL DEFAULT '',
            grade_manual INTEGER NOT NULL DEFAULT 0,
            violation_reason TEXT NOT NULL DEFAULT '',
            violation_time TEXT NOT NULL DEFAULT '',
            violation_count INTEGER NOT NULL DEFAULT 0,
            unlock_count INTEGER NOT NULL DEFAULT 0,
            answered_count INTEGER NOT NULL DEFAULT 0,
            alert_dismissed INTEGER NOT NULL DEFAULT 0,
            started_at TEXT NOT NULL,
            finished_at TEXT,
            last_seen TEXT NOT NULL,
            UNIQUE(session_id, student_name_norm)
        );
        """
        exec(schema)

        if getSetting("password_salt") == nil {
            let salt = NetworkUtils.randomHex(bytes: 16)
            setSetting("password_salt", value: salt, ignoreExisting: true)
            setSetting("password_hash", value: NetworkUtils.sha256Hex("\(salt):1234"), ignoreExisting: true)
        }
        setSetting("grading_scale", value: "10", ignoreExisting: true)
        setSetting("scale_10", value: jsonString(Self.defaultScale10), ignoreExisting: true)
        setSetting("scale_5", value: jsonString(Self.defaultScale5), ignoreExisting: true)
        setSetting("sound_enabled", value: "1", ignoreExisting: true)
        setSetting("default_violation_grade", value: "2", ignoreExisting: true)

        if queryInt("SELECT COUNT(*) FROM groups") == 0 {
            runUpdate(
                "INSERT INTO groups (name, students_json, created_at) VALUES (?, ?, ?)",
                params: ["Т-691", "[]", NetworkUtils.nowISO()]
            )
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bind(_ stmt: OpaquePointer?, params: [Any?]) {
        for (i, val) in params.enumerated() {
            let idx = Int32(i + 1)
            if val == nil || val is NSNull {
                sqlite3_bind_null(stmt, idx)
            } else if let s = val as? String {
                s.withCString { sqlite3_bind_text(stmt, idx, $0, -1, SQLITE_TRANSIENT) }
            } else if let n = val as? Int {
                sqlite3_bind_int64(stmt, idx, Int64(n))
            } else if let n = val as? Int64 {
                sqlite3_bind_int64(stmt, idx, n)
            } else if let d = val as? Double {
                sqlite3_bind_double(stmt, idx, d)
            } else if let b = val as? Bool {
                sqlite3_bind_int(stmt, idx, b ? 1 : 0)
            } else {
                String(describing: val!).withCString { sqlite3_bind_text(stmt, idx, $0, -1, SQLITE_TRANSIENT) }
            }
        }
    }

    private func queryRows(_ sql: String, params: [Any?] = []) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params: params)

        var results: [[String: Any]] = []
        let colCount = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for c in 0..<colCount {
                guard let namePtr = sqlite3_column_name(stmt, c) else { continue }
                let colName = String(cString: namePtr)
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER:
                    row[colName] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT:
                    row[colName] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT:
                    row[colName] = sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? ""
                case SQLITE_NULL:
                    row[colName] = NSNull()
                default:
                    row[colName] = ""
                }
            }
            results.append(row)
        }
        return results
    }

    private func queryInt(_ sql: String, params: [Any?] = []) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params: params)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    @discardableResult
    private func runUpdate(_ sql: String, params: [Any?] = []) -> (ok: Bool, lastId: Int, code: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return (false, 0, SQLITE_ERROR) }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK else { return (false, 0, prep) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params: params)
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_DONE ? (true, Int(sqlite3_last_insert_rowid(db)), rc) : (false, 0, rc)
    }

    func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    func parseJSONArray(_ str: String) -> [Any] {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let arr = obj as? [Any] else { return [] }
        return arr
    }

    func parseJSONDict(_ str: String) -> [String: Any] {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    private func strVal(_ dict: [String: Any], _ key: String, default def: String = "") -> String {
        if let s = dict[key] as? String { return s }
        if let n = dict[key] as? NSNumber { return n.stringValue }
        return def
    }

    private func intVal(_ dict: [String: Any], _ key: String, default def: Int = 0) -> Int {
        if let i = dict[key] as? Int { return i }
        if let d = dict[key] as? Double { return Int(d) }
        if let s = dict[key] as? String, let i = Int(s) { return i }
        return def
    }

    private func dblVal(_ dict: [String: Any], _ key: String, default def: Double = 0) -> Double {
        if let d = dict[key] as? Double { return d }
        if let i = dict[key] as? Int { return Double(i) }
        if let s = dict[key] as? String, let d = Double(s) { return d }
        return def
    }

    private func cleanNumber(_ v: Double) -> Any {
        v.rounded() == v ? Int(v) : (v * 100).rounded() / 100
    }

    // MARK: - Settings & Auth

    func getSetting(_ key: String) -> String? {
        queryRows("SELECT value FROM settings WHERE key=?", params: [key]).first?["value"] as? String
    }

    func setSetting(_ key: String, value: String, ignoreExisting: Bool = false) {
        let sql = ignoreExisting
            ? "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)"
            : "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)"
        runUpdate(sql, params: [key, value])
    }

    func getSettingsDict() -> [String: Any] {
        var map: [String: String] = [:]
        for r in queryRows("SELECT key, value FROM settings") {
            if let k = r["key"] as? String, let v = r["value"] as? String { map[k] = v }
        }
        return [
            "grading_scale": map["grading_scale"] ?? "10",
            "scale_10": parseJSONArray(map["scale_10"] ?? jsonString(Self.defaultScale10)),
            "scale_5": parseJSONArray(map["scale_5"] ?? jsonString(Self.defaultScale5)),
            "sound_enabled": (map["sound_enabled"] ?? "1") == "1",
            "default_violation_grade": map["default_violation_grade"] ?? "2"
        ]
    }

    func updateSettings(_ data: [String: Any]) {
        if let sc = data["grading_scale"] as? String, ["10", "5", "points"].contains(sc) {
            setSetting("grading_scale", value: sc)
        }
        if let snd = data["sound_enabled"] as? Bool {
            setSetting("sound_enabled", value: snd ? "1" : "0")
        }
        if let s10 = data["scale_10"] as? [Any] { setSetting("scale_10", value: jsonString(s10)) }
        if let s5 = data["scale_5"] as? [Any] { setSetting("scale_5", value: jsonString(s5)) }
    }

    func updatePassword(oldPw: String, newPw: String) -> String? {
        let trimmed = newPw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 3 { return "Минимум 3 символа" }
        guard let salt = getSetting("password_salt"), let stored = getSetting("password_hash") else {
            return "Ошибка настроек"
        }
        if NetworkUtils.sha256Hex("\(salt):\(oldPw)") != stored { return "Текущий пароль неверен" }
        let newSalt = NetworkUtils.randomHex(bytes: 16)
        setSetting("password_salt", value: newSalt)
        setSetting("password_hash", value: NetworkUtils.sha256Hex("\(newSalt):\(trimmed)"))
        return nil
    }

    func loginTeacher(password: String) -> String? {
        guard let salt = getSetting("password_salt"), let stored = getSetting("password_hash"),
              NetworkUtils.sha256Hex("\(salt):\(password)") == stored else { return nil }
        return issueLocalTeacherToken()
    }

    func issueLocalTeacherToken() -> String {
        let token = NetworkUtils.randomHex(bytes: 32)
        runUpdate("INSERT INTO auth_tokens (token, created_at) VALUES (?, ?)", params: [token, NetworkUtils.nowISO()])
        return token
    }

    func isTeacherTokenValid(_ token: String) -> Bool {
        !token.isEmpty && queryInt("SELECT COUNT(*) FROM auth_tokens WHERE token=?", params: [token]) > 0
    }

    func logoutTeacher(token: String) {
        if !token.isEmpty { runUpdate("DELETE FROM auth_tokens WHERE token=?", params: [token]) }
    }

    func backupData() -> Data {
        lock.lock()
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
        let data = (try? Data(contentsOf: dbURL)) ?? Data()
        lock.unlock()
        return data
    }

    // MARK: - Groups

    func listGroups() -> [[String: Any]] {
        let rows = queryRows("SELECT * FROM groups ORDER BY name COLLATE NOCASE")
        var counts: [Int: Int] = [:]
        for cr in queryRows("SELECT group_id, COUNT(*) as cnt FROM sessions GROUP BY group_id") {
            counts[intVal(cr, "group_id")] = intVal(cr, "cnt")
        }
        return rows.map { r in
            let gid = intVal(r, "id")
            return [
                "id": gid,
                "name": strVal(r, "name"),
                "students": parseJSONArray(strVal(r, "students_json", default: "[]")),
                "sessions_count": counts[gid] ?? 0,
                "created_at": strVal(r, "created_at")
            ]
        }
    }

    func createGroup(name: String, students: [String]) -> (id: Int?, error: String?) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return (nil, "Введите название группы") }
        let res = runUpdate(
            "INSERT INTO groups (name, students_json, created_at) VALUES (?, ?, ?)",
            params: [clean, jsonString(students), NetworkUtils.nowISO()]
        )
        return res.ok ? (res.lastId, nil) : (nil, "Группа с таким названием уже существует")
    }

    func updateGroup(id: Int, name: String, students: [String]) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return "Введите название группы" }
        let res = runUpdate(
            "UPDATE groups SET name=?, students_json=? WHERE id=?",
            params: [clean, jsonString(students), id]
        )
        return res.ok ? nil : "Группа с таким названием уже существует"
    }

    func deleteGroup(id: Int) {
        runUpdate("DELETE FROM groups WHERE id=?", params: [id])
    }

    // MARK: - Tests

    func listTests() -> [[String: Any]] {
        queryRows("SELECT * FROM tests ORDER BY updated_at DESC, id DESC").map { r in
            let qs = parseJSONArray(strVal(r, "questions_json", default: "[]"))
            return [
                "id": intVal(r, "id"),
                "title": strVal(r, "title"),
                "time_limit": intVal(r, "time_limit"),
                "grading_scale": strVal(r, "grading_scale", default: "default"),
                "shuffle_questions": intVal(r, "shuffle_questions") != 0,
                "shuffle_options": intVal(r, "shuffle_options") != 0,
                "questions": qs,
                "questions_count": qs.count,
                "created_at": strVal(r, "created_at"),
                "updated_at": strVal(r, "updated_at")
            ]
        }
    }

    func saveTest(_ data: [String: Any], testId: Int?) -> (id: Int?, error: String?) {
        let title = strVal(data, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return (nil, "Введите название теста") }
        guard let rawQs = data["questions"] as? [[String: Any]], !rawQs.isEmpty else {
            return (nil, "Добавьте хотя бы один вопрос")
        }

        var cleaned: [[String: Any]] = []
        for (idx, q) in rawQs.enumerated() {
            let qtext = strVal(q, "text").trimmingCharacters(in: .whitespacesAndNewlines)
            if qtext.isEmpty { return (nil, "Вопрос \(idx + 1): заполните текст вопроса") }
            var qtype = strVal(q, "type", default: "single")
            if !["single", "multiple", "text"].contains(qtype) { qtype = "single" }
            var pts = dblVal(q, "points", default: 1)
            if pts <= 0 { pts = 1 }
            let qid = strVal(q, "id").isEmpty ? "q\(idx + 1)_\(NetworkUtils.randomHex(bytes: 3))" : strVal(q, "id")
            var item: [String: Any] = ["id": qid, "type": qtype, "text": qtext, "points": cleanNumber(pts)]

            if qtype == "single" || qtype == "multiple" {
                let opts = ((q["options"] as? [Any]) ?? []).map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
                if opts.count < 2 || opts.contains(where: { $0.isEmpty }) {
                    return (nil, "Вопрос \(idx + 1): нужно минимум 2 непустых варианта ответа")
                }
                var corr: [Int] = []
                for c in (q["correct"] as? [Any]) ?? [] {
                    let ci = (c as? Int) ?? (c as? Double).map(Int.init) ?? (c as? String).flatMap(Int.init)
                    if let ci, ci >= 0 && ci < opts.count { corr.append(ci) }
                }
                if corr.isEmpty { return (nil, "Вопрос \(idx + 1): выберите правильный ответ") }
                item["options"] = opts
                item["correct"] = qtype == "single" ? [corr[0]] : Array(Set(corr)).sorted()
            } else {
                let acc = strVal(q, "acceptedText").trimmingCharacters(in: .whitespacesAndNewlines)
                if acc.isEmpty { return (nil, "Вопрос \(idx + 1): укажите правильный текстовый ответ") }
                item["acceptedText"] = acc
            }
            cleaned.append(item)
        }

        let timeLimit = max(0, intVal(data, "time_limit", default: 0))
        var scale = strVal(data, "grading_scale", default: "default")
        if !["default", "10", "5", "points"].contains(scale) { scale = "default" }
        let shQ = ((data["shuffle_questions"] as? Bool) ?? false) ? 1 : 0
        let shO = ((data["shuffle_options"] as? Bool) ?? false) ? 1 : 0
        let now = NetworkUtils.nowISO()
        let qsJson = jsonString(cleaned)

        if let tid = testId {
            runUpdate(
                "UPDATE tests SET title=?, time_limit=?, grading_scale=?, shuffle_questions=?, shuffle_options=?, questions_json=?, updated_at=? WHERE id=?",
                params: [title, timeLimit, scale, shQ, shO, qsJson, now, tid]
            )
            return (tid, nil)
        }
        let res = runUpdate(
            "INSERT INTO tests (title, time_limit, grading_scale, shuffle_questions, shuffle_options, questions_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params: [title, timeLimit, scale, shQ, shO, qsJson, now, now]
        )
        return (res.lastId, nil)
    }

    func duplicateTest(id: Int) -> Int? {
        guard let row = queryRows("SELECT * FROM tests WHERE id=?", params: [id]).first else { return nil }
        let now = NetworkUtils.nowISO()
        let res = runUpdate(
            "INSERT INTO tests (title, time_limit, grading_scale, shuffle_questions, shuffle_options, questions_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params: [
                strVal(row, "title") + " (копия)", intVal(row, "time_limit"),
                strVal(row, "grading_scale", default: "default"), intVal(row, "shuffle_questions"),
                intVal(row, "shuffle_options"), strVal(row, "questions_json", default: "[]"), now, now
            ]
        )
        return res.ok ? res.lastId : nil
    }

    func deleteTest(id: Int) {
        runUpdate("DELETE FROM tests WHERE id=?", params: [id])
    }

    // MARK: - Scoring & Serialization

    func calculateScoreAndGrade(
        questions: [[String: Any]],
        answers: [String: Any],
        scaleMode: String,
        settings: [String: Any]
    ) -> (score: Any, maxScore: Any, scoreDouble: Double, maxDouble: Double, percent: Double, grade: String) {
        var score: Double = 0
        var maxScore: Double = 0

        for q in questions {
            let qid = strVal(q, "id")
            let pts = max(0.0, dblVal(q, "points", default: 1))
            maxScore += pts
            let ans = answers[qid]
            let qtype = strVal(q, "type", default: "single")

            if qtype == "single" {
                let corrArr = (q["correct"] as? [Any]) ?? []
                if let ans, !(ans is NSNull), corrArr.count == 1 {
                    let a = (ans as? Int) ?? (ans as? Double).map(Int.init) ?? (ans as? String).flatMap(Int.init)
                    let c = (corrArr[0] as? Int) ?? (corrArr[0] as? Double).map(Int.init)
                    if let a, let c, a == c { score += pts }
                }
            } else if qtype == "multiple" {
                let corr = ((q["correct"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }.sorted()
                if let ansList = ans as? [Any], !corr.isEmpty {
                    let picked = ansList.compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) ?? ($0 as? String).flatMap(Int.init) }.sorted()
                    if picked == corr { score += pts }
                }
            } else if qtype == "text" {
                let accepted = strVal(q, "acceptedText")
                    .replacingOccurrences(of: ";", with: ",")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                if let s = ans as? String, accepted.contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                    score += pts
                }
            }
        }

        let percent = maxScore > 0 ? ((score / maxScore) * 1000).rounded() / 10.0 : 0.0
        let scClean = cleanNumber(score)
        let mxClean = cleanNumber(maxScore)

        let grade: String
        if scaleMode == "points" {
            grade = "\(scClean)/\(mxClean)"
        } else {
            let rawThresholds = (scaleMode == "5" ? settings["scale_5"] : settings["scale_10"]) as? [[String: Any]] ?? []
            let sorted = rawThresholds.sorted { dblVal($0, "min") > dblVal($1, "min") }
            var found = sorted.last.map { strVal($0, "grade", default: "1") } ?? "1"
            for item in sorted {
                if percent >= dblVal(item, "min") {
                    found = strVal(item, "grade", default: found)
                    break
                }
            }
            grade = found
        }
        return (scClean, mxClean, score, maxScore, percent, grade)
    }

    func serializeAttempt(_ row: [String: Any], totalQuestions: Int) -> [String: Any] {
        [
            "id": intVal(row, "id"),
            "session_id": intVal(row, "session_id"),
            "student_name": strVal(row, "student_name"),
            "status": strVal(row, "status", default: "in_progress"),
            "score": cleanNumber(dblVal(row, "score")),
            "max_score": cleanNumber(dblVal(row, "max_score")),
            "percent": dblVal(row, "percent"),
            "grade": strVal(row, "grade"),
            "grade_manual": intVal(row, "grade_manual") != 0,
            "violation_reason": strVal(row, "violation_reason"),
            "violation_time": strVal(row, "violation_time"),
            "violation_count": intVal(row, "violation_count"),
            "unlock_count": intVal(row, "unlock_count"),
            "answered_count": intVal(row, "answered_count"),
            "total_questions": totalQuestions,
            "alert_dismissed": intVal(row, "alert_dismissed") != 0,
            "started_at": strVal(row, "started_at"),
            "finished_at": row["finished_at"] ?? NSNull(),
            "last_seen": strVal(row, "last_seen")
        ]
    }

    func getActiveSessionRow() -> [String: Any]? {
        queryRows("SELECT * FROM sessions WHERE status='active' ORDER BY id DESC LIMIT 1").first
    }

    func getActiveSessionPayload() -> [String: Any] {
        guard let sess = getActiveSessionRow() else { return ["session": NSNull(), "attempts": []] }
        let questions = parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]"))
        let attRows = queryRows("SELECT * FROM attempts WHERE session_id=? ORDER BY id ASC", params: [intVal(sess, "id")])
        var sessOut = sess
        sessOut.removeValue(forKey: "questions_snapshot_json")
        sessOut["questions_count"] = questions.count
        return ["session": sessOut, "attempts": attRows.map { serializeAttempt($0, totalQuestions: questions.count) }]
    }

    // MARK: - Sessions

    func startSession(_ data: [String: Any]) -> (sessionId: Int?, error: String?) {
        lock.lock()
        defer { lock.unlock() }

        let gid = intVal(data, "group_id")
        let tid = intVal(data, "test_id")
        if gid <= 0 || tid <= 0 { return (nil, "Выберите группу и тест") }
        if getActiveSessionRow() != nil { return (nil, "Сначала завершите текущую контрольную") }

        var vAction = strVal(data, "violation_action", default: "grade")
        if vAction != "grade" && vAction != "no_grade" { vAction = "grade" }
        let vGrade = strVal(data, "violation_grade", default: "2").trimmingCharacters(in: .whitespacesAndNewlines)
        if vAction == "grade" && vGrade.isEmpty { return (nil, "Укажите оценку за нарушение") }

        let reqFS = ((data["require_fullscreen"] as? Bool) ?? false) ? 1 : 0
        let blockPS = ((data["block_printscreen"] as? Bool) ?? true) ? 1 : 0

        guard let grp = queryRows("SELECT * FROM groups WHERE id=?", params: [gid]).first,
              let tst = queryRows("SELECT * FROM tests WHERE id=?", params: [tid]).first else {
            return (nil, "Группа или тест не найдены")
        }

        let settings = getSettingsDict()
        var scale = strVal(tst, "grading_scale", default: "default")
        if scale == "default" { scale = strVal(settings, "grading_scale", default: "10") }

        let res = runUpdate(
            """
            INSERT INTO sessions (
                test_id, test_title, group_id, group_name, status, time_limit,
                violation_action, violation_grade, require_fullscreen, block_printscreen,
                grading_scale, questions_snapshot_json, shuffle_questions, shuffle_options, started_at
            ) VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            params: [
                intVal(tst, "id"), strVal(tst, "title"), intVal(grp, "id"), strVal(grp, "name"),
                intVal(tst, "time_limit"), vAction, vAction == "grade" ? vGrade : "",
                reqFS, blockPS, scale, strVal(tst, "questions_json", default: "[]"),
                intVal(tst, "shuffle_questions"), intVal(tst, "shuffle_options"), NetworkUtils.nowISO()
            ]
        )
        if vAction == "grade" { setSetting("default_violation_grade", value: vGrade) }
        return (res.lastId, nil)
    }

    func stopActiveSession() -> Int? {
        lock.lock()
        defer { lock.unlock() }

        guard let sess = getActiveSessionRow() else { return nil }
        let sessId = intVal(sess, "id")
        let settings = getSettingsDict()
        let questions = (parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]")) as? [[String: Any]]) ?? []
        let now = NetworkUtils.nowISO()

        for att in queryRows("SELECT * FROM attempts WHERE session_id=? AND status='in_progress'", params: [sessId]) {
            let answers = parseJSONDict(strVal(att, "answers_json", default: "{}"))
            let calc = calculateScoreAndGrade(questions: questions, answers: answers, scaleMode: strVal(sess, "grading_scale", default: "10"), settings: settings)
            runUpdate(
                "UPDATE attempts SET status='submitted', score=?, max_score=?, percent=?, grade=?, finished_at=? WHERE id=?",
                params: [calc.scoreDouble, calc.maxDouble, calc.percent, calc.grade, now, intVal(att, "id")]
            )
        }
        runUpdate("UPDATE sessions SET status='finished', ended_at=? WHERE id=?", params: [now, sessId])
        return sessId
    }

    // MARK: - Student Logic

    private func buildStudentQuestions(questions: [[String: Any]], qOrder: [String], optOrders: [String: [Int]]) -> [[String: Any]] {
        var qMap: [String: [String: Any]] = [:]
        for q in questions { qMap[strVal(q, "id")] = q }
        var out: [[String: Any]] = []
        for qid in qOrder {
            guard let q = qMap[qid] else { continue }
            let qtype = strVal(q, "type", default: "single")
            var item: [String: Any] = ["id": qid, "type": qtype, "text": strVal(q, "text"), "points": q["points"] ?? 1]
            if qtype == "single" || qtype == "multiple" {
                let rawOpts = ((q["options"] as? [Any]) ?? []).map { String(describing: $0) }
                let order = optOrders[qid] ?? Array(0..<rawOpts.count)
                item["options"] = order.compactMap { ($0 >= 0 && $0 < rawOpts.count) ? ["index": $0, "text": rawOpts[$0]] : nil }
            }
            out.append(item)
        }
        return out
    }

    private func computeRemainingSeconds(session: [String: Any], attempt: [String: Any]) -> Any {
        let limitMin = intVal(session, "time_limit")
        if limitMin <= 0 { return NSNull() }
        guard let started = NetworkUtils.parseISO(strVal(attempt, "started_at")) else { return limitMin * 60 }
        return max(0, Int(Double(limitMin * 60) - Date().timeIntervalSince(started)))
    }

    private func countAnswered(_ answers: [String: Any]) -> Int {
        var cnt = 0
        for (_, v) in answers {
            if let arr = v as? [Any] { if !arr.isEmpty { cnt += 1 } }
            else if !(v is NSNull), !String(describing: v).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cnt += 1 }
        }
        return cnt
    }

    func getStudentStatus(token: String) -> [String: Any] {
        let sess = getActiveSessionRow()
        var attempt: [String: Any]? = nil

        if !token.isEmpty, let attRow = queryRows("SELECT * FROM attempts WHERE token=?", params: [token]).first {
            if let sess, intVal(attRow, "session_id") == intVal(sess, "id") {
                attempt = attRow
            } else if sess == nil, let sRow = queryRows("SELECT * FROM sessions WHERE id=?", params: [intVal(attRow, "session_id")]).first {
                let st = strVal(attRow, "status")
                if st == "submitted" || st == "violated" {
                    return [
                        "active": false,
                        "recent_result": [
                            "test_title": strVal(sRow, "test_title"),
                            "group_name": strVal(sRow, "group_name"),
                            "student_name": strVal(attRow, "student_name"),
                            "status": st,
                            "score": cleanNumber(dblVal(attRow, "score")),
                            "max_score": cleanNumber(dblVal(attRow, "max_score")),
                            "percent": dblVal(attRow, "percent"),
                            "grade": strVal(attRow, "grade"),
                            "violation_reason": strVal(attRow, "violation_reason")
                        ]
                    ]
                }
            }
        }

        guard let sess else { return ["active": false] }
        let grp = queryRows("SELECT students_json FROM groups WHERE id=?", params: [intVal(sess, "group_id")]).first
        let roster = grp.map { parseJSONArray(strVal($0, "students_json", default: "[]")) } ?? []
        let questions = (parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]")) as? [[String: Any]]) ?? []
        let taken = queryRows("SELECT student_name FROM attempts WHERE session_id=?", params: [intVal(sess, "id")]).map { strVal($0, "student_name") }

        let sessPublic: [String: Any] = [
            "id": intVal(sess, "id"),
            "test_title": strVal(sess, "test_title"),
            "group_name": strVal(sess, "group_name"),
            "time_limit": intVal(sess, "time_limit"),
            "questions_count": questions.count,
            "require_fullscreen": intVal(sess, "require_fullscreen") != 0,
            "block_printscreen": intVal(sess, "block_printscreen") != 0,
            "violation_action": strVal(sess, "violation_action"),
            "violation_grade": strVal(sess, "violation_grade"),
            "roster": roster,
            "taken_names": taken
        ]

        guard let att = attempt else { return ["active": true, "session": sessPublic, "attempt": NSNull()] }

        let qOrder = (parseJSONArray(strVal(att, "question_order_json", default: "[]")) as? [String]) ?? []
        var optOrders: [String: [Int]] = [:]
        for (k, v) in parseJSONDict(strVal(att, "option_orders_json", default: "{}")) {
            if let arr = v as? [Any] { optOrders[k] = arr.compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) } }
        }
        let st = strVal(att, "status")
        let attPublic: [String: Any] = [
            "token": strVal(att, "token"),
            "student_name": strVal(att, "student_name"),
            "status": st,
            "answers": parseJSONDict(strVal(att, "answers_json", default: "{}")),
            "score": cleanNumber(dblVal(att, "score")),
            "max_score": cleanNumber(dblVal(att, "max_score")),
            "percent": dblVal(att, "percent"),
            "grade": strVal(att, "grade"),
            "violation_reason": strVal(att, "violation_reason"),
            "remaining_seconds": computeRemainingSeconds(session: sess, attempt: att),
            "questions": st == "in_progress" ? buildStudentQuestions(questions: questions, qOrder: qOrder, optOrders: optOrders) : []
        ]
        return ["active": true, "session": sessPublic, "attempt": attPublic]
    }

    func studentJoin(name rawName: String) -> (response: [String: Any], teacherEvent: [String: Any]?, error: String?) {
        lock.lock()
        defer { lock.unlock() }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if name.count < 2 { return ([:], nil, "Введите фамилию и имя") }
        let norm = name.lowercased()

        guard let sess = getActiveSessionRow() else { return ([:], nil, "Нет активной контрольной") }
        let sessId = intVal(sess, "id")
        let questions = (parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]")) as? [[String: Any]]) ?? []

        if let existing = queryRows("SELECT * FROM attempts WHERE session_id=? AND student_name_norm=?", params: [sessId, norm]).first {
            let st = strVal(existing, "status")
            let tok = strVal(existing, "token")
            if st == "violated" {
                return (["token": tok, "status": "violated", "violation_reason": strVal(existing, "violation_reason"), "grade": strVal(existing, "grade")], nil, nil)
            }
            if st == "submitted" {
                return (["token": tok, "status": "submitted", "score": cleanNumber(dblVal(existing, "score")), "max_score": cleanNumber(dblVal(existing, "max_score")), "grade": strVal(existing, "grade")], nil, nil)
            }
            runUpdate("UPDATE attempts SET last_seen=? WHERE id=?", params: [NetworkUtils.nowISO(), intVal(existing, "id")])
            return (["token": tok, "status": "in_progress"], serializeAttempt(existing, totalQuestions: questions.count), nil)
        }

        var qOrder = questions.map { strVal($0, "id") }
        if intVal(sess, "shuffle_questions") != 0 { qOrder.shuffle() }
        var optOrders: [String: [Int]] = [:]
        for q in questions {
            let qt = strVal(q, "type", default: "single")
            if qt == "single" || qt == "multiple" {
                var idxs = Array(0..<((q["options"] as? [Any]) ?? []).count)
                if intVal(sess, "shuffle_options") != 0 { idxs.shuffle() }
                optOrders[strVal(q, "id")] = idxs
            }
        }

        let token = NetworkUtils.randomHex(bytes: 24)
        let now = NetworkUtils.nowISO()
        let maxScore = questions.reduce(0.0) { $0 + max(0.0, dblVal($1, "points", default: 1)) }

        let res = runUpdate(
            "INSERT INTO attempts (session_id, student_name, student_name_norm, token, status, answers_json, question_order_json, option_orders_json, max_score, started_at, last_seen) VALUES (?, ?, ?, ?, 'in_progress', '{}', ?, ?, ?, ?, ?)",
            params: [sessId, name, norm, token, jsonString(qOrder), jsonString(optOrders), maxScore, now, now]
        )
        let row = queryRows("SELECT * FROM attempts WHERE id=?", params: [res.lastId]).first ?? [:]
        return (["token": token, "status": "in_progress"], serializeAttempt(row, totalQuestions: questions.count), nil)
    }

    func studentProgress(token: String, answers: [String: Any]) -> (ok: Bool, teacherEvent: [String: Any]?) {
        lock.lock()
        defer { lock.unlock() }
        guard let att = queryRows("SELECT * FROM attempts WHERE token=?", params: [token]).first,
              strVal(att, "status") == "in_progress",
              let sess = queryRows("SELECT * FROM sessions WHERE id=?", params: [intVal(att, "session_id")]).first else {
            return (false, nil)
        }
        let questions = parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]"))
        runUpdate(
            "UPDATE attempts SET answers_json=?, answered_count=?, last_seen=? WHERE id=?",
            params: [jsonString(answers), countAnswered(answers), NetworkUtils.nowISO(), intVal(att, "id")]
        )
        let updated = queryRows("SELECT * FROM attempts WHERE id=?", params: [intVal(att, "id")]).first ?? att
        return (true, serializeAttempt(updated, totalQuestions: questions.count))
    }

    func studentSubmit(token: String, answers: [String: Any]?) -> (response: [String: Any], teacherEvent: [String: Any]?, notFound: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let att = queryRows("SELECT * FROM attempts WHERE token=?", params: [token]).first else { return ([:], nil, true) }
        if strVal(att, "status") != "in_progress" {
            return (["status": strVal(att, "status"), "score": cleanNumber(dblVal(att, "score")), "max_score": cleanNumber(dblVal(att, "max_score")), "percent": dblVal(att, "percent"), "grade": strVal(att, "grade")], nil, false)
        }
        let sess = queryRows("SELECT * FROM sessions WHERE id=?", params: [intVal(att, "session_id")]).first ?? [:]
        let questions = (parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]")) as? [[String: Any]]) ?? []
        let finalAns = answers ?? parseJSONDict(strVal(att, "answers_json", default: "{}"))
        let calc = calculateScoreAndGrade(questions: questions, answers: finalAns, scaleMode: strVal(sess, "grading_scale", default: "10"), settings: getSettingsDict())
        let now = NetworkUtils.nowISO()
        runUpdate(
            "UPDATE attempts SET status='submitted', answers_json=?, answered_count=?, score=?, max_score=?, percent=?, grade=?, finished_at=?, last_seen=? WHERE id=?",
            params: [jsonString(finalAns), countAnswered(finalAns), calc.scoreDouble, calc.maxDouble, calc.percent, calc.grade, now, now, intVal(att, "id")]
        )
        let updated = queryRows("SELECT * FROM attempts WHERE id=?", params: [intVal(att, "id")]).first ?? att
        return (["status": "submitted", "score": calc.score, "max_score": calc.maxScore, "percent": calc.percent, "grade": calc.grade], serializeAttempt(updated, totalQuestions: questions.count), false)
    }

    func studentViolation(token: String, reason: String, answers: [String: Any]?) -> (response: [String: Any], teacherAttempt: [String: Any]?, alert: [String: Any]?) {
        lock.lock()
        defer { lock.unlock() }
        guard let att = queryRows("SELECT * FROM attempts WHERE token=?", params: [token]).first else {
            return (["ok": true, "status": "none", "grade": ""], nil, nil)
        }
        if strVal(att, "status") != "in_progress" {
            return (["ok": true, "status": strVal(att, "status"), "grade": strVal(att, "grade")], nil, nil)
        }
        let sess = queryRows("SELECT * FROM sessions WHERE id=?", params: [intVal(att, "session_id")]).first ?? [:]
        let questions = (parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]")) as? [[String: Any]]) ?? []
        let finalAns = answers ?? parseJSONDict(strVal(att, "answers_json", default: "{}"))
        let calc = calculateScoreAndGrade(questions: questions, answers: finalAns, scaleMode: strVal(sess, "grading_scale", default: "10"), settings: getSettingsDict())
        let grade = strVal(sess, "violation_action") == "grade" ? strVal(sess, "violation_grade") : "—"
        let now = NetworkUtils.nowISO()
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Выход из окна теста" : reason

        runUpdate(
            "UPDATE attempts SET status='violated', answers_json=?, answered_count=?, score=?, max_score=?, percent=?, grade=?, violation_reason=?, violation_time=?, violation_count=violation_count+1, alert_dismissed=0, finished_at=?, last_seen=? WHERE id=?",
            params: [jsonString(finalAns), countAnswered(finalAns), calc.scoreDouble, calc.maxDouble, calc.percent, grade, cleanReason, now, now, now, intVal(att, "id")]
        )
        let updated = queryRows("SELECT * FROM attempts WHERE id=?", params: [intVal(att, "id")]).first ?? att
        let alert: [String: Any] = ["attempt_id": intVal(updated, "id"), "student_name": strVal(updated, "student_name"), "reason": cleanReason, "time": now, "grade": grade]
        return (["ok": true, "status": "violated", "reason": cleanReason, "grade": grade], serializeAttempt(updated, totalQuestions: questions.count), alert)
    }

    // MARK: - Teacher Attempt Actions

    func unblockAttempt(id: Int) -> (teacherAttempt: [String: Any]?, studentToken: String?, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let att = queryRows("SELECT * FROM attempts WHERE id=?", params: [id]).first else { return (nil, nil, "Попытка не найдена") }
        guard let sess = queryRows("SELECT * FROM sessions WHERE id=?", params: [intVal(att, "session_id")]).first,
              strVal(sess, "status") == "active" else { return (nil, nil, "Контрольная уже завершена") }
        let questions = parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]"))
        runUpdate("UPDATE attempts SET status='in_progress', grade='', grade_manual=0, unlock_count=unlock_count+1, alert_dismissed=1, finished_at=NULL WHERE id=?", params: [id])
        let updated = queryRows("SELECT * FROM attempts WHERE id=?", params: [id]).first ?? att
        return (serializeAttempt(updated, totalQuestions: questions.count), strVal(updated, "token"), nil)
    }

    func dismissAlert(attemptId: Int) -> [String: Any]? {
        runUpdate("UPDATE attempts SET alert_dismissed=1 WHERE id=?", params: [attemptId])
        guard let att = queryRows("SELECT * FROM attempts WHERE id=?", params: [attemptId]).first,
              let sess = queryRows("SELECT questions_snapshot_json FROM sessions WHERE id=?", params: [intVal(att, "session_id")]).first else { return nil }
        return serializeAttempt(att, totalQuestions: parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]")).count)
    }

    func setManualGrade(attemptId: Int, grade: String) -> [String: Any]? {
        runUpdate("UPDATE attempts SET grade=?, grade_manual=1, alert_dismissed=1 WHERE id=?", params: [grade, attemptId])
        guard let att = queryRows("SELECT * FROM attempts WHERE id=?", params: [attemptId]).first,
              let sess = queryRows("SELECT questions_snapshot_json FROM sessions WHERE id=?", params: [intVal(att, "session_id")]).first else { return nil }
        return serializeAttempt(att, totalQuestions: parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]")).count)
    }

    func deleteAttempt(id: Int) {
        runUpdate("DELETE FROM attempts WHERE id=?", params: [id])
    }

    func attemptDetails(id: Int) -> [String: Any]? {
        guard let att = queryRows("SELECT * FROM attempts WHERE id=?", params: [id]).first,
              let sess = queryRows("SELECT * FROM sessions WHERE id=?", params: [intVal(att, "session_id")]).first else { return nil }
        let questions = (parseJSONArray(strVal(sess, "questions_snapshot_json", default: "[]")) as? [[String: Any]]) ?? []
        let answers = parseJSONDict(strVal(att, "answers_json", default: "{}"))
        var breakdown: [[String: Any]] = []

        for q in questions {
            let ans = answers[strVal(q, "id")]
            let qtype = strVal(q, "type", default: "single")
            var isCorrect = false
            var studentDisplay = "Нет ответа"
            var correctDisplay = ""

            if qtype == "single" {
                let opts = ((q["options"] as? [Any]) ?? []).map { String(describing: $0) }
                let corr = ((q["correct"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }
                if let c0 = corr.first, c0 >= 0 && c0 < opts.count { correctDisplay = opts[c0] }
                if let ans, !(ans is NSNull), let idx = (ans as? Int) ?? (ans as? Double).map(Int.init) ?? (ans as? String).flatMap(Int.init), idx >= 0 && idx < opts.count {
                    studentDisplay = opts[idx]
                    isCorrect = (corr.first == idx)
                }
            } else if qtype == "multiple" {
                let opts = ((q["options"] as? [Any]) ?? []).map { String(describing: $0) }
                let corr = ((q["correct"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }.sorted()
                correctDisplay = corr.compactMap { $0 < opts.count ? opts[$0] : nil }.joined(separator: ", ")
                if let arr = ans as? [Any], !arr.isEmpty {
                    let picked = arr.compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) ?? ($0 as? String).flatMap(Int.init) }.sorted()
                    studentDisplay = picked.compactMap { ($0 >= 0 && $0 < opts.count) ? opts[$0] : nil }.joined(separator: ", ")
                    isCorrect = (picked == corr)
                }
            } else if qtype == "text" {
                let accRaw = strVal(q, "acceptedText")
                correctDisplay = accRaw
                let accepted = accRaw.replacingOccurrences(of: ";", with: ",").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
                if let s = ans as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    studentDisplay = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    isCorrect = accepted.contains(studentDisplay.lowercased())
                }
            }
            breakdown.append([
                "text": strVal(q, "text"), "type": qtype, "points": q["points"] ?? 1,
                "student_answer": studentDisplay, "correct_answer": correctDisplay, "is_correct": isCorrect
            ])
        }

        return [
            "attempt": serializeAttempt(att, totalQuestions: questions.count),
            "session": ["test_title": strVal(sess, "test_title"), "group_name": strVal(sess, "group_name"), "started_at": strVal(sess, "started_at")],
            "breakdown": breakdown
        ]
    }

    func getJournal(groupFilter: String, testFilter: String, search: String) -> [String: Any] {
        var sql = "SELECT a.*, s.test_title, s.group_name FROM attempts a JOIN sessions s ON a.session_id = s.id WHERE 1=1"
        var params: [Any?] = []
        if !groupFilter.isEmpty { sql += " AND s.group_name = ?"; params.append(groupFilter) }
        if !testFilter.isEmpty { sql += " AND s.test_title = ?"; params.append(testFilter) }
        sql += " ORDER BY a.id DESC LIMIT 1000"

        let qLower = search.lowercased()
        let records: [[String: Any]] = queryRows(sql, params: params).compactMap { r in
            let sname = strVal(r, "student_name")
            if !qLower.isEmpty && !sname.lowercased().contains(qLower) { return nil }
            return [
                "id": intVal(r, "id"), "date": strVal(r, "started_at"), "group_name": strVal(r, "group_name"),
                "student_name": sname, "test_title": strVal(r, "test_title"), "status": strVal(r, "status"),
                "score": cleanNumber(dblVal(r, "score")), "max_score": cleanNumber(dblVal(r, "max_score")),
                "percent": dblVal(r, "percent"), "grade": strVal(r, "grade"),
                "grade_manual": intVal(r, "grade_manual") != 0, "violation_reason": strVal(r, "violation_reason"),
                "violation_count": intVal(r, "violation_count"), "unlock_count": intVal(r, "unlock_count")
            ]
        }
        return [
            "records": records,
            "groups": queryRows("SELECT DISTINCT group_name FROM sessions ORDER BY group_name").map { strVal($0, "group_name") },
            "tests": queryRows("SELECT DISTINCT test_title FROM sessions ORDER BY test_title").map { strVal($0, "test_title") }
        ]
    }

    func exportJournalCSV(groupFilter: String, testFilter: String) -> Data {
        var sql = "SELECT a.*, s.test_title, s.group_name FROM attempts a JOIN sessions s ON a.session_id = s.id WHERE 1=1"
        var params: [Any?] = []
        if !groupFilter.isEmpty { sql += " AND s.group_name = ?"; params.append(groupFilter) }
        if !testFilter.isEmpty { sql += " AND s.test_title = ?"; params.append(testFilter) }
        sql += " ORDER BY a.id DESC"

        func csvEscape(_ s: String) -> String {
            (s.contains(";") || s.contains("\"") || s.contains("\n")) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let statusLabels = ["submitted": "Сдал", "violated": "Нарушение", "in_progress": "В процессе"]
        var lines = ["Дата;Группа;ФИО;Тест;Статус;Баллы;Процент;Оценка;Нарушение"]
        for r in queryRows(sql, params: params) {
            let st = strVal(r, "status")
            let cols = [
                strVal(r, "started_at"), strVal(r, "group_name"), strVal(r, "student_name"), strVal(r, "test_title"),
                statusLabels[st] ?? st, "\(cleanNumber(dblVal(r, "score")))/\(cleanNumber(dblVal(r, "max_score")))",
                "\(dblVal(r, "percent"))%", strVal(r, "grade"), strVal(r, "violation_reason")
            ].map(csvEscape)
            lines.append(cols.joined(separator: ";"))
        }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
