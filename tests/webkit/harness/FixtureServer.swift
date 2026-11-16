// A small HTTP/1.1 server on 127.0.0.1 for the watch fixtures: the manifest,
// the subtitle files and the video. Every response carries CORS headers
// (the page's origin is https://www.netflix.com) and supports byte ranges,
// which media loading needs.
import Foundation
import Network

@MainActor
final class FixtureServer {
  struct Request {
    let method: String
    let path: String // without the query string
    let query: String
    let headers: [String: String] // lowercased names
    let body: Data
  }

  struct Response {
    var status = 200
    var contentType = "text/plain; charset=utf-8"
    var body = Data()
    static func notFound() -> Response { Response(status: 404, body: Data("not found".utf8)) }
  }

  typealias Handler = @MainActor (Request) -> Response

  private var listener: NWListener?
  private var routes: [String: Handler] = [:]
  private(set) var port: UInt16 = 0
  /// "METHOD /path" for every request, in order.
  private(set) var requests: [String] = []
  private(set) var bodies: [String: [Data]] = [:]
  /// Requests answered with 206 Partial Content.
  private(set) var rangeRequests = 0

  var origin: String { "http://127.0.0.1:\(port)" }

  func route(_ path: String, _ handler: @escaping Handler) { routes[path] = handler }

  func serveFile(_ path: String, file: URL, contentType: String) {
    route(path) { _ in
      guard let data = try? Data(contentsOf: file) else { return .notFound() }
      return Response(status: 200, contentType: contentType, body: data)
    }
  }

  func start() async throws {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    params.allowLocalEndpointReuse = true
    let l = try NWListener(using: params)
    listener = l
    l.newConnectionHandler = { [weak self] conn in
      MainActor.assumeIsolated { self?.accept(conn) }
    }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      var resumed = false
      l.stateUpdateHandler = { state in
        MainActor.assumeIsolated {
          guard !resumed else { return }
          switch state {
          case .ready: resumed = true; c.resume()
          case .failed(let e): resumed = true; c.resume(throwing: e)
          default: break
          }
        }
      }
      l.start(queue: .main)
    }
    port = l.port?.rawValue ?? 0
  }

  private func accept(_ conn: NWConnection) {
    conn.start(queue: .main)
    receive(conn, buffer: Data())
  }

  private func receive(_ conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
      MainActor.assumeIsolated {
        guard let self else { return }
        var buf = buffer
        if let data { buf.append(data) }
        if let request = self.parse(buf) {
          self.respond(conn, request)
        } else if isComplete || error != nil {
          conn.cancel()
        } else {
          self.receive(conn, buffer: buf)
        }
      }
    }
  }

  /// Returns the request once the head and its Content-Length body arrived.
  private func parse(_ buf: Data) -> Request? {
    guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: buf[buf.startIndex..<headEnd.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let parts = lines.removeFirst().split(separator: " ")
    guard parts.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "") ?? 0
    let body = buf[headEnd.upperBound...]
    if body.count < length { return nil }
    let target = String(parts[1])
    let pathEnd = target.firstIndex(of: "?") ?? target.endIndex
    return Request(method: String(parts[0]), path: String(target[..<pathEnd]),
                   query: pathEnd < target.endIndex ? String(target[target.index(after: pathEnd)...]) : "",
                   headers: headers, body: Data(body.prefix(length)))
  }

  private func respond(_ conn: NWConnection, _ req: Request) {
    requests.append(req.method + " " + req.path)
    if !req.body.isEmpty { bodies[req.path, default: []].append(req.body) }
    var res: Response
    if req.method == "OPTIONS" {
      res = Response(status: 204)
    } else if let handler = routes[req.path] {
      res = handler(req)
    } else {
      res = .notFound()
    }
    var headers: [(String, String)] = [
      ("Access-Control-Allow-Origin", req.headers["origin"] ?? "*"),
      ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
      ("Access-Control-Allow-Headers", req.headers["access-control-request-headers"] ?? "*"),
      ("Access-Control-Allow-Private-Network", "true"),
      ("Cache-Control", "no-store"),
      ("Connection", "close"),
      ("Content-Type", res.contentType),
      ("Accept-Ranges", "bytes"),
    ]
    var body = res.body
    if res.status == 200, let range = req.headers["range"], let r = FixtureServer.byteRange(range, total: body.count) {
      res.status = 206
      rangeRequests += 1
      headers.append(("Content-Range", "bytes \(r.lowerBound)-\(r.upperBound)/\(body.count)"))
      body = body.subdata(in: r.lowerBound..<(r.upperBound + 1))
    }
    headers.append(("Content-Length", String(body.count)))
    let reason = [200: "OK", 204: "No Content", 206: "Partial Content", 404: "Not Found"][res.status] ?? "Status"
    var head = "HTTP/1.1 \(res.status) \(reason)\r\n"
    for (k, v) in headers { head += "\(k): \(v)\r\n" }
    head += "\r\n"
    var out = Data(head.utf8)
    if req.method != "HEAD" { out.append(body) }
    conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
  }

  /// "bytes=a-b", "bytes=a-" or "bytes=-n" as a closed range, or nil.
  static func byteRange(_ header: String, total: Int) -> ClosedRange<Int>? {
    guard total > 0, header.hasPrefix("bytes=") else { return nil }
    let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
    let ends = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    guard ends.count == 2 else { return nil }
    if ends[0].isEmpty, let n = Int(ends[1]), n > 0 { return max(0, total - n)...(total - 1) }
    guard let a = Int(ends[0]), a < total else { return nil }
    let b = Int(ends[1]).map { min($0, total - 1) } ?? (total - 1)
    return a <= b ? a...b : nil
  }

  func stop() { listener?.cancel() }
}
