//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import AVFoundation
import Cocoa
import Foundation
import os.log
import ServiceManagement
import Settings
import SimplyCoreAudio
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
  let statusItem: NSStatusItem = {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.behavior = .removalAllowed
    return item
  }()

  var mediaKeyTap = MediaKeyTapManager()
  var keyboardShortcuts = KeyboardShortcutsManager()
  let coreAudio = SimplyCoreAudio()
  var accessibilityObserver: NSObjectProtocol!
  var statusItemObserver: NSObjectProtocol!
  var statusItemVisibilityChangedByUser = true
  var reconfigureID: Int = 0 // dispatched reconfigure command ID
  private var generation = 0
  private var configurationWork: DispatchWorkItem?
  private var pendingFirstRun = false
  private var restoreAfterWake = false
  private var serviceObserver: DDCServiceObserver?
  private var changedDuringProbe = Set<CGDirectDisplayID>()
  private var recoveryDelays: [CGDirectDisplayID: Int] = [:]
  private var recoveryWork: [CGDirectDisplayID: DispatchWorkItem] = [:]
  var sleepID: Int = 0 // sleep event ID
  var safeMode = false
  var jobRunning = false
  var startupActionWriteCounter: Int = 0
  var audioPlayer: AVAudioPlayer?
  let updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: UpdaterDelegate(), userDriverDelegate: nil)

  var settingsPaneStyle: Settings.Style {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return Settings.Style.toolbarItems
    } else {
      return Settings.Style.segmentedControl
    }
  }

  lazy var settingsWindowController: SettingsWindowController = .init(
    panes: [
      mainPrefsVc!,
      menuslidersPrefsVc!,
      keyboardPrefsVc!,
      displaysPrefsVc!,
      aboutPrefsVc!,
    ],
    style: self.settingsPaneStyle,
    animated: true
  )

  func applicationDidFinishLaunching(_: Notification) {
    app = self
    self.subscribeEventListeners()
    self.showSafeModeAlertIfNeeded()
    if !prefs.bool(forKey: PrefKey.appAlreadyLaunched.rawValue) {
      self.showOnboardingWindow()
    }
    self.setPrefsBuildNumber()
    self.setDefaultPrefs()
    self.setMenu()
    CGDisplayRegisterReconfigurationCallback({ _, _, _ in
      DispatchQueue.main.async { app.displayReconfigured() }
    }, nil)
    if Arm64DDC.isArm64 {
      self.serviceObserver = DDCServiceObserver { [weak self] added, registryIDs in
        self?.ddcServicesChanged(added: added, registryIDs: registryIDs)
      }
    }
    self.configure(firstrun: true)
    DisplayManager.shared.createGammaActivityEnforcer()
    self.updaterController.startUpdater()
  }

  @objc func quitClicked(_: AnyObject) {
    os_log("Quit clicked", type: .info)
    menu.closeMenu()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      NSApplication.shared.terminate(self)
    }
  }

  @objc func prefsClicked(_: AnyObject) {
    os_log("Settings clicked", type: .info)
    self.settingsWindowController.show()
  }

  private func currentReopenSenderBundleIdentifier() -> String? {
    guard let event = NSAppleEventManager.shared().currentAppleEvent else { return nil }
    if let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value,
       let sender = NSRunningApplication(processIdentifier: pid_t(pid))
    {
      return sender.bundleIdentifier
    }
    if let pid = event.attributeDescriptor(forKeyword: keyAddressAttr)?.coerce(toDescriptorType: typeKernelProcessID)?.int32Value,
       let sender = NSRunningApplication(processIdentifier: pid_t(pid))
    {
      return sender.bundleIdentifier
    }
    return nil
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    guard let senderBundleIdentifier = self.currentReopenSenderBundleIdentifier()?.lowercased(),
          !senderBundleIdentifier.contains("workflow"), !senderBundleIdentifier.contains("shortcut")
    else { return false }
    self.prefsClicked(self)
    return false
  }

  func applicationWillTerminate(_: Notification) {
    os_log("Goodbye!", type: .info)
    DisplayManager.shared.resetSwBrightnessForAllDisplays(noPrefSave: true)
    self.updateStatusItemVisibility(true)
  }

  private func setPrefsBuildNumber() {
    let currentBuildNumber = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    let previousBuildNumber: Int = (Int(prefs.string(forKey: PrefKey.buildNumber.rawValue) ?? "0") ?? 0)
    if self.safeMode || ((previousBuildNumber < MIN_PREVIOUS_BUILD_NUMBER) && previousBuildNumber > 0) || (previousBuildNumber > currentBuildNumber), let bundleID = Bundle.main.bundleIdentifier {
      if !self.safeMode {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Incompatible previous version", comment: "Shown in the alert dialog")
        alert.informativeText = NSLocalizedString("Settings for an incompatible previous app version detected. Default settings are reloaded.", comment: "Shown in the alert dialog")
        alert.runModal()
      }
      prefs.removePersistentDomain(forName: bundleID)
    }
    prefs.set(currentBuildNumber, forKey: PrefKey.buildNumber.rawValue)
  }

  func setDefaultPrefs() {
    if !prefs.bool(forKey: PrefKey.appAlreadyLaunched.rawValue) {
      // Only settings that are not false, 0 or "" by default are set here. Assumes pre-wiped database.
      prefs.set(true, forKey: PrefKey.appAlreadyLaunched.rawValue)
      prefs.set(true, forKey: PrefKey.SUEnableAutomaticChecks.rawValue)
    }
  }

  @objc func displayReconfigured() {
    let firstChange = self.reconfigureID == 0
    self.invalidateDiscovery()
    self.reconfigureID = self.generation
    self.updateMediaKeyTap()
    os_log("Bumping reconfigureID to %{public}@", type: .info, String(self.reconfigureID))
    if firstChange {
      DisplayManager.shared.resetSwBrightnessForAllDisplays(noPrefSave: true)
      CGDisplayRestoreColorSyncSettings()
      _ = DisplayManager.shared.destroyAllShades()
    }
    if self.sleepID == 0 {
      let dispatchedReconfigureID = self.reconfigureID
      os_log("Display to be reconfigured with reconfigureID %{public}@", type: .info, String(dispatchedReconfigureID))
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.configure(dispatchedReconfigureID: dispatchedReconfigureID)
      }
    }
  }

  private func invalidateDiscovery() {
    self.generation += 1
    self.configurationWork?.cancel()
    for work in self.recoveryWork.values { work.cancel() }
    self.recoveryWork.removeAll()
    self.recoveryDelays.removeAll()
    self.changedDuringProbe.removeAll()
  }

  func configure(dispatchedReconfigureID: Int? = nil, firstrun: Bool = false) {
    guard self.sleepID == 0, dispatchedReconfigureID == nil || dispatchedReconfigureID == self.reconfigureID else { return }
    self.invalidateDiscovery()
    let generation = self.generation
    self.reconfigureID = generation
    self.pendingFirstRun = self.pendingFirstRun || firstrun
    self.updateMediaKeyTap()
    let manager = DisplayManager.shared
    let displays = manager.discoverDisplays()
    if manager.displays.isEmpty {
      manager.displays = displays
      menu.updateMenus()
    }
    menu.refreshMonitorSettings()
    let external = displays.compactMap { $0 as? OtherDisplay }
    let safeMode = self.safeMode
    let work = DispatchWorkItem {
      let matches = Arm64DDC.isArm64 && !safeMode ? Arm64DDC.getServiceMatches(displayIDs: external.map(\.identifier)) : []
      var readings: [CGDirectDisplayID: OtherDisplay.StartupReadings] = [:]
      for display in external {
        let match = matches.first { $0.displayID == display.identifier }
        readings[display.identifier] = display.readForConfiguration(match: match, safeMode: safeMode)
      }
      DispatchQueue.main.async {
        guard self.generation == generation, self.sleepID == 0 else { return }
        for display in external {
          if let reading = readings[display.identifier] {
            display.applyConfiguration(match: matches.first { $0.displayID == display.identifier }, readings: reading)
          }
        }
        manager.displays = displays
        manager.addDisplayCounterSuffixes()
        self.reconfigureID = 0
        self.configurationWork = nil
        let first = self.pendingFirstRun
        self.pendingFirstRun = false
        self.finishConfiguration(firstrun: first, readings: readings)
        for display in external where readings[display.identifier]?.transportFailed == true ||
          (display.canOpenMonitorSettings && !display.arm64ddc) {
          self.recoverDDC(for: display)
        }
      }
    }
    self.configurationWork = work
    manager.globalDDCQueue.async(execute: work)
  }

  private func finishConfiguration(firstrun: Bool, readings: [CGDirectDisplayID: OtherDisplay.StartupReadings]) {
    DisplayManager.shared.gammaInterferenceCounter = 0
    if firstrun && prefs.integer(forKey: PrefKey.startupAction.rawValue) != StartupAction.write.rawValue {
      DisplayManager.shared.resetSwBrightnessForAllDisplays(prefsOnly: true)
    }
    DisplayManager.shared.setupOtherDisplays(firstrun: firstrun, readings: readings)
    self.updateMenusAndKeys()
    if !firstrun || prefs.integer(forKey: PrefKey.startupAction.rawValue) == StartupAction.write.rawValue {
      if !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) {
        DisplayManager.shared.restoreSwBrightnessForAllDisplays(async: !prefs.bool(forKey: PrefKey.disableSmoothBrightness.rawValue))
      }
    }
    displaysPrefsVc?.loadDisplayList()
    menu.refreshMonitorSettings()
    self.job(start: true)
    if self.restoreAfterWake {
      self.restoreAfterWake = false
      self.startupActionWriteRepeatAfterSober()
    }
  }

  private func ddcServicesChanged(added: Bool, registryIDs: Set<UInt64>) {
    guard self.sleepID == 0, self.reconfigureID == 0 else { return }
    for display in DisplayManager.shared.getOtherDisplays() {
      let id = display.identifier
      if added && display.transportUnavailable {
        if self.recoveryWork[id] != nil && self.recoveryDelays[id] == nil {
          self.changedDuringProbe.insert(id)
        } else {
          self.recoverDDC(for: display, immediately: true)
        }
      } else if !added, let current = display.arm64RegistryID, registryIDs.contains(current) {
        self.recoverDDC(for: display, immediately: true)
      }
    }
  }

  func recoverDDC(for display: OtherDisplay, immediately: Bool = false) {
    let id = display.identifier
    let manager = DisplayManager.shared
    guard Arm64DDC.isArm64, !self.safeMode, self.reconfigureID == 0, self.sleepID == 0,
          !display.isVirtual, !display.isDummy, display.samsungTV == nil,
          !display.readPrefAsBool(key: .forceSw),
          manager.displays.contains(where: { $0 === display }) else { return }
    let wasUnavailable = display.transportUnavailable
    display.transportUnavailable = true
    if self.recoveryWork[id] != nil {
      // A manual refresh may skip backoff but never duplicates a running probe.
      guard immediately, self.recoveryDelays[id] != nil else { return }
      self.recoveryWork[id]?.cancel()
    }
    let interval = self.recoveryDelays[id] ?? 2
    self.recoveryDelays[id] = interval
    let generation = self.generation
    let ids = manager.getOtherDisplays().map(\.identifier)
    let work = DispatchWorkItem {
      self.recoveryDelays[id] = nil
      manager.globalDDCQueue.async {
        display.releaseFailedDDCService()
        let candidates = Arm64DDC.recoveryCandidates(for: id, among: ids)
        let recovered = display.reopenDDC(candidates: candidates)
        DispatchQueue.main.async {
          guard generation == self.generation else { return }
          self.recoveryWork[id] = nil
          let newServiceArrived = self.changedDuringProbe.remove(id) != nil
          if let recovered {
            display.transportUnavailable = false
            display.markDDCRecovered(registryID: recovered)
            os_log("DDC recovered for display %{public}u", type: .info, id)
            self.updateMenusAndKeys()
            menu.refreshMonitorSettings()
          } else {
            self.recoveryDelays[id] = min(interval * 2, 60)
            os_log("DDC unavailable for display %{public}u after checking %{public}d candidate(s), retry in %{public}d s", type: .info, id, candidates.count, self.recoveryDelays[id] ?? 60)
            self.recoverDDC(for: display, immediately: newServiceArrived)
          }
        }
      }
    }
    self.recoveryWork[id] = work
    if !wasUnavailable { menu.refreshMonitorSettings() }
    DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : Double(interval)), execute: work)
  }

  func retryMonitorSettings(for display: OtherDisplay) -> Bool {
    guard self.recoveryWork[display.identifier] != nil else { return false }
    self.recoverDDC(for: display, immediately: true)
    return true
  }

  func updateMenusAndKeys() {
    menu.updateMenus()
    self.keyboardShortcuts.updateRegistrations()
    self.updateMediaKeyTap()
  }

  func requestMediaKeyAccess() {
    let permissionsRequired: Bool = [KeyboardVolume.media.rawValue, KeyboardVolume.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardVolume.rawValue)) || [KeyboardBrightness.media.rawValue, KeyboardBrightness.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardBrightness.rawValue))
    if !MediaKeyTapManager.readPrivileges(prompt: false), permissionsRequired {
      _ = MediaKeyTapManager.readPrivileges(prompt: true)
    }
  }

  private func subscribeEventListeners() {
    NotificationCenter.default.addObserver(self, selector: #selector(self.audioDeviceChanged), name: Notification.Name.defaultOutputDeviceChanged, object: nil) // subscribe Audio output detector (SimplyCoreAudio)
    DistributedNotificationCenter.default.addObserver(self, selector: #selector(self.displayReconfigured), name: NSNotification.Name(rawValue: kColorSyncDisplayDeviceProfilesNotification.takeRetainedValue() as String), object: nil) // ColorSync change
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.sleepNotification), name: NSWorkspace.screensDidSleepNotification, object: nil) // sleep and wake listeners
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.wakeNotification), name: NSWorkspace.screensDidWakeNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.sleepNotification), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.wakeNotification), name: NSWorkspace.didWakeNotification, object: nil)
    _ = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(rawValue: NSNotification.Name.accessibilityApi.rawValue), object: nil, queue: nil) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.updateMediaKeyTap() } } // listen for accessibility status changes
    self.statusItemObserver = self.statusItem.observe(\.isVisible, options: [.old, .new]) { _, _ in self.statusItemVisibilityChanged() }
  }

  @objc private func sleepNotification() {
    self.invalidateDiscovery()
    self.sleepID += 1
    os_log("Sleeping with sleep %{public}@", type: .info, String(self.sleepID))
    self.updateMediaKeyTap()
  }

  @objc private func wakeNotification() {
    if self.sleepID != 0 {
      os_log("Waking up from sleep %{public}@", type: .info, String(self.sleepID))
      let dispatchedSleepID = self.sleepID
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { // Some displays take time to recover...
        self.soberNow(dispatchedSleepID: dispatchedSleepID)
      }
    }
  }

  private func soberNow(dispatchedSleepID: Int) {
    if self.sleepID == dispatchedSleepID {
      os_log("Sober from sleep %{public}@", type: .info, String(self.sleepID))
      self.sleepID = 0
      self.restoreAfterWake = true
      self.configure()
      self.updateMediaKeyTap()
    }
  }

  private func startupActionWriteRepeatAfterSober(dispatchedCounter: Int = 0) {
    let counter = dispatchedCounter == 0 ? 10 : dispatchedCounter
    self.startupActionWriteCounter = dispatchedCounter == 0 ? counter : self.startupActionWriteCounter
    guard prefs.integer(forKey: PrefKey.startupAction.rawValue) == StartupAction.write.rawValue, self.startupActionWriteCounter == counter else {
      return
    }
    os_log("Sober write action repeat for DDC - %{public}@", type: .info, String(counter))
    DisplayManager.shared.restoreOtherDisplays()
    self.startupActionWriteCounter = counter - 1
    if counter > 1 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.startupActionWriteRepeatAfterSober(dispatchedCounter: counter - 1)
      }
    }
  }

  private func job(start: Bool = false) {
    guard !(self.jobRunning && start) else {
      return
    }
    if self.sleepID == 0, self.reconfigureID == 0 {
      if !self.jobRunning {
        os_log("MonitorControl job started.", type: .info)
        self.jobRunning = true
      }
      var refreshedSomething = false
      for display in DisplayManager.shared.displays {
        if let otherDisplay = display as? OtherDisplay {
          otherDisplay.samsungTV?.refreshIfNeeded()
          if otherDisplay.usesSamsungBrightness { continue }
        }
        let delta = display.refreshBrightness()
        if delta != 0 {
          refreshedSomething = true
          if prefs.bool(forKey: PrefKey.enableBrightnessSync.rawValue) {
            for targetDisplay in DisplayManager.shared.displays where targetDisplay != display {
              os_log("Updating delta from display %{public}@ to display %{public}@", type: .info, String(display.identifier), String(targetDisplay.identifier))
              let newValue = max(0, min(1, targetDisplay.getBrightness() + delta))
              _ = targetDisplay.setBrightness(newValue)
              if let slider = targetDisplay.sliderHandler[.brightness] {
                slider.setValue(newValue, displayID: targetDisplay.identifier)
              }
            }
          }
        }
      }
      let nextRefresh = refreshedSomething ? 0.1 : 1.0
      DispatchQueue.main.asyncAfter(deadline: .now() + nextRefresh) {
        self.job()
      }
    } else {
      self.jobRunning = false
      os_log("MonitorControl job died because of sleep or reconfiguration.", type: .info)
    }
  }

  func settingsReset() {
    os_log("Resetting all settings.")
    if !prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) {
      DisplayManager.shared.resetSwBrightnessForAllDisplays(async: false)
    }
    if let bundleID = Bundle.main.bundleIdentifier {
      prefs.removePersistentDomain(forName: bundleID)
    }
    app.updateStatusItemVisibility(true)
    self.setDefaultPrefs()
    self.updateMediaKeyTap()
    self.configure(firstrun: true)
  }

  @objc func audioDeviceChanged() {
    if let defaultDevice = self.coreAudio.defaultOutputDevice {
      os_log("Default output device changed to “%{public}@”.", type: .info, defaultDevice.name)
      os_log("Can device set its own volume? %{public}@", type: .info, defaultDevice.canSetVirtualMainVolume(scope: .output).description)
    }
    self.updateMediaKeyTap()
  }

  func updateMediaKeyTap() {
    self.mediaKeyTap.updateMediaKeyTap()
  }

  func setStartAtLogin(enabled: Bool) {
    let identifier = "\(Bundle.main.bundleIdentifier!)Helper" as CFString
    SMLoginItemSetEnabled(identifier, enabled)
  }

  func getSystemSettings() -> [String: AnyObject]? {
    var propertyListFormat = PropertyListSerialization.PropertyListFormat.xml
    let plistPath = NSString(string: "~/Library/Preferences/.GlobalPreferences.plist").expandingTildeInPath
    guard let plistXML = FileManager.default.contents(atPath: plistPath) else {
      return nil
    }
    do {
      return try PropertyListSerialization.propertyList(from: plistXML, options: .mutableContainersAndLeaves, format: &propertyListFormat) as? [String: AnyObject]
    } catch {
      os_log("Error reading system prefs plist: %{public}@", type: .info, error.localizedDescription)
      return nil
    }
  }

  func macOS10() -> Bool {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return false
    } else {
      return true
    }
  }

  func playVolumeChangedSound() {
    guard let settings = app.getSystemSettings(), let hasSoundEnabled = settings["com.apple.sound.beep.feedback"] as? Int, hasSoundEnabled == 1 else {
      return
    }
    do {
      self.audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"))
      self.audioPlayer?.volume = 1
      self.audioPlayer?.play()
    } catch {
      os_log("%{public}@", type: .error, error.localizedDescription)
    }
  }

  private func setMenu() {
    menu = MenuHandler()
    menu.delegate = menu
    self.statusItem.button?.image = NSImage(named: "status")
    self.statusItem.menu = menu
  }

  private func showSafeModeAlertIfNeeded() {
    if NSEvent.modifierFlags.contains(NSEvent.ModifierFlags.shift) {
      self.safeMode = true
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Safe Mode Activated", comment: "Shown in the alert dialog")
      alert.informativeText = NSLocalizedString("Shift was pressed during launch. MonitorControl started in safe mode. Default settings are reloaded, DDC read is blocked.", comment: "Shown in the alert dialog")
      alert.runModal()
    }
  }

  private func showOnboardingWindow() {
    onboardingVc?.showWindow(self)
    onboardingVc?.window?.center()
    NSApp.activate(ignoringOtherApps: true)
  }

  private func statusItemVisibilityChanged() {
    if !self.statusItem.isVisible, self.statusItemVisibilityChangedByUser {
      prefs.set(MenuIcon.hide.rawValue, forKey: PrefKey.menuIcon.rawValue)
    }
  }

  func updateStatusItemVisibility(_ visible: Bool) {
    self.statusItemVisibilityChangedByUser = false
    self.statusItem.isVisible = visible
    self.statusItemVisibilityChangedByUser = true
  }
}
