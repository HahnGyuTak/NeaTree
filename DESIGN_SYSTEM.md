# SwiftUI Liquid Glass 디자인 시스템

`OrganizerDesignSystem`은 파일 처리 코드와 분리된 SwiftUI 라이브러리다. macOS 27 SDK로 빌드하며, macOS 26 이상에서는 native Liquid Glass를 사용하고 macOS 14–25에서는 재질 기반 대체 표현을 사용한다. 구버전 대체 표현은 네이티브 굴절과 동일하지 않다.

## 파일과 공개 컴포넌트

| 파일 | 제공 기능 |
| --- | --- |
| `Sources/OrganizerDesignSystem/LiquidGlassStyle.swift` | 재질·하이라이트·그림자·호버 ViewModifier, Color/Animation 확장, 버튼 스타일, 카드, GlassEffectContainer 래퍼 |
| `Sources/OrganizerDesignSystem/LiquidWindowControls.swift` | 투명한 신호등, 호버 시 색상·광택·아이콘, 실제 호스팅 창 동작, 커스텀 타이틀바 적용·복원 |
| `Sources/OrganizerDesignSystem/LiquidSidebar.swift` | 창 뒤 재질을 반영하는 사이드바, 선택·호버 matched geometry, 메인 콘텐츠 레이아웃 |
| `Sources/OrganizerDesignPreview/main.swift` | 샘플 파일만 사용하는 독립 실행 미리보기 |

## 재질·버튼·카드

```swift
import SwiftUI
import OrganizerDesignSystem

struct ProposalCard: View {
    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            VStack(spacing: 20) {
                LiquidGlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("정리 제안").font(.headline)
                        Text("문서 / 프로젝트 / 견적서")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("적용") { /* 검토된 작업 실행 */ }
                    .buttonStyle(LiquidGlassButtonStyle())
            }
        }
    }
}
```

임의 뷰에는 `.liquidGlass(cornerRadius: 14, tint: nil)`과 `.liquidHoverEffect()`를 적용한다. 테두리·그림자만 필요할 때는 `LiquidGlassHighlight`와 `LiquidGlassShadow` modifier를 개별 적용한다. 주변 glass 요소는 하나의 `LiquidGlassGroup`으로 묶고, 정지 상태에서 합쳐지지 않아야 하는 요소의 실제 간격보다 작은 `spacing`을 지정한다.

`Color.liquidGlassHighlight`, `.liquidGlassShadow`, `.liquidGlassSurface`와 `Animation.liquidHover`, `.liquidSelection`, `.liquidReveal`을 공통 토큰으로 제공한다. 직접 애니메이션 토큰을 사용할 때는 호출 뷰에서도 `accessibilityReduceMotion`을 확인한다. 제공 컴포넌트는 시스템의 동작 줄이기·투명도 줄이기·대비 증가 환경값을 읽는다.

## 신호등과 타이틀바

```swift
VStack(spacing: 0) {
    HStack {
        LiquidWindowControls()
        Text("파일 정리")
        Spacer()
    }
    .padding(.horizontal, 16)
    .frame(height: 52)

    // 사이드바와 메인 콘텐츠
}
.liquidCustomTitlebar()
```

`.liquidCustomTitlebar()`는 해당 창에만 명시적으로 적용한다. 네이티브 신호등을 숨기고 전체 크기 콘텐츠·투명 타이틀바를 설정하며, 뷰가 제거되면 변경 전 창 설정을 복원한다. 기본 `LiquidWindowControls()`는 자신이 속한 NSWindow를 약하게 참조한다. 전역 `keyWindow`를 사용하지 않는다.

닫기와 최소화는 해당 창의 `performClose`·`performMiniaturize`, +는 `performZoom`으로 확대/복원을 수행한다. 전체 화면 동작을 원하면 `onClose:onMinimize:onZoom:` 콜백 초기화로 별도 연결한다. 콜백에서 창을 캡처할 때는 `[weak window]`를 사용한다. 기본 컴포넌트는 창의 버튼 활성 상태와 창 스타일을 확인한다. Apple의 초록 버튼 메뉴·타일링 등 전체 시스템 동작을 복제한 컴포넌트는 아니다.

## 사이드바와 메인 레이아웃

```swift
@State private var selection: String? = "review"

let items = [
    LiquidSidebarItem(id: "review", title: "검토함", systemImage: "tray", count: 3),
    LiquidSidebarItem(id: "held", title: "보류", systemImage: "pause.circle")
]

// View.body 안에서 사용
LiquidSidebarLayout(items: items, selection: $selection) {
    ProposalCard().padding(24)
}
```

창 뒤 바탕화면 또는 다른 배경 색이 실제로 반영되려면 호스팅 `NSWindow`에 `isOpaque = false`, `backgroundColor = .clear`를 설정하고, 사이드바 뒤에 불투명 배경을 넣지 않아야 한다. 사이드바는 `.sidebar`/`.behindWindow` AppKit 재질을 사용하고, 선택 하이라이트에는 native glass를 적용한다. 전체 화면·배경·접근성 설정에 따라 실제 투명도는 달라진다.

## 독립 미리보기 실행

현재 맥에서 빌드한 앱은 `preview/Liquid Glass Preview.app`이다. Finder에서 열어 바로 컴포넌트를 검토할 수 있다. 개발용 로컬 빌드이며, 배포용 서명·공증을 진행한 앱은 아니다.

프로젝트 폴더에서 실행한다.

```sh
swift run organizer-design-preview
swift run organizer-design-preview --dark
```

미리보기는 코어를 참조하지 않고 샘플 문서로만 동작한다. 신호등 호버, 사이드바 선택·호버, 버튼 누름, 창 닫기·최소화·확대를 확인할 수 있다. 앱의 실제 다운로드 감시나 API 요청은 시작하지 않는다.

`--snapshot /절대/경로/preview.png`는 자체 뷰의 정적 이미지를 저장하고 종료한다. macOS가 창 합성 단계에서 처리하는 실제 배경·굴절은 정적 뷰 캡처에 완전히 담기지 않을 수 있으므로 재질과 모션의 최종 확인은 실행 미리보기로 한다.

실제 파일 정리 앱에 디자인을 적용하기 전에는 사용자에게 이미지 시안을 보여주고 승인을 받는다. 컴포넌트 코드 요청을 전체 화면 디자인 승인으로 취급하지 않는다.

## 확인한 범위

2026-11-11 macOS 27.2 SDK와 Swift 6.4.2로 디자인 라이브러리·미리보기 실행 파일의 빌드를 확인했다. 실제 미리보기에서 선택 행의 글자·아이콘 가독성, 사이드바 선택 변경, 적용·취소 샘플 동작, 해당 창의 닫기와 확대/복원을 확인했다. 배경 도형에만 glass를 적용했을 때 글자가 가려지던 문제는 행 전체를 glass의 전경 콘텐츠로 전달하도록 수정했다.

정적인 화면만으로 스프링의 질감, 호버 시 색상 전환, 바탕화면에 따른 재질 변화까지 최종 승인한 것으로 취급하지 않는다. 해당 모션과 시스템 접근성 설정별 표현은 사용자 검수 시 실제 미리보기에서 확인한다. 이전 OS의 재질 대체 분기는 빌드에 포함되어 있지만 해당 OS에서 별도로 실행하지 않았다.
