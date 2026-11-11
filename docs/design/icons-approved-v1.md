# NeaTree 아이콘 확정 시안 v1

2026-11-11 사용자가 [이 시안](icons-approved-v1.png)을 확정하고 실제 앱·메뉴막대 아이콘에 적용하도록 승인했다.

- 앱 아이콘: 반투명 유리 타일, 뭉툭한 뿔과 정원사 모자를 쓴 독버섯 캐릭터, 파일·폴더 더미.
- 메뉴막대: 표정과 모자를 제외한 버섯 머리가 문서 윗부분을 덮는 단색 템플릿 심볼.
- 메뉴막대는 macOS의 템플릿 렌더링으로 밝은 배경과 어두운 배경에 대응하며, 대기 개수는 별도 텍스트로 표시한다.

사용자의 후속 요청에 따라 앱 아이콘은 단일 합성 이미지 대신 **Icon Composer 레이어 문서**인 `assets/icons/AppIcon.icon`으로 구성한다. 유리 배경, 파일·폴더 더미와 캐릭터의 깊이를 분리하고, 유리 재질과 렌더링은 Icon Composer 설정에 보존한다. 표준 PNG 미리보기는 검수·참고용이며 실제 레이어 문서를 대신하지 않는다.

`Sources/OrganizerApp/Resources/`에는 메뉴막대의 `MenuBarTemplate.png`(18×18)와 `MenuBarTemplate@2x.png`(36×36)를 둔다. 맨 실행 파일을 `swift run`으로 실행할 때의 `AppIcon.icns`는 개발용 대체 아이콘이다. 앱 번들의 Finder·Dock 아이콘에는 아래의 컴파일 결과를 사용한다.

```sh
scripts/compile-app-icon.sh work/icon-compiled
```

출력 폴더는 새 폴더여야 한다. Apple `actool`은 `AppIcon.icon`에서 레이어를 담은 `Assets.car`, 이전 지원 OS용 `AppIcon.icns`, 아이콘 이름을 기록한 `icon-info.plist`를 생성한다. 스크립트는 `assetutil` 결과를 `icon-assets.json`으로 남기고, 컴파일된 `AppIcon`의 `IconImageStack`이 복수 레이어를 유지하는지 확인한다. `scripts/pack-app.sh`는 이 컴파일을 자동 실행해 CAR·ICNS를 `Contents/Resources`에 넣고, 부분 plist를 실제 `Info.plist`에 병합한다. `CFBundleIconName`은 `AppIcon`이며 `CFBundleIconFile`도 컴파일 결과에 따른다. macOS 14 최소 지원을 유지한다. [Apple Icon Composer 안내](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

같은 빌드의 `NeaTree_OrganizerApp.bundle`도 앱의 `Contents/Resources`에 복사한다. 개발용 패키징도 이 경로를 사용하며, 서명·공증 여부는 아이콘 적용과 별개로 [배포 문서](../DISTRIBUTION.md)의 검증 결과를 따른다.
