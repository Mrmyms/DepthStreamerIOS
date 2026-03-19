"""
YOLO + MediaPipe + DepthStreamer (HTTP MJPEG)
Igual que DroidCam pero con profundidad LiDAR

Instalación:
    pip install ultralytics opencv-python mediapipe numpy requests

Uso:
    python yolo_depth.py --ip 192.168.1.50
"""

import cv2
import argparse
import time
import math
import struct
import threading
import numpy as np
import requests
from collections import defaultdict
from ultralytics import YOLO
import mediapipe as mp

# ─── Configuración ────────────────────────────────────────────────────────────

DEFAULT_IP     = "10.48.206.201"
IPHONE_PORT    = 8080
MODEL_SIZE     = "yolov8n-pose.pt"
MODEL_OBJECTS  = "yolov8n.pt"
CONF_THRESHOLD = 0.45
SHOW_FPS       = True
SHOW_LABELS    = True
SHOW_CONF      = True
MAX_FPS        = 10
FRAME_INTERVAL = 1.0 / MAX_FPS

PALETTE = [
    (56, 210, 120), (255, 180, 30), (80, 160, 255), (220, 80, 80),
    (180, 80, 220), (80, 220, 220), (255, 120, 60),  (120, 255, 120),
]

def get_color(class_id):
    return PALETTE[class_id % len(PALETTE)]

# ─── Estado compartido ────────────────────────────────────────────────────────

latest_depth = None
depth_lock   = threading.Lock()

# ─── Hilo de profundidad ──────────────────────────────────────────────────────

def depth_thread(ip, port):
    global latest_depth
    url = f"http://{ip}:{port}/depth"
    while True:
        try:
            with requests.get(url, stream=True, timeout=5) as r:
                buf = b""
                for chunk in r.iter_content(chunk_size=4096):
                    buf += chunk
                    while len(buf) >= 8:
                        w = struct.unpack(">I", buf[0:4])[0]
                        h = struct.unpack(">I", buf[4:8])[0]
                        total = 8 + w * h * 4
                        if len(buf) < total:
                            break
                        depth = np.frombuffer(buf[8:total], dtype=np.float32).reshape((h, w))
                        buf   = buf[total:]
                        with depth_lock:
                            latest_depth = depth
        except Exception as e:
            print(f"⚠️  Depth stream: {e} — reintentando...")
            time.sleep(1)

# ─── Helpers ──────────────────────────────────────────────────────────────────

def get_distance_meters(depth, x, y, rgb_w, rgb_h):
    d_h, d_w = depth.shape
    dx = int(np.clip(x * d_w / rgb_w, 0, d_w - 1))
    dy = int(np.clip(y * d_h / rgb_h, 0, d_h - 1))
    return float(depth[dy, dx])

def draw_box(frame, x1, y1, x2, y2, label, conf, color, depth=None, rgb_w=1, rgb_h=1):
    cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
    if SHOW_LABELS:
        dist_str = ""
        if depth is not None:
            metros = get_distance_meters(depth, (x1+x2)//2, (y1+y2)//2, rgb_w, rgb_h)
            dist_str = f" {metros:.1f}m"
        text = f"{label} {conf:.0%}{dist_str}" if SHOW_CONF else f"{label}{dist_str}"
        font = cv2.FONT_HERSHEY_SIMPLEX
        (tw, th), _ = cv2.getTextSize(text, font, 0.55, 1)
        pad = 4
        cv2.rectangle(frame, (x1, y1-th-pad*2), (x1+tw+pad*2, y1), color, -1)
        cv2.putText(frame, text, (x1+pad, y1-pad), font, 0.55, (0,0,0), 1, cv2.LINE_AA)

def draw_hud(frame, fps, counts):
    lines = [f"FPS: {fps:.1f}"] + [f"  {n}: {c}" for n, c in sorted(counts.items())]
    pad, lh = 10, 22
    overlay = frame.copy()
    cv2.rectangle(overlay, (0,0), (200, pad*2+len(lines)*lh), (0,0,0), -1)
    cv2.addWeighted(overlay, 0.45, frame, 0.55, 0, frame)
    for i, line in enumerate(lines):
        cv2.putText(frame, line, (pad, pad+lh*(i+1)-4),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.52,
                    (180,255,180) if i==0 else (220,220,220), 1, cv2.LINE_AA)

LANDMARK_NAMES = [
    "muñeca",
    "pulgar_base","pulgar_medio","pulgar_nudillo","pulgar_punta",
    "indice_base","indice_medio","indice_nudillo","indice_punta",
    "medio_base","medio_medio","medio_nudillo","medio_punta",
    "anular_base","anular_medio","anular_nudillo","anular_punta",
    "menique_base","menique_medio","menique_nudillo","menique_punta",
]

def landmarks_a_dict(lm, w, h):
    return {name: (int(lm[i].x*w), int(lm[i].y*h))
            for i, name in enumerate(LANDMARK_NAMES)}

def distancia(pts, a, b):
    x1,y1=pts[a]; x2,y2=pts[b]
    return math.sqrt((x2-x1)**2+(y2-y1)**2)

def distancia_relativa(pts, a, b):
    ref = distancia(pts, "muñeca", "medio_base")
    return distancia(pts,a,b)/ref if ref > 0 else 0

def es_puno(pts):
    return all([pts["indice_punta"][1]  > pts["indice_base"][1],
                pts["medio_punta"][1]   > pts["medio_base"][1],
                pts["anular_punta"][1]  > pts["anular_base"][1],
                pts["menique_punta"][1] > pts["menique_base"][1]])

def es_paz(pts):
    return (pts["indice_punta"][1] < pts["indice_base"][1] and
            pts["medio_punta"][1]  < pts["medio_base"][1]  and
            pts["anular_punta"][1] > pts["anular_base"][1] and
            pts["menique_punta"][1]> pts["menique_base"][1])

def es_pulgar_arriba(pts):
    return (pts["pulgar_punta"][1]  < pts["pulgar_nudillo"][1] and
            pts["indice_punta"][1]  > pts["indice_base"][1]    and
            pts["medio_punta"][1]   > pts["medio_base"][1]     and
            pts["anular_punta"][1]  > pts["anular_base"][1]    and
            pts["menique_punta"][1] > pts["menique_base"][1])

def detectar_gesto(pts):
    if distancia_relativa(pts, "pulgar_punta", "indice_punta") < 0.3:
        return "Pinch"
    elif es_puno(pts):    return "Puno"
    elif es_pulgar_arriba(pts): return "Pulgar arriba"
    elif es_paz(pts):     return "Paz"
    return ""

SKELETON = [(5,7),(7,9),(6,8),(8,10),(5,6),(5,11),(6,12),
            (11,13),(13,15),(12,14),(14,16)]

# ─── Main ─────────────────────────────────────────────────────────────────────

def main(args):
    video_url = f"http://{args.ip}:{IPHONE_PORT}/video"
    print(f"📡  Conectando a {video_url}")

    threading.Thread(target=depth_thread, args=(args.ip, IPHONE_PORT), daemon=True).start()

    cap = cv2.VideoCapture(video_url)
    if not cap.isOpened():
        print("❌  No se pudo conectar. Verifica que la app esté transmitiendo.")
        return

    print("✅  Video conectado")
    print("🔍  Cargando modelos YOLO ...")
    model         = YOLO(MODEL_SIZE)
    model_objects = YOLO(MODEL_OBJECTS)
    print("✅  Modelos listos")

    mp_hands       = mp.solutions.hands
    mp_drawing     = mp.solutions.drawing_utils
    hands_detector = mp_hands.Hands(
        max_num_hands=2,
        min_detection_confidence=0.6,
        min_tracking_confidence=0.5,
    )

    print("     Q=salir  S=screenshot  D=depth\n")

    prev_time       = time.time()
    fps             = 0.0
    last_frame_time = 0.0
    screenshot_n    = 0
    show_depth      = False

    while True:
        ret, frame = cap.read()
        if not ret:
            time.sleep(0.05)
            continue

        now = time.time()
        if now - last_frame_time < FRAME_INTERVAL:
            continue
        last_frame_time = now

        h, w = frame.shape[:2]
        counts = defaultdict(int)

        with depth_lock:
            depth = latest_depth.copy() if latest_depth is not None else None

        # YOLO objetos
        for box in model_objects(frame, conf=CONF_THRESHOLD, verbose=False)[0].boxes:
            cls_id = int(box.cls[0])
            conf   = float(box.conf[0])
            name   = model_objects.names[cls_id]
            x1,y1,x2,y2 = map(int, box.xyxy[0])
            draw_box(frame, x1,y1,x2,y2, name, conf, get_color(cls_id), depth, w, h)
            counts[name] += 1

        # YOLO pose
        results_pose = model(frame, conf=CONF_THRESHOLD, verbose=False)[0]
        if results_pose.keypoints is not None:
            for person in results_pose.keypoints.xy:
                for x, y in person:
                    cv2.circle(frame, (int(x),int(y)), 4, (0,255,0), -1)
                for a,b in SKELETON:
                    xa,ya=person[a]; xb,yb=person[b]
                    cv2.line(frame,(int(xa),int(ya)),(int(xb),int(yb)),(255,180,0),2)

        # MediaPipe
        results_hands = hands_detector.process(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        if results_hands.multi_hand_landmarks:
            for hl in results_hands.multi_hand_landmarks:
                mp_drawing.draw_landmarks(frame, hl, mp_hands.HAND_CONNECTIONS)
                pts   = landmarks_a_dict(hl.landmark, w, h)
                gesto = detectar_gesto(pts)
                dist_str = ""
                if depth is not None:
                    mx,my = pts["muñeca"]
                    dist_str = f" {get_distance_meters(depth,mx,my,w,h):.1f}m"
                if gesto:
                    cv2.putText(frame, f"{gesto}{dist_str}",
                                (pts["muñeca"][0], pts["muñeca"][1]-20),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0,255,255), 2, cv2.LINE_AA)

        # Depth colormap
        if show_depth and depth is not None:
            d     = np.clip(depth, 0.3, 10.0)
            d     = (255-((d-0.3)/4.7*255)).astype(np.uint8)
            d_vis = cv2.resize(cv2.applyColorMap(d, cv2.COLORMAP_BONE),(w,h))
            frame = np.hstack([frame, d_vis])

        # FPS
        elapsed   = time.time() - prev_time
        fps       = 0.85*fps + 0.15*(1.0/max(elapsed,1e-6))
        prev_time = time.time()
        if SHOW_FPS:
            draw_hud(frame, fps, counts)

        cv2.imshow("YOLO + DepthStreamer  |  Q=salir  S=screenshot  D=depth", frame)

        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):   break
        elif key == ord('s'):
            screenshot_n += 1
            cv2.imwrite(f"screenshot_{screenshot_n:03d}.jpg", frame)
            print(f"📸  screenshot_{screenshot_n:03d}.jpg")
        elif key == ord('d'):
            show_depth = not show_depth

    hands_detector.close()
    cap.release()
    cv2.destroyAllWindows()
    print("👋  Cerrado")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip",   default=DEFAULT_IP)
    parser.add_argument("--conf", default=CONF_THRESHOLD, type=float)
    args = parser.parse_args()
    CONF_THRESHOLD = args.conf
    main(args)
