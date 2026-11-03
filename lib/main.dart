import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

// ─────────────────────────────────────────────────────────────
//  ENTRY POINT
// ─────────────────────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StepCounterApp());
}

class StepCounterApp extends StatelessWidget {
  const StepCounterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Step Counter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          brightness: Brightness.light,
        ),
        fontFamily: 'SF Pro Display', // falls back to system sans-serif
      ),
      home: const StepCounterScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  ACTIVITY ENUM
// ─────────────────────────────────────────────────────────────
enum ActivityType { idle, walking, jogging, running }

extension ActivityExt on ActivityType {
  String get label {
    switch (this) {
      case ActivityType.idle:    return 'Idle';
      case ActivityType.walking: return 'Walking';
      case ActivityType.jogging: return 'Jogging';
      case ActivityType.running: return 'Running';
    }
  }

  IconData get icon {
    switch (this) {
      case ActivityType.idle:    return Icons.self_improvement_rounded;
      case ActivityType.walking: return Icons.directions_walk_rounded;
      case ActivityType.jogging: return Icons.directions_run_rounded;
      case ActivityType.running: return Icons.flash_on_rounded;
    }
  }

  Color get color {
    switch (this) {
      case ActivityType.idle:    return const Color(0xFF90A4AE);
      case ActivityType.walking: return const Color(0xFF42A5F5);
      case ActivityType.jogging: return const Color(0xFF66BB6A);
      case ActivityType.running: return const Color(0xFFEF5350);
    }
  }
}

// ─────────────────────────────────────────────────────────────
//  STEP COUNTER SCREEN
// ─────────────────────────────────────────────────────────────
class StepCounterScreen extends StatefulWidget {
  const StepCounterScreen({super.key});

  @override
  State<StepCounterScreen> createState() => _StepCounterScreenState();
}

class _StepCounterScreenState extends State<StepCounterScreen>
    with SingleTickerProviderStateMixin {

  // ── Tracking state ──────────────────────────────────────────
  bool _isTracking = false;
  bool _hasPaused  = false;
  int  _stepCount  = 0;

  // ── Timer ────────────────────────────────────────────────────
  Timer?    _timer;
  Duration  _elapsed = Duration.zero;

  // ── Activity / SPM ──────────────────────────────────────────
  ActivityType _activity = ActivityType.idle;
  final List<int> _stepTimestamps = []; // unix ms of each step

  // ── Sensor subscription ─────────────────────────────────────
  StreamSubscription<AccelerometerEvent>? _accelSub;

  // ── Low-pass filter state ────────────────────────────────────
  // Smooths raw accelerometer to reduce noise / phone vibration.
  // α close to 0 = heavy smoothing; α close to 1 = little smoothing.
  static const double _alpha = 0.1;
  double _filtX = 0, _filtY = 0, _filtZ = 0;

  // ── Magnitude ring buffer for dynamic threshold ───────────────
  // We keep the last N magnitudes to compute a rolling average
  // and set a threshold ABOVE the baseline — this adapts to the
  // user's walking style and device orientation.
  static const int _bufferSize = 30;
  final List<double> _magBuffer = [];

  // ── Peak detection state ─────────────────────────────────────
  double _prevMag        = 0;       // previous filtered magnitude
  bool   _risingEdge     = false;   // we are on the rising slope
  static const double _minPeakAboveBaseline = 1.8; // m/s² above mean
  static const int    _refractoryMs         = 250;  // min ms between steps
  int _lastStepTime = 0; // unix ms of last accepted step

  // ── Animation controller for step pulse ─────────────────────
  late final AnimationController _pulseCtrl;
  late final Animation<double>   _pulseAnim;

  // ────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _timer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────
  //  CONTROLS
  // ─────────────────────────────────────────────────────────────

  void _startTracking() {
    setState(() {
      _isTracking = true;
      _hasPaused  = false;
    });
    _startTimer();
    _startAccelerometer();
  }

  void _pauseTracking() {
    setState(() {
      _isTracking = false;
      _hasPaused  = true;
    });
    _timer?.cancel();
    _accelSub?.cancel();
    _accelSub = null;
  }

  void _continueTracking() {
    setState(() {
      _isTracking = true;
      _hasPaused  = false;
    });
    _startTimer();
    _startAccelerometer();
  }

  void _resetTracking() {
    _timer?.cancel();
    _accelSub?.cancel();
    _accelSub = null;
    setState(() {
      _isTracking   = false;
      _hasPaused    = false;
      _stepCount    = 0;
      _elapsed      = Duration.zero;
      _activity     = ActivityType.idle;
      _stepTimestamps.clear();
      _magBuffer.clear();
      _filtX = _filtY = _filtZ = 0;
      _prevMag = 0;
      _risingEdge  = false;
      _lastStepTime = 0;
    });
  }

  // ─────────────────────────────────────────────────────────────
  //  TIMER
  // ─────────────────────────────────────────────────────────────

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _elapsed += const Duration(seconds: 1));
      }
    });
  }

  String _formatDuration(Duration d) {
    final h  = d.inHours.toString().padLeft(2, '0');
    final m  = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s  = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  // ─────────────────────────────────────────────────────────────
  //  ACCELEROMETER + STEP DETECTION
  // ─────────────────────────────────────────────────────────────

  void _startAccelerometer() {
    // sensors_plus emits AccelerometerEvent at ~50–100 Hz on most devices.
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval, // ~20 ms → ~50 Hz
    ).listen(_onAccelEvent);
  }

  void _onAccelEvent(AccelerometerEvent event) {
    // ── 1. Low-pass filter (exponential moving average) ──────────
    // Removes high-frequency noise (vibration, small shakes).
    // Only the slow, periodic walking signal passes through.
    _filtX = _alpha * event.x + (1 - _alpha) * _filtX;
    _filtY = _alpha * event.y + (1 - _alpha) * _filtY;
    _filtZ = _alpha * event.z + (1 - _alpha) * _filtZ;

    // ── 2. Compute vector magnitude ──────────────────────────────
    // Using total acceleration magnitude removes orientation
    // dependency — the algorithm works regardless of how the
    // phone is held (pocket, hand, armband, etc.).
    final double mag = sqrt(
      _filtX * _filtX + _filtY * _filtY + _filtZ * _filtZ,
    );

    // ── 3. Maintain rolling magnitude buffer ─────────────────────
    // Used to compute a dynamic baseline and threshold.
    _magBuffer.add(mag);
    if (_magBuffer.length > _bufferSize) _magBuffer.removeAt(0);

    // ── 4. Dynamic threshold from rolling baseline ───────────────
    // Baseline = mean of recent magnitudes (~gravity + slight motion).
    // A step peak must exceed baseline + _minPeakAboveBaseline.
    double baseline = _magBuffer.reduce((a, b) => a + b) / _magBuffer.length;
    double threshold = baseline + _minPeakAboveBaseline;

    // ── 5. Peak detection ────────────────────────────────────────
    // A step is counted when:
    //  (a) We are on the FALLING edge (prev > current),
    //  (b) Previous value exceeded the threshold (it was a peak),
    //  (c) Refractory period has passed (avoids double-counting).
    final bool fallingEdge = _prevMag > mag;
    final bool wasPeak     = _prevMag > threshold;
    final int  nowMs       = DateTime.now().millisecondsSinceEpoch;
    final bool refractoryOk =
        (nowMs - _lastStepTime) >= _refractoryMs;

    if (_risingEdge && fallingEdge && wasPeak && refractoryOk) {
      // ✅ Valid step detected
      _lastStepTime = nowMs;
      _risingEdge   = false;
      _countStep(nowMs);
    }

    // Track whether we are on a rising slope
    if (mag > _prevMag) _risingEdge = true;

    _prevMag = mag;
  }

  // ─────────────────────────────────────────────────────────────
  //  STEP COUNTING + ACTIVITY DETECTION
  // ─────────────────────────────────────────────────────────────

  void _countStep(int nowMs) {
    // Prune timestamps older than 60 seconds for SPM calculation
    _stepTimestamps.add(nowMs);
    _stepTimestamps.removeWhere(
      (t) => (nowMs - t) > 60000,
    );

    // SPM = steps in the last 60 s window
    final int spm = _stepTimestamps.length;

    ActivityType activity;
    if (spm < 60)       activity = ActivityType.idle;
    else if (spm < 110) activity = ActivityType.walking;
    else if (spm < 150) activity = ActivityType.jogging;
    else                activity = ActivityType.running;

    if (mounted) {
      setState(() {
        _stepCount++;
        _activity = activity;
      });
      // Pulse animation on each step
      _pulseCtrl.forward(from: 0);
    }
  }

  // ─────────────────────────────────────────────────────────────
  //  UI
  // ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            children: [
              _buildGradientHeader(),
              const SizedBox(height: 20),
              _buildStepCard(),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(child: _buildTimerCard()),
                    const SizedBox(width: 14),
                    Expanded(child: _buildActivityCard()),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _buildControls(),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  // ── Gradient Header ─────────────────────────────────────────
  Widget _buildGradientHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
        ),
        borderRadius: BorderRadius.only(
          bottomLeft:  Radius.circular(36),
          bottomRight: Radius.circular(36),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.directions_walk_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Step Counter',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Accelerometer-based tracking',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 22),
          // Status pill
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _isTracking
                  ? Colors.greenAccent.withOpacity(0.25)
                  : Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: _isTracking
                    ? Colors.greenAccent.withOpacity(0.6)
                    : Colors.white24,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _isTracking ? Colors.greenAccent : Colors.white54,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _isTracking
                      ? 'Tracking Active'
                      : _hasPaused
                          ? 'Paused'
                          : 'Not Tracking',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Large Step Counter Card ─────────────────────────────────
  Widget _buildStepCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1976D2).withOpacity(0.10),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            const Text(
              'Total Steps',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF90A4AE),
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 14),
            ScaleTransition(
              scale: _pulseAnim,
              child: Text(
                '$_stepCount',
                style: const TextStyle(
                  fontSize: 80,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1565C0),
                  height: 1.0,
                  letterSpacing: -4,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.local_fire_department_rounded,
                    color: Colors.orange.shade400, size: 18),
                const SizedBox(width: 4),
                Text(
                  '${(_stepCount * 0.04).toStringAsFixed(1)} kcal  •  '
                  '${(_stepCount * 0.00075).toStringAsFixed(2)} km',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF78909C),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Timer Card ──────────────────────────────────────────────
  Widget _buildTimerCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F2FD),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.timer_rounded,
              color: Color(0xFF1976D2),
              size: 20,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Duration',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF90A4AE),
              fontWeight: FontWeight.w500,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatDuration(_elapsed),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A237E),
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }

  // ── Activity Card ───────────────────────────────────────────
  Widget _buildActivityCard() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _activity.color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _activity.icon,
              color: _activity.color,
              size: 20,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Activity',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF90A4AE),
              fontWeight: FontWeight.w500,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              _activity.label,
              key: ValueKey(_activity),
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: _activity.color,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Controls ────────────────────────────────────────────────
  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          // Primary action button
          if (!_isTracking && !_hasPaused)
            _primaryButton(
              label: 'Start',
              icon: Icons.play_arrow_rounded,
              color: const Color(0xFF1976D2),
              onTap: _startTracking,
            ),

          if (_isTracking)
            _primaryButton(
              label: 'Pause',
              icon: Icons.pause_rounded,
              color: const Color(0xFFFB8C00),
              onTap: _pauseTracking,
            ),

          if (!_isTracking && _hasPaused)
            _primaryButton(
              label: 'Continue',
              icon: Icons.play_circle_filled_rounded,
              color: const Color(0xFF43A047),
              onTap: _continueTracking,
            ),

          const SizedBox(height: 14),

          // Reset button (only visible when there's data)
          if (_stepCount > 0 || _hasPaused)
            SizedBox(
              width: double.infinity,
              height: 54,
              child: OutlinedButton.icon(
                onPressed: _resetTracking,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text(
                  'Reset',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFEF5350),
                  side: const BorderSide(
                    color: Color(0xFFEF5350),
                    width: 1.5,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 60,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 26),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          elevation: 0,
          shadowColor: color.withOpacity(0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
    );
  }
}
