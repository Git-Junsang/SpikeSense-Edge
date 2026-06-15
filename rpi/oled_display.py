"""oled_display.py — 1.3" I2C OLED(SH1106) 상태 표시 (데모용)
=============================================================
demo.py에서 "현재 음이 정상/비정상인지"를 OLED에 띄운다.

하드웨어: 1.30인치 I2C OLED는 보통 **SH1106**(128×64) 컨트롤러다.
          (0.96인치는 SSD1306 — --oled-controller ssd1306 로 전환)
배선:     VCC=3V3, GND, SDA=GPIO2(pin3), SCL=GPIO3(pin5)
사전준비: raspi-config로 I2C 활성화, `i2cdetect -y 1`로 주소 확인(보통 0x3c)
의존성:   luma.oled (pip install luma.oled) — Pillow·smbus2 자동 설치

luma/Pillow가 없거나 OLED가 안 붙어도 데모가 죽지 않도록, 초기화 실패 시
모든 출력은 무시되고 콘솔 로그만 남는다(헤드리스/데스크톱 검증 가능).
"""
import os

_FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def _load_font(size):
    from PIL import ImageFont
    for p in _FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


class OledDisplay:
    """SH1106/SSD1306 128×64 상태 디스플레이. 초기화 실패 시 무동작(no-op)."""

    LABELS = {0: "NORMAL", 1: "ANOMALY"}

    def __init__(self, controller="sh1106", i2c_port=1, i2c_addr=0x3c,
                 rotate=0, enabled=True):
        self.dev = None
        self._canvas = None
        self.font_s = None
        self.font_m = None
        if not enabled:
            print("  [OLED] 비활성화(--no-oled) → 콘솔만 사용")
            return
        try:
            from luma.core.interface.serial import i2c
            from luma.core.render import canvas
            from luma.oled.device import sh1106, ssd1306
            serial = i2c(port=i2c_port, address=i2c_addr)
            cls = ssd1306 if controller == "ssd1306" else sh1106
            self.dev = cls(serial, rotate=rotate)
            self._canvas = canvas
            self.font_s = _load_font(11)
            self.font_m = _load_font(18)
            print(f"  [OLED] {controller} @ I2C 0x{i2c_addr:02x} "
                  f"(port {i2c_port}) 초기화 OK")
        except Exception as e:
            self.dev = None
            print(f"  [OLED] 초기화 실패 → 콘솔만 사용 ({type(e).__name__}: {e})")

    # ── 내부: 트랙 한 행(정상/이상) 그리기 ───────────────────
    def _row(self, draw, y, text, highlight):
        # 이상(highlight)이면 흰 박스 반전 → 멀리서도 한눈에
        if highlight:
            draw.rectangle((0, y, 127, y + 21), outline="white", fill="white")
            draw.text((4, y + 1), text, font=self.font_m, fill="black")
        else:
            draw.text((4, y + 1), text, font=self.font_m, fill="white")

    # ── 두 트랙 상태 화면 ────────────────────────────────────
    def show_status(self, step, total, l0, l1):
        if self.dev is None:
            return
        with self._canvas(self.dev) as draw:
            draw.text((0, 0), "SpikeSense", font=self.font_s, fill="white")
            draw.text((104, 0), f"{step}/{total}", font=self.font_s, fill="white")
            self._row(draw, 16, f"T0 {self.LABELS[l0]}", l0 == 1)
            self._row(draw, 40, f"T1 {self.LABELS[l1]}", l1 == 1)

    # ── 전송 중 화면 ─────────────────────────────────────────
    def show_sending(self, step, total, track_id):
        if self.dev is None:
            return
        with self._canvas(self.dev) as draw:
            draw.text((0, 0), "SpikeSense", font=self.font_s, fill="white")
            draw.text((104, 0), f"{step}/{total}", font=self.font_s, fill="white")
            draw.text((4, 24), f"sending T{track_id} ...",
                      font=self.font_m, fill="white")

    # ── 자유 텍스트 여러 줄 ──────────────────────────────────
    def show_lines(self, lines):
        if self.dev is None:
            return
        with self._canvas(self.dev) as draw:
            y = 0
            for ln in lines[:5]:
                draw.text((0, y), ln, font=self.font_s, fill="white")
                y += 13

    def clear(self):
        if self.dev is None:
            return
        with self._canvas(self.dev) as draw:
            draw.rectangle(self.dev.bounding_box, outline="black", fill="black")
