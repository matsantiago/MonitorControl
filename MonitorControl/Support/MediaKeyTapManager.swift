//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import AudioToolbox
import Cocoa
import Foundation
import MediaKeyTap
import os.log

class MediaKeyTapManager {
  private var mediaKeyTap: MonitorMediaKeyTap?
  private var tapGeneration = 0
  var keyRepeatTimers: [MediaKey: Timer] = [:]

  private func handle(mediaKey: MediaKey, isPressed: Bool, isRepeat: Bool, modifiers: NSEvent.ModifierFlags) {
    let isControl = modifiers.contains(.control)
    let isCommand = modifiers.contains(.command)
    let isOption = modifiers.contains(.option)
    let isShift = modifiers.contains(.shift)
    if isPressed, isCommand, !isControl, mediaKey == .brightnessDown, DisplayManager.engageMirror() {
      return
    }
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      return
    }
    if isPressed, !isRepeat, self.handleOpenPrefPane(mediaKey: mediaKey, modifiers: modifiers) {
      return
    }
    var isSmallIncrement = isOption && isShift
    let isContrast = isControl && isOption && isCommand
    if [.brightnessUp, .brightnessDown].contains(mediaKey), prefs.bool(forKey: PrefKey.useFineScaleBrightness.rawValue) {
      isSmallIncrement = !isSmallIncrement
    }
    if [.volumeUp, .volumeDown, .mute].contains(mediaKey), prefs.bool(forKey: PrefKey.useFineScaleVolume.rawValue) {
      isSmallIncrement = !isSmallIncrement
    }
    if isPressed, isControl, !isOption, mediaKey == .brightnessUp || mediaKey == .brightnessDown {
      self.handleDirectedBrightness(isCommandModifier: isCommand, isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
      return
    }
    let oppositeKey: MediaKey? = self.oppositeMediaKey(mediaKey: mediaKey)
    // If the opposite key to the one being held has an active timer, cancel it - we'll be going in the opposite direction
    if let oppositeKey = oppositeKey, let oppositeKeyTimer = self.keyRepeatTimers[oppositeKey], oppositeKeyTimer.isValid {
      oppositeKeyTimer.invalidate()
    } else if let mediaKeyTimer = self.keyRepeatTimers[mediaKey], mediaKeyTimer.isValid {
      // If there's already an active timer for the key being held down, let it run rather than executing it again
      if isRepeat {
        return
      }
      mediaKeyTimer.invalidate()
    }
    self.sendDisplayCommand(mediaKey: mediaKey, isRepeat: isRepeat, isSmallIncrement: isSmallIncrement, isPressed: isPressed, isContrast: isContrast)
  }

  func handleDirectedBrightness(isCommandModifier: Bool, isUp: Bool, isSmallIncrement: Bool) {
    if isCommandModifier {
      for otherDisplay in DisplayManager.shared.getOtherDisplays() {
        otherDisplay.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
      }
      for appleDisplay in DisplayManager.shared.getAppleDisplays() where !appleDisplay.isBuiltIn() {
        appleDisplay.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
      }
      return
    } else if let internalDisplay = DisplayManager.shared.getBuiltInDisplay() as? AppleDisplay {
      internalDisplay.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
      return
    }
  }

  private func sendDisplayCommand(mediaKey: MediaKey, isRepeat: Bool, isSmallIncrement: Bool, isPressed: Bool, isContrast: Bool = false) {
    self.sendDisplayCommandVolumeMute(mediaKey: mediaKey, isRepeat: isRepeat, isSmallIncrement: isSmallIncrement, isPressed: isPressed)
    self.sendDisplayCommandBrightnessContrast(mediaKey: mediaKey, isRepeat: isRepeat, isSmallIncrement: isSmallIncrement, isPressed: isPressed, isContrast: isContrast)
  }

  private func sendDisplayCommandVolumeMute(mediaKey: MediaKey, isRepeat: Bool, isSmallIncrement: Bool, isPressed: Bool) {
    guard [.volumeUp, .volumeDown, .mute].contains(mediaKey), app.sleepID == 0, app.reconfigureID == 0, let affectedDisplays = DisplayManager.shared.getAffectedDisplays(isBrightness: false, isVolume: true) else {
      return
    }
    var wasNotIsPressedVolumeSentAlready = false
    for display in affectedDisplays where !display.readPrefAsBool(key: .isDisabled) {
      switch mediaKey {
      case .mute:
        // The mute key should not respond to press + hold or keyup
        if !isRepeat, isPressed, let display = display as? OtherDisplay {
          display.toggleMute()
          if !wasNotIsPressedVolumeSentAlready, display.readPrefAsInt(for: .audioMuteScreenBlank) != 1, !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume) {
            app.playVolumeChangedSound()
            wasNotIsPressedVolumeSentAlready = true
          }
        }
      case .volumeUp, .volumeDown:
        // volume only matters for other displays
        if let display = display as? OtherDisplay {
          if isPressed {
            display.stepVolume(isUp: mediaKey == .volumeUp, isSmallIncrement: isSmallIncrement)
          } else if !wasNotIsPressedVolumeSentAlready, !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume) {
            app.playVolumeChangedSound()
            wasNotIsPressedVolumeSentAlready = true
          }
        }
      default: continue
      }
    }
  }

  private func sendDisplayCommandBrightnessContrast(mediaKey: MediaKey, isRepeat _: Bool, isSmallIncrement: Bool, isPressed: Bool, isContrast: Bool = false) {
    guard [.brightnessUp, .brightnessDown].contains(mediaKey), app.sleepID == 0, app.reconfigureID == 0, isPressed, let affectedDisplays = DisplayManager.shared.getAffectedDisplays(isBrightness: true, isVolume: false) else {
      return
    }
    for display in affectedDisplays where !display.readPrefAsBool(key: .isDisabled) {
      switch mediaKey {
      case .brightnessUp:
        if isContrast, let otherDisplay = display as? OtherDisplay {
          otherDisplay.stepContrast(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
        } else {
          var isAnyDisplayInSwAfterBrightnessMode = false
          for display in affectedDisplays where ((display as? OtherDisplay)?.isSwBrightnessNotDefault() ?? false) && !((display as? OtherDisplay)?.isSw() ?? false) && prefs.bool(forKey: PrefKey.separateCombinedScale.rawValue) {
            isAnyDisplayInSwAfterBrightnessMode = true
          }
          if !(isAnyDisplayInSwAfterBrightnessMode && !(((display as? OtherDisplay)?.isSwBrightnessNotDefault() ?? false) && !((display as? OtherDisplay)?.isSw() ?? false))) {
            display.stepBrightness(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
          }
        }
      case .brightnessDown:
        if isContrast, let otherDisplay = display as? OtherDisplay {
          otherDisplay.stepContrast(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
        } else {
          display.stepBrightness(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
        }
      default: continue
      }
    }
  }

  private func oppositeMediaKey(mediaKey: MediaKey) -> MediaKey? {
    if mediaKey == .brightnessUp {
      return .brightnessDown
    } else if mediaKey == .brightnessDown {
      return .brightnessUp
    } else if mediaKey == .volumeUp {
      return .volumeDown
    } else if mediaKey == .volumeDown {
      return .volumeUp
    }
    return nil
  }

  func updateMediaKeyTap() {
    self.tapGeneration += 1
    self.mediaKeyTap = nil
    guard app.sleepID == 0, app.reconfigureID == 0, !app.safeMode, Self.readPrivileges(prompt: false) else {
      return
    }
    var keys: [MediaKey] = []
    if [KeyboardBrightness.media.rawValue, KeyboardBrightness.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardBrightness.rawValue)) {
      keys.append(contentsOf: [.brightnessUp, .brightnessDown])
    }
    if [KeyboardVolume.media.rawValue, KeyboardVolume.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardVolume.rawValue)) {
      keys.append(contentsOf: [.mute, .volumeUp, .volumeDown])
    }
    // Remove brightness keys if no external displays are connected, but only if brightness fine control is not active
    var disengageBrightness = true
    for display in DisplayManager.shared.getAllDisplays() where !display.isBuiltIn() {
      disengageBrightness = false
    }
    if disengageBrightness, !prefs.bool(forKey: PrefKey.useFineScaleBrightness.rawValue) {
      let keysToDelete: [MediaKey] = [.brightnessUp, .brightnessDown]
      keys.removeAll { keysToDelete.contains($0) }
    }
    // Remove volume related keys if audio device is controllable
    if let defaultAudioDevice = app.coreAudio.defaultOutputDevice {
      let keysToDelete: [MediaKey] = [.volumeUp, .volumeDown, .mute]
      if prefs.integer(forKey: PrefKey.multiKeyboardVolume.rawValue) == MultiKeyboardVolume.audioDeviceNameMatching.rawValue {
        if DisplayManager.shared.updateAudioControlTargetDisplays(deviceName: defaultAudioDevice.name) == 0 {
          keys.removeAll { keysToDelete.contains($0) }
        }
      } else if defaultAudioDevice.canSetVirtualMainVolume(scope: .output) == true {
        keys.removeAll { keysToDelete.contains($0) }
      }
    }
    guard !keys.isEmpty else { return }
    let generation = self.tapGeneration
    self.mediaKeyTap = MonitorMediaKeyTap(keys: Set(keys), alternateBrightness: !prefs.bool(forKey: PrefKey.disableAltBrightnessKeys.rawValue)) { [weak self] key, isPressed, isRepeat, modifiers in
      guard let self, self.tapGeneration == generation else { return }
      self.handle(mediaKey: key, isPressed: isPressed, isRepeat: isRepeat, modifiers: modifiers)
    }
  }

  private func handleOpenPrefPane(mediaKey: MediaKey, modifiers: NSEvent.ModifierFlags) -> Bool {
    if !(modifiers.contains(.option) && !modifiers.contains(.shift) && !modifiers.contains(.control) && !modifiers.contains(.command)) {
      return false
    }
    switch mediaKey {
    case .brightnessUp, .brightnessDown:
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Displays.prefPane"))
    case .mute, .volumeUp, .volumeDown:
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane"))
    default:
      return false
    }
    return true
  }

  static func readPrivileges(prompt: Bool) -> Bool {
    let status = prompt ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) : AXIsProcessTrusted()
    os_log("Reading Accessibility privileges - Current access status %{public}@", type: .info, String(status))
    return status
  }
}

private final class MonitorMediaKeyTap {
  private let port: CFMachPort
  private let source: CFRunLoopSource

  private final class Context {
    let keys: Set<MediaKey>
    let alternateBrightness: Bool
    let onMediaKey: (MediaKey, Bool, Bool, NSEvent.ModifierFlags) -> Void

    init(keys: Set<MediaKey>, alternateBrightness: Bool, onMediaKey: @escaping (MediaKey, Bool, Bool, NSEvent.ModifierFlags) -> Void) {
      self.keys = keys
      self.alternateBrightness = alternateBrightness
      self.onMediaKey = onMediaKey
    }

    func process(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
      let key: MediaKey?
      let isPressed: Bool
      let isRepeat: Bool
      switch type {
      case .keyDown:
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 107 where self.alternateBrightness, 145: key = .brightnessDown
        case 113 where self.alternateBrightness, 144: key = .brightnessUp
        default: key = nil
        }
        isPressed = true
        isRepeat = false
      case let type where type.rawValue == UInt32(NX_SYSDEFINED):
        guard let systemEvent = NSEvent(cgEvent: event), systemEvent.subtype.rawValue == 8 else {
          return .passUnretained(event)
        }
        key = MediaKeyTap.keycodeToMediaKey(Int32((systemEvent.data1 >> 16) & 0xffff))
        isPressed = (systemEvent.data1 & 0xff00) == 0x0a00
        isRepeat = (systemEvent.data1 & 1) != 0
      default:
        return .passUnretained(event)
      }
      guard let key, self.keys.contains(key) else { return .passUnretained(event) }
      let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
      // Return to WindowServer immediately, even when a display operation blocks AppKit.
      DispatchQueue.main.async { self.onMediaKey(key, isPressed, isRepeat, modifiers) }
      return nil
    }
  }

  init?(keys: Set<MediaKey>, alternateBrightness: Bool, onMediaKey: @escaping (MediaKey, Bool, Bool, NSEvent.ModifierFlags) -> Void) {
    let context = Context(keys: keys, alternateBrightness: alternateBrightness, onMediaKey: onMediaKey)
    let keyDownMask = keys.contains(.brightnessUp) || keys.contains(.brightnessDown) ? CGEventMask(1) << CGEventType.keyDown.rawValue : 0
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                       eventsOfInterest: keyDownMask | (CGEventMask(1) << NX_SYSDEFINED), callback: { _, type, event, info in
      guard let info else { return .passUnretained(event) }
      return Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().process(event, type: type)
    }, userInfo: Unmanaged.passUnretained(context).toOpaque()) else { return nil }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
      CFMachPortInvalidate(port)
      return nil
    }
    self.port = port
    self.source = source
    DispatchQueue(label: "MonitorControl media keys", qos: .userInteractive).async {
      withExtendedLifetime(context) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        while CFRunLoopSourceIsValid(source) {
          CFRunLoopRunInMode(.defaultMode, 1, false)
        }
      }
    }
  }

  deinit {
    CGEvent.tapEnable(tap: self.port, enable: false)
    CFMachPortInvalidate(self.port)
    CFRunLoopSourceInvalidate(self.source)
  }
}
