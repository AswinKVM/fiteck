import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

// ═══════════════════════════════════════════════════════════════
// ENTRY POINT
// ═══════════════════════════════════════════════════════════════

void main() {
  runApp(const FitnessTrackerApp());
}

class FitnessTrackerApp extends StatelessWidget {
  const FitnessTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Fitness Tracker',
      theme: ThemeData.dark(useMaterial3: true),
      home: const StartupPage(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// ALGORITHM 1: 1D KALMAN FILTER
//
// Removes accelerometer noise by tracking the hidden "true" signal.
//
// State:       x_k  = x_{k-1}        (signal assumed slow-changing)
// Measurement: z_k  = x_k + noise
//
// q = process noise covariance  (how fast can the true signal change?)
// r = measurement noise covariance (how noisy is the sensor?)
//
// Low q → trust the model, slow to react
// Low r → trust sensor, fast to react
// ═══════════════════════════════════════════════════════════════

class KalmanFilter1D {
  double _x;   // current state estimate
  double _p;   // error covariance
  final double q;
  final double r;

  KalmanFilter1D({
    required double initialValue,
    this.q = 0.008,
    this.r = 0.8,
  })  : _x = initialValue,
        _p = 1.0;

  double update(double measurement) {
    final double pPred = _p + q;
    final double k     = pPred / (pPred + r);   // Kalman gain
    _x = _x + k * (measurement - _x);           // update estimate
    _p = (1 - k) * pPred;                        // update covariance
    return _x;
  }

  double get value => _x;
}

// ═══════════════════════════════════════════════════════════════
// ALGORITHM 2: ADAPTIVE STEP DETECTOR
//
// Problems with a fixed threshold:
//   - Walking vs running have very different magnitudes
//   - Phone orientation changes the entire signal level
//   - A fixed threshold misses steps or double-counts them
//
// Solution:
//   1. Sliding window tracks recent signal to estimate peak & valley
//   2. Threshold = midpoint of (peak, valley), updated every sample
//   3. Hysteresis prevents rapid re-triggering after a step
//   4. Minimum step interval (250 ms) blocks impossibly fast steps
// ═══════════════════════════════════════════════════════════════

class AdaptiveStepDetector {
  static const int    _windowSize       = 20;
  static const int    _minIntervalMs    = 250;
  static const double _hysteresis       = 0.8;

  final List<double> _window = [];
  double   _threshold    = 11.0;
  bool     _aboveThresh  = false;
  DateTime _lastStep     = DateTime(0);

  bool update(double filteredMag) {
    _window.add(filteredMag);
    if (_window.length > _windowSize) _window.removeAt(0);

    if (_window.length >= 4) {
      final double hi  = _window.reduce((a, b) => a > b ? a : b);
      final double lo  = _window.reduce((a, b) => a < b ? a : b);
      final double mid = (hi + lo) / 2.0;
      _threshold = 0.95 * _threshold + 0.05 * mid; // smooth threshold drift
    }

    bool detected = false;

    if (!_aboveThresh && filteredMag > _threshold) {
      _aboveThresh = true;
      final int ms = DateTime.now().difference(_lastStep).inMilliseconds;
      if (ms > _minIntervalMs) {
        detected   = true;
        _lastStep  = DateTime.now();
      }
    } else if (_aboveThresh && filteredMag < _threshold - _hysteresis) {
      _aboveThresh = false; // reset — ready for next step
    }

    return detected;
  }

  double get currentThreshold => _threshold;
}

// ═══════════════════════════════════════════════════════════════
// ALGORITHM 3: ACTIVITY CLASSIFIER
//
// A fixed-threshold classifier is fragile. Instead, this computes
// both the MEAN and VARIANCE of dynamic acceleration over a 1-second
// sliding window, then classifies based on both.
//
//   Still:    mean ≈ 0,   variance ≈ 0
//   Standing: mean small, variance small  (breathing, micro-sways)
//   Walking:  mean moderate, variance moderate (rhythmic impact)
//   Running:  mean high,     variance high  (large foot-strike)
//
// A debounce confirms the class for 0.5s before switching.
// ═══════════════════════════════════════════════════════════════

enum ActivityType { still, standing, walking, running }

class ActivityClassifier {
  static const int _windowSz      = 50;  // ~1 s at 50 Hz
  static const int _confirmFrames = 25;  // 0.5 s before confirming switch

  final List<double> _buf = [];
  ActivityType _pending       = ActivityType.still;
  int          _pendingCount  = 0;
  ActivityType confirmed      = ActivityType.still;

  void update(double dynAccel) {
    _buf.add(dynAccel);
    if (_buf.length > _windowSz) _buf.removeAt(0);
    _debounce(_classify());
  }

  ActivityType _classify() {
    if (_buf.length < 10) return ActivityType.still;

    final double mean = _buf.reduce((a, b) => a + b) / _buf.length;
    final double variance = _buf
        .map((v) => (v - mean) * (v - mean))
        .reduce((a, b) => a + b) / _buf.length;

    if (mean < 0.3 && variance < 0.05) return ActivityType.still;
    if (mean < 0.8 && variance < 0.3)  return ActivityType.standing;
    if (mean < 3.5 || variance < 2.0)  return ActivityType.walking;
    return ActivityType.running;
  }

  void _debounce(ActivityType detected) {
    if (detected == _pending) {
      _pendingCount++;
      if (_pendingCount >= _confirmFrames) confirmed = detected;
    } else {
      _pending      = detected;
      _pendingCount = 0;
    }
  }

  static double metValue(ActivityType t) {
    switch (t) {
      case ActivityType.running:  return 9.8;
      case ActivityType.walking:  return 3.5;
      case ActivityType.standing: return 1.8;
      case ActivityType.still:    return 1.3;
    }
  }

  static String label(ActivityType t) {
    switch (t) {
      case ActivityType.running:  return "Running";
      case ActivityType.walking:  return "Walking";
      case ActivityType.standing: return "Standing";
      case ActivityType.still:    return "Still";
    }
  }

  static IconData icon(ActivityType t) {
    switch (t) {
      case ActivityType.running:  return Icons.directions_run;
      case ActivityType.walking:  return Icons.directions_walk;
      case ActivityType.standing: return Icons.accessibility_new;
      case ActivityType.still:    return Icons.airline_seat_recline_normal;
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// ALGORITHM 4: WEINBERG STRIDE LENGTH ESTIMATOR
//
// A fixed stride length (e.g. 0.75 m) is wrong for everyone.
// This uses the Weinberg (2002) formula:
//
//   L = K × (a_max - a_min) ^ (1/4)
//
// Where:
//   a_max  = peak magnitude in the inter-step buffer
//   a_min  = valley magnitude in the inter-step buffer
//   K      = empirical constant (0.38 walking, 0.50 running)
//
// Distance from steps = Σ L_i
// Used as fallback when GPS accuracy is poor (>25 m).
// ═══════════════════════════════════════════════════════════════

class StrideEstimator {
  static const double _kWalk = 0.38;
  static const double _kRun  = 0.50;

  final List<double> _buf = [];

  void addSample(double mag) {
    _buf.add(mag);
    if (_buf.length > 100) _buf.removeAt(0);
  }

  double strideLength(ActivityType act) {
    if (_buf.length < 4) return 0.75;

    final double hi   = _buf.reduce((a, b) => a > b ? a : b);
    final double lo   = _buf.reduce((a, b) => a < b ? a : b);
    final double diff = (hi - lo).clamp(0.1, 30.0);
    final double k    = act == ActivityType.running ? _kRun : _kWalk;

    _buf.clear();
    return k * pow(diff, 0.25).toDouble();
  }
}

// ═══════════════════════════════════════════════════════════════
// ALGORITHM 5: PERSONALISED CALORIE CALCULATOR
//
// Uses the Mifflin–St Jeor BMR equation (the most validated formula):
//
//   Male:   BMR = 10W + 6.25H - 5A + 5
//   Female: BMR = 10W + 6.25H - 5A - 161
//
// Calories/second = MET × BMR / (24 × 3600)
//
// This accounts for age, height, weight, gender — far more accurate
// than the generic MET × 3.5 × weight / 200 formula.
// ═══════════════════════════════════════════════════════════════

class CalorieCalculator {
  final double _bmr;

  CalorieCalculator({
    required double weight,
    required double height,
    required int    age,
    required String gender,
  }) : _bmr = gender == "Female"
           ? 10 * weight + 6.25 * height - 5 * age - 161
           : 10 * weight + 6.25 * height - 5 * age + 5;

  double kcalPerSecond(double met) => (met * _bmr) / (24 * 3600);
}

// ═══════════════════════════════════════════════════════════════
// STARTUP PAGE
// ═══════════════════════════════════════════════════════════════

class StartupPage extends StatefulWidget {
  const StartupPage({super.key});

  @override
  State<StartupPage> createState() => _StartupPageState();
}

class _StartupPageState extends State<StartupPage> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => prefs.containsKey('name')
            ? const FitnessDashboard()
            : const ProfileSetupPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

// ═══════════════════════════════════════════════════════════════
// PROFILE SETUP PAGE
// ═══════════════════════════════════════════════════════════════

class ProfileSetupPage extends StatefulWidget {
  const ProfileSetupPage({super.key});

  @override
  State<ProfileSetupPage> createState() => _ProfileSetupPageState();
}

class _ProfileSetupPageState extends State<ProfileSetupPage> {
  final _name   = TextEditingController();
  final _age    = TextEditingController();
  final _weight = TextEditingController();
  final _height = TextEditingController();
  String _gender = "Male";

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name',   _name.text.trim());
    await prefs.setInt   ('age',    int.tryParse(_age.text)       ?? 25);
    await prefs.setDouble('weight', double.tryParse(_weight.text) ?? 70);
    await prefs.setDouble('height', double.tryParse(_height.text) ?? 170);
    await prefs.setString('gender', _gender);
    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const FitnessDashboard()));
  }

  Widget _field(String label, TextEditingController c,
      {TextInputType keyboardType = TextInputType.number}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextField(
          controller: c,
          keyboardType: keyboardType,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text("Profile Setup")),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(children: [
            _field("Name", _name, keyboardType: TextInputType.name),
            _field("Age", _age),
            _field("Weight (kg)", _weight),
            _field("Height (cm)", _height),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _gender,
              decoration: const InputDecoration(
                  labelText: "Gender", border: OutlineInputBorder()),
              items: ["Male", "Female"]
                  .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                  .toList(),
              onChanged: (v) => setState(() => _gender = v!),
            ),
            const SizedBox(height: 20),
            FilledButton(
                onPressed: _save, child: const Text("Save & Continue")),
          ]),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════
// FITNESS DASHBOARD
// ═══════════════════════════════════════════════════════════════

class FitnessDashboard extends StatefulWidget {
  const FitnessDashboard({super.key});

  @override
  State<FitnessDashboard> createState() => _FitnessDashboardState();
}

class _FitnessDashboardState extends State<FitnessDashboard> {
  // ── Subscriptions ──
  StreamSubscription? _accelSub;
  StreamSubscription? _gyroSub;
  StreamSubscription<Position>? _posSub;
  Timer? _calorieTimer;

  // ── Algorithm instances ──
  final KalmanFilter1D      _kalman    = KalmanFilter1D(initialValue: 9.8, q: 0.008, r: 0.8);
  final AdaptiveStepDetector _stepDet  = AdaptiveStepDetector();
  final ActivityClassifier   _classify = ActivityClassifier();
  final StrideEstimator      _stride   = StrideEstimator();
  CalorieCalculator?         _calCalc;

  // ── Display values ──
  AccelerometerEvent? _accel;
  GyroscopeEvent?     _gyro;
  double _filteredMag   = 9.8;
  double _dynThreshold  = 11.0;

  // ── Metrics ──
  int    steps      = 0;
  double distanceKm = 0;
  double speedKmh   = 0;
  double calories   = 0;

  // ── GPS ──
  Position? _lastPos;
  double    _gpsAccuracy = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs  = await SharedPreferences.getInstance();
    final double w = prefs.getDouble('weight') ?? 70;
    final double h = prefs.getDouble('height') ?? 170;
    final int    a = prefs.getInt   ('age')    ?? 25;
    final String g = prefs.getString('gender') ?? "Male";

    _calCalc = CalorieCalculator(weight: w, height: h, age: a, gender: g);

    // Accelerometer at ~50 Hz
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen(_onAccel);

    // Gyroscope
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen((e) => setState(() => _gyro = e));

    // Calorie timer: exactly once per second
    _calorieTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_calCalc == null) return;
      final double met = ActivityClassifier.metValue(_classify.confirmed);
      setState(() => calories += _calCalc!.kcalPerSecond(met));
    });

    // GPS
    final perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) return;

    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2,
      ),
    ).listen(_onPosition);
  }

  void _onAccel(AccelerometerEvent e) {
    _accel = e;

    // 1. Raw magnitude
    final double raw = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);

    // 2. Kalman filter
    final double filtered = _kalman.update(raw);
    _filteredMag = filtered;

    // 3. Dynamic acceleration (remove gravity)
    final double dynAccel = (filtered - 9.8).abs();

    // 4. Feed stride estimator
    _stride.addSample(filtered);

    // 5. Activity classification
    _classify.update(dynAccel);

    // 6. Step detection
    final bool step = _stepDet.update(filtered);
    _dynThreshold = _stepDet.currentThreshold;

    if (step &&
        (_classify.confirmed == ActivityType.walking ||
         _classify.confirmed == ActivityType.running)) {
      steps++;
      // Use Weinberg stride distance when GPS is unavailable/inaccurate
      if (_gpsAccuracy > 25 || _lastPos == null) {
        distanceKm += _stride.strideLength(_classify.confirmed) / 1000.0;
      }
    }

    setState(() {});
  }

  void _onPosition(Position pos) {
    _gpsAccuracy = pos.accuracy;
    speedKmh     = pos.speed * 3.6;

    if (pos.accuracy < 20 && _lastPos != null) {
      final double d = Geolocator.distanceBetween(
        _lastPos!.latitude, _lastPos!.longitude,
        pos.latitude,       pos.longitude,
      );
      if (d > 2.0) distanceKm += d / 1000.0;
    }
    _lastPos = pos;
    setState(() {});
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _posSub?.cancel();
    _calorieTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ActivityType act = _classify.confirmed;
    return Scaffold(
      appBar: AppBar(title: const Text("Fitness Tracker"), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _ActivityBanner(activity: act),
          const SizedBox(height: 12),
          _MetricGrid(
              steps: steps, distanceKm: distanceKm,
              speedKmh: speedKmh, calories: calories),
          const SizedBox(height: 16),
          _SensorCard(
            title: "Accelerometer",
            values: [_accel?.x, _accel?.y, _accel?.z],
            extra: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                Text(
                  "Kalman filtered:    ${_filteredMag.toStringAsFixed(3)} m/s²",
                  style: const TextStyle(color: Colors.tealAccent, fontSize: 13,
                      fontFamily: 'monospace'),
                ),
                Text(
                  "Adaptive threshold: ${_dynThreshold.toStringAsFixed(3)}",
                  style: const TextStyle(color: Colors.amberAccent, fontSize: 13,
                      fontFamily: 'monospace'),
                ),
                Text(
                  "Activity:           ${ActivityClassifier.label(act)}",
                  style: const TextStyle(color: Colors.white70, fontSize: 13,
                      fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SensorCard(title: "Gyroscope", values: [_gyro?.x, _gyro?.y, _gyro?.z]),
          const SizedBox(height: 12),
          // GPS accuracy indicator
          Card(
            child: ListTile(
              leading: Icon(
                Icons.gps_fixed,
                color: _gpsAccuracy == 0
                    ? Colors.grey
                    : _gpsAccuracy < 20
                        ? Colors.greenAccent
                        : _gpsAccuracy < 50
                            ? Colors.amberAccent
                            : Colors.redAccent,
              ),
              title: const Text("GPS Accuracy"),
              subtitle: Text(
                _gpsAccuracy == 0
                    ? "Waiting for lock..."
                    : "±${_gpsAccuracy.toStringAsFixed(1)} m  "
                      "(${_gpsAccuracy < 20 ? 'Good — using GPS distance' : _gpsAccuracy < 50 ? 'Fair' : 'Poor — using stride estimation'})",
              ),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text("Reset Profile"),
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.clear();
              if (!context.mounted) return;
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const ProfileSetupPage()),
              );
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// UI COMPONENTS
// ═══════════════════════════════════════════════════════════════

class _ActivityBanner extends StatelessWidget {
  final ActivityType activity;
  const _ActivityBanner({required this.activity});

  Color get _color {
    switch (activity) {
      case ActivityType.running:  return Colors.orange;
      case ActivityType.walking:  return Colors.teal;
      case ActivityType.standing: return Colors.blueGrey;
      case ActivityType.still:    return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        color:        _color.withOpacity(0.15),
        border:       Border.all(color: _color.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        Icon(ActivityClassifier.icon(activity), color: _color, size: 36),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text("Current activity",
              style: TextStyle(fontSize: 12, color: Colors.white54)),
          Text(ActivityClassifier.label(activity),
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: _color)),
        ]),
      ]),
    );
  }
}

class _MetricGrid extends StatelessWidget {
  final int    steps;
  final double distanceKm;
  final double speedKmh;
  final double calories;
  const _MetricGrid({
    required this.steps, required this.distanceKm,
    required this.speedKmh, required this.calories,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 1.7,
      children: [
        _MetricTile("Steps",    steps.toString(),                      Icons.directions_walk,       Colors.blueAccent),
        _MetricTile("Distance", "${distanceKm.toStringAsFixed(2)} km", Icons.route,                 Colors.tealAccent),
        _MetricTile("Speed",    "${speedKmh.toStringAsFixed(1)} km/h", Icons.speed,                 Colors.orangeAccent),
        _MetricTile("Calories", "${calories.toStringAsFixed(1)} kcal", Icons.local_fire_department, Colors.redAccent),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String   label;
  final String   value;
  final IconData icon;
  final Color    color;
  const _MetricTile(this.label, this.value, this.icon, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.1),
        border:       Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:  MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: color, size: 20),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ]),
        ],
      ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  final String        title;
  final List<double?> values;
  final Widget?       extra;
  const _SensorCard({required this.title, required this.values, this.extra});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: ['X', 'Y', 'Z'].asMap().entries.map((e) {
                final double? v = values[e.key];
                return Column(children: [
                  Text(e.value,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white54)),
                  Text(
                    v != null ? v.toStringAsFixed(3) : "—",
                    style: const TextStyle(
                        fontSize: 16, fontFamily: 'monospace'),
                  ),
                ]);
              }).toList(),
            ),
            if (extra != null) extra!,
          ],
        ),
      ),
    );
  }
}
