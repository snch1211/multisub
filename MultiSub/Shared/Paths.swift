//
//  Paths.swift
//  MultiSub
//
//  Where shared files live. Shared between the host app and the Safari
//  extension.
//

import Foundation

enum MultiSubPaths {
    /// See `AppIdentity.appGroupID` for why the group name is derived from
    /// our signature instead of written down.
    static var appGroupID: String? { AppIdentity.appGroupID }

    /// Both targets are sandboxed, so the model and config live in the shared
    /// App Group container, visible to the app and the Safari extension alike.
    static var sharedRoot: URL {
        let fm = FileManager.default
        let base: URL
        if let groupID = appGroupID,
           let group = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            base = group.appendingPathComponent("MultiSub", isDirectory: true)
        } else {
            base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MultiSub", isDirectory: true)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var modelsRoot: URL { sharedRoot.appendingPathComponent("models", isDirectory: true) }
    static var configFile: URL { sharedRoot.appendingPathComponent("config.json") }
}
