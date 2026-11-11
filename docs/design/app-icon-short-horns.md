# 실로 짧은 뿔 — 앱 아이콘 반영

2026-11-11 사용자가 짧고 통통하며 끝만 살짝 뾰족한 뿔 시안을 “오케이”로 확정했다. 승인된 캐릭터 이미지를 기존 Icon Composer의 `Character.png` 레이어에 반영했다.

- 승인 이미지를 1254×1254에서 1024×1024로 macOS `sips`를 사용해 균일 리샘플링했다. 새 이미지를 생성하거나 뿔을 다시 그리지 않았다.
- 기존 레이어와 같은 전체 캔버스 배치를 유지했다. 알파 16 초과 영역은 기존 `(26,94)–(998,758)`에서 `(25,93)–(999,759)`로, 리샘플링에 따른 약 1px 차이다.
- 별도 파일·폴더 레이어 `Files.png`와 유리 배경·그룹 설정 `icon.json`은 바이트 단위로 동일하다.
- Apple `actool`로 컴파일한 Default, Dark Aqua, Tintable `IconImageStack`이 각각 3개 레이어를 유지하는지 확인했다.
- 컴파일 결과의 `AppIcon.icns`를 개발용 리소스에 반영했다. 앱 패키지는 기존 빌드 스크립트로 `.icon`을 다시 컴파일해 `Assets.car`와 ICNS를 포함한다.

실제 Icon Composer 렌더인 [기본 모드](icons-short-horns-default.png)와 [다크 모드](icons-short-horns-dark.png)를 확인했다. 별도 64px 기본 모드 렌더에서도 캐릭터와 짧은 뿔이 잘리거나 파일 더미에 가리지 않는지 확인했다.

레이어 크기·알파·컴파일 스택·원본 해시는 [검증 기록](../../assets/icons/app-icon-short-horns-verification.json)에 보존한다. 이 문서는 앱 아이콘의 자산·컴파일 검증이며, 메뉴막대와 3D 모델 또는 전체 앱 실행 검증을 대신하지 않는다.
