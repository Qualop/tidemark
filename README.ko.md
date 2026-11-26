<p align="center">
  <img src="docs/hero-ko.png" width="780" alt="Codex 입력창에 표시된 Tidemark와 호버 카드">
</p>

<h1 align="center">Tidemark</h1>

<p align="center">
  남은 Codex·Claude 사용량을 입력창에서 바로 보여줍니다.<br>
  <a href="README.md">English</a>
</p>

---

Tidemark는 Codex와 Claude 데스크톱 앱 입력창의 빈 공간에 **5h**와 **7d** 막대 두 개를 띄웁니다. Codex에서는 지금 선택한 모델 기준으로 남은 한도를, Claude에서는 입력창 아래 줄에 Claude 한도를 한 줄로 보여줍니다. 막대에 마우스를 올리면 macOS 지니 효과로 카드가 막대에서 흘러나와, 모든 제공자의 남은 사용량과 각 한도가 언제 초기화되는지 한 번에 보여줍니다.

OpenCodex로 Claude 같은 다른 제공자를 Codex에 연결해 쓴다면, Tidemark가 모델 선택기를 따라갑니다. `anthropic/claude-…`를 고르면 Claude 한도가, GPT 모델을 고르면 다시 GPT 한도가 표시됩니다.

## 기능

- **모델 선택기를 따라갑니다.** 입력창에서 선택된 모델을 읽어, 바꾼 뒤 0.1초 안팎에 해당 한도로 바꿔 보여줍니다.
- **요금제를 알아봅니다.** 5시간 한도에 걸릴 일이 없는 요금제(Claude Ultra, ChatGPT Pro)에서는 5h 막대 대신 요금제 이름을 보여줘 `Ultra | 7d ━━ 100%`처럼 표시합니다. 월 단위 한도만 있는 요금제는 `30d`로 보여줍니다.
- **Codex와 Claude 모두.** 두 데스크톱 앱에서 동작하고, 앞에 있는 앱을 따라갑니다. Claude 앱은 아래 버튼 줄이 얇아서 한 줄 디자인으로 바뀝니다.
- **호버 카드.** 모든 제공자의 남은 비율과 초기화까지 남은 시간을 함께 보여줍니다. 지금 쓰는 제공자는 자기 색 이름과 채워진 점으로, 나머지는 회색으로 표시됩니다. 배경 블러, 나타나고 사라질 때의 macOS 지니 효과, 라이트·다크 모드를 지원합니다.
- **모델별 토큰 속도.** 호버 카드에 앱별 최근 응답 속도(tok/s)를 모델마다 보여줍니다. Codex와 Claude 앱은 각자의 세션 기록으로 따로 잽니다.
- **작업을 방해하지 않습니다.** 클릭은 그대로 아래로 통과하고, Dock 아이콘도 메뉴 막대 아이콘도 창도 없습니다.
- **가볍습니다.** 프로세스 하나로 동작하며, Codex가 앞에 있을 때 메모리 약 11MB, CPU는 코어 하나의 1% 미만을 씁니다. 그 밖에는 거의 쓰지 않습니다. Codex가 꺼져 있으면 Codex가 켜지기를 기다리기만 합니다.
- **두 가지 언어.** 영어판과 한국어판을 따로 빌드해 각각 최대한 작게 유지합니다.

## 요구 사항

| | |
|---|---|
| macOS | macOS 14 Sonoma 이상 (Apple 실리콘, Intel 모두) |
| 앱 | Codex / ChatGPT 데스크톱 앱(`com.openai.codex`), Claude 데스크톱 앱(`com.anthropic.claudefordesktop`) 중 하나 이상 |
| 선택 | 더 많은 제공자를 보려면 Claude Code, OpenCodex, Gemini CLI 중 로그인된 것 (아래 참고) |

## 설치

1. [Releases](../../releases)에서 `Tidemark-<버전>-ko.zip`을 내려받습니다. 영어판은 `-en.zip`입니다.
2. 압축을 풀고 **Tidemark.app**을 **응용 프로그램** 폴더로 옮깁니다.
3. 앱을 엽니다. 공증(notarization)을 받지 않은 앱이라 처음 실행할 때 macOS가 막습니다. **시스템 설정 → 개인정보 보호 및 보안**에서 **그래도 열기**를 누르거나, 터미널에서 다음을 실행합니다.
   ```sh
   xattr -dr com.apple.quarantine /Applications/Tidemark.app
   ```
4. **손쉬운 사용** 권한을 요청하면 허용합니다(**시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**). 입력창 위치를 찾고 모델 선택기 글자를 읽는 데 필요합니다. 권한이 허용되면 Codex와 Claude 모두에 렌더러 접근성 트리 활성화를 요청합니다. Electron의 `AXManualAccessibility`를 지원하지 않는 Codex에서는 Chromium의 `AXEnhancedUserInterface`를 사용합니다.

실행하면 로그인 항목에 스스로 등록되고, macOS가 등록을 빠뜨린 경우에 대비해 실행할 때마다 다시 확인합니다. **시스템 설정 → 일반 → 로그인 항목**에서 끄면 꺼진 상태를 그대로 둡니다.

> 별도 개발자 인증서 없이 서명한 앱이라, 새 버전으로 업데이트하면 손쉬운 사용 권한을 다시 물을 수 있습니다. 기존 항목을 지우고 새로 허용해 주세요.

## 숫자는 어디서 오나요

별도 서비스는 필요 없습니다. 이미 쓰고 있는 도구에서 각 제공자의 값을 직접 읽고, 좋은 출처부터 씁니다.

| 한도 | 출처 |
|---|---|
| GPT | Codex 로그인(`~/.codex/auth.json`)으로 Codex가 직접 쓰는 `chatgpt.com/backend-api/wham/usage`를 조회합니다. OpenCodex 캐시는 대체 수단으로만 씁니다. |
| Claude | 1. `ClaudeKeychain`을 **직접 켠 경우에만** Claude Code 로그인으로 정확한 5h·7d 한도를 조회합니다(`api.anthropic.com/api/oauth/usage`). 2. OpenCodex가 있으면 그 사용량 캐시. 3. Claude 앱이 앞에 있을 때 앱 자체의 사용량 표시(5h만). |
| Gemini | Gemini CLI 로그인(`~/.gemini/oauth_creds.json`)으로 Pro·Flash 일일 한도를 조회합니다. Code Assist 한도가 있는 계정으로 로그인돼 있을 때만 표시합니다. 만료된 토큰은 메모리에서만 갱신하고 파일에 다시 쓰지 않습니다. |
| 선택된 모델 | 손쉬운 사용 API로 읽은 입력창의 모델 선택기 |
| 토큰 속도 | 각 앱의 로컬 기록 `~/.codex/sessions`(Codex Desktop 세션)와 `~/.claude/projects`(Claude 데스크톱 앱 항목). 시간, 출력 토큰 수, 모델 이름만 읽고, 기록에 새로 추가된 부분만 읽습니다. 요청부터 응답 끝까지의 시간으로 출력 토큰 수를 나누므로 첫 토큰까지의 대기 시간이 포함됩니다. Claude 일반 채팅 모드는 로컬 기록이 없어 재지 않습니다. |

토큰은 필요할 때만 읽어 메모리에만 두고, 해당 회사 서버에만 보냅니다. 조회는 최대 1분에 한 번(Gemini는 5분에 한 번)입니다.

Tidemark는 Codex나 OpenCodex 파일에 아무것도 쓰지 않고, 다른 곳으로 아무것도 보내지 않습니다. Tidemark 자체 파일은 `~/Library/Application Support/Tidemark`에 있습니다.

## 설정

필요할 때만 쓰면 됩니다. `~/Library/Application Support/Tidemark/config.json` 파일에 아래 키 중 원하는 것만 넣고 Tidemark를 다시 실행하세요.

| 키 | 기본값 | 의미 |
|---|---|---|
| `VisualScale` | `0.95` | 막대 크기 |
| `HorizontalOffset` | `0` | 좌우 위치 미세 조정(포인트) |
| `BottomOffset` | `32` | 입력창 아래쪽 버튼 줄을 못 찾았을 때의 세로 위치 |
| `TrackingIntervalMs` | `8` | 창을 움직이거나 크기를 바꿀 때 따라가는 주기 |
| `UsageRefreshIntervalMs` | `60000` | 사용량을 가져오는 주기 |
| `ClaudeKeychain` | `false` | 키체인의 Claude Code 로그인으로 정확한 Claude 한도를 가져옵니다. 처음 한 번 macOS가 허용 여부를 묻습니다(별도 인증서 없이 서명한 앱이라 업데이트 후에도 다시 물을 수 있습니다). |
| `NoFiveHourPlans` | `["claude:ultra", "gpt:pro"]` | 5h 막대 대신 요금제 이름을 보여줄 요금제 목록. `[]`로 두면 항상 5h를 보여줍니다. |

```json
{ "VisualScale": 1.0, "HorizontalOffset": -4 }
```

## 소스에서 빌드

Xcode 또는 Command Line Tools(Swift 5.9 이상)가 필요합니다.

```sh
git clone https://github.com/Qualop/tidemark.git
cd tidemark
Scripts/install.sh ko     # 한국어판, ~/Applications에 설치
Scripts/install.sh        # 영어판
```

`Scripts/build-release.sh`는 유니버설 릴리즈 압축 파일을 `dist/`에 만듭니다. `swift run TidemarkChecks`로 사용량 파싱 검증을 실행할 수 있습니다.

## 삭제

```sh
Scripts/uninstall.sh
```

직접 지우려면 Tidemark를 종료하고(`pkill -x Tidemark`) 앱과 `~/Library/Application Support/Tidemark` 폴더를 삭제하면 됩니다.

## 막대가 보이지 않을 때

`~/Library/Application Support/Tidemark/tracking.json`에 앱별 마지막 추적 상태, Tidemark 버전, 접근성 활성화 요청 결과(`0`은 성공)를 기록합니다. 앱 비활성, 권한 대기, 창·입력창·모델 선택기 감지 실패, 표시 공간 부족, 표시 완료를 구분합니다. 상태가 바뀔 때만 기록하며 창 제목이나 대화 내용은 포함하지 않습니다. 사용한 활성화 속성도 기록합니다. Chromium은 요청을 받아들인 뒤에도 `-25208`을 반환할 수 있으므로, 약 2초의 활성화 지연 후 추적 상태로 실제 감지 여부를 확인합니다. `status.json`의 사용량 조회 성공은 막대 표시 성공을 뜻하지 않습니다.

## 가볍게 유지하는 방법

- 입력창은 손쉬운 사용 트리를 한 번 훑어 찾고, 찾는 즉시 탐색을 멈춥니다. 그 뒤로는 요소마다 필요한 속성 몇 개만 요청 한 번에 묶어 읽습니다.
- 위치는 0.1초마다 확인하고, 창을 움직이거나 입력창 크기가 바뀔 때만 빠르게 따라갑니다.
- 마우스 움직임은 Codex가 맨 앞에 있을 때만 봅니다. 호버 카드는 처음 쓸 때 만들어지고, 비트맵 한 장과 Core Animation 레이어 몇 개로 그려지며, 사라지면 메모리를 돌려줍니다.
- 지니 효과는 WindowServer가 카드 창을 휘게 하는 방식이라, Tidemark 쪽 CPU는 애니메이션 한 번에 약 10ms입니다.

## 크레딧

지니 애니메이션은 usagimaru의 [GenieWarpMesh](https://github.com/usagimaru/GenieWarpMesh)(MIT)를 씁니다. 이 라이브러리는 비공개 API인 `CGSSetWindowWarp`를 사용합니다.

## 라이선스

[MIT](LICENSE). Tidemark는 OpenAI 및 Anthropic과 관련이 없습니다.
