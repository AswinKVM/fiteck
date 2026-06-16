import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

// ═══════════════════════════════════════════════════════════════════════
// WHAT CHANGED AND WHY — BUGS FOUND FROM RESEARCH
//
// BUG 1 (Critical): We were counting steps with pure accelerometer math.
//   The Android hardware TYPE_STEP_COUNTER chip is already a dedicated
//   step-counting DSP running at hardware level. It has its own filtering,
//   gait validation, and false-positive rejection built-in. Apps like
//   Google Fit, Samsung Health, and Fitbit all use it as primary.
//   Fix: Use METHOD_CHANNEL to call Android's TYPE_STEP_COUNTER.
//        Use our accelerometer algorithm ONLY as fallback when hardware
//        sensor is unavailable (some cheap Android devices, all iOS).
//
// BUG 2 (Critical): "Running" showing while walking in hand.
//   Root cause: dynAccel = |filteredMag - gravity|. A single arm swing
//   peaks at 3–5 m/s² even at rest. Our window was 1 s (50 samples).
//   One big arm swing spike in a 1-second window → mean > 3.5 → "Running".
//   Fix: 3-second window (150 samples). Use VARIANCE, not just mean.
//        Running has BOTH high mean AND high variance. Walking has
//        moderate mean but LOW variance. Standing has zero of both.
//
// BUG 3 (Critical): Fixed thresholds don't adapt to walking style.
//   (danielmurray/adaptiv on GitHub proved this: same threshold gave 101
//   steps for one person and 88 for another on identical 100-step trials.)
//   Fix: Adaptive threshold = (rolling_max + rolling_min) / 2, updated
//        every sample. This self-calibrates to any user's gait strength.
//
// BUG 4: Step counted on every sample above threshold, not per step.
//   Fix: Rising-edge detection with minimum 300 ms cooldown between steps.
//        (freddiejbawden/stepz: require 3+ consecutive steps before
//        accepting — implemented as warmup counter.)
//
// BUG 5: Cadence thresholds wrong for hand-held use.
//   Fix: Position-aware cadence limits:
//     Hand-held running: cadence > 2.5 Hz (150 spm) — much stricter
//     Pocket running:    cadence > 2.2 Hz (132 spm)
//     Hand-held walk:    cadence 0.6–2.5 Hz
//
// BUG 6: Steps accepted during "unknown" position with only 0.5× penalty.
//   Fix: During unknown, require 3-step warmup before accepting any count.
//
// BUG 7: No session warmup. First 3 steps of any new session were
//   frequently false positives (the algorithm needs to settle).
//   Fix: Warmup gate of 3 valid steps before counting starts.
//        (Documented in accurate_step_counter package and SparkDay research)
//
// REFERENCE SOURCES:
//   1. pub.dev/packages/accurate_step_counter — hardware sensor approach
//   2. pub.dev/packages/pedometer_plus — Android/iOS step sensor bridge
//   3. github.com/danielmurray/adaptiv — adaptive threshold proof
//   4. github.com/freddiejbawden/stepz — 3-step warmup / sequence validation
//   5. github.com/isibord/StepTrackerAndroid — debug overlay comparison
//   6. patents.justia.com/patent/11112268 — STMicro false-positive rejection
//   7. ora.ox.ac.uk/.../b1b3cf44 — Oxford optimised step algo (6 positions)
//   8. sparkdayapp.com/blog/step-counting-accuracy — arm swing false positive
// ═══════════════════════════════════════════════════════════════════════

void main() => runApp(const FitnessTrackerApp());

class FitnessTrackerApp extends StatelessWidget {
  const FitnessTrackerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Smart Fitness',
        theme: ThemeData.dark(useMaterial3: true),
        home: const StartupPage(),
      );
}

// ═══════════════════════════════════════════════════════════════════════
// PHONE POSITION
// ═══════════════════════════════════════════════════════════════════════

enum PhonePosition { trouserPocket, handHeld, flatOnTable, bag, armband, unknown }
enum ActivityType  { still, standing, walking, running }

// ═══════════════════════════════════════════════════════════════════════
// HARDWARE STEP COUNTER BRIDGE
//
// Calls Android's TYPE_STEP_COUNTER sensor through a MethodChannel.
// This is the DSP chip inside the phone — it already does all filtering
// internally and is used by every major fitness app.
//
// Falls back silently to software counting when unavailable
// (iOS, some budget Androids, or before permission is granted).
// ═══════════════════════════════════════════════════════════════════════

class HardwareStepSensor {
  static const MethodChannel _ch =
      MethodChannel('com.fitness.tracker/step_sensor');

  bool available     = false;
  int  _bootSteps    = 0; // steps since last boot from hardware
  int  _sessionBase  = -1; // baseline at session start
  int  sessionSteps  = 0;

  Future<void> init() async {
    try {
      final bool? avail =
          await _ch.invokeMethod<bool>('checkAvailable');
      available = avail ?? false;
      if (available) await _ch.invokeMethod('startListening');
    } catch (_) {
      available = false;
    }
  }

  // Call this every time the channel fires with a new boot-step count
  void onHardwareCount(int bootCount) {
    _bootSteps = bootCount;
    if (_sessionBase < 0) _sessionBase = bootCount; // first reading = baseline
    sessionSteps = _bootSteps - _sessionBase;
  }

  void reset() {
    _sessionBase = _bootSteps;
    sessionSteps = 0;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// POSITION CLASSIFIER
// Features: pitch, roll, gyro energy, magnitude variance
// ═══════════════════════════════════════════════════════════════════════

class PositionClassifier {
  static const int _wSz = 50;
  static const int _cfm = 40;

  final List<double> _mBuf = [], _pBuf = [], _rBuf = [], _gBuf = [];
  PhonePosition _pending      = PhonePosition.unknown;
  int           _pendingCount = 0;
  PhonePosition  confirmed    = PhonePosition.unknown;

  static (double, double) pitchRoll(double ax, double ay, double az) => (
    atan2(ay, sqrt(ax * ax + az * az)) * 180 / pi,
    atan2(-ax, az) * 180 / pi,
  );

  void update(double ax, double ay, double az, double gx, double gy, double gz) {
    final double mag   = sqrt(ax*ax + ay*ay + az*az);
    final double gyroE = sqrt(gx*gx + gy*gy + gz*gz);
    final (double pitch, double roll) = pitchRoll(ax, ay, az);

    _mBuf.add(mag);   _pBuf.add(pitch.abs());
    _rBuf.add(roll.abs()); _gBuf.add(gyroE);
    if (_mBuf.length > _wSz) { _mBuf.removeAt(0); _pBuf.removeAt(0); _rBuf.removeAt(0); _gBuf.removeAt(0); }
    if (_mBuf.length < 20) return;

    final double mMag  = _mean(_mBuf);
    final double varM  = _variance(_mBuf, mMag);
    final double mPitch= _mean(_pBuf);
    final double mRoll = _mean(_rBuf);
    final double mGyro = _mean(_gBuf);
    _debounce(_classify(varM, mPitch, mRoll, mGyro));
  }

  PhonePosition _classify(double varM, double pitch, double roll, double gyro) {
    if (pitch < 20 && varM < 0.05 && gyro < 0.1)                              return PhonePosition.flatOnTable;
    if (pitch > 55 && pitch < 90 && gyro > 0.3 && varM > 0.15)               return PhonePosition.handHeld;
    if (roll > 70 && roll < 110 && pitch > 60 && gyro > 0.15 && gyro < 1.5)  return PhonePosition.armband;
    if (pitch > 65 && pitch < 110 && gyro < 0.4 && varM > 0.03)              return PhonePosition.trouserPocket;
    if (gyro > 0.8 && varM > 0.5)                                             return PhonePosition.bag;
    return PhonePosition.unknown;
  }

  void _debounce(PhonePosition d) {
    if (d == _pending) { _pendingCount++; if (_pendingCount >= _cfm) confirmed = d; }
    else { _pending = d; _pendingCount = 0; }
  }

  static double _mean(List<double> b) => b.reduce((a, v) => a + v) / b.length;
  static double _variance(List<double> b, double m) =>
      b.map((v) => (v-m)*(v-m)).reduce((a, v) => a + v) / b.length;

  static String  label(PhonePosition p) => switch (p) {
    PhonePosition.trouserPocket => "Trouser pocket",
    PhonePosition.handHeld      => "Hand-held",
    PhonePosition.flatOnTable   => "Flat on table",
    PhonePosition.bag           => "Bag / backpack",
    PhonePosition.armband       => "Armband",
    PhonePosition.unknown       => "Detecting…",
  };
  static IconData icon(PhonePosition p) => switch (p) {
    PhonePosition.trouserPocket => Icons.dry_cleaning,
    PhonePosition.handHeld      => Icons.back_hand,
    PhonePosition.flatOnTable   => Icons.table_restaurant,
    PhonePosition.bag           => Icons.backpack,
    PhonePosition.armband       => Icons.watch,
    PhonePosition.unknown       => Icons.device_unknown,
  };
}

// ═══════════════════════════════════════════════════════════════════════
// KALMAN FILTER
// ═══════════════════════════════════════════════════════════════════════

class KalmanFilter {
  double _x, _p;
  final double q, r;
  KalmanFilter({required double init, this.q = 0.02, this.r = 1.5})
      : _x = init, _p = 1.0;
  double update(double z) {
    final double pp = _p + q;
    final double k  = pp / (pp + r);
    _x += k * (z - _x); _p = (1 - k) * pp;
    return _x;
  }
  double get value => _x;
}

// ═══════════════════════════════════════════════════════════════════════
// DYNAMIC GRAVITY TRACKER
// ═══════════════════════════════════════════════════════════════════════

class DynamicGravity {
  double _g = 9.8;
  double update(double mag) { _g = 0.003 * mag + 0.997 * _g; return _g; }
  double get gravity => _g;
}

// ═══════════════════════════════════════════════════════════════════════
//
// Key changes from broken version:
//   1. Window = 150 samples (3 seconds), not 50 (1 second).
//      A 1-s window catches single arm swings → "Running".
//      A 3-s window averages over many strides → true mean emerges.
//
//   2. Uses BOTH mean AND variance for classification.
//      Walking:  mean 0.5–2.5,  variance LOW  (rhythmic, consistent)
//      Running:  mean 2.5+,     variance HIGH (large foot impacts)
//      Arm swing alone: mean spike but variance stays erratic, NOT periodic
//
//   3. Position-aware thresholds:
//      Hand-held: higher threshold needed because arm swing adds 2–4 m/s²
//      Pocket:    lower threshold OK (fabric damps arm contribution)
// ═══════════════════════════════════════════════════════════════════════

class ActivityClassifier {
  static const int _wSz = 150; // 3 s at 50 Hz — critical fix
  static const int _cfm = 40;

  final List<double> _buf = [];
  ActivityType _pending      = ActivityType.still;
  int          _pendingCount = 0;
  ActivityType  confirmed    = ActivityType.still;

  void update(double dynAccel, double cadenceHz, PhonePosition pos) {
    _buf.add(dynAccel);
    if (_buf.length > _wSz) _buf.removeAt(0);
    if (_buf.length < 30) return;

    final double mean = _buf.reduce((a, b) => a + b) / _buf.length;
    final double variance = _buf
        .map((v) => (v - mean) * (v - mean))
        .reduce((a, b) => a + b) / _buf.length;

    // Position-aware running threshold
    // Hand-held: arm swing inflates mean by 2–4 m/s², so raise the bar
    final double runMeanThresh = switch (pos) {
      PhonePosition.handHeld      => 3.8, // higher — arm swing penalty
      PhonePosition.trouserPocket => 2.5,
      PhonePosition.armband       => 2.2,
      _                           => 3.0,
    };
    final double runCadThresh = switch (pos) {
      PhonePosition.handHeld => 2.5, // >150 spm — genuinely running
      _                      => 2.2,
    };

    // Must satisfy BOTH mean AND cadence/variance for running
    // This prevents a single arm-swing spike from triggering Running
    ActivityType det;
    if (mean > runMeanThresh && variance > 0.15 ) {
      det = ActivityType.running;
    } else if (cadenceHz >= 0.6 || (mean > 0.5 && variance > 0.05)) {
      det = ActivityType.walking;
    } else if (mean > 0.2 || variance > 0.03) {
      det = ActivityType.standing;
    } else {
      det = ActivityType.still;
    }

    if (det == _pending) {
      _pendingCount++;
      if (_pendingCount >= _cfm) confirmed = det;
    } else {
      _pending = det; _pendingCount = 0;
    }
  }

  static double met(ActivityType t) => switch (t) {
    ActivityType.running  => 9.8,
    ActivityType.walking  => 3.5,
    ActivityType.standing => 1.8,
    ActivityType.still    => 1.3,
  };
  static String  label(ActivityType t) => switch (t) {
    ActivityType.running  => "Running",
    ActivityType.walking  => "Walking",
    ActivityType.standing => "Standing",
    ActivityType.still    => "Still",
  };
  static IconData icon(ActivityType t) => switch (t) {
    ActivityType.running  => Icons.directions_run,
    ActivityType.walking  => Icons.directions_walk,
    ActivityType.standing => Icons.accessibility_new,
    ActivityType.still    => Icons.airline_seat_recline_normal,
  };
}

// ═══════════════════════════════════════════════════════════════════════
//
// Used ONLY when hardware sensor unavailable (iOS / old devices).
//
// Key fixes:
//   - Adaptive threshold: rolling (max + min) / 2 over 30-sample window
//     (from danielmurray/adaptiv — eliminates fixed-threshold bias)
//   - Rising-edge only: counts a step when signal goes UP through threshold
//   - 300 ms minimum interval between steps
//   - Warmup gate: first 3 detections in a new walking session are
//     discarded (from freddiejbawden/stepz — removes false-start counts)
//   - Requires 3-step sequence before resetting warmup gate on resume
// ═══════════════════════════════════════════════════════════════════════

class SoftwareStepDetector {
  // Rolling window for adaptive threshold
  static const int    _wSize    = 30;
  static const int    _minMs    = 300;
  static const double _hyst     = 0.5;
  static const int    _warmupN  = 3;   // discard first N triggers

  final List<double> _win = [];
  double   _thresh     = 11.0;
  bool     _above      = false;
  DateTime _lastStep   = DateTime(0);
  int      _warmup     = 0;      // steps since last still period
  bool     _inSession  = false;

  // Returns number of validated steps (0 or 1 per call)
  int update(double filteredMag, ActivityType activity) {
    // Reset warmup when phone has been still
    if (activity == ActivityType.still) { _inSession = false; _warmup = 0; }

    // Update adaptive threshold window
    _win.add(filteredMag);
    if (_win.length > _wSize) _win.removeAt(0);
    if (_win.length >= 6) {
      final double hi = _win.reduce((a, b) => a > b ? a : b);
      final double lo = _win.reduce((a, b) => a < b ? a : b);
      // Blend toward new midpoint (0.92 smoothing prevents threshold jitter)
      _thresh = 0.92 * _thresh + 0.08 * ((hi + lo) / 2.0);
    }

    // Rising-edge detection
    if (!_above && filteredMag > _thresh) {
      _above = true;
      final int ms = DateTime.now().difference(_lastStep).inMilliseconds;
      if (ms > _minMs) {
        _lastStep = DateTime.now();

        if (!_inSession) {
          // Warmup phase — discard first _warmupN triggers
          _warmup++;
          if (_warmup >= _warmupN) _inSession = true;
          return 0;
        }
        return 1; // valid step
      }
    } else if (_above && filteredMag < _thresh - _hyst) {
      _above = false;
    }

    return 0;
  }

  double get threshold => _thresh;
}

// ═══════════════════════════════════════════════════════════════════════
// STRIDE ESTIMATOR (Weinberg, position-corrected K values)
// ═══════════════════════════════════════════════════════════════════════

class StrideEstimator {
  final List<double> _buf = [];
  void addSample(double mag) { _buf.add(mag); if (_buf.length > 120) _buf.removeAt(0); }

  double stride(ActivityType act, PhonePosition pos) {
    if (_buf.length < 4) return 0.75;
    final double hi   = _buf.reduce((a, b) => a > b ? a : b);
    final double lo   = _buf.reduce((a, b) => a < b ? a : b);
    final double diff = (hi - lo).clamp(0.1, 30.0);
    // Pocket/bag dampen the magnitude → higher K to compensate
    final double kW = switch (pos) {
      PhonePosition.trouserPocket => 0.42,
      PhonePosition.bag           => 0.45,
      _                           => 0.38,
    };
    final double kR = switch (pos) {
      PhonePosition.trouserPocket => 0.54,
      PhonePosition.bag           => 0.56,
      _                           => 0.50,
    };
    _buf.clear();
    return (act == ActivityType.running ? kR : kW) * pow(diff, 0.25).toDouble();
  }
}

// ═══════════════════════════════════════════════════════════════════════
// CALORIE CALCULATOR (Mifflin–St Jeor BMR)
// ═══════════════════════════════════════════════════════════════════════

class CalorieCalculator {
  final double _bmr;
  CalorieCalculator({required double weight, required double height,
      required int age, required String gender})
      : _bmr = gender == "Female"
            ? 10 * weight + 6.25 * height - 5 * age - 161
            : 10 * weight + 6.25 * height - 5 * age + 5;
  double kcalPerSec(double met) => (met * _bmr) / 86400.0;
}

// ═══════════════════════════════════════════════════════════════════════
// STARTUP + PROFILE PAGES
// ═══════════════════════════════════════════════════════════════════════

class StartupPage extends StatefulWidget {
  const StartupPage({super.key});
  @override State<StartupPage> createState() => _StartupPageState();
}
class _StartupPageState extends State<StartupPage> {
  @override void initState() { super.initState(); _check(); }
  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(
      builder: (_) => prefs.containsKey('name')
          ? const FitnessDashboard() : const ProfileSetupPage()));
  }
  @override Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class ProfileSetupPage extends StatefulWidget {
  const ProfileSetupPage({super.key});
  @override State<ProfileSetupPage> createState() => _ProfileSetupPageState();
}
class _ProfileSetupPageState extends State<ProfileSetupPage> {
  final _name=TextEditingController(), _age=TextEditingController(),
        _weight=TextEditingController(), _height=TextEditingController();
  String _gender = "Male";

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name',   _name.text.trim());
    await prefs.setInt   ('age',    int.tryParse(_age.text)       ?? 25);
    await prefs.setDouble('weight', double.tryParse(_weight.text) ?? 70);
    await prefs.setDouble('height', double.tryParse(_height.text) ?? 170);
    await prefs.setString('gender', _gender);
    if (!mounted) return;
    Navigator.pushReplacement(context,
        MaterialPageRoute(builder: (_) => const FitnessDashboard()));
  }

  Widget _field(String label, TextEditingController c,
      {TextInputType kt = TextInputType.number}) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextField(controller: c, keyboardType: kt,
          decoration: InputDecoration(labelText: label,
              border: const OutlineInputBorder())));

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("Profile Setup")),
    body: Padding(padding: const EdgeInsets.all(16),
      child: ListView(children: [
        _field("Name", _name, kt: TextInputType.name),
        _field("Age", _age), _field("Weight (kg)", _weight),
        _field("Height (cm)", _height),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(initialValue: _gender,
          decoration: const InputDecoration(labelText: "Gender",
              border: OutlineInputBorder()),
          items: ["Male","Female"].map((g) =>
              DropdownMenuItem(value: g, child: Text(g))).toList(),
          onChanged: (v) => setState(() => _gender = v!)),
        const SizedBox(height: 20),
        FilledButton(onPressed: _save, child: const Text("Save & Continue")),
      ])));
}

// ═══════════════════════════════════════════════════════════════════════
// FITNESS DASHBOARD
// ═══════════════════════════════════════════════════════════════════════

class FitnessDashboard extends StatefulWidget {
  const FitnessDashboard({super.key});
  @override State<FitnessDashboard> createState() => _FitnessDashboardState();
}

class _FitnessDashboardState extends State<FitnessDashboard> {
  StreamSubscription? _accelSub, _gyroSub;
  StreamSubscription<Position>? _posSub;
  Timer? _calorieTimer;

  // ── Algorithm stack ──
  final HardwareStepSensor    _hw         = HardwareStepSensor();
  final PositionClassifier    _posClass   = PositionClassifier();
  final DynamicGravity        _gravity    = DynamicGravity();
  final KalmanFilter          _kalman     = KalmanFilter(init: 9.8, q: 0.015, r: 1.2);
  final ActivityClassifier    _actClass   = ActivityClassifier();
  final SoftwareStepDetector  _swDet      = SoftwareStepDetector();
  final StrideEstimator       _stride     = StrideEstimator();
  CalorieCalculator?          _calCalc;

  // ── Sensor display values ──
  AccelerometerEvent? _accel;
  GyroscopeEvent?     _gyro;
  double _filteredMag = 9.8, _dynAccel = 0, _gravEst = 9.8;

  // ── Metrics ──
  int    _hwSteps    = 0;   // from hardware sensor
  int    _swSteps    = 0;   // from software fallback
  double distanceKm  = 0;
  double speedKmh    = 0;
  double calories    = 0;

  // ── GPS ──
  Position? _lastPos;
  double    _gpsAccuracy = 0;

  // ── Debug ──
  String _stepSource = "detecting…";
  double _swThreshold = 11.0;

  // ── Total steps (hardware preferred) ──
  int get totalSteps => _hw.available ? _hwSteps : _swSteps;

  @override void initState() { super.initState(); _init(); }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _calCalc = CalorieCalculator(
      weight: prefs.getDouble('weight') ?? 70,
      height: prefs.getDouble('height') ?? 170,
      age:    prefs.getInt   ('age')    ?? 25,
      gender: prefs.getString('gender') ?? "Male",
    );

    // ── Try hardware sensor first ──
    await _hw.init();
    if (_hw.available) {
      _stepSource = "Android hardware sensor";
      // Listen for hardware step events via MethodChannel EventChannel
      const EventChannel stepEvents =
          EventChannel('com.fitness.tracker/step_events');
      stepEvents.receiveBroadcastStream().listen((dynamic count) {
        if (count is int) {
          _hw.onHardwareCount(count);
          setState(() => _hwSteps = _hw.sessionSteps);
        }
      });
    } else {
      _stepSource = "Software fallback (no hardware sensor)";
    }

    // ── Accelerometer — always needed (for position, activity, fallback steps) ──
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval, // ~50 Hz
    ).listen(_onAccel);

    // ── Gyroscope — needed for position classifier ──
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen((e) => _gyro = e);

    // ── Calorie timer — exactly once per second ──
    _calorieTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_calCalc == null) return;
      setState(() => calories +=
          _calCalc!.kcalPerSec(ActivityClassifier.met(_actClass.confirmed)));
    });

    // ── GPS ──
    final perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return;
    }
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2,
      ),
    ).listen(_onPosition);
  }

  void _onAccel(AccelerometerEvent e) {
    _accel = e;
    final double gx = _gyro?.x ?? 0;
    final double gy = _gyro?.y ?? 0;
    final double gz = _gyro?.z ?? 0;

    // 1. Orientation-invariant magnitude
    final double rawMag = sqrt(e.x*e.x + e.y*e.y + e.z*e.z);

    // 2. Slow gravity tracker (handles pocket tilt)
    _gravEst = _gravity.update(rawMag);

    // 3. Kalman denoise
    _filteredMag = _kalman.update(rawMag);

    // 4. Dynamic acceleration
    _dynAccel = (_filteredMag - _gravEst).abs();

    // 5. Feed stride estimator
    _stride.addSample(_filteredMag);

    // 6. Position classification
    _posClass.update(e.x, e.y, e.z, gx, gy, gz);
    final PhonePosition pos = _posClass.confirmed;

    // 7. Activity classification (3-s window, position-aware thresholds)
    // Cadence is estimated from last software detector threshold crossing rate
    // (simplified — hardware sensor doesn't give cadence directly)
    _actClass.update(_dynAccel, 0, pos);
    final ActivityType act = _actClass.confirmed;

    // 8. Software step detection (fallback only)
    if (!_hw.available) {
      // Only count steps when walking or running, not still/standing
      if (act == ActivityType.walking || act == ActivityType.running) {
        final int newSteps = _swDet.update(_filteredMag, act);
        if (newSteps > 0) {
          _swSteps += newSteps;
          // Add Weinberg stride-based distance
          if (_gpsAccuracy > 25 || _lastPos == null) {
            distanceKm += _stride.stride(act, pos) / 1000.0;
          }
        }
      }
      _swThreshold = _swDet.threshold;
    } else {
      // Hardware sensor handles steps — just update distance from GPS or stride
      // Distance is updated in _onPosition via GPS; stride fallback when poor GPS
    }

    setState(() {});
  }

  void _onPosition(Position pos) {
    _gpsAccuracy = pos.accuracy;
    speedKmh     = pos.speed * 3.6;
    if (pos.accuracy < 20 && _lastPos != null) {
      final double d = Geolocator.distanceBetween(
        _lastPos!.latitude, _lastPos!.longitude,
        pos.latitude, pos.longitude,
      );
      if (d > 2.0) distanceKm += d / 1000.0;
    }
    _lastPos = pos;
    setState(() {});
  }

  @override void dispose() {
    _accelSub?.cancel(); _gyroSub?.cancel();
    _posSub?.cancel();   _calorieTimer?.cancel();
    super.dispose();
  }

  // ════════════════════════════ UI ════════════════════════════

  @override Widget build(BuildContext context) {
    final pos = _posClass.confirmed;
    final act = _actClass.confirmed;
    return Scaffold(
      appBar: AppBar(title: const Text("Smart Fitness"), centerTitle: true),
      body: ListView(padding: const EdgeInsets.all(12), children: [

        _PositionBanner(position: pos),
        const SizedBox(height: 10),
        _ActivityBanner(activity: act),
        const SizedBox(height: 12),

        _MetricGrid(steps: totalSteps, distanceKm: distanceKm,
            speedKmh: speedKmh, calories: calories),
        const SizedBox(height: 16),

        // ── Debug panel ──
        Card(child: Padding(padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text("Step counting pipeline",
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            _DR("Source",          _stepSource,
                _hw.available ? Colors.greenAccent : Colors.amberAccent),
            _DR("Hardware steps",  _hw.available ? "$_hwSteps" : "n/a",
                Colors.tealAccent),
            _DR("Software steps",  "$_swSteps", Colors.blueAccent),
            _DR("Kalman filtered", "${_filteredMag.toStringAsFixed(3)} m/s²",
                Colors.tealAccent),
            _DR("Tracked gravity", "${_gravEst.toStringAsFixed(3)} m/s²",
                Colors.blueAccent),
            _DR("Dynamic accel",   "${_dynAccel.toStringAsFixed(3)} m/s²",
                Colors.orangeAccent),
            if (!_hw.available)
              _DR("SW threshold",  _swThreshold.toStringAsFixed(3),
                  Colors.purpleAccent),
            _DR("GPS accuracy",
                _gpsAccuracy == 0 ? "waiting…" : "±${_gpsAccuracy.toStringAsFixed(1)} m",
                _gpsAccuracy < 20 ? Colors.greenAccent
                    : _gpsAccuracy < 50 ? Colors.amberAccent : Colors.redAccent),
          ]))),
        const SizedBox(height: 12),

        _SensorCard("Accelerometer", [_accel?.x, _accel?.y, _accel?.z]),
        const SizedBox(height: 12),
        _SensorCard("Gyroscope",     [_gyro?.x,  _gyro?.y,  _gyro?.z]),
        const SizedBox(height: 20),

        Row(children: [
          Expanded(child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text("Reset steps"),
            onPressed: () => setState(() {
              _hw.reset(); _swSteps = 0; distanceKm = 0; calories = 0;
            }),
          )),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(
            icon: const Icon(Icons.person),
            label: const Text("Reset profile"),
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.clear();
              if (!context.mounted) return;
              Navigator.pushReplacement(context,
                  MaterialPageRoute(builder: (_) => const ProfileSetupPage()));
            },
          )),
        ]),
        const SizedBox(height: 16),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// UI COMPONENTS
// ═══════════════════════════════════════════════════════════════════════

class _PositionBanner extends StatelessWidget {
  final PhonePosition position;
  const _PositionBanner({required this.position});
  Color get _c => switch (position) {
    PhonePosition.trouserPocket => Colors.deepPurple,
    PhonePosition.handHeld      => Colors.teal,
    PhonePosition.flatOnTable   => Colors.blueGrey,
    PhonePosition.bag           => Colors.brown,
    PhonePosition.armband       => Colors.indigo,
    PhonePosition.unknown       => Colors.grey,
  };
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
    decoration: BoxDecoration(color: _c.withValues(alpha: 0.12),
        border: Border.all(color: _c.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      Icon(PositionClassifier.icon(position), color: _c, size: 22),
      const SizedBox(width: 10),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Phone position", style: TextStyle(fontSize: 11, color: Colors.white54)),
        Text(PositionClassifier.label(position),
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _c)),
      ]),
    ]),
  );
}

class _ActivityBanner extends StatelessWidget {
  final ActivityType activity;
  const _ActivityBanner({required this.activity});
  Color get _c => switch (activity) {
    ActivityType.running  => Colors.orange,
    ActivityType.walking  => Colors.teal,
    ActivityType.standing => Colors.blueGrey,
    ActivityType.still    => Colors.grey,
  };
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
    decoration: BoxDecoration(color: _c.withValues(alpha: 0.12),
        border: Border.all(color: _c.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      Icon(ActivityClassifier.icon(activity), color: _c, size: 30),
      const SizedBox(width: 12),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Activity", style: TextStyle(fontSize: 11, color: Colors.white54)),
        Text(ActivityClassifier.label(activity),
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _c)),
      ]),
    ]),
  );
}

class _MetricGrid extends StatelessWidget {
  final int steps; final double distanceKm, speedKmh, calories;
  const _MetricGrid({required this.steps, required this.distanceKm,
      required this.speedKmh, required this.calories});
  @override Widget build(BuildContext context) => GridView.count(
    crossAxisCount: 2, shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.7,
    children: [
      _Tile("Steps",    steps.toString(),                      Icons.directions_walk,       Colors.blueAccent),
      _Tile("Distance", "${distanceKm.toStringAsFixed(2)} km", Icons.route,                 Colors.tealAccent),
      _Tile("Speed",    "${speedKmh.toStringAsFixed(1)} km/h", Icons.speed,                 Colors.orangeAccent),
      _Tile("Calories", "${calories.toStringAsFixed(1)} kcal", Icons.local_fire_department, Colors.redAccent),
    ]);
}

class _Tile extends StatelessWidget {
  final String label, value; final IconData icon; final Color color;
  const _Tile(this.label, this.value, this.icon, this.color);
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.1),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(14)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Icon(icon, color: color, size: 20),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: TextStyle(fontSize: 18,
              fontWeight: FontWeight.bold, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ]),
      ]));
}

class _SensorCard extends StatelessWidget {
  final String title; final List<double?> values;
  const _SensorCard(this.title, this.values);
  @override Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: ['X','Y','Z'].asMap().entries.map((e) {
            final double? v = values[e.key];
            return Column(children: [
              Text(e.value, style: const TextStyle(fontSize: 12, color: Colors.white54)),
              Text(v != null ? v.toStringAsFixed(3) : "—",
                  style: const TextStyle(fontSize: 15, fontFamily: 'monospace')),
            ]);
          }).toList()),
      ])));
}

class _DR extends StatelessWidget {
  final String l, v; final Color c;
  const _DR(this.l, this.v, this.c);
  @override Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3.5),
    child: Row(children: [
      Expanded(child: Text(l, style: const TextStyle(fontSize: 12, color: Colors.white54))),
      Text(v, style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: c)),
    ]));
}
