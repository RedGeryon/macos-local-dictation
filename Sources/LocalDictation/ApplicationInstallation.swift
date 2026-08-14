import Foundation

enum ApplicationInstallation {
    static let applicationName = "Local Dictation.app"

    static var destinationURL: URL {
        URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(applicationName, isDirectory: true)
    }

    static func isInApplications(
        _ applicationURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = applicationURL.standardizedFileURL.path
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true).path + "/"
        let userApplications = homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path + "/"
        return path.hasPrefix(systemApplications) || path.hasPrefix(userApplications)
    }
}
