# Contributing

## 개발 환경

- macOS 13 이상, Xcode 16 이상
- 의존성 없음. `swift build` / `swift test`만 있으면 된다.

```bash
swift build          # 빌드
swift test           # 테스트
./Scripts/run.sh     # 앱 실행
```

## PR 기준

CI(`.github/workflows/ci.yml`)가 세 가지를 검사한다. 전부 통과해야 병합된다.

1. `swift build -c release` 성공
2. `swift test` 전부 통과
3. **컴파일 경고 0건** — 경고가 하나라도 있으면 실패한다

## 이 프로젝트에서 특히 조심할 것

이 앱은 사용자 파일을 지운다. 아래 규칙은 협상 대상이 아니다.

### 삭제는 휴지통을 거친다

새 삭제 경로를 추가할 때 `FileManager.removeItem`을 쓰지 말고 `TrashService.trash`를 쓴다. 복구 불가능한 삭제(`simctl delete` 등)는 반드시 `confirmationDialog`로 확인을 받는다.

### 실패를 삼키지 않는다

`TrashService.trash`는 의도적으로 `@discardableResult`가 아니다. 반환값을 반드시 확인하고, 실패한 항목은 목록에서 지우지 않고 `errorMessage`로 사용자에게 보고한다. "지운 것처럼 보이지만 용량은 그대로"가 이 앱에서 가장 나쁜 실패 모드다.

### 캐시 판정에 새 디렉터리를 추가할 때

`ProjectCacheScanner`에 이름을 넣기 전에 그 이름이 소스 디렉터리로도 쓰이는지 따져본다. 조금이라도 애매하면 `unambiguousCacheDirNames`가 아니라 `markerGatedCacheDirNames`에 마커 파일과 함께 넣는다. 테스트도 함께 추가한다 (`ProjectCacheMarkerGateTests` 참고).

### 외부 프로세스를 실행할 때

`ShellRunner`를 쓴다. `Process`를 직접 만들지 말 것 — stderr를 `Pipe`로 두면 자식이 파이프 버퍼를 채운 순간 앱이 영구 정지한다. 이미 한 번 겪은 버그이고 회귀 테스트가 있다.

### 메인 스레드를 막지 않는다

`du`, `find`, `simctl`, `trashItem`은 모두 초 단위로 걸릴 수 있다. 전부 `Task.detached`에서 돌리고 결과만 `@MainActor`로 가져온다.

## 코드 스타일

- `let` 우선, 값 타입 우선
- 뷰 로직은 `ViewModels/`로, 파일시스템 접근은 `Services/`로
- 왜 그렇게 했는지가 자명하지 않은 코드에만 주석을 단다 (특히 회피한 함정)
- 새 UI 문자열은 한국어. 영어 로컬라이제이션 PR은 환영한다

## 테스트

Swift Testing(`import Testing`, `@Test`, `#expect`)을 쓴다. 순수 로직은 반드시 테스트한다. 파일시스템이 필요하면 `NSTemporaryDirectory()` 하위에 UUID 디렉터리를 만들어 쓴다 — 사용자 홈을 건드리는 테스트는 받지 않는다.

## 커밋 메시지

```
<type>: <description>
```

`feat` `fix` `refactor` `docs` `test` `chore` `perf` `ci`
