import Foundation

enum DynamicPathMode: String, Codable, CaseIterable, Identifiable {
    case bezier
    case sinusoidal

    var id: String { rawValue }
    var title: String { self == .bezier ? "Bezier" : "Sin" }
    var xmlName: String { self == .bezier ? "Bezier" : "Sin" }
    var summary: String {
        self == .bezier
            ? "Direct movement between timeline poses. Vector 2's default."
            : "Uses a sine section to control acceleration and direction."
    }
}

enum DynamicSinQuarter: String, Codable, CaseIterable, Identifiable {
    case oneQuarterAcc
    case oneQuarterDec
    case twoQuarters
    case twoQuartersFastSlowFast
    case threeQuarters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneQuarterAcc: return "Ease In"
        case .oneQuarterDec: return "Ease Out"
        case .twoQuarters: return "Ease In-Out"
        case .twoQuartersFastSlowFast: return "Fast-Slow-Fast"
        case .threeQuarters: return "Backtrack then Finish"
        }
    }

    var xmlName: String {
        switch self {
        case .oneQuarterAcc: return "1QuarterAcc"
        case .oneQuarterDec: return "1QuarterDec"
        case .twoQuarters: return "2Quarters"
        case .twoQuartersFastSlowFast: return "2QuartersFastSlowFast"
        case .threeQuarters: return "3Quarters"
        }
    }

    var summary: String {
        switch self {
        case .oneQuarterAcc: return "Starts slowly and accelerates."
        case .oneQuarterDec: return "Starts quickly and settles gently."
        case .twoQuarters: return "Starts and ends gently. Best natural default."
        case .twoQuartersFastSlowFast: return "Fast at both ends and slower in the middle."
        case .threeQuarters: return "Moves backward first, then travels forward to the destination."
        }
    }

    static func fromXML(_ value: String?) -> DynamicSinQuarter {
        allCases.first { $0.xmlName == value } ?? .twoQuarters
    }
}

enum DynamicRotationMode: String, Codable, CaseIterable, Identifiable {
    case linear
    case easeIn
    case easeOut
    case sinOneQuarterAcc
    case sinOneQuarterDec
    case sinTwoQuarters
    case sinTwoQuartersFastSlowFast
    case sinThreeQuarters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Cubic Ease In"
        case .easeOut: return "Cubic Ease Out"
        case .sinOneQuarterAcc: return "Smooth Ease In"
        case .sinOneQuarterDec: return "Smooth Ease Out"
        case .sinTwoQuarters: return "Smooth Ease In-Out"
        case .sinTwoQuartersFastSlowFast: return "Fast-Slow-Fast"
        case .sinThreeQuarters: return "Backtrack then Finish"
        }
    }

    var xmlName: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "EaseIn"
        case .easeOut: return "EaseOut"
        case .sinOneQuarterAcc: return "Sin_1QuarterAcc"
        case .sinOneQuarterDec: return "Sin_1QuarterDec"
        case .sinTwoQuarters: return "Sin_2Quarters"
        case .sinTwoQuartersFastSlowFast: return "Sin_2QuartersFastSlowFast"
        case .sinThreeQuarters: return "Sin_3Quarters"
        }
    }

    var summary: String {
        switch self {
        case .linear: return "Rotates at one constant speed."
        case .easeIn: return "Starts very slowly, then accelerates sharply."
        case .easeOut: return "Starts quickly, then slows sharply."
        case .sinOneQuarterAcc: return "A gentler accelerating rotation."
        case .sinOneQuarterDec: return "A gentler settling rotation."
        case .sinTwoQuarters: return "Smooth at both ends. Best natural default."
        case .sinTwoQuartersFastSlowFast: return "Fast at both ends, slow in the middle."
        case .sinThreeQuarters: return "Rotates backward first, then reaches the requested angle."
        }
    }

    static func fromXML(_ value: String?) -> DynamicRotationMode {
        allCases.first { $0.xmlName == value } ?? .linear
    }
}

enum DynamicStudioEasing {
    static func pathProgress(_ t: Double, mode: DynamicPathMode, quarter: DynamicSinQuarter) -> Double {
        guard mode == .sinusoidal else { return t }
        return sinProgress(t, quarter: quarter)
    }

    static func rotationProgress(_ t: Double, mode: DynamicRotationMode) -> Double {
        switch mode {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut:
            let shifted = t - 1
            return shifted * shifted * shifted + 1
        case .sinOneQuarterAcc: return sinProgress(t, quarter: .oneQuarterAcc)
        case .sinOneQuarterDec: return sinProgress(t, quarter: .oneQuarterDec)
        case .sinTwoQuarters: return sinProgress(t, quarter: .twoQuarters)
        case .sinTwoQuartersFastSlowFast: return sinProgress(t, quarter: .twoQuartersFastSlowFast)
        case .sinThreeQuarters: return sinProgress(t, quarter: .threeQuarters)
        }
    }

    private static func sinProgress(_ t: Double, quarter: DynamicSinQuarter) -> Double {
        let clamped = min(max(t, 0), 1)
        switch quarter {
        case .oneQuarterAcc:
            return 1 - cos(clamped * .pi / 2)
        case .oneQuarterDec:
            return sin(clamped * .pi / 2)
        case .twoQuarters:
            return (1 - cos(clamped * .pi)) / 2
        case .twoQuartersFastSlowFast:
            if clamped < 0.5 {
                return 0.5 * sin(clamped * .pi)
            }
            return 0.5 + 0.5 * (1 - cos((clamped - 0.5) * .pi))
        case .threeQuarters:
            if clamped < 1.0 / 3.0 {
                return -sin(clamped * 3 * .pi / 2)
            }
            if clamped < 2.0 / 3.0 {
                return -1 + (1 - cos((clamped - 1.0 / 3.0) * 3 * .pi / 2))
            }
            return sin((clamped - 2.0 / 3.0) * 3 * .pi / 2)
        }
    }
}
