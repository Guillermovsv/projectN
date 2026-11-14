import Foundation
import Testing
@testable import ProjectN

struct SecretStoreTests {
    @Test func roundTripsPrivatelyAndSurvivesReload() throws {
        let svc = "test.\(UUID().uuidString)"
        #expect(SecretStore.get(service: svc, account: "a") == nil)
        #expect(SecretStore.set(service: svc, account: "a", value: "xoxb-123"))
        SecretStore.resetCache()
        #expect(SecretStore.get(service: svc, account: "a") == "xoxb-123")
        let attrs = try FileManager.default.attributesOfItem(atPath: SecretStore.file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        SecretStore.delete(service: svc, account: "a")
        SecretStore.resetCache()
        #expect(SecretStore.get(service: svc, account: "a") == nil)
    }
}
