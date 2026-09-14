import Foundation
import Network
import Combine
import SwiftUI
import UIKit
@preconcurrency import AVFoundation
import Darwin
import CoreImage

/// An explicit foreground session. Audio files are never captured from other apps.
@MainActor
final class LocalAudioSharing: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var address: URL?
    @Published private(set) var accessCode = ""
    @Published private(set) var status = String(localized: "Sharing is off")
    @Published private(set) var transferredBytes: Int64 = 0

    private let playbackStore: PlaybackStore
    private var server: LocalAudioHTTPServer?
    private var certificateServer: LocalAudioHTTPServer?
    private var tlsIdentity: SharingTLSIdentity?
    @Published private(set) var certificateAddress: URL?
    @Published private(set) var certificateFingerprint = ""

    var joinAddress: URL? {
        guard let address else { return nil }
        var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)
        parts?.fragment = "code=" + accessCode
        return parts?.url
    }
    private var subscription: AnyCancellable?
    private var preparation: Task<Void, Never>?
    private var preparedPath: String?
    private var track: SharedAudioTrack?
    private var sessionID = UUID()
    private var previousIdleTimerDisabled = false
    @Published private(set) var isPreparingAudio = false
    @Published var reduceBandwidth = UserDefaults.standard.bool(forKey: "medio.sharing.reduceBandwidth") {
        didSet {
            UserDefaults.standard.set(reduceBandwidth, forKey: "medio.sharing.reduceBandwidth")
            preparedPath = nil
            update(playback: playbackStore.playback)
        }
    }

    init(playbackStore: PlaybackStore) {
        self.playbackStore = playbackStore
        subscription = playbackStore.$playback.sink { [weak self] playback in
            self?.update(playback: playback)
        }
    }

    func start() {
        guard !isEnabled else { return }
        guard let host = Self.wifiAddress() else {
            status = String(localized: "Connect to Wi-Fi to share audio.")
            return
        }
        let identity: SharingTLSIdentity
        do { identity = try SharingTLSIdentity.make(host: host) }
        catch {
            status = String(localized: "Could not create the encrypted sharing session. Please try again.")
            return
        }
        tlsIdentity = identity
        certificateFingerprint = identity.fingerprint
        sessionID = UUID()
        let id = sessionID
        accessCode = String(format: "%06u", arc4random_uniform(1_000_000))
        transferredBytes = 0
        isEnabled = true
        status = String(localized: "Starting sharing…")
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let server = LocalAudioHTTPServer(code: accessCode, page: SharingReceiverPage.html, tlsIdentity: identity) { [weak self] event in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                if case .bytes(let count) = event { self.transferredBytes += count; return }
                guard self.isEnabled else { return }
                switch event {
                case .ready(let port):
                    self.address = Self.listenerURL(host: host, port: port, encrypted: true)
                    self.status = String(localized: "Ready for listeners")
                case .failed:
                    self.stop()
                    self.status = String(localized: "Could not start sharing. Check Local Network access in iOS Settings.")
                case .bytes: break
                }
            }
        }
        let certificates = LocalAudioHTTPServer(code: "", page: "", certificateDownload: identity.rootCertificate) { [weak self] event in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                if case .bytes(let count) = event { self.transferredBytes += count; return }
                guard self.isEnabled else { return }
                switch event {
                case .ready(let port):
                    self.certificateAddress = Self.listenerURL(host: host, port: port)?.appendingPathComponent("certificate.cer")
                case .failed:
                    self.stop()
                    self.status = String(localized: "Could not start sharing. Check Local Network access in iOS Settings.")
                case .bytes: break
                }
            }
        }
        certificateServer = certificates
        certificates.start()
        self.server = server
        server.start()
        update(playback: playbackStore.playback)
    }

    func stop() {
        guard isEnabled else { return }
        isEnabled = false
        preparation?.cancel()
        preparation = nil
        server?.stop()
        server = nil
        certificateServer?.stop()
        certificateServer = nil
        tlsIdentity = nil
        certificateAddress = nil
        certificateFingerprint = ""
        address = nil
        accessCode = ""
        preparedPath = nil
        track = nil
        isPreparingAudio = false
        status = String(localized: "Sharing is off")
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }

    private func update(playback: PlaybackState) {
        guard isEnabled, let server else { return }
        let item = playbackStore.nowPlaying
        if preparedPath != item?.id {
            preparedPath = item?.id
            track = nil
            isPreparingAudio = false
            preparation?.cancel()
            if let item {
                let id = sessionID
                let compact = reduceBandwidth
                isPreparingAudio = true
                preparation = Task { [weak self] in
                    let candidate = await SharedAudioTrack.prepare(item: item, compact: compact)
                    guard !Task.isCancelled, let self, self.isEnabled, self.sessionID == id,
                          self.preparedPath == item.id else { return }
                    self.isPreparingAudio = false
                    self.track = candidate
                    self.update(playback: self.playbackStore.playback)
                }
            }
        }
        let message = item == nil ? String(localized: "Play a song in Medio to begin.")
            : (isPreparingAudio ? String(localized: "Preparing audio for sharing…") : (track == nil ? String(localized: "This file cannot be shared. Use an unprotected MP3, M4A, AAC, WAV, AIFF, or FLAC audio file.") : ""))
        server.update(track: track, state: SharedAudioState(
            track: track?.id, title: item?.title ?? "", artist: item?.artist ?? "",
            position: Double(playback.positionMs) / 1000, playing: playback.isPlaying && track != nil,
            message: message
        ))
    }

    static func listenerURL(host: String, port: UInt16, encrypted: Bool = false) -> URL? {
        // An IPv6 literal needs brackets; interface-scoped addresses are not portable
        // to the receiving device, so wifiAddress excludes them.
        let authority = host.contains(":") ? "[\(host)]" : host
        let scheme = encrypted ? "https" : "http"
        return URL(string: "\(scheme)://\(authority):\(port)")
    }

    private static func wifiAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var ipv6Host: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            defer { pointer = interface.ifa_next }
            guard String(cString: interface.ifa_name) == "en0", let address = interface.ifa_addr,
                  [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family),
                  interface.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let numericHost = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if address.pointee.sa_family == UInt8(AF_INET) { return numericHost }
                if !numericHost.contains("%") { ipv6Host = numericHost }

            }
        }
        return ipv6Host
    }
}

struct SharedAudioTrack: Sendable {
    let id: String
    let url: URL
    let mimeType: String
    let size: Int64
    var temporaryAudio: SharedTemporaryAudio? = nil

    static func validatedURL(path: String, documents: URL) -> URL? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let root = documents.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.path.hasPrefix(root),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    static func prepare(item: MediaItem, compact: Bool = false) async -> SharedAudioTrack? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let source = validatedURL(path: item.id, documents: documents) else { return nil }
        let types = ["mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav",
                     "aif": "audio/aiff", "aiff": "audio/aiff", "flac": "audio/flac"]
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.hasProtectedContent)) == false,
              (try? await asset.load(.isPlayable)) == true else { return nil }
        let copy: SharedTemporaryAudio?
        if compact || item.isVideo {
            guard let output = try? await SharingAudioPreparation.makeAudioCopy(from: source, compact: compact) else { return nil }
            copy = SharedTemporaryAudio(url: output)
        } else { copy = nil }
        let url = copy?.url ?? source
        guard let mime = types[url.pathExtension.lowercased()],
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
        return SharedAudioTrack(id: UUID().uuidString, url: url, mimeType: mime, size: Int64(size), temporaryAudio: copy)
    }

}

struct SharedAudioState: Codable, Sendable {
    var track: String?
    var title: String = ""
    var artist: String = ""
    var position: Double = 0
    var playing: Bool = false
    var message: String = ""
}

/// Serial-queue ownership covers the listener, snapshots, connections and file handles.
/// No path supplied by an HTTP client is ever interpreted as a filesystem path.
final class LocalAudioHTTPServer: @unchecked Sendable {
    enum Event: Sendable { case ready(UInt16), failed, bytes(Int64) }
    private let queue = DispatchQueue(label: "medio.local-audio-server", qos: .utility)
    private let restrictToWiFi: Bool
    private let tlsIdentity: SharingTLSIdentity?
    private let certificateDownload: Data?
    private let code: String
    private let token = UUID().uuidString + UUID().uuidString
    private let page: Data
    private let event: @Sendable (Event) -> Void
    private var listener: NWListener?
    private var connections: [UUID: Peer] = [:]
    private var track: SharedAudioTrack?
    private var state = SharedAudioState()
    private var stateUpdatedAt = ProcessInfo.processInfo.systemUptime
    private var failedJoins: [Date] = []
    private var pendingBytes: Int64 = 0
    private var lastUsageReport = Date()

    private final class Peer {
        let connection: NWConnection
        var request = Data()
        var file: FileHandle?
        var remaining: Int64 = 0
        var timeout: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
        deinit { try? file?.close() }
    }

    init(code: String, page: String, restrictToWiFi: Bool = true, tlsIdentity: SharingTLSIdentity? = nil, certificateDownload: Data? = nil, event: @escaping @Sendable (Event) -> Void) {
        self.tlsIdentity = tlsIdentity
        self.certificateDownload = certificateDownload
        self.code = code
        self.restrictToWiFi = restrictToWiFi
        self.page = Data(page.utf8)
        self.event = event
    }

    func start() {
        queue.async { [self] in
            do {
                // Production audio never falls back to plaintext. The sole HTTP endpoint
                // exposes a public certificate, with no code, token, metadata or audio.
                guard !restrictToWiFi || tlsIdentity != nil || certificateDownload != nil else {
                    event(.failed); return
                }
                let parameters = try tlsIdentity.map { NWParameters(tls: try $0.options(), tcp: NWProtocolTCP.Options()) } ?? NWParameters.tcp
                if restrictToWiFi {
                    parameters.requiredInterfaceType = .wifi
                } else {
                    // Integration tests stay on loopback and do not ask for LAN access.
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                }
                parameters.includePeerToPeer = false
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                if restrictToWiFi && certificateDownload == nil {
                    listener.service = NWListener.Service(name: "Medio Audio", type: "_medio-audio._tcp")
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready: if let port = listener?.port { self.event(.ready(port.rawValue)) }
                    case .failed: self.event(.failed); self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            } catch { event(.failed) }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    func update(track: SharedAudioTrack?, state: SharedAudioState) {
        queue.async { [self] in
            if self.track?.id != track?.id {
                for id in Array(connections.keys) where connections[id]?.file != nil { close(id) }
            }
            self.track = track
            self.state = state
            self.stateUpdatedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { close(id) }
        track = nil
        if pendingBytes > 0 { event(.bytes(pendingBytes)); pendingBytes = 0 }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        let peer = Peer(connection)
        connections[id] = peer
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(id) }
            if case .cancelled = state { self?.close(id) }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.close(id) }
        peer.timeout = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        connection.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let peer = connections[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, let peer = self.connections[id] else { return }
            if let data { peer.request.append(data); self.count(data.count) }
            guard peer.request.count <= 8192 else { self.reply(id, status: "431 Request Header Fields Too Large"); return }
            if let boundary = peer.request.range(of: Data("\r\n\r\n".utf8)) {
                guard let request = LocalAudioHTTPRequest(header: peer.request[..<boundary.lowerBound]) else {
                    self.reply(id, status: "400 Bad Request"); return
                }
                let body = peer.request[boundary.upperBound...]
                guard body.count >= request.contentLength else {
                    if complete || error != nil { self.close(id) } else { self.receive(id) }
                    return
                }
                self.route(id, request: request, body: Data(body.prefix(request.contentLength)))
            } else if complete || error != nil { self.close(id) }
            else { self.receive(id) }
        }
    }

    private func route(_ id: UUID, request: LocalAudioHTTPRequest, body: Data) {
        guard ["GET", "HEAD", "POST"].contains(request.method) else { reply(id, status: "405 Method Not Allowed"); return }
        guard let url = URLComponents(string: request.target), url.scheme == nil, url.host == nil,
              request.target.hasPrefix("/"), !request.target.hasPrefix("//") else {
            reply(id, status: "400 Bad Request"); return
        }
        if let certificateDownload {
            guard url.path == "/certificate.cer", request.method == "GET" || request.method == "HEAD" else {
                reply(id, status: "404 Not Found"); return
            }
            reply(id, type: "application/x-x509-ca-cert", body: certificateDownload, head: request.method == "HEAD")
            return
        }
        if url.path == "/", request.method != "POST" {
            reply(id, type: "text/html; charset=utf-8", body: page, head: request.method == "HEAD"); return
        }
        if url.path == "/join", request.method == "POST" {
            failedJoins.removeAll { Date().timeIntervalSince($0) > 60 }
            guard failedJoins.count < 10 else { reply(id, status: "429 Too Many Requests"); return }
            guard String(data: body, encoding: .utf8) == code else {
                failedJoins.append(Date()); reply(id, status: "403 Forbidden"); return
            }
            reply(id, type: "application/json", body: (try? JSONSerialization.data(withJSONObject: ["token": token])) ?? Data()); return
        }
        let supplied = request.headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
            ?? url.queryItems?.first(where: { $0.name == "token" })?.value
        guard supplied == token else { reply(id, status: "403 Forbidden"); return }
        guard request.method != "POST" else { reply(id, status: "405 Method Not Allowed"); return }
        if url.path == "/state" {
            var current = state
            if current.playing { current.position += max(0, ProcessInfo.processInfo.systemUptime - stateUpdatedAt) }
            reply(id, type: "application/json", body: (try? JSONEncoder().encode(current)) ?? Data(), head: request.method == "HEAD")
        } else if let track, url.path == "/audio/" + track.id {
            stream(id, track: track, rangeHeader: request.headers["range"], head: request.method == "HEAD")
        } else { reply(id, status: "404 Not Found") }
    }

    private func stream(_ id: UUID, track: SharedAudioTrack, rangeHeader: String?, head: Bool) {
        guard let range = AudioByteRange.parse(rangeHeader, size: track.size) else {
            reply(id, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(track.size)\r\n"); return
        }
        guard let peer = connections[id], let file = try? FileHandle(forReadingFrom: track.url),
              (try? file.seek(toOffset: UInt64(range.start))) != nil else { reply(id, status: "404 Not Found"); return }
        peer.file = file
        peer.remaining = range.length
        peer.timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.close(id) }
        peer.timeout = timeout
        queue.asyncAfter(deadline: .now() + 3600, execute: timeout)
        let partial = rangeHeader != nil
        let extra = "Accept-Ranges: bytes\r\n" + (partial ? "Content-Range: bytes \(range.start)-\(range.end)/\(track.size)\r\n" : "")
        let header = header(status: partial ? "206 Partial Content" : "200 OK", type: track.mimeType, length: range.length, extra: extra)
        send(id, data: Data(header.utf8)) { [weak self] in
            if head { self?.close(id) } else { self?.sendChunk(id) }
        }
    }

    private func sendChunk(_ id: UUID) {
        guard let peer = connections[id], peer.remaining > 0 else { close(id); return }
        guard let data = try? peer.file?.read(upToCount: Int(min(65536, peer.remaining))), !data.isEmpty else { close(id); return }
        peer.remaining -= Int64(data.count)
        send(id, data: data) { [weak self] in self?.sendChunk(id) }
    }

    private func reply(_ id: UUID, status: String = "200 OK", type: String = "text/plain", body: Data = Data(), head: Bool = false, extra: String = "") {
        var data = Data(header(status: status, type: type, length: Int64(body.count), extra: extra).utf8)
        if !head { data.append(body) }
        send(id, data: data) { [weak self] in self?.close(id) }
    }

    private func header(status: String, type: String, length: Int64, extra: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\(extra)\r\n"
    }

    private func send(_ id: UUID, data: Data, completion: @escaping @Sendable () -> Void) {
        connections[id]?.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, self.connections[id] != nil else { return }
            if error != nil { self.close(id) } else { self.count(data.count); completion() }
        })
    }

    private func count(_ bytes: Int) {
        pendingBytes += Int64(bytes)
        if Date().timeIntervalSince(lastUsageReport) > 1 {
            event(.bytes(pendingBytes)); pendingBytes = 0; lastUsageReport = Date()
        }
    }

    private func close(_ id: UUID) {
        guard let peer = connections.removeValue(forKey: id) else { return }
        peer.timeout?.cancel()
        peer.connection.cancel()
        try? peer.file?.close()
        peer.file = nil
    }
}

struct LocalAudioHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let contentLength: Int
    init?(header: Data) {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { return nil }
        method = String(first[0]); target = String(first[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { return nil }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return nil }
        let length = headers["content-length"].flatMap(Int.init) ?? (headers["content-length"] == nil ? 0 : -1)
        guard (0...512).contains(length) else { return nil }
        self.headers = headers; contentLength = length
    }
}

struct AudioByteRange: Equatable {
    let start: Int64
    let end: Int64
    var length: Int64 { end - start + 1 }
    static func parse(_ header: String?, size: Int64) -> AudioByteRange? {
        guard size > 0 else { return nil }
        guard let header else { return AudioByteRange(start: 0, end: size - 1) }
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            return AudioByteRange(start: max(0, size - suffix), end: size - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : (Int64(parts[1]) ?? -1)
        guard end >= start else { return nil }
        return AudioByteRange(start: start, end: min(end, size - 1))
    }
}

struct AudioSharingSettingsSection: View {
    @ObservedObject var sharing: LocalAudioSharing
    @EnvironmentObject private var router: AppRouter
    var body: some View {
        Section("Share Audio") {
            Toggle("Share with Other Headphones or Speakers", isOn: Binding(get: { sharing.isEnabled }, set: { $0 ? sharing.start() : sharing.stop() }))
                .accessibilityIdentifier("settings_audio_sharing")
            Toggle("Reduce Audio Bandwidth", isOn: $sharing.reduceBandwidth)
                .accessibilityIdentifier("settings_sharing_compression")
            Text("Creates a temporary 96 kbps AAC copy. Videos share only their audio. Preparing a copy may take time; original files are unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if sharing.isPreparingAudio { ProgressView("Preparing audio for sharing…") }
            Text("Open the address below in Safari on another device on the same Wi-Fi, enter the code, and tap Listen. Connect that device to your headphones or speaker.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Set Up Encryption") { router.present(.sharingEncryptionSetup) }
                .accessibilityIdentifier("sharing_encryption_setup")
            if let address = sharing.address {
                Text("Set up certificate trust on the listening device before scanning the join QR code. If Safari says the connection is not private, return to Set Up Encryption; do not bypass the warning.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(address.absoluteString).textSelection(.enabled)
                    .accessibilityIdentifier("sharing_address")
                Text("Access code: \(sharing.accessCode)").monospacedDigit()
                    .accessibilityIdentifier("sharing_code")
                if let joinAddress = sharing.joinAddress {
                    SharingQRCode(url: joinAddress)
                        .accessibilityIdentifier("sharing_join_qr")
                    Text("Scan to open the encrypted player and fill in the access code. Then tap Listen.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Copy Join Link") { UIPasteboard.general.string = joinAddress.absoluteString }
                }
            }
            Text("Local data this session: \(ByteCountFormatter.string(fromByteCount: sharing.transferredBytes, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            Text(sharing.status).font(.caption).foregroundStyle(.secondary)
            Text("Keep Medio open while sharing. Leaving the app stops the session. Audio and access codes use encrypted HTTPS. Each receiving device needs the one-time certificate setup. Playback timing depends on Wi-Fi and the receiving browser.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Share only audio you have permission to share. Protected audio and other apps’ sound are not supported. No internet connection is required.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}


struct SharingQRCode: View {
    let url: URL
    static func image(for url: URL) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
    var body: some View {
        if let image = Self.image(for: url) {
            Image(uiImage: image).interpolation(.none).resizable()
                .frame(width: 208, height: 208).padding(20)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Sharing QR Code")
        }
    }
}

struct SharingEncryptionSetup: View {
    @ObservedObject var sharing: LocalAudioSharing
    var body: some View {
        List {
            Section("One-Time Setup") {
                Text("Keep Medio open on the host. Complete these steps on the other device in Safari, not in the camera’s preview browser.")
                if sharing.certificateAddress == nil {
                    Text("Turn on Share with Other Headphones or Speakers to create the certificate QR code.")
                }
                Text("On the listening device, scan this certificate QR code. Install the downloaded Medio Local Audio profile in Settings → General → VPN & Device Management.")
                if let url = sharing.certificateAddress {
                    SharingQRCode(url: url)
                    Text(url.absoluteString).font(.caption).textSelection(.enabled)
                }
                Text("Verify that the downloaded certificate matches the SHA-256 fingerprint shown on this host before trusting it. The certificate download is public; audio is available only through HTTPS.")
                Text(sharing.certificateFingerprint).font(.caption.monospaced()).textSelection(.enabled)
                Text("Then open Settings → General → About → Certificate Trust Settings and enable trust for this Medio Local Audio certificate. Return here and scan the join QR code.")
                Text("Trust only a host you control. Installing a root certificate grants trust to certificates signed by that host. Remove its profile from the listening device when you no longer need it.")
                Link("Apple’s Certificate Setup Guide", destination: URL(string: "https://support.apple.com/102390")!)
            }
        }
        .navigationTitle("Encrypted Sharing")
        .accessibilityIdentifier("sharing_encryption_page")
    }
}
