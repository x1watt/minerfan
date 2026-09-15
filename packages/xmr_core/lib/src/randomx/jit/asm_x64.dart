import 'dart:typed_data';

/// A small x86-64 assembler: exactly the instruction forms the RandomX JIT
/// templates use (tevador/RandomX and xmrig `jit_compiler_x86_static.S`).
/// Registers are numbered as in the encoding (rax=0 .. r15=15, xmm0..15).

const int rax = 0, rcx = 1, rdx = 2, rbx = 3, rsp = 4, rbp = 5, rsi = 6, rdi = 7;
const int r8 = 8, r9 = 9, r10 = 10, r11 = 11, r12 = 12, r13 = 13, r14 = 14, r15 = 15;

/// A memory operand: `[base + index*scale + disp]`, or `[rip + label]`.
class Mem {
  final int base; // -1 for rip-relative
  final int index; // -1 for none
  final int scale;
  final int disp;
  final Label? label;
  const Mem(this.base, {this.index = -1, this.scale = 1, this.disp = 0}) : label = null;
  const Mem.rip(Label this.label)
      : base = -1,
        index = -1,
        scale = 1,
        disp = 0;
}

class Label {
  int pos = -1;
  final List<(int, int, int)> _uses = []; // (fixup position, size, next-instruction position)
}

class X64 {
  Uint8List _b = Uint8List(4096);
  int pos = 0;
  final List<(int, Label)> _ripFixups = [];

  Uint8List get bytes => Uint8List.sublistView(_b, 0, pos);

  void _grow(int n) {
    if (pos + n <= _b.length) return;
    final nb = Uint8List(_b.length * 2 + n);
    nb.setRange(0, pos, _b);
    _b = nb;
  }

  void db(int v) {
    _grow(1);
    _b[pos++] = v & 0xff;
  }

  void dbs(List<int> v) {
    for (final x in v) {
      db(x);
    }
  }

  void d32(int v) {
    for (var i = 0; i < 4; i++) {
      db(v >> (8 * i));
    }
  }

  void d64(int v) {
    for (var i = 0; i < 8; i++) {
      db(v >> (8 * i));
    }
  }

  /// Pads with zero bytes (data) or NOPs (code) to a multiple of [n].
  void align(int n, {bool code = true}) {
    while (pos % n != 0) {
      db(code ? 0x90 : 0);
    }
  }

  void bind(Label l) {
    l.pos = pos;
    for (final (at, size, next) in l._uses) {
      _patch(at, size, pos - next);
    }
    l._uses.clear();
  }

  void _patch(int at, int size, int rel) {
    if (size == 1) {
      if (rel < -128 || rel > 127) throw StateError('rel8 out of range: $rel');
      _b[at] = rel & 0xff;
    } else {
      for (var i = 0; i < 4; i++) {
        _b[at + i] = (rel >> (8 * i)) & 0xff;
      }
    }
  }

  void _rel(Label l, int size) {
    final at = pos;
    for (var i = 0; i < size; i++) {
      db(0);
    }
    if (l.pos >= 0) {
      _patch(at, size, l.pos - pos);
    } else {
      l._uses.add((at, size, pos));
    }
  }

  // ---- encoding core ----------------------------------------------------

  /// Emits [prefix] bytes, REX, [opcode] bytes and the ModRM (+SIB, disp)
  /// for `reg` and a register or memory [rm]. [immBytes] immediate bytes
  /// follow and must be emitted by the caller (they count for rip-relative
  /// displacements).
  void _op(List<int> prefix, bool w, List<int> opcode, int reg, Object rm, {int immBytes = 0, bool forceRex = false}) {
    dbs(prefix);
    final m = rm is Mem ? rm : null;
    final r = rm is int ? rm : 0;
    var rex = 0x40 | (w ? 8 : 0) | ((reg & 8) != 0 ? 4 : 0);
    if (m != null) {
      if (m.index >= 0 && (m.index & 8) != 0) rex |= 2;
      if (m.base >= 0 && (m.base & 8) != 0) rex |= 1;
    } else if ((r & 8) != 0) {
      rex |= 1;
    }
    if (rex != 0x40 || forceRex) db(rex);
    dbs(opcode);
    final regBits = (reg & 7) << 3;
    if (m == null) {
      db(0xC0 | regBits | (r & 7));
      return;
    }
    if (m.base < 0) {
      db(0x05 | regBits);
      final at = pos;
      d32(0);
      _ripFixups.add((at, m.label!));
      _ripImm = immBytes;
      return;
    }
    final base = m.base & 7;
    final hasIndex = m.index >= 0;
    int mod;
    if (m.disp == 0 && base != 5) {
      mod = 0;
    } else if (m.disp >= -128 && m.disp <= 127) {
      mod = 1;
    } else {
      mod = 2;
    }
    if (hasIndex || base == 4) {
      db((mod << 6) | regBits | 4);
      final ss = const {1: 0, 2: 1, 4: 2, 8: 3}[m.scale]!;
      final idx = hasIndex ? (m.index & 7) : 4;
      db((ss << 6) | (idx << 3) | base);
    } else {
      db((mod << 6) | regBits | base);
    }
    if (mod == 1) {
      db(m.disp);
    } else if (mod == 2) {
      d32(m.disp);
    }
  }

  int _ripImm = 0;

  /// Resolves rip-relative displacements once the instruction (including
  /// its immediate) is complete.
  void _endInstr() {
    if (_ripFixups.isEmpty) return;
    for (final (at, label) in _ripFixups) {
      final next = at + 4 + _ripImm;
      if (label.pos >= 0) {
        _patch(at, 4, label.pos - next);
      } else {
        label._uses.add((at, 4, next));
      }
    }
    _ripFixups.clear();
    _ripImm = 0;
  }

  void _i(List<int> prefix, bool w, List<int> opcode, int reg, Object rm) {
    _op(prefix, w, opcode, reg, rm);
    _endInstr();
  }

  // ---- integer instructions --------------------------------------------

  void movRR(int dst, int src) => _i(const [], true, const [0x8B], dst, src);
  void movRR32(int dst, int src) => _i(const [], false, const [0x8B], dst, src);
  void movRM(int dst, Mem m) => _i(const [], true, const [0x8B], dst, m);
  void movMR(Mem m, int src) => _i(const [], true, const [0x89], src, m);
  void movRM32(int dst, Mem m) => _i(const [], false, const [0x8B], dst, m);
  void movMR32(Mem m, int src) => _i(const [], false, const [0x89], src, m);

  void movRI64(int dst, int imm) {
    db(0x48 | ((dst & 8) != 0 ? 1 : 0));
    db(0xB8 + (dst & 7));
    d64(imm);
  }

  void movMI32(Mem m, int imm) {
    _op(const [], false, const [0xC7], 0, m, immBytes: 4);
    d32(imm);
    _endInstr();
  }

  void xorRR(int dst, int src) => _i(const [], true, const [0x33], dst, src);
  void xorRM(int dst, Mem m) => _i(const [], true, const [0x33], dst, m);
  void xorRM32(int dst, Mem m) => _i(const [], false, const [0x33], dst, m);
  void addRR(int dst, int src) => _i(const [], true, const [0x03], dst, src);
  void cmpRM(int dst, Mem m) => _i(const [], true, const [0x3B], dst, m);
  void cmpRR(int dst, int src) => _i(const [], true, const [0x3B], dst, src);
  void leaRM(int dst, Mem m) => _i(const [], true, const [0x8D], dst, m);
  void imulRM(int dst, Mem m) => _i(const [], true, const [0x0F, 0xAF], dst, m);

  void _grp1(bool w, int ext, int dst, int imm) {
    if (imm >= -128 && imm <= 127) {
      _op(const [], w, const [0x83], ext, dst);
      db(imm);
    } else {
      _op(const [], w, const [0x81], ext, dst);
      d32(imm);
    }
  }

  void addRI(int dst, int imm) => _grp1(true, 0, dst, imm);
  void subRI(int dst, int imm) => _grp1(true, 5, dst, imm);
  void andRI32(int dst, int imm) {
    _op(const [], false, const [0x81], 4, dst);
    d32(imm); // always imm32 so the mask can be patched in place
  }

  void andRI(int dst, int imm) => _grp1(true, 4, dst, imm);

  void _shift(bool w, int ext, int dst, int imm) {
    _op(const [], w, const [0xC1], ext, dst);
    db(imm);
  }

  void rorRI(int dst, int imm) => _shift(true, 1, dst, imm);
  void shlRI(int dst, int imm) => _shift(true, 4, dst, imm);
  void shrRI(int dst, int imm) => _shift(true, 5, dst, imm);

  void push(int r) {
    if (r >= 8) db(0x41);
    db(0x50 + (r & 7));
  }

  void pop(int r) {
    if (r >= 8) db(0x41);
    db(0x58 + (r & 7));
  }

  void ret() => db(0xC3);
  void nop() => db(0x90);

  void jmp(Label l, {bool short = false}) {
    if (short) {
      db(0xEB);
      _rel(l, 1);
    } else {
      db(0xE9);
      _rel(l, 4);
    }
  }

  /// Conditional jump; [cc] is the condition nibble (2 = b, 4 = z, 5 = nz).
  void jcc(int cc, Label l, {bool short = false}) {
    if (short) {
      db(0x70 + cc);
      _rel(l, 1);
    } else {
      db(0x0F);
      db(0x80 + cc);
      _rel(l, 4);
    }
  }

  void call(Label l) {
    db(0xE8);
    _rel(l, 4);
  }

  void prefetchnta(Mem m) => _i(const [], false, const [0x0F, 0x18], 0, m);
  void prefetcht0(Mem m) => _i(const [], false, const [0x0F, 0x18], 1, m);
  void prefetchw(Mem m) => _i(const [], false, const [0x0F, 0x0D], 1, m);

  // ---- SSE ----------------------------------------------------------------

  void movapdRM(int x, Mem m) => _i(const [0x66], false, const [0x0F, 0x28], x, m);
  void movapdMR(Mem m, int x) => _i(const [0x66], false, const [0x0F, 0x29], x, m);
  void movdqaRM(int x, Mem m) => _i(const [0x66], false, const [0x0F, 0x6F], x, m);
  void movdqaMR(Mem m, int x) => _i(const [0x66], false, const [0x0F, 0x7F], x, m);
  void movdquRM(int x, Mem m) => _i(const [0xF3], false, const [0x0F, 0x6F], x, m);
  void movdquMR(Mem m, int x) => _i(const [0xF3], false, const [0x0F, 0x7F], x, m);
  void cvtdq2pdRM(int x, Mem m) => _i(const [0xF3], false, const [0x0F, 0xE6], x, m);
  void andpd(int x, int y) => _i(const [0x66], false, const [0x0F, 0x54], x, y);
  void orpd(int x, int y) => _i(const [0x66], false, const [0x0F, 0x56], x, y);
  void xorpd(int x, int y) => _i(const [0x66], false, const [0x0F, 0x57], x, y);
  void pxor(int x, int y) => _i(const [0x66], false, const [0x0F, 0xEF], x, y);
  void aesenc(int x, int y) => _i(const [0x66], false, const [0x0F, 0x38, 0xDC], x, y);
  void aesdec(int x, int y) => _i(const [0x66], false, const [0x0F, 0x38, 0xDE], x, y);
  void aesencM(int x, Mem m) => _i(const [0x66], false, const [0x0F, 0x38, 0xDC], x, m);
  void aesdecM(int x, Mem m) => _i(const [0x66], false, const [0x0F, 0x38, 0xDE], x, m);
  void ldmxcsr(Mem m) => _i(const [], false, const [0x0F, 0xAE], 2, m);
  void stmxcsr(Mem m) => _i(const [], false, const [0x0F, 0xAE], 3, m);

  /// `rorx rdx, rax, 32` (BMI2), the one VEX form the templates need.
  void rorxRdxRax32() => dbs(const [0xC4, 0xE3, 0xFB, 0xF0, 0xD0, 0x20]);

  /// `vzeroupper`.
  void vzeroupper() => dbs(const [0xC5, 0xF8, 0x77]);
}
