# BookScan3

iPad 11인치 및 iPad(A16, 11세대)를 포함한 **iPadOS 18 이상**에서 사용하는 네이티브 북스캔 앱입니다. SwiftUI와 Apple 프레임워크만 사용하며 외부 서버·계정·패키지 의존성이 없습니다. iPhone 화면도 지원합니다.

## 실행

1. Mac의 Xcode에서 `BookScan3.xcodeproj`를 엽니다.
2. `BookScan3` 타깃 → **Signing & Capabilities → Team**에 본인의 Apple 개발 팀을 선택합니다. 필요하면 Bundle Identifier를 고유한 값으로 변경합니다.
3. iPad를 연결하고 신뢰 및 개발자 모드를 활성화합니다.
4. 실행 기기로 iPad를 선택하고 **⌘R**을 누릅니다.

프로젝트 파일이 포함되어 있어 XcodeGen 설치 없이 열 수 있습니다. 구성 파일을 수정했다면 XcodeGen으로 재생성합니다.

```sh
xcodegen generate
xcodebuild -project BookScan3.xcodeproj -scheme BookScan3 \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

시뮬레이터에는 후면 카메라가 없으므로 촬영 대신 사진 가져오기를 사용합니다. 실제 촬영은 iPad에서 검증해야 합니다.

## 사용

- **새 책 만들기**에서 제목을 입력합니다.
- **스캔 시작** → 한 페이지 또는 펼친 책을 선택합니다. 펼친 책은 왼쪽부터 두 페이지로 저장합니다.
- 문서 외곽은 자동 검출하고 원근을 보정합니다. 검출되지 않으면 전체 사진을 사용합니다.
- 접힘선을 자동으로 찾거나, 자동 찾기를 끄고 왼쪽/오른쪽 비율을 조절합니다.
- 필요할 때 **기본 곡면 보정**을 켭니다. 접힘선 부근의 수평 압축을 원통형 역투영으로 완화하는 근사 방식입니다. 강도가 높으면 평평한 페이지가 왜곡될 수 있으므로 낮은 강도부터 사용합니다.
- 수동 촬영 또는 자동 촬영을 사용합니다. 자동 촬영은 문서 면적·움직임·선명도를 검사하고 약 0.6초간 안정되면 촬영합니다. 다음 촬영은 책을 충분히 움직이거나 화면 밖으로 뺐다가 놓아 재활성화합니다. 단순히 정지한 같은 구도로는 반복 촬영하지 않습니다.
- 서재에서 사진 여러 장을 가져오면 각각 단일 페이지로 저장합니다. 사진 한 장을 양면으로 나누려면 촬영 화면에서 **펼친 책 → 사진에서 가져오기**를 사용합니다.
- 페이지를 눌러 확대·필터 변경·텍스트 인식·읽어주기·텍스트 복사 및 공유를 사용합니다. 필터 변경은 보존된 보정 이미지에서 다시 처리하며 기존 OCR 결과는 초기화합니다.
- 페이지를 길게 눌러 삭제하거나 순서를 바꿉니다. 드래그 또는 메뉴의 앞으로/뒤로 이동을 사용할 수 있습니다.
- **PDF 내보내기**로 파일 앱이나 AirDrop 등에 공유합니다. **⋯ → PC로 Wi-Fi 전송**은 같은 Wi-Fi에서 선택한 책 한 권을 다운로드하는 임시 주소를 표시합니다. 전송 화면을 닫거나 앱을 벗어나면 서버가 중지됩니다.

## 구조

`ARCHITECTURE.md`를 기준으로 UI, 상태 관리, 영상 처리, 저장, 전송을 분리했습니다.

| 영역 | 구현 |
| --- | --- |
| SwiftUI | 서재 사이드바, 반응형 페이지 그리드, 촬영, 페이지 상세, 공유 화면 |
| ViewModels | MainActor 상태 변경, 작업 중복 방지, 저장 후 UI 반영 |
| CameraService | AVFoundation 사진/프리뷰, 독립 세션·분석 큐, 회전 코디네이터 |
| ImageProcessor | Vision 문서 검출, 원근 보정, 접힘선 추정, 분할, 4개 필터 |
| CylindricalDewarpService | 선택적 수평 원통형 보정, 강도 조절 |
| OCRService | Vision accurate OCR, 지원 언어 조회 후 한·영·일·중 설정 |
| StorageManager | actor 기반 JSON/JPEG 저장, 원자적 메타데이터 교체, 썸네일, 페이지별 PDF 렌더링 |
| PCTransferServer | NWListener, Wi-Fi 인터페이스, 임시 토큰, 요청 길이/접속 수 제한, 64KB 단위 PDF 전송 |

저장 위치: 앱 Documents/BookScan3. `library.json` 및 각 페이지의 JPEG 3개(필터 적용 전 보정본·현재 이미지·썸네일)를 사용합니다. PDF는 임시 Exports 폴더에 생성합니다. 카메라 원본 전체 사진은 별도로 보존하지 않으므로 분할 비율을 잘못 설정했다면 다시 가져오거나 촬영해야 합니다.

## 아키텍처 목표와 현재 범위

이 저장소에는 학습된 `.mlpackage` 파일이 제공되지 않았습니다. 다음 항목은 구현 또는 실기기 검증이 추가로 필요합니다.

- **DewarpNet → Textline Mesh → Cylindrical 3단계 자동 fallback**: 현재 기본 원통형 수평 보정만 구현했습니다. Core ML 추론과 텍스트 라인 기반 3D/메시 복원은 포함되지 않습니다.
- **손가락 제거 및 인페인팅**, 서브픽셀 코너 정제, CLAHE: 미구현입니다. 해당 기능을 수행하는 것처럼 표시하는 옵션은 없습니다.
- **60fps 검출 및 450ms 처리·250MB 메모리 목표**: 달성했다고 보장하지 않습니다. 분석은 프리뷰와 분리해 최대 약 8fps로 제한합니다. 실기기 성능과 발열 검증 전까지 60fps Vision 추론을 강제하지 않습니다.
- **PDF**: 현재 이미지 기반 PDF입니다. OCR은 앱 안에서 검색·복사·텍스트 공유할 수 있으나 PDF의 검색 가능한 숨은 텍스트 레이어와 ePub 출력은 미구현입니다.
- **Wi-Fi API**: 선택한 PDF를 위한 `/` 및 `/download.pdf`만 제공합니다. 전체 서재 열람 API는 노출하지 않습니다. HTTP이므로 신뢰하는 Wi-Fi에서 사용하며 주소를 아는 기기는 다운로드할 수 있습니다.
- Wi-Fi 전송, 카메라 센서 회전, 저조도/반사광, 100페이지 연속 촬영과 성능 수치는 실제 iPad에서 검증이 필요합니다. OS 백업 정책에 따른 기기 백업은 앱의 외부 서버 통신과 별개입니다.

## 검증

Xcode 26.6 / iPad Pro 11-inch (M5), iPadOS 26.5 시뮬레이터에서 초기 구현의 단위 테스트 5개 및 UI 테스트 1개 통과:

- JSON/JPEG 저장·복원, 원본 보존, 필터 재적용, PDF 페이지 수, 삭제 파일 정리
- 손상된 메타데이터를 덮어쓰지 않는지 확인
- 비대칭 양면 분할과 네 필터의 실제 이미지 생성
- 자동 촬영 안정화·중복 방지·재활성화·흐린 프레임 거부
- Wi-Fi 토큰·경로·메서드 검증
- 책 생성 → 촬영 화면 → 서재 복귀

그 이후 추가한 회전 코디네이터 및 원통형 곡면 보정을 포함한 **최종 iOS arm64 기기용 빌드가 성공했습니다**(코드 서명 제외). 시뮬레이터 재실행 권한이 거절되어 이 두 변경의 실행 테스트는 아직 하지 못했습니다. 곡면 보정 검증 코드는 테스트에 추가했습니다. 기본 곡면 보정의 Core Image Kernel Language API에는 deprecated 경고가 있으며, 후속 작업에서 Metal 커널로 이전해야 합니다.

## Apple API 참고

- [Vision 문서 검출 결과](https://developer.apple.com/documentation/vision/vndetectdocumentsegmentationrequest/results)
- [AVCaptureConnection 회전](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle)
- [iPad 카메라와 RotationCoordinator](https://developer.apple.com/videos/play/wwdc2023/10106/)

문서에 적힌 API의 도입 버전이나 ANE 속도 수치는 실제 SDK/디바이스 결과와 구분해야 합니다. 앱의 최소 지원 버전은 설계대로 iPadOS/iOS 18로 지정했습니다.
