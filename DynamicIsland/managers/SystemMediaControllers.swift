/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import AppKit
import CoreAudio
import os
import CoreGraphics
import IOKit

extension Notification.Name {
    static let systemVolumeDidChange = Notification.Name("DynamicIsland.systemVolumeDidChange")
    static let systemBrightnessDidChange = Notification.Name("DynamicIsland.systemBrightnessDidChange")
    static let systemAudioRouteDidChange = Notification.Name("DynamicIsland.systemAudioRouteDidChange")
}

final class HUDSuppressionCoordinator {
    static let shared = HUDSuppressionCoordinator()

    private let queue = DispatchQueue(label: "com.dynamicisland.hud-suppression")
    private var volumeSuppressedUntil: Date?

    func suppressVolumeHUD(for interval: TimeInterval) {
        guard interval > 0 else { return }
        queue.sync {
            let proposed = Date().addingTimeInterval(interval)
            if let current = volumeSuppressedUntil {
                volumeSuppressedUntil = max(current, proposed)
            } else {
                volumeSuppressedUntil = proposed
            }
        }
    }

    var shouldSuppressVolumeHUD: Bool {
        queue.sync {
            guard let expiration = volumeSuppressedUntil else {
                return false
            }
            if Date() < expiration {
                return true
            }
            volumeSuppressedUntil = nil
            return false
        }
    }
}

final class SystemVolumeController {
    static let shared = SystemVolumeController()

    var onVolumeChange: ((Float, Bool) -> Void)?
    var onRouteChange: (() -> Void)?

    private let callbackQueue = DispatchQueue(label: "com.dynamicisland.volume-listener")
    /// Written from `callbackQueue` when the route changes and read from
    /// wherever a volume is asked for, so it is not a plain stored property.
    private let deviceIDStorage = OSAllocatedUnfairLock(initialState: AudioDeviceID(0))

    private var currentDeviceID: AudioDeviceID {
        get { deviceIDStorage.withLock { $0 } }
        set { deviceIDStorage.withLock { $0 = newValue } }
    }
    private var listenersInstalled = false
    private struct InstalledListener {
        let deviceID: AudioDeviceID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var installedListeners: [InstalledListener] = []
    private var volumeElement: AudioObjectPropertyElement?
    private var muteElement: AudioObjectPropertyElement?
    private let silenceThreshold: Float = 0.001 // Treat very low values as mute requests.

    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` ('vmvc').
    ///
    /// The property macOS's own volume UI works through. Some outputs publish
    /// no per-channel `VolumeScalar` at all -- HDMI and DisplayPort commonly,
    /// and built-in speakers on some Macs -- but still answer this one.
    private let virtualMainVolumeSelector = AudioObjectPropertySelector(0x766D_7663)

    /// The last level actually read from the hardware, per device.
    ///
    /// A failed read used to be reported as zero, which is a real volume and
    /// therefore indistinguishable from silence: the slider dropped to the
    /// bottom and stayed there. Holding the last known level makes a failed
    /// read do nothing instead of lying.
    ///
    /// Keyed by device because levels are not shared: headphones at 20% and
    /// speakers at 80% are two different facts, and answering one with the
    /// other after a route change would be a fresh way of being wrong. The
    /// most recent reading of any device is kept as the last resort, for a
    /// device that has never yet answered -- "unchanged" is a better guess
    /// than "silent" when the truth is "unknown".
    private struct VolumeMemory {
        var byDevice: [AudioDeviceID: Float] = [:]
        /// Absent until some device has answered once.
        ///
        /// Starting this at zero gave the same protection everywhere except
        /// the one place it was needed most: before the first successful
        /// read there was nothing to hold, so an unreadable device at launch
        /// published 0% -- silence the user never asked for, and
        /// indistinguishable from having turned it down themselves.
        var mostRecent: Float?
    }

    private let volumeMemory = OSAllocatedUnfairLock(initialState: VolumeMemory())

    private let candidateElements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain,
        AudioObjectPropertyElement(1),
        AudioObjectPropertyElement(2)
    ]

    private init() {
        currentDeviceID = resolveDefaultDevice()
        refreshPropertyElements()
        installDefaultDeviceListener()
        installVolumeListeners(for: currentDeviceID)
        notifyCurrentState()
    }

    func start() {
        // Listeners are installed during init, nothing else required.
    }

    func stop() {
        // We keep listeners alive for the app lifetime; clearing closures prevents UI updates.
        onVolumeChange = nil
        onRouteChange = nil
    }

    func adjust(by delta: Float) {
        guard delta != 0 else { return }
        if isMuted {
            setMuted(false)
        }

        let deviceID = currentDeviceID
        // Reads on the way through, so a device that can answer populates its
        // own entry before the check below.
        let current = currentVolume

        // A relative change needs a real level to be relative to. `getVolume`
        // will happily answer with another device's level rather than report a
        // zero it does not mean -- fine for showing a slider, not fine as the
        // base for a write, where being 60 points out moves the volume 60
        // points. Absolute sets from the slider still work; only the delta is
        // refused.
        guard volumeMemory.withLock({ $0.byDevice[deviceID] != nil }) else {
            NSLog("⚠️ Not adjusting volume on \(deviceID): no confirmed level to adjust from")
            return
        }

        setVolume(max(0, min(1, current + delta)), on: deviceID)
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    var currentVolume: Float {
        getVolume()
    }

    var isMuted: Bool {
        getMuteState()
    }

    func setVolume(_ value: Float) {
        setVolume(value, on: currentDeviceID)
    }

    /// Writes a level to one named device.
    ///
    /// The device is a parameter rather than something each step looks up for
    /// itself, because the steps are not instantaneous: elements are discovered
    /// on whatever device is default at that moment, and the write happens
    /// after. A route change in between had the write aiming the old device's
    /// elements at the new device.
    private func setVolume(_ value: Float, on deviceID: AudioDeviceID) {
        let clamped = max(0, min(1, value))
        let currentlyMuted = getMuteState(on: deviceID)

        if clamped <= silenceThreshold {
            if !currentlyMuted {
                setMuted(true, on: deviceID)
            }
        } else if currentlyMuted {
            setMuted(false, on: deviceID)
        }

        let elements = volumeElements(on: deviceID)
        var wrote = false

        if elements.isEmpty {
            var volume = clamped
            wrote = setData(selector: kAudioDevicePropertyVolumeScalar, on: deviceID, data: &volume) == noErr
        } else {
            for element in elements {
                var volume = clamped
                let status = setData(selector: kAudioDevicePropertyVolumeScalar, element: element, on: deviceID, data: &volume)
                if status == noErr {
                    cache(element: element, for: kAudioDevicePropertyVolumeScalar)
                    wrote = true
                } else {
                    NSLog("⚠️ Failed to set volume for element \(element): \(status)")
                }
            }
        }

        // Same fallback the read side uses, for the same devices: a scalar
        // nobody accepted does not mean the volume cannot be set.
        if !wrote, writeVirtualMainVolume(clamped, on: deviceID) {
            wrote = true
        }

        if wrote {
            // The device has just been told what its level is, so that is what
            // it is until a read says otherwise. Without this, the read that
            // `notifyCurrentState` is about to do can fail and hand back the
            // level from before the write -- and the slider springs back to
            // where the user just dragged it from.
            volumeMemory.withLock {
                $0.byDevice[deviceID] = clamped
                $0.mostRecent = clamped
            }
        } else {
            NSLog("⚠️ Failed to set volume on \(deviceID)")
        }

        notifyCurrentState()
    }

    func setMuted(_ muted: Bool) {
        setMuted(muted, on: currentDeviceID)
    }

    private func setMuted(_ muted: Bool, on deviceID: AudioDeviceID) {
        var muteFlag: UInt32 = muted ? 1 : 0
        let elements = muteElements(on: deviceID)

        if elements.isEmpty {
            let status = setData(selector: kAudioDevicePropertyMute, on: deviceID, data: &muteFlag)
            if status != noErr {
                NSLog("⚠️ Failed to set mute state: \(status)")
            }
            return
        }

        for element in elements {
            var value = muteFlag
            let status = setData(selector: kAudioDevicePropertyMute, element: element, on: deviceID, data: &value)
            if status != noErr {
                NSLog("⚠️ Failed to set mute state for element \(element): \(status)")
            } else {
                cache(element: element, for: kAudioDevicePropertyMute)
            }
        }
    }

    // MARK: - Private

    private func resolveDefaultDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout.size(ofValue: deviceID))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        if status != noErr {
            NSLog("⚠️ Unable to fetch default audio device: \(status)")
        }
        return deviceID
    }

    private func installDefaultDeviceListener() {
        guard !listenersInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            callbackQueue
        ) { [weak self] _, _ in
            guard let self else { return }
            self.handleDefaultDeviceChanged()
        }
        if status != noErr {
            NSLog("⚠️ Failed to install default device listener: \(status)")
        }
        listenersInstalled = true
    }

    private func installVolumeListeners(for deviceID: AudioDeviceID) {
        // Route changes call this again. Without taking the old ones down
        // first, every change left another live pair listening to a device we
        // no longer read, each still calling notifyCurrentState.
        removeVolumeListeners()

        if let element = resolveElement(selector: kAudioDevicePropertyVolumeScalar, deviceID: deviceID) {
            volumeElement = element
            addVolumeListener(selector: kAudioDevicePropertyVolumeScalar, element: element, deviceID: deviceID)
        }

        if let element = resolveElement(selector: kAudioDevicePropertyMute, deviceID: deviceID) {
            muteElement = element
            addVolumeListener(selector: kAudioDevicePropertyMute, element: element, deviceID: deviceID)
        }

        // The devices this fallback exists for are exactly the ones with no
        // scalar element to listen on, so without this they would read
        // correctly once and then never hear about a change made anywhere
        // else -- the keyboard keys, Control Centre, another app.
        var virtualAddress = makeAddress(selector: virtualMainVolumeSelector, element: kAudioObjectPropertyElementMain)
        if propertyExists(deviceID: deviceID, address: &virtualAddress) {
            addVolumeListener(selector: virtualMainVolumeSelector, element: kAudioObjectPropertyElementMain, deviceID: deviceID)
        }
    }

    private func addVolumeListener(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement,
        deviceID: AudioDeviceID
    ) {
        var address = makeAddress(selector: selector, element: element)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyCurrentState()
        }

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, callbackQueue, block)
        guard status == noErr else {
            NSLog("⚠️ Failed to observe volume property on \(deviceID): \(status)")
            return
        }

        installedListeners.append(InstalledListener(deviceID: deviceID, address: address, block: block))
    }

    private func removeVolumeListeners() {
        for listener in installedListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.deviceID, &address, callbackQueue, listener.block)
        }
        installedListeners.removeAll()
    }

    private func handleDefaultDeviceChanged() {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.currentDeviceID = self.resolveDefaultDevice()
            self.refreshPropertyElements()
            self.installVolumeListeners(for: self.currentDeviceID)
            self.notifyCurrentState()
            DispatchQueue.main.async {
                self.onRouteChange?()
                NotificationCenter.default.post(name: .systemAudioRouteDidChange, object: nil)
            }
        }
    }

    private func notifyCurrentState() {
        // Nothing has ever been read: say nothing rather than announce a
        // level. There is no volume to report yet, and every value that could
        // stand in for "unknown" is a real volume to whoever receives it.
        guard let volume = knownVolume() else { return }
        let muted = getMuteState()
        DispatchQueue.main.async {
            self.onVolumeChange?(volume, muted)
            NotificationCenter.default.post(name: .systemVolumeDidChange, object: nil, userInfo: ["value": volume, "muted": muted])
        }
    }

    private func getVolume() -> Float {
        knownVolume() ?? 0
    }

    /// The current level, or nil when no device has ever answered.
    ///
    /// Callers that must produce a number fall back to zero; callers that are
    /// telling somebody else what the volume is should say nothing instead.
    private func knownVolume() -> Float? {
        // One snapshot for the whole read. Re-reading `currentDeviceID` in each
        // helper meant a route change part-way through could read device B and
        // file the answer under device A -- the precise mix-up the per-device
        // memory exists to avoid.
        let deviceID = currentDeviceID

        if let value = readScalarVolume(on: deviceID) ?? readVirtualMainVolume(on: deviceID) {
            volumeMemory.withLock {
                $0.byDevice[deviceID] = value
                $0.mostRecent = value
            }
            return value
        }

        // Every read failed. That is not the same as the volume being zero,
        // and reporting zero pins the slider to the bottom for as long as the
        // device stays unreadable.
        NSLog("⚠️ Unable to fetch volume for \(deviceID); holding the last known level")
        return volumeMemory.withLock { $0.byDevice[deviceID] ?? $0.mostRecent }
    }

    /// The per-element `VolumeScalar` reading, or nil when the device exposes
    /// none that can be read.
    private func readScalarVolume(on deviceID: AudioDeviceID) -> Float? {
        let elements = volumeElements(on: deviceID)

        if elements.isEmpty {
            var volume = Float32(0)
            let status = getData(selector: kAudioDevicePropertyVolumeScalar, on: deviceID, data: &volume)
            return status == noErr ? volume : nil
        }

        var masterVolume: Float?
        var accumulator: Float = 0
        var count: Float = 0

        for element in elements {
            var value = Float32(0)
            let status = getData(selector: kAudioDevicePropertyVolumeScalar, element: element, on: deviceID, data: &value)
            if status == noErr {
                if element == kAudioObjectPropertyElementMain {
                    masterVolume = value
                }
                accumulator += value
                count += 1
            }
        }

        if let masterVolume { return masterVolume }
        return count > 0 ? accumulator / count : nil
    }

    private func readVirtualMainVolume(on deviceID: AudioDeviceID) -> Float? {
        var address = makeAddress(selector: virtualMainVolumeSelector, element: kAudioObjectPropertyElementMain)
        guard propertyExists(deviceID: deviceID, address: &address) else { return nil }

        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func writeVirtualMainVolume(_ value: Float, on deviceID: AudioDeviceID) -> Bool {
        var address = makeAddress(selector: virtualMainVolumeSelector, element: kAudioObjectPropertyElementMain)
        guard propertyExists(deviceID: deviceID, address: &address) else { return false }

        var volume = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume) == noErr
    }

    private func getMuteState() -> Bool {
        getMuteState(on: currentDeviceID)
    }

    private func getMuteState(on deviceID: AudioDeviceID) -> Bool {
        let elements = muteElements(on: deviceID)

        if elements.isEmpty {
            var mute: UInt32 = 0
            let status = getData(selector: kAudioDevicePropertyMute, on: deviceID, data: &mute)
            if status != noErr {
                return false
            }
            return mute != 0
        }

        var retrieved = false
        var allMuted = true

        for element in elements {
            var value: UInt32 = 0
            let status = getData(selector: kAudioDevicePropertyMute, element: element, on: deviceID, data: &value)
            if status == noErr {
                retrieved = true
                if value == 0 {
                    allMuted = false
                }
            }
        }

        if retrieved {
            return allMuted
        }

        var fallback: UInt32 = 0
        let status = getData(selector: kAudioDevicePropertyMute, data: &fallback)
        if status != noErr {
            return false
        }
        return fallback != 0
    }

    private func refreshPropertyElements() {
        volumeElement = resolveElement(selector: kAudioDevicePropertyVolumeScalar, deviceID: currentDeviceID)
        muteElement = resolveElement(selector: kAudioDevicePropertyMute, deviceID: currentDeviceID)
    }

    private func resolveElement(selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> AudioObjectPropertyElement? {
        for element in candidateElements {
            var address = makeAddress(selector: selector, element: element)
            if propertyExists(deviceID: deviceID, address: &address) {
                return element
            }
        }
        return nil
    }

    private func preferredElements(for selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        if let cached = cachedElement(for: selector) {
            return [cached] + candidateElements.filter { $0 != cached }
        }
        return candidateElements
    }

    private func cachedElement(for selector: AudioObjectPropertySelector) -> AudioObjectPropertyElement? {
        switch selector {
        case kAudioDevicePropertyVolumeScalar:
            return volumeElement
        case kAudioDevicePropertyMute:
            return muteElement
        default:
            return nil
        }
    }

    private func cache(element: AudioObjectPropertyElement, for selector: AudioObjectPropertySelector) {
        switch selector {
        case kAudioDevicePropertyVolumeScalar:
            volumeElement = element
        case kAudioDevicePropertyMute:
            muteElement = element
        default:
            break
        }
    }

    private func makeAddress(selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private func propertyExists(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        withUnsafePointer(to: &address) { pointer in
            AudioObjectHasProperty(deviceID, pointer)
        }
    }

    private func getData<T>(selector: AudioObjectPropertySelector, on deviceID: AudioDeviceID? = nil, data: inout T) -> OSStatus {
        let target = deviceID ?? currentDeviceID
        var lastStatus: OSStatus = kAudioHardwareUnspecifiedError
        for element in preferredElements(for: selector) {
            var address = makeAddress(selector: selector, element: element)
            guard propertyExists(deviceID: target, address: &address) else { continue }
            var size = UInt32(MemoryLayout<T>.size)
            lastStatus = AudioObjectGetPropertyData(target, &address, 0, nil, &size, &data)
            if lastStatus == noErr {
                cache(element: element, for: selector)
                return lastStatus
            }
        }
        return lastStatus
    }

    private func setData<T>(selector: AudioObjectPropertySelector, on deviceID: AudioDeviceID? = nil, data: inout T) -> OSStatus {
        let target = deviceID ?? currentDeviceID
        var lastStatus: OSStatus = kAudioHardwareUnspecifiedError
        for element in preferredElements(for: selector) {
            var address = makeAddress(selector: selector, element: element)
            guard propertyExists(deviceID: target, address: &address) else { continue }
            let size = UInt32(MemoryLayout<T>.size)
            lastStatus = AudioObjectSetPropertyData(target, &address, 0, nil, size, &data)
            if lastStatus == noErr {
                cache(element: element, for: selector)
                return lastStatus
            }
        }
        return lastStatus
    }

    private func getData<T>(selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement, on deviceID: AudioDeviceID? = nil, data: inout T) -> OSStatus {
        let target = deviceID ?? currentDeviceID
        var address = makeAddress(selector: selector, element: element)
        guard propertyExists(deviceID: target, address: &address) else {
            return kAudioHardwareUnknownPropertyError
        }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(target, &address, 0, nil, &size, &data)
    }

    private func setData<T>(selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement, on deviceID: AudioDeviceID? = nil, data: inout T) -> OSStatus {
        let target = deviceID ?? currentDeviceID
        var address = makeAddress(selector: selector, element: element)
        guard propertyExists(deviceID: target, address: &address) else {
            return kAudioHardwareUnknownPropertyError
        }
        let size = UInt32(MemoryLayout<T>.size)
        return AudioObjectSetPropertyData(target, &address, 0, nil, size, &data)
    }

    private func volumeElements(on deviceID: AudioDeviceID? = nil) -> [AudioObjectPropertyElement] {
        let target = deviceID ?? currentDeviceID
        return candidateElements.filter { element in
            var address = makeAddress(selector: kAudioDevicePropertyVolumeScalar, element: element)
            return propertyExists(deviceID: target, address: &address)
        }
    }

    private func muteElements(on deviceID: AudioDeviceID? = nil) -> [AudioObjectPropertyElement] {
        let target = deviceID ?? currentDeviceID
        return candidateElements.filter { element in
            var address = makeAddress(selector: kAudioDevicePropertyMute, element: element)
            return propertyExists(deviceID: target, address: &address)
        }
    }
}

final class SystemBrightnessController {
    static let shared = SystemBrightnessController()

    var onBrightnessChange: ((Float) -> Void)?

    private let notificationCenter = NotificationCenter.default
    private var observers: [NSObjectProtocol] = []
    private var notificationsInstalled = false
    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var lastEmittedBrightness: Float = 0.5
    private let coreBrightnessClient = CoreBrightnessDisplayClient.shared
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 0.15
    private let pollChangeThreshold: Float = 0.005

    // MARK: - User-initiated brightness gate
    private var userInitiatedBrightnessChange = false
    private var userInitiatedResetTimer: Timer?
    private let userInitiatedWindow: TimeInterval = 1.5

    // MARK: - Emission throttling
    private var lastEmissionDate: Date = .distantPast
    private let minimumEmissionInterval: TimeInterval = 0.03  // ~33 fps max for drag

    private init() {
        displayID = CGMainDisplayID()
        registerExternalNotifications()
        lastEmittedBrightness = currentBrightness
    }

    func start() {
        displayID = CGMainDisplayID()
        let initial = currentBrightness
        lastEmittedBrightness = initial
        NSLog("✅ SystemBrightnessController: started with initial brightness: %.3f (Display ID: %u, CoreBrightness: %@)",
              initial, displayID, coreBrightnessClient.isAvailable ? "available" : "unavailable")
        notifyCurrentBrightness()
        startPolling()
    }

    func stop() {
        onBrightnessChange = nil
        pollTimer?.invalidate()
        pollTimer = nil
        userInitiatedResetTimer?.invalidate()
        userInitiatedResetTimer = nil
        userInitiatedBrightnessChange = false
    }

    func adjust(by delta: Float) {
        markUserInitiated()

        let current = currentBrightness
        let target = max(0, min(1, current + delta))
        applyBrightness(target)
        emitBrightnessChange(value: target, force: true)
    }

    func setBrightness(_ value: Float) {
        let clamped = max(0, min(1, value))
        markUserInitiated()

        applyBrightness(clamped)
        emitBrightnessChange(value: clamped, force: false)
    }

    // MARK: - User-initiated helpers

    private func markUserInitiated() {
        userInitiatedBrightnessChange = true
        userInitiatedResetTimer?.invalidate()
        userInitiatedResetTimer = Timer.scheduledTimer(withTimeInterval: userInitiatedWindow, repeats: false) { [weak self] _ in
            self?.userInitiatedBrightnessChange = false
        }
    }

    var currentBrightness: Float {
        if let level = getBrightnessViaDisplayServices() {
            return level
        }
        if coreBrightnessClient.isAvailable, let level = coreBrightnessClient.currentBrightness() {
            return level
        }
        guard let service = displayService() else { return lastEmittedBrightness }
        var brightness: Float = 0
        let result = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
        IOObjectRelease(service)
        if result == kIOReturnSuccess {
            return brightness
        }
        return lastEmittedBrightness
    }

    private func notifyCurrentBrightness() {
        let brightness = currentBrightness
        emitBrightnessChange(value: brightness, force: true)
    }

    private func applyBrightness(_ value: Float) {
        let clamped = max(0, min(1, value))
        if setBrightnessViaDisplayServices(clamped) {
            return
        }
        if coreBrightnessClient.isAvailable && coreBrightnessClient.setBrightness(clamped) {
            return
        }
        guard let service = displayService() else { return }
        let status = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, clamped)
        IOObjectRelease(service)
        if status != kIOReturnSuccess {
            NSLog("⚠️ Failed to set brightness via IODisplay: \(status)")
        }
    }

    private func emitBrightnessChange(value: Float, force: Bool = false) {
        let clamped = max(0, min(1, value))
        lastEmittedBrightness = clamped

        if !force {
            let now = Date()
            guard now.timeIntervalSince(lastEmissionDate) >= minimumEmissionInterval else { return }
            lastEmissionDate = now
        }

        let dispatchBlock = { [weak self] in
            guard let self else { return }
            self.onBrightnessChange?(clamped)
            self.notificationCenter.post(name: .systemBrightnessDidChange, object: nil, userInfo: ["value": clamped])
        }
        if Thread.isMainThread {
            dispatchBlock()
        } else {
            DispatchQueue.main.async(execute: dispatchBlock)
        }
    }

    private func displayService() -> io_service_t? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        let service = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        return service
    }

    private func setBrightnessViaDisplayServices(_ value: Float) -> Bool {
        if displayID == 0 { displayID = CGMainDisplayID() }
        guard let status = DisplayServicesDynamic.shared.setBrightness(displayID: displayID, value: value) else {
            return false
        }
        if status == kIOReturnSuccess {
            return true
        }
        displayID = CGMainDisplayID()
        guard let retry = DisplayServicesDynamic.shared.setBrightness(displayID: displayID, value: value) else {
            NSLog("⚠️ DisplayServicesSetBrightness unavailable after display refresh")
            return false
        }
        if retry != kIOReturnSuccess {
            NSLog("⚠️ DisplayServicesSetBrightness failed: \(retry)")
            return false
        }
        return true
    }

    private func getBrightnessViaDisplayServices() -> Float? {
        if displayID == 0 { displayID = CGMainDisplayID() }
        guard let result = DisplayServicesDynamic.shared.getBrightness(displayID: displayID) else {
            return nil
        }
        if result.status == kIOReturnSuccess {
            return result.value
        }
        displayID = CGMainDisplayID()
        guard let retry = DisplayServicesDynamic.shared.getBrightness(displayID: displayID) else {
            NSLog("⚠️ DisplayServicesGetBrightness unavailable after display refresh")
            return nil
        }
        if retry.status == kIOReturnSuccess {
            return retry.value
        }
        NSLog("⚠️ DisplayServicesGetBrightness failed: \(retry.status)")
        return nil
    }

    private func registerExternalNotifications() {
        guard !notificationsInstalled else { return }
        let names = [
            Notification.Name("com.apple.BezelEngine.BrightnessChanged"),
            Notification.Name("com.apple.BezelServices.BrightnessChanged"),
            Notification.Name("com.apple.controlcenter.display.brightness"),
            Notification.Name("com.apple.CoreBrightness.DisplayBrightnessChanged")
        ]
        observers = names.map { name in
            DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let system = self.currentBrightness
                if self.userInitiatedBrightnessChange {
                    self.notifyCurrentBrightness()
                } else {
                    self.lastEmittedBrightness = max(0, min(1, system))
                }
            }
        }

        let screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.displayID = CGMainDisplayID()
        }
        observers.append(screenObserver)

        notificationsInstalled = true
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let system = self.currentBrightness
            let diff = abs(system - self.lastEmittedBrightness)
            guard diff >= self.pollChangeThreshold else { return }

            if self.userInitiatedBrightnessChange {
                self.emitBrightnessChange(value: system, force: true)
            } else if diff >= 0.03 {
                // Significant external brightness change (Control Center, Touch Bar, external key)
                self.emitBrightnessChange(value: system, force: true)
            } else {
                // Subtle auto-brightness change — update baseline silently
                self.lastEmittedBrightness = max(0, min(1, system))
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        userInitiatedResetTimer?.invalidate()
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            notificationCenter.removeObserver($0)
        }
    }
}
