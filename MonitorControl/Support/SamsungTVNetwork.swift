//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Darwin
import Foundation
import Security

enum SamsungTVError: Error {
  case discovery, response, unsupported, authorization, certificate, keychain(OSStatus)
}

struct SamsungTVDevice: Codable {
  static let renderingService = "urn:schemas-upnp-org:service:RenderingControl:1"

  let id: String
  let name: String
  let model: String
  let location: URL

  var address: String { self.location.host ?? "" }
  var label: String { "\(self.name) — \(self.model) (\(self.address))" }
  var remoteAccount: String { self.id + ".remote" }

  func currentAddress() -> Self? {
    if let device = try? Self.describe(location: self.location), device.id == self.id {
      return device
    }
    return try? Self.discover(matching: self.id).first
  }

  static func discover(matching id: String? = nil) throws -> [Self] {
    let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard socket >= 0 else { throw SamsungTVError.discovery }
    defer { Darwin.close(socket) }
    var destination = sockaddr_in()
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    destination.sin_port = in_port_t(1900).bigEndian
    inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)
    let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(self.renderingService)\r\n\r\n"
    let sent = withUnsafePointer(to: &destination) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(socket, request, request.utf8.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard sent == request.utf8.count else { throw SamsungTVError.discovery }

    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var pollDescriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
    var locations: Set<URL> = []
    var buffer = [UInt8](repeating: 0, count: 8192)
    while locations.count < 16 {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0, poll(&pollDescriptor, 1, Int32(remaining * 1000)) > 0,
            pollDescriptor.revents & Int16(POLLIN) != 0 else { break }
      var source = sockaddr_in()
      var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let count = withUnsafeMutablePointer(to: &source) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(socket, &buffer, buffer.count, MSG_DONTWAIT, $0, &sourceLength)
        }
      }
      guard count > 0, let address = inet_ntoa(source.sin_addr) else { continue }
      let reply = String(decoding: buffer.prefix(count), as: UTF8.self)
      if let location = self.location(from: reply, sender: String(cString: address), matching: id) {
        locations.insert(location)
      }
    }

    var devices: [String: Self] = [:]
    for location in locations {
      guard let device = try? self.describe(location: location), id == nil || device.id == id else { continue }
      devices[device.id] = device
      if id != nil { break }
    }
    return devices.values.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
  }

  static func location(from reply: String, sender: String, matching id: String?) -> URL? {
    let lines = reply.components(separatedBy: .newlines)
    guard let status = lines.first, status.hasPrefix("HTTP/1.1 200 ") || status.hasPrefix("HTTP/1.0 200 ") else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1)
      if parts.count == 2 {
        headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    guard let value = headers["location"], let url = URL(string: value),
          url.scheme?.lowercased() == "http", url.host == sender, url.user == nil, url.password == nil else { return nil }
    // Some renderers omit USN. The device description is always checked before use.
    if let id = id, let usn = headers["usn"], usn.lowercased().hasPrefix("uuid:"),
       usn.components(separatedBy: "::").first?.lowercased() != id {
      return nil
    }
    return url
  }

  static func describe(location: URL) throws -> Self {
    let xml = try SamsungTVXML.parse(SamsungTVHTTP.fetch(URLRequest(url: location)))
    guard let device = xml.child("device"),
          device.child("manufacturer")?.value.lowercased().hasPrefix("samsung") == true,
          let id = device.child("UDN")?.value.lowercased(), id.hasPrefix("uuid:"), id.count > 5,
          device.child("serviceList")?.children.contains(where: { $0.child("serviceType")?.value == self.renderingService }) == true else {
      throw SamsungTVError.response
    }
    return Self(id: id, name: device.child("friendlyName")?.value ?? "Samsung TV",
                model: device.child("modelName")?.value ?? "Samsung", location: location)
  }

  func pair() throws -> SamsungTVCredential {
    guard let url = URL(string: "https://\(self.address):1516/") else { throw SamsungTVError.response }
    let transport = SamsungTVHTTP()
    let result = try transport.rpc(url: url, method: "createAccessToken", timeout: 65)
    guard let certificate = transport.certificate, let token = result["AccessToken"] as? String, !token.isEmpty else {
      throw SamsungTVError.authorization
    }
    return SamsungTVCredential(token: token, certificate: certificate)
  }

  func backlight(using credential: SamsungTVCredential, setting value: Int? = nil) throws -> Int? {
    var parameters: [String: Any] = [:]
    if let value = value { parameters["backlight"] = value }
    let result = try self.ipControl("backlightControl", using: credential, parameters: parameters)
    if value != nil { return nil }
    let backlight = result["backlight"] as? Int ?? (result["backlight"] as? String).flatMap(Int.init)
    guard let level = backlight, (0 ... 50).contains(level) else { throw SamsungTVError.unsupported }
    return level
  }

  func ipVolume(using credential: SamsungTVCredential, setting value: Int? = nil) throws -> Int? {
    let result = try self.ipControl("directVolumeControl", using: credential, parameters: value.map { ["volume": $0] } ?? [:])
    if value != nil { return nil }
    let volume = result["volume"] as? Int ?? (result["volume"] as? String).flatMap(Int.init)
    guard let level = volume, (0 ... 100).contains(level) else { throw SamsungTVError.unsupported }
    return level
  }

  func ipMute(using credential: SamsungTVCredential, setting value: Int? = nil) throws -> Int? {
    let result = try self.ipControl("muteControl", using: credential, parameters: value.map { ["mute": $0 == 0 ? "muteOff" : "muteOn"] } ?? [:])
    if value != nil { return nil }
    switch result["mute"] as? String {
    case "muteOff": return 0
    case "muteOn": return 1
    default: throw SamsungTVError.unsupported
    }
  }

  private func ipControl(_ method: String, using credential: SamsungTVCredential, parameters: [String: Any]) throws -> [String: Any] {
    guard let url = URL(string: "https://\(self.address):1516/") else { throw SamsungTVError.response }
    var authenticated = parameters
    authenticated["AccessToken"] = credential.token
    return try SamsungTVHTTP(certificate: credential.certificate).rpc(url: url, method: method, parameters: authenticated)
  }
}

struct SamsungTVCredential: Codable {
  let token: String
  let certificate: Data

  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "MonitorControl") + ".SamsungTV",
      kSecAttrAccount as String: account,
    ]
  }

  static func load(_ account: String) throws -> Self {
    var query = self.query(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { throw SamsungTVError.keychain(status) }
    return try JSONDecoder().decode(Self.self, from: data)
  }

  func save(_ account: String) throws {
    let query = Self.query(account)
    let attributes = [kSecValueData as String: try JSONEncoder().encode(self)]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw SamsungTVError.keychain(status) }
  }

  static func remove(_ account: String) throws {
    let status = SecItemDelete(self.query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw SamsungTVError.keychain(status) }
  }
}

private final class SamsungTVHTTP: NSObject, URLSessionTaskDelegate {
  private let expectedCertificate: Data?
  private(set) var certificate: Data?
  private(set) var rejectedCertificate = false

  init(certificate: Data? = nil) { self.expectedCertificate = certificate }

  static func fetch(_ request: URLRequest) throws -> Data {
    try SamsungTVHTTP().send(request, timeout: 2)
  }

  func rpc(url: URL, method: String, parameters: [String: Any]? = nil, timeout: TimeInterval = 2) throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var body: [String: Any] = ["jsonrpc": "2.0", "id": "1", "method": method]
    if let parameters = parameters { body["params"] = parameters }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let data = try self.send(request, timeout: timeout)
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SamsungTVError.response
    }
    let code = (response["error"] as? [String: Any])?["code"] as? Int ?? response["code"] as? Int
    switch code {
    case -32010, -32700: throw SamsungTVError.authorization
    case -32601, -32001, -32003: throw SamsungTVError.unsupported
    case .some: throw SamsungTVError.response
    case nil: break
    }
    guard let result = response["result"], !(result is NSNull) else { throw SamsungTVError.response }
    return result as? [String: Any] ?? [:]
  }

  static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.connectionProxyDictionary = [:]
    return configuration
  }

  static func wait<Value>(timeout: TimeInterval,
                          start: (@escaping (Result<Value, Error>) -> Void) -> Void) throws -> Value {
    let done = DispatchSemaphore(value: 0)
    var result: Result<Value, Error> = .failure(SamsungTVError.response)
    start {
      result = $0
      done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else { throw URLError(.timedOut) }
    return try result.get()
  }

  private func send(_ request: URLRequest, timeout: TimeInterval) throws -> Data {
    let session = URLSession(configuration: Self.configuration(timeout: timeout), delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    return try Self.wait(timeout: timeout + 1) { completion in
      session.dataTask(with: request) { data, response, error in
        if self.rejectedCertificate {
          completion(.failure(SamsungTVError.certificate))
        } else if let error = error {
          completion(.failure(error))
        } else if let status = (response as? HTTPURLResponse)?.statusCode, (200 ... 299).contains(status),
                  let data = data, data.count <= 256 * 1024 {
          completion(.success(data))
        } else {
          completion(.failure(SamsungTVError.response))
        }
      }.resume()
    }
  }

  func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                  newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  private static func leaf(of trust: SecTrust) -> SecCertificate? {
    if #available(macOS 12.0, *) {
      return (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }
    return SecTrustGetCertificateAtIndex(trust, 0)
  }

  func urlSession(_: URLSession, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust, let leaf = Self.leaf(of: trust) else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    let certificate = SecCertificateCopyData(leaf) as Data
    if let expected = self.expectedCertificate, certificate != expected {
      self.rejectedCertificate = true
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    // Initial trust is established by the on-screen pairing approval. Subsequent requests pin that leaf.
    self.certificate = certificate
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}

final class SamsungTVXML: NSObject, XMLParserDelegate {
  let name: String
  private var text = ""
  private(set) var children: [SamsungTVXML] = []
  private var stack: [SamsungTVXML] = []

  private init(_ name: String) { self.name = name }

  var value: String { self.text.trimmingCharacters(in: .whitespacesAndNewlines) }

  func child(_ name: String) -> SamsungTVXML? { self.children.first { $0.name == name } }

  static func parse(_ data: Data) throws -> SamsungTVXML {
    let root = SamsungTVXML("")
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = root
    guard parser.parse(), let document = root.children.first else { throw SamsungTVError.response }
    return document
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String]) {
    guard self.stack.count < 32 else {
      parser.abortParsing()
      return
    }
    let element = SamsungTVXML(elementName)
    (self.stack.last ?? self).children.append(element)
    self.stack.append(element)
  }

  func parser(_: XMLParser, foundCharacters string: String) { self.stack.last?.text += string }

  func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
    _ = self.stack.popLast()
  }
}

enum SamsungTVRemoteKey: String {
  case volumeUp = "KEY_VOLUP"
  case volumeDown = "KEY_VOLDOWN"
  case mute = "KEY_MUTE"
}

@available(macOS 10.15, *)
extension SamsungTVDevice {
  func pairRemote() throws -> SamsungTVCredential {
    guard let credential = try self.remote(keys: [], using: nil) else { throw SamsungTVError.authorization }
    return credential
  }

  func sendRemote(_ keys: [SamsungTVRemoteKey], using credential: SamsungTVCredential) throws {
    _ = try self.remote(keys: keys, using: credential)
  }

  private func remote(keys: [SamsungTVRemoteKey], using credential: SamsungTVCredential?) throws -> SamsungTVCredential? {
    var url = URLComponents()
    url.scheme = "wss"
    url.host = self.address
    url.port = 8002
    url.path = "/api/v2/channels/samsung.remote.control"
    url.queryItems = [URLQueryItem(name: "name", value: Data("MonitorControl".utf8).base64EncodedString())]
    if let token = credential?.token, !token.isEmpty {
      url.queryItems?.append(URLQueryItem(name: "token", value: token))
    }
    guard let endpoint = url.url else { throw SamsungTVError.response }
    let transport = SamsungTVHTTP(certificate: credential?.certificate)
    let session = URLSession(configuration: SamsungTVHTTP.configuration(timeout: 65), delegate: transport, delegateQueue: nil)
    let socket = session.webSocketTask(with: endpoint)
    socket.resume()
    defer {
      socket.cancel(with: .normalClosure, reason: nil)
      session.invalidateAndCancel()
    }

    let timeout: TimeInterval = credential == nil ? 62 : 3
    let connected: URLSessionWebSocketTask.Message
    do {
      connected = try SamsungTVHTTP.wait(timeout: timeout) { socket.receive(completionHandler: $0) }
    } catch {
      if transport.rejectedCertificate { throw SamsungTVError.certificate }
      throw error
    }
    let data: Data
    switch connected {
    case let .string(string): data = Data(string.utf8)
    case let .data(bytes): data = bytes
    @unknown default: throw SamsungTVError.response
    }
    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          response["event"] as? String == "ms.channel.connect" else { throw SamsungTVError.authorization }

    if credential == nil {
      guard let certificate = transport.certificate else { throw SamsungTVError.certificate }
      let payload = response["data"] as? [String: Any]
      let token = payload?["token"] as? String ?? ""
      return SamsungTVCredential(token: token, certificate: certificate)
    }

    for key in keys {
      let message = """
      {"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"\(key.rawValue)","Option":"false","TypeOfRemote":"SendRemoteKey"}}
      """
      _ = try SamsungTVHTTP.wait(timeout: 2) { (completion: @escaping (Result<Void, Error>) -> Void) in
        socket.send(.string(message)) { error in
          if let error = error { completion(.failure(error)) } else { completion(.success(())) }
        }
      }
      Thread.sleep(forTimeInterval: 0.08)
    }
    return nil
  }
}
