import Foundation

#if COMPANION_TESTING
func companionTestingSelectedAIProviderConfiguration(environment: [String: String]) throws -> CompanionAIProviderConfiguration {
    try CompanionAISettingsStore(environment: environment).providerConfiguration()
}
#endif
