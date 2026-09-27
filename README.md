# Claude × Codex 오케스트레이션 킷

**agent-switchboard를 Gemini 구독 없이, 멈춤 없이 쓰기 위한 보완 도구 (Windows)**

Claude(Anthropic)와 GPT(OpenAI Codex)를 한 작업 안에서 함께 부리는 도구인
[agent-switchboard](https://github.com/FutureisinPast/mcp-agent-switchboard)는 강력하지만,
**Gemini 구독이 없는 사용자에게는 몇 분마다 작업이 멈추는 문제**가 있습니다.
이 킷은 그 원인을 소스 코드 수준에서 찾아내고, 도구가 공식으로 제공하는 설정만 사용해 해결합니다.

- **멈춤 없음** — 작업을 가로막던 "게이트"가 더 이상 차단하지 않습니다. 기록은 그대로 남습니다.
- **역할을 파일 하나로** — 누가 설계하고 누가 코딩할지, 어떤 모델을 얼마나 깊게 생각하게 할지를 `roles.json` 한 파일에서 정합니다.
- **되돌아가지 않음** — switchboard가 재시작할 때마다 설정을 덮어쓰던 문제를 막습니다.

> 이 문제를 어떻게 추적하고 해결했는지는 [사례 연구 문서](docs/case-study.md)에 자세히 정리했습니다.

---

## 성과 요약

저자 PC에서 같은 작업 흐름을 개선 전후로 기록한 게이트 로그를 비교했습니다.
두 가지 방법(Python, PowerShell)으로 따로 계산해 결과가 일치하는 것을 확인했습니다.

| 항목 | 개선 전 (7.1일) | 개선 후 (3.1일) |
|---|---:|---:|
| 도구 호출 수 | 328회 | 332회 |
| **게이트에 막힌 호출** | **34회** | **0회** |
| **손으로 게이트를 푼 횟수** | **37회** | **0회** |
| 다른 AI에게 일을 넘긴 횟수 | 29회 | 22회 |
| 그중 게이트가 "위임했다"고 인정한 횟수 | **0회** | (차단이 없으므로 불필요) |
| 이전 설정이었다면 막혔을 호출 | — | 156회 (전체의 47%) |

- 개선 전에는 **일을 넘겨도 게이트가 단 한 번도 인정하지 않았습니다.** 29회 중 4회는 존재하지 않는 Gemini로 보내려다 실패했고, 25회는 Codex로 잘 처리됐는데도 switchboard의 버그 때문에 영수증이 붙지 않았습니다. 그래서 막히면 손으로 푸는 것 말고는 방법이 없었습니다.
- 설정을 적용한 2026-08-29부터 2026-09-27까지 **29일 동안** 여러 번의 재시작을 거치고도 설정이 한 번도 되돌아가지 않았습니다.

---

## 이런 분께 맞습니다

- agent-switchboard를 설치해서 Claude Code(+ 선택적으로 Codex CLI)와 함께 쓰고 있다
- **Gemini/Antigravity 구독은 없다** (Claude 구독 + ChatGPT 구독만 있다)
- 작업 중에 "Routing gate: ... The next call is blocked" 같은 메시지로 자꾸 멈춘다
- Windows를 쓴다

### 필요한 것

| 항목 | 비고 |
|---|---|
| Windows 10/11 | PowerShell 5.1(기본 내장) 또는 7 |
| [agent-switchboard](https://github.com/FutureisinPast/mcp-agent-switchboard) | 먼저 설치되어 있어야 합니다. 1.0.39에서 실측, 1.0.47까지 소스 기준 동일 동작 확인 |
| Claude Code | 필수 |
| Codex CLI | 선택. GPT에게 일을 맡기려면 필요 |

---

## 먼저 알아두면 좋은 용어

| 용어 | 쉬운 설명 |
|---|---|
| **MCP** | AI 프로그램이 외부 도구를 불러 쓰는 표준 연결 방식. agent-switchboard는 MCP로 동작하는 "AI 간 중계소"입니다. |
| **브레인 / 워커** | 브레인은 지금 여러분과 대화 중인 AI(판단 담당), 워커는 브레인이 일을 나눠 주는 다른 AI(실행 담당)입니다. |
| **위임** | 브레인이 읽기·검색·구현 같은 일을 워커에게 넘기는 것. 비싼 모델의 사용량을 아끼는 핵심 수단입니다. |
| **게이트** | switchboard가 설치하는 감시 장치. 브레인이 위임 없이 직접 일을 4번 하면 다음 행동을 막습니다. |
| **릴리프** | 막힌 게이트를 다시 여는 것. 원래는 "위임에 성공하면" 자동으로 열리게 설계되어 있습니다. |
| **롤 파일** | 워커 AI의 설정 파일(어떤 모델을 쓰고 얼마나 깊게 생각할지). `~\.claude\agents\` 등에 있습니다. |
| **effort** | AI가 답하기 전에 얼마나 깊게 생각할지의 단계(low → max). 높을수록 정확하지만 느리고 비쌉니다. |

---

## 왜 멈췄나 — 3분 요약

게이트는 "브레인이 직접 일하지 말고 워커에게 넘겨라"라는 규칙을 강제합니다. 문제는 **넘길 곳이 없었다는 것**입니다.

```mermaid
flowchart LR
    A[브레인이 직접 4번 작업] --> B{게이트}
    B -->|차단| C[위임해야 풀림]
    C --> D[기본 워커 = Gemini Flash]
    D -->|구독 없음| E[실패: 인정 안 됨]
    C --> F[Codex에게 위임]
    F -->|작업은 성공| G[영수증 누락 버그: 인정 안 됨]
    E --> H[손으로 해제 명령 입력]
    G --> H
```

1. switchboard가 설치하는 기본 지시문이 **Gemini Flash를 기본 워커로 못박아** 둡니다(설정으로 바꿀 수 없음). 구독이 없으면 이 위임은 항상 실패하고, 실패한 위임은 게이트를 열어주지 않습니다.
2. Codex에게 넘기면 일은 잘 끝나지만, switchboard 코드가 **Gemini 경로에만 영수증을 붙이도록** 되어 있어 게이트가 위임으로 인정하지 않습니다.
3. 손으로 설정을 고쳐도, switchboard는 **프로그램이 시작될 때마다 설정 파일을 다시 써서** 원래대로 돌려놓습니다.

자세한 추적 과정과 소스 코드 근거는 [사례 연구](docs/case-study.md)를 참고하세요.

---

## 이 킷이 하는 일

| 문제 | 해결 방법 | 사용한 수단 |
|---|---|---|
| 게이트가 계속 막음 | 차단 대신 기록만 하는 모드로 전환 | switchboard 공식 환경변수 `AGENT_BROKER_GATE_MODE=warn` |
| 없는 워커(Gemini)를 쓰라고 지시 | 실제로 가진 Claude·Codex 기준 지시문으로 교체 | 지시문 파일에 별도 구역으로 추가 |
| 재시작하면 지시문이 되살아남 | switchboard가 "사용자가 편집함"으로 판정해 건드리지 않도록 표식 조정 | switchboard 자체의 보호 규칙 |
| 재시작하면 롤 파일이 되돌아감 | switchboard가 "사용자 소유"로 판정하도록 파일 정리 | switchboard 자체의 보호 규칙 |
| 모델·effort를 한곳에서 못 바꿈 | `roles.json` → 롤 파일 자동 동기화 | 세션 시작 시 실행되는 동기화 스크립트 |

해킹이나 우회가 아니라, **switchboard 소스 코드에 이미 있는 설정과 보호 규칙만** 사용합니다.
실제 switchboard 코드(1.0.39, 1.0.47)로 설정 새로고침을 두 번 돌려 설치 결과가 한 바이트도 바뀌지 않는 것을 테스트로 확인합니다.

---

## 설치

### 1. 내려받기

```powershell
git clone https://github.com/<사용자명>/<저장소명>.git
cd <저장소명>
```

ZIP으로 받았다면 Windows가 인터넷에서 받은 스크립트를 막을 수 있으니 먼저 차단을 풀어주세요.

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
```

### 2. 무엇이 바뀌는지 미리 보기 (권장)

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
```

아무 파일도 바꾸지 않고 적용할 내용만 보여줍니다.

### 3. 설치

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

설치기는 건드리는 모든 파일을 먼저 `~\.claude\orchestration-backups\<날짜-시간>\`에 백업합니다.
여러 번 실행해도 결과는 같습니다. 끝나면 항목별 `[OK]` / `[FAIL]` 결과를 보여줍니다.

### 4. 프로그램 완전히 다시 시작하기 — 꼭 필요합니다

환경변수는 **새로 시작한 프로그램부터** 적용됩니다. VS Code, Claude Code, Codex를 모두 완전히 종료한 뒤 다시 여세요.
창만 닫으면 백그라운드에 남아 있을 수 있으니, 확실하지 않으면 작업 관리자에서 `Code.exe`가 없는지 확인하세요.

### 옵션

| 옵션 | 설명 |
|---|---|
| `-DryRun` | 아무것도 바꾸지 않고 계획만 출력 |
| `-Force` | 이미 있는 `roles.json`도 기본값으로 덮어쓰기. switchboard 실행 파일이 없어도 진행 |
| `-HomeDir <경로>` | 적용할 사용자 폴더 지정 (기본: 현재 사용자). 주로 테스트용 |
| `-SkipEnvVar` | 환경변수는 건드리지 않기. 주로 테스트용 |

---

## 사용법

### 역할과 모델 정하기 — `roles.json` 하나만 고치면 됩니다

파일 위치: `%USERPROFILE%\.claude\orchestration\roles.json`

역할은 네 가지입니다.

| 역할 | 하는 일 |
|---|---|
| `consultant` | 설계 검토, 어려운 문제 진단, 다른 시각의 2차 의견 |
| `implementer` | 승인된 계획대로 구현하고 테스트 |
| `reader` | 파일 읽기, 검색, 정보 추출 |
| `reviewer` | 코드 리뷰, 점검 |

`active_profile` 한 줄만 바꾸면 역할 배정이 통째로 바뀝니다.

| 프로필 | consultant | implementer | reader | reviewer | 이럴 때 |
|---|---|---|---|---|---|
| `claude-lead` (기본) | GPT (Sol) | Claude (Sonnet) | Claude (Haiku) | GPT (Terra) | Claude가 주도하고 GPT에게 반대 의견을 들을 때 |
| `codex-lead` | **Claude (Opus)** | **GPT (Terra)** | GPT (Luna) | Claude (Sonnet) | GPT가 코딩하고 Claude가 자문할 때 |
| `claude-only` | Claude (Opus) | Claude (Sonnet) | Claude (Haiku) | Claude (Sonnet) | ChatGPT 사용량을 아낄 때 |
| `codex-only` | GPT (Sol) | GPT (Terra) | GPT (Luna) | GPT (Terra) | Claude 사용량을 아낄 때 |

```json
{
  "active_profile": "codex-lead",
  "profiles": {
    "codex-lead": {
      "roles": {
        "consultant":  { "vendor": "claude", "model": "opus",          "effort": "max",    "mechanism": "native_subagent", "agent_type": "consultant" },
        "implementer": { "vendor": "codex",  "model": "gpt-5.6-terra", "effort": "medium", "mechanism": "route_agent_task" }
      }
    }
  }
}
```

세부 조정은 각 역할의 `model`과 `effort`를 직접 바꾸면 됩니다. 쓸 수 있는 값은 파일 안 `_valid_values`에 적혀 있습니다.

### 바꾼 내용이 적용되는 시점

- **새 세션을 시작하면 자동 적용**됩니다. 세션 시작 때 동기화 스크립트가 돕니다.
- 지금 열린 세션에 바로 반영하려면:

```powershell
& "$env:USERPROFILE\.claude\orchestration\sync-roles.ps1"          # 적용
& "$env:USERPROFILE\.claude\orchestration\sync-roles.ps1" -DryRun  # 미리 보기
```

> **왜 동기화가 필요한가요?**
> GPT에게 넘기는 일은 모델과 effort를 호출할 때 직접 전달하므로 `roles.json` 값이 바로 쓰입니다.
> 하지만 Claude 내부 워커를 부르는 기능에는 effort를 전달할 방법이 없고, 롤 파일에 적힌 값만 읽습니다.
> 그래서 `roles.json` 값을 롤 파일로 옮겨 적는 동기화 스크립트가 필요합니다.

### 프로젝트마다 다르게 쓰기

특정 프로젝트만 다른 구성을 쓰려면 그 프로젝트 폴더에 **점(.)으로 시작하는** 폴더를 만들어 두세요.

```
<프로젝트 폴더>\.orchestration\roles.json
```

이 파일이 있으면 전역 설정보다 우선합니다.

### 적용됐는지 확인하기

```powershell
# 1) 게이트 모드 — warn 이어야 합니다
[Environment]::GetEnvironmentVariable('AGENT_BROKER_GATE_MODE','User')

# 2) 롤 파일이 switchboard 관리에서 벗어났는지 — 전부 False 여야 합니다
Get-ChildItem "$env:USERPROFILE\.claude\agents\*.md", "$env:USERPROFILE\.codex\agents\*.toml" |
  ForEach-Object { "{0,-20} managed={1}" -f $_.Name,
    [bool](Select-String -Path $_.FullName -Pattern 'agent-switchboard:managed sha256' -Quiet) }
```

---

## 문제 해결

**Q.게이트가 여전히 막아요.**
프로그램을 완전히 다시 시작했는지 확인하세요. 환경변수는 이미 떠 있는 프로그램에는 적용되지 않습니다.
Claude Code 상태 표시에 `gate: warn`이 보이면 정상입니다.

**Q.설정이 재시작 후 되돌아간 것 같아요.**
세션 시작 때 동기화 스크립트가 자동으로 복구합니다. 위 "적용됐는지 확인하기"를 실행해 보고,
그래도 이상하면 `install.ps1`을 한 번 더 실행하세요. 여러 번 실행해도 안전합니다.

**Q.Codex에게 넘긴 일이 로그에 `no-credit`로 기록돼요.**
switchboard 쪽 버그입니다. 작업 자체는 정상이고, warn 모드에서는 아무 영향이 없습니다.

**Q.`agent-switchboard.exe --help`가 오류를 내요.**
한국어 Windows에서 출력이 파이프로 넘어갈 때 도움말 속 특수문자(긴 줄표)를 표시하지 못하는 switchboard 쪽 문제입니다.
`routing-override --help`처럼 하위 명령의 도움말은 정상입니다.

**Q."스크립트를 실행할 수 없습니다" 같은 실행 정책 오류가 나요."**
설치 명령처럼 `powershell -ExecutionPolicy Bypass -File ...` 형태로 실행하거나, 위의 `Unblock-File`을 먼저 실행하세요.

**Q.Codex를 브레인으로 써도 되나요?**
됩니다. 설치기가 Codex용 지시문(`~\.codex\AGENTS.md`)도 함께 설치합니다.
Codex 브레인에서는 GPT 워커가 내부 워커, Claude가 외부 위임 대상이 되도록 규칙이 반대로 적혀 있습니다.

---

## 제거

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

설치 전 백업을 기준으로 **이 킷이 넣은 부분만** 되돌립니다. 설치 후 여러분이 직접 추가한 지시문이나 설정은 그대로 둡니다.
직접 고친 `roles.json`은 지우지 않고 백업 폴더로 옮겨 둡니다.

---

## 알려진 한계

- **Windows 전용**입니다. macOS/Linux에서는 검증하지 않았습니다.
- warn 모드는 차단 대신 기록만 합니다. 즉 "위임을 강제하는" 규율은 꺼지고, 대신 지시문이 위임 원칙을 안내하는 방식입니다. 비용 관리를 엄격히 강제하고 싶다면 이 점을 고려하세요.
- Codex 위임의 영수증 누락은 switchboard 쪽 버그라 이 킷으로는 고칠 수 없습니다(1.0.47 기준 미수정). 기록 집계에만 영향이 있습니다.
- switchboard의 게이트 안내 문구는 여전히 Gemini Flash 위임을 권합니다. 프로그램 자체의 출력이라 바꿀 수 없으며, 설치된 지시문이 그 레인을 쓰지 말라고 안내합니다.
- 수치는 저자의 PC 한 대에서 측정한 결과입니다.

---

## 저장소 구성

```
├─ install.ps1              설치
├─ uninstall.ps1            제거
├─ scripts/sync-roles.ps1   roles.json → 롤 파일 동기화
├─ templates/               roles.json, 지시문, consultant 롤 원본
├─ tests/run-tests.ps1      가짜 사용자 폴더에서 설치·제거를 검증하는 테스트
├─ tests/interop/           실제 switchboard 코드로 "설치 결과를 건드리지 않음"을 확인하는 테스트
└─ docs/case-study.md       문제 추적과 개선 과정 상세
```

### 테스트 실행 (개발자용)

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

모든 테스트는 `%TEMP%` 아래 임시 폴더에서만 돌고, 실제 사용자 폴더와 환경변수는 건드리지 않습니다.
switchboard 원본 코드로 검증하는 상호운용 테스트는 [tests/interop](tests/interop/) 안내를 참고하세요.

---

## 라이선스와 출처

- 이 저장소의 킷 파일은 [MIT 라이선스](LICENSE)입니다.
- [agent-switchboard](https://github.com/FutureisinPast/mcp-agent-switchboard)는 FutureisinPast / ChartTrades의 저작물이며
  **PolyForm Noncommercial 1.0.0(비상업적 사용만 허용)** 라이선스입니다. 이 저장소는 switchboard 코드를 포함하지 않습니다.
  switchboard를 사용할 때는 해당 라이선스를 따라야 합니다.
- 문서 속 switchboard 소스 인용은 동작 설명을 위한 짧은 발췌입니다.
