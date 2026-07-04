# smarthome

## FINDINGS
## 1. Home Assistant on/around Windows 11 (June 2026 state)

**Critical fact: HA Core (venv) was deprecated and dropped as a supported install method after release 2025.12** (announced 2025-05-22 HA blog). Only HAOS and HA Container are supported now. HA Core also never officially supported Windows, and current HA requires Python 3.13.x — the machine's Python 3.14 wouldn't work anyway. Do not target Core.

Current versions (June 2026): HA Core **2026.6** (released 2026-06-03, "Pick a card, any card" — new card picker), HAOS 16.x line.

| Method | RAM | Maintenance | Verdict for this machine |
|---|---|---|---|
| **HAOS in Hyper-V VM (.vhdx)** | 2 GB min official, 3 GB comfortable; \~32 GB dynamic vhdx | Lowest: Supervisor auto-updates, Add-on store (Mosquitto, Z2M, Node-RED, Frigate all one-click), built-in full backups | **Recommended.** Officially documented by HA for Windows |
| HA Container (Docker Desktop/WSL2) | Docker Desktop WSL2 VM \~1.5–2.5 GB + HA \~600 MB | No Supervisor, no add-ons; every service (HA, Mosquitto, Z2M, Frigate) is a separate hand-managed container; Docker Desktop ties to user session | Workable for devs, hostile to the "novice can run it" requirement |
| HA Core venv | n/a | Deprecated/unsupported since 2025.12 | Dead end |

**Hyper-V setup** (official: home-assistant.io/installation/windows/): download `haos_ova-16.x.vhdx.zip`, then:
```powershell
New-VM -Name HAOS -Generation 2 -MemoryStartupBytes 3GB -VHDPath C:\HAOS\haos_ova-16.x.vhdx -SwitchName "HA-External"
Set-VMFirmware HAOS -EnableSecureBoot Off          # required, no Secure Boot
Set-VM HAOS -StaticMemory -AutomaticStartAction Start
```
Reach it at `http://homeassistant.local:8123`.

**Coexistence with the existing \~2 GB BlarAI VM: yes, easily.** Budget on the 31.3 GB host: Windows \~5 GB + BlarAI VM 2 GB + HAOS VM 3 GB ≈ 10 GB, leaving \~21 GB for dev/LLM work. The real constraint is not RAM but: (a) **Hyper-V has NO USB passthrough** — official HA docs carry an explicit warning — so a USB Zigbee stick can never be attached to the HAOS VM (fix: network coordinator, see §6, or run Zigbee2MQTT natively on the host); (b) HAOS needs an **External vSwitch (bridged)** for mDNS/SSDP device discovery, and external switches bound to a **Wi-Fi NIC are unreliable** on laptops (Wi-Fi bridging/MAC limitations) — use Ethernet/dock, or accept Default Switch NAT with broken discovery and changing subnets.

## 2. Camera/NVR

**Frigate is still Linux-Docker-only in 2026 — no native Windows build.** Current stable: **0.17.1** (0.17.0 released 2026-02-27, 0.17.1 \~2026-03-22). Headline for this hardware: 0.17 added **official Intel NPU support via OpenVINO** (`/dev/accel` passthrough); docs recommend NPU for object detection + iGPU for enrichments (semantic search, face recognition) on Core Ultra chips. Reported inference \~8.4 ms YOLO on a Core Ultra 7 265K NPU. Detector config:
```yaml
detectors:
  ov:
    type: openvino
    device: NPU   # or GPU
model:
  model_type: yolo-generic
```
Windows paths for Frigate, in order of viability:
- **Docker Desktop + WSL2**: works, but Intel iGPU access uses the WSL paravirt device — map `/dev/dxg` (not `/dev/dri`) and mount `/usr/lib/wsl:/usr/lib/wsl`, plus Intel compute-runtime inside the container (github.com/blakeblackshear/frigate/discussions/4375). Fragile across updates. **NPU is NOT available under WSL2** (intel/linux-npu-driver issue #56 — no `/dev/accel`). At Build 2026 (June 2) Microsoft announced **WSL 3** with paravirtualized GPU+NPU passthrough explicitly covering Lunar Lake — but it is an announcement, not GA; don't build on it yet.
- **Frigate add-on inside HAOS Hyper-V VM**: CPU-only detection unless you do Hyper-V GPU-P partitioning (documented at cardus.com 2025-01-06) — advanced, driver-version-locked, not novice-suitable.
- **Frigate on a dedicated Linux box**: the clean path (see §7).

**Native Windows alternatives**: **Blue Iris** — $70 one-time license (15-day trial), Windows-native, mature, pairs with **CodeProject.AI Server** (free, runs as a Windows service, DirectML/OpenVINO modules) for person/face/LPR detection; widely judged the most complete Windows NVR (wundertech.net comparison). **Shinobi**: Node-based, "works on Windows" but docs/installer effectively target Linux/Docker; weak choice. **go2rtc** (see §5) is the native-Windows restreamer regardless of NVR choice.

**Dashboard integration**: Frigate ships an official HA integration + the **Advanced Camera Card** (formerly frigate-hass-card, repo dermotduffy/advanced-camera-card) renders live WebRTC/MSE via go2rtc in Lovelace. Blue Iris integrates with HA via the blueiris MQTT integration + generic camera/RTSP.

## 3. MQTT on Windows

**Mosquitto 2.1.2** — native 64-bit Windows installer (`mosquitto-2.1.2-install-windows-x64.exe` from mosquitto.org/download), installs to `C:\Program Files\mosquitto`, registers a **Windows service** (`mosquitto install`, then `net start mosquitto`). Footprint \~10 MB RAM, \~5 MB disk — negligible. Since v2.0 it binds localhost-only by default; minimal LAN config:
```
# C:\Program Files\mosquitto\mosquitto.conf
listener 1883 0.0.0.0
allow_anonymous false
password_file C:\Program Files\mosquitto\passwd
```
`mosquitto_passwd -c passwd ha` to create the user. Alternative: skip native entirely and use the Mosquitto **add-on** inside HAOS (one click) — simpler for the novice end-state.

## 4. Dashboards

- **HA Lovelace**: the default answer. 2026.6 improved the card picker; sections-style dashboards + Advanced Camera Card + (optionally) AlexxIT WebRTC card give "control devices + live camera feeds" with zero custom code. Runs on Pixel 8 Pro / Legion Y700 via HA Companion app; the Y700 makes a good wall panel with Fully Kiosk.
- **Node-RED Dashboard 2.0** (`@flowfuse/node-red-dashboard`, Vue/Vuetify, actively maintained by FlowFuse; Dashboard 1 is dead): good for quick technical panels, but a second system to learn/maintain; HA-connection via `node-red-contrib-home-assistant-websocket`.
- **Custom web app**: best ROI for the coding agent only for the video-heavy view: HA WebSocket API for state/control + go2rtc WebRTC for sub-second video. 

**Recommendation for the agent: target Lovelace first (covers the novice), and a small custom React/vanilla page only for multi-cam live walls using go2rtc's API.**

## 5. APIs for the coding agent

- **HA REST** (`/api/`): `GET /api/states`, `POST /api/services/light/turn_on` with `Authorization: Bearer <long-lived token>`; tokens minted in user profile (valid 10 years) or via WS `auth/long_lived_access_token` (developers.home-assistant.io/docs/auth_api/).
- **HA WebSocket** (`ws://host:8123/api/websocket`): auth handshake `{"type":"auth","access_token":"..."}`, then `subscribe_events` (state_changed), `call_service`, `get_states` — this is what real-time dashboards should use.
- **MQTT**: device telemetry/control bus; Zigbee2MQTT publishes `zigbee2mqtt/<device>` topics; HA auto-discovers via MQTT Discovery.
- **go2rtc 1.9.14** (2026-01-19; AlexxIT/go2rtc): ships a native **Windows binary** (zero-dependency single exe). API: web UI on `:1984`, MSE `ws://host:1984/api/ws?src=cam`, WebRTC on `:8555` + `POST /api/webrtc?src=cam` (WHEP), MJPEG `/api/stream.mjpeg?src=cam`, snapshots `/api/frame.jpeg`. Config:
```yaml
streams:
  front_door: rtsp://user:pass@192.168.1.50:554/h264Preview_01_main
```
Embeds in any web page via its `video-stream.js`/WebRTC — the canonical way to get live video into a custom dashboard.

## 6. Protocol hardware (offline-first, 2026)

- **Zigbee — buy a NETWORK coordinator, not USB**, because of the Hyper-V no-USB constraint: **SMLIGHT SLZB-06MG24** (EFR32MG24, +5 dBi, Ethernet/PoE/USB/Wi-Fi, \~$40-45) — SmartHomeScene's top network pick (guide updated 2026-02-05); works with Zigbee2MQTT/ZHA over TCP (`socket://ip:6638`) from inside the HAOS VM. Alternates: Sonoff Dongle Max (PoE), or USB sticks **HA Connect ZBT-2** ($49, MG24, released 2025-11-19 — but Zigbee OR Thread, not both) / Sonoff ZBDongle-E (\~$20 budget). If USB is chosen, Zigbee2MQTT must run **natively on Windows** (officially documented: zigbee2mqtt.io/guide/installation/05_windows.html, Node 22+ — Node 24 present) talking to Mosquitto, since the stick can't reach the VM.
- **Thread/Matter**: needs its own radio — **SMLIGHT SLZB-MR3** (dual-radio MG24+CC2674, simultaneous Zigbee AND Thread over Ethernet) or a second ZBT-2 dedicated to Thread (OpenThread Border Router add-on). Matter is fully local (HA Matter Server add-on); requires working IPv6 on the LAN — the UniFi Dream Machine handles that. Matter-over-Wi-Fi devices need no dongle at all.
- **Z-Wave (optional)**: **Zooz ZST39 LR** 800-series (\~$35-40) + Z-Wave JS UI; USB-only, so same host-vs-VM caveat.
- All of the above are cloud-free by design (Z2M/ZHA/OTBR/Z-Wave JS are local).
- **Ubiquiti note**: if the router is the *original* UDM (base), it does **not** run UniFi Protect; the Dream Router (UDR/UDR7) and UDM-Pro line do. If Protect is available, HA's UniFi Protect integration is fully local and go2rtc can consume its RTSPS streams.

## 7. Laptop vs dedicated device — honest assessment

Hosting production HA + NVR on this laptop conflicts with: 24/7 uptime vs. a dev machine that reboots for Windows Update/sleeps; 32 GB shared ceiling where the Arc 140V's "VRAM" for Qwen3-14B INT4 (\~9 GB) comes out of the same pool as VMs and Frigate; Wi-Fi-bridged Hyper-V networking fragility; continuous NVR disk writes on the single NVMe (230 GB free shrinks fast at \~1-2 GB/cam/day even with motion-only retention). 

Dedicated options: **HA Green now $199** (Nabu Casa price increase announced 2026-01-08; RK3566/4 GB — too weak for Frigate, not recommended here). **Intel N150 mini PC (Beelink S13/S13 Pro class, \~$160, 16 GB/500 GB)** runs HAOS bare-metal (generic x86-64) including the Frigate add-on with OpenVINO on its iGPU at \~8 W — the consensus 2026 pick (smarthomeu.com, jrattechworks.com).

## RECOMMENDATION
Two-phase plan that fits this exact machine:

**Phase 1 — develop on the laptop now (all offline):**
1. HAOS in a Hyper-V Gen-2 VM: 3 GB static RAM, 2 vCPU, Secure Boot off, External vSwitch (use Ethernet via dock — avoid Wi-Fi bridging). Coexists fine with the 2 GB BlarAI VM (\~10 GB total system load, \~21 GB left for dev).
2. Inside HAOS, use add-ons for everything the novice will touch: Mosquitto add-on, Zigbee2MQTT add-on, Advanced Camera Card via HACS. This keeps the end-state one-box and one-click-updatable.
3. Buy the SMLIGHT SLZB-06MG24 Ethernet/PoE Zigbee coordinator (\~$45) — it sidesteps Hyper-V's hard no-USB-passthrough limitation entirely and lets the whole config move to any future host unchanged. Add an SLZB-MR3 or second ZBT-2 later only if Thread/Matter-over-Thread devices show up.
4. Run go2rtc 1.9.14 as a native Windows exe for camera restreaming and WebRTC; the coding agent builds dashboards against HA WebSocket API (state/control, long-lived access token) + go2rtc WebRTC/MSE endpoints (:1984/:8555). Target Lovelace as the primary dashboard; custom web app only for the multi-camera live wall.
5. For person detection during development, run Frigate 0.17.1 via Docker Desktop/WSL2 with the OpenVINO detector on `device: GPU` (`/dev/dxg` + `/usr/lib/wsl` mount). Accept that the NPU is unreachable from WSL2 today. Cap WSL2 RAM in the existing .wslconfig (e.g. 6 GB). Skip Blue Iris unless you decide the laptop is the permanent NVR — in that case $70 Blue Iris + free CodeProject.AI is the best native-Windows stack.
6. Buy ONVIF/RTSP PoE cameras (Reolink/Amcrest/Dahua class) — never cloud-only cams. Check which Dream Machine model you own: the original UDM cannot run UniFi Protect; a UDR can, and HA integrates with Protect locally.

**Phase 2 — when it must run 24/7 for real:** move the HAOS backup to a \~$160 Intel N150 mini PC (Beelink S13 class, 16 GB) running HAOS bare-metal with the Frigate add-on using OpenVINO on its iGPU. HA's full-backup restore makes the migration nearly turnkey, and the SLZB-06MG24 (network-attached) moves with zero reconfig. Do not buy HA Green ($199 since Jan 2026, too weak for camera AI). The laptop returns to being purely the dev machine, talking to the same HA/MQTT/go2rtc APIs over LAN.

## CAVEATS
- Frigate release dates were cross-checked (0.17.0 = 2026-02-27 via newreleases.io) but one fetched page rendered relative dates ambiguously; 0.17.1 date (\~2026-03-22) is medium confidence. Verify on github.com/blakeblackshear/frigate/releases.
- Intel iGPU OpenVINO inside Docker Desktop/WSL2 is community-supported, not officially documented by Frigate; it can break when Docker Desktop, the WSL kernel, or Intel compute-runtime update. The Arc 140V (Lunar Lake/Xe2) is newer than most reported WSL2 Frigate setups — expect some driver fiddling; have the CPU detector as fallback.
- The NPU (AI Boost, \~47 TOPS) is NOT usable by Frigate on this Windows machine today: no /dev/accel in WSL2, no USB/accelerator passthrough in Hyper-V. WSL 3's announced GPU/NPU passthrough (Build 2026, June 2) explicitly lists Lunar Lake but has no GA date — treat as future upside, not a plan.
- Hyper-V External vSwitch over the laptop's Wi-Fi NIC is flaky for mDNS/SSDP and may break HA device discovery and Matter commissioning; reliable operation effectively requires wired Ethernet. Default Switch (NAT) changes subnets across reboots.
- go2rtc Windows binary: the releases page fetch didn't enumerate win64 assets (truncated asset list), but Windows builds are an advertised core feature ("zero-dependency app for all OS: Windows, macOS, Linux"); confirm go2rtc_win64.zip exists on the v1.9.14 release before scripting installs.
- Laptop-as-server risks regardless of stack: Windows Update reboots, sleep/lid policies, single NVMe wear from continuous recording, and GPU RAM contention between Qwen3-14B INT4 (\~9 GB shared) and everything else. 24/7 camera recording on 230 GB free disk forces short retention.
- HA Green price ($199) and ZBT-2 availability reflect Jan/Nov 2025-26 announcements; street prices fluctuate. SLZB-06MG24 exact price not pinned in sources (\~$40-45 typical).
- Whether the user's "Dream Machine" supports UniFi Protect is unresolved (community page failed to load); original UDM = no Protect per long-standing Ubiquiti positioning — user should check their exact model in the UniFi OS console.
- Zigbee2MQTT exact 2.x minor version as of June 2026 was not pinned; its Windows guide currently specifies Node 22 LTS — Node 24 on this machine is newer and likely fine but unverified against Z2M's engine range.

## SOURCES
https://www.home-assistant.io/installation/windows/
https://www.home-assistant.io/blog/2025/05/22/deprecating-core-and-supervised-installation-methods-and-32-bit-systems/
https://www.home-assistant.io/blog/2026/06/03/release-20266/
https://www.home-assistant.io/installation/
https://joinhomeshift.com/home-assistant-install
https://docs.frigate.video/configuration/object_detectors/
https://docs.frigate.video/frigate/hardware/
https://docs.frigate.video/guides/configuring_go2rtc/
https://github.com/blakeblackshear/frigate/releases
https://newreleases.io/project/github/blakeblackshear/frigate/release/v0.17.0
https://github.com/blakeblackshear/frigate/discussions/13248
https://github.com/blakeblackshear/frigate/discussions/22421
https://github.com/blakeblackshear/frigate/discussions/21755
https://github.com/blakeblackshear/frigate/discussions/4375
https://www.cardus.com/2025/01/06/frigate-nvr-docker-in-a-hyper-v-vm-with-a-virtualized-partitioned-gpu/
https://github.com/AlexxIT/go2rtc
https://github.com/AlexxIT/go2rtc/releases
https://mosquitto.org/download/
https://www.zigbee2mqtt.io/guide/installation/05_windows.html
https://smarthomescene.com/top-picks/best-zigbee-coordinators-for-home-assistant/
https://www.home-assistant.io/blog/2025/11/19/home-assistant-connect-zbt-2/
https://www.cnx-software.com/2025/11/20/home-assistant-connect-zbt-2-zigbee-thread-usb-adapter/
https://smarthomescene.com/reviews/home-assistant-zbt-2-zigbee-and-thread-coordinator-review/
https://www.nabucasa.com/news/2026-01-08-green-pricing-change/
https://smarthomeu.com/blog/best-hardware-home-assistant-2026-green-vs-pi-5-vs-mini-pc-vs-nuc
https://jrattechworks.com/best-mini-pc-for-home-assistant/
https://www.wundertech.net/frigate-vs-blue-iris/
https://www.thesmarthomehookup.com/test_install/free-license-plate-reading-face-recognition-and-object-detection-for-blue-iris-full-walkthrough/
https://developers.home-assistant.io/docs/auth_api/
https://dashboard.flowfuse.com/
https://dashboard.flowfuse.com/user/home-assistant.html
https://github.com/dermotduffy/frigate-hass-card/issues/1827
https://www.techtimes.com/articles/317598/20260602/wsl-3-build-2026-near-native-gpu-npu-passthrough-brings-local-ai-windows.htm
https://github.com/intel/linux-npu-driver/issues/56
https://www.thesmartesthouse.com/products/zooz-800-series-z-wave-long-range-usb-stick-zst39
https://docs.shinobi.video/installation
https://community.ui.com/questions/UniFi-Protect-with-Base-Dream-Machine/46d2058f-8ae8-4633-a6a3-d86da6d8006d
https://pvrblog.com/brands/unifi/
