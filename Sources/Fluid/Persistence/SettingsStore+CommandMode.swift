import Combine
import CryptoKit
import Foundation

extension SettingsStore {
    private var commandModeLinkedToGlobalKey: String { "CommandModeLinkedToGlobal" }

    var commandModeLinkedToGlobal: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: self.commandModeLinkedToGlobalKey) as? Bool {
                return value
            }
            return true
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.commandModeLinkedToGlobalKey)
        }
    }

    var effectiveCommandModeProviderID: String {
        if self.commandModeLinkedToGlobal {
            return self.supportedCommandModeProviderID(self.selectedProviderID) ?? ""
        }

        if let providerID = self.supportedCommandModeProviderID(self.commandModeSelectedProviderID) {
            return providerID
        }

        return ""
    }

    var effectiveCommandModeSelectedModel: String {
        let providerID = self.effectiveCommandModeProviderID
        let models = self.commandModeModels(for: providerID)

        if self.commandModeLinkedToGlobal,
           self.supportedCommandModeProviderID(self.selectedProviderID) == providerID
        {
            let key = ModelRepository.shared.providerKey(for: providerID)
            return self.providerScopedModel(self.selectedModelByProvider[key], in: models)
                ?? self.providerScopedModel(self.selectedModel, in: models)
                ?? models.first
                ?? ""
        }

        return self.providerScopedModel(self.commandModeSelectedModel, in: models)
            ?? models.first
            ?? ""
    }

    var commandModeReadinessIssue: String? {
        let sourceProviderID = self.commandModeLinkedToGlobal ? self.selectedProviderID : self.commandModeSelectedProviderID
        if sourceProviderID == "apple-intelligence" || sourceProviderID == "apple-intelligence-disabled" {
            return "命令模式无法使用 Apple Intelligence，因为终端工具需要聊天 API。请选择已验证的聊天服务商，或关闭同步。"
        }
        if self.isPrivateAIProviderID(sourceProviderID) {
            return "\(PrivateAIProviderFeature.displayName) 的命令模式即将推出。请选择已验证的聊天服务商，或关闭同步。"
        }

        let providerID = self.effectiveCommandModeProviderID
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "命令模式需要一个已验证的聊天服务商。"
        }

        let model = self.effectiveCommandModeSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return "命令模式需要选择一个聊天模型。"
        }

        if self.isUnsupportedCommandModeModel(model) {
            return "命令模式需要一个聊天模型。所选模型不受聊天/补全接口支持。"
        }

        guard self.isCommandModeProviderVerified(providerID) else {
            if self.commandModeLinkedToGlobal {
                return "命令模式需要一个已验证的聊天服务商。请验证同步的 AI 增强服务商，或关闭同步并为命令模式单独选择一个。"
            }
            return "命令模式需要一个已验证的聊天服务商。请先在 AI 增强中验证此服务商，再使用命令模式。"
        }

        return nil
    }

    func commandModeModels(for providerID: String) -> [String] {
        let storedList = ModelRepository.shared.providerKeys(for: providerID).lazy
            .compactMap { self.availableModelsByProvider[$0] }
            .first { !$0.isEmpty }

        return storedList ?? ModelRepository.shared.defaultModels(for: providerID)
    }

    private func supportedCommandModeProviderID(_ providerID: String) -> String? {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != "apple-intelligence", trimmed != "apple-intelligence-disabled" else { return nil }
        guard !self.isPrivateAIProviderID(trimmed) else { return nil }
        return trimmed
    }

    func isCommandModeProviderVerified(_ providerID: String) -> Bool {
        guard !self.isPrivateAIProviderID(providerID) else { return false }
        let key = ModelRepository.shared.providerKey(for: providerID)
        guard let stored = self.verifiedProviderFingerprints[key] else { return false }

        let baseURL = self.commandModeProviderBaseURL(for: providerID)
        let apiKey = self.getAPIKey(for: providerID) ?? ""
        return self.commandModeProviderFingerprint(baseURL: baseURL, apiKey: apiKey) == stored
    }

    private func commandModeProviderBaseURL(for providerID: String) -> String {
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) {
            return saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ModelRepository.shared.isBuiltIn(providerID) {
            return ModelRepository.shared.defaultBaseURL(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func commandModeProviderFingerprint(baseURL: String, apiKey: String) -> String? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return nil }
        let input = "\(trimmedBase)|\(trimmedKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isPrivateAIProviderID(_ providerID: String) -> Bool {
        PrivateFeatures.privateAIProvider &&
            providerID.trimmingCharacters(in: .whitespacesAndNewlines) == PrivateAIProviderFeature.shared.providerID
    }

    private func isUnsupportedCommandModeModel(_ model: String) -> Bool {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if PrivateAIIntegrationService.shouldHandleDictation(model: value) {
            return true
        }
        if value.contains("embedding") || value.contains("rerank") || value.contains("moderation") {
            return true
        }
        if value.hasPrefix("tts-") || value.hasPrefix("whisper-") || value.hasPrefix("dall-e") {
            return true
        }
        return value == "davinci" || value == "curie" || value == "babbage" || value == "ada"
    }

    private func nonEmptyModel(_ model: String?) -> String? {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func providerScopedModel(_ model: String?, in models: [String]) -> String? {
        guard let model = self.nonEmptyModel(model), models.contains(model) else { return nil }
        return model
    }
}
