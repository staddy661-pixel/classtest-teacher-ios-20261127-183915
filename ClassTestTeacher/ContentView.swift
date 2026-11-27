import SwiftUI
import UIKit

enum TeacherMode: Equatable {
    case home
    case localHost
    case remotePC(String)
}

struct ContentView: View {
    @StateObject private var server = LocalHTTPServer()
    @StateObject private var tunnel: CloudflareTunnelManager
    @AppStorage("ct_teacher_remote_url") private var savedRemoteUrl: String = ""
    @AppStorage("ct_teacher_use_tunnel") private var useInternetTunnel: Bool = true

    @State private var mode: TeacherMode = .home
    @State private var remoteInput: String = ""
    @State private var errorMsg: String? = nil
    @State private var showQRSheet: Bool = false
    @State private var showScanner: Bool = false
    @State private var showStopConfirm: Bool = false
    @State private var copiedToast: Bool = false
    @State private var selectedEndpointIndex: Int = 0
    @State private var webViewReloadId = UUID()

    init() {
        let srv = LocalHTTPServer()
        _server = StateObject(wrappedValue: srv)
        _tunnel = StateObject(wrappedValue: srv.tunnel)
    }

    private let bgColor = Color(red: 0.965, green: 0.973, blue: 0.984)
    private let primaryColor = Color(red: 0.145, green: 0.388, blue: 0.922)
    private let borderColor = Color(red: 0.886, green: 0.910, blue: 0.941)
    private let textColor = Color(red: 0.059, green: 0.090, blue: 0.165)

    private var currentStudentURL: String {
        if selectedEndpointIndex == -1 && !tunnel.publicURL.isEmpty {
            return tunnel.publicURL
        }
        if server.endpoints.indices.contains(selectedEndpointIndex) {
            return "http://\(server.endpoints[selectedEndpointIndex].ip):\(server.port)"
        }
        if !tunnel.publicURL.isEmpty {
            return tunnel.publicURL
        }
        return server.primaryStudentURL
    }

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            switch mode {
            case .home:
                homeScreen
            case .localHost:
                localHostScreen
            case .remotePC(let url):
                remoteScreen(url: url)
            }

            if copiedToast {
                VStack {
                    Spacer()
                    Text("Адрес скопирован")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(10)
                        .padding(.bottom, 28)
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            if remoteInput.isEmpty && !savedRemoteUrl.isEmpty { remoteInput = savedRemoteUrl }
            server.refreshEndpoints()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            server.refreshEndpoints()
        }
        .onChange(of: tunnel.publicURL) { newVal in
            if !newVal.isEmpty {
                selectedEndpointIndex = -1
            }
        }
        .sheet(isPresented: $showQRSheet) { qrModalSheet }
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                onScanned: { code in
                    showScanner = false
                    remoteInput = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    connectRemote()
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .alert("Остановить сервер?", isPresented: $showStopConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Остановить", role: .destructive) { stopLocalHost() }
        } message: {
            Text("Ученики потеряют связь с контрольной. Все уже сданные оценки сохранятся в базе.")
        }
    }

    private var homeScreen: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Text("К")
                            .font(.headline.bold())
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(primaryColor)
                            .cornerRadius(9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("КлассТест Учитель")
                                .font(.title3.bold())
                                .foregroundColor(textColor)
                            Text("Хост прямо на iPhone")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Сети iPhone")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Обновить") { server.refreshEndpoints() }
                                .font(.caption.weight(.semibold))
                                .foregroundColor(primaryColor)
                        }

                        if server.endpoints.isEmpty {
                            Text("Включите Wi-Fi или «Режим модема» в Настройках iPhone")
                                .font(.footnote)
                                .foregroundColor(.orange)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.08))
                                .cornerRadius(8)
                        } else {
                            ForEach(server.endpoints) { ep in
                                HStack {
                                    Circle().fill(Color.green).frame(width: 8, height: 8)
                                    Text(ep.label)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundColor(textColor)
                                    Spacer()
                                    Text("http://\(ep.ip):8000")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(primaryColor)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(bgColor)
                                .cornerRadius(8)
                            }
                        }
                    }

                    if let errorMsg {
                        Text(errorMsg).font(.caption).foregroundColor(.red)
                    }

                    Toggle(isOn: $useInternetTunnel) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("🌐 Интернет-ссылка (Cloudflare)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(textColor)
                            Text("Ученики подключаются из любой сети; админка через интернет закрыта")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(primaryColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bgColor)
                    .cornerRadius(9)

                    Button(action: startLocalHost) {
                        HStack(spacing: 8) {
                            Image(systemName: useInternetTunnel ? "globe" : "play.fill")
                            Text(useInternetTunnel ? "Запустить хост в интернете (1 клик)" : "Запустить хост на iPhone")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(primaryColor)
                        .cornerRadius(10)
                    }

                    Text("Если в Wi-Fi колледжа включена изоляция клиентов, включите «Режим модема» на iPhone — ученики подключатся напрямую без интернета.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .background(Color.white)
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Подключиться к серверу на ноутбуке")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(textColor)

                    TextField("192.168.1.45:8000", text: $remoteInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(11)
                        .background(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1.2))
                        .onSubmit { connectRemote() }

                    HStack(spacing: 10) {
                        Button(action: connectRemote) {
                            Text("Открыть панель ПК")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(primaryColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(primaryColor.opacity(0.08))
                                .cornerRadius(8)
                        }

                        Button(action: { showScanner = true }) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.body.weight(.semibold))
                                .foregroundColor(textColor)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .background(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1.2))
                        }
                    }
                }
                .padding(18)
                .background(Color.white)
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: 1))
            }
            .padding(18)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    private var localHostScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(tunnelDotColor).frame(width: 9, height: 9)
                    Button(action: copyCurrentAddress) {
                        Text(currentStudentURL
                            .replacingOccurrences(of: "https://", with: "")
                            .replacingOccurrences(of: "http://", with: ""))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button(action: toggleTunnel) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                        Text(tunnelButtonLabel)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tunnel.status == "ready" ? .green : primaryColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background((tunnel.status == "ready" ? Color.green : primaryColor).opacity(0.12))
                    .cornerRadius(7)
                }
                Button(action: {
                    server.refreshEndpoints()
                    showQRSheet = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "qrcode")
                        Text("QR")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(primaryColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(primaryColor.opacity(0.1))
                    .cornerRadius(7)
                }
                Button(action: { showStopConfirm = true }) {
                    Text("Стоп")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white)

            Divider()

            TeacherWebView(urlString: server.localAutoLoginTeacherURL) { err in
                errorMsg = err
            }
            .id(webViewReloadId)
        }
    }

    private func remoteScreen(url: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("ПК: \(url.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: ""))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Назад") { mode = .home }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(primaryColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white)

            Divider()

            TeacherWebView(urlString: url) { err in
                errorMsg = err
                mode = .home
            }
            .id(webViewReloadId)
        }
    }

    private var qrModalSheet: some View {
        NavigationView {
            VStack(spacing: 18) {
                if server.endpoints.count > 1 || !tunnel.publicURL.isEmpty {
                    Picker("Сеть", selection: $selectedEndpointIndex) {
                        if !tunnel.publicURL.isEmpty {
                            Text("🌐 Интернет").tag(-1)
                        }
                        ForEach(Array(server.endpoints.enumerated()), id: \.offset) { idx, ep in
                            Text("\(ep.label) (\(ep.ip))").tag(idx)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                if let qrImg = NetworkUtils.generateQRUIImage(text: currentStudentURL, scale: 14) {
                    Image(uiImage: qrImg)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300, maxHeight: 300)
                        .background(Color.white)
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)
                }

                Text(currentStudentURL)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundColor(textColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    Button(action: copyCurrentAddress) {
                        Label("Копировать", systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(primaryColor)
                            .cornerRadius(9)
                    }

                    Button(action: { server.refreshEndpoints() }) {
                        Label("Обновить IP", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(textColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(borderColor, lineWidth: 1.2))
                    }
                }

                Text("Не сворачивайте приложение и не блокируйте экран iPhone, пока идёт контрольная.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 20)
            .background(bgColor.ignoresSafeArea())
            .navigationTitle("Подключение учеников")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { showQRSheet = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var tunnelDotColor: Color {
        switch tunnel.status {
        case "ready": return .green
        case "starting": return .orange
        case "failed": return .red
        default: return .green
        }
    }

    private var tunnelButtonLabel: String {
        switch tunnel.status {
        case "ready": return "Сеть: ON"
        case "starting": return "Запуск…"
        case "failed": return "Повтор"
        default: return "Интернет"
        }
    }

    private func toggleTunnel() {
        if tunnel.status == "ready" || tunnel.status == "starting" {
            tunnel.stop()
            selectedEndpointIndex = 0
        } else {
            tunnel.start(port: server.port)
        }
    }

    private func startLocalHost() {
        errorMsg = nil
        if server.start(preferredPort: 8000) {
            UIApplication.shared.isIdleTimerDisabled = true
            selectedEndpointIndex = 0
            if useInternetTunnel {
                tunnel.start(port: server.port)
            }
            webViewReloadId = UUID()
            mode = .localHost
        } else {
            errorMsg = server.lastError ?? "Не удалось запустить сервер"
        }
    }

    private func stopLocalHost() {
        server.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        mode = .home
    }

    private func copyCurrentAddress() {
        UIPasteboard.general.string = currentStudentURL
        withAnimation { copiedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { copiedToast = false }
        }
    }

    private func connectRemote() {
        var s = remoteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            errorMsg = "Введите адрес сервера на ПК, например 192.168.1.45:8000"
            return
        }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        let teacherUrl = s.hasSuffix("/teacher") ? s : s + "/teacher"
        errorMsg = nil
        savedRemoteUrl = s
        remoteInput = s
        webViewReloadId = UUID()
        mode = .remotePC(teacherUrl)
    }
}
