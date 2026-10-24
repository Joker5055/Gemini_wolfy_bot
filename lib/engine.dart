import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

class Candle {
  final int time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory Candle.fromJson(List<dynamic> json) {
    return Candle(
      time: json[0] as int,
      open: double.parse(json[1].toString()),
      high: double.parse(json[2].toString()),
      low: double.parse(json[3].toString()),
      close: double.parse(json[4].toString()),
      volume: double.parse(json[5].toString()),
    );
  }
}

class IndicatorResult {
  final List<double?> ema9;
  final List<double?> ema21;
  final List<double?> ema50;
  final List<double?> ema200;
  final List<double?> rsi;
  final List<double?> macd;
  final List<double?> macdSignal;
  final List<double?> bbUpper;
  final List<double?> bbMiddle;
  final List<double?> bbLower;
  final List<double?> stochK;
  final List<double?> stochD;
  final List<double?> cci;
  final List<double?> adx;
  final List<double?> atr;
  final List<double?> supertrend;

  IndicatorResult({
    required this.ema9,
    required this.ema21,
    required this.ema50,
    required this.ema200,
    required this.rsi,
    required this.macd,
    required this.macdSignal,
    required this.bbUpper,
    required this.bbMiddle,
    required this.bbLower,
    required this.stochK,
    required this.stochD,
    required this.cci,
    required this.adx,
    required this.atr,
    required this.supertrend,
  });
}

class TechnicalAnalysis {
  static IndicatorResult compute(List<Candle> candles) {
    final closes = candles.map((c) => c.close).toList();
    final highs = candles.map((c) => c.high).toList();
    final lows = candles.map((c) => c.low).toList();

    final ema9 = _calcEMA(closes, 9);
    final ema21 = _calcEMA(closes, 21);
    final ema50 = _calcEMA(closes, 50);
    final ema200 = _calcEMA(closes, 200);
    final rsi = _calcRSI(closes, 14);
    final macdData = _calcMACD(closes);
    final bbData = _calcBollingerBands(closes, 20, 2.0);
    final stochData = _calcStochastic(highs, lows, closes, 14, 3);
    final cci = _calcCCI(highs, lows, closes, 20);
    final atr = _calcATR(highs, lows, closes, 14);
    final adx = _calcADX(highs, lows, closes, 14);
    final supertrend = _calcSupertrend(highs, lows, closes, atr, 3.0);

    return IndicatorResult(
      ema9: ema9,
      ema21: ema21,
      ema50: ema50,
      ema200: ema200,
      rsi: rsi,
      macd: macdData['macd']!,
      macdSignal: macdData['signal']!,
      bbUpper: bbData['upper']!,
      bbMiddle: bbData['middle']!,
      bbLower: bbData['lower']!,
      stochK: stochData['k']!,
      stochD: stochData['d']!,
      cci: cci,
      adx: adx,
      atr: atr,
      supertrend: supertrend,
    );
  }

  static List<double?> _calcEMA(List<double> data, int period) {
    List<double?> result = List.filled(data.length, null);
    if (data.length < period) return result;
    double sum = 0;
    for (int i = 0; i < period; i++) {
      sum += data[i];
    }
    double k = 2 / (period + 1);
    result[period - 1] = sum / period;
    for (int i = period; i < data.length; i++) {
      result[i] = (data[i] * k) + (result[i - 1]! * (1 - k));
    }
    return result;
  }

  static List<double?> _calcRSI(List<double> closes, int period) {
    List<double?> result = List.filled(closes.length, null);
    if (closes.length <= period) return result;
    double gainSum = 0;
    double lossSum = 0;
    for (int i = 1; i <= period; i++) {
      double diff = closes[i] - closes[i - 1];
      if (diff >= 0) {
        gainSum += diff;
      } else {
        lossSum -= diff;
      }
    }
    double avgGain = gainSum / period;
    double avgLoss = lossSum / period;
    result[period] = avgLoss == 0 ? 100 : 100 - (100 / (1 + (avgGain / avgLoss)));

    for (int i = period + 1; i < closes.length; i++) {
      double diff = closes[i] - closes[i - 1];
      double gain = diff > 0 ? diff : 0;
      double loss = diff < 0 ? -diff : 0;
      avgGain = (avgGain * (period - 1) + gain) / period;
      avgLoss = (avgLoss * (period - 1) + loss) / period;
      if (avgLoss == 0) {
        result[i] = 100;
      } else {
        double rs = avgGain / avgLoss;
        result[i] = 100 - (100 / (1 + rs));
      }
    }
    return result;
  }

  static Map<String, List<double?>> _calcMACD(List<double> closes) {
    final ema12 = _calcEMA(closes, 12);
    final ema26 = _calcEMA(closes, 26);
    List<double?> macd = List.filled(closes.length, null);
    for (int i = 0; i < closes.length; i++) {
      if (ema12[i] != null && ema26[i] != null) {
        macd[i] = ema12[i]! - ema26[i]!;
      }
    }
    List<double> macdNonNull = [];
    List<int> validIndices = [];
    for (int i = 0; i < macd.length; i++) {
      if (macd[i] != null) {
        macdNonNull.add(macd[i]!);
        validIndices.add(i);
      }
    }
    List<double?> signalPart = _calcEMA(macdNonNull, 9);
    List<double?> signal = List.filled(closes.length, null);
    for (int i = 0; i < signalPart.length; i++) {
      signal[validIndices[i]] = signalPart[i];
    }
    return {'macd': macd, 'signal': signal};
  }

  static Map<String, List<double?>> _calcBollingerBands(List<double> closes, int period, double stdDevMultiplier) {
    List<double?> upper = List.filled(closes.length, null);
    List<double?> middle = List.filled(closes.length, null);
    List<double?> lower = List.filled(closes.length, null);

    for (int i = period - 1; i < closes.length; i++) {
      double sum = 0;
      for (int j = i - period + 1; j <= i; j++) {
        sum += closes[j];
      }
      double mean = sum / period;
      double varianceSum = 0;
      for (int j = i - period + 1; j <= i; j++) {
        varianceSum += pow(closes[j] - mean, 2);
      }
      double stdDev = sqrt(varianceSum / period);
      middle[i] = mean;
      upper[i] = mean + (stdDev * stdDevMultiplier);
      lower[i] = mean - (stdDev * stdDevMultiplier);
    }
    return {'upper': upper, 'middle': middle, 'lower': lower};
  }

  static Map<String, List<double?>> _calcStochastic(List<double> highs, List<double> lows, List<double> closes, int periodK, int periodD) {
    List<double?> k = List.filled(closes.length, null);
    List<double?> d = List.filled(closes.length, null);

    for (int i = periodK - 1; i < closes.length; i++) {
      double minLow = lows.sublist(i - periodK + 1, i + 1).reduce(min);
      double maxHigh = highs.sublist(i - periodK + 1, i + 1).reduce(max);
      if (maxHigh - minLow == 0) {
        k[i] = 50;
      } else {
        k[i] = ((closes[i] - minLow) / (maxHigh - minLow)) * 100;
      }
    }

    for (int i = periodK + periodD - 2; i < closes.length; i++) {
      double sum = 0;
      int count = 0;
      for (int j = i - periodD + 1; j <= i; j++) {
        if (k[j] != null) {
          sum += k[j]!;
          count++;
        }
      }
      if (count == periodD) {
        d[i] = sum / periodD;
      }
    }
    return {'k': k, 'd': d};
  }

  static List<double?> _calcCCI(List<double> highs, List<double> lows, List<double> closes, int period) {
    List<double?> cci = List.filled(closes.length, null);
    List<double> tp = List.generate(closes.length, (i) => (highs[i] + lows[i] + closes[i]) / 3);

    for (int i = period - 1; i < closes.length; i++) {
      double mean = tp.sublist(i - period + 1, i + 1).reduce((a, b) => a + b) / period;
      double meanDev = tp.sublist(i - period + 1, i + 1).map((val) => (val - mean).abs()).reduce((a, b) => a + b) / period;
      if (meanDev == 0) {
        cci[i] = 0;
      } else {
        cci[i] = (tp[i] - mean) / (0.015 * meanDev);
      }
    }
    return cci;
  }

  static List<double?> _calcATR(List<double> highs, List<double> lows, List<double> closes, int period) {
    List<double?> atr = List.filled(closes.length, null);
    if (closes.length <= period) return atr;

    List<double> tr = [highs[0] - lows[0]];
    for (int i = 1; i < closes.length; i++) {
      double tr1 = highs[i] - lows[i];
      double tr2 = (highs[i] - closes[i - 1]).abs();
      double tr3 = (lows[i] - closes[i - 1]).abs();
      tr.add(max(tr1, max(tr2, tr3)));
    }

    double sum = tr.sublist(0, period).reduce((a, b) => a + b);
    atr[period - 1] = sum / period;
    for (int i = period; i < closes.length; i++) {
      atr[i] = (atr[i - 1]! * (period - 1) + tr[i]) / period;
    }
    return atr;
  }

  static List<double?> _calcADX(List<double> highs, List<double> lows, List<double> closes, int period) {
    List<double?> adx = List.filled(closes.length, null);
    if (closes.length <= period * 2) return adx;

    List<double> tr = [];
    List<double> plusDM = [];
    List<double> minusDM = [];

    for (int i = 1; i < closes.length; i++) {
      double upMove = highs[i] - highs[i - 1];
      double downMove = lows[i - 1] - lows[i];
      plusDM.add((upMove > downMove && upMove > 0) ? upMove : 0);
      minusDM.add((downMove > upMove && downMove > 0) ? downMove : 0);

      double tr1 = highs[i] - lows[i];
      double tr2 = (highs[i] - closes[i - 1]).abs();
      double tr3 = (lows[i] - closes[i - 1]).abs();
      tr.add(max(tr1, max(tr2, tr3)));
    }

    List<double> smoothedTR = List.filled(tr.length, 0);
    List<double> smoothedPlusDM = List.filled(tr.length, 0);
    List<double> smoothedMinusDM = List.filled(tr.length, 0);

    smoothedTR[period - 1] = tr.sublist(0, period).reduce((a, b) => a + b);
    smoothedPlusDM[period - 1] = plusDM.sublist(0, period).reduce((a, b) => a + b);
    smoothedMinusDM[period - 1] = minusDM.sublist(0, period).reduce((a, b) => a + b);

    for (int i = period; i < tr.length; i++) {
      smoothedTR[i] = smoothedTR[i - 1] - (smoothedTR[i - 1] / period) + tr[i];
      smoothedPlusDM[i] = smoothedPlusDM[i - 1] - (smoothedPlusDM[i - 1] / period) + plusDM[i];
      smoothedMinusDM[i] = smoothedMinusDM[i - 1] - (smoothedMinusDM[i - 1] / period) + minusDM[i];
    }

    List<double> dx = [];
    for (int i = period - 1; i < tr.length; i++) {
      double plusDI = 100 * (smoothedPlusDM[i] / smoothedTR[i]);
      double minusDI = 100 * (smoothedMinusDM[i] / smoothedTR[i]);
      double diff = (plusDI - minusDI).abs();
      double sum = plusDI + minusDI;
      dx.add(sum == 0 ? 0 : 100 * (diff / sum));
    }

    if (dx.length >= period) {
      double adxVal = dx.sublist(0, period).reduce((a, b) => a + b) / period;
      int startIndex = (period * 2) - 1;
      adx[startIndex] = adxVal;
      for (int i = period; i < dx.length; i++) {
        adxVal = ((adxVal * (period - 1)) + dx[i]) / period;
        adx[i + period] = adxVal;
      }
    }
    return adx;
  }

  static List<double?> _calcSupertrend(List<double> highs, List<double> lows, List<double> closes, List<double?> atr, double multiplier) {
    List<double?> st = List.filled(closes.length, null);
    List<bool> inUpperTrend = List.filled(closes.length, true);

    for (int i = 1; i < closes.length; i++) {
      if (atr[i] == null) continue;
      double hl2 = (highs[i] + lows[i]) / 2;
      double basicUpper = hl2 + (multiplier * atr[i]!);
      double basicLower = hl2 - (multiplier * atr[i]!);

      double prevUpper = basicUpper;
      double prevLower = basicLower;

      if (i > 1 && st[i - 1] != null) {
        if (closes[i - 1] <= prevUpper) {
          basicUpper = min(basicUpper, prevUpper);
        }
        if (closes[i - 1] >= prevLower) {
          basicLower = max(basicLower, prevLower);
        }
      }

      if (closes[i] > prevUpper) {
        inUpperTrend[i] = true;
      } else if (closes[i] < prevLower) {
        inUpperTrend[i] = false;
      } else {
        inUpperTrend[i] = inUpperTrend[i - 1];
      }

      st[i] = inUpperTrend[i] ? basicLower : basicUpper;
    }
    return st;
  }
}

class StrategyResult {
  final String name;
  final int signal; // +1 = BUY, -1 = SELL, 0 = NEUTRAL
  final double winRate;
  final int totalTrades;
  final double expectancy;
  final bool isProven;

  StrategyResult({
    required this.name,
    required this.signal,
    required this.winRate,
    required this.totalTrades,
    required this.expectancy,
    required this.isProven,
  });
}

class StrategyEngine {
  static List<StrategyResult> evaluateAll(List<Candle> candles, IndicatorResult ind) {
    final strategyNames = [
      "EMA Cross",
      "RSI+Bollinger",
      "MACD+Trend",
      "Supertrend",
      "ADX Trend",
      "Stoch+CCI",
      "Breakout 20",
      "Engulfing Pattern"
    ];

    List<StrategyResult> results = [];
    for (int i = 0; i < strategyNames.length; i++) {
      int currentSig = _getSignalForStrategy(i, candles.length - 1, candles, ind);
      var bt = _backtestStrategy(i, candles, ind);

      results.add(StrategyResult(
        name: strategyNames[i],
        signal: currentSig,
        winRate: bt['winRate'] ?? 0.0,
        totalTrades: bt['totalTrades'] ?? 0,
        expectancy: bt['expectancy'] ?? -1.0,
        isProven: bt['isProven'] ?? false,
      ));
    }
    return results;
  }

  static int _getSignalForStrategy(int stratIndex, int i, List<Candle> c, IndicatorResult ind) {
    if (i < 200) return 0;
    final close = c[i].close;
    final open = c[i].open;

    switch (stratIndex) {
      case 0: // EMA Cross
        if (ind.ema9[i] == null || ind.ema21[i] == null) return 0;
        if (ind.ema9[i]! > ind.ema21[i]! && ind.ema9[i - 1]! <= ind.ema21[i - 1]!) return 1;
        if (ind.ema9[i]! < ind.ema21[i]! && ind.ema9[i - 1]! >= ind.ema21[i - 1]!) return -1;
        break;
      case 1: // RSI + BB
        if (ind.rsi[i] == null || ind.bbLower[i] == null) return 0;
        if (ind.rsi[i]! < 30 && close <= ind.bbLower[i]!) return 1;
        if (ind.rsi[i]! > 70 && close >= ind.bbUpper[i]!) return -1;
        break;
      case 2: // MACD + Trend
        if (ind.macd[i] == null || ind.macdSignal[i] == null || ind.ema200[i] == null) return 0;
        if (ind.macd[i]! > ind.macdSignal[i]! && close > ind.ema200[i]!) return 1;
        if (ind.macd[i]! < ind.macdSignal[i]! && close < ind.ema200[i]!) return -1;
        break;
      case 3: // Supertrend
        if (ind.supertrend[i] == null) return 0;
        if (close > ind.supertrend[i]!) return 1;
        if (close < ind.supertrend[i]!) return -1;
        break;
      case 4: // ADX Trend
        if (ind.adx[i] == null || ind.ema50[i] == null) return 0;
        if (ind.adx[i]! > 25 && close > ind.ema50[i]!) return 1;
        if (ind.adx[i]! > 25 && close < ind.ema50[i]!) return -1;
        break;
      case 5: // Stoch + CCI
        if (ind.stochK[i] == null || ind.cci[i] == null) return 0;
        if (ind.stochK[i]! < 20 && ind.cci[i]! < -100) return 1;
        if (ind.stochK[i]! > 80 && ind.cci[i]! > 100) return -1;
        break;
      case 6: // Breakout 20
        double max20 = c.sublist(i - 20, i).map((e) => e.high).reduce(max);
        double min20 = c.sublist(i - 20, i).map((e) => e.low).reduce(min);
        if (close > max20) return 1;
        if (close < min20) return -1;
        break;
      case 7: // Engulfing
        bool isBullishEngulf = (c[i - 1].close < c[i - 1].open) && (close > open) && (close >= c[i - 1].open) && (open <= c[i - 1].close);
        bool isBearishEngulf = (c[i - 1].close > c[i - 1].open) && (close < open) && (close <= c[i - 1].open) && (open >= c[i - 1].close);
        if (isBullishEngulf) return 1;
        if (isBearishEngulf) return -1;
        break;
    }
    return 0;
  }

  static Map<String, dynamic> _backtestStrategy(int stratIndex, List<Candle> c, IndicatorResult ind) {
    int trainEnd = (c.length * 0.6).floor();

    var trainRes = _runBacktestRange(stratIndex, 200, trainEnd, c, ind);
    var testRes = _runBacktestRange(stratIndex, trainEnd, c.length, c, ind);

    bool isProven = (trainRes['expectancy'] > 0) && (testRes['expectancy'] > 0) && (trainRes['trades'] >= 3) && (testRes['trades'] >= 3);
    int totalTrades = trainRes['trades'] + testRes['trades'];
    int totalWins = trainRes['wins'] + testRes['wins'];
    double totalNetPnl = trainRes['netPnl'] + testRes['netPnl'];

    double overallExpectancy = totalTrades > 0 ? totalNetPnl / totalTrades : -1.0;
    double overallWinRate = totalTrades > 0 ? (totalWins / totalTrades) * 100 : 0.0;

    return {
      'isProven': isProven,
      'winRate': overallWinRate,
      'totalTrades': totalTrades,
      'expectancy': overallExpectancy,
    };
  }

  static Map<String, dynamic> _runBacktestRange(int stratIndex, int start, int end, List<Candle> c, IndicatorResult ind) {
    int trades = 0;
    int wins = 0;
    double netPnl = 0.0;

    for (int i = start; i < end - 12; i++) {
      int sig = _getSignalForStrategy(stratIndex, i, c, ind);
      if (sig == 0) continue;

      // Filter: higher trend check
      if (ind.ema50[i] == null || ind.ema200[i] == null) continue;
      bool higherTrendUp = c[i].close > ind.ema50[i]! && ind.ema50[i]! > ind.ema200[i]!;
      bool higherTrendDown = c[i].close < ind.ema50[i]! && ind.ema50[i]! < ind.ema200[i]!;

      if (sig == 1 && !higherTrendUp) continue;
      if (sig == -1 && !higherTrendDown) continue;

      double entry = c[i].close;
      double? atrVal = ind.atr[i];
      if (atrVal == null || atrVal == 0) continue;

      double slDist = 1.5 * atrVal;
      double tpDist = 3.0 * atrVal;

      double sl = sig == 1 ? entry - slDist : entry + slDist;
      double tp = sig == 1 ? entry + tpDist : entry - tpDist;

      trades++;
      bool closed = false;
      double pnlPct = 0.0;

      for (int k = i + 1; k <= i + 12 && k < end; k++) {
        double h = c[k].high;
        double l = c[k].low;

        if (sig == 1) {
          if (l <= sl) {
            pnlPct = - (slDist / entry);
            closed = true;
          } else if (h >= tp) {
            pnlPct = (tpDist / entry);
            wins++;
            closed = true;
          }
        } else {
          if (h >= sl) {
            pnlPct = - (slDist / entry);
            closed = true;
          } else if (l <= tp) {
            pnlPct = (tpDist / entry);
            wins++;
            closed = true;
          }
        }
        if (closed) break;
      }

      if (!closed) {
        double exitClose = c[min(i + 12, c.length - 1)].close;
        pnlPct = sig == 1 ? (exitClose - entry) / entry : (entry - exitClose) / entry;
        if (pnlPct > 0) wins++;
      }

      pnlPct -= 0.002; // 0.2% round-trip fee
      netPnl += pnlPct;
      i += 12; // move forward to avoid overlapping signals
    }

    return {
      'trades': trades,
      'wins': wins,
      'netPnl': netPnl,
      'expectancy': trades > 0 ? netPnl / trades : -1.0,
    };
  }
}

class TopSignal {
  final String pair;
  final String timeframe;
  final String direction; // BUY, SELL, NO TRADE
  final double entry;
  final double sl;
  final double tp;
  final double confidence;
  final int score;
  final String reason;

  TopSignal({
    required this.pair,
    required this.timeframe,
    required this.direction,
    required this.entry,
    required this.sl,
    required this.tp,
    required this.confidence,
    required this.score,
    required this.reason,
  });
}

class Fetcher {
  static Future<List<Candle>> getKlines(String pair, String tf) async {
    String symbol = "${pair}USDT";
    String urlPrimary = "https://data-api.binance.vision/api/v3/klines?symbol=$symbol&interval=$tf&limit=1000";
    String urlFallback = "https://api.binance.com/api/v3/klines?symbol=$symbol&interval=$tf&limit=1000";

    try {
      final res = await http.get(Uri.parse(urlPrimary)).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        List data = jsonDecode(res.body);
        return data.map((e) => Candle.fromJson(e)).toList();
      }
    } catch (_) {}

    try {
      final res = await http.get(Uri.parse(urlFallback)).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        List data = jsonDecode(res.body);
        return data.map((e) => Candle.fromJson(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<Map<String, double>> getPrices(List<String> pairs) async {
    final out = <String, double>{};
    final q = Uri.encodeComponent(jsonEncode(pairs.map((p) => "${p}USDT").toList()));
    for (final host in ['https://data-api.binance.vision', 'https://api.binance.com']) {
      try {
        final res = await http.get(Uri.parse('$host/api/v3/ticker/price?symbols=$q')).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          for (final e in jsonDecode(res.body) as List) {
            out[(e['symbol'] as String).replaceAll('USDT', '')] = double.parse(e['price'].toString());
          }
          return out;
        }
      } catch (_) {}
    }
    return out;
  }
}
