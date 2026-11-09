import Foundation

/// Preserve the user's open windows across a permission-cache restart.
enum PermissionRestart {
    static func arguments(settingsVisible: Bool, guide: PermissionGuide?) -> [String] {
        var result = ["--permission-restarted"]
        if settingsVisible { result.append("--show-settings") }
        if let guide {
            result += ["--permission-guide", guide == .input ? "input" : "accessibility"]
        }
        return result
    }

    static func guide(in arguments: [String]) -> PermissionGuide? {
        guard let index = arguments.firstIndex(of: "--permission-guide"), index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "input": return .input
        case "accessibility": return .accessibility
        default: return nil
        }
    }
}
