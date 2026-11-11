# Psilo v7 앱용 자산

2026-11-12 사용자의 최신 실로 앱 반영 요청에 따라 `review-v7-plump-horns/Psilo-v7.blend` 전체를 변환했다. 승인된 통통한 원형 단면 뿔, v7 갓·몸통·모자·표면에 붙은 눈·함몰된 입을 보존한다. **앱 연결을 위한 자산이며, 사용자에게 전체 외형·모션 품질의 최종 승인을 받은 상태는 아니다.**

## 구성

- `Psilo.usdz`: 앱에 번들링할 중립 모델. Y-up, +Z 정면, 미터 단위.
- `Psilo-v7-runtime-studio.blend`: 경량 메시·패킹된 텍스처·표정 키를 포함한 Blender 검토 장면. Blender 좌표계는 Z-up, −Y 정면이다.
- `Psilo-v7-{color,roughness,normal}.png`: 조명을 굽지 않은 표면색·거칠기·노멀 맵. 색상 2048², 나머지 1024².
- `baked-{front,left,right}.png`, `smile-{0.5,1}.png`: 같은 스튜디오 설정으로 확인한 정지·중간·완료 표정. 실제 앱 조명과 GPU 렌더 결과를 대신하지 않는다.
- `working-three-quarter.png`, `error-three-quarter.png`: 안경·파일·오류 눈의 재질과 부착을 확인한 Blender 포즈. 앱 애니메이션 캡처가 아니다.
- `model-metrics.json`, `geometry-validation.json`: 원본·빌드 스크립트·USDZ 해시, 기하·텍스처 규모 및 접합 검증.
- `Psilo-lod*.blend`, `Psilo-lod.metrics.json`, `Psilo-app.usda`, `Psilo.usdc`, `textures/`: 재현과 점검을 위한 중간 산출물. 앱에는 USDZ 하나만 넣는다.

## 런타임 계약

기존 `Psilo`, `Head`, `Hat`, `Horns`, `Glasses`, `eye_L/R`, `mouth_proud`, `ErrorEyes`, `spiral_L/R`, `file_0/1/2` 제어 이름과 로컬 축을 유지한다. `Horns`는 `Head`에 고정하며 별도 지연 회전하지 않는다.

| 메시 | 표정 키 | 역할 |
| --- | --- | --- |
| `Cap` | `SmileClose` | 함몰된 입이 연속적으로 닫힘 |
| `MouthInterior` | `SmileClose` | 함몰면에 맞춘 어두운 내부가 함께 닫힘 |
| `EyeDot_L`, `EyeDot_R` | `Happy` | 점 눈이 뿌듯한 눈매로 연속 변형 |

`Smile`은 완성된 곡선 메시다. `mouth_proud` 제어를 통해 입이 거의 닫힌 뒤 드러낸다. `MouthInterior`의 닫힌 표정은 면적이 0인 가로 선으로 수렴하므로 별도 투명도 교체가 없다. 원래 제작용의 동적 입 셰이더를 정적 텍스처에 굳혀 넣지 않는다.

macOS 15 이상에서는 USD 표정 키를 사용한다. macOS 14용 동일 토폴로지 대상 메시 4개는 `PsiloMorphTargets` 그룹에 저장하며 이름은 `MorphTarget_<메시>_<키>`다. 로딩 직후 이 그룹을 장면에서 제거한다. 14에서는 UV·삼각형 인덱스·재질·좌표의 유효성을 확인한 뒤 표정이 바뀌는 동안에만 메시 버퍼를 보간한다. 이 대상 메시들은 화면에 렌더링하지 않는다.

## 규모와 검증 범위

표시 가능한 메시 총 41,219 삼각형, 숨긴 호환 대상 메시 24,935 삼각형, 재질 2개, 텍스처 3개다. 소품과 표정 부위는 필요할 때만 활성화한다. 최종 USDZ는 5,014,102바이트이며 앱 리소스와 바이트 단위로 동일하다. SHA-256: `810e6b176d4541bf58117c4a2152e28107285757fd7d6ca404df6196960f347c`. 파일 크기나 삼각형 수는 전력·프레임 속도 측정값이 아니다.

Blender 5.3 CPU Cycles 64샘플로 베이크했다. 곡면의 극점처럼 면적이 없는 원본 삼각형은 안정적인 변위 보간을 사용하며, 내보내기 전 모든 메시·표정 좌표와 USD 수치가 유한한지 검사한다. `usdchecker --arkit`를 통과한 파일만 생성한다. 뿔 밑면 전체의 표본은 양쪽 모두 갓 안에 있고, 원뿔 단면과 둥근 끝의 기하 오차는 부동소수점 수준이다.

같은 기하의 후보 D는 RealityKit에서 네이티브 키 4개와 macOS 14 강제 호환 경로 4개의 0 → .2 → .5 → .85 → 1 → .7 → 0 전환을 검증했다. 최종 패키지의 실제 앱 GPU 캡처와 사용자 품질 확인은 별도로 기록한다.

## 앱 표시 색상

앱의 색상 변환 표는 [color-transform](color-transform/README.md)에 별도로 기록했다. Blender AgX의 수치 출력을 33³ half-float 표로 생성하며, 재생성 스크립트의 출력이 번들 리소스와 바이트 단위로 같다. 제작 화면의 +0.4 노출과 런타임의 +1.2 스톱 보정은 구분해서 기록한다.

## 공개 소스 메타데이터

Blender 파일의 로컬 이미지·패킹 경로와 파일 브라우저·출력 메타데이터를 상대 경로로 바꿨다. 19개 현재·과거 원본은 변경 전후의 기하·재질 및 텍스처 픽셀 지문이 같다. PNG 미리보기는 개인 경로가 들어 있던 텍스트 청크만 제거했고 나머지 청크와 IDAT는 그대로다. `blend-metadata-sanitization.json`과 `png-metadata-sanitization.json`에 이전·이후 해시를 기록했다. 원본 해시가 달라진 이유는 이 메타데이터 정리이며 앱 USDZ는 바뀌지 않았다.

## 재생성

저장소 루트에서 Blender, `usdcat`, `usdzip`, `usdchecker`가 필요하다. 출력 디렉토리는 새 빈 경로여야 하며 원본과 앱 리소스를 자동으로 덮어쓰지 않는다.

```sh
blender -b assets/psilo/review-v7-plump-horns/Psilo-v7.blend \
  --python scripts/build-psilo-runtime-v7.py -- --out /tmp/psilo-runtime-v7-new
```
