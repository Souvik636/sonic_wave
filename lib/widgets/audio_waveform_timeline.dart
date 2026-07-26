import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'package:google_fonts/google_fonts.dart';

class AudioWaveformTimeline extends StatefulWidget {
  final double startVal;
  final double endVal;
  final double maxVal;
  final double currentPosition;
  final double fadeInVal;
  final double fadeOutVal;
  final ValueChanged<RangeValues> onChanged;

  const AudioWaveformTimeline({
    super.key,
    required this.startVal,
    required this.endVal,
    required this.maxVal,
    required this.currentPosition,
    required this.fadeInVal,
    required this.fadeOutVal,
    required this.onChanged,
  });

  @override
  State<AudioWaveformTimeline> createState() => _AudioWaveformTimelineState();
}

class _AudioWaveformTimelineState extends State<AudioWaveformTimeline> {
  double _zoomFactor = 1.0; // 1.0x to 4.0x zoom
  double _baseZoomFactor = 1.0;
  final ScrollController _scrollController = ScrollController();

  // Stable pseudo-random waveform height generator
  late List<double> _baseHeights;

  @override
  void initState() {
    super.initState();
    final random = math.Random(42);
    _baseHeights = List.generate(300, (index) {
      final double sinVal = math.sin((index / 50.0) * math.pi).abs();
      return (0.15 + 0.6 * sinVal + 0.25 * random.nextDouble()).clamp(0.1, 1.0);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _formatTimelineTime(double seconds) {
    final int mins = (seconds / 60).floor();
    final int secs = (seconds % 60).floor();
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final totalDuration = widget.maxVal <= 0.0 ? 1.0 : widget.maxVal;

    // Calculate total bars based on zoom level
    final int barCount = (100 * _zoomFactor).toInt();

    return LayoutBuilder(
      builder: (context, constraints) {
        final double timelineWidth = constraints.maxWidth;
        final double scrollableWidth = timelineWidth * _zoomFactor;

        // Adaptive time intervals for ticks based on zoom level
        double tickInterval = 10.0;
        if (_zoomFactor > 7.0) {
          tickInterval = 1.0;
        } else if (_zoomFactor > 5.0) {
          tickInterval = 2.0;
        } else if (_zoomFactor > 3.0) {
          tickInterval = 5.0;
        } else if (_zoomFactor < 1.3) {
          tickInterval = 15.0;
        }

        final List<double> ticks = [];
        for (double t = 0.0; t <= totalDuration; t += tickInterval) {
          ticks.add(t);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ZOOM CONTROL BAR
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Zoom: ${_zoomFactor.toStringAsFixed(1)}x (Pinch to zoom)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.spaceMono(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _zoomFactor = (_zoomFactor - 1.0).clamp(1.0, 10.0);
                        });
                      },
                      child: const MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Padding(
                          padding: EdgeInsets.all(6.0),
                          child: Icon(Icons.zoom_out_rounded, color: Colors.white70, size: 18),
                        ),
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        activeTrackColor: primaryColor,
                        inactiveTrackColor: Colors.white12,
                        thumbColor: Colors.white,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                      ),
                      child: SizedBox(
                        width: 65,
                        child: Slider(
                          value: _zoomFactor,
                          min: 1.0,
                          max: 10.0,
                          onChanged: (val) {
                            setState(() {
                              _zoomFactor = val;
                            });
                          },
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _zoomFactor = (_zoomFactor + 1.0).clamp(1.0, 10.0);
                        });
                      },
                      child: const MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Padding(
                          padding: EdgeInsets.all(6.0),
                          child: Icon(Icons.zoom_in_rounded, color: Colors.white70, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),

            // PINCH-TO-ZOOM GESTURE DETECTOR
            GestureDetector(
              onScaleStart: (details) {
                _baseZoomFactor = _zoomFactor;
              },
              onScaleUpdate: (details) {
                setState(() {
                  _zoomFactor = (_baseZoomFactor * details.scale).clamp(1.0, 10.0);
                });
              },
              child: Container(
                height: 110,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: SizedBox(
                    width: scrollableWidth,
                    child: Stack(
                      children: [
                        // WAVEFORM BARS
                        Positioned.fill(
                          top: 10,
                          bottom: 25,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: List.generate(barCount, (index) {
                                final double barPosSecs = (index / barCount) * totalDuration;
                                final bool isInTrimRange = barPosSecs >= widget.startVal && barPosSecs <= widget.endVal;

                                final bool isInFadeIn = isInTrimRange &&
                                    widget.fadeInVal > 0 &&
                                    (barPosSecs < widget.startVal + widget.fadeInVal);

                                final bool isInFadeOut = isInTrimRange &&
                                    widget.fadeOutVal > 0 &&
                                    (barPosSecs > widget.endVal - widget.fadeOutVal);

                                final double heightFactor = _baseHeights[index % _baseHeights.length];

                                Color barColor = Colors.white24;
                                if (isInTrimRange) {
                                  if (isInFadeIn) {
                                    barColor = Colors.tealAccent.withValues(alpha: 0.8);
                                  } else if (isInFadeOut) {
                                    barColor = Colors.orangeAccent.withValues(alpha: 0.8);
                                  } else {
                                    barColor = primaryColor;
                                  }
                                }

                                return Expanded(
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 1.0),
                                    height: 70 * heightFactor,
                                    decoration: BoxDecoration(
                                      color: barColor,
                                      borderRadius: BorderRadius.circular(1.5),
                                      boxShadow: isInTrimRange
                                          ? [
                                              BoxShadow(
                                                color: barColor.withValues(alpha: 0.2),
                                                blurRadius: 2,
                                              )
                                            ]
                                          : null,
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                        ),

                        // FADE ENVELOPE OVERLAYS
                        Positioned.fill(
                          top: 10,
                          bottom: 25,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final double w = constraints.maxWidth;
                              final double startPct = widget.startVal / totalDuration;
                              final double endPct = widget.endVal / totalDuration;
                              final double fadeInPct = widget.fadeInVal / totalDuration;
                              final double fadeOutPct = widget.fadeOutVal / totalDuration;

                              return Stack(
                                children: [
                                  if (widget.fadeInVal > 0)
                                    Positioned(
                                      left: startPct * w,
                                      width: fadeInPct * w,
                                      top: 0,
                                      bottom: 0,
                                      child: CustomPaint(
                                        painter: _FadeEnvelopePainter(isFadeIn: true),
                                      ),
                                    ),
                                  if (widget.fadeOutVal > 0)
                                    Positioned(
                                      left: (endPct - fadeOutPct) * w,
                                      width: fadeOutPct * w,
                                      top: 0,
                                      bottom: 0,
                                      child: CustomPaint(
                                        painter: _FadeEnvelopePainter(isFadeIn: false),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),

                        // RUNNING PLAYHEAD INDICATOR LINE
                        if (widget.currentPosition > 0.0)
                          Positioned(
                            top: 4,
                            bottom: 22,
                            left: (widget.currentPosition / totalDuration) * (scrollableWidth - 20) + 10,
                            child: Column(
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: Colors.amber,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.amber.withValues(alpha: 0.6),
                                        blurRadius: 4,
                                        spreadRadius: 1,
                                      )
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Container(
                                    width: 1.5,
                                    color: Colors.amber,
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // TIMELINE TICK LABELS - Positioned individually to prevent horizontal overflow
                        ...List.generate(ticks.length, (index) {
                          final double tickSecs = ticks[index];
                          final double leftOffset = (tickSecs / totalDuration) * (scrollableWidth - 20) + 10;

                          return Positioned(
                            bottom: 2,
                            left: leftOffset - 15, // Centered horizontally at the marker location
                            width: 30,
                            child: Text(
                              _formatTimelineTime(tickSecs),
                              textAlign: TextAlign.center,
                              style: GoogleFonts.spaceMono(
                                color: Colors.white38,
                                fontSize: 8,
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),

            // TRIM RANGE SELECTOR SLIDER
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: primaryColor,
                inactiveTrackColor: Colors.white12,
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayColor: primaryColor.withValues(alpha: 0.2),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: RangeSlider(
                  values: RangeValues(widget.startVal, widget.endVal),
                  min: 0.0,
                  max: totalDuration,
                  onChanged: widget.onChanged,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FadeEnvelopePainter extends CustomPainter {
  final bool isFadeIn;

  _FadeEnvelopePainter({required this.isFadeIn});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill;

    final path = Path();
    if (isFadeIn) {
      paint.shader = LinearGradient(
        colors: [
          Colors.tealAccent.withValues(alpha: 0.15),
          Colors.tealAccent.withValues(alpha: 0.0),
        ],
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

      path.moveTo(0, size.height);
      path.lineTo(size.width, 0);
      path.lineTo(size.width, size.height);
      path.close();
    } else {
      paint.shader = LinearGradient(
        colors: [
          Colors.orangeAccent.withValues(alpha: 0.15),
          Colors.orangeAccent.withValues(alpha: 0.0),
        ],
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

      path.moveTo(0, size.height);
      path.lineTo(0, 0);
      path.lineTo(size.width, size.height);
      path.close();
    }

    canvas.drawPath(path, paint);

    final linePaint = Paint()
      ..color = isFadeIn ? Colors.tealAccent.withValues(alpha: 0.4) : Colors.orangeAccent.withValues(alpha: 0.4)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final linePath = Path();
    if (isFadeIn) {
      linePath.moveTo(0, size.height);
      linePath.lineTo(size.width, 0);
    } else {
      linePath.moveTo(0, 0);
      linePath.lineTo(size.width, size.height);
    }
    canvas.drawPath(linePath, linePaint);
  }

  @override
  bool shouldRepaint(covariant _FadeEnvelopePainter oldDelegate) => false;
}
