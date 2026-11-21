//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import AppKit

final class MonitorSettingsWindowController: NSWindowController {
  private typealias SliderRow = (slider: NSSlider, readout: NSTextField, stepper: NSStepper)
  private typealias Preset = (title: String, writeValue: UInt16, reportedValue: UInt16)

  private let basicCommands: [Command] = [.brightness, .contrast, .audioSpeakerVolume]
  private let rgbCommands: [Command] = [.videoGainRed, .videoGainGreen, .videoGainBlue]
  private let presetOptions: [Command: [Preset]] = [
    .gamma: [
      (NSLocalizedString("Mode 1", comment: "LG gamma preset"), 0x0064, 1),
      (NSLocalizedString("Mode 2", comment: "LG gamma preset"), 0x6400, 2),
      (NSLocalizedString("Mode 3", comment: "LG gamma preset"), 0x7800, 3),
      (NSLocalizedString("Mode 4", comment: "LG gamma preset"), 0x8c00, 4),
    ],
    .selectColorPreset: [
      (NSLocalizedString("Custom (RGB)", comment: "LG color temperature preset"), 0x0b, 0x0b),
      (NSLocalizedString("6500 K", comment: "LG color temperature preset"), 0x05, 0x05),
      // The US550 reports zero after selecting the cooler preset.
      (NSLocalizedString("9300 K", comment: "LG color temperature preset"), 0x08, 0),
    ],
  ]

  private var activeDisplay: OtherDisplay?
  private var displayPrefsID: String?
  private var identity: Arm64DDC.EDIDIdentity?
  private var refreshID = 0
  private var sliderRows: [Command: SliderRow] = [:]
  private var popupRows: [Command: NSPopUpButton] = [:]
  private var sliderValues: [Command: UInt16] = [:]
  private var presetValues: [Command: UInt16] = [:]
  private let status = NSTextField(wrappingLabelWithString: "")
  private lazy var refreshButton = NSButton(title: NSLocalizedString("Refresh", comment: "Reread monitor settings"), target: self, action: #selector(self.refreshClicked))

  init() {
    let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = false
    window.becomesKeyOnlyIfNeeded = true
    super.init(window: window)
    self.status.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    self.status.textColor = .secondaryLabelColor
    self.status.widthAnchor.constraint(equalToConstant: 330).isActive = true
    self.status.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
  }

  required init?(coder: NSCoder) {
    fatalError("MonitorSettingsWindowController requires a monitor")
  }

  func show(for display: OtherDisplay) {
    guard let window = self.window else { return }
    let wasVisible = window.isVisible
    self.identity = Arm64DDC.EDIDIdentity(displayID: display.identifier)
    if self.displayPrefsID != display.prefsId || window.contentView?.subviews.isEmpty == true {
      self.displayPrefsID = display.prefsId
      self.buildContent(for: display)
    }
    let friendlyName = display.readPrefAsString(key: .friendlyName)
    let title = NSLocalizedString("Monitor Settings", comment: "Monitor settings window title")
    window.title = "\(title) — \(friendlyName.isEmpty ? display.name : friendlyName)"
    if !wasVisible {
      window.center()
    }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.orderFrontRegardless()
    self.refreshIfVisible()
  }

  @objc private func refreshClicked() {
    if let display = self.activeDisplay, app.retryMonitorSettings(for: display) { return }
    self.refreshIfVisible()
  }

  func refreshIfVisible() {
    guard self.window?.isVisible == true else { return }
    self.refreshID += 1
    let refreshID = self.refreshID
    for (command, _) in self.sliderRows {
      self.showSliderValue(nil, for: command)
    }
    for (command, _) in self.popupRows {
      self.showPreset(nil, for: command)
    }
    self.refreshButton.isEnabled = false
    let eligible = DisplayManager.shared.getOtherDisplays().filter(\.canOpenMonitorSettings)
    let sameMonitor = eligible.filter { self.identity == Arm64DDC.EDIDIdentity(displayID: $0.identifier) }
    guard let display = eligible.first(where: { $0.prefsId == self.displayPrefsID }) ??
      (sameMonitor.count == 1 && self.identity?.serial != 0 ? sameMonitor.first : nil) else {
      self.activeDisplay = nil
      self.status.stringValue = NSLocalizedString("Monitor unavailable.", comment: "Monitor settings status")
      self.refreshButton.isEnabled = true
      return
    }
    self.activeDisplay = display
    self.displayPrefsID = display.prefsId
    if app.reconfigureID != 0 || app.sleepID != 0 {
      self.status.stringValue = NSLocalizedString("Reading monitor settings…", comment: "Monitor settings status")
      return
    }
    if display.transportUnavailable && Arm64DDC.isArm64 {
      self.showReconnecting()
      app.recoverDDC(for: display)
      return
    }
    self.status.stringValue = NSLocalizedString("Reading monitor settings…", comment: "Monitor settings status")
    let commands = (Array(self.sliderRows.keys) + self.popupRows.keys.map { self.readCommand(for: $0) }).sorted { $0.rawValue < $1.rawValue }
    display.readMonitorSettings(commands) { [weak self] values, transportFailed in
      guard let self, self.refreshID == refreshID else { return }
      for (command, _) in self.sliderRows {
        guard let value = values[command], value.max > 0, value.current <= value.max else { continue }
        if self.basicCommands.contains(command) {
          display.updateMaximum(for: command, reported: value.max)
          if command != .brightness || !display.smoothBrightnessRunning {
            display.processCurrentDDCValue(isReadFromDisplay: true, command: command, firstrun: false, currentDDCValue: value.current)
          }
          let normalized = display.setupSliderCurrentValue(command: command)
          guard normalized.isFinite, (0 ... 1).contains(normalized) else { continue }
          self.showSliderValue(UInt16((normalized * 100).rounded()), for: command)
          display.sliderHandler[command]?.setValue(normalized, displayID: display.identifier)
        } else {
          self.showSliderValue(value.current, for: command, maximum: command == .blackStabilizer ? 100 : value.max)
        }
      }
      for (command, _) in self.popupRows {
        self.showPreset(values[self.readCommand(for: command)]?.current, for: command)
      }
      self.updateRGBAvailability()
      self.refreshButton.isEnabled = true
      if transportFailed {
        self.showReconnecting()
      } else if values.isEmpty {
        self.status.stringValue = NSLocalizedString("The monitor did not respond.", comment: "Monitor settings status")
      } else {
        self.status.stringValue = values.count == commands.count ? "" : NSLocalizedString("Some settings are unavailable in this monitor mode.", comment: "Monitor settings status")
      }
    }
  }

  private func showReconnecting() {
    self.refreshButton.isEnabled = true
    self.status.stringValue = NSLocalizedString("Monitor controls offline. Reconnecting automatically…", comment: "DDC link unavailable")
  }

  private func buildContent(for display: OtherDisplay) {
    self.sliderRows.removeAll()
    self.popupRows.removeAll()
    let isUS550 = display.modelNumber == 0x5c9d
    var pictureRows = [
      self.sliderRow(.brightness, title: NSLocalizedString("Brightness", comment: "Monitor setting")),
      self.sliderRow(.contrast, title: NSLocalizedString("Contrast", comment: "Monitor setting")),
    ]
    var colorRows: [[NSView]] = []
    if isUS550 {
      pictureRows.append(self.popupRow(.gamma, title: NSLocalizedString("Gamma", comment: "Monitor setting")))
      pictureRows.append(self.sliderRow(.blackStabilizer, title: NSLocalizedString("Black Stabilizer", comment: "Monitor setting"), increment: 5))
      colorRows.append(self.popupRow(.selectColorPreset, title: NSLocalizedString("Color temperature", comment: "Monitor setting")))
    }
    colorRows += [
      self.sliderRow(.videoGainRed, title: NSLocalizedString("Red", comment: "RGB gain")),
      self.sliderRow(.videoGainGreen, title: NSLocalizedString("Green", comment: "RGB gain")),
      self.sliderRow(.videoGainBlue, title: NSLocalizedString("Blue", comment: "RGB gain")),
    ]
    let audioRows = [self.sliderRow(.audioSpeakerVolume, title: NSLocalizedString("Volume", comment: "Monitor setting"))]
    let picture = self.section(NSLocalizedString("Picture", comment: "Monitor settings section"), rows: pictureRows)
    let color = self.section(NSLocalizedString("White Balance", comment: "Monitor settings section"), rows: colorRows)
    let audio = self.section(NSLocalizedString("Audio", comment: "Monitor settings section"), rows: audioRows)
    let footer = NSStackView(views: [self.status, self.refreshButton])
    footer.alignment = .centerY
    footer.spacing = 12
    let layout = NSStackView(views: [picture, color, audio, footer])
    layout.orientation = .vertical
    layout.alignment = .leading
    layout.spacing = 20
    layout.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 20, right: 26)
    let size = layout.fittingSize
    self.window?.contentView = layout
    self.window?.setContentSize(size)
  }

  private func section(_ title: String, rows: [[NSView]]) -> NSStackView {
    let heading = NSTextField(labelWithString: title)
    heading.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    let grid = NSGridView(views: rows)
    grid.rowAlignment = .none
    grid.column(at: 0).width = 132
    grid.columnSpacing = 12
    grid.rowSpacing = 8
    let stack = NSStackView(views: [heading, grid])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    return stack
  }

  private func sliderRow(_ command: Command, title: String, increment: Double = 1) -> [NSView] {
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(self.changeSlider(_:)))
    slider.isContinuous = false
    slider.tag = Int(command.rawValue)
    slider.widthAnchor.constraint(equalToConstant: 218).isActive = true
    slider.setAccessibilityLabel(title)
    let readout = NSTextField(labelWithString: "—")
    readout.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    readout.alignment = .right
    readout.widthAnchor.constraint(equalToConstant: 34).isActive = true
    let stepper = NSStepper()
    stepper.minValue = 0
    stepper.maxValue = 100
    stepper.increment = increment
    stepper.autorepeat = false
    stepper.valueWraps = false
    stepper.target = self
    stepper.action = #selector(self.changeSlider(_:))
    stepper.tag = slider.tag
    stepper.setAccessibilityLabel(title)
    self.sliderRows[command] = (slider, readout, stepper)
    return [NSTextField(labelWithString: title), slider, readout, stepper]
  }

  private func popupRow(_ command: Command, title: String) -> [NSView] {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.tag = Int(command.rawValue)
    popup.target = self
    popup.action = #selector(self.changePreset(_:))
    popup.setAccessibilityLabel(title)
    popup.addItem(withTitle: "—")
    popup.item(at: 0)?.isHidden = true
    for preset in self.presetOptions[command] ?? [] {
      popup.addItem(withTitle: preset.title)
    }
    self.popupRows[command] = popup
    return [NSTextField(labelWithString: title), popup, NSGridCell.emptyContentView, NSGridCell.emptyContentView]
  }

  private func showSliderValue(_ value: UInt16?, for command: Command, maximum: UInt16? = nil) {
    guard let row = self.sliderRows[command] else { return }
    self.sliderValues[command] = value
    if let maximum {
      row.slider.maxValue = Double(maximum)
      row.stepper.maxValue = Double(maximum)
    }
    row.slider.integerValue = Int(value ?? 0)
    row.stepper.integerValue = Int(value ?? 0)
    row.readout.stringValue = value.map { String($0) } ?? "—"
    row.slider.isEnabled = value != nil
    row.stepper.isEnabled = value != nil
  }

  private func readCommand(for command: Command) -> Command {
    command == .gamma ? .lgGammaMode : command
  }

  private func showPreset(_ value: UInt16?, for command: Command) {
    guard let popup = self.popupRows[command] else { return }
    self.presetValues[command] = value
    let index = self.presetOptions[command]?.firstIndex { $0.reportedValue == value }
    popup.selectItem(at: index.map { $0 + 1 } ?? 0)
    popup.isEnabled = value != nil
  }

  private func updateRGBAvailability() {
    for command in self.rgbCommands {
      let enabled = self.canEditRGB && self.sliderValues[command] != nil
      self.sliderRows[command]?.slider.isEnabled = enabled
      self.sliderRows[command]?.stepper.isEnabled = enabled
    }
  }

  private var canEditRGB: Bool {
    guard let temperature = self.popupRows[.selectColorPreset] else { return true }
    return temperature.isEnabled && self.presetValues[.selectColorPreset] == 0x0b
  }

  @objc private func changeSlider(_ sender: NSControl) {
    guard let display = self.activeDisplay, app.sleepID == 0, app.reconfigureID == 0,
          let command = Command(rawValue: UInt8(sender.tag)), let row = self.sliderRows[command], row.slider.isEnabled,
          let previous = self.sliderValues[command] else { return }
    let step = row.stepper.increment
    let value = UInt16(min(row.slider.maxValue, max(0, (sender.doubleValue / step).rounded() * step)))
    self.showSliderValue(value, for: command)
    guard value != previous else { return }
    if self.basicCommands.contains(command) {
      let normalized = Float(value) / 100
      display.setSliderValue(normalized, for: command)
      display.sliderHandler[command]?.setValue(normalized, displayID: display.identifier)
      if command == .brightness {
        display.brightnessSyncSourceValue = normalized
      }
      return
    }
    row.slider.isEnabled = false
    row.stepper.isEnabled = false
    self.status.stringValue = ""
    let generation = self.refreshID
    // The US550 reads Black Stabilizer in 0–100 units and writes it in steps of five.
    let writeValue = command == .blackStabilizer ? value / 5 : value
    display.setMonitorSetting(command, value: writeValue, verifyWith: command) { [weak self] result in
      guard let self, self.refreshID == generation else { return }
      self.showSliderValue(result?.current ?? previous, for: command)
      if self.rgbCommands.contains(command), !self.canEditRGB {
        row.slider.isEnabled = false
        row.stepper.isEnabled = false
      }
      if result?.current != value {
        self.showWriteFailure()
      }
    }
  }

  @objc private func changePreset(_ sender: NSPopUpButton) {
    let index = sender.indexOfSelectedItem - 1
    guard let display = self.activeDisplay, app.sleepID == 0, app.reconfigureID == 0,
          let command = Command(rawValue: UInt8(sender.tag)), let options = self.presetOptions[command],
          options.indices.contains(index), let previous = self.presetValues[command] else { return }
    let preset = options[index]
    guard preset.reportedValue != previous else { return }
    sender.isEnabled = false
    self.updateRGBAvailability()
    self.status.stringValue = ""
    let generation = self.refreshID
    display.setMonitorSetting(command, value: preset.writeValue, verifyWith: self.readCommand(for: command)) { [weak self] result in
      guard let self, self.refreshID == generation else { return }
      self.showPreset(result?.current ?? previous, for: command)
      self.updateRGBAvailability()
      if result?.current != preset.reportedValue {
        self.showWriteFailure()
      }
    }
  }

  private func showWriteFailure() {
    self.status.stringValue = NSLocalizedString("The monitor did not confirm the change.", comment: "Monitor settings write error")
  }
}
