//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import IOKit
import os.log

let ARM64_DDC_7BIT_ADDRESS: UInt8 = 0x37 // This works with DisplayPort devices
let ARM64_DDC_DATA_ADDRESS: UInt8 = 0x51

class Arm64DDC: NSObject {
  #if arch(arm64)
    static let isArm64: Bool = true
  #else
    static let isArm64: Bool = false
  #endif
  static let MAX_MATCH_SCORE: Int = 20

  struct EDIDIdentity: Hashable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    init(displayID: CGDirectDisplayID) {
      self.vendor = CGDisplayVendorNumber(displayID)
      self.model = CGDisplayModelNumber(displayID)
      self.serial = CGDisplaySerialNumber(displayID)
    }

    init?(edid: [UInt8]) {
      guard edid.count == 128,
            edid.prefix(8).elementsEqual([0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]),
            edid.reduce(0, &+) == 0
      else {
        return nil
      }
      self.vendor = UInt32(edid[8]) << 8 | UInt32(edid[9])
      self.model = UInt32(edid[10]) | UInt32(edid[11]) << 8
      self.serial = UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24
    }

    func isCompatible(with identity: EDIDIdentity) -> Bool {
      self.vendor == identity.vendor && self.model == identity.model &&
        (self.serial == identity.serial || self.serial == 0 || identity.serial == 0)
    }
  }

  struct IOregService {
    var edidUUID: String = ""
    var manufacturerID: String = ""
    var productName: String = ""
    var serialNumber: Int64 = 0
    var alphanumericSerialNumber: String = ""
    var location: String = ""
    var ioDisplayLocation: String = ""
    var transportUpstream: String = ""
    var transportDownstream: String = ""
    var service: IOAVService?
    var serviceLocation: Int = 0
    var registryID: UInt64 = 0
    var edidIdentity: EDIDIdentity?
    var cachedIdentity: EDIDIdentity?
    var edidReadStatus: IOReturn = kIOReturnNotReady
    var displayAttributes: NSDictionary?
  }

  struct Arm64Service {
    var displayID: CGDirectDisplayID = 0
    var service: IOAVService?
    var serviceLocation: Int = 0
    var discouraged: Bool = false
    var dummy: Bool = false
    var serviceDetails: IOregService
    var matchScore: Int = 0
  }

  static func getServiceMatches(displayIDs: [CGDirectDisplayID]) -> [Arm64Service] {
    self.getServiceMatches(displayIDs: displayIDs, services: self.getIoregServicesForMatching())
  }

  static func recoveryCandidates(for id: CGDirectDisplayID, among ids: [CGDirectDisplayID]) -> [IOregService] {
    let identity = EDIDIdentity(displayID: id)
    let services = self.getIoregServicesForMatching(target: identity)
    let matches = self.getServiceMatches(displayIDs: ids, services: services)
    let preferred = matches.first { $0.displayID == id }?.serviceDetails
    var candidates = preferred.map { [$0] } ?? []
    guard ids.filter({ identity.isCompatible(with: EDIDIdentity(displayID: $0)) }).count == 1 else { return candidates }
    let assigned = Set(matches.map { $0.serviceDetails.registryID })
    candidates += services.filter { candidate in
      candidate.service != nil && !assigned.contains(candidate.registryID) &&
        (candidate.edidIdentity ?? candidate.cachedIdentity)?.isCompatible(with: identity) == true
    }
    return candidates
  }

  private static func getServiceMatches(displayIDs: [CGDirectDisplayID], services: [IOregService]) -> [Arm64Service] {
    let ioregServicesForMatching = services.filter { $0.service != nil }
    let displaysByIdentity = Dictionary(grouping: displayIDs) { EDIDIdentity(displayID: $0) }
    let servicesByIdentity = Dictionary(grouping: ioregServicesForMatching, by: \.edidIdentity)
    var matchedDisplayServices: [Arm64Service] = []
    var takenServiceLocations = Set<Int>()
    var takenRegistryIDs = Set<UInt64>()
    var takenDisplayIDs = Set<CGDirectDisplayID>()
    // A framebuffer can be followed by several proxies, including inactive ones.
    // Prefer the proxy whose live EDID identifies this display before scoring registry metadata.
    for displayID in displayIDs {
      let identity = EDIDIdentity(displayID: displayID)
      guard identity.serial != 0, displaysByIdentity[identity]?.count == 1,
            let candidates = servicesByIdentity[identity], candidates.count == 1,
            let candidate = candidates.first, takenRegistryIDs.insert(candidate.registryID).inserted
      else {
        continue
      }
      matchedDisplayServices.append(self.serviceMatch(displayID: displayID, candidate: candidate, score: self.MAX_MATCH_SCORE))
      takenDisplayIDs.insert(displayID)
      takenServiceLocations.insert(candidate.serviceLocation)
    }

    var scoredCandidateDisplayServices: [Int: [Arm64Service]] = [:]
    for displayID in displayIDs where !takenDisplayIDs.contains(displayID) {
      let identity = EDIDIdentity(displayID: displayID)
      for ioregServiceForMatching in ioregServicesForMatching where !takenRegistryIDs.contains(ioregServiceForMatching.registryID) {
        // Keep the metadata fallback for unreadable EDIDs and overrides, but
        // never point it at a proxy known to serve a different online display.
        if let cached = ioregServiceForMatching.cachedIdentity, !cached.isCompatible(with: identity) { continue }
        let liveIdentity = ioregServiceForMatching.edidIdentity
        if let liveIdentity, !liveIdentity.isCompatible(with: identity),
           displaysByIdentity.keys.contains(where: { liveIdentity.isCompatible(with: $0) })
        {
          continue
        }
        let score = self.ioregMatchScore(displayID: displayID, ioregEdidUUID: ioregServiceForMatching.edidUUID, ioDisplayLocation: ioregServiceForMatching.ioDisplayLocation, ioregProductName: ioregServiceForMatching.productName, ioregSerialNumber: ioregServiceForMatching.serialNumber, serviceLocation: ioregServiceForMatching.serviceLocation)
        guard score > 0 else {
          continue
        }
        let displayService = self.serviceMatch(displayID: displayID, candidate: ioregServiceForMatching, score: score)
        // Ties still use registry topology to distinguish identical displays.
        let priority = score * 4 + (liveIdentity?.isCompatible(with: identity) == true ? 2 : 0) + (ioregServiceForMatching.cachedIdentity?.isCompatible(with: identity) == true ? 1 : 0)
        scoredCandidateDisplayServices[priority, default: []].append(displayService)
      }
    }
    for score in scoredCandidateDisplayServices.keys.sorted(by: >) {
      for candidate in scoredCandidateDisplayServices[score, default: []] {
        guard !takenDisplayIDs.contains(candidate.displayID),
              !takenServiceLocations.contains(candidate.serviceLocation),
              takenRegistryIDs.insert(candidate.serviceDetails.registryID).inserted
        else {
          continue
        }
        takenDisplayIDs.insert(candidate.displayID)
        takenServiceLocations.insert(candidate.serviceLocation)
        matchedDisplayServices.append(candidate)
      }
    }
    return matchedDisplayServices
  }

  private static func serviceMatch(displayID: CGDirectDisplayID, candidate: IOregService, score: Int) -> Arm64Service {
    Arm64Service(displayID: displayID, service: candidate.service, serviceLocation: candidate.serviceLocation, discouraged: self.checkIfDiscouraged(ioregService: candidate), dummy: self.checkIfDummy(ioregService: candidate), serviceDetails: candidate, matchScore: score)
  }

  static func read(service: IOAVService?, command: UInt8, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil, transportFailure: ((IOReturn) -> Void)? = nil) -> (current: UInt16, max: UInt16)? {
    var values: (UInt16, UInt16)?
    var send: [UInt8] = [command]
    var reply = [UInt8](repeating: 0, count: 11)
    if Self.performDDCCommunication(service: service, send: &send, reply: &reply, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, readSleepTime: readSleepTime, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime, transportFailure: transportFailure),
       reply[2] == 0x02, reply[3] == 0, reply[4] == command {
      let max = UInt16(reply[6]) * 256 + UInt16(reply[7])
      let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
      values = (current, max)
    } else {
      values = nil
    }
    return values
  }

  static func write(service: IOAVService?, command: UInt8, value: UInt16, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> Bool {
    var send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 255)]
    var reply: [UInt8] = []
    return Self.performDDCCommunication(service: service, send: &send, reply: &reply, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime)
  }

  static func performDDCCommunication(service: IOAVService?, send: inout [UInt8], reply: inout [UInt8], writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil, transportFailure: ((IOReturn) -> Void)? = nil) -> Bool {
    let dataAddress = ARM64_DDC_DATA_ADDRESS
    var lastStatus = kIOReturnSuccess
    guard let service else {
      transportFailure?(kIOReturnNoDevice)
      return false
    }
    var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0] // Note: the last byte is the place of the checksum, see next line!
    packet[packet.count - 1] = self.checksum(chk: send.count == 1 ? ARM64_DDC_7BIT_ADDRESS << 1 : ARM64_DDC_7BIT_ADDRESS << 1 ^ dataAddress, data: &packet, start: 0, end: packet.count - 2)
    for _ in 1 ... (numOfRetryAttemps ?? 4) + 1 {
      for _ in 1 ... max((numOfWriteCycles ?? 2) + 0, 1) {
        usleep(writeSleepTime ?? 10000)
        lastStatus = IOAVServiceWriteI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(dataAddress), &packet, UInt32(packet.count))
        if lastStatus != kIOReturnSuccess { break }
      }
      // A failed request cannot have a valid reply. Leave recovery to rediscovery.
      if lastStatus == kIOReturnBusy || lastStatus == kIOReturnNotReady {
        usleep(retrySleepTime ?? 20000)
        continue
      }
      guard lastStatus == kIOReturnSuccess else { break }
      if reply.isEmpty { return true }
      usleep(readSleepTime ?? 50000)
      lastStatus = IOAVServiceReadI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), 0, &reply, UInt32(reply.count))
      guard lastStatus == kIOReturnSuccess else { break }
      if self.checksum(chk: 0x50, data: &reply, start: 0, end: reply.count - 2) == reply[reply.count - 1] {
        return true
      }
      usleep(retrySleepTime ?? 20000)
    }
    if lastStatus != kIOReturnSuccess { transportFailure?(lastStatus) }
    return false
  }

  /// DDC checksum calculator
  static func checksum(chk: UInt8, data: inout [UInt8], start: Int, end: Int) -> UInt8 {
    var chkd: UInt8 = chk
    for i in start ... end {
      chkd ^= data[i]
    }
    return chkd
  }

  static func ioregMatchScore(displayID: CGDirectDisplayID, ioregEdidUUID: String, ioDisplayLocation: String = "", ioregProductName: String = "", ioregSerialNumber: Int64 = 0, serviceLocation _: Int = 0) -> Int {
    var matchScore = 0
    if let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary? {
      if let kDisplayYearOfManufacture = dictionary[kDisplayYearOfManufacture] as? Int64, let kDisplayWeekOfManufacture = dictionary[kDisplayWeekOfManufacture] as? Int64, let kDisplayVendorID = dictionary[kDisplayVendorID] as? Int64, let kDisplayProductID = dictionary[kDisplayProductID] as? Int64, let kDisplayVerticalImageSize = dictionary[kDisplayVerticalImageSize] as? Int64, let kDisplayHorizontalImageSize = dictionary[kDisplayHorizontalImageSize] as? Int64 {
        struct KeyLoc {
          var key: String
          var loc: Int
        }
        let edidUUIDSearchKeys: [KeyLoc] = [
          // Vendor ID
          KeyLoc(key: String(format: "%04x", UInt16(max(0, min(kDisplayVendorID, 256 * 256 - 1)))).uppercased(), loc: 0),
          // Product ID
          KeyLoc(key: String(format: "%02x", UInt8((UInt16(max(0, min(kDisplayProductID, 256 * 256 - 1))) >> (0 * 8)) & 0xFF)).uppercased()
            + String(format: "%02x", UInt8((UInt16(max(0, min(kDisplayProductID, 256 * 256 - 1))) >> (1 * 8)) & 0xFF)).uppercased(), loc: 4),
          // Manufacture date
          KeyLoc(key: String(format: "%02x", UInt8(max(0, min(kDisplayWeekOfManufacture, 256 - 1)))).uppercased()
            + String(format: "%02x", UInt8(max(0, min(kDisplayYearOfManufacture - 1990, 256 - 1)))).uppercased(), loc: 19),
          // Image size
          KeyLoc(key: String(format: "%02x", UInt8(max(0, min(kDisplayHorizontalImageSize / 10, 256 - 1)))).uppercased()
            + String(format: "%02x", UInt8(max(0, min(kDisplayVerticalImageSize / 10, 256 - 1)))).uppercased(), loc: 30),
        ]
        for searchKey in edidUUIDSearchKeys where searchKey.key != "0000" && searchKey.key == ioregEdidUUID.prefix(searchKey.loc + 4).suffix(4) {
          matchScore += 1
        }
      }
      if ioDisplayLocation != "", let kIODisplayLocation = dictionary[kIODisplayLocationKey] as? String, ioDisplayLocation == kIODisplayLocation {
        matchScore += 10
      }
      if ioregProductName != "", let nameList = dictionary["DisplayProductName"] as? [String: String], let name = nameList["en_US"] ?? nameList.first?.value, name.lowercased() == ioregProductName.lowercased() {
        matchScore += 1
      }
      if ioregSerialNumber != 0, let serial = dictionary[kDisplaySerialNumber] as? Int64, serial == ioregSerialNumber {
        matchScore += 1
      }
    }
    return matchScore
  }

  static func ioregIterateToNextObjectOfInterest(interests: [String], iterator: io_iterator_t) -> (name: String, entry: io_service_t)? {
    let name = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer {
      name.deallocate()
    }
    while true {
      let entry = IOIteratorNext(iterator)
      guard entry != IO_OBJECT_NULL else {
        return nil
      }
      if IORegistryEntryGetName(entry, name) == KERN_SUCCESS {
        let nameString = String(cString: name)
        if interests.contains(where: { nameString.contains($0) }) {
          return (nameString, entry)
        }
      }
      IOObjectRelease(entry)
    }
  }

  static func getIORegServiceAppleCDC2Properties(entry: io_service_t) -> IOregService {
    var ioregService = IOregService()
    if let unmanagedEdidUUID = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let edidUUID = unmanagedEdidUUID.takeRetainedValue() as? String {
      ioregService.edidUUID = edidUUID
    }
    let cpath = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
    defer { cpath.deallocate() }
    IORegistryEntryGetPath(entry, kIOServicePlane, cpath)
    ioregService.ioDisplayLocation = String(cString: cpath)
    if let unmanagedDisplayAttrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let displayAttrs = unmanagedDisplayAttrs.takeRetainedValue() as? NSDictionary {
      ioregService.displayAttributes = displayAttrs
      if let productAttrs = displayAttrs.value(forKey: "ProductAttributes") as? NSDictionary {
        if let manufacturerID = productAttrs.value(forKey: "ManufacturerID") as? String {
          ioregService.manufacturerID = manufacturerID
        }
        if let productName = productAttrs.value(forKey: "ProductName") as? String {
          ioregService.productName = productName
        }
        if let serialNumber = productAttrs.value(forKey: "SerialNumber") as? Int64 {
          ioregService.serialNumber = serialNumber
        }
        if let alphanumericSerialNumber = productAttrs.value(forKey: "AlphanumericSerialNumber") as? String {
          ioregService.alphanumericSerialNumber = alphanumericSerialNumber
        }
      }
    }
    if let unmanagedTransport = IORegistryEntryCreateCFProperty(entry, "Transport" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let transport = unmanagedTransport.takeRetainedValue() as? NSDictionary {
      if let upstream = transport.value(forKey: "Upstream") as? String {
        ioregService.transportUpstream = upstream
      }
      if let downstream = transport.value(forKey: "Downstream") as? String {
        ioregService.transportDownstream = downstream
      }
    }
    return ioregService
  }

  static func setIORegServiceDCPAVServiceProxy(entry: io_service_t, ioregService: inout IOregService, target: EDIDIdentity?) {
    IORegistryEntryGetRegistryEntryID(entry, &ioregService.registryID)
    if let unmanagedLocation = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let location = unmanagedLocation.takeRetainedValue() as? String {
      ioregService.location = location
      if location == "External", let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
        if let target {
          ioregService.cachedIdentity = self.cachedIdentity(of: service)
          // Skip healthy monitors on other ports during background recovery.
          if let cached = ioregService.cachedIdentity, !cached.isCompatible(with: target) { return }
        }
        var bytes = [UInt8](repeating: 0, count: 128)
        let status = IOAVServiceReadI2C(service, 0x50, 0, &bytes, UInt32(bytes.count))
        ioregService.edidReadStatus = status
        // Detached proxies can retain the framebuffer name and even a cached EDID.
        guard status != kIOReturnNoDevice, status != kIOReturnNotAttached else { return }
        ioregService.service = service
        if status == kIOReturnSuccess { ioregService.edidIdentity = EDIDIdentity(edid: bytes) }
        if ioregService.edidIdentity == nil {
          if target == nil { ioregService.cachedIdentity = self.cachedIdentity(of: service) }
          os_log("Display proxy %{public}llu live EDID status 0x%{public}x", type: .info, ioregService.registryID, status)
        }
      }
    }
  }

  private static func cachedIdentity(of service: IOAVService) -> EDIDIdentity? {
    var cached: Unmanaged<CFData>?
    let result = IOAVServiceCopyEDID(service, &cached)
    guard let data = cached?.takeRetainedValue() as Data?, result == kIOReturnSuccess else { return nil }
    return EDIDIdentity(edid: Array(data.prefix(128)))
  }

  static func getIoregServicesForMatching(target: EDIDIdentity? = nil) -> [IOregService] {
    var serviceLocation = 0
    var proxies: [(entry: io_service_t, framebuffer: IOregService)] = []
    let ioregRoot: io_registry_entry_t = IORegistryGetRootEntry(kIOMasterPortDefault)
    defer {
      IOObjectRelease(ioregRoot)
    }
    var iterator = io_iterator_t()
    defer {
      IOObjectRelease(iterator)
    }
    var ioregService = IOregService()
    guard IORegistryEntryCreateIterator(ioregRoot, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
      return []
    }
    let keyDCPAVServiceProxy = "DCPAVServiceProxy"
    let keysFramebuffer = ["AppleCLCD2", "IOMobileFramebufferShim"]
    while true {
      guard let objectOfInterest = ioregIterateToNextObjectOfInterest(interests: [keyDCPAVServiceProxy] + keysFramebuffer, iterator: iterator) else {
        break
      }
      if keysFramebuffer.contains(objectOfInterest.name) {
        ioregService = self.getIORegServiceAppleCDC2Properties(entry: objectOfInterest.entry)
        IOObjectRelease(objectOfInterest.entry)
        serviceLocation += 1
        ioregService.serviceLocation = serviceLocation
      } else if objectOfInterest.name == keyDCPAVServiceProxy {
        proxies.append((objectOfInterest.entry, ioregService))
      } else {
        IOObjectRelease(objectOfInterest.entry)
      }
    }
    // Opening an AV service adds a user client to the registry. Finish walking
    // the registry first so our own I/O cannot invalidate its recursive iterator.
    return proxies.map { proxy in
      defer { IOObjectRelease(proxy.entry) }
      var candidate = proxy.framebuffer
      self.setIORegServiceDCPAVServiceProxy(entry: proxy.entry, ioregService: &candidate, target: target)
      return candidate
    }
  }

  static func checkIfDummy(ioregService: IOregService) -> Bool {
    if ioregService.manufacturerID == "AOC", ioregService.productName == "28E850" {
      return true
    }
    return false
  }

  static func checkIfDiscouraged(ioregService _: IOregService) -> Bool {
    false
  }
}

// IOKit can publish a replacement DDC endpoint without changing the desktop layout.
final class DDCServiceObserver {
  private let port: IONotificationPortRef
  private var added: io_iterator_t = 0
  private var removed: io_iterator_t = 0
  private let changed: (Bool, Set<UInt64>) -> Void

  init?(changed: @escaping (Bool, Set<UInt64>) -> Void) {
    guard let port = IONotificationPortCreate(kIOMasterPortDefault) else { return nil }
    self.port = port
    self.changed = changed
    IONotificationPortSetDispatchQueue(port, .main)
    let context = Unmanaged.passUnretained(self).toOpaque()
    let callback: IOServiceMatchingCallback = { context, iterator in
      guard let context else { return }
      let observer = Unmanaged<DDCServiceObserver>.fromOpaque(context).takeUnretainedValue()
      let ids = DDCServiceObserver.drain(iterator)
      if !ids.isEmpty { observer.changed(iterator == observer.added, ids) }
    }
    guard IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("DCPAVServiceProxy"), callback, context, &self.added) == KERN_SUCCESS,
          IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("DCPAVServiceProxy"), callback, context, &self.removed) == KERN_SUCCESS else { return nil }
    // Draining arms the notifications. Existing services are handled by startup.
    _ = Self.drain(self.added)
    _ = Self.drain(self.removed)
  }

  private static func drain(_ iterator: io_iterator_t) -> Set<UInt64> {
    var ids = Set<UInt64>()
    while true {
      let entry = IOIteratorNext(iterator)
      guard entry != IO_OBJECT_NULL else { break }
      var id: UInt64 = 0
      if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS { ids.insert(id) }
      IOObjectRelease(entry)
    }
    return ids
  }

  deinit {
    IONotificationPortDestroy(self.port)
    if self.added != 0 { IOObjectRelease(self.added) }
    if self.removed != 0 { IOObjectRelease(self.removed) }
  }
}
