# NeaTree GitHub Releases 배포

NeaTree(Neat + Tree)는 Mac App Store 대신 이 저장소의 [GitHub Releases](https://github.com/HahnGyuTak/NeaTree/releases)에서 제공한다. 사용자는 ZIP을 풀거나 DMG를 열고 `NeaTree.app`을 응용 프로그램 폴더에 복사한다. DMG는 앱과 `/Applications` 링크만 포함하는 기본 구성이며 별도 시각 디자인을 추가하지 않는다. 앱의 번들 ID는 `io.github.HahnGyuTak.NeaTree`다.

## 빌드 종류

| 종류 | 용도 | 표시 |
| --- | --- | --- |
| Ad-hoc 서명 | 현재 맥의 개발·검수 | 파일명에 `-development`, 공증되지 않음 |
| 일반 서명, 공증 전 | 서명 작업 중간 확인 | 파일명에 `-unnotarized`, 릴리스 업로드 거절 |
| Developer ID + Hardened Runtime + 공증 + staple | 사용자 배포 후보 | 공증 검증 후에만 릴리스 **초안** 생성 가능 |

공증은 App Store 심사와 별개이며 직접 배포에도 사용할 수 있다. Apple은 Developer ID로 서명하고 Hardened Runtime·타임스탬프를 갖춘 소프트웨어를 `notarytool`로 제출하는 절차를 제공한다. [Apple 공증 안내](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [커스텀 공증 절차](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

현재 코드는 macOS 14 이상을 대상으로 한다. Liquid Glass 컴파일에는 Xcode 26 이상이 필요하며 macOS 14–25 실행에서는 대체 재질을 사용한다. 기본 로컬 패키지는 현재 맥의 아키텍처를 사용한다. 배포 워크플로는 Apple Silicon·Intel을 담은 universal 실행 파일을 빌드한다. 빌드 성공이 모든 지원 OS의 실제 사용 검증을 대신하지는 않는다.

## 로컬 개발 앱 만들기

저장소 루트에서 실행한다. 이 명령은 실제 사용자 파일을 읽거나 API를 호출하지 않고 소스만 빌드한다.

```sh
scripts/pack-app.sh --version 0.1.0 --configuration debug --no-dmg
```

기본 결과는 `dist/NeaTree-0.1.0-b1-macos-arm64-development/`처럼 버전·빌드 번호·아키텍처가 포함된 폴더다. 해당 폴더에는 앱 번들, ZIP, `build-metadata.json`, `SHA256SUMS`가 들어간다. `--no-dmg`를 빼면 DMG도 만든다. 같은 결과 폴더가 있으면 덮어쓰지 않고 중단하므로 `--build-number 2` 또는 별도 `--output-dir`을 사용한다.

내부 Swift 실행 파일 이름은 `file-organizer`다. 이미 빌드한 실행 파일을 묶을 때는 다음처럼 지정한다.

```sh
scripts/pack-app.sh --configuration debug --version 0.1.0 --no-dmg \
  --binary /빌드/결과/file-organizer --output-dir /패키지/출력
```

이미 별도의 샌드박스 안에서 실행 중인 개발 환경은 필요할 때 `--disable-manifest-sandbox`를 지정할 수 있다. 이는 SwiftPM의 중첩 manifest sandbox 옵션이며, 앱의 보안 기능이나 macOS Gatekeeper를 끄는 옵션이 아니다. 빌드 캐시 위치는 `--scratch-path`로 바꾼다.

## CI

`NeaTree build and test`는 `main` push와 pull request에서 테스트·앱 빌드·개발용 ZIP 패키징을 실행한다. 자동 결과는 Actions의 `NeaTree-macOS-development-build` 아티팩트이며 GitHub Release에 자동 게시하지 않는다. ZIP 내부에서 실행 권한을 보존하므로 앱 폴더를 그대로 Actions에 업로드하지 않는다.

공식 runner 목록과 설치 소프트웨어에서 `macos-26` arm64 및 Xcode 26을 확인해 해당 runner를 사용한다. `macos-27`이라는 확인되지 않은 runner 이름은 사용하지 않는다. 워크플로 시작 시 선택된 SDK가 26 이상인지 검사한다. [GitHub runner 표](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [macOS 26 설치 도구](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)

## 서명된 릴리스 초안 만들기

유효한 Apple Developer ID Application 인증서와 Apple 공증 자격 증명이 필요하다. 인증서 발급이나 계정 등록을 자동으로 수행하지 않는다. 다음 값은 GitHub 저장소의 Actions secrets에 직접 설정하고 소스·문서·이슈에 넣지 않는다.

| Actions secret | 내용 |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | 개인 키를 포함한 Developer ID Application `.p12`의 한 줄 base64 |
| `MACOS_CERTIFICATE_PASSWORD` | `.p12` 내보내기 암호 |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: … (…)` 형식의 인증서 표시 이름 |
| `APPLE_ID` | 공증에 사용할 Apple 계정 |
| `APPLE_APP_SPECIFIC_PASSWORD` | 해당 계정의 앱 암호 |
| `APPLE_TEAM_ID` | 인증서와 일치하는 Developer Team ID |

Actions에서 **Prepare NeaTree signed release draft**를 선택하고 `main` 브랜치와 `0.1.0` 같은 버전을 지정한다. 워크플로는 테스트 후 일회용 키체인에 인증서를 가져와 universal 앱에 서명한다. 앱을 공증·staple한 뒤 최종 ZIP을 만들고, DMG도 별도로 서명·공증·staple한다. 작업 종료 시 일회용 키체인과 인증서 파일은 삭제한다. GitHub에 전달하는 토큰은 내장 `GITHUB_TOKEN`이다.

이 워크플로에는 태그 push 자동 실행이나 자동 공개 단계가 없다. 결과는 기본적으로 prerelease로 표시된 **draft**다. 다운로드·설치·파일 작업·되돌리기·권한 요청·분류 품질을 확인하고 릴리스 노트를 검토한 뒤 GitHub에서 직접 공개한다. 서명 자격 증명이 없거나 공증에 실패하면 개발 빌드로 몰래 대체하지 않고 중단한다.

로컬에서 이미 인증서와 notarytool keychain profile을 준비했다면 다음과 같이 사용할 수 있다.

```sh
SIGNING_IDENTITY='Developer ID Application: 개발자 이름 (TEAMID)' \
NOTARY_PROFILE='neatree-notary' \
scripts/pack-app.sh --version 0.1.0 --build-number 1 --arch universal --notarize

GH_REPO='HahnGyuTak/NeaTree' \
scripts/release.sh dist/NeaTree-0.1.0-b1-macos-universal
```

로컬 `pack-app.sh`는 인증서나 keychain profile을 생성하지 않는다. 공증된 릴리스는 커밋된 깨끗한 소스에서만 만들 수 있고, 업로드 시 체크아웃과 패키지의 커밋이 일치해야 한다. 기존 릴리스를 덮어쓰지 않는다. API 키·사용자 설정·개인 파일·디자인 미리보기 앱·테스트 실행 파일은 앱 번들에 포함하지 않는다.

## 공개 전 확인

- `SHA256SUMS`와 최종 ZIP·DMG가 일치하는지 확인한다.
- 인터넷으로 내려받은 파일에서 설치와 첫 실행을 확인한다. 로컬에서만 실행한 결과로 Gatekeeper 동작을 판단하지 않는다.
- 릴리스 설명에 버전, 지원 OS·아키텍처, 알려진 제한, 모델 API 사용 및 전송 범위를 적는다.
- 처음에는 prerelease로 배포하고 대표 파일의 실제 분류 품질까지 확인한 후 안정 버전으로 전환한다.

배포 스크립트와 워크플로를 준비한 사실은 서명·공증·공개 배포를 이미 완료했다는 뜻이 아니다.
