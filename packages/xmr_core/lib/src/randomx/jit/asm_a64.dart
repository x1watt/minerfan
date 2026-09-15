import 'dart:typed_data';

/// A small AArch64 assembler: the instruction forms used by the RandomX
/// ARM64 JIT templates (xmrig `jit_compiler_a64_static.S`, BSD-3-Clause).
/// Registers are plain numbers: x0..x30 (31 = xzr or sp depending on the
/// instruction), v0..v31.

class A64Label {
  int pos = -1; // byte offset
  final List<(int, int)> _uses = []; // (instruction offset, kind)
}

const int _kB26 = 0, _kB19 = 1, _kAdr = 2;

class A64 {
  Uint8List _b = Uint8List(8192);
  int pos = 0;

  Uint8List get bytes => Uint8List.sublistView(_b, 0, pos);

  void _grow(int n) {
    if (pos + n <= _b.length) return;
    final nb = Uint8List(_b.length * 2 + n);
    nb.setRange(0, pos, _b);
    _b = nb;
  }

  /// Emits one 32-bit instruction word.
  void w(int v) {
    _grow(4);
    _b[pos] = v & 0xff;
    _b[pos + 1] = (v >> 8) & 0xff;
    _b[pos + 2] = (v >> 16) & 0xff;
    _b[pos + 3] = (v >> 24) & 0xff;
    pos += 4;
  }

  void d64(int v) {
    w(v);
    w(v >> 32);
  }

  int _read(int at) => _b[at] | (_b[at + 1] << 8) | (_b[at + 2] << 16) | (_b[at + 3] << 24);

  void _write(int at, int v) {
    _b[at] = v & 0xff;
    _b[at + 1] = (v >> 8) & 0xff;
    _b[at + 2] = (v >> 16) & 0xff;
    _b[at + 3] = (v >> 24) & 0xff;
  }

  void bind(A64Label l) {
    l.pos = pos;
    for (final (at, kind) in l._uses) {
      _fix(at, kind, pos - at);
    }
    l._uses.clear();
  }

  void _fix(int at, int kind, int rel) {
    final v = _read(at);
    switch (kind) {
      case _kB26:
        _write(at, v | ((rel >> 2) & 0x3FFFFFF));
      case _kB19:
        _write(at, v | (((rel >> 2) & 0x7FFFF) << 5));
      case _kAdr:
        _write(at, v | ((rel & 3) << 29) | (((rel >> 2) & 0x7FFFF) << 5));
    }
  }

  void _ref(int word, A64Label l, int kind) {
    final at = pos;
    w(word);
    if (l.pos >= 0) {
      _fix(at, kind, l.pos - at);
    } else {
      l._uses.add((at, kind));
    }
  }

  void align(int n) {
    while (pos % n != 0) {
      w(0xD503201F); // nop
    }
  }

  void zeros(int bytes) {
    for (var i = 0; i < bytes; i += 4) {
      w(0);
    }
  }

  // ---- branches ---------------------------------------------------------

  void b(A64Label l) => _ref(0x14000000, l, _kB26);
  void bl(A64Label l) => _ref(0x94000000, l, _kB26);
  void bne(A64Label l) => _ref(0x54000001, l, _kB19);
  void blo(A64Label l) => _ref(0x54000003, l, _kB19);
  void adr(int rd, A64Label l) => _ref(0x10000000 | rd, l, _kAdr);
  void ret() => w(0xD65F03C0);

  // ---- integer ------------------------------------------------------------

  void movReg(int rd, int rm) => w(0xAA0003E0 | (rm << 16) | rd); // orr rd, xzr, rm
  void movReg32(int rd, int rm) => w(0x2A0003E0 | (rm << 16) | rd);
  void movXzr(int rd) => movReg(rd, 31);
  void movz(int rd, int imm16, {int hw = 0}) => w(0xD2800000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | rd);
  void addReg(int rd, int rn, int rm, {int lsl = 0}) => w(0x8B000000 | (rm << 16) | (lsl << 10) | (rn << 5) | rd);
  void eorReg(int rd, int rn, int rm) => w(0xCA000000 | (rm << 16) | (rn << 5) | rd);
  void addImm(int rd, int rn, int imm12) => w(0x91000000 | ((imm12 & 0xFFF) << 10) | (rn << 5) | rd);
  void subImm(int rd, int rn, int imm12) => w(0xD1000000 | ((imm12 & 0xFFF) << 10) | (rn << 5) | rd);
  void subsImm(int rd, int rn, int imm12) => w(0xF1000000 | ((imm12 & 0xFFF) << 10) | (rn << 5) | rd);
  void cmpReg(int rn, int rm) => w(0xEB000000 | (rm << 16) | (rn << 5) | 31);
  void madd(int rd, int rn, int rm, int ra) => w(0x9B000000 | (rm << 16) | (ra << 10) | (rn << 5) | rd);
  void lsrImm(int rd, int rn, int sh) => w(0xD340FC00 | (sh << 16) | (rn << 5) | rd);
  void rorImm(int rd, int rn, int sh) => w(0x93C00000 | (rn << 16) | (sh << 10) | (rn << 5) | rd);
  void rbit(int rd, int rn) => w(0xDAC00000 | (rn << 5) | rd);
  void mrsFpcr(int rt) => w(0xD53B4400 | rt);
  void msrFpcr(int rt) => w(0xD51B4400 | rt);

  /// `and wd, wn, #1`: a placeholder the JIT overwrites with the real mask.
  void andW1(int rd, int rn) => w(0x12000000 | (rn << 5) | rd);

  /// `and xd, xn, #1` placeholder.
  void andX1(int rd, int rn) => w(0x92400000 | (rn << 5) | rd);

  // ---- loads and stores --------------------------------------------------

  void stp(int rt, int rt2, int rn, int off) => w(0xA9000000 | (((off >> 3) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt);
  void ldp(int rt, int rt2, int rn, int off) => w(0xA9400000 | (((off >> 3) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt);
  void stpPre(int rt, int rt2, int rn, int off) => w(0xA9800000 | (((off >> 3) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt);
  void ldpPost(int rt, int rt2, int rn, int off) => w(0xA8C00000 | (((off >> 3) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt);
  void stpD(int rt, int rt2, int rn, int off) => w(0x6D000000 | (((off >> 3) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt);
  void ldpD(int rt, int rt2, int rn, int off) => w(0x6D400000 | (((off >> 3) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt);
  void stpQ(int rt, int rt2, int rn, int off) => w(0xAD000000 | (((off >> 4) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt);
  void ldpQ(int rt, int rt2, int rn, int off) => w(0xAD400000 | (((off >> 4) & 0x7F) << 15) | (rt2 << 10) | (rn << 5) | rt);
  void str(int rt, int rn, int off) => w(0xF9000000 | ((off >> 3) << 10) | (rn << 5) | rt);
  void ldr(int rt, int rn, int off) => w(0xF9400000 | ((off >> 3) << 10) | (rn << 5) | rt);
  void strW(int rt, int rn, int off) => w(0xB9000000 | ((off >> 2) << 10) | (rn << 5) | rt);
  void ldrW(int rt, int rn, int off) => w(0xB9400000 | ((off >> 2) << 10) | (rn << 5) | rt);
  void strPre(int rt, int rn, int off) => w(0xF8000C00 | ((off & 0x1FF) << 12) | (rn << 5) | rt);
  void ldrPost(int rt, int rn, int off) => w(0xF8400400 | ((off & 0x1FF) << 12) | (rn << 5) | rt);
  void ldrQ(int rt, int rn, int off) => w(0x3DC00000 | ((off >> 4) << 10) | (rn << 5) | rt);
  void prfmPldl2strm(int rn) => w(0xF9800003 | (rn << 5));

  // ---- SIMD ---------------------------------------------------------------

  void sxtl(int vd, int vn) => w(0x0F20A400 | (vn << 5) | vd); // .2d <- .2s
  void sxtl2(int vd, int vn) => w(0x4F20A400 | (vn << 5) | vd); // .2d <- .4s high
  void scvtf2d(int vd, int vn) => w(0x4E61D800 | (vn << 5) | vd);
  void andV(int vd, int vn, int vm) => w(0x4E201C00 | (vm << 16) | (vn << 5) | vd);
  void orrV(int vd, int vn, int vm) => w(0x4EA01C00 | (vm << 16) | (vn << 5) | vd);
  void eorV(int vd, int vn, int vm) => w(0x6E201C00 | (vm << 16) | (vn << 5) | vd);
  void dup2d(int vd, int xn) => w(0x4E080C00 | (xn << 5) | vd);
  void moviZero4s(int vd) => w(0x4F000400 | vd);
  void aese(int vd, int vn) => w(0x4E284800 | (vn << 5) | vd);
  void aesd(int vd, int vn) => w(0x4E285800 | (vn << 5) | vd);
  void aesmc(int vd, int vn) => w(0x4E286800 | (vn << 5) | vd);
  void aesimc(int vd, int vn) => w(0x4E287800 | (vn << 5) | vd);

  /// `movi vd.2d, #0x00FFFFFFFFFFFFFF`.
  void moviMantissaMask(int vd) => w(0x6F00E400 | (3 << 16) | (0x1F << 5) | vd);
}
