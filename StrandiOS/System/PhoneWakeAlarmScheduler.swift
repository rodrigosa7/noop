import AlarmKit
import Combine
import Foundation
import StrandDesign
import SwiftUI

/// The iPhone's audible wake alarm. The strap alarm and wind-down reminder have separate switches;
/// this one uses their shared wake schedule but owns its own opt-in state.
///
/// AlarmKit is available on iOS 26 and later. The system owns the scheduled alarms after NOOP exits,
/// so no Bluetooth connection or app process is needed for the chosen wake time to alert.
@MainActor
final class PhoneWakeAlarmScheduler: ObservableObject {
    static let shared = PhoneWakeAlarmScheduler()

    struct Schedule {
        let baseMinutes: Int
        let weekdays: Set<Int>
        let overrides: [Int: Int]

        /// Empty weekdays means every day, matching the strap alarm's persisted convention.
        var rows: [(weekday: Int, minutes: Int)] {
            let days = weekdays.isEmpty ? Set(1...7) : weekdays.filter { (1...7).contains($0) }
            return days.sorted().map { day in
                let minute = overrides[day].flatMap { (0..<1440).contains($0) ? $0 : nil }
                    ?? min(max(baseMinutes, 0), 1439)
                return (day, minute)
            }
        }

        var fingerprint: String {
            rows.map { "\($0.weekday):\($0.minutes)" }.joined(separator: ",")
        }
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var hasError = false
    /// Lets the strap backup notification follow the final AlarmKit state after an asynchronous edit.
    var onScheduleChanged: (() -> Void)?

    private enum Key {
        static let enabled = "alarm.phoneWakeEnabled"
        static let bank = "alarm.phoneWakeBank"
        static let fingerprint = "alarm.phoneWakeSchedule"
    }

    private let defaults = UserDefaults.standard
    private var operation: Task<Void, Never>?
    private var revision = 0
    private var latestSchedule: Schedule?
    private var desiredEnabled: Bool
    private var requestAuthorizationOnNextEnable = false

    private init() {
        let enabled = UserDefaults.standard.bool(forKey: Key.enabled)
        isEnabled = enabled
        desiredEnabled = enabled
    }

    /// Serialize edits so quick picker changes cannot leave an older schedule as the final one.
    /// Authorization is requested only for a user-initiated switch-on, never on app launch.
    func setEnabled(_ enabled: Bool, schedule: Schedule) {
        desiredEnabled = enabled
        requestAuthorizationOnNextEnable = enabled
        enqueue(enabled: enabled, schedule: schedule, requestAuthorization: enabled)
    }

    func reconcile(schedule: Schedule) {
        guard desiredEnabled else { return }
        enqueue(enabled: true, schedule: schedule,
                requestAuthorization: requestAuthorizationOnNextEnable)
    }

    private func enqueue(enabled: Bool, schedule: Schedule, requestAuthorization: Bool) {
        revision += 1
        let token = revision
        latestSchedule = schedule
        let preceding = operation
        isBusy = true
        operation = Task { @MainActor [weak self] in
            await preceding?.value
            guard let self else { return }
            guard token == self.revision else { return }
            await self.apply(enabled: enabled, schedule: self.latestSchedule ?? schedule,
                             requestAuthorization: requestAuthorization)
            if token == self.revision {
                self.isBusy = false
                self.requestAuthorizationOnNextEnable = false
                self.onScheduleChanged?()
            }
        }
    }

    @available(iOS 26.0, *)
    func hasCurrentAlarm(for schedule: Schedule) -> Bool {
        guard isEnabled, !hasError,
              AlarmManager.shared.authorizationState == .authorized,
              defaults.string(forKey: Key.fingerprint) == schedule.fingerprint,
              let installed = try? Set(AlarmManager.shared.alarms.map(\.id)) else { return false }
        let bank = defaults.integer(forKey: Key.bank)
        return schedule.rows.allSatisfy {
            installed.contains(Self.alarmID(bank: bank, weekday: $0.weekday))
        }
    }

    private func apply(enabled: Bool, schedule: Schedule, requestAuthorization: Bool) async {
        guard #available(iOS 26.0, *) else { return }
        let manager = AlarmManager.shared
        let activeBank = defaults.integer(forKey: Key.bank)

        guard enabled else {
            let firstCancelled = cancelBank(0, using: manager)
            let secondCancelled = cancelBank(1, using: manager)
            guard firstCancelled && secondCancelled else {
                hasError = true
                return
            }
            defaults.removeObject(forKey: Key.bank)
            defaults.removeObject(forKey: Key.fingerprint)
            defaults.set(false, forKey: Key.enabled)
            isEnabled = false
            hasError = false
            return
        }

        let authorized: Bool
        if manager.authorizationState == .authorized {
            authorized = true
        } else if requestAuthorization {
            authorized = (try? await manager.requestAuthorization()) == .authorized
        } else {
            authorized = false
        }
        guard authorized, !schedule.rows.isEmpty else {
            // Keep a previously armed schedule if a later edit could not be applied.
            hasError = true
            return
        }

        guard let installed = try? Set(manager.alarms.map(\.id)) else {
            hasError = true
            return
        }
        let activeIDs = schedule.rows.map { Self.alarmID(bank: activeBank, weekday: $0.weekday) }
        if defaults.string(forKey: Key.fingerprint) == schedule.fingerprint,
           activeIDs.allSatisfy(installed.contains) {
            hasError = !cancelBank(1 - activeBank, using: manager)
            return
        }

        // Two deterministic banks let us schedule replacements before cancelling the old wake. If the
        // process dies midway, the next reconciliation removes the inactive bank's partial alarms.
        let replacementBank = 1 - activeBank
        guard cancelBank(replacementBank, using: manager) else {
            hasError = true
            return
        }
        var newIDs: [UUID] = []
        do {
            for row in schedule.rows {
                let id = Self.alarmID(bank: replacementBank, weekday: row.weekday)
                let time = Alarm.Schedule.Relative.Time(hour: row.minutes / 60,
                                                        minute: row.minutes % 60)
                let repeatDay = Self.localeWeekday(row.weekday)
                let alarmSchedule = Alarm.Schedule.relative(
                    .init(time: time, repeats: .weekly([repeatDay])))
                let presentation = AlarmPresentation(alert: .init(
                    title: "Time to wake up",
                    stopButton: AlarmButton(text: "Stop", textColor: .white,
                                            systemImageName: "stop.circle")))
                let attributes = AlarmAttributes<WakeMetadata>(presentation: presentation,
                                                                 tintColor: StrandPalette.accent)
                let configuration = AlarmManager.AlarmConfiguration.alarm(
                    schedule: alarmSchedule, attributes: attributes)
                _ = try await manager.schedule(id: id, configuration: configuration)
                newIDs.append(id)
            }
        } catch {
            for id in newIDs { try? manager.cancel(id: id) }
            hasError = true
            return
        }

        defaults.set(replacementBank, forKey: Key.bank)
        defaults.set(schedule.fingerprint, forKey: Key.fingerprint)
        defaults.set(true, forKey: Key.enabled)
        isEnabled = true
        hasError = false
        hasError = !cancelBank(activeBank, using: manager)
    }

    @available(iOS 26.0, *)
    private func cancelBank(_ bank: Int, using manager: AlarmManager) -> Bool {
        guard let installed = try? Set(manager.alarms.map(\.id)) else { return false }
        var succeeded = true
        for day in 1...7 {
            let id = Self.alarmID(bank: bank, weekday: day)
            guard installed.contains(id) else { continue }
            do { try manager.cancel(id: id) } catch { succeeded = false }
        }
        return succeeded
    }

    private static func alarmID(bank: Int, weekday: Int) -> UUID {
        UUID(uuidString: String(format: "A116A7A0-2600-4000-8000-%012d", bank * 10 + weekday))!
    }

    @available(iOS 26.0, *)
    private static func localeWeekday(_ calendarWeekday: Int) -> Locale.Weekday {
        switch calendarWeekday {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        default: .saturday
        }
    }
}

private struct WakeMetadata: AlarmMetadata {}
