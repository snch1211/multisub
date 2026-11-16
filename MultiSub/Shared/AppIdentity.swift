//
//  AppIdentity.swift
//  MultiSub
//
//  Who this process is, worked out at run time from our own bundle and code
//  signature. Shared between the host app and the Safari extension.
//
//  Nothing here is hardcoded on purpose: the bundle ID and Team ID come from
//  MultiSub.xcconfig / Local.xcconfig at build time, so a fresh clone signed
//  by any team gets matching values in both processes without touching the
//  source.
//

import Foundation
import Security

enum AppIdentity {
    private static let extensionSuffix = ".Extension"

    /// True inside the Safari extension (`MultiSub Extension.appex`).
    static let isExtension: Bool = Bundle.main.bundleURL.pathExtension == "appex"

    /// Bundle ID of the host app. The extension's own ID is the app's ID plus
    /// ".Extension" (see MultiSub.xcconfig), so inside the appex we strip it.
    static let appBundleID: String = {
        let own = Bundle.main.bundleIdentifier ?? "MultiSub"
        guard own.hasSuffix(extensionSuffix) else { return own }
        return String(own.dropLast(extensionSuffix.count))
    }()

    static var extensionBundleID: String { appBundleID + extensionSuffix }

    /// The shared App Group uses a Team-ID-prefixed name. macOS authorizes it
    /// purely by code-signature verification (any App ID signed by the same
    /// team gets it automatically), unlike the old portal-registered `group.*`
    /// name, which requires the App Group capability to be attached to *every*
    /// App ID's provisioning profile individually — on a free Personal Team
    /// that attachment silently failed for the Safari extension's App ID, which
    /// is what caused the recurring "「MultiSub」想要取用其他 App 的資料" TCC
    /// prompt.
    ///
    /// Read from our own signed entitlement rather than hardcoded, so the
    /// source carries no literal Team ID. The app and the extension are signed
    /// with the same team, so both derive the identical string and the shared
    /// container path stays stable. Nil only if the entitlement is somehow
    /// unreadable, in which case `MultiSubPaths.sharedRoot` falls back to
    /// Application Support.
    static let appGroupID: String? = {
        guard let groups = entitlement("com.apple.security.application-groups") as? [String] else { return nil }
        return groups.first { !$0.hasPrefix("group.") }
    }()

    /// The keychain access group both processes share for the user's API keys
    /// (`$(AppIdentifierPrefix)$(MULTISUB_BUNDLE_ID).shared` in the
    /// entitlements). Read from the signature for the same reason as
    /// `appGroupID`. Nil when the entitlement is missing (unusual dev
    /// signing); `SecretStore` then lets the keychain pick its default group.
    static let keychainAccessGroup: String? = {
        guard let groups = entitlement("keychain-access-groups") as? [String], !groups.isEmpty else { return nil }
        return groups.first { $0.hasSuffix(".shared") } ?? groups.first
    }()

    private static func entitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }
}
