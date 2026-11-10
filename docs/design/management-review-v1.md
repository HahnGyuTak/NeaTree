# 추가 기능 화면 시안 v1

- 상태: 2026-11-11 이미지 표시 후 사용자 검수 대기
- 이미지: `management-review-v1.png`
- 범위: 규칙 편집·삭제, 감시 제외, 다중 선택 일괄 검토, Quick Look 원본 미리보기
- 기존 NeaTree 창·Liquid Glass 컴포넌트를 유지하며 새 장식이나 강조색을 추가하지 않는다.
- 생성: 내장 image_gen. 최초 생성 뒤 파란 강조와 불필요한 도구 막대 아이콘을 제거하는 편집을 적용했다.

## 생성 프롬프트

```text
Use case: ui-mockup. Create one high-fidelity UI review board for NeaTree, native macOS file organizer, with four distinct macOS window crops in a clear 2 by 2 grid on a clean warm-neutral background. Sharp Korean UI typography. This is an image design proposal, not a screenshot. Preserve a restrained Finder layout and neutral Liquid Glass materials: softly translucent light gray sidebar and toolbar, white reading area, fine clear glass edges only, subtle shadows, monochrome SF-symbol-like icons. No arbitrary accent colors, blue selected rows, decorative borders, marketing logos, illustrations, or gradients. Small transparent traffic lights at top left. App title exactly "NeaTree". Panels labeled discreetly outside windows: "1. 규칙 편집", "2. 감시 제외", "3. 일괄 검토", "4. 원본 미리보기".
Panel 1: existing Finder sidebar items 검토함, 미분류, 보류, 정리 이력, 분류 규칙; main heading 분류 규칙, simple rows of confirmed folder rules with small "편집" and "삭제" buttons and top "규칙 추가". Show a native compact sheet over this window titled "규칙 편집", folder dropdown "문서 › 01_프로젝트", multiline instruction editor containing "견적서는 날짜_프로젝트_견적서 형식으로 저장", bottom "취소" and "저장". No card decoration beyond existing gentle glass control materials.
Panel 2: native settings sheet titled "설정" showing section "감시 제외". Two stacked ordinary text fields with labels "제외할 확장자" value "dmg, zip" and "제외할 다운로드 하위 폴더" value "임시자료". Small gray hint "직접 가져온 파일은 제외 규칙과 관계없이 검토합니다." and right aligned "제외 설정 저장". Include small section "백그라운드" with normal switches "다운로드 폴더 감시", "새 파일 자동 분석", no new design motif.
Panel 3: same Finder sidebar, file list with three rows and two subtle neutral selections, heading "2개 선택". Right review area shows editable row per file with two text fields labels "이름" and "위치"; sample "견적서.txt", "회의록.md", destination "문서 › 01_프로젝트". Plain top common-folder picker label "선택한 파일의 위치"; lower buttons "선택 보류", "미분류로 보내기", "검토 후 적용". A small neutral result line below "항목별 결과를 확인할 수 있습니다." Keep names individually editable and all actions simple native buttons. No automatic apply or promotional text.
Panel 4: normal single-file review area with filename, proposed name and destination, small "원본 미리보기" button beside "Finder에서 보기", and a macOS Quick Look-style sheet showing an ordinary document preview. A tiny lower text line "기기의 OCR로 읽은 텍스트" below a text excerpt. Native preview close affordance, no custom graphic style.
Composition: four panels equally sized and readable, generous gutters, concise text, wide landscape board about 2048x1536 or larger, enough pixels for Korean text. Show realistic desktop application UI, not browser chrome.
```

## 수정 프롬프트

```text
Edit the provided NeaTree UI review board only. Preserve all four panels, Korean text, layouts, document content, neutral Liquid Glass materials and panel headings. Change every saturated blue primary button, selected list highlight, and toggle into a restrained neutral gray system-style active state with clear dark text or white knob. No blue or other saturated accent anywhere. Also remove the unused back/forward chevrons and list/grid view mode buttons from all four titlebars, leaving NeaTree title on left and search on right. Do not introduce any other controls or content. Make selected rows distinct with neutral gray translucency. Keep readable sharp typography and the same four-panel composition.
```
