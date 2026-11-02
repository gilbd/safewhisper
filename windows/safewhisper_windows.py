"""SafeWhisper Windows tray client.

This client intentionally uses the same local JSON protocol as macOS. It never
opens a TCP listener: the helper socket is a local AF_UNIX socket supported by
modern Windows 10/11.
"""
from __future__ import annotations

import ctypes
import json
import logging
import os
import socket
import tempfile
import threading
import time
import wave
from ctypes import wintypes
from pathlib import Path

import pyperclip
import sounddevice as sd
from PIL import Image, ImageDraw
import pystray

SOCKET_PATH = Path(os.environ.get("SAFEWHISPER_HELPER_SOCKET", Path(os.environ.get("LOCALAPPDATA", Path.home())) / "SafeWhisper" / "run" / "helper.sock"))
CHUNK_SECONDS = 20
SAMPLE_RATE = 16_000
CHANNELS = 1
SAMPLE_WIDTH = 2


class SafeWhisperWindows:
    def __init__(self) -> None:
        log_path = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "SafeWhisper" / "windows.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        logging.basicConfig(filename=log_path, level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        logging.info("SafeWhisper Windows starting; socket=%s", SOCKET_PATH)
        self.recording = False
        self.cancel_requested = False
        self.frames = bytearray()
        self.lock = threading.Lock()
        self.recording_thread: threading.Thread | None = None
        self.language = os.environ.get("SAFEWHISPER_LANGUAGE", "auto")
        self.icon = pystray.Icon(
            "SafeWhisper",
            self._icon_image(),
            "SafeWhisper",
            menu=pystray.Menu(
                pystray.MenuItem("Auto-detect", lambda icon, item: self._set_language("auto"), checked=lambda item: self.language == "auto"),
                pystray.MenuItem("Hebrew", lambda icon, item: self._set_language("he"), checked=lambda item: self.language == "he"),
                pystray.MenuItem("English", lambda icon, item: self._set_language("en"), checked=lambda item: self.language == "en"),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Quit SafeWhisper", lambda icon, item: icon.stop()),
            ),
        )
        self._install_hotkeys()

    def _set_language(self, language: str) -> None:
        self.language = language
        os.environ["SAFEWHISPER_LANGUAGE"] = language
        self.icon.update_menu()

    def _icon_image(self) -> Image.Image:
        image = Image.new("RGBA", (64, 64), (18, 20, 28, 255))
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((9, 9, 55, 55), radius=12, outline="white", width=4)
        draw.ellipse((25, 17, 39, 39), outline="white", width=3)
        draw.arc((19, 27, 45, 48), 0, 180, fill="white", width=3)
        draw.line((32, 39, 32, 48), fill="white", width=3)
        return image

    def _install_hotkeys(self) -> None:
        self.hotkey_thread = threading.Thread(target=self._run_windows_keyboard_hook, daemon=True)
        self.hotkey_thread.start()

    def _run_windows_keyboard_hook(self) -> None:
        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32
        WH_KEYBOARD_LL = 13
        WM_KEYDOWN = 0x0100
        WM_SYSKEYDOWN = 0x0104
        WM_KEYUP = 0x0101
        WM_SYSKEYUP = 0x0105
        VK_ESCAPE = 0x1B
        VK_CONTROL = {0xA2, 0xA3}
        VK_MENU = {0xA4, 0xA5}
        VK_SHIFT = {0x10, 0xA0, 0xA1}
        VK_K = 0x4B
        pressed = {"ctrl": False, "alt": False, "shift": False, "hotkey": False}
        callback_type = ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)

        class KBDLLHOOKSTRUCT(ctypes.Structure):
            _fields_ = [("vkCode", wintypes.DWORD), ("scanCode", wintypes.DWORD), ("flags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.POINTER(wintypes.ULONG))]

        @callback_type
        def callback(code, wparam, lparam):
            if code >= 0 and wparam in (WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP):
                key = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents.vkCode
                down = wparam in (WM_KEYDOWN, WM_SYSKEYDOWN)
                if key in VK_CONTROL: pressed["ctrl"] = down
                if key in VK_MENU: pressed["alt"] = down
                if key in VK_SHIFT: pressed["shift"] = down
                if down and key == VK_ESCAPE:
                    self.cancel_recording()
                if down and key == VK_K and pressed["ctrl"] and pressed["alt"] and pressed["shift"] and not pressed["hotkey"]:
                    pressed["hotkey"] = True
                    self.toggle_recording()
                if not down and key == VK_K:
                    pressed["hotkey"] = False
            return user32.CallNextHookEx(None, code, wparam, lparam)

        hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, callback, kernel32.GetModuleHandleW(None), 0)
        if not hook:
            logging.exception("SetWindowsHookExW failed: %s", ctypes.get_last_error())
            return
        logging.info("Global Win32 keyboard hook registered")
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))
        user32.UnhookWindowsHookEx(hook)

    def toggle_recording(self) -> None:
        if self.recording:
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self) -> None:
        with self.lock:
            if self.recording:
                return
            self.recording = True
            self.cancel_requested = False
            self.frames.clear()
        self.recording_thread = threading.Thread(target=self._capture, daemon=True)
        self.recording_thread.start()

    def _capture(self) -> None:
        def callback(indata, frame_count, time_info, status):
            if status:
                print(f"SafeWhisper audio: {status}")
            with self.lock:
                if self.recording:
                    self.frames.extend(bytes(indata))

        try:
            with sd.RawInputStream(samplerate=SAMPLE_RATE, blocksize=0, dtype="int16", channels=CHANNELS, callback=callback):
                while True:
                    with self.lock:
                        if not self.recording:
                            break
                    time.sleep(0.05)
        except Exception as exc:
            with self.lock:
                self.recording = False
            print(f"SafeWhisper recording failed: {exc}")

    def cancel_recording(self) -> None:
        with self.lock:
            if not self.recording:
                return
            self.cancel_requested = True
            self.recording = False
            self.frames.clear()

    def stop_recording(self) -> None:
        with self.lock:
            if not self.recording:
                return
            self.recording = False
            if self.cancel_requested or not self.frames:
                self.frames.clear()
                return
            audio = bytes(self.frames)
            self.frames.clear()
        threading.Thread(target=self._transcribe_audio, args=(audio,), daemon=True).start()

    def _transcribe_audio(self, audio: bytes) -> None:
        language = self.language
        with tempfile.TemporaryDirectory(prefix="safewhisper-") as temp_dir:
            source = Path(temp_dir) / "recording.wav"
            self._write_wav(source, audio)
            result = []
            with wave.open(str(source), "rb") as wav:
                frames_per_chunk = SAMPLE_RATE * CHUNK_SECONDS
                offset = 0
                while offset < wav.getnframes():
                    count = min(frames_per_chunk, wav.getnframes() - offset)
                    wav.setpos(offset)
                    chunk = wav.readframes(count)
                    if not chunk:
                        break
                    chunk_path = Path(temp_dir) / f"chunk-{offset}.wav"
                    self._write_wav(chunk_path, chunk)
                    response = self._request({"type": "transcribe", "suffix": ".wav", "language": language, "audio_base64": __import__("base64").b64encode(chunk).decode("ascii")})
                    if not response.get("ok"):
                        raise RuntimeError(response.get("error", "transcription failed"))
                    if response.get("text", "").strip():
                        result.append(response["text"].strip())
                    offset += count
            text = " ".join(result).strip()
            if text:
                self._paste(text)

    def _write_wav(self, path: Path, data: bytes) -> None:
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(CHANNELS)
            wav.setsampwidth(SAMPLE_WIDTH)
            wav.setframerate(SAMPLE_RATE)
            wav.writeframes(data)

    def _request(self, payload: dict) -> dict:
        SOCKET_PATH.parent.mkdir(parents=True, exist_ok=True)
        encoded = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(300)
            client.connect(str(SOCKET_PATH))
            client.sendall(encoded)
            data = bytearray()
            while not data.endswith(b"\n"):
                chunk = client.recv(65536)
                if not chunk:
                    raise RuntimeError("SafeWhisper helper closed the local pipe")
                data.extend(chunk)
        return json.loads(data.decode("utf-8"))

    def _paste(self, text: str) -> None:
        pyperclip.copy(text)
        time.sleep(0.08)
        ctypes.windll.user32.keybd_event(0x11, 0, 0, 0)  # CTRL down
        ctypes.windll.user32.keybd_event(0x56, 0, 0, 0)  # V down
        ctypes.windll.user32.keybd_event(0x56, 0, 2, 0)  # V up
        ctypes.windll.user32.keybd_event(0x11, 0, 2, 0)  # CTRL up

    def run(self) -> None:
        self.icon.run()


if __name__ == "__main__":
    SafeWhisperWindows().run()
