import Foundation
import Network
import Combine
import SwiftUI
import UIKit
@preconcurrency import AVFoundation
import Darwin

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
    private var subscription: AnyCancellable?
    private var preparation: Task<Void, Never>?
    private var preparedPath: String?
    private var track: SharedAudioTrack?
    private var sessionID = UUID()
    private var previousIdleTimerDisabled = false

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
        sessionID = UUID()
        let id = sessionID
        accessCode = String(format: "%06u", arc4random_uniform(1_000_000))
        transferredBytes = 0
        isEnabled = true
        status = String(localized: "Starting sharing…")
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let server = LocalAudioHTTPServer(code: accessCode, page: SharingReceiverPage.html) { [weak self] event in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                if case .bytes(let count) = event { self.transferredBytes += count; return }
                guard self.isEnabled else { return }
                switch event {
                case .ready(let port):
                    self.address = URL(string: "http://\(host):\(port)")
                    self.status = String(localized: "Ready for listeners")
                case .failed:
                    self.stop()
                    self.status = String(localized: "Could not start sharing. Check Local Network access in iOS Settings.")
                case .bytes: break
                }
            }
        }
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
        address = nil
        accessCode = ""
        preparedPath = nil
        track = nil
        status = String(localized: "Sharing is off")
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }

    private func update(playback: PlaybackState) {
        guard isEnabled, let server else { return }
        let item = playbackStore.nowPlaying
        if preparedPath != item?.id {
            preparedPath = item?.id
            track = nil
            preparation?.cancel()
            if let item {
                let id = sessionID
                preparation = Task { [weak self] in
                    let candidate = await SharedAudioTrack.prepare(item: item)
                    guard !Task.isCancelled, let self, self.isEnabled, self.sessionID == id,
                          self.preparedPath == item.id else { return }
                    self.track = candidate
                    self.update(playback: self.playbackStore.playback)
                }
            }
        }
        let message = item == nil ? String(localized: "Play a song in Medio to begin.")
            : (track == nil ? String(localized: "This file cannot be shared. Use an unprotected MP3, M4A, AAC, WAV, AIFF, or FLAC audio file.") : "")
        server.update(track: track, state: SharedAudioState(
            track: track?.id, title: item?.title ?? "", artist: item?.artist ?? "",
            position: Double(playback.positionMs) / 1000, playing: playback.isPlaying && track != nil,
            message: message
        ))
    }

    private static func wifiAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            defer { pointer = interface.ifa_next }
            guard String(cString: interface.ifa_name) == "en0", let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

struct SharedAudioTrack: Sendable {
    let id: String
    let url: URL
    let mimeType: String
    let size: Int64

    static func validatedURL(path: String, documents: URL) -> URL? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let root = documents.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.path.hasPrefix(root),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    static func prepare(item: MediaItem) async -> SharedAudioTrack? {
        guard !item.isVideo, let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let url = validatedURL(path: item.id, documents: documents) else { return nil }
        let types = ["mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav",
                     "aif": "audio/aiff", "aiff": "audio/aiff", "flac": "audio/flac"]
        guard let mime = types[url.pathExtension.lowercased()] else { return nil }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.hasProtectedContent)) == false,
              (try? await asset.load(.isPlayable)) == true,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
        return SharedAudioTrack(id: UUID().uuidString, url: url, mimeType: mime, size: Int64(size))
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
    private let code: String
    private let token = UUID().uuidString + UUID().uuidString
    private let page: Data
    private let event: @Sendable (Event) -> Void
    private var listener: NWListener?
    private var connections: [UUID: Peer] = [:]
    private var track: SharedAudioTrack?
    private var state = SharedAudioState()
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

    init(code: String, page: String, restrictToWiFi: Bool = true, event: @escaping @Sendable (Event) -> Void) {
        self.code = code
        self.restrictToWiFi = restrictToWiFi
        self.page = Data(page.utf8)
        self.event = event
    }

    func start() {
        queue.async { [self] in
            do {
                let parameters = NWParameters.tcp
                if restrictToWiFi { parameters.requiredInterfaceType = .wifi }
                parameters.includePeerToPeer = false
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                listener.service = NWListener.Service(name: "Medio Audio", type: "_medio-audio._tcp")
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
            reply(id, type: "application/json", body: (try? JSONEncoder().encode(state)) ?? Data(), head: request.method == "HEAD")
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
    var body: some View {
        Section("Share Audio") {
            Toggle("Share with Other Headphones or Speakers", isOn: Binding(get: { sharing.isEnabled }, set: { $0 ? sharing.start() : sharing.stop() }))
                .accessibilityIdentifier("settings_audio_sharing")
            Text("Open the address below in Safari on another device on the same Wi-Fi, enter the code, and tap Listen. Connect that device to your headphones or speaker.")
                .font(.caption).foregroundStyle(.secondary)
            if let address = sharing.address {
                Text(address.absoluteString).textSelection(.enabled)
                    .accessibilityIdentifier("sharing_address")
                Text("Access code: \(sharing.accessCode)").monospacedDigit()
                    .accessibilityIdentifier("sharing_code")
                Button("Copy Address") { UIPasteboard.general.string = address.absoluteString }
            }
            Text("Local data this session: \(ByteCountFormatter.string(fromByteCount: sharing.transferredBytes, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            Text(sharing.status).font(.caption).foregroundStyle(.secondary)
            Text("Keep Medio open while sharing. Leaving the app stops the session. Use a trusted Wi-Fi network; audio travels locally without encryption. Playback timing and file support depend on the receiving browser.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Share only audio you have permission to share. Protected audio and other apps’ sound are not supported. No internet connection is required.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
