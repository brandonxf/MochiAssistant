#!/usr/bin/env python3
"""Sintetiza los efectos de sonido de la isla (WAV mono 16 bit, 48 kHz) en ui/sounds/."""
import wave
from pathlib import Path

import numpy as np

SR = 48000
OUT = Path(__file__).resolve().parent.parent / "ui" / "sounds"


def tone(f0, f1=None, dur=0.12, vol=0.5, attack=0.006, shape="sine", vib=0.0):
    """Tono con barrido de frecuencia f0→f1 y envolvente de ataque + caída exponencial."""
    f1 = f0 if f1 is None else f1
    t = np.linspace(0, dur, int(SR * dur), endpoint=False)
    f = f0 + (f1 - f0) * (t / dur) ** 0.7
    if vib:
        f = f * (1 + vib * np.sin(2 * np.pi * 28 * t))
    ph = 2 * np.pi * np.cumsum(f) / SR
    w = np.sin(ph)
    if shape == "soft":  # añade un armónico suave: timbre de campanita
        w = 0.8 * w + 0.2 * np.sin(2 * ph) + 0.08 * np.sin(3 * ph)
    env = np.minimum(1, t / attack) * np.exp(-4.2 * t / dur)
    return vol * w * env


def seq(*parts, gap=0.0):
    out = []
    for p in parts:
        out.append(p)
        if gap:
            out.append(np.zeros(int(SR * gap)))
    return np.concatenate(out)


def mix(*parts):
    n = max(len(p) for p in parts)
    out = np.zeros(n)
    for p in parts:
        out[: len(p)] += p
    return out


def delay(sig, secs):
    return np.concatenate([np.zeros(int(SR * secs)), sig])


def save(name, sig):
    sig = np.concatenate([sig, np.zeros(int(SR * 0.02))])
    peak = np.max(np.abs(sig)) or 1
    sig = sig / max(peak, 1) * min(peak, 0.9)
    data = (np.clip(sig, -1, 1) * 32767).astype("<i2")
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


C5, E5, G5, C6, E6 = 523.25, 659.25, 783.99, 1046.5, 1318.5

sounds = {
    # Asomarse y saludar
    "peek": tone(420, 760, 0.11, 0.45, shape="soft"),
    "greet": seq(tone(G5, G5 * 1.04, 0.09, 0.4, shape="soft"), tone(C6, C6, 0.16, 0.4, shape="soft"), gap=0.015),
    # Abrir / cerrar la isla
    "open": tone(300, 640, 0.17, 0.4, shape="soft"),
    "close": tone(640, 280, 0.15, 0.35, shape="soft"),
    # Micro-interacciones
    "hover": tone(880, 960, 0.05, 0.22, shape="soft"),
    "blip": tone(1200, 1200, 0.04, 0.25),
    "pop": tone(350, 900, 0.08, 0.5),
    "slap": mix(tone(180, 60, 0.12, 0.7), tone(900, 200, 0.05, 0.3)),
    "annoyed": seq(tone(330, 240, 0.12, 0.35, vib=0.03), tone(300, 200, 0.16, 0.35, vib=0.03), gap=0.03),
    "dizzy": seq(*[tone(500 + 250 * np.sin(i), 500 + 250 * np.sin(i + 1.4), 0.1, 0.3, vib=0.05) for i in range(7)]),
    "love": seq(tone(E5, E5, 0.12, 0.3, shape="soft"), tone(G5, G5, 0.12, 0.3, shape="soft"), tone(C6, C6, 0.22, 0.3, shape="soft")),
    # Estados del agente
    "approval": seq(tone(C6, C6, 0.1, 0.4, shape="soft"), tone(E6, E6, 0.1, 0.4, shape="soft"), tone(C6, C6, 0.18, 0.4, shape="soft"), gap=0.04),
    "question": seq(tone(E5, E5 * 1.25, 0.16, 0.4, shape="soft"), tone(G5, G5 * 1.3, 0.2, 0.4, shape="soft"), gap=0.03),
    "error": seq(tone(260, 190, 0.16, 0.45), tone(200, 140, 0.24, 0.45), gap=0.03),
    "finish": seq(tone(C5, C5, 0.1, 0.4, shape="soft"), tone(E5, E5, 0.1, 0.4, shape="soft"), tone(G5, G5, 0.1, 0.4, shape="soft"),
                  mix(tone(C6, C6, 0.45, 0.45, shape="soft"), tone(E6, E6, 0.45, 0.25, shape="soft")), gap=0.02),
    "approve": seq(tone(G5, G5, 0.07, 0.4, shape="soft"), tone(C6, C6, 0.16, 0.4, shape="soft"), gap=0.01),
    "deny": seq(tone(330, 330, 0.08, 0.4, shape="soft"), tone(220, 220, 0.18, 0.4, shape="soft"), gap=0.01),
    # Archivos y chat
    "gulp": seq(tone(500, 180, 0.09, 0.5), tone(320, 120, 0.11, 0.5), gap=0.02),
    "send": tone(500, 1500, 0.1, 0.35, shape="soft"),
    "receive": tone(1400, 700, 0.1, 0.3, shape="soft"),
}

OUT.mkdir(parents=True, exist_ok=True)
for name, sig in sounds.items():
    save(name, sig)
print(f"{len(sounds)} sonidos en {OUT}")
