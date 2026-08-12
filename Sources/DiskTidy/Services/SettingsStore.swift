import Foundation

/// 문자열 설정 저장소.
///
/// `UserDefaults`를 그대로 주입받지 않는 이유는 테스트 때문이다. 테스트가 명명 스위트
/// (`UserDefaults(suiteName:)`)를 쓰면 `~/Library/Preferences`에 plist가 생기고,
/// `removePersistentDomain` 뒤에 파일을 지워도 cfprefsd가 비동기로 다시 써서 되살아난다.
/// 인터페이스를 좁혀 두면 테스트가 파일을 아예 만들지 않는다.
protocol SettingsStore {
    func string(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
}

struct UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func setString(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
