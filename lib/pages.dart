import 'package:flutter/material.dart';
import 'engine.dart';

class CandlestickPainter extends CustomPainter {
  final List<Candle> candles;
  final List<double?> ema9;
  final List<double?> ema21;

  CandlestickPainter({
    required this.candles,
    required this.ema9,
    required this.ema21,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;

    int displayCount = 40;
    int startIndex = candles.length > displayCount ? candles.length - displayCount : 0;
    List<Candle> visible = candles.sublist(startIndex);

    double maxHigh = visible.map((e) => e.high).reduce((a, b) => a > b ? a : b);
    double minLow = visible.map((e) => e.low).reduce((a, b) => a < b ? a : b);
    double priceRange = (maxHigh - minLow) == 0 ? 1 : maxHigh - minLow;

    double candleWidth = size.width / visible.length;

    Paint greenPaint = Paint()..color = const Color(0FF00E676)..style = PaintingStyle.fill;
    Paint redPaint = Paint()..color = const Color(0FFFF5252)..style = PaintingStyle.fill;
    Paint wickPaint = Paint()..strokeWidth = 1.2;

    for (int i = 0; i < visible.length; i++) {
      Candle c = visible[i];
      double x = i * candleWidth + (candleWidth / 2);

      double highY = size.height - ((c.high - minLow) / priceRange * size.height);
      double lowY = size.height - ((c.low - minLow) / priceRange * size.height);
      double openY = size.height - ((c.open - minLow) / priceRange * size.height);
      double closeY = size.height - ((c.close - minLow) / priceRange * size.height);

      bool isGreen = c.close >= c.open;
      wickPaint.color = isGreen ? const Color(0FF00E676) : const Color(0FFFF5252);

      canvas.drawLine(Offset(x, highY), Offset(x, lowY), wickPaint);

      double top = isGreen ? closeY : openY;
      double bottom = isGreen ? openY : closeY;
      double rectHeight = (bottom - top).abs();
      if (rectHeight < 1) rectHeight = 1;

      canvas.drawRect(
        Rect.fromLTWH(x - (candleWidth * 0.35), top, candleWidth * 0.7, rectHeight),
        isGreen ? greenPaint : redPaint,
      );
    }

    // Draw EMA 9 (Cyan) & EMA 21 (Yellow)
    _drawEMALine(canvas, size, ema9, startIndex, visible.length, minLow, priceRange, candleWidth, Colors.cyan);
    _drawEMALine(canvas, size, ema21, startIndex, visible.length, minLow, priceRange, candleWidth, Colors.amber);
  }

  void _drawEMALine(Canvas canvas, Size size, List<double?> ema, int startIndex, int length, double minLow, double range, double width, Color color) {
    Paint linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    Path path = Path();
    bool started = false;

    for (int i = 0; i < length; i++) {
      int idx = startIndex + i;
      if (idx < ema.length && ema[idx] != null) {
        double x = i * width + (width / 2);
        double y = size.height - ((ema[idx]! - minLow) / range * size.height);
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
    }
    if (started) canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
