# Windows 학업 작업실

`study_hub.py`는 Windows 10/11에서 Python 3.11 이상으로 실행하는 학업 중심 앱입니다.
표준 라이브러리만 사용합니다. macOS 앱과 같은 저장소에 있지만, 현재 제공 기능은
**eTL 과제·마감 조회, 과제 원문 열기, 붙여 넣은 학업 내용의 AI 정리**입니다.
Mac 전용 메시지·캘린더 통합, 녹음·전사, 문서·미디어 도구는 아직 Windows판에 없습니다.

```powershell
py -3 windows\study_hub.py
```

학교 eTL의 Canvas API 토큰을 `과제와 마감` 탭에 넣으면 수강 중인 과제의 정확한
마감과 제출 종료 시각을 읽습니다. 토큰은 저장하지 않습니다. AI 정리는 기본값인
로컬 Ollama 또는 설정한 OpenAI 호환 API를 사용합니다. API 키도 저장하지 않습니다.
외부 API를 선택하면 입력창의 텍스트가 해당 주소로 전송됩니다. ChatGPT Edu 계정과
API 사용 권한·과금은 별개이므로 이용 가능 여부를 먼저 확인하세요.

GitHub Actions의 `windows-study-hub` 워크플로는 Windows에서 테스트한 뒤
PyInstaller로 `SNUStudyHub.exe`를 만들어 Actions artifact에 올립니다.
Windows 실행 파일을 최종 릴리스하기 전에는 실제 Windows PC에서 eTL 로그인,
한글 표시, 로컬 Ollama와 API 연결을 확인해야 합니다.

[Windows 자동 빌드 산출물](https://github.com/sesepark/snu-local-agent/actions/workflows/windows-study-hub.yml)에서 최근 성공한 실행의 `SNUStudyHub-Windows`를 내려받을 수 있습니다.
