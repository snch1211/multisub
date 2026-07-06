//
//  ConfigStore.swift
//  MultiSub
//
//  UI-side single source of truth for config.json (style guide v2 §6).
//  Wraps MultiSubConfig.load()/save() — "change immediately persists",
//  same semantics as v1's ViewController. Feature views (G2/G3) mutate
//  `config` directly and call `save()`.
//

import Foundation

@Observable
@MainActor
final class ConfigStore {
    var config: MultiSubConfig = MultiSubConfig.load()

    func save() {
        config.save()
    }
}
