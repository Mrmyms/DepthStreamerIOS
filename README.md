# DepthStreamerIOS

> Real-time RGB + LiDAR depth streaming from iPhone to Python/OpenCV — free, open source, and developer-ready.

![iOS 16+](https://img.shields.io/badge/iOS-16%2B-blue?logo=apple)
![License MIT](https://img.shields.io/badge/License-MIT-green)
![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-blue?logo=python)
![LiDAR Required](https://img.shields.io/badge/Hardware-LiDAR%20Required-red)

---

## What is this?

DepthStreamer turns your iPhone Pro into a professional **RGB-D camera** — streaming synchronized color video and LiDAR depth data over WiFi to any Python script in real time.

No paid apps. No USB cables. No extra hardware. Just your iPhone and your Mac.


<img width="1178" height="739" alt="Screenshot 2026-03-19 at 10 53 20 a m" src="https://github.com/user-attachments/assets/1e4f7cd6-eed8-412c-9542-5dd49700990d" />


---

## Features

- 📡 **Live MJPEG stream** — plug directly into `cv2.VideoCapture()` like a webcam
- 📏 **Real-time LiDAR depth** — accurate distance in meters for every pixel
- 🔒 **Hyperfocal focus lock** — everything in frame stays sharp, no bokeh
- 🎯 **Tap to focus** — touch any point on screen to force focus there
- 📊 **Live stats** — FPS, resolution, connected clients, frame count
- 🔄 **Auto-restart** — recovers from interruptions automatically
- 🖥️ **Clean UI** — built for real use, not demos

---

## Requirements

**iPhone:**
- iPhone 12 Pro or later (LiDAR required)
- iOS 16+
- Xcode 15+ to build and install

**Mac / Python:**
- Python 3.10+
- Same WiFi network as the iPhone

---

## Installation

### 1. Build the iOS app

```bash
git clone https://github.com/Mrmyms/DepthStreamerIOS
```

1. Open `DepthStreamer.xcodeproj` in Xcode
2. Select your iPhone as the target device
3. Set your Apple ID in **Signing & Capabilities**
4. Press `⌘R` to build and install
5. Trust the developer certificate on your iPhone: **Settings → General → VPN & Device Management**

### 2. Install Python dependencies

```bash
pip install ultralytics opencv-python mediapipe numpy requests
```

### 3. Run

Open the app on your iPhone, press **Iniciar Stream**, note the IP address shown, then:

```bash
python yolo_depth.py --ip 192.168.1.X
```

---

## API Endpoints

Once the app is streaming:

| Endpoint | Format | Use |
|----------|--------|-----|
| `http://IP:8080/video` | MJPEG | `cv2.VideoCapture()` |
| `http://IP:8080/depth` | Binary float32 | Raw depth in meters |
| `http://IP:8080/` | HTML | Status page |

### Depth packet format

```
[4 bytes] width   (uint32 big-endian)
[4 bytes] height  (uint32 big-endian)
[w×h×4 bytes] float32 array — distance in meters per pixel
```

### Minimal Python example

```python
import cv2

cap = cv2.VideoCapture("http://192.168.1.X:8080/video")

while True:
    ret, frame = cap.read()
    if ret:
        cv2.imshow("DepthStreamer", frame)
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break
```

---

## Full pipeline — YOLO + Skeleton + Hand gestures + LiDAR depth

The included `yolo_depth.py` demonstrates the full stack:

- **YOLOv8** object detection with real distance in meters on every bounding box
- **YOLOv8-pose** full body skeleton (17 keypoints)
- **MediaPipe Hands** hand skeleton (21 keypoints per hand)
- Gesture recognition: Pinch, Fist, Thumbs up, Peace
- Live depth colormap visualization (press `D`)

```bash
python yolo_depth.py --ip 192.168.1.X
```

| Key | Action |
|-----|--------|
| `Q` | Quit |
| `S` | Save screenshot |
| `D` | Toggle depth colormap |

---

## Possible applications

- 🤖 **Robotics** — affordable RGB-D sensor for obstacle avoidance
- 🏠 **Smart home** — gesture control without extra hardware
- 🏥 **Rehabilitation** — real-time posture and movement analysis
- 🔒 **Security** — people counting, zone intrusion with distance
- 🎓 **Research** — accessible depth data for computer vision projects
- 📐 **Spatial measurement** — measure real-world objects with LiDAR
- 🎮 **Interaction** — control apps and games with hand gestures

---

## Compatibility

| Device | LiDAR | Status |
|--------|-------|--------|
| iPhone 12 Pro / Pro Max | ✅ | ✅ Full |
| iPhone 13 Pro / Pro Max | ✅ | ✅ Full |
| iPhone 14 Pro / Pro Max | ✅ | ✅ Full |
| iPhone 15 Pro / Pro Max | ✅ | ✅ Full |
| iPhone 12 / 13 / 14 / 15 (standard) | ❌ | Video only |
| iPad Pro 2020+ | ✅ | ✅ Full |

---

## License

MIT — free to use, modify, and distribute.
**Credit required** — you must keep the original copyright notice in all copies.

```
Copyright (c) 2026 Manuel Yobani Martinez Sanchez
```

---

## Author

**Manuel Yobani Martinez Sanchez**
 Powered by ARKit, YOLO, and MediaPipe.

*If this project helped you, a ⭐ on GitHub goes a long way.*
[README.md](https://github.com/user-attachments/files/26119233/README.md)



