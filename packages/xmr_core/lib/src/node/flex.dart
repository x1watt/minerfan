/// One sample of how busy the machine is apart from the miner.
class FlexReading {
  /// Cores' worth of CPU other programs used since the last sample; null
  /// when the OS does not tell.
  final double? otherCores;

  /// Memory the OS can hand out without swapping, and physical memory;
  /// null when unknown.
  final int? availableBytes;
  final int? totalBytes;

  const FlexReading({this.otherCores, this.availableBytes, this.totalBytes});
}

/// Flexible CPU/RAM mining: mines in the machine's idle time and gets out of
/// the way of the user's work.
///
/// CPU: every core's worth of CPU that other programs use takes one mining
/// thread off (all of them when other programs fill the machine). Threads
/// come off at once and come back one per [upStepMs] once the load is gone.
///
/// RAM: below [lowFraction] of physical memory free, the fast-mode dataset
/// ([datasetBytes], 2 GiB) is given back and mining continues in light
/// mode; below [criticalFraction] mining pauses. The dataset is rebuilt only
/// after [datasetBackMs] with room for it plus a margin.
class FlexGovernor {
  final int maxThreads;
  final int datasetBytes;
  final int upStepMs;
  final int datasetBackMs;
  final double lowFraction;
  final double criticalFraction;

  int threads;

  /// Whether the fast-mode dataset may be kept (false: give it back).
  bool datasetWanted = true;

  /// Whether there has been room to build a dataset for [datasetBackMs].
  bool datasetRoom = false;

  /// Why mining is held back, for the log and the UI; empty when it is not.
  String note = '';

  /// The memory part of [note] (changes rarely, so it is logged).
  String memoryNote = '';

  /// Free memory below which the dataset is given back, for a machine with
  /// [totalBytes] of memory (the pool builds a dataset only when this much
  /// stays free besides it).
  static int lowMark(int totalBytes, [double fraction = 0.15]) => _max((totalBytes * fraction).round(), _gib);

  double? _other;
  int _upSinceMs = -1;
  int _roomSinceMs = -1;
  bool _memPaused = false;

  FlexGovernor(
    this.maxThreads, {
    this.datasetBytes = 0,
    this.upStepMs = 6000,
    this.datasetBackMs = 180000,
    this.lowFraction = 0.15,
    this.criticalFraction = 0.12,
  }) : threads = maxThreads;

  static const _gib = 1 << 30;

  int update(FlexReading r, int nowMs) {
    // CPU: smooth the samples a little, so one busy moment does not
    // take threads off and put them back two seconds later.
    final o = r.otherCores;
    if (o != null) _other = _other == null ? o : _other! * 0.5 + o * 0.5;
    final other = _other ?? 0;
    // Half a core of hysteresis: threads come off at 0.7 of a core and come
    // back below 0.2, so a load near a boundary does not flap.
    final cpuTarget = (maxThreads - (other + 0.3).floor()).clamp(0, maxThreads);
    final cpuUpTarget = (maxThreads - (other + 0.8).floor()).clamp(0, maxThreads);

    // RAM.
    final avail = r.availableBytes, total = r.totalBytes;
    var memNote = '';
    if (avail != null && total != null && total > 0) {
      final low = lowMark(total, lowFraction);
      final critical = _max((total * criticalFraction).round(), _gib ~/ 2);
      if (_memPaused ? avail < critical + _gib ~/ 4 : avail < critical) {
        _memPaused = true;
      } else {
        _memPaused = false;
      }
      if (datasetBytes > 0) {
        // Room for a dataset with memory still above the low mark, and a
        // margin, for a few minutes in a row.
        if (avail >= datasetBytes + low + _gib) {
          if (_roomSinceMs < 0) _roomSinceMs = nowMs;
        } else {
          _roomSinceMs = -1;
        }
        datasetRoom = _roomSinceMs >= 0 && nowMs - _roomSinceMs >= datasetBackMs;
        if (datasetWanted && avail < low) {
          datasetWanted = false;
        } else if (!datasetWanted && datasetRoom) {
          datasetWanted = true;
        }
      }
      if (_memPaused) {
        memNote = 'paused: ${avail >> 20} MiB of memory free';
      } else if (!datasetWanted) {
        memNote = 'fast mode off: memory is needed by other programs';
      }
    }

    memoryNote = memNote;
    final target = _memPaused ? 0 : cpuTarget;
    final upTarget = _memPaused ? 0 : cpuUpTarget;
    if (target < threads) {
      threads = target;
      _upSinceMs = -1;
    } else if (upTarget > threads) {
      if (_upSinceMs < 0) {
        _upSinceMs = nowMs;
      } else if (nowMs - _upSinceMs >= upStepMs) {
        threads++;
        _upSinceMs = threads < upTarget ? nowMs : -1;
      }
    } else {
      _upSinceMs = -1;
    }

    note = [
      if (memNote.isNotEmpty) memNote,
      if (!_memPaused && threads < maxThreads)
        threads < cpuUpTarget ? 'adding threads back' : 'other programs use ${other.toStringAsFixed(1)} cores',
    ].join('; ');
    return threads;
  }

  static int _max(int a, int b) => a > b ? a : b;
}
