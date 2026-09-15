import 'dart:async';
import 'dart:typed_data';

/// Work for a header-nonce miner: an 80-byte header (the nonce field is
/// overwritten) and its target.
class MiningWork {
  final int id;
  final Uint8List header;
  final BigInt target;
  const MiningWork(this.id, this.header, this.target);
}

/// A nonce that meets the target, already checked with the CPU hash.
class FoundNonce {
  final int workId;
  final int nonce;
  final Uint8List powHash;
  const FoundNonce(this.workId, this.nonce, this.powHash);
}

class MinerStats {
  final String device;
  final double hashrate; // measured, including pauses
  final double fullSpeed; // while running
  final double duty;
  final int hashes;
  const MinerStats(this.device, this.hashrate, this.fullSpeed, this.duty, this.hashes);
}

/// Searches header nonces on one device (a GPU, or CPU threads). The
/// caller gives work and a duty (share of full speed) and gets found
/// nonces back.
abstract class HeaderMiner {
  /// Human name of the device, known after [start].
  String get device;
  MinerStats get stats;
  Stream<FoundNonce> get found;
  Stream<String> get errors;

  /// Throws when the device cannot be used.
  Future<void> start();

  /// Replaces the work (a new tip or template).
  void work(MiningWork w);

  /// Share of full speed, 0 to 1.
  void setDuty(double d);

  /// Stops searching until new work arrives.
  void pause();

  Future<void> stop();
}
