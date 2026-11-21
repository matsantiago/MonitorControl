//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log
import Settings

class DisplaysPrefsViewController: NSViewController, SettingsPane, NSTableViewDataSource, NSTableViewDelegate {
  let paneIdentifier = Settings.PaneIdentifier.displays
  let paneTitle: String = NSLocalizedString("Displays", comment: "Shown in the main prefs window")

  var toolbarItemIcon: NSImage {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return NSImage(systemSymbolName: "display.2", accessibilityDescription: "Displays")!
    } else {
      return NSImage(named: NSImage.infoName)!
    }
  }

  var displays: [Display] = []
  private var samsungSetupRunning = false
  private var samsungSearchRunning = false
  private var samsungSearchResults: [SamsungTVDevice]?

  @IBOutlet var displayList: NSTableView!
  @IBOutlet var displayScrollView: NSScrollView!
  @IBOutlet var constraintHeight: NSLayoutConstraint!
  @IBOutlet var showAdvancedDisplays: NSButton!

  override func viewDidLoad() {
    super.viewDidLoad()
    self.displayScrollView.scrollerStyle = .legacy
    self.populateSettings()
    self.loadDisplayList()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    self.searchSamsungTVs()
  }

  func populateSettings() {
    self.showAdvancedDisplays.state = prefs.bool(forKey: PrefKey.showAdvancedSettings.rawValue) ? .on : .off
  }

  func updateGridLayout() -> Bool {
    let hide = !prefs.bool(forKey: PrefKey.showAdvancedSettings.rawValue)
    self.loadDisplayList()
    return !hide
  }

  @objc func loadDisplayList() {
    guard self.displayList != nil else {
      os_log("Reloading Displays settings display list skipped as there is no display list table yet.", type: .info)
      return
    }
    os_log("Reloading Displays settings display list", type: .info)
    self.displays = DisplayManager.shared.getAllDisplays()
    self.displayList?.reloadData()
    self.updateDisplayListRowHeight()
    if self.view.window?.isVisible == true, self.samsungSearchResults == nil, !self.samsungSearchRunning {
      self.searchSamsungTVs()
    }
  }

  @IBAction func showAdvancedClicked(_ sender: NSButton) {
    switch sender.state {
    case .on:
      prefs.set(true, forKey: PrefKey.showAdvancedSettings.rawValue)
    case .off:
      prefs.set(false, forKey: PrefKey.showAdvancedSettings.rawValue)
    default: break
    }
    _ = self.updateGridLayout()
    displaysPrefsVc?.view.layoutSubtreeIfNeeded()
  }

  func numberOfRows(in _: NSTableView) -> Int {
    self.displays.count
  }

  static func isImac() -> Bool {
    let platformExpertDevice = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    if let modelIdentifier = IORegistryEntryCreateCFProperty(platformExpertDevice, "model" as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String {
      return modelIdentifier.contains("iMac")
    }
    return false
  }

  struct DisplayInfo {
    var displayType = ""
    var displayImage = ""
    var controlMethod = ""
    var controlStatus = ""
  }

  static func getDisplayInfo(display: Display) -> DisplayInfo {
    var displayType = NSLocalizedString("Other Display", comment: "Shown in the Display Settings")
    var displayImage = "display.trianglebadge.exclamationmark"
    var controlMethod = NSLocalizedString("No Control", comment: "Shown in the Display Settings") + "  ⚠️"
    var controlStatus = NSLocalizedString("This display has an unspecified control status.", comment: "Shown in the Display Settings")
    if display.isVirtual, !display.isDummy {
      displayType = NSLocalizedString("Virtual Display", comment: "Shown in the Display Settings")
      displayImage = "tv.and.mediabox"
      controlMethod = NSLocalizedString("Software (shade)", comment: "Shown in the Display Settings") + "  ⚠️"
      controlStatus = NSLocalizedString("This is a virtual display (examples: AirPlay, Sidecar, display connected via a DisplayLink Dock or similar) which does not allow hardware or software gammatable control. Shading is used as a substitute but only in non-mirror scenarios. Mouse cursor will be unaffected and artifacts may appear when entering/leaving full screen mode.", comment: "Shown in the Display Settings")
    } else if display is OtherDisplay, !display.isDummy {
      displayType = NSLocalizedString("External Display", comment: "Shown in the Display Settings")
      displayImage = "display"
      if let otherDisplay: OtherDisplay = display as? OtherDisplay {
        if let tv = otherDisplay.samsungTV {
          let method = otherDisplay.usesSamsungBrightness
            ? NSLocalizedString("Samsung network", comment: "Display control method")
            : NSLocalizedString("Software (Samsung TV)", comment: "Display control method")
          controlMethod = method
          let description = otherDisplay.usesSamsungBrightness
            ? NSLocalizedString("MonitorControl controls the TV backlight over the local network.", comment: "Display control description")
            : NSLocalizedString("Brightness uses software dimming.", comment: "Display control description")
          controlStatus = [tv.binding.device.label, description, tv.status].filter { !$0.isEmpty }.joined(separator: "\n")
        } else if otherDisplay.isSwOnly() || (otherDisplay.samsungDDCResponds == false && otherDisplay.isSw()) {
          if otherDisplay.readPrefAsBool(key: .avoidGamma) {
            controlMethod = NSLocalizedString("Software (shade)", comment: "Shown in the Display Settings") + "  ⚠️"
          } else {
            controlMethod = NSLocalizedString("Software (gamma)", comment: "Shown in the Display Settings") + "  ⚠️"
          }
          displayImage = "display.trianglebadge.exclamationmark"
          controlStatus = NSLocalizedString("This display allows for software brightness control via gamma table manipulation or shade as it does not support hardware control. Reasons for this might be using the HDMI port of a Mac mini (which blocks hardware DDC control) or having a blacklisted display.", comment: "Shown in the Display Settings")
          if otherDisplay.samsungDDCResponds == false {
            controlStatus = NSLocalizedString("DDC brightness did not respond", comment: "Samsung TV discovery status")
          }
        } else {
          if otherDisplay.isSw() {
            if otherDisplay.readPrefAsBool(key: .avoidGamma) {
              controlMethod = NSLocalizedString("Software (shade, forced)", comment: "Shown in the Display Settings")
            } else {
              controlMethod = NSLocalizedString("Software (gamma, forced)", comment: "Shown in the Display Settings")
            }
            controlStatus = NSLocalizedString("This display is reported to support hardware DDC control but the current settings allow for software control only.", comment: "Shown in the Display Settings")
          } else {
            controlMethod = NSLocalizedString("Hardware (DDC)", comment: "Shown in the Display Settings")
            controlStatus = NSLocalizedString("This display is reported to support hardware DDC control. If you encounter issues, you can disable hardware DDC control to force software control.", comment: "Shown in the Display Settings")
          }
        }
      }
    } else if !display.isDummy, let appleDisplay: AppleDisplay = display as? AppleDisplay {
      if appleDisplay.isBuiltIn() {
        displayType = NSLocalizedString("Built-in Display", comment: "Shown in the Display Settings")
        if self.isImac() {
          displayImage = "desktopcomputer"
        } else {
          displayImage = "laptopcomputer"
        }
      } else {
        displayType = NSLocalizedString("External Display", comment: "Shown in the Display Settings")
        displayImage = "display"
      }
      controlMethod = NSLocalizedString("Hardware (Apple)", comment: "Shown in the Display Settings")
      controlStatus = NSLocalizedString("This display supports native Apple brightness protocol. This allows macOS to control this display without MonitorControl as well.", comment: "Shown in the Display Settings")
    }
    return DisplayInfo(displayType: displayType, displayImage: displayImage, controlMethod: controlMethod, controlStatus: controlStatus)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let tableColumn = tableColumn else {
      return nil
    }
    os_log("Populating Displays Table")
    let display = self.displays[row]
    if let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? DisplaysPrefsCellView {
      cell.display = display
      let samsungOptions = self.samsungTVOptions(for: display)
      cell.updateSamsungTVControls(status: samsungOptions.status, button: samsungOptions.button)

      // ID
      cell.displayId.stringValue = String(display.identifier)
      // Firendly name
      cell.friendlyName.stringValue = (display.readPrefAsString(key: .friendlyName) != "" ? display.readPrefAsString(key: .friendlyName) : display.name)
      cell.friendlyName.isEditable = true
      // Enabled
      cell.enabledButton.state = display.readPrefAsBool(key: .isDisabled) ? .off : .on
      // Enabled
      cell.avoidGamma.state = display.readPrefAsBool(key: .avoidGamma) ? .on : .off
      if let otherDisplay = display as? OtherDisplay, !otherDisplay.isVirtual, !otherDisplay.usesSamsungBrightness {
        cell.avoidGamma.isEnabled = true
      } else {
        cell.avoidGamma.isEnabled = false
      }
      // DDC
      cell.ddcButton.state = ((display as? OtherDisplay)?.isSw() ?? true) ? .off : .on
      if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSwOnly(), otherDisplay.samsungTV == nil {
        cell.ddcButton.isEnabled = true
      } else {
        cell.ddcButton.isEnabled = false
      }
      // Display type, image, control method
      let displayInfo = DisplaysPrefsViewController.getDisplayInfo(display: display)
      cell.displayType.stringValue = displayInfo.displayType
      cell.controlMethod.stringValue = displayInfo.controlMethod
      cell.controlMethod.controlView?.toolTip = displayInfo.controlStatus
      if !DEBUG_MACOS10, #available(macOS 11.0, *) {
        cell.displayImage.image = NSImage(systemSymbolName: displayInfo.displayImage, accessibilityDescription: display.name)!
      } else {
        cell.displayImage.image = NSImage(named: NSImage.touchBarIconViewTemplateName)!
      }
      // Disable Volume OSD
      if let otherDisplay = display as? OtherDisplay, otherDisplay.usesSamsungVolume || !otherDisplay.isSw() {
        cell.disableVolumeOSDButton.state = otherDisplay.readPrefAsBool(key: .hideOsd) ? .on : .off
        cell.disableVolumeOSDButton.isEnabled = true
      } else {
        cell.disableVolumeOSDButton.state = .off
        cell.disableVolumeOSDButton.isEnabled = false
      }
      // Advanced settings
      cell.unavailableDDCBrightness.state = !display.readPrefAsBool(key: .unavailableDDC, for: .brightness) ? .on : .off
      if let otherDisplay = display as? OtherDisplay, !otherDisplay.isSwOnly(), otherDisplay.samsungTV == nil {
        cell.pollingModeMenu.isEnabled = true
        cell.pollingModeMenu.selectItem(withTag: otherDisplay.readPrefAsInt(key: .pollingMode))
        if otherDisplay.readPrefAsInt(key: .pollingMode) == PollingMode.custom.rawValue {
          cell.pollingCount.isEnabled = true
        } else {
          cell.pollingCount.isEnabled = false
        }
        cell.pollingCount.stringValue = String(otherDisplay.pollingCount)
        cell.longerDelayButton.isEnabled = true
        cell.longerDelayButton.state = otherDisplay.readPrefAsBool(key: .longerDelay) ? .on : .off
        cell.enableMuteButton.isEnabled = true
        cell.enableMuteButton.state = otherDisplay.readPrefAsBool(key: .enableMuteUnmute) ? .on : .off

        cell.combinedBrightnessSwitchingPoint.isEnabled = true
        cell.combinedBrightnessSwitchingPoint.intValue = Int32(otherDisplay.readPrefAsInt(key: .combinedBrightnessSwitchingPoint))

        cell.audioDeviceNameOverride.isEnabled = true
        cell.audioDeviceNameOverride.stringValue = otherDisplay.readPrefAsString(key: .audioDeviceNameOverride)
        cell.updateWithCurrentAudioName.isEnabled = true

        cell.unavailableDDCVolume.isEnabled = true
        cell.unavailableDDCContrast.isEnabled = true
        cell.unavailableDDCVolume.state = !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume) ? .on : .off
        cell.unavailableDDCContrast.state = !otherDisplay.readPrefAsBool(key: .unavailableDDC, for: .contrast) ? .on : .off

        cell.minDDCOverrideBrightness.isEnabled = true
        cell.minDDCOverrideVolume.isEnabled = true
        cell.minDDCOverrideContrast.isEnabled = true
        cell.minDDCOverrideBrightness.stringValue = otherDisplay.readPrefAsString(key: .minDDCOverride, for: .brightness)
        cell.minDDCOverrideVolume.stringValue = otherDisplay.readPrefAsString(key: .minDDCOverride, for: .audioSpeakerVolume)
        cell.minDDCOverrideContrast.stringValue = otherDisplay.readPrefAsString(key: .minDDCOverride, for: .contrast)

        cell.maxDDCOverrideBrightness.isEnabled = true
        cell.maxDDCOverrideVolume.isEnabled = true
        cell.maxDDCOverrideContrast.isEnabled = true
        cell.maxDDCOverrideBrightness.stringValue = otherDisplay.readPrefAsString(key: .maxDDCOverride, for: .brightness)
        cell.maxDDCOverrideVolume.stringValue = otherDisplay.readPrefAsString(key: .maxDDCOverride, for: .audioSpeakerVolume)
        cell.maxDDCOverrideContrast.stringValue = otherDisplay.readPrefAsString(key: .maxDDCOverride, for: .contrast)

        cell.curveDDCBrightness.isEnabled = true
        cell.curveDDCVolume.isEnabled = true
        cell.curveDDCContrast.isEnabled = true
        cell.curveDDCBrightness.intValue = Int32(otherDisplay.readPrefAsInt(key: .curveDDC, for: .brightness) == 0 ? 5 : otherDisplay.readPrefAsInt(key: .curveDDC, for: .brightness))
        cell.curveDDCVolume.intValue = Int32(otherDisplay.readPrefAsInt(key: .curveDDC, for: .audioSpeakerVolume) == 0 ? 5 : otherDisplay.readPrefAsInt(key: .curveDDC, for: .audioSpeakerVolume))
        cell.curveDDCContrast.intValue = Int32(otherDisplay.readPrefAsInt(key: .curveDDC, for: .contrast) == 0 ? 5 : otherDisplay.readPrefAsInt(key: .curveDDC, for: .contrast))

        cell.invertDDCBrightness.state = otherDisplay.readPrefAsBool(key: .invertDDC, for: .brightness) ? .on : .off
        cell.invertDDCVolume.state = otherDisplay.readPrefAsBool(key: .invertDDC, for: .audioSpeakerVolume) ? .on : .off
        cell.invertDDCContrast.state = otherDisplay.readPrefAsBool(key: .invertDDC, for: .contrast) ? .on : .off
        cell.invertDDCBrightness.isEnabled = true
        cell.invertDDCVolume.isEnabled = true
        cell.invertDDCContrast.isEnabled = true

        cell.remapDDCBrightness.isEnabled = true
        cell.remapDDCVolume.isEnabled = true
        cell.remapDDCContrast.isEnabled = true
        cell.remapDDCBrightness.stringValue = otherDisplay.readPrefAsString(key: .remapDDC, for: .brightness)
        cell.remapDDCVolume.stringValue = otherDisplay.readPrefAsString(key: .remapDDC, for: .audioSpeakerVolume)
        cell.remapDDCContrast.stringValue = otherDisplay.readPrefAsString(key: .remapDDC, for: .contrast)
      } else {
        cell.pollingModeMenu.selectItem(withTag: 0)
        cell.pollingModeMenu.isEnabled = false
        cell.pollingCount.stringValue = ""
        cell.pollingCount.isEnabled = false
        cell.longerDelayButton.state = .off
        cell.longerDelayButton.isEnabled = false
        cell.enableMuteButton.state = .off
        cell.enableMuteButton.isEnabled = false

        cell.combinedBrightnessSwitchingPoint.intValue = 0
        cell.combinedBrightnessSwitchingPoint.isEnabled = false

        cell.audioDeviceNameOverride.isEnabled = false
        cell.audioDeviceNameOverride.stringValue = ""
        cell.updateWithCurrentAudioName.isEnabled = false

        cell.unavailableDDCVolume.state = .off
        cell.unavailableDDCContrast.state = .off
        cell.unavailableDDCVolume.isEnabled = false
        cell.unavailableDDCContrast.isEnabled = false

        cell.minDDCOverrideBrightness.stringValue = ""
        cell.minDDCOverrideVolume.stringValue = ""
        cell.minDDCOverrideContrast.stringValue = ""
        cell.minDDCOverrideBrightness.isEnabled = false
        cell.minDDCOverrideVolume.isEnabled = false
        cell.minDDCOverrideContrast.isEnabled = false

        cell.maxDDCOverrideBrightness.stringValue = ""
        cell.maxDDCOverrideVolume.stringValue = ""
        cell.maxDDCOverrideContrast.stringValue = ""
        cell.maxDDCOverrideBrightness.isEnabled = false
        cell.maxDDCOverrideVolume.isEnabled = false
        cell.maxDDCOverrideContrast.isEnabled = false

        cell.curveDDCBrightness.intValue = 5
        cell.curveDDCVolume.intValue = 5
        cell.curveDDCContrast.intValue = 5
        cell.curveDDCBrightness.isEnabled = false
        cell.curveDDCVolume.isEnabled = false
        cell.curveDDCContrast.isEnabled = false

        cell.invertDDCBrightness.state = .off
        cell.invertDDCVolume.state = .off
        cell.invertDDCContrast.state = .off
        cell.invertDDCBrightness.isEnabled = false
        cell.invertDDCVolume.isEnabled = false
        cell.invertDDCContrast.isEnabled = false

        cell.remapDDCBrightness.stringValue = ""
        cell.remapDDCVolume.stringValue = ""
        cell.remapDDCContrast.stringValue = ""
        cell.remapDDCBrightness.isEnabled = false
        cell.remapDDCVolume.isEnabled = false
        cell.remapDDCContrast.isEnabled = false
      }
      if prefs.bool(forKey: PrefKey.showAdvancedSettings.rawValue) {
        cell.advancedSettings.isHidden = false
      } else {
        cell.advancedSettings.isHidden = true
      }
      return cell
    }
    return nil
  }

  func updateDisplayListRowHeight() {
    if prefs.bool(forKey: PrefKey.showAdvancedSettings.rawValue) {
      self.displayList?.rowHeight = 520
      self.constraintHeight?.constant = self.displayList.rowHeight + 15 + 30
    } else {
      self.displayList?.rowHeight = 180
      self.constraintHeight?.constant = self.displayList.rowHeight * 2 + 15 + 30
    }
  }
}

extension DisplaysPrefsViewController {
  private var availableSamsungTVs: [SamsungTVDevice] {
    let linkedIDs = Set(self.displays.compactMap { ($0 as? OtherDisplay)?.samsungTV?.binding.device.id })
    return (self.samsungSearchResults ?? []).filter { !linkedIDs.contains($0.id) }
  }

  private func samsungTVOptions(for display: Display) -> (status: String?, button: String?) {
    guard let display = display as? OtherDisplay else { return (nil, nil) }
    if let tv = display.samsungTV {
      let button: String?
      if tv.needsPairing, tv.online != false {
        button = NSLocalizedString("Set Up TV…", comment: "Display settings button")
      } else if prefs.bool(forKey: PrefKey.showAdvancedSettings.rawValue) {
        button = NSLocalizedString("Manage TV Link…", comment: "Display settings button")
      } else {
        button = nil
      }
      return (tv.connectionLabel, button)
    }
    guard display.canDiscoverSamsungTV else { return (nil, nil) }
    if self.samsungSearchRunning {
      return (NSLocalizedString("Searching for Samsung TVs…", comment: "Samsung TV discovery progress"), nil)
    }
    if !self.availableSamsungTVs.isEmpty {
      return (NSLocalizedString("Samsung TV available over the network", comment: "Samsung TV discovery status"),
              NSLocalizedString("Set Up TV…", comment: "Display settings button"))
    }
    let status = self.samsungSearchResults == nil
      ? NSLocalizedString("DDC brightness did not respond", comment: "Samsung TV discovery status")
      : NSLocalizedString("No Samsung TVs found", comment: "Samsung TV discovery result")
    return (status, NSLocalizedString("Find TV…", comment: "Display settings button"))
  }

  private func searchSamsungTVs() {
    guard !self.samsungSearchRunning, self.displays.contains(where: { ($0 as? OtherDisplay)?.canDiscoverSamsungTV == true }) else { return }
    self.samsungSearchRunning = true
    self.loadDisplayList()
    SamsungTVControl.setupQueue.async {
      let devices = (try? SamsungTVDevice.discover()) ?? []
      DispatchQueue.main.async {
        self.samsungSearchResults = devices
        self.samsungSearchRunning = false
        self.loadDisplayList()
      }
    }
  }

  func configureSamsungTV(for display: OtherDisplay, in window: NSWindow) {
    guard !self.samsungSetupRunning else { return }
    guard let tv = display.samsungTV else {
      if !self.availableSamsungTVs.isEmpty {
        self.selectSamsungTV(for: display, in: window)
      } else {
        self.searchSamsungTVs()
      }
      return
    }

    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Samsung TV over network", comment: "Samsung TV settings title")
    let brightness = display.usesSamsungBrightness
      ? NSLocalizedString("Brightness: TV backlight", comment: "Samsung TV brightness mode")
      : NSLocalizedString("Brightness: software dimming", comment: "Samsung TV brightness mode")
    let volume: String
    if display.usesSamsungVolume {
      volume = NSLocalizedString("Volume: slider", comment: "Samsung TV volume mode")
    } else if display.usesSamsungRemoteVolume {
      volume = NSLocalizedString("Volume: remote buttons", comment: "Samsung TV volume mode")
    } else {
      volume = NSLocalizedString("Volume: pairing required", comment: "Samsung TV volume mode")
    }
    alert.informativeText = [tv.binding.device.label, brightness, volume, tv.status].filter { !$0.isEmpty }.joined(separator: "\n")

    var actions: [(title: String, handler: (() -> Void)?)] = []
    if tv.online != false, tv.canPairIP {
      actions.append((NSLocalizedString("Pair Brightness and Volume…", comment: "Start IP Control pairing"),
                      { self.confirmSamsungBrightness(for: display, in: window) }))
    }
    if tv.online != false, tv.canPairRemoteVolume {
      actions.append((NSLocalizedString("Pair Volume Only…", comment: "Start TV remote pairing"),
                      { self.pairSamsungVolume(for: display, in: window) }))
    }
    let closeTitle = actions.isEmpty ? NSLocalizedString("OK", comment: "Dismiss alert") : NSLocalizedString("Cancel", comment: "Cancel button")
    actions.append((closeTitle, nil))
    if prefs.bool(forKey: PrefKey.showAdvancedSettings.rawValue) {
      actions.append((NSLocalizedString("Forget TV", comment: "Remove association with Samsung TV"),
                      { self.forgetSamsungTV(for: display, in: window) }))
    }
    for action in actions {
      alert.addButton(withTitle: action.title)
    }
    alert.beginSheetModal(for: window) { response in
      let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
      if actions.indices.contains(index) { actions[index].handler?() }
    }
  }

  private func selectSamsungTV(for display: OtherDisplay, in window: NSWindow) {
    let devices = self.availableSamsungTVs
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    picker.addItems(withTitles: devices.map(\.label))
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Select the TV for this display", comment: "Samsung TV picker")
    alert.accessoryView = picker
    alert.addButton(withTitle: NSLocalizedString("Connect", comment: "Connect to selected Samsung TV"))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn, devices.indices.contains(picker.indexOfSelectedItem),
            let current = self.currentDisplay(for: display, in: window) else { return }
      let device = devices[picker.indexOfSelectedItem]
      guard self.availableSamsungTVs.contains(where: { $0.id == device.id }) else { return }
      self.connectSamsungTV(device, to: current, in: window)
    }
  }

  private func connectSamsungTV(_ device: SamsungTVDevice, to display: OtherDisplay, in window: NSWindow) {
    let binding = SamsungTVBinding(device: device)
    self.installSamsungTV(binding, values: [:], on: display)
    self.configureSamsungTV(for: display, in: window)
  }

  private func pairSamsungVolume(for display: OtherDisplay, in window: NSWindow) {
    guard let tv = display.samsungTV else { return }
    let binding = tv.binding
    self.runSamsungSetup(in: window, message: NSLocalizedString("Checking volume. Allow MonitorControl if the TV asks.", comment: "Samsung TV volume setup progress"), work: {
      guard let device = binding.device.currentAddress() else { throw SamsungTVError.discovery }
      var updated = binding
      updated.device = device
      if #available(macOS 10.15, *) {
        let credential = try device.pairRemote()
        try credential.save(device.remoteAccount)
        updated.usesRemoteVolume = true
        return updated
      }
      throw SamsungTVError.unsupported
    }) { result in
      guard let current = self.currentDisplay(for: display, in: window) else { return }
      switch result {
      case let .success(updated):
        self.installSamsungTV(updated, values: tv.values, on: current)
      case .failure:
        self.showSamsungMessage(NSLocalizedString("TV remote unavailable", comment: "Samsung TV volume pairing failed"),
                                detail: NSLocalizedString("Keep the TV on, allow MonitorControl on the TV, and try Pair Volume Only again.", comment: "Samsung TV volume pairing troubleshooting"), in: window)
      }
    }
  }

  private func confirmSamsungBrightness(for display: OtherDisplay, in window: NSWindow) {
    guard let tv = display.samsungTV else { return }
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Pair TV brightness and volume", comment: "Samsung TV brightness setup")
    alert.informativeText = NSLocalizedString("On the TV, open All Settings → Connection → Network → Expert Settings. Enable Power On with Mobile, followed by IP Remote. Switch to the Mac’s HDMI input, then click Pair and approve on the TV.", comment: "Samsung TV brightness setup instructions")
    alert.addButton(withTitle: NSLocalizedString("Pair", comment: "Start TV pairing"))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn else { return }
      let binding = tv.binding
      self.runSamsungSetup(in: window, message: NSLocalizedString("Waiting for approval on the TV…", comment: "Samsung TV pairing progress"), work: {
        guard let device = binding.device.currentAddress() else { throw SamsungTVError.discovery }
        let credential = try device.pair()
        let brightness = try? device.backlight(using: credential)
        let volume = try? device.ipVolume(using: credential)
        let muted = volume == nil ? nil : try? device.ipMute(using: credential)
        guard brightness != nil || volume != nil else { throw SamsungTVError.unsupported }
        try credential.save(device.id)
        return (device, brightness, volume, muted)
      }) { result in
        guard let current = self.currentDisplay(for: display, in: window) else { return }
        switch result {
        case let .success((device, brightness, volume, muted)):
          var updatedBinding = binding
          updatedBinding.device = device
          updatedBinding.hasBrightness = brightness != nil
          updatedBinding.hasVolume = volume != nil
          updatedBinding.hasMute = muted != nil
          var values = tv.values
          values[.brightness] = brightness
          values[.audioSpeakerVolume] = volume
          values[.audioMuteScreenBlank] = muted
          self.installSamsungTV(updatedBinding, values: values, on: current)
        case let .failure(error):
          let detail: String
          switch error {
          case SamsungTVError.unsupported:
            detail = NSLocalizedString("The TV paired but did not expose backlight or volume adjustment on this input or firmware.", comment: "Samsung TV backlight unsupported")
          case SamsungTVError.keychain:
            detail = NSLocalizedString("MonitorControl could not save the TV’s pairing in Keychain.", comment: "Samsung TV Keychain error")
          default:
            detail = NSLocalizedString("Check that IP Remote is enabled, keep the Mac’s HDMI input visible, and approve the pairing prompt on the TV.", comment: "Samsung TV pairing troubleshooting")
          }
          self.showSamsungMessage(NSLocalizedString("Samsung IP Control unavailable", comment: "Samsung TV pairing failed"), detail: detail, in: window)
        }
      }
    }
  }

  private func installSamsungTV(_ binding: SamsungTVBinding, values: [Command: Int], on display: OtherDisplay) {
    binding.save(for: display)
    display.samsungTV = SamsungTVControl(display: display, binding: binding, values: values)
    if binding.hasBrightness { _ = display.setSwBrightness(1) }
    app.updateMenusAndKeys()
    self.loadDisplayList()
  }

  private func forgetSamsungTV(for display: OtherDisplay, in window: NSWindow) {
    guard let binding = display.samsungTV?.binding else { return }
    self.runSamsungSetup(in: window, message: NSLocalizedString("Removing TV link…", comment: "Samsung TV setup progress"), work: {
      try SamsungTVCredential.remove(binding.device.id)
      try SamsungTVCredential.remove(binding.device.remoteAccount)
    }) { result in
      guard (try? result.get()) != nil else {
        self.showSamsungMessage(NSLocalizedString("Could not remove the TV’s Keychain item.", comment: "Samsung TV error"), in: window)
        return
      }
      SamsungTVBinding.remove(for: display)
      if let current = DisplayManager.shared.getOtherDisplays().first(where: { $0.prefsId == display.prefsId }) {
        current.samsungTV = nil
      }
      app.configure()
    }
  }

  private func currentDisplay(for display: OtherDisplay, in window: NSWindow) -> OtherDisplay? {
    if let current = DisplayManager.shared.getOtherDisplays().first(where: { $0.prefsId == display.prefsId }) {
      return current
    }
    self.showSamsungMessage(NSLocalizedString("The display was disconnected.", comment: "Samsung TV setup error"), in: window)
    return nil
  }

  private func showSamsungMessage(_ title: String, detail: String = "", in window: NSWindow) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss alert"))
    alert.beginSheetModal(for: window)
  }

  private func runSamsungSetup<Value>(in window: NSWindow, message: String, work: @escaping () throws -> Value,
                                      completed: @escaping (Result<Value, Error>) -> Void) {
    self.samsungSetupRunning = true
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 370, height: 86), styleMask: [.titled], backing: .buffered, defer: false)
    let indicator = NSProgressIndicator(frame: NSRect(x: 24, y: 29, width: 24, height: 24))
    indicator.style = .spinning
    indicator.startAnimation(nil)
    sheet.contentView?.addSubview(indicator)
    let label = NSTextField(wrappingLabelWithString: message)
    label.frame = NSRect(x: 60, y: 23, width: 286, height: 36)
    sheet.contentView?.addSubview(label)
    window.beginSheet(sheet)
    SamsungTVControl.setupQueue.async {
      let result = Result { try work() }
      DispatchQueue.main.async {
        self.samsungSetupRunning = false
        window.endSheet(sheet)
        completed(result)
      }
    }
  }
}
