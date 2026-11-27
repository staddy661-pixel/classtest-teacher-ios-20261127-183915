import Foundation
import zlib

enum DocxImportError: LocalizedError {
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let msg): return msg
        }
    }
}

enum DocxImporter {
    static let maxBytes = 10 * 1024 * 1024
    static let maxQuestions = 300

    static let importPageHTML = """
    <!DOCTYPE html>
    <html lang="ru"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Импорт теста из Word — КлассТест</title>
    <style>
    :root{--bg:#f8fafc;--card:#fff;--text:#0f172a;--muted:#64748b;--line:#e2e8f0;--accent:#2563eb;--ok:#15803d;--bad:#b91c1c;--warn:#a16207}
    @media (prefers-color-scheme:dark){:root{--bg:#0b1220;--card:#111a2e;--text:#e5e7eb;--muted:#94a3b8;--line:#22304d;--accent:#60a5fa;--ok:#4ade80;--bad:#f87171;--warn:#facc15}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
    .wrap{max-width:720px;margin:0 auto;padding:24px 16px}
    .card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px;margin-bottom:16px}
    h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:0 0 8px}
    p{margin:6px 0}.muted{color:var(--muted);font-size:14px}
    label{display:block;font-size:14px;color:var(--muted);margin:12px 0 4px}
    input[type=text],input[type=file]{width:100%;padding:10px;border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--text);font:inherit}
    button,.btn{display:inline-block;margin-top:14px;padding:10px 18px;border:0;border-radius:10px;background:var(--accent);color:#fff;font:inherit;cursor:pointer;text-decoration:none}
    button:disabled{opacity:.5;cursor:default}
    .btn.sec{background:transparent;color:var(--accent);border:1px solid var(--line)}
    pre{background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:12px;overflow-x:auto;font-size:14px;margin:8px 0}
    code{background:var(--bg);padding:1px 5px;border-radius:5px}
    #res .ok{color:var(--ok)}#res .bad{color:var(--bad)}#res li{color:var(--warn);font-size:14px}
    </style></head><body><div class="wrap">
    <div class="card">
    <h1>Импорт теста из Word</h1>
    <p class="muted">Загрузите .docx — тест появится в списке тестов учителя.</p>
    <p id="auth" class="bad" style="display:none">Вы не вошли как учитель. Откройте <a href="/teacher">страницу учителя</a>, войдите и вернитесь сюда.</p>
    <label for="f">Файл .docx</label>
    <input id="f" type="file" accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document">
    <label for="t">Название теста (необязательно — иначе возьмётся из документа)</label>
    <input id="t" type="text" maxlength="200" placeholder="Например: Контрольная по Python">
    <button id="go">Загрузить</button>
    <a class="btn sec" href="/api/tests/docx-template">Скачать образец .docx</a>
    <div id="res" style="margin-top:14px"></div>
    </div>
    <div class="card">
    <h2>Как оформить документ</h2>
    <pre>Тема: Основы Python
    Время: 20
    Перемешать вопросы: да
    Перемешать варианты: да

    1. Какой тип у значения 3.14? [2 балла]
    А) int
    Б) float *
    В) str

    2. Выберите изменяемые типы.
    А) list *
    Б) tuple
    В) dict *

    3. Какая функция выводит текст?
    Ответ: print</pre>
    <ul class="muted">
    <li>Вопрос начинается с номера: <code>1.</code> или <code>1)</code>. Баллы — в конце в скобках: <code>[2 балла]</code> (по умолчанию 1).</li>
    <li>Варианты — буква и скобка: <code>А)</code>, <code>Б)</code> (кириллица или латиница).</li>
    <li>Правильный вариант: звёздочка <code>*</code> в конце, либо строка <code>Ответ: Б</code> (несколько — <code>Ответ: А, В</code>), либо выделите вариант жирным или маркером.</li>
    <li>Если правильных больше одного — вопрос станет «несколько ответов».</li>
    <li>Без вариантов, но со строкой <code>Ответ: слово</code> — текстовый вопрос. Несколько допустимых ответов через <code>;</code>.</li>
    <li>Номера и буквы должны быть набраны текстом, а не автоматической нумерацией Word.</li>
    <li>Строки <code>Тема</code>, <code>Время</code> (минуты), <code>Перемешать …</code> — необязательные, пишутся до первого вопроса.</li>
    </ul>
    </div>
    <p><a href="/teacher">← К странице учителя</a></p>
    </div>
    <script>
    const $=id=>document.getElementById(id);
    fetch('/api/auth/me').then(r=>r.json()).then(d=>{if(!d.authenticated)$('auth').style.display='block'}).catch(()=>{});
    $('go').onclick=async()=>{
      const f=$('f').files[0], res=$('res');
      res.textContent='';
      if(!f){res.innerHTML='<p class="bad">Выберите файл .docx</p>';return}
      $('go').disabled=true;
      try{
        const q='?filename='+encodeURIComponent(f.name)+'&title='+encodeURIComponent($('t').value.trim());
        const r=await fetch('/api/tests/import-docx'+q,{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:f});
        const d=await r.json().catch(()=>({error:'Ошибка сервера'}));
        const box=document.createElement('div');
        const head=document.createElement('p');
        if(r.ok){
          head.className='ok';
          head.textContent='Готово: «'+d.title+'», вопросов: '+d.questions_count+'.';
        }else{
          head.className='bad';
          head.textContent=d.error||('Ошибка '+r.status);
        }
        box.appendChild(head);
        if(d.warnings&&d.warnings.length){
          const ul=document.createElement('ul');
          d.warnings.forEach(w=>{const li=document.createElement('li');li.textContent=w;ul.appendChild(li)});
          box.appendChild(ul);
        }
        if(r.ok){const a=document.createElement('a');a.href='/teacher';a.textContent='Открыть список тестов';box.appendChild(a)}
        res.appendChild(box);
      }catch(e){
        res.innerHTML='<p class="bad">Не удалось отправить файл</p>';
      }
      $('go').disabled=false;
    };
    </script></body></html>
    """

    // MARK: - Build Template .docx

    static func buildTemplate() -> Data {
        let wNS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let sample = [
            "Тема: Основы Python (пример)",
            "Время: 20",
            "Перемешать вопросы: да",
            "Перемешать варианты: да",
            "",
            "1. Какой тип данных у значения 3.14? [1 балл]",
            "А) int",
            "Б) float *",
            "В) str",
            "Г) bool",
            "2. Выберите все изменяемые типы данных. [2 балла]",
            "А) list *",
            "Б) tuple",
            "В) dict *",
            "Г) str",
            "3. Какая встроенная функция выводит текст на экран?",
            "Ответ: print",
            "4. Столица Беларуси? [1 балл]",
            "Ответ: Минск; Minsk",
            "5. Какой оператор выполняет деление нацело?",
            "А) /",
            "Б) //",
            "В) %",
            "Ответ: Б"
        ]

        let bodyXML = sample.map { line in
            "<w:p><w:r><w:t xml:space=\"preserve\">\(xmlEscape(line))</w:t></w:r></w:p>"
        }.joined()

        let documentXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"\(wNS)\"><w:body>\(bodyXML)</w:body></w:document>"
        let contentTypesXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"
        let relsXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"

        return buildStoredZip([
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(relsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8))
        ])
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Parse .docx

    private struct DocxLine {
        let text: String
        let style: String
        let bold: Bool
    }

    private struct RawOption {
        let label: String
        var text: String
        let star: Bool
        let bold: Bool
    }

    private struct RawQuestion {
        let num: Int
        var text: String
        var options: [RawOption]
        var answer: String?
    }

    static func parseDocxTest(raw: Data, filename: String = "", titleOverride: String = "") throws -> [String: Any] {
        guard !raw.isEmpty else {
            throw DocxImportError.invalidFile("Файл пуст")
        }
        guard raw.count <= maxBytes else {
            throw DocxImportError.invalidFile("Файл слишком большой")
        }
        guard let docXML = try extractZipEntry(data: raw, targetName: "word/document.xml") else {
            throw DocxImportError.invalidFile("Это не файл .docx (поддерживается формат Word 2007 и новее)")
        }

        let lines = parseDocumentXML(docXML)
        var title = ""
        var styleTitle = ""
        var firstLine = ""
        var timeLimit = 0
        var shuffleQ = false
        var shuffleO = false
        var rawQs: [RawQuestion] = []
        var curIdx: Int? = nil

        let qNumRe = try! NSRegularExpression(pattern: "^(\\d{1,3})[.)]\\s+(.+)$")
        let titleRe = try! NSRegularExpression(pattern: "^(?:тема|название|тест)\\s*[:\\-]\\s*(.+)$", options: .caseInsensitive)
        let timeRe = try! NSRegularExpression(pattern: "^(?:время|таймер|лимит)\\s*[:\\-]\\s*(\\d+)", options: .caseInsensitive)
        let shufQRe = try! NSRegularExpression(pattern: "^перемешать\\s+вопросы\\s*[:\\-]\\s*(.+)$", options: .caseInsensitive)
        let shufORe = try! NSRegularExpression(pattern: "^перемешать\\s+варианты\\s*[:\\-]\\s*(.+)$", options: .caseInsensitive)
        let ansRe = try! NSRegularExpression(pattern: "^(?:ответы?|правильный(?:\\s+ответ)?)\\s*[:\\-]\\s*(.+)$", options: .caseInsensitive)
        let optRe = try! NSRegularExpression(pattern: "^([А-ЯA-Zа-яa-z])[).]\\s+(.+)$")
        let markEndRe = try! NSRegularExpression(pattern: "(?:\\s*\\*+|\\s*\\[\\s*(?:\\*|правильн\\w*|верный)\\s*\\]|\\s*\\(\\s*\\*\\s*\\)|\\s*[✓✔+])\\s*$", options: .caseInsensitive)
        let markStartRe = try! NSRegularExpression(pattern: "^(?:\\*+\\s*|[✓✔]\\s*)")

        let titleStyles: Set<String> = ["title", "heading1", "heading2", "1", "2"]

        for ln in lines {
            let text = ln.text
            if let m = firstMatch(qNumRe, in: text) {
                let num = Int(substring(text, m.range(at: 1))) ?? (rawQs.count + 1)
                let body = substring(text, m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                rawQs.append(RawQuestion(num: num, text: body, options: [], answer: nil))
                if rawQs.count > maxQuestions {
                    throw DocxImportError.invalidFile("Слишком много вопросов (максимум \(maxQuestions))")
                }
                curIdx = rawQs.count - 1
                continue
            }

            if curIdx == nil {
                if let m = firstMatch(titleRe, in: text), title.isEmpty {
                    title = substring(text, m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }
                if let m = firstMatch(timeRe, in: text) {
                    timeLimit = Int(substring(text, m.range(at: 1))) ?? 0
                    continue
                }
                if let m = firstMatch(shufQRe, in: text) {
                    shuffleQ = isTruthy(substring(text, m.range(at: 1)))
                    continue
                }
                if let m = firstMatch(shufORe, in: text) {
                    shuffleO = isTruthy(substring(text, m.range(at: 1)))
                    continue
                }
                if styleTitle.isEmpty && titleStyles.contains(ln.style.lowercased()) {
                    styleTitle = text
                } else if firstLine.isEmpty {
                    firstLine = text
                }
                continue
            }

            let idx = curIdx!
            if let m = firstMatch(ansRe, in: text), rawQs[idx].answer == nil {
                rawQs[idx].answer = substring(text, m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if rawQs[idx].answer != nil {
                continue
            }

            if let m = firstMatch(optRe, in: text) {
                let label = substring(text, m.range(at: 1))
                var body = substring(text, m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                var star = false
                if let endM = firstMatch(markEndRe, in: body) {
                    star = true
                    body = (body as NSString).replacingCharacters(in: endM.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let startM = firstMatch(markStartRe, in: body) {
                    star = true
                    body = (body as NSString).replacingCharacters(in: startM.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                rawQs[idx].options.append(RawOption(label: label, text: body, star: star, bold: ln.bold))
                continue
            }

            if !rawQs[idx].options.isEmpty {
                let last = rawQs[idx].options.count - 1
                rawQs[idx].options[last].text = (rawQs[idx].options[last].text + " " + text).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rawQs[idx].text = (rawQs[idx].text + "\n" + text).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var questions: [[String: Any]] = []
        var warnings: [String] = []
        for q in rawQs {
            let (item, warn) = buildQuestion(q, seq: questions.count + 1)
            if let warn {
                warnings.append(warn)
            } else if let item {
                questions.append(item)
            }
        }

        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let resolvedTitle = [titleOverride, title, styleTitle, firstLine, stem, "Тест из Word"]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Тест из Word"
        let finalTitle = String(resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))

        return [
            "title": finalTitle,
            "time_limit": timeLimit,
            "shuffle_questions": shuffleQ,
            "shuffle_options": shuffleO,
            "questions": questions,
            "warnings": warnings
        ]
    }

    private static func buildQuestion(_ q: RawQuestion, seq: Int) -> ([String: Any]?, String?) {
        let ptsRe = try! NSRegularExpression(pattern: "\\[\\s*(\\d+(?:[.,]\\d+)?)\\s*(?:бал[а-я]*|б\\.?|pt|pts)?\\s*\\]\\s*$", options: .caseInsensitive)
        var qText = q.text
        var pts: Double = 1
        if let m = firstMatch(ptsRe, in: qText) {
            let numStr = substring(qText, m.range(at: 1)).replacingOccurrences(of: ",", with: ".")
            pts = max(0.5, Double(numStr) ?? 1)
            qText = (qText as NSString).replacingCharacters(in: m.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if qText.isEmpty {
            return (nil, "Вопрос \(q.num): пустой текст")
        }

        let opts = q.options.filter { !$0.text.isEmpty }
        if !opts.isEmpty {
            if opts.count < 2 {
                return (nil, "Вопрос \(q.num): меньше двух вариантов ответа")
            }
            var correct: [Int] = []
            if let ans = q.answer {
                correct = matchAnswerLabels(ans, opts: opts)
            }
            if correct.isEmpty {
                correct = opts.enumerated().compactMap { $0.element.star ? $0.offset : nil }
            }
            if correct.isEmpty {
                let boldIdxs = opts.enumerated().compactMap { $0.element.bold ? $0.offset : nil }
                if !boldIdxs.isEmpty && boldIdxs.count < opts.count {
                    correct = boldIdxs
                }
            }
            if correct.isEmpty {
                return (nil, "Вопрос \(q.num): не отмечен правильный ответ")
            }
            let qtype = correct.count > 1 ? "multiple" : "single"
            return ([
                "id": "q\(seq)",
                "type": qtype,
                "text": qText,
                "options": opts.map { $0.text },
                "correct": correct,
                "points": pts
            ], nil)
        }

        if let ans = q.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !ans.isEmpty {
            return ([
                "id": "q\(seq)",
                "type": "text",
                "text": qText,
                "acceptedText": ans,
                "points": pts
            ], nil)
        }
        return (nil, "Вопрос \(q.num): нет ни вариантов ответа, ни строки «Ответ: …»")
    }

    private static func matchAnswerLabels(_ ans: String, opts: [RawOption]) -> [Int] {
        let letters = ["а", "б", "в", "г", "д", "е", "ж", "з"]
        let latLetters = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let byLabel = Dictionary(uniqueKeysWithValues: opts.enumerated().map { ($0.element.label.lowercased(), $0.offset) })
        let byText = Dictionary(uniqueKeysWithValues: opts.enumerated().map { ($0.element.text.lowercased(), $0.offset) })

        var idxs: [Int] = []
        let parts = ans.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        for part in parts {
            let tok = part.replacingOccurrences(of: "[).]+$", with: "", options: .regularExpression)
            if let idx = byLabel[tok] {
                idxs.append(idx)
            } else if let n = Int(tok), n >= 1 && n <= opts.count {
                idxs.append(n - 1)
            } else if let li = letters.firstIndex(of: tok), li < opts.count {
                idxs.append(li)
            } else if let li = latLetters.firstIndex(of: tok), li < opts.count {
                idxs.append(li)
            } else if let idx = byText[part] {
                idxs.append(idx)
            }
        }
        return Array(Set(idxs)).sorted()
    }

    private static func isTruthy(_ s: String) -> Bool {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["да", "yes", "true", "1", "+"].contains(v)
    }

    private static func firstMatch(_ re: NSRegularExpression, in str: String) -> NSTextCheckingResult? {
        re.firstMatch(in: str, range: NSRange(location: 0, length: (str as NSString).length))
    }

    private static func substring(_ str: String, _ range: NSRange) -> String {
        guard range.location != NSNotFound else { return "" }
        return (str as NSString).substring(with: range)
    }

    // MARK: - Word XML Parser

    private final class WordXMLDelegate: NSObject, XMLParserDelegate {
        var lines: [DocxLine] = []
        private var inPara = false
        private var inRun = false
        private var inText = false
        private var paraText = ""
        private var paraStyle = ""
        private var runText = ""
        private var runBold = false
        private var anyNonEmpty = false
        private var allHighlighted = true

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.components(separatedBy: ":").last ?? elementName
            switch local {
            case "p":
                inPara = true
                paraText = ""
                paraStyle = ""
                anyNonEmpty = false
                allHighlighted = true
            case "pStyle":
                if inPara, let val = attributeDict["w:val"] ?? attributeDict["val"] {
                    paraStyle = val
                }
            case "r":
                if inPara {
                    inRun = true
                    runText = ""
                    runBold = false
                }
            case "b":
                if inRun {
                    let val = (attributeDict["w:val"] ?? attributeDict["val"] ?? "").lowercased()
                    if val != "0" && val != "false" { runBold = true }
                }
            case "highlight":
                if inRun {
                    let val = (attributeDict["w:val"] ?? attributeDict["val"] ?? "").lowercased()
                    if !val.isEmpty && val != "none" { runBold = true }
                }
            case "shd":
                if inRun {
                    let val = (attributeDict["w:fill"] ?? attributeDict["fill"] ?? "").lowercased()
                    if !val.isEmpty && val != "auto" && val != "ffffff" { runBold = true }
                }
            case "t":
                if inRun { inText = true }
            case "tab":
                if inRun { runText += " " }
            case "br":
                if inRun { runText += "\n" }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { runText += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let local = elementName.components(separatedBy: ":").last ?? elementName
            switch local {
            case "t":
                inText = false
            case "r":
                if inRun {
                    paraText += runText
                    if !runText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        anyNonEmpty = true
                        if !runBold { allHighlighted = false }
                    }
                    inRun = false
                }
            case "p":
                if inPara {
                    let trimmed = paraText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        lines.append(DocxLine(text: trimmed, style: paraStyle, bold: anyNonEmpty && allHighlighted))
                    }
                    inPara = false
                }
            default:
                break
            }
        }
    }

    private static func parseDocumentXML(_ data: Data) -> [DocxLine] {
        let parser = XMLParser(data: data)
        let delegate = WordXMLDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.lines
    }

    // MARK: - Minimal Pure-Swift ZIP Reader & Writer (zlib)

    private static func readU16(_ d: Data, _ off: Int) -> Int {
        Int(d[off]) | (Int(d[off + 1]) << 8)
    }

    private static func readU32(_ d: Data, _ off: Int) -> Int {
        Int(d[off]) | (Int(d[off + 1]) << 8) | (Int(d[off + 2]) << 16) | (Int(d[off + 3]) << 24)
    }

    private static func extractZipEntry(data: Data, targetName: String) throws -> Data? {
        guard data.count >= 22 else { return nil }
        let minOff = max(0, data.count - 65557)
        var eocdOffset: Int? = nil
        var i = data.count - 22
        while i >= minOff {
            if data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 0x05 && data[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { return nil }
        let cdCount = readU16(data, eocd + 10)
        var pos = readU32(data, eocd + 16)

        for _ in 0..<cdCount {
            guard pos + 46 <= data.count,
                  data[pos] == 0x50, data[pos + 1] == 0x4B, data[pos + 2] == 0x01, data[pos + 3] == 0x02 else {
                break
            }
            let method = readU16(data, pos + 10)
            let compSize = readU32(data, pos + 20)
            let uncompSize = readU32(data, pos + 24)
            let nameLen = readU16(data, pos + 28)
            let extraLen = readU16(data, pos + 30)
            let commentLen = readU16(data, pos + 32)
            let localOff = readU32(data, pos + 42)
            let nameData = data.subdata(in: (pos + 46)..<(pos + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            pos += 46 + nameLen + extraLen + commentLen

            if name == targetName {
                guard localOff + 30 <= data.count,
                      data[localOff] == 0x50, data[localOff + 1] == 0x4B, data[localOff + 2] == 0x03, data[localOff + 3] == 0x04 else {
                    return nil
                }
                let lNameLen = readU16(data, localOff + 26)
                let lExtraLen = readU16(data, localOff + 28)
                let dataStart = localOff + 30 + lNameLen + lExtraLen
                guard dataStart + compSize <= data.count else { return nil }
                let compData = data.subdata(in: dataStart..<(dataStart + compSize))
                if method == 0 {
                    return compData
                } else if method == 8 {
                    return inflateRaw(compData, expectedSize: uncompSize)
                }
                throw DocxImportError.invalidFile("Неподдерживаемый метод сжатия в .docx")
            }
        }
        return nil
    }

    private static func inflateRaw(_ comp: Data, expectedSize: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: max(expectedSize, comp.count * 2))
        let chunkSize = 16384
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        let ok = comp.withUnsafeBytes { rawPtr -> Bool in
            guard let base = rawPtr.bindMemory(to: Bytef.self).baseAddress else { return false }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base)
            stream.avail_in = uInt(comp.count)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(buffer, count: produced) }
                if status == Z_STREAM_END { return true }
                if status != Z_OK { return false }
            }
        }
        return ok ? output : nil
    }

    private static func appendU16(_ d: inout Data, _ v: Int) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
    }

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
    }

    private static func buildStoredZip(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var cd = Data()

        for (name, body) in entries {
            let nameData = Data(name.utf8)
            let crc = body.withUnsafeBytes { ptr -> UInt32 in
                let base = ptr.bindMemory(to: Bytef.self).baseAddress
                return UInt32(crc32(0, base, uInt(body.count)))
            }
            let localOffset = UInt32(out.count)

            appendU32(&out, 0x04034b50)
            appendU16(&out, 20)
            appendU16(&out, 0x0800) // UTF-8
            appendU16(&out, 0)      // stored
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU32(&out, crc)
            appendU32(&out, UInt32(body.count))
            appendU32(&out, UInt32(body.count))
            appendU16(&out, nameData.count)
            appendU16(&out, 0)
            out.append(nameData)
            out.append(body)

            appendU32(&cd, 0x02014b50)
            appendU16(&cd, 20)
            appendU16(&cd, 20)
            appendU16(&cd, 0x0800)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU32(&cd, crc)
            appendU32(&cd, UInt32(body.count))
            appendU32(&cd, UInt32(body.count))
            appendU16(&cd, nameData.count)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU32(&cd, 0)
            appendU32(&cd, localOffset)
            cd.append(nameData)
        }

        let cdOffset = UInt32(out.count)
        let cdSize = UInt32(cd.count)
        out.append(cd)

        appendU32(&out, 0x06054b50)
        appendU16(&out, 0)
        appendU16(&out, 0)
        appendU16(&out, entries.count)
        appendU16(&out, entries.count)
        appendU32(&out, cdSize)
        appendU32(&out, cdOffset)
        appendU16(&out, 0)
        return out
    }
}
