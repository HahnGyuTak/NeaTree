# 실로(Psilo) 3D 자산

NeaTree의 파일 정리 도우미다. 넓고 낮은 산호색 버섯 갓과 세 개의 아이보리 반점, 뭉툭한 큰 뿔 두 개, 정원사 모자, 작은 점 눈과 타원 입을 유지한다. 작업할 때 안경과 파일이 등장하고, 완료·오류 표정은 별도 부위로 움직인다.

최신 제작용 모델은 [v7 통통한 뿔 검수본](review-v7-plump-horns/README.md)이다. [v6](review-v6-fidelity/README.md)에서 갓·몸통·얼굴 접합·재질·뿔 부착을 수정한 뒤, 뿔이 작고 뾰족하다는 후속 피드백에 따라 원형 단면·밑면 전체 매립을 유지하면서 크기와 끝의 둥글기를 늘렸다. 2026-11-12 최신 모델의 앱 반영 요청에 따라 전체 v7을 경량화·베이크하고 연속 표정 변형을 연결했다. 실제 앱 리소스는 [runtime-v7/Psilo.usdz](runtime-v7/README.md)이며, 아래 `blender/` 파일은 초기 제작·MCP 편집 기록이다. 전체 외형·모션의 최종 사용자 품질 승인은 별도다.

## 파일

| 파일 | 용도 |
| --- | --- |
| `blender/Psilo-MCP.blend` | Blender MCP에서 실제 장면을 편집하고 작업·완료·오류·복귀의 미리보기 키프레임을 추가한 원본. 텍스처가 패킹되어 있다. |
| `blender/Psilo.blend` | 앱용 중립 모델을 제작한 Blender 원본. 일반 Blender Z-up 장면과 편집 가능한 부위·모디파이어를 보존한다. |
| `blender/Psilo.usdz` | 초기 모델의 중립 포즈 내보내기. 최신 앱 자산은 `runtime-v7/Psilo.usdz`다. |
| `runtime-v7/Psilo.usdz` | 최신 전체 v7의 앱용 중립 모델. 베이크 재질·4개 표정 채널·macOS 14 호환 데이터를 포함한다. |
| `blender/Psilo-cap-color.png` | 갓 표면의 반점과 미세한 색감을 담은 유일한 768×768 텍스처. |
| `blender/Psilo-front.png`, `blender/Psilo-three-quarter.png` | Blender 스튜디오 조명의 정면·사선 검토 이미지. 앱 렌더링의 조명이나 그림자와 다를 수 있다. |
| `blender/model-metrics.json` | 내보낸 앱 모델의 규모. |
| `../../Sources/OrganizerApp/Resources/Psilo.usdz` | 앱에 실제 번들링하는 모델. 검증한 중립 USDZ와 동일하게 유지한다. |
| `../../scripts/blender-psilo.py` | Blender `bpy`로 메시·곡선·재질·UV·스튜디오 장면을 제작하고 USDZ로 내보내는 보조 스크립트. |

MCP 원본의 미리보기 프레임에는 비행 중인 파일 위치가 포함된다. 그 프레임을 앱의 중립 포즈로 바로 내보내지 않는다. 앱은 중립 파일 위치를 도착점으로 기억하므로, 재출력할 때 파일 세 개의 도착 위치와 부위별 로컬 축을 유지해야 한다.

## 제작 방식

Blender 5.3에서 실제 편집 가능한 3D 장면을 제작했다. `bpy` 보조 스크립트로 형태와 재질을 구성했으며, 이후 Blender MCP로 실행 중인 장면 조회, 키프레임·포즈 편집, 프레임 미리보기와 저장을 수행했다. 이전 USD 프로토타입을 가져온 모델이나 미리 렌더링한 평면 캐릭터가 아니다. 외부 유료 모델 생성이나 에셋 생성 서비스는 사용하지 않았다.

MCP 연결은 제삼자 프로젝트 [mcp-for-blender](https://github.com/ahujasid/mcp-for-blender)의 애드온과 stdio 서버를 통해 확인했다. 이 연결은 제작 도구이며 NeaTree 실행에 Blender나 MCP 서버가 필요하지 않다. Codex의 기본 도구 등록과 별개인 독립 MCP 클라이언트로 실제 `get_scene_info`, `execute_blender_code`, `look` 호출을 사용했다.

기본 장면을 재생성하려면 Blender와 `usdcat`, `usdzip`, `usdchecker`가 필요하다. 저장한 원본을 보존한 작업 복사본에서 저장소 루트를 전달한다.

```sh
blender --background --python scripts/blender-psilo.py -- "$PWD"
```

이 스크립트는 기본 장면과 USDZ를 다시 생성한다. 이후 MCP에서 추가한 편집·키프레임을 재현하는 전체 작업 이력은 아니다. Blender에서 수정한 장면을 내보낼 때도 제작 좌표계에서 앱 좌표계로 각 메시와 로컬 변환을 변환해야 한다. 부모 하나를 회전시키는 방식만으로 대체하면 시선·고개·안경 리깅의 축이 달라질 수 있다.

## 앱 리깅 계약

아래 이름은 USD 래퍼 아래에서도 재귀적으로 조회한다. 이름 변경 시 `Psilo3DView.swift`를 함께 수정한다.

| 부위 이름 | 역할 |
| --- | --- |
| `Psilo` | 모델 루트, 미세한 호흡 |
| `Head` | 고개·시선 방향과 들썩임의 기준 |
| `Hat` | 고개를 약간 늦게 따라가는 모자 |
| `Horns` | 갓과 함께 움직이는 고정 뿔. 별도 지연 회전하지 않는다. |
| `Glasses` | 작업 중 내려와 안착하는 안경 |
| `eye_L`, `eye_R` | 커서 시선과 깜빡임 |
| `mouth_idle`, `mouth_proud` | 기본·뿌듯한 표정 |
| `ErrorEyes`, `spiral_L`, `spiral_R` | 오류 표정과 회전 |
| `Props/file_0`, `Props/file_1`, `Props/file_2` | 정해진 경로로 모이는 파일 소품 |

안경·오류 눈·뿌듯한 입·파일은 중립 자산에서 매우 작은 크기로 보관한다. 런타임 드라이버는 표시량에 따라 단위 크기까지 연속적으로 바꾸고 숨겨진 부위는 비활성화한다.

앱은 Blender 키프레임 클립을 재생하지 않는다. `PsiloActivity`와 `PsiloIssue`를 받아 연속 감쇠 스프링으로 현재 포즈와 속도를 다음 목표로 이어간다. 파일 경로는 미리 정한 Bézier 곡선이며 물리 시뮬레이션은 없다. 동작과 배치 기준은 [캐릭터 행동 문서](../../docs/design/mascot-motion.md)에 있다.

## 규모와 실행 범위

현재 v7 USDZ는 **표시 가능한 삼각형 41,219개·재질 2개·텍스처 3개·5,014,102바이트**다. macOS 14 표정 호환 데이터 24,935 삼각형은 로딩 직후 장면에서 제거하며 렌더링하지 않는다. 상세 수치·해시·재생성 방법은 [앱용 자산 문서](runtime-v7/README.md)에 있다. `usdchecker --arkit`를 통과했다. 이는 자산 규모와 형식 검증이며 기기별 프레임 속도나 전력 소비 측정값은 아니다.

앱은 방향광 하나를 사용하고 실시간 그림자·물리·충돌을 생략한다. 창이 닫히거나 최소화·숨김·완전 가림 상태가 되면 `ARView`와 프레임 구독을 제거하고, 다시 보이면 보존한 모델·포즈로 렌더링을 재개한다. 앱에는 이 모델과 RealityKit 런타임만 번들링하며 제작용 스튜디오 바닥·카메라·조명·Blender 실행 파일은 포함하지 않는다.
