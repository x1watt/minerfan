/// OpenCL C source of scrypt(N=1024, r=1, p=1) over an 80-byte block
/// header, one work item per nonce. Written for minerfan from RFC 7914
/// (scrypt), FIPS 180-4 (SHA-256) and RFC 2104/8018 (HMAC, PBKDF2).
///
/// Arguments of `scrypt_search`:
/// - `hdr`: the header as 20 big-endian 32-bit words (word 19, the nonce,
///   is replaced per work item);
/// - `target`: the target as 8 little-endian 32-bit words (word 7 is the
///   most significant);
/// - `nonce0`: the nonce of work item 0;
/// - `v`: scratch, 128 KiB per work item of the launch;
/// - `out`: `out[0]` counts results, nonces follow (at most 255).
///
/// `scrypt_hash` has the same inputs but writes every hash (8 words per
/// work item, SHA-256 output order) for tests.
const String scryptKernelSource = r'''
#define ROTL(x, n) rotate((uint)(x), (uint)(n))
#define SWAP32(x) (as_uint(as_uchar4((uint)(x)).s3210))
#define CH(x, y, z) bitselect((z), (y), (x))
#define MAJ(x, y, z) bitselect((x), (y), (z) ^ (x))
#define S0(x) (ROTL(x, 30) ^ ROTL(x, 19) ^ ROTL(x, 10))
#define S1(x) (ROTL(x, 26) ^ ROTL(x, 21) ^ ROTL(x, 7))
#define s0(x) (ROTL(x, 25) ^ ROTL(x, 14) ^ ((x) >> 3))
#define s1(x) (ROTL(x, 15) ^ ROTL(x, 13) ^ ((x) >> 10))

__constant uint K256[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

void sha256_init(uint *s) {
  s[0] = 0x6a09e667; s[1] = 0xbb67ae85; s[2] = 0x3c6ef372; s[3] = 0xa54ff53a;
  s[4] = 0x510e527f; s[5] = 0x9b05688c; s[6] = 0x1f83d9ab; s[7] = 0x5be0cd19;
}

// One SHA-256 compression of the 16 big-endian words in w.
void sha256_block(uint *s, const uint *in) {
  uint w[16];
  for (int i = 0; i < 16; i++) w[i] = in[i];
  uint a = s[0], b = s[1], c = s[2], d = s[3], e = s[4], f = s[5], g = s[6], h = s[7];
  for (int i = 0; i < 64; i++) {
    uint wi;
    if (i < 16) {
      wi = w[i];
    } else {
      wi = s1(w[(i - 2) & 15]) + w[(i - 7) & 15] + s0(w[(i - 15) & 15]) + w[i & 15];
      w[i & 15] = wi;
    }
    uint t1 = h + S1(e) + CH(e, f, g) + K256[i] + wi;
    uint t2 = S0(a) + MAJ(a, b, c);
    h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  s[0] += a; s[1] += b; s[2] += c; s[3] += d; s[4] += e; s[5] += f; s[6] += g; s[7] += h;
}

void salsa8(uint *b) {
  uint x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7];
  uint x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15];
  for (int i = 0; i < 4; i++) {
    x4 ^= ROTL(x0 + x12, 7);  x8 ^= ROTL(x4 + x0, 9);   x12 ^= ROTL(x8 + x4, 13);  x0 ^= ROTL(x12 + x8, 18);
    x9 ^= ROTL(x5 + x1, 7);   x13 ^= ROTL(x9 + x5, 9);  x1 ^= ROTL(x13 + x9, 13);  x5 ^= ROTL(x1 + x13, 18);
    x14 ^= ROTL(x10 + x6, 7); x2 ^= ROTL(x14 + x10, 9); x6 ^= ROTL(x2 + x14, 13);  x10 ^= ROTL(x6 + x2, 18);
    x3 ^= ROTL(x15 + x11, 7); x7 ^= ROTL(x3 + x15, 9);  x11 ^= ROTL(x7 + x3, 13);  x15 ^= ROTL(x11 + x7, 18);
    x1 ^= ROTL(x0 + x3, 7);   x2 ^= ROTL(x1 + x0, 9);   x3 ^= ROTL(x2 + x1, 13);   x0 ^= ROTL(x3 + x2, 18);
    x6 ^= ROTL(x5 + x4, 7);   x7 ^= ROTL(x6 + x5, 9);   x4 ^= ROTL(x7 + x6, 13);   x5 ^= ROTL(x4 + x7, 18);
    x11 ^= ROTL(x10 + x9, 7); x8 ^= ROTL(x11 + x10, 9); x9 ^= ROTL(x8 + x11, 13);  x10 ^= ROTL(x9 + x8, 18);
    x12 ^= ROTL(x15 + x14, 7); x13 ^= ROTL(x12 + x15, 9); x14 ^= ROTL(x13 + x12, 13); x15 ^= ROTL(x14 + x13, 18);
  }
  b[0] += x0; b[1] += x1; b[2] += x2; b[3] += x3; b[4] += x4; b[5] += x5; b[6] += x6; b[7] += x7;
  b[8] += x8; b[9] += x9; b[10] += x10; b[11] += x11; b[12] += x12; b[13] += x13; b[14] += x14; b[15] += x15;
}

// BlockMix with r = 1: B0 = salsa(B0 ^ B1), B1 = salsa(B1 ^ B0).
void block_mix(uint *x) {
  for (int k = 0; k < 16; k++) x[k] ^= x[16 + k];
  salsa8(x);
  for (int k = 0; k < 16; k++) x[16 + k] ^= x[k];
  salsa8(x + 16);
}

// The whole scrypt of the header whose big-endian words are hw (word 19
// already holds the nonce); writes the 8 hash words (SHA-256 order).
void scrypt_header(const uint *hw, uint *hash, __global uint4 *v, uint gid, uint g) {
  uint blk[16], st[8], istate[8], ostate[8], hk[8], inner[8];
  // HMAC key: the 80-byte header is longer than a block, so K = SHA256(hdr).
  sha256_init(st);
  for (int i = 0; i < 16; i++) blk[i] = hw[i];
  sha256_block(st, blk);
  for (int i = 0; i < 4; i++) blk[i] = hw[16 + i];
  blk[4] = 0x80000000;
  for (int i = 5; i < 15; i++) blk[i] = 0;
  blk[15] = 80 * 8;
  sha256_block(st, blk);
  for (int i = 0; i < 8; i++) hk[i] = st[i];
  sha256_init(istate);
  sha256_init(ostate);
  for (int i = 0; i < 8; i++) blk[i] = hk[i] ^ 0x36363636;
  for (int i = 8; i < 16; i++) blk[i] = 0x36363636;
  sha256_block(istate, blk);
  for (int i = 0; i < 8; i++) blk[i] = hk[i] ^ 0x5c5c5c5c;
  for (int i = 8; i < 16; i++) blk[i] = 0x5c5c5c5c;
  sha256_block(ostate, blk);

  // PBKDF2(header, header, 1, 128): four HMAC blocks.
  uint x[32];
  uint mid[8];
  for (int i = 0; i < 8; i++) mid[i] = istate[i];
  for (int i = 0; i < 16; i++) blk[i] = hw[i];
  sha256_block(mid, blk);
  for (uint n = 1; n <= 4; n++) {
    for (int i = 0; i < 8; i++) st[i] = mid[i];
    for (int i = 0; i < 4; i++) blk[i] = hw[16 + i];
    blk[4] = n;
    blk[5] = 0x80000000;
    for (int i = 6; i < 15; i++) blk[i] = 0;
    blk[15] = (64 + 84) * 8;
    sha256_block(st, blk);
    for (int i = 0; i < 8; i++) inner[i] = st[i];
    for (int i = 0; i < 8; i++) st[i] = ostate[i];
    for (int i = 0; i < 8; i++) blk[i] = inner[i];
    blk[8] = 0x80000000;
    for (int i = 9; i < 15; i++) blk[i] = 0;
    blk[15] = (64 + 32) * 8;
    sha256_block(st, blk);
    for (int i = 0; i < 8; i++) x[(n - 1) * 8 + i] = SWAP32(st[i]);
  }

  // ROMix, N = 1024: V interleaved by work item for coalesced access.
  for (uint j = 0; j < 1024; j++) {
    for (int q = 0; q < 8; q++) v[(j * 8 + q) * g + gid] = (uint4)(x[4 * q], x[4 * q + 1], x[4 * q + 2], x[4 * q + 3]);
    block_mix(x);
  }
  for (uint i = 0; i < 1024; i++) {
    uint j = x[16] & 1023;
    for (int q = 0; q < 8; q++) {
      uint4 t = v[(j * 8 + q) * g + gid];
      x[4 * q] ^= t.x; x[4 * q + 1] ^= t.y; x[4 * q + 2] ^= t.z; x[4 * q + 3] ^= t.w;
    }
    block_mix(x);
  }

  // PBKDF2(header, B', 1, 32): salt is the 128 bytes of x, then INT(1).
  for (int i = 0; i < 8; i++) st[i] = istate[i];
  for (int i = 0; i < 16; i++) blk[i] = SWAP32(x[i]);
  sha256_block(st, blk);
  for (int i = 0; i < 16; i++) blk[i] = SWAP32(x[16 + i]);
  sha256_block(st, blk);
  blk[0] = 1;
  blk[1] = 0x80000000;
  for (int i = 2; i < 15; i++) blk[i] = 0;
  blk[15] = (64 + 132) * 8;
  sha256_block(st, blk);
  for (int i = 0; i < 8; i++) inner[i] = st[i];
  for (int i = 0; i < 8; i++) st[i] = ostate[i];
  for (int i = 0; i < 8; i++) blk[i] = inner[i];
  blk[8] = 0x80000000;
  for (int i = 9; i < 15; i++) blk[i] = 0;
  blk[15] = (64 + 32) * 8;
  sha256_block(st, blk);
  for (int i = 0; i < 8; i++) hash[i] = st[i];
}

__kernel void scrypt_search(__global const uint *hdr, __global const uint *target, uint nonce0,
                            __global uint4 *v, __global uint *out) {
  uint gid = get_global_id(0), g = get_global_size(0);
  uint hw[20];
  for (int i = 0; i < 19; i++) hw[i] = hdr[i];
  uint nonce = nonce0 + gid;
  hw[19] = SWAP32(nonce);
  uint h[8];
  scrypt_header(hw, h, v, gid, g);
  // The hash is a little-endian number: word k of it is SWAP32(h[k]).
  for (int k = 7; k >= 0; k--) {
    uint a = SWAP32(h[k]), t = target[k];
    if (a < t) break;
    if (a > t) return;
  }
  uint slot = atomic_inc(&out[0]);
  if (slot < 255) out[1 + slot] = nonce;
}

__kernel void scrypt_hash(__global const uint *hdr, __global const uint *target, uint nonce0,
                          __global uint4 *v, __global uint *out) {
  uint gid = get_global_id(0), g = get_global_size(0);
  uint hw[20];
  for (int i = 0; i < 19; i++) hw[i] = hdr[i];
  hw[19] = SWAP32(nonce0 + gid);
  uint h[8];
  scrypt_header(hw, h, v, gid, g);
  for (int i = 0; i < 8; i++) out[gid * 8 + i] = h[i];
}
''';
