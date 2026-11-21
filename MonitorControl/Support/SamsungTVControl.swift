//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa

struct SamsungTVBinding: Codable {
  var device: SamsungTVDevice
  var hasBrightness = false
  var hasVolume = false
  var hasMute = false
  var usesRemoteVolume = false

  private static func preferenceKey(_ display: OtherDisplay) -> String { "SamsungTV." + display.prefsId }

  static func load(for display: OtherDisplay) -> Self? {
    guard !display.isVirtual, !display.isDummy, let data = prefs.data(forKey: self.preferenceKey(display)) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }

  func save(for display: OtherDisplay) {
    prefs.set(try? JSONEncoder().encode(self), forKey: Self.preferenceKey(display))
  }

  static func remove(for display: OtherDisplay) {
    prefs.removeObject(forKey: self.preferenceKey(display))
  }
}

// The display, pending values and callbacks belong to the main queue. Only the network
// worker accesses sockets or the Keychain. Each network batch verifies the renderer UUID.
final class SamsungTVControl {
  static let setupQueue = DispatchQueue(label: "Samsung TV setup", qos: .userInitiated)
  private let queue = DispatchQueue(label: "Samsung TV controls", qos: .userInitiated)
  private weak var display: OtherDisplay?
  private(set) var binding: SamsungTVBinding
  private(set) var values: [Command: Int]
  private var pending: [Command: Int] = [:]
  private var confirmed: [Command: Int]
  private var pendingKeys: [SamsungTVRemoteKey] = []
  private var working = false
  private var nextRefresh: TimeInterval = 0
  private var needsIPPairing = false
  private var needsVolumePairing = false
  private var ipControlsReachable = true
  private var remoteControlReachable = true
  private var credential: SamsungTVCredential?
  private var remoteCredential: SamsungTVCredential?
  private(set) var online: Bool?

  init(display: OtherDisplay, binding: SamsungTVBinding, values: [Command: Int] = [:]) {
    self.display = display
    self.binding = binding
    self.values = values
    self.confirmed = values
  }

  var canPairIP: Bool {
    self.needsIPPairing || !self.binding.hasBrightness || (!self.binding.hasVolume && !self.binding.usesRemoteVolume)
  }

  var canPairRemoteVolume: Bool {
    !self.binding.hasVolume && (!self.binding.usesRemoteVolume || self.needsVolumePairing)
  }

  var needsPairing: Bool { self.canPairIP || self.canPairRemoteVolume }

  var status: String {
    if self.online == false {
      return NSLocalizedString("TV unreachable. MonitorControl will search again automatically.", comment: "Samsung TV status")
    }
    if self.needsIPPairing {
      return NSLocalizedString("Samsung IP Control needs to be paired again.", comment: "Samsung TV status")
    }
    if self.needsVolumePairing, !self.binding.hasVolume {
      return NSLocalizedString("TV volume needs to be paired again.", comment: "Samsung TV status")
    }
    if !self.ipControlsReachable || !self.remoteControlReachable {
      return NSLocalizedString("TV found, but its controls are not responding.", comment: "Samsung TV status")
    }
    return ""
  }

  var connectionLabel: String {
    if self.online == false {
      return NSLocalizedString("TV offline", comment: "Samsung TV status in display row")
    }
    if self.needsIPPairing || (self.needsVolumePairing && !self.binding.hasVolume) {
      return NSLocalizedString("Pairing required", comment: "Samsung TV status in display row")
    }
    if !self.ipControlsReachable || !self.remoteControlReachable {
      return NSLocalizedString("TV controls unavailable", comment: "Samsung TV status in display row")
    }
    if self.needsPairing {
      return NSLocalizedString("TV setup incomplete", comment: "Samsung TV status in display row")
    }
    if self.online == nil {
      return NSLocalizedString("Checking TV connection…", comment: "Samsung TV status in display row")
    }
    return NSLocalizedString("Brightness and volume connected", comment: "Samsung TV status in display row")
  }

  func set(_ command: Command, value: Int) {
    self.values[command] = value
    self.pending[command] = value
    self.schedule()
  }

  func press(_ key: SamsungTVRemoteKey) {
    guard self.pendingKeys.count < 12 else { return }
    self.pendingKeys.append(key)
    self.schedule()
  }

  func refreshIfNeeded() {
    guard ProcessInfo.processInfo.systemUptime >= self.nextRefresh else { return }
    self.schedule()
  }

  private func schedule() {
    guard !self.working, let display = self.display, self.isCurrent(display), !app.safeMode,
          app.sleepID == 0, app.reconfigureID == 0 else { return }
    self.working = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak display] in
      guard let self = self, let display = display, self.isCurrent(display) else { return }
      guard app.sleepID == 0, app.reconfigureID == 0 else {
        self.pending.removeAll()
        self.pendingKeys.removeAll()
        self.working = false
        return
      }
      let commands = self.pending
      self.pending.removeAll()
      let keys = self.pendingKeys
      self.pendingKeys.removeAll()
      let binding = self.binding
      self.queue.async {
        let result = self.run(binding: binding, commands: commands, keys: keys)
        DispatchQueue.main.async { self.finish(result) }
      }
    }
  }

  private func isCurrent(_ display: OtherDisplay) -> Bool {
    display.samsungTV === self && DisplayManager.shared.getOtherDisplays().contains { $0 === display }
  }

  private struct Result {
    let device: SamsungTVDevice?
    var values: [Command: Int] = [:]
    var failedCommands: Set<Command> = []
    var needsIPPairing = false
    var needsVolumePairing: Bool?
    var remoteControlReachable: Bool?
  }

  private func run(binding: SamsungTVBinding, commands: [Command: Int], keys: [SamsungTVRemoteKey]) -> Result {
    guard let device = binding.device.currentAddress() else {
      return Result(device: nil, failedCommands: Set(commands.keys))
    }
    return self.communicate(binding: binding, device: device, commands: commands, keys: keys)
  }

  private func communicate(binding: SamsungTVBinding, device: SamsungTVDevice, commands: [Command: Int], keys: [SamsungTVRemoteKey]) -> Result {
    var result = Result(device: device)
    if binding.usesRemoteVolume, !binding.hasVolume || !keys.isEmpty, #available(macOS 10.15, *) {
      do {
        let credential = try self.remoteCredential ?? SamsungTVCredential.load(device.remoteAccount)
        self.remoteCredential = credential
        try device.sendRemote(keys, using: credential)
        result.needsVolumePairing = false
        result.remoteControlReachable = true
      } catch {
        self.remoteCredential = nil
        result.remoteControlReachable = false
        switch error {
        case SamsungTVError.authorization, SamsungTVError.certificate, SamsungTVError.keychain:
          result.needsVolumePairing = true
        default: break
        }
      }
    }
    if binding.hasBrightness || binding.hasVolume {
      do {
        let credential = try self.credential ?? SamsungTVCredential.load(device.id)
        self.credential = credential

        func update(_ command: Command, operation: (Int?) throws -> Int?) {
          do {
            result.values[command] = try operation(commands[command])
          } catch {
            if commands[command] != nil { result.failedCommands.insert(command) }
            switch error {
            case SamsungTVError.authorization, SamsungTVError.certificate:
              self.credential = nil
              result.needsIPPairing = true
            default: break
            }
          }
        }

        if binding.hasBrightness {
          update(.brightness) { target in
            if let target = target { _ = try device.backlight(using: credential, setting: target) }
            return try device.backlight(using: credential)
          }
        }
        if binding.hasVolume {
          update(.audioSpeakerVolume) { target in
            if let target = target { _ = try device.ipVolume(using: credential, setting: target) }
            return try device.ipVolume(using: credential)
          }
        }
        if binding.hasMute {
          update(.audioMuteScreenBlank) { target in
            if let target = target { _ = try device.ipMute(using: credential, setting: target) }
            return try device.ipMute(using: credential)
          }
        }
      } catch {
        result.failedCommands.formUnion(commands.keys)
        result.needsIPPairing = true
      }
    }
    return result
  }

  private func finish(_ result: Result) {
    guard let display = self.display, self.isCurrent(display) else { return }
    self.working = false
    let previousStatus = self.connectionLabel
    let now = ProcessInfo.processInfo.systemUptime
    self.online = result.device != nil
    if self.online == true {
      self.needsIPPairing = result.needsIPPairing
      self.ipControlsReachable = (!self.binding.hasBrightness || result.values[.brightness] != nil)
        && (!self.binding.hasVolume || result.values[.audioSpeakerVolume] != nil)
    }
    if let needsPairing = result.needsVolumePairing { self.needsVolumePairing = needsPairing }
    if let reachable = result.remoteControlReachable, !self.binding.hasVolume { self.remoteControlReachable = reachable }
    self.nextRefresh = now + (self.online == true ? 8 : 4)
    if let device = result.device, device.location != self.binding.device.location {
      self.binding.device = device
      self.binding.save(for: display)
    }
    // Roll back failed writes to the last reading and preserve newer queued input.
    for command in result.failedCommands where self.pending[command] == nil {
      self.values[command] = self.confirmed[command]
    }
    for (command, value) in result.values {
      self.confirmed[command] = value
      if self.pending[command] == nil { self.values[command] = value }
    }
    display.updateSamsungTVSliders()
    if previousStatus != self.connectionLabel { displaysPrefsVc?.loadDisplayList() }
    if !result.failedCommands.isEmpty {
      self.nextRefresh = now + 2
    }
    if !self.pending.isEmpty || !self.pendingKeys.isEmpty {
      self.schedule()
    }
  }
}
