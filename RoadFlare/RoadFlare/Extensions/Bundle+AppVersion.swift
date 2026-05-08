import Foundation

extension Bundle {
    var appVersionLabel: String {
        let marketing = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "Version \(marketing)"
    }
}
