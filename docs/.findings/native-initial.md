# Margin 네이티브 구현 리뷰

결론적으로 **amend**를 권고합니다. Core 동작과 AI 안전장치는 대체로 의도에 맞게 구현되어 있습니다. 다만 NSDocument 생애주기와 연결된 경로 세 곳에서 버전 이력이 잘못 연결되거나 텍스트가 손상될 수 있으므로, 완료를 선언하기 전에 H 항목을 수정해야 합니다.

전달받은 소스에는 줄 번호가 없어서, 아래 `file:line`은 제가 직접 센 근사값(≈)입니다. 심볼 이름도 함께 적었습니다. 저는 도구를 사용하지 않았기 때문에, 이 리뷰에 나오는 런타임 동작은 모두 소스를 읽고 추론한 결과입니다. AppKit 내부 동작에 기대는 지적에는 *(추정)*을 붙였습니다.

## Closeout

| 항목 | 내용 |
|---|---|
| 리뷰 대상 | `native-brief.json`, `requirements.json`, `Application.swift`, `Checks.swift`, `Core.swift`, `Editor.swift`, `Review.swift`, `Sheets.swift`, `build.sh`, `run.sh`, `preview.{html,js,css}` |
| 리뷰 방식 | 전달된 소스 전문을 정적으로 읽었습니다. 도구 호출, 빌드, 실행은 하지 않았습니다. |
| 사용자 보고 기준 통과 항목 | `--check` core assertion 18건, 이전 `--ui-check`(NSTextView, 뷰 선택, Tab, undo, sanitized WebKit, 로컬 자동저장과 원본 파일 자동저장) |
| 아직 주장하지 않은 항목 | 확장 history UI, restore, layout 검사(진행 중), live provider 호출, 실제 Keychain 저장 |
| 확인된 범위 | NSDocument 저장 경로, VersionStore 원자성, 복원 흐름, AI stale/IME/Tab 가드, 출처 필터, Keychain 경로, WebKit 정책 |
| 확인하지 못한 범위 | NSDocument가 스스로 실행하는 autosave, 창 복원, 종료 시퀀스의 실제 동작. 모두 *(추정)*입니다. |
| 발견 건수 | H 4, M 7, L 4 |

## Protocol Benefit

| 항목 | 점수 | 근거 |
|---|---|---|
| decision (0-3) | 2 | 브리프가 웹 앱을 명시적으로 기각하고 AppKit NSDocument와 NSTextView 구조로 방향을 바꿨습니다. 다만 이 전환은 사용자가 거부한 데서 시작했습니다. |
| discovery (0-2) | 1 | "복원 전 현재 내용 보관"과 "충돌 감지"는 위험 요소로 잡아 냈습니다. 그러나 `autosaveElsewhere`, 창 복원, 닫은 뒤 다시 여는 경로는 위험 목록에 없습니다. |
| verification (0-2) | 1 | UI check가 자동저장, 복원, Tab을 실제로 검사합니다. 반면 untitled 자동저장, 닫기 후 재열기, 종료 직전 1초 구간, 복원 후 undo는 검사하지 않습니다. |
| correctapply (0-1) | 1 | 다중 파일 신규 기능이므로 Phase 1을 적용한 판단은 적절했습니다. |
| reworkavoided (0-2) | 0 | 실제로 막아 낸 재작업이 관찰된 기록은 없습니다. 반사실 추정은 점수에 넣지 않았습니다. |

## Findings

### H: 데이터 무결성과 손실 위험

**H1. untitled 문서를 자동저장하면 레코드 경로가 Autosave Information 파일로 바뀝니다.** `Application.swift:≈243` (`MarginDocument.writeSafely`)

- 결함: `writeSafely`는 저장 방식(operation)과 상관없이 마지막에 `record.path = url...`과 `expectedDiskHash`를 갱신합니다. untitled 문서는 `autosavesInPlace=true`이고 `autosavingDelay=1`이므로, NSDocument가 `.autosaveElsewhereOperation`으로 `~/Library/Autosave Information/...` 아래에 파일을 씁니다 *(추정)*. 이때 레코드 경로가 그 임시 파일로 덮어써집니다. 이후 `edited()`가 `fileURL?.path`, 즉 nil로 다시 덮어쓰기 때문에 경로 값이 번갈아 바뀝니다. 다음 실행 때 복구 경로(`applicationDidFinishLaunching`)가 이 임시 파일의 해시와 일치하면, 그 파일이 `fileURL`로 연결되어 원본처럼 편집됩니다. `.saveToOperation`(사본 저장)도 같은 방식으로 레코드를 다른 파일에 붙여 버립니다.
- 필요한 수정: `record.path`, `name`, `expectedDiskHash`는 `.saveOperation`, `.saveAsOperation`, `.autosaveInPlaceOperation` 가운데 `url == fileURL`인 경우에만 갱신해야 합니다. `autosaveElsewhere`와 `saveTo`는 버전 스냅샷만 남겨야 합니다. 이 경로를 untitled 상태에서 2초 이상 기다리는 UI check로 고정해야 합니다.

**H2. 복원과 외부 소스 동기화가 `NSTextView.string`을 통째로 바꾸므로 undo 스택이 오래된 범위를 가리킵니다.** `Editor.swift:≈147` (`refreshSources`), `Application.swift:≈300` (`restore`)

- 결함: `refreshSources`는 `pane.editor.string = ...`으로 텍스트 저장소를 undo 등록 없이 교체합니다. 두 pane은 같은 창의 undo manager를 공유합니다 *(추정)*. 그래서 복원한 직후 ⌘Z를 누르면, 복원 전 텍스트 기준의 range가 새 텍스트에 적용되어 문서가 손상되거나 `NSRangeException`이 발생할 수 있습니다. UI check는 restore 다음에 undo를 실행하지 않으므로 이 상황을 검출하지 못합니다.
- 필요한 수정: 가장 좋은 방법은 두 pane이 하나의 `NSTextStorage`를 공유하도록 layout manager 두 개를 붙이는 것입니다. 이렇게 하면 동기화 코드가 필요 없어지고, M4에서 다루는 성능과 커서 문제도 함께 해결됩니다. 최소한으로 고치려면, 복원과 프로그램이 일으키는 교체를 `shouldChangeText(in:)`와 `replaceCharacters`, 그리고 undo grouping으로 처리하거나, 교체 직후 `undoManager.removeAllActions()`를 호출해야 합니다. "restore 후 undo" 시나리오를 check에 추가해야 합니다.

**H3. 닫은 문서가 `documents` 배열에 남기 때문에, 같은 파일을 다시 열면 아무 창도 나타나지 않습니다.** `Application.swift:≈80` (`open`), `≈290` (`close`)

- 결함: `close()`가 끝나도 `MarginAppDelegate.documents`에서 문서를 제거하지 않습니다. 그래서 `open(url)`이 이미 닫힌 문서를 찾아 `showWindows()`만 호출하고, 그 문서에는 window controller가 없으므로 창이 열리지 않습니다. 충돌 메시지가 안내하는 "원본을 다시 열어 주세요"도 같은 이유로 동작하지 않습니다. 열린 파일 문서에서는 같은 경로가 그대로 반환되기 때문입니다. 종료할 때 닫힌 문서까지 `flush()`가 실행되는 부작용도 있습니다.
- 필요한 수정: `close()`에서 delegate 배열의 해당 문서를 제거하고 `NSDocumentController.removeDocument`를 호출해야 합니다. 충돌이 났을 때 현재 내용을 보존한 채 디스크에서 다시 읽는 명시적 동작(`revert`나 "디스크에서 다시 열기")을 추가해야 합니다.

**H4. 파일 저장 경로의 충돌 메시지가 실제와 다른 사실을 말합니다.** `Application.swift:≈239` (`writeSafely`)

- 결함: `FileGuard.validate`가 `persistNow`보다 먼저 실행됩니다. 그래서 ⌘S로 저장하다 충돌이 나면 현재 내용을 버전에 남기기 전에 예외가 발생합니다. 그런데 오류 문구는 "현재 내용은 버전 이력에 보관했어요"라고 말합니다(`Core.swift:≈145`). debounce된 `edited()`가 이미 저장한 경우에만 이 문구가 우연히 맞습니다.
- 필요한 수정: `persistNow`를 먼저 실행한 뒤 `validate`를 호출해야 합니다. 이 순서를 고정하는 check를 추가해야 합니다.

### M

**M1. 시스템 창 복원과 자체 복구가 겹칠 수 있습니다.** `Application.swift:≈52`, `≈222` (`init()`)

- 결함: NSDocument 창은 기본적으로 restorable입니다 *(추정)*. 재실행하면 `NSDocumentController`가 convenience `init()`으로 새 무작위 레코드를 만들어 문서를 복원할 수 있습니다. 이렇게 복원된 문서는 `documents` 배열에 들어가지 않으므로, 자체 복구가 같은 내용을 한 번 더 엽니다. 그러면 창이 두 개 생기고 이력도 나뉩니다. 같은 이유로 `read(from:)` 경로는 `store.record(path:)`로 기존 레코드를 찾지 않습니다.
- 필요한 수정: `window.isRestorable = false`로 끄거나, 복구 경로를 NSDocumentController 하나로 통일해야 합니다. `read(from:)`에서는 기존 레코드를 경로로 찾아 연결해야 합니다.

**M2. 복구할 때 디스크 해시가 다르면 원본 파일과의 연결이 영구히 끊깁니다.** `Application.swift:≈57`

- 결함: 디스크 해시가 다르면 `fileURL=nil`로 복구합니다. 그 뒤 첫 `edited()`가 `record.path=nil`을 저장하므로, 같은 파일을 다시 열면 새 레코드가 생겨 이력이 나뉩니다. 사용자에게는 "원본이 바뀌었다"는 안내도 나오지 않습니다.
- 필요한 수정: 레코드 경로는 유지하고, 문서는 "원본 충돌" 상태로 표시해야 합니다. 그리고 "디스크 버전 열기"와 "다른 이름으로 저장" 중에서 고르게 해야 합니다.

**M3. 종료 직전 1초 안의 편집이 원본 파일에 써지는지 보장되지 않습니다.** `Application.swift:≈108` (`applicationShouldTerminate`), `≈283` (`flush`)

- 결함: `flush()`는 로컬 VersionStore에만 저장하고, 대기 중인 원본 파일 자동저장 작업은 cancel합니다. NSDocumentController가 종료 과정에서 dirty 문서를 autosave하는지는 검증되지 않았습니다 *(추정)*. `showHistory`도 `flush()`로 같은 작업을 취소하기 때문에, 상태 표시가 "저장 중…"에 머물 수 있습니다.
- 필요한 수정: 파일이 연결된 dirty 문서는 종료할 때 `autosave(withImplicitCancellability:)`가 완료될 때까지 `.terminateLater`로 기다려야 합니다. "편집 직후 ⌘Q, 재실행, 원본 파일 해시 비교" check를 추가해야 합니다.

**M4. 키 입력마다 숨겨진 pane까지 전체 문자열을 재설정하고 렌더링합니다.** `Editor.swift:≈147`, `≈157`

- 결함: 2MB 문서에서는 키 입력마다 O(n) 복사가 발생합니다. 숨겨진 pane에 `marked.parse`를 두 번 실행하고, 다른 source pane의 선택 범위 길이를 0으로 만들며 스크롤 위치도 초기화합니다.
- 필요한 수정: H2에서 제안한 NSTextStorage 공유로 해결할 수 있습니다. 미리보기는 보이는 pane만, debounce를 걸어 렌더링해야 합니다.

**M5. 이력을 열 때 모든 버전의 본문을 메모리에 올리고 해시를 검증합니다.** `Core.swift:≈110` (`versions`), `Editor.swift:≈178` (`showHistory`)

- 결함: debounce 간격이 1초이고 정리 정책이 없으므로 버전 수가 계속 늘어납니다. 큰 문서에서 이력을 열면 메모리와 시간이 버전 수에 비례해 증가합니다. 마지막 버전 파일 하나가 손상되면 `latest`가 예외를 던지고, 그 문서의 모든 `save`가 영구히 실패합니다.
- 필요한 수정: 레코드에 메타데이터(시각, 이유, 크기)만 담고, 본문은 사용자가 선택할 때 lazy load해야 합니다. 손상된 버전은 건너뛰고 표시하도록 해야 합니다.

**M6. ad-hoc 서명 때문에 재빌드하면 Keychain 항목을 읽지 못할 수 있고, 실패 원인이 숨겨집니다.** `build.sh:codesign --sign -`, `Review.swift:≈14` (`load`)

- 결함: ad-hoc 서명은 빌드할 때마다 cdhash가 바뀝니다. 그래서 기존 항목의 ACL과 맞지 않을 수 있습니다 *(추정)*. `interactionNotAllowed` 상태에서는 `errSecSuccess`가 아닌 모든 상태가 nil로 처리됩니다. 그 결과 UI는 "API 키가 아직 없어요"라고 잘못 안내합니다.
- 필요한 수정: `errSecItemNotFound`와 그 밖의 상태(`errSecInteractionNotAllowed`, `errSecAuthFailed`)를 구분해 표시해야 합니다. 키 삭제 동작도 추가해야 합니다.

**M7. 사실 차단이 모델이 고른 category와 숫자 변화에만 의존합니다.** `Review.swift:≈103` (`blocked`)

- 결함: 모델이 "일본"을 "대한민국"으로 바꾸고 category를 `wording`으로 표시하면, 차단을 통과해 Tab으로 적용할 수 있습니다. `knownLimits`에 "semantic classification은 모델 판단"이라고 적혀 있기는 합니다. 그러나 FR-MD-5의 "unsupported factual edits blocked"를 충족한다고 주장하기에는 부족합니다.
- 필요한 수정: 최소한 고유명사, 날짜, 숫자 토큰의 차이를 감지하면 `fact`로 승격해야 합니다. 또는 FR-MD-5의 문구를 현재 보장 범위에 맞게 축소해야 합니다.

### L

- **L1.** `Editor.swift:≈221`: `cancelOperation`이 항상 `true`를 반환합니다. 제안이 없을 때도 Esc를 소비하므로 상위 responder가 Esc를 받지 못합니다. 제안이 있을 때만 `true`를 반환하도록 바꾸는 것이 좋습니다.
- **L2.** `Editor.swift:≈247` (`showProposal`): 읽기 전용 제안 텍스트에 `checkTextInDocument(nil)`을 실행하는 것은 불필요합니다. 제거하는 것이 좋습니다.
- **L3.** `edited()`의 배경 작업이 실패하면 `revision`을 확인하지 않고 상태를 덮어씁니다. 그래서 오래된 실패 문구가 최신 성공 문구를 가릴 수 있습니다. 성공 경로와 같은 `revision` 가드를 넣는 것이 좋습니다.
- **L4.** `build.sh`가 `node_modules`를 직접 복사합니다. 그래서 "pinned bundle"이라는 주장이 lockfile과 검증된 버전에 근거하는지 이 소스만으로는 확인할 수 없습니다. 복사한 리소스의 버전과 해시를 `--state-json`에 노출하는 것이 좋습니다.

### 잘 구현된 부분

- `VersionStore.save`는 스냅샷 파일을 먼저 원자적으로 기록한 뒤 레코드 포인터를 갱신합니다. 같은 해시를 중복 저장하지 않으며, 읽을 때 무결성을 검증합니다.
- 복원은 덮어쓰지 않고 새 버전을 추가합니다. 복원 전 현재 내용도 먼저 보관합니다.
- AI 제안을 적용하려면 `revision`, 원문 일치, 선택 범위 포함 세 조건을 모두 통과해야 합니다. 비동기 결과는 token과 `Task.isCancelled`로 다시 검사합니다. IME 입력 중(`hasMarkedText`)에는 예약 시점과 실행 시점에 모두 차단합니다.
- 사실 수정을 승인할 근거는 provider의 `web_search_tool_result`와 citation URL로만 인정합니다. 모델이 만들어 낸 URL은 `unverified`로 강등합니다.
- WebKit은 nonPersistent 저장소, CSP, DOMPurify를 적용하고, 이미지를 placeholder로 바꾸며, 번들 내부 파일로만 이동을 허용합니다. localhost 서버는 사용하지 않습니다.

## Verdict

**amend**를 권고합니다. 차단할 정도로 설계가 잘못된 것은 아닙니다. 다만 H1부터 H4까지는 브리프의 circuit breaker("restore 테스트에서 미저장 내용 손실")와 FR-MD-7, FR-MD-8의 진실성 요건에 직접 걸립니다. 따라서 이 네 항목을 수정하고, 다음 check를 추가로 통과시킨 뒤에 완료를 선언해야 합니다.

1. untitled 자동저장 후 `record.path`가 바뀌지 않는지 검사합니다.
2. restore 직후 undo해도 텍스트가 손상되지 않는지 검사합니다.
3. 문서를 닫은 뒤 같은 파일을 다시 열면 창이 나타나는지 검사합니다.
4. ⌘S로 저장하다 충돌이 나도 버전이 보존되는지 검사합니다.

M1과 M3은 현재 소스만으로는 실제 동작을 확정할 수 없습니다. 실행 검증으로 확인하거나, 수정해서 위험을 없애야 합니다.
