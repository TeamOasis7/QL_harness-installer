# QL Harness 개인용 설치

Windows PowerShell에서 한 줄로 설치한다.

```powershell
irm https://raw.githubusercontent.com/TeamOasis7/QL_harness-installer/main/install.ps1 | iex
```

설치 위치는 `%LOCALAPPDATA%\Programs\QLHarness`이며 바탕화면에 QL Harness 바로가기를 만든다. 같은 명령을 다시 실행하면 기존 설치를 확인하고 갱신한다.

Git·Rust·Node·Python은 필요하지 않다. GitHub CLI가 없으면 공식 portable 배포본을 checksum 검증 후 설치 폴더 안에 준비한다.

프로그램과 소스 저장소는 비공개다. 다운로드 단계에서 해당 저장소 접근 권한이 있는 GitHub 계정의 인증이 필요하다. 최초 인증 화면과 기기 코드 안내에 따라 본인이 로그인한다.

이 공개 저장소에는 설치 스크립트와 이 안내만 있다. 프로그램 실행파일·프로젝트 소스·인증 정보는 포함하지 않는다.
