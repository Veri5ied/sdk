part of dart.math;

abstract class Random {
  factory Random([int seed]) =>
      (seed == null) ? const _JSRandom() : new _Random(seed);
  int nextInt(int max);
  double nextDouble();
  bool nextBool();
}
