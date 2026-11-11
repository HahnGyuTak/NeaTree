import Foundation
import Security
import Testing
@testable import OrganizerCore

@Suite("Noninteractive Keychain availability")
struct APIKeyStoreTests {
    @Test func availabilityRequestsOnlyMetadataAndSkipsAuthentication() throws {
        var calls = 0
        let exists = try APIKeyStore.containsKey { query in
            calls += 1
            let attributes = query as NSDictionary
            #expect(attributes[kSecClass] as? String == kSecClassGenericPassword as String)
            #expect(attributes[kSecAttrService] as? String == "local.file-organizer.openai")
            #expect(attributes[kSecAttrAccount] as? String == "api-key")
            #expect(attributes[kSecReturnAttributes] as? Bool == true)
            #expect(attributes[kSecReturnData] as? Bool == false)
            #expect(attributes[kSecMatchLimit] as? String == kSecMatchLimitOne as String)
            #expect(attributes[kSecUseAuthenticationUI] as? String == kSecUseAuthenticationUISkip as String)
            #expect(attributes[kSecValueData] == nil)
            #expect(attributes[kSecReturnRef] == nil)
            return errSecSuccess
        }
        #expect(exists)
        #expect(calls == 1)
    }

    @Test func absentItemIsNotConfigured() throws {
        #expect(try !APIKeyStore.containsKey { _ in errSecItemNotFound })
    }

    @Test func availabilityFailureIsReportedWithoutRetryingOrReadingData() {
        var calls = 0
        #expect(throws: (any Error).self) {
            _ = try APIKeyStore.containsKey { _ in
                calls += 1
                return errSecInteractionNotAllowed
            }
        }
        #expect(calls == 1)
    }
}
