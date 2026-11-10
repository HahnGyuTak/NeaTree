# File Organizer

다운로드한 파일과 폴더의 내용을 살펴보고, 기존 폴더 구조와 명명 규칙에 맞는 이름·위치를 제안하는 macOS 앱입니다. 사용자가 검토하고 적용할 때 파일을 이동하며, 미분류·보류·이력·되돌리기를 지원합니다.

현재 Swift 파일 관리 코어와 Liquid Glass 디자인 시스템을 바탕으로 본창·메뉴바 앱을 개발 중입니다. 배포 채널은 **GitHub Releases**이며, App Store 배포를 사용하지 않습니다. 아직 정식 배포 버전은 없습니다.

## 주요 동작

- 지정 폴더의 구조·파일명 사례를 분석하고 분류 규칙 후보를 확인합니다.
- 다운로드 완료를 감지하거나 사용자가 가져온 파일·폴더를 검토함에 넣습니다.
- GPT 분석이 제안한 이름·폴더를 수정한 뒤 적용합니다. 번호는 적용 시 충돌을 확인하고 배정합니다.
- 애매한 자료는 `다운로드/미분류`로 보내거나 원래 위치에 보류합니다.
- 메뉴바에서 대기 중인 제안을 확인하고, 본창에서 미리보기·규칙·이력을 검토합니다.
- 원본 변경과 경로 이탈을 검사하고 기존 파일을 덮어쓰지 않습니다.

## 개발

macOS 14 이상, Swift 6과 Xcode 26 이상이 필요합니다. macOS 26 이상에서는 네이티브 Liquid Glass를 사용하고, 이전 버전은 재질 기반 대체 표현을 사용합니다.

```sh
swift build
swift test
swift run organizer help
swift run organizer-design-preview
```

API 분석에는 사용자의 OpenAI API 키가 필요합니다. 키는 macOS 키체인에 저장합니다. 폴더 선택·파일 가져오기만으로 API에 자료를 전송하지 않으며, 분석을 요청하거나 자동 분석을 켰을 때 선택한 범위의 파일명·경로·추출 내용이 전송됩니다.

## 문서

- [기획안](docs/PLAN.md)
- [디자인 요구사항](DESIGN_REQUIREMENTS.md)
- [SwiftUI 디자인 시스템](DESIGN_SYSTEM.md)
- [파일 관리 코어와 CLI](docs/CORE_USAGE.md)
- [다운로드 및 배포](https://github.com/HahnGyuTak/mac-file-organizer/releases)

현재 코어는 동일 볼륨의 일반 파일·폴더 이동을 지원합니다. 큰 파일 검사 한도, 텍스트·PDF 추출 범위와 아직 구현하지 않은 파일 형식은 코어 문서에 기록되어 있습니다.
