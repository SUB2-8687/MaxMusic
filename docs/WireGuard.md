# 앱 내부 WireGuard · HTTP/HTTPS/SOCKS5 프록시 (WIREGUARD=1)

시스템 VPN이나 Network Extension을 켜지 않고, YouTube Music 앱 **자체의** API 요청과 음악 스트리밍을
사용자가 가져온 WireGuard `.conf`의 서버로 보내는 기능입니다. 기본 빌드에는 포함되지 않고,
`WIREGUARD=1`(또는 GitHub Actions의 `enable_wireguard`)로 빌드할 때만 들어갑니다.

> iOS 17 이상이 필요합니다. URLSession에 프록시를 강제하는 `nw_proxy_config` /
> `NSURLSessionConfiguration.proxyConfigurations` API가 iOS 17.0부터 있기 때문입니다.
> iOS 13–16에서는 dylib는 정상 로드되지만 기능이 켜지지 않습니다.

## 구조

```
YouTube Music (NSURLSession, GTMSessionFetcher, HAMURLSessionDataLoader …)
   │  모든 NSURLSessionConfiguration / 세션 생성 시 프록시 강제 (failover 금지)
   ▼
127.0.0.1:<임의 포트>  인증 SOCKS5 · HTTP CONNECT   ← 실행마다 새 사용자명/비밀번호
   │  (FFmpeg 다운로드는 http_proxy → CONNECT)
   ▼
Go 엔진: gVisor netstack (사용자 공간 TCP/IP, DNS는 프로필 DNS로 터널 안에서 조회)
   ▼
wireguard-go  ──UDP──▶  WireGuard 서버 (.conf의 Endpoint)
```

- 시스템 TUN, 라우팅 테이블, VPN 프로필, Network Extension을 만들지 않습니다. 기기에 열리는 소켓은
  WireGuard UDP 소켓과 loopback 리스너뿐입니다.
- 프록시를 적용할 수 없거나 엔진이 실패하면 요청이 **실패**합니다. 직접 연결로 넘어가지 않습니다.
  (`nw_proxy_config_set_failover_allowed(false)`, 실패 시 차단용 `NSURLProtocol`, 닫힌 포트)
- 엔진 코드에는 직접 다이얼(`net.Dial`) 경로가 없습니다. 호스트 이름은 netstack의 리졸버가
  프로필의 `DNS` 서버로 **터널 안에서** 조회합니다.

## 빌드

### GitHub Actions (IPA)

1. Actions → **Build and Release YTMusicUltimate and MaxMusic** → Run workflow
2. 복호화된 YouTube Music IPA URL을 입력하고 **App-local WireGuard**를 체크합니다.
3. 빌드 요약에 `ytm_transport_scan.py` 결과가 표시됩니다(아래 "버전별 재확인" 참고).
4. 릴리스(draft)에 `…_WireGuard.ipa`가 생깁니다. 이 IPA는 fakesign 상태이므로 **본인 인증서로
   앱 전체(추가된 dylib·프레임워크 포함)를 다시 서명**해서 설치합니다(Sideloadly, ESign, AltStore 등).

### 로컬

```bash
bash WireGuard/build-ios.sh
```

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless SIDELOADING=1 WIREGUARD=1
```

`build-ios.sh`에는 `WireGuard/go.mod`에 맞는 Go가 필요합니다(Go 1.27.x, `GOTOOLCHAIN`이 자동으로 받음).
Linux에서는 `IOS_SDK=/path/to/iPhoneOS.sdk`를 지정합니다. 의존성 버전과 체크섬은 `go.mod`/`go.sum`에
고정되어 있고 `go mod verify`로 확인할 수 있습니다.

## 사용

1. YouTube Music → 설정 → YTMusicUltimate → **앱 내부 WireGuard**
2. **.conf 파일 가져오기**(또는 클립보드에서 가져오기). 가져오면 사용 스위치가 켜집니다.
3. 안내에 따라 앱을 완전히 종료하고 다시 엽니다(훅은 실행 시점에만 설치됩니다).
4. 시스템 VPN을 끈 상태에서 **국가·출구 IP 확인** → **연결 진단 실행**
5. **실제로 곡 재생, 다음 곡, 잠금 화면 재생을 확인**합니다. 재생 오류가 나면 그 직후 **진단 복사**를 누릅니다.

지원하는 `.conf`: `[Interface]`(PrivateKey, Address, DNS, MTU, ListenPort) + `[Peer]` 하나(PublicKey,
PresharedKey, Endpoint, AllowedIPs, PersistentKeepalive). `AllowedIPs`에 `0.0.0.0/0`이 있어야 하고
`DNS`에 숫자 IP가 하나 이상 있어야 합니다. `PreUp/PostUp` 같은 스크립트 필드는 거부합니다.
Clash YAML 등 다른 형식은 지원하지 않습니다. Endpoint가 호스트 이름이면 서버에 접속하기 위해 기기 DNS로
한 번 조회합니다(터널을 만들기 전이라 피할 수 없음). 화면에 그 사실이 표시됩니다.

## HTTP · HTTPS · SOCKS5 프록시 모드

WireGuard 대신 외부 프록시 서버를 쓸 수 있습니다. 설정 화면의 연결 종류에서 HTTP/HTTPS/SOCKS5를 고르고
서버·포트·(선택) 사용자 이름·비밀번호를 입력한 뒤 **이 연결 방식 저장** → 사용 켜기 → 앱 재시작.

- 같은 URLSession 훅으로 `nw_proxy_config`를 적용하며 직접 연결 failover는 금지입니다. 설정을 읽을 수 없으면
  (Keychain 잠김 등) 요청을 차단합니다.
- HTTP/HTTPS는 HTTP CONNECT입니다. HTTPS는 프록시와의 구간을 TLS로 암호화하고 시스템 신뢰 저장소로 프록시
  인증서를 검증합니다(자체 서명 인증서 프록시는 연결되지 않음). SOCKS5는 사용자 이름/비밀번호 인증을 지원합니다.
- 호스트 이름은 프록시 서버가 조회합니다(CONNECT/SOCKS5에 이름을 그대로 전달). 앱 내 "터널 DNS" 확인은
  WireGuard 모드에서만 동작합니다.
- 비밀번호는 Keychain(이 기기 전용)에 저장하며 진단에는 서버 주소와 비밀번호가 들어가지 않습니다.
- YTMusicUltimate 다운로드(FFmpeg)는 HTTP 프록시만 지원합니다. HTTPS·SOCKS5 모드에서는 직접 연결로 새지 않도록
  다운로드를 차단합니다.
- Envoy/Cronet/HTTP3 전송 패치는 WireGuard 모드와 똑같이 적용됩니다(이 경로들은 어떤 프록시도 거치지 않음).

## 개인정보·보안

- `.conf`(개인키 포함)는 Keychain에 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`로만 저장합니다.
  IPA·소스·로그·빌드 결과물에 들어가지 않습니다. 문서 선택기의 임시 복사본은 가져온 직후 지웁니다.
- 재서명할 때 팀 ID가 바뀌면 Keychain 접근 그룹이 달라져 프로필을 다시 가져와야 할 수 있습니다.
- 진단에는 카운터, HTTP 상태 코드, 오류 도메인·코드만 들어갑니다. 복사 전에 Go의 `Redact()`가
  키, 토큰, URL(서명된 곡 URL 포함), 이메일, IP 주소 마지막 옥텟을 한 번 더 지웁니다.
- loopback 프록시는 실행마다 바뀌는 무작위 사용자명/비밀번호가 없으면 연결을 받지 않습니다.
  "인증 없음" SOCKS, UDP ASSOCIATE, 일반 HTTP 프록시 요청은 거부합니다.
- `WIREGUARD=1` 빌드에서는 기능이 꺼져 있어도 Go 런타임이 함께 로드됩니다(대기 상태 스레드 몇 개).

## 음악 전송 경로 분석과 처리

국가 확인(Cloudflare trace)이 성공해도 음악이 재생된다는 증거가 아닙니다. YouTube Music은 URLSession 외의
전송 스택을 쓸 수 있고, 그 경우 프록시를 거치지 않습니다. 현재 처리 내용은 다음과 같습니다.

| 경로 | 처리 | 근거 |
| --- | --- | --- |
| NSURLSession (API, GTMSessionFetcher, HAMURLSessionDataLoader) | 설정·세션 생성 훅으로 SOCKS5 강제, failover 금지 | macOS 하네스로 Apple 실제 스택 검증 |
| `YTIHamplayerUrlSessionDataLoaderConfig.networkStackType` | 9.42.2에서 3 = HAMEnvoyDataLoader, 0 = URLSession 로더. 아래 규칙으로만 변경 | 9.42.2 실행파일 분석(사용자 제공 결과) |
| Cronet / QUIC / Envoy BOOL 플래그 (`useCronet`, `useCronetNative`, `assumeHTTP3Capable`, `enableCronet`, `enableQuic`, `cronetEnabled`, `cronetQuicEnabled`, `platypusUseEnvoyNetFetch`, `onesiePlatypusUseEnvoyNetFetch`) | 선택자와 반환 타입이 BOOL로 확인될 때만 NO로 고정, 원래 값 기록 | 이름 자체가 의미를 나타내므로 버전과 무관 |
| `NSURLRequest.assumesHTTP3Capable` | 설정 시 NO로 바꿈 | SOCKS 프록시는 TCP만 전달 |
| YTMusicUltimate 다운로드 (FFmpeg) | `http_proxy` 환경변수 → FFmpeg tls가 인증 CONNECT 사용 | FFmpeg 4.3(libavformat 58.48) 문자열·프로토콜 확인, Go 테스트로 407→재인증 흐름 검증 |
| `+[NSData dataWithContentsOfURL:]` (YTMU 매니페스트·커버) | 터널 세션으로 우회 처리 | macOS 하네스 |
| AVFoundation 원격 URL (`AVURLAsset`) | 처리 불가(별도 프로세스). **개수만 진단에 표시** | 진단 `bypass.suspects` |
| WKWebView(로그인 페이지 등) | 처리하지 않음(별도 프로세스) | 음악 재생과 무관 |
| 백그라운드 URLSession | 프록시를 적용하지만 앱 밖에서 실행되므로 동작이 보장되지 않음 | macOS 하네스는 적용 여부만 기록 |

### networkStackType 규칙 (다른 버전에 그대로 적용하지 않음)

1. 실행 중인 바이너리의 protobuf enum 서술자에 값 이름이 있으면 `URL_SESSION`이 들어간 값을 고릅니다.
2. 이름이 없으면 **검증된 버전(현재 9.42.2)** 에서만 0을 씁니다.
3. 그 외 버전은 값을 바꾸지 않고 **관측만** 합니다(원래 값 히스토그램 기록).
   진단에 `Envoy tasks`가 0보다 크면 설정의 **고급 → URLSession 음악 로더 강제**를 켜고 다시 시험합니다.

### 버전별 재확인

- **빌드 시점**: `tools/ytm_transport_scan.py`가 IPA의 모든 Mach-O에서 위 클래스와 선택자, `NETWORK_STACK`
  enum 이름 문자열, 암호화 여부를 확인합니다. 정적 존재 여부 검사일 뿐, 분기 동작까지 증명하지는 않습니다.
- **실행 시점**: 패치는 클래스·선택자·타입 인코딩이 맞을 때만 설치되고, 맞지 않으면 `hooks.skipped`에
  표시됩니다. **이 버전의 전송 경로 클래스 스캔**은 Envoy/Cronet/QUIC/DataLoader 관련 클래스와 YTI*Config
  플래그 목록을 진단에 추가합니다.
- **재생 후**: `music.loader`(URLSession/Envoy 요청 수), `music.loader.instances`(실제로 생성된 로더),
  `tunnel.destinations`(터널을 통과한 media-cdn/youtube-api 연결 수)를 봅니다.
  `media-cdn`이 늘고 `Envoy tasks`가 0이면 음악 스트림이 터널을 지난 것입니다.

## 언어팩

WireGuard·프록시 화면의 문구(`WG_*` 키 77개)는 `Localizable.strings`가 아니라 같은 `.lproj` 안의 `WireGuard.strings`에 있습니다.

```
layout/Library/Application Support/YTMusicUltimate.bundle/
  en.lproj/ Localizable.strings   (YTMusicUltimate 문구)
            WireGuard.strings     (WG_* 문구)
  ko.lproj/ Localizable.strings
            WireGuard.strings
```

- 한글 문구는 `ko.lproj/WireGuard.strings`만 고치면 됩니다. 다른 화면은 `ko.lproj/Localizable.strings`입니다.
- 코드는 `localizedStringForKey:value:table:@"WireGuard"`로 읽고, 키나 파일이 없으면 코드에 적힌 영어 문구가 대신 표시됩니다.
- 키와 서식 지정자(`%@`, `%lld`)는 en과 ko가 같아야 합니다. `python3 tools/check_wireguard_strings.py`가 소스에서 쓰는 키, ko/en 일치, `Localizable.strings`에 남은 `WG_*` 키를 확인합니다(`WireGuard engine check` 워크플로에서도 실행).
- IPA 빌드(`main.yml`)는 en·ko 언어팩만 남기며, 한글 패치 단계에서 `WireGuard.strings`도 deb에 함께 넣습니다.

## 진단 항목

| 항목 | 의미 |
| --- | --- |
| `wireguard.handshake` | 마지막 WireGuard 핸드셰이크 경과 시간, 암호화 송수신 바이트 |
| `tunnel.connections` | 터널 TCP 연결 수 (호스트 이름/IP 대상), 실패, DNS 실패 |
| `tunnel.destinations` | media-cdn(googlevideo 등) / youtube-api / 기타 연결 수 (호스트 이름은 저장하지 않음) |
| `proxy.applied` | 프록시가 적용된 URLSession 설정·세션 수, 적용 실패와 차단된 요청 |
| `transport.flag …`, `transport.networkStackType` | 각 패치의 적용 결과와 원래 값 |
| `music.loader`, `music.loader.instances` | 로더별 요청 수, 실제 생성된 로더 클래스 |
| `music.http-status`, `music.errors` | 음악 로더의 HTTP 상태 분포, 오류 도메인·코드 분포 |
| `bypass.suspects` | AVURLAsset 원격 URL 수, Envoy 로더 요청 수 |
| `check.*` | 국가, 터널 DNS, HTTPS, HTTP 206 확인 결과 |

## 테스트 범위

| 구분 | 내용 | 어디서 |
| --- | --- | --- |
| 자동 (Linux) | `.conf` 파서·거부 규칙, SOCKS5/CONNECT 인증, WireGuard 루프백 핸드셰이크, 터널 DNS, HTTPS, HTTP 206, 직접 연결 미발생, 피어 중단 시 실패, UDP rebind·리스너 복구, 진단 마스킹 (`go test -race`) | `WireGuard/*_test.go`, CI `go-tests` |
| 자동 (macOS, 프록시 모드) | NSURLSession → 로컬 테스트 프록시: HTTP CONNECT(Basic 인증·407 재시도, 인증 없음), SOCKS5(인증)에서 HTTPS 206 통과 / SOCKS5 잘못된 비밀번호, 신뢰할 수 없는 인증서의 HTTPS 프록시, 닫힌 프록시 포트에서는 원 서버에 도달하지 않음 / FFmpeg 환경변수 / 진단에 비밀번호 없음 | `tests/wireguard`, CI `macos` |
| 자동 (macOS) | Apple NSURLSession + Network.framework → SOCKS5(인증, failover 금지) → 엔진 → WireGuard 테스트 피어: HTTPS, 206, 터널 DNS, sharedSession, NSData, 직접 연결 미발생, 죽은 피어·잘못된 프로필에서 차단, Google 플래그 패치 로직(목 클래스), 진단 마스킹 | `tests/wireguard`, CI `macos` |
| 자동 (빌드) | iOS arm64 엔진 아카이브, `WIREGUARD=1` deb 빌드, dylib에 테스트 코드 없음, 라이선스 포함, 기본 빌드에는 엔진이 들어가지 않음 | CI `macos` (`WireGuard engine check`, deb는 아티팩트로 업로드) |
| **실기기 필요** | 설치·설정 화면, 실제 YouTube Music 바이너리의 패치 적용, Google 서버 곡 재생·다음 곡·잠금 화면 재생, Wi‑Fi/셀룰러 전환, 실제 WireGuard 서버 | 사용자 확인 |

## 실제 WireGuard 서버로 확인 (선택)

`WireGuard live server check` 워크플로는 실제 서버로 연결해 macOS의 NSURLSession으로 핸드셰이크, 터널 DNS,
출구 국가, HTTPS, HTTP 206을 확인합니다. 앱 재생 검증은 아니지만, 내 `.conf`와 서버가 이 엔진에서 동작하는지
기기 없이 확인할 수 있습니다.

1. 저장소 Settings → Secrets and variables → Actions → **New repository secret**
2. 이름 `WG_TEST_CONF`, 값에 `.conf` 파일 내용 전체를 붙여넣습니다.
3. Actions → **WireGuard live server check** → Run workflow (예상 국가 코드, 기본 `US`)

프로필은 Secret에서만 읽고 커밋·출력·업로드하지 않습니다. 로그에는 카운터, 국가, 마스킹된 출구 IP만 나옵니다.
무료 서버는 GitHub 러너(데이터센터 IP)에서의 연결을 제한할 수 있으므로, 여기서 실패해도 기기에서 다시 확인하세요.

## 라이선스

정적으로 링크되는 wireguard-go(MIT), gVisor(Apache-2.0), google/btree(Apache-2.0), golang.org/x/*
(BSD-3-Clause), Go 런타임(BSD-3-Clause)의 라이선스 전문은 `WireGuard/THIRD_PARTY_LICENSES.txt`에 있고,
`WIREGUARD=1` 패키지에서는 `YTMusicUltimate.bundle/WireGuard-THIRD_PARTY_LICENSES.txt`로 함께 배포됩니다.
