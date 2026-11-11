# 승인된 v7 뿔 — 앱·메뉴바 아이콘

2026-11-12 사용자가 [v7 정면](../../assets/psilo/review-v7-plump-horns/front.png)과 [사선](../../assets/psilo/review-v7-plump-horns/left.png)의 뿔을 확정하고 두 아이콘에도 반영하도록 요청했다. 짧고 통통한 원뿔, 넓게 둥근 끝, 갓 기울기에 맞춘 방향과 완전히 붙은 밑동을 기준으로 삼았다. 캐릭터 전체 모델·모션의 최종 승인으로 확대하지 않는다.

## 반영 결과

- 앱 아이콘의 `Character.png`를 수정했다. 뿔 외의 모자·얼굴·갓·몸통은 기존 원화의 구성을 유지한다. 내장 `image_gen`으로 뿔 이전, 크기 보정, 투명 가장자리 정리를 수행한 뒤 macOS `sips`로 1024×1024에 균일 리샘플링했다.
- `Files.png`와 `icon.json`은 해시가 동일하다. 유리 배경·캐릭터·파일 더미가 분리된 네이티브 레이어 문서를 유지한다.
- 메뉴바는 모자·얼굴·반점 없는 버섯 갓과 문서 심볼을 유지하면서 뿔을 통통하고 둥글게 바꿨다. 첫 후보는 갓·문서 비율이 달라 폐기했고, 원본 심볼이 선명한 참조를 이용한 두 번째 후보를 적용했다.
- 생성형 래스터 편집이므로 뿔 외 영역의 모든 픽셀이 동일하다는 뜻은 아니다. 별도 파일 더미 레이어와 Icon Composer 문서의 보존은 바이트 단위로 확인했다.

## 검증

- Apple `actool`로 Default, Dark Aqua, Tintable 각각 **3개 레이어**의 `IconImageStack`을 컴파일했다. 개발용 ICNS도 다시 생성해 앱 리소스에 반영했다.
- Icon Composer의 실제 macOS 27 렌더러로 기본·다크 모드의 512px와 64px 표시를 확인했다. 뿔의 둥근 끝과 모자와의 구분, 가장자리와 작은 크기 가독성을 검토했다.
- 메뉴바 18×18·36×36 템플릿을 다시 출력했다. 알파 0–1과 검은색 실루엣을 확인하고 밝은·어두운 배경에서 기본 문서 형태가 읽히는지 확인했다.
- Debug 개발 앱 0.1.0-b9를 빌드·패키징하고 ad-hoc 서명을 검증했다. 앱 번들의 메뉴바 이미지·ICNS와 소스 리소스의 SHA256이 모두 일치한다. [패키지 검증](../../assets/icons/v7-horns-package-verification.json). 로컬 개발 빌드이며 공증·GitHub 공개 배포를 수행한 것은 아니다.

[앱 아이콘 기본 모드](icons-v7-horns-default.png) · [다크 모드](icons-v7-horns-dark.png) · [메뉴바 표시](menu-v7-horns-light-dark.png)

정확한 프롬프트와 소스·출력 해시는 [앱 생성 기록](../../assets/icons/app-icon-v7-horns-generation.json), [앱 검증](../../assets/icons/app-icon-v7-horns-verification.json), [메뉴 생성 기록](../../assets/icons/menu-v7-horns-generation.json), [메뉴 검증](../../assets/icons/menu-v7-horns-verification.json)에 보존한다. 내장 이미지 도구를 사용했으며 별도 API 키로 외부 이미지 생성 요청을 보내지 않았다.
