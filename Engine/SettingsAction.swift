import Foundation

/// Applies the brain's checked set_setting action. Keeping this beside the other action
/// handlers lets parallel work extend Desk's dispatch loop without moving its existing cases.
extension Desk {
    func applySetting(_ setting: Plan.Setting?) async -> String {
        guard let setting else { return "Couldn't change settings: the setting was missing." }
        if let agent = setting.agent, setting.model != nil || setting.effort != nil || setting.complexEffort != nil {
            let oldModel = AgentModels.value(agent, "model")
            let oldEffort = AgentModels.value(agent, "effort")
            let oldComplexEffort = AgentModels.value(agent, "complexEffort")
            if let model = setting.model { UserDefaults.standard.set(model, forKey: "\(agent).model") }
            if let effort = setting.effort { UserDefaults.standard.set(effort, forKey: "\(agent).effort") }
            if let effort = setting.complexEffort { UserDefaults.standard.set(effort, forKey: "\(agent).complexEffort") }
            _ = UserDefaults.standard.synchronize()
            let newModel = AgentModels.value(agent, "model")
            let newEffort = AgentModels.value(agent, "effort")
            let newComplexEffort = AgentModels.value(agent, "complexEffort")
            var changed = "\(AgentModels.name(oldModel)) · \(AgentModels.effortName(oldEffort)) to \(AgentModels.name(newModel)) · \(AgentModels.effortName(newEffort))"
            if setting.model != nil && setting.effort == nil && setting.complexEffort == nil { changed = "\(AgentModels.name(oldModel)) to \(AgentModels.name(newModel))" }
            if setting.model == nil && setting.effort != nil && setting.complexEffort == nil { changed = "\(AgentModels.effortName(oldEffort)) to \(AgentModels.effortName(newEffort))" }
            if setting.model == nil && setting.effort == nil && setting.complexEffort != nil {
                changed = "complex jobs from \(AgentModels.effortName(oldComplexEffort)) to \(AgentModels.effortName(newComplexEffort))"
            }
            return "Changed \(Job.agentNames[agent] ?? agent)'s \(changed)."
        }
        if let max = setting.maxRunning {
            let old = maxRunning
            JobSlots.save(max)
            maxRunning = max
            return "Changed jobs at once from \(old) to \(max)."
        }
        if let name = setting.account, let lift = setting.lift {
            if let state = accounts.accounts.first(where: {
                $0.account.id == name || $0.account.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                guard let changed = liftReserve(state.account.id, lift) else {
                    return "Couldn't change \(name)'s weekly reserve: that account is gone."
                }
                let old = state.reserveLiftedUntil() != nil
                return lift
                    ? "Lifted \(changed.account.name)'s weekly reserve (was \(old ? "lifted" : "in place"))."
                    : "Put \(changed.account.name)'s weekly reserve back (was \(old ? "lifted" : "in place"))."
            }
            guard let remote = elsewhere().flatMap(\.accounts).first(where: {
                $0.account.id == name || $0.account.name.caseInsensitiveCompare(name) == .orderedSame
            }), await liftElsewhereReserve(remote.account.id, lift) else {
                return "Couldn't change \(name)'s weekly reserve: that account is gone."
            }
            return lift ? "Lifted \(remote.account.name)'s weekly reserve." : "Put \(remote.account.name)'s weekly reserve back."
        }
        return "Couldn't change settings: the setting was incomplete."
    }
}
