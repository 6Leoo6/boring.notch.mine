//
//  SharingStateManager.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-10.
//

import AppKit
import Combine
import Foundation

extension Notification.Name {
	static let sharingDidFinish = Notification.Name("com.boringNotch.sharingDidFinish")
}

@MainActor
final class SharingStateManager: ObservableObject {
	static let shared = SharingStateManager()

	private var activeSessions: Int = 0 {
		didSet {
			let newValue = activeSessions > 0
			if newValue != preventNotchClose {
				preventNotchClose = newValue
				if newValue {
					startWatchdog()
				} else {
					watchdog?.cancel()
					watchdog = nil
					NotificationCenter.default.post(name: .sharingDidFinish, object: nil)
				}
			}
		}
	}

	/// Ceiling on how long the guard may be held.
	///
	/// The guard exists so the notch cannot collapse out from under a share sheet, and every
	/// path that raises it is supposed to lower it again. When one does not, `close()` returns
	/// early for the rest of the launch and the window is stuck open with no way back except
	/// quitting the app — a far worse outcome than a sheet losing its guard. Two minutes is
	/// long enough that a user still choosing a service is never cut short.
	private static let maxGuardDuration: Duration = .seconds(120)
	private var watchdog: Task<Void, Never>?

	private func startWatchdog() {
		watchdog?.cancel()
		watchdog = Task { @MainActor [weak self] in
			try? await Task.sleep(for: Self.maxGuardDuration)
			guard let self, !Task.isCancelled, self.preventNotchClose else { return }
			self.activeDelegates.removeAll()
			self.activeSessions = 0
		}
	}

	@Published var preventNotchClose: Bool = false

	private var activeDelegates: [UUID: SharingLifecycleDelegate] = [:]

	private init() {}
	
	func requestCloseIfReady() {
		if !preventNotchClose {
			NotificationCenter.default.post(name: .sharingDidFinish, object: nil)
		}
	}

	func beginInteraction() {
		activeSessions += 1
	}

	func endInteraction() {
		if activeSessions > 0 { activeSessions -= 1 }
	}

	func makeDelegate(onEnd: (() -> Void)? = nil) -> SharingLifecycleDelegate {
		let id = UUID()
		let delegate = SharingLifecycleDelegate(id: id, onEnd: { [weak self] in
			onEnd?()
			self?.unregisterDelegate(id: id)
		}, onBegin: { [weak self] in
			self?.beginInteraction()
		}, onFinish: { [weak self] in
			self?.endInteraction()
		})
		activeDelegates[id] = delegate
		return delegate
	}

	private func unregisterDelegate(id: UUID) {
		activeDelegates.removeValue(forKey: id)
	}
}

final class SharingLifecycleDelegate: NSObject, NSSharingServiceDelegate, NSSharingServicePickerDelegate {
	let id: UUID
	private let onEnd: () -> Void
	private let onBegin: () -> Void
	private let onFinish: () -> Void

	private var pickerActive = false
	private var serviceInProgress = false
	private var finished = false
	/// How many times this delegate raised the guard. `onBegin` can fire more than once for a
	/// single share, and the release path used to lower the count exactly once.
	private var outstandingBegins = 0
	private var timeoutTask: Task<Void, Never>?

	init(id: UUID, onEnd: @escaping () -> Void, onBegin: @escaping () -> Void, onFinish: @escaping () -> Void) {
		self.id = id
		self.onEnd = onEnd
		self.onBegin = onBegin
		self.onFinish = onFinish
	}
	
	deinit {
		timeoutTask?.cancel()
	}

	private func begin() {
		outstandingBegins += 1
		onBegin()
	}

	func markPickerBegan() {
		guard !pickerActive else { return }
		pickerActive = true
		begin()
		// The picker path had NO fallback: its only release was `didChoose`, so a picker that
		// was dismissed without reporting one — or never shown at all — held the guard for the
		// rest of the launch.
		startTimeoutFallback(seconds: 120)
	}

	func markServiceBegan() {
		guard !serviceInProgress else { return }
		serviceInProgress = true
		begin()
		startTimeoutFallback(seconds: 2)
	}

	/// The interaction never actually started, so drop the delegate without having raised the
	/// guard at all — used when there is no view to anchor a picker to.
	func abandon() {
		guard !finished else { return }
		finished = true
		timeoutTask?.cancel()
		onEnd()
	}

	private func startTimeoutFallback(seconds: Int) {
		timeoutTask?.cancel()
		timeoutTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(seconds))
			guard let self = self, !Task.isCancelled else { return }
			if !self.finished {
				self.finishIfNeeded()
			}
		}
	}

	private func finishIfNeeded() {
		guard !finished else { return }
		finished = true
		timeoutTask?.cancel()
		// Release EVERY begin this delegate issued rather than one of them. A share that
		// raised the guard twice (picker, then service) left the count permanently above
		// zero, which pins `preventNotchClose` true and stops the notch ever closing again.
		let outstanding = outstandingBegins
		outstandingBegins = 0
		for _ in 0 ..< outstanding { onFinish() }
		onEnd()
	}

	// MARK: - NSSharingServicePickerDelegate

	func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
		if service == nil {
			if pickerActive && !serviceInProgress {
				finishIfNeeded()
			}
			return
		}

		service?.delegate = self
		serviceInProgress = true
		startTimeoutFallback(seconds: 2)
	}

	// MARK: - NSSharingServiceDelegate

	func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
		if !pickerActive && !serviceInProgress {
			begin()
		}
		serviceInProgress = true
	}

	func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
		finishIfNeeded()
	}

	func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
		finishIfNeeded()
	}
}

