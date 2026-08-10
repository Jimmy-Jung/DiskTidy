import Foundation
import Security

/// API 키 저장소. 키는 `UserDefaults`에 두지 않는다 — 평문 plist로 남아
/// 백업과 다른 프로세스에 그대로 노출된다.
protocol APIKeyStore: Sendable {
    func key(for account: String) -> String?
    /// nil이나 빈 문자열이면 삭제한다. 성공 여부를 반드시 확인한다.
    func setKey(_ key: String?, for account: String) -> Bool
}

/// macOS 키체인 구현. 계정을 제공자별로 나눠 제공자를 바꿔도 키가 섞이지 않는다.
///
/// ad-hoc 서명 빌드는 빌드마다 코드 서명 identity가 달라져 키체인이 접근 권한을 다시 묻는다.
/// 배포 빌드(Developer ID)에서는 한 번만 묻는다.
struct KeychainAPIKeyStore: APIKeyStore {
    private let service: String

    init(service: String = "com.jimmy.disktidy.ai") {
        self.service = service
    }

    func key(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    func setKey(_ key: String?, for account: String) -> Bool {
        let query = baseQuery(account: account)

        guard let key, !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            // 원래 없던 항목을 지우는 것도 "키가 없다"는 목표를 만족한다.
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(key.utf8)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = data
        // 최초 잠금 해제 후에만 읽힌다. 기본값과 달리 재시동 직후 자동 실행에서도 읽힌다.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
