이 관리 블록은 switchboard-kit이 의도적으로 비워 두었습니다.

agent-switchboard가 이 자리에 넣는 기본 라우팅 정책은 이 환경에 없는 Gemini/Antigravity 레인을 기본 작업 레인으로 지정합니다. 그 지시를 따르면 매번 실패할 디스패치를 먼저 시도하게 됩니다.

유효한 정책은 switchboard-kit 정책 블록에 있습니다. Claude는 `%USERPROFILE%\.claude\CLAUDE.md`, Codex는 `%USERPROFILE%\.codex\AGENTS.md`의 맨 위를 보세요.

시작 표식의 체크섬은 일부러 0으로 채웠습니다. 체크섬이 본문과 맞지 않으므로 agent-switchboard는 이 블록을 사용자 수정본으로 판단하고 덮어쓰지 않습니다. 이 블록을 지우지 마세요. 블록이 사라지면 agent-switchboard가 다음 실행 때 원래 정책을 다시 추가합니다.

원래 상태로 되돌리려면 키트의 uninstall.ps1을 실행하세요.
