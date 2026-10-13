// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import Foundation

/// Unix-socket server. Each connection sends one JSON line and receives one JSON line back.
final class IPCServer: @unchecked Sendable {
    typealias Handler = @MainActor ([String: Any]) -> [String: Any]

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let clients = DispatchQueue(label: "notchcast.ipc", attributes: .concurrent)
    private static let maxRequestBytes = 2 * 1024 * 1024

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// True when another instance is already listening on `path`.
    static func isListening(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = makeAddress(path)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }
        var addr = Self.makeAddress(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        chmod(path, 0o600)

        let fd = listenFD
        Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                self?.clients.async { self?.serve(client) }
            }
        }.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < Self.maxRequestBytes {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(chunk, count: n)
            if chunk[n - 1] == UInt8(ascii: "\n") { break }
        }

        let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let handler = self.handler
        let reply: [String: Any] = DispatchQueue.main.sync {
            MainActor.assumeIsolated { handler(request) }
        }
        guard var out = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return }
        out.append(UInt8(ascii: "\n"))
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
    }

    private static func makeAddress(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return addr
    }
}
