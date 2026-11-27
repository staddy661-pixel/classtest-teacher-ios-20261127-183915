import CoreImage
import CryptoKit
import Darwin
import Foundation
import Security
import UIKit

struct NetworkEndpoint: Identifiable, Hashable {
    let id: String
    let interfaceName: String
    let ip: String
    let label: String
}

enum NetworkUtils {
    static func getLocalEndpoints() -> [NetworkEndpoint] {
        var found: [NetworkEndpoint] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return []
        }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && isRunning && !isLoopback, let addr = current.pointee.ifa_addr {
                if addr.pointee.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let res = getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if res == 0 {
                        let ip = String(cString: hostname)
                        let iface = String(cString: current.pointee.ifa_name)
                        if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && !iface.hasPrefix("pdp_ip") && !iface.hasPrefix("utun") {
                            let label: String
                            if iface.hasPrefix("bridge") {
                                label = "Режим модема"
                            } else if iface == "en0" {
                                label = "Wi-Fi"
                            } else {
                                label = iface
                            }
                            if !found.contains(where: { $0.ip == ip }) {
                                found.append(NetworkEndpoint(id: "\(iface)-\(ip)", interfaceName: iface, ip: ip, label: label))
                            }
                        }
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }

        func rank(_ iface: String) -> Int {
            if iface.hasPrefix("bridge") { return 0 }
            if iface == "en0" { return 1 }
            return 2
        }
        found.sort { rank($0.interfaceName) < rank($1.interfaceName) }
        return found
    }

    static func getLocalIPs() -> [String] {
        let eps = getLocalEndpoints()
        if eps.isEmpty { return ["127.0.0.1"] }
        return eps.map { $0.ip }
    }

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(bytes: Int) -> String {
        var arr = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &arr)
        return arr.map { String(format: "%02x", $0) }.joined()
    }

    static func nowISO() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: Date())
    }

    static func parseISO(_ str: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.date(from: str)
    }

    static func generateQRUIImage(text: String, scale: CGFloat = 12) -> UIImage? {
        let data = Data(text.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        let border = Int(scale * 2)
        let w = cgImage.width + border * 2
        let h = cgImage.height + border * 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            UIImage(cgImage: cgImage).draw(in: CGRect(x: border, y: border, width: cgImage.width, height: cgImage.height))
        }
    }

    static func generateQRPNG(text: String) -> Data {
        if let img = generateQRUIImage(text: text, scale: 12), let png = img.pngData() {
            return png
        }
        return Data()
    }
}
