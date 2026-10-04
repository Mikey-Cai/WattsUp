import Foundation

/// How strongly the memory card is washed with the pressure colour. Normal and
/// unknown pressure never tint: the wash is a reminder, not decoration.
public enum PressureTint: String, Equatable, Sendable {
    case none
    case warning
    case critical

    public init(level: MemoryPressureLevel) {
        switch level {
        case .warning: self = .warning
        case .critical: self = .critical
        case .normal, .unknown: self = .none
        }
    }

    public var isTinted: Bool { self != .none }

    /// Opacity of the system yellow/red wash at the card's leading edge. Dark
    /// glass needs a little more colour to read; light glass less so the text
    /// stays crisp. Both stay well under a "filled" look.
    public func backgroundOpacity(darkMode: Bool) -> Double {
        switch self {
        case .none: return 0
        case .warning: return darkMode ? 0.16 : 0.15
        case .critical: return darkMode ? 0.18 : 0.12
        }
    }

    /// The wash fades towards the trailing edge to keep it soft.
    public func trailingOpacity(darkMode: Bool) -> Double { backgroundOpacity(darkMode: darkMode) * 0.45 }

    public func borderOpacity(darkMode: Bool) -> Double {
        switch self {
        case .none: return 0
        case .warning: return darkMode ? 0.30 : 0.38
        case .critical: return darkMode ? 0.32 : 0.34
        }
    }
}
