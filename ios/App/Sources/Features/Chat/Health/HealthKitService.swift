import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// Read-only Apple Health snapshot for chat context.
///
/// When Health is enabled in Add to Chat, a fresh snapshot is formatted into
/// a system prompt so the model can answer questions about the user's stats
/// without inventing numbers that aren't present.
@MainActor
final class HealthKitService: ObservableObject {
    enum AuthorizationState: Equatable {
        case unknown
        case unavailable
        case notDetermined
        case denied
        case authorized
    }

    @Published private(set) var authorizationState: AuthorizationState = .unknown
    @Published private(set) var lastError: String?

    #if canImport(HealthKit)
    private let store = HKHealthStore()
    #endif

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    // MARK: - Availability / auth

    var isHealthDataAvailable: Bool {
        #if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    /// Refresh local auth state from HealthKit (does not prompt).
    func refreshAuthorizationState() {
        #if canImport(HealthKit)
        guard isHealthDataAvailable else {
            authorizationState = .unavailable
            return
        }
        // HealthKit doesn't expose a single "all authorized" flag for read
        // types. We treat any readable core type with sharingDenied as denied
        // only when the user has explicitly refused; otherwise notDetermined
        // until we successfully request.
        let sample = Self.readTypes.first
        if let sample {
            let status = store.authorizationStatus(for: sample)
            switch status {
            case .sharingDenied:
                // Note: for *read* access, status is often `.notDetermined`
                // even after grant (Apple privacy). `.sharingDenied` is
                // reliable only for share types. Keep notDetermined/authorized
                // based on whether we've completed a request in this process.
                break
            default:
                break
            }
        }
        if authorizationState == .unknown {
            authorizationState = .notDetermined
        }
        #else
        authorizationState = .unavailable
        #endif
    }

    /// Prompt the system HealthKit sheet for the types we need to read.
    func requestAuthorization() async throws {
        #if canImport(HealthKit)
        guard isHealthDataAvailable else {
            authorizationState = .unavailable
            throw HealthKitServiceError.unavailable
        }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            // Read status is intentionally opaque; treat a successful request
            // as authorized so we attempt queries. Queries return empty when
            // the user denied individual types.
            authorizationState = .authorized
            lastError = nil
        } catch {
            authorizationState = .denied
            lastError = error.localizedDescription
            throw error
        }
        #else
        authorizationState = .unavailable
        throw HealthKitServiceError.unavailable
        #endif
    }

    // MARK: - Snapshot

    /// Build a prompt-ready health summary for the model.
    func snapshotForPrompt() async throws -> String {
        #if canImport(HealthKit)
        guard isHealthDataAvailable else {
            throw HealthKitServiceError.unavailable
        }
        if authorizationState != .authorized {
            try await requestAuthorization()
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOf7d = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let startOf14d = calendar.date(byAdding: .day, value: -14, to: startOfToday) ?? startOfToday

        async let stepsToday = sum(.stepCount, unit: .count(), from: startOfToday, to: now)
        async let steps7d = sum(.stepCount, unit: .count(), from: startOf7d, to: now)
        async let activeEnergyToday = sum(.activeEnergyBurned, unit: .kilocalorie(), from: startOfToday, to: now)
        async let activeEnergy7d = sum(.activeEnergyBurned, unit: .kilocalorie(), from: startOf7d, to: now)
        async let exerciseToday = sum(.appleExerciseTime, unit: .minute(), from: startOfToday, to: now)
        async let exercise7d = sum(.appleExerciseTime, unit: .minute(), from: startOf7d, to: now)
        async let distanceToday = sum(.distanceWalkingRunning, unit: .mile(), from: startOfToday, to: now)
        async let restingHR = latest(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let latestHR = latest(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let hrv = latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))
        async let spo2 = latest(.oxygenSaturation, unit: .percent())
        async let weight = latest(.bodyMass, unit: .pound())
        async let height = latest(.height, unit: .inch())
        async let sleep = sleepSummary(from: startOf14d, to: now)
        async let workouts = recentWorkouts(from: startOf7d, to: now)

        let sToday = await stepsToday
        let s7 = await steps7d
        let aeToday = await activeEnergyToday
        let ae7 = await activeEnergy7d
        let exToday = await exerciseToday
        let ex7 = await exercise7d
        let distToday = await distanceToday
        let rhr = await restingHR
        let hr = await latestHR
        let hrvVal = await hrv
        let spo2Val = await spo2
        let weightVal = await weight
        let heightVal = await height
        let sleepLines = await sleep
        let workoutLines = await workouts

        var lines: [String] = []
        lines.append("## Apple Health snapshot (read-only)")
        lines.append("Captured at: \(Self.iso.string(from: now))")
        lines.append("Privacy: This is the user's personal health data, shared only for this conversation. Answer using these numbers; do not invent measurements that are not listed. If a metric is missing, say it is unavailable. Prefer clear units and ranges. You are not a doctor — suggest professional care for medical concerns.")
        lines.append("")
        lines.append("### Activity")
        lines.append(metricLine("Steps today", sToday.map { formatInt($0) }))
        if let s7 {
            let avg = s7 / 7.0
            lines.append("- Steps (last 7 days total): \(formatInt(s7)) · ~\(formatInt(avg))/day average")
        } else {
            lines.append("- Steps (last 7 days): unavailable")
        }
        lines.append(metricLine("Active energy today", aeToday.map { "\(formatInt($0)) kcal" }))
        if let ae7 {
            lines.append("- Active energy (7-day total): \(formatInt(ae7)) kcal · ~\(formatInt(ae7 / 7.0)) kcal/day")
        }
        lines.append(metricLine("Exercise minutes today", exToday.map { "\(formatInt($0)) min" }))
        if let ex7 {
            lines.append("- Exercise minutes (7-day total): \(formatInt(ex7)) min")
        }
        lines.append(metricLine("Walking + running distance today", distToday.map { String(format: "%.2f mi", $0) }))
        lines.append("")
        lines.append("### Heart & vitals")
        lines.append(metricLine("Resting heart rate (latest)", rhr.map { "\(formatInt($0)) bpm" }))
        lines.append(metricLine("Heart rate (latest sample)", hr.map { "\(formatInt($0)) bpm" }))
        lines.append(metricLine("HRV SDNN (latest)", hrvVal.map { String(format: "%.0f ms", $0) }))
        if let spo2Val {
            lines.append("- Blood oxygen (latest): \(String(format: "%.1f%%", spo2Val * 100))")
        } else {
            lines.append("- Blood oxygen (latest): unavailable")
        }
        lines.append("")
        lines.append("### Body")
        lines.append(metricLine("Weight (latest)", weightVal.map { String(format: "%.1f lb", $0) }))
        lines.append(metricLine("Height (latest)", heightVal.map { String(format: "%.1f in", $0) }))
        lines.append("")
        lines.append("### Sleep")
        if sleepLines.isEmpty {
            lines.append("- No sleep samples in the last 14 days (or access denied).")
        } else {
            lines.append(contentsOf: sleepLines)
        }
        lines.append("")
        lines.append("### Workouts (last 7 days)")
        if workoutLines.isEmpty {
            lines.append("- No workouts recorded (or access denied).")
        } else {
            lines.append(contentsOf: workoutLines)
        }

        return lines.joined(separator: "\n")
        #else
        throw HealthKitServiceError.unavailable
        #endif
    }

    // MARK: - Queries

    #if canImport(HealthKit)
    private static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .distanceWalkingRunning,
            .appleExerciseTime,
            .heartRate,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .oxygenSaturation,
            .bodyMass,
            .height,
        ]
        for id in quantities {
            if let t = HKObjectType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        types.insert(HKObjectType.workoutType())
        return types
    }

    private func sum(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samplePredicate = HKSamplePredicate.quantitySample(type: type, predicate: predicate)
        // Cumulative types (steps, energy) use sum; discrete averages fall back below.
        let options: HKStatisticsOptions = type.aggregationStyle == .cumulative ? .cumulativeSum : .discreteAverage
        let descriptor = HKStatisticsQueryDescriptor(predicate: samplePredicate, options: options)
        do {
            let stats = try await descriptor.result(for: store)
            if options.contains(.cumulativeSum) {
                return stats?.sumQuantity()?.doubleValue(for: unit)
            }
            return stats?.averageQuantity()?.doubleValue(for: unit)
        } catch {
            return nil
        }
    }

    private func latest(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 1
        )
        do {
            let samples = try await descriptor.result(for: store)
            return samples.first?.quantity.doubleValue(for: unit)
        } catch {
            return nil
        }
    }

    private func sleepSummary(from start: Date, to end: Date) async -> [String] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 80
        )
        do {
            let samples = try await descriptor.result(for: store)
            guard !samples.isEmpty else { return [] }

            // Group by calendar night (end date's startOfDay).
            let calendar = Calendar.current
            var byNight: [Date: TimeInterval] = [:]
            for sample in samples {
                // Prefer asleep stages (iOS 16+ split of the old `.asleep` value).
                // inBed is handled only as a fallback when no asleep stages exist.
                let value = sample.value
                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                ]
                guard asleepValues.contains(value) else { continue }
                let night = calendar.startOfDay(for: sample.endDate)
                byNight[night, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
            }

            let nights = byNight.keys.sorted(by: >).prefix(7)
            if nights.isEmpty {
                // Fall back: total inBed if no asleep stages tagged.
                var inBed: [Date: TimeInterval] = [:]
                for sample in samples {
                    if sample.value == HKCategoryValueSleepAnalysis.inBed.rawValue {
                        let night = calendar.startOfDay(for: sample.endDate)
                        inBed[night, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
                    }
                }
                return inBed.keys.sorted(by: >).prefix(5).map { night in
                    let hours = (inBed[night] ?? 0) / 3600
                    return "- \(Self.dayFormatter.string(from: night)): \(String(format: "%.1f", hours)) h in bed"
                }
            }
            return nights.map { night in
                let hours = (byNight[night] ?? 0) / 3600
                return "- \(Self.dayFormatter.string(from: night)): \(String(format: "%.1f", hours)) h asleep"
            }
        } catch {
            return []
        }
    }

    private func recentWorkouts(from start: Date, to end: Date) async -> [String] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 12
        )
        do {
            let workouts = try await descriptor.result(for: store)
            return workouts.map { w in
                let mins = Int((w.duration / 60).rounded())
                let kcal = w.totalEnergyBurned?.doubleValue(for: .kilocalorie())
                let energy = kcal.map { " · \(formatInt($0)) kcal" } ?? ""
                let name = w.workoutActivityType.commonName
                let when = "\(Self.dayFormatter.string(from: w.startDate)) \(Self.timeFormatter.string(from: w.startDate))"
                return "- \(when): \(name), \(mins) min\(energy)"
            }
        } catch {
            return []
        }
    }
    #endif

    // MARK: - Formatting

    private func metricLine(_ label: String, _ value: String?) -> String {
        if let value {
            return "- \(label): \(value)"
        }
        return "- \(label): unavailable"
    }

    private func formatInt(_ value: Double) -> String {
        let n = Int(value.rounded())
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

enum HealthKitServiceError: LocalizedError {
    case unavailable
    case denied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Health is not available on this device."
        case .denied:
            return "Health access was denied. Enable it in Settings → Privacy → Health."
        }
    }
}

#if canImport(HealthKit)
private extension HKWorkoutActivityType {
    var commonName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .traditionalStrengthTraining: return "Strength"
        case .functionalStrengthTraining: return "Functional strength"
        case .yoga: return "Yoga"
        case .hiking: return "Hiking"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .mixedCardio: return "Mixed cardio"
        case .highIntensityIntervalTraining: return "HIIT"
        case .dance: return "Dance"
        case .cooldown: return "Cooldown"
        case .coreTraining: return "Core"
        case .flexibility: return "Flexibility"
        case .pilates: return "Pilates"
        case .stairClimbing: return "Stairs"
        case .other: return "Other"
        default: return "Workout"
        }
    }
}
#endif
