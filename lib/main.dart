import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'engine.dart';
import 'pages.dart';

void main() {
  runApp(const WolfiesHitBotApp());
}

class WolfiesHitBotApp extends StatelessWidget {
  const WolfiesHitBotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wolfies Hit Bot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0FF0D0E12),
        primaryColor: const Color(0FF1E222D),
        cardColor: const Color(0FF181C27),
        colorScheme: const ColorScheme.dark(
          primary: Colors.amber,
          secondary: Colors.cyanAccent,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<String> pairs = ['BTC', 'ETH', 'BNB', 'SOL', 'XRP', 'DOGE', 'ADA'];
  final List<String> timeframes = ['15m', '1h', '4h'];

  String selectedPair = 'BTC';
  String selectedTF = '1h';

  List<Candle> currentCandles = [];
  IndicatorResult? currentIndicators;
  List<StrategyResult> currentStrategies = [];
  TopSignal? topOpportunity;

  Map<String, double> livePrices = {};
  WebSocketChannel? _wsChannel;
  Timer? _restTimer;

  // Demo Account State
  double demoBalance = 1000.0;
  List<Map<String, dynamic>> openPositions = [];
  List<Map<String, dynamic>> tradeHistory = [];
  bool autoBotActive = false;

  final TextEditingController amountCtrl = TextEditingController(text: "100");
  final TextEditingController slCtrl = TextEditingController(text: "2");
  final TextEditingController tpCtrl = TextEditingController(text: "4");

  @override
  void initState() {
    super.initState();
    _loadData();
    _connectWebSocket();
    _startPricePolling();
  }

  @override
  void dispose() {
    _wsChannel?.sink.close();
    _restTimer?.cancel();
    amountCtrl.dispose();
    slCtrl.dispose();
    tpCtrl.dispose();
    super.dispose();
  }

  void _loadData() async {
    List<Candle> c = await Fetcher.getKlines(selectedPair, selectedTF);
    if (c.isNotEmpty) {
      IndicatorResult ind = TechnicalAnalysis.compute(c);
      List<StrategyResult> strats = StrategyEngine.evaluateAll(c, ind);

      setState(() {
        currentCandles = c;
        currentIndicators = ind;
        currentStrategies = strats;
        livePrices[selectedPair] = c.last.close;
      });

      _calculateTopSignal(c, ind, strats);
    }
  }

  void _calculateTopSignal(List<Candle> c, IndicatorResult ind, List<StrategyResult> strats) {
    var provenStrats = strats.where((s) => s.isProven).toList();
    int buyVotes = provenStrats.where((s) => s.signal == 1).length;
    int sellVotes = provenStrats.where((s) => s.signal == -1).length;

    double entry = c.last.close;
    double? atr = ind.atr.last ?? (entry * 0.02);

    int finalScore = 0;
    String dir = "NO TRADE";
    String reason = "Market neutral hai ya strategy consensus nahi mila.";

    if (buyVotes >= 2 && buyVotes > sellVotes) {
      dir = "BUY";
      finalScore = buyVotes;
      reason = "$buyVotes proven strategies ne Buy signal confirm kiya hai.";
    } else if (sellVotes >= 2 && sellVotes > buyVotes) {
      dir = "SELL";
      finalScore = sellVotes;
      reason = "$sellVotes proven strategies ne Sell signal confirm kiya hai.";
    }

    double sl = dir == "BUY" ? entry - (1.5 * atr) : entry + (1.5 * atr);
    double tp = dir == "BUY" ? entry + (3.0 * atr) : entry - (3.0 * atr);

    setState(() {
      topOpportunity = TopSignal(
        pair: selectedPair,
        timeframe: selectedTF,
        direction: dir,
        entry: entry,
        sl: sl,
        tp: tp,
        confidence: (finalScore / 8) * 100,
        score: finalScore,
        reason: reason,
      );
    });

    if (autoBotActive && dir != "NO TRADE") {
      _executeAutoTrade(dir, entry, sl, tp);
    }
  }

  void _connectWebSocket() {
    try {
      String streamName = "${selectedPair.toLowerCase()}usdt@kline_$selectedTF";
      _wsChannel = WebSocketChannel.connect(
        Uri.parse("wss://data-stream.binance.vision/ws/$streamName"),
      );

      _wsChannel!.stream.listen((message) {
        var data = jsonDecode(message);
        if (data['k'] != null) {
          double close = double.parse(data['k']['c'].toString());
          setState(() {
            livePrices[selectedPair] = close;
            if (currentCandles.isNotEmpty) {
              currentCandles.last = Candle(
                time: currentCandles.last.time,
                open: currentCandles.last.open,
                high: max(currentCandles.last.high, close),
                low: min(currentCandles.last.low, close),
                close: close,
                volume: currentCandles.last.volume,
              );
            }
          });
        }
      }, onError: (_) {}, onDone: () {});
    } catch (_) {}
  }

  void _startPricePolling() {
    _restTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      for (String p in pairs) {
        try {
          final res = await Fetcher.getKlines(p, '15m');
          if (res.isNotEmpty) {
            double price = res.last.close;
            setState(() {
              livePrices[p] = price;
            });
            _checkPositionsTrigger(p, price);
          }
        } catch (_) {}
      }
    });
  }

  void _checkPositionsTrigger(String pair, double price) {
    List<Map<String, dynamic>> remaining = [];
    for (var pos in openPositions) {
      if (pos['pair'] == pair) {
        bool isLong = pos['type'] == 'BUY';
        double sl = pos['sl'];
        double tp = pos['tp'];
        bool hitSl = isLong ? price <= sl : price >= sl;
        bool hitTp = isLong ? price >= tp : price <= tp;

        if (hitSl || hitTp) {
          double exitPrice = hitSl ? sl : tp;
          double pnl = isLong
              ? ((exitPrice - pos['entry']) / pos['entry']) * pos['amount']
              : ((pos['entry'] - exitPrice) / pos['entry']) * pos['amount'];

          pnl -= pos['amount'] * 0.001; // 0.1% fee
          demoBalance += pos['amount'] + pnl;

          tradeHistory.add({
            'pair': pair,
            'type': pos['type'],
            'pnl': pnl,
            'reason': hitSl ? 'Stop-Loss Hit' : 'Take-Profit Hit',
          });
          continue;
        }
      }
      remaining.add(pos);
    }
    setState(() {
      openPositions = remaining;
    });
  }

  void _executeAutoTrade(String dir, double entry, double sl, double tp) {
    if (openPositions.length >= 3) return;
    if (openPositions.any((p) => p['pair'] == selectedPair)) return;

    double riskAmount = demoBalance * 0.01;
    if (demoBalance >= riskAmount) {
      setState(() {
        demoBalance -= riskAmount;
        openPositions.add({
          'pair': selectedPair,
          'type': dir,
          'entry': entry,
          'amount': riskAmount,
          'sl': sl,
          'tp': tp,
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("🐺 WOLFIES HIT BOT", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.amber)),
        backgroundColor: const Color(0FF141721),
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: Chip(
              label: Text("Demo: \$${demoBalance.toStringAsFixed(1)}", style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
              backgroundColor: const Color(0FF1E222D),
            ),
          )
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildSignalsTab(),
          _buildChartsTab(),
          _buildDemoTab(),
          _buildSeekhoTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        selectedItemColor: Colors.amber,
        unselectedItemColor: Colors.grey,
        backgroundColor: const Color(0FF141721),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.bolt), label: 'Signals'),
          BottomNavigationBarItem(icon: Icon(Icons.show_chart), label: 'Charts'),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance_wallet), label: 'Demo'),
          BottomNavigationBarItem(icon: Icon(Icons.school), label: 'Seekho'),
        ],
      ),
    );
  }

  // --- TAB 1: SIGNALS ---
  Widget _buildSignalsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  value: selectedPair,
                  isExpanded: true,
                  dropdownColor: const Color(0FF1E222D),
                  items: pairs.map((p) => DropdownMenuItem(value: p, child: Text("$p / USDT"))).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => selectedPair = v);
                      _loadData();
                    }
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  value: selectedTF,
                  isExpanded: true,
                  dropdownColor: const Color(0FF1E222D),
                  items: timeframes.map((t) => DropdownMenuItem(value: t, child: Text("Timeframe: $t"))).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => selectedTF = v);
                      _loadData();
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Top Opportunity Card
          Card(
            color: const Color(0FF1E222D),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("${topOpportunity?.pair ?? selectedPair} (${topOpportunity?.timeframe ?? selectedTF})", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: topOpportunity?.direction == "BUY"
                              ? Colors.green
                              : topOpportunity?.direction == "SELL"
                                  ? Colors.red
                                  : Colors.grey,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(topOpportunity?.direction ?? "NO TRADE", style: const TextStyle(fontWeight: FontWeight.bold)),
                      )
                    ],
                  ),
                  const Divider(color: Colors.white24, height: 20),
                  Text("Reason: ${topOpportunity?.reason ?? 'Analyzing...'}", style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 10),
                  if (topOpportunity?.direction != "NO TRADE") ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("Entry: \$${topOpportunity?.entry.toStringAsFixed(2)}"),
                        Text("SL: \$${topOpportunity?.sl.toStringAsFixed(2)}", style: const TextStyle(color: Colors.redAccent)),
                        Text("TP: \$${topOpportunity?.tp.toStringAsFixed(2)}", style: const TextStyle(color: Colors.greenAccent)),
                      ],
                    ),
                  ]
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text("Live Chart (EMA 9 & 21)", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            height: 180,
            width: double.infinity,
            color: const Color(0FF141721),
            child: CustomPaint(
              painter: CandlestickPainter(
                candles: currentCandles,
                ema9: currentIndicators?.ema9 ?? [],
                ema21: currentIndicators?.ema21 ?? [],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text("Strategy Backtest Metrics", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Table(
            border: TableBorder.all(color: Colors.white10),
            children: [
              const TableRow(
                decoration: BoxDecoration(color: Color(0FF1E222D)),
                children: [
                  Padding(padding: EdgeInsets.all(6), child: Text("Strategy", style: TextStyle(fontWeight: FontWeight.bold))),
                  Padding(padding: EdgeInsets.all(6), child: Text("Signal", style: TextStyle(fontWeight: FontWeight.bold))),
                  Padding(padding: EdgeInsets.all(6), child: Text("Win %", style: TextStyle(fontWeight: FontWeight.bold))),
                  Padding(padding: EdgeInsets.all(6), child: Text("Proven", style: TextStyle(fontWeight: FontWeight.bold))),
                ],
              ),
              ...currentStrategies.map((s) => TableRow(
                    children: [
                      Padding(padding: const EdgeInsets.all(6), child: Text(s.name, style: const TextStyle(fontSize: 12))),
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          s.signal == 1 ? "BUY" : s.signal == -1 ? "SELL" : "WAIT",
                          style: TextStyle(color: s.signal == 1 ? Colors.green : s.signal == -1 ? Colors.red : Colors.grey, fontSize: 12),
                        ),
                      ),
                      Padding(padding: const EdgeInsets.all(6), child: Text("${s.winRate.toStringAsFixed(0)}%", style: const TextStyle(fontSize: 12))),
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(s.isProven ? Icons.check_circle : Icons.cancel, color: s.isProven ? Colors.green : Colors.red, size: 16),
                      ),
                    ],
                  )),
            ],
          )
        ],
      ),
    );
  }

  // --- TAB 2: CHARTS ---
  Widget _buildChartsTab() {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.1, crossAxisSpacing: 8, mainAxisSpacing: 8),
      itemCount: pairs.length,
      itemBuilder: (context, index) {
        String p = pairs[index];
        double price = livePrices[p] ?? 0.0;
        return Card(
          color: const Color(0FF181C27),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text("$p/USDT", style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text("\$${price.toStringAsFixed(2)}", style: const TextStyle(fontSize: 16, color: Colors.amber)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.green.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                  child: const Text("LIVE MONITOR", style: TextStyle(color: Colors.green, fontSize: 10)),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  // --- TAB 3: DEMO ---
  Widget _buildDemoTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("Balance: \$${demoBalance.toStringAsFixed(2)} USDT", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.amber)),
              ElevatedButton(
                onPressed: () => setState(() {
                  demoBalance = 1000.0;
                  openPositions.clear();
                  tradeHistory.clear();
                }),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                child: const Text("Reset Demo"),
              )
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text("Auto Demo Bot (1% Risk)"),
            subtitle: const Text("Proven signals aane par automatic trade execute karega."),
            value: autoBotActive,
            onChanged: (v) => setState(() => autoBotActive = v),
          ),
          const SizedBox(height: 12),
          TextField(controller: amountCtrl, decoration: const InputDecoration(labelText: "Trade Amount (USDT)", border: OutlineInputBorder())),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: TextField(controller: slCtrl, decoration: const InputDecoration(labelText: "SL %", border: OutlineInputBorder()))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: tpCtrl, decoration: const InputDecoration(labelText: "TP %", border: OutlineInputBorder()))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _manualTrade("BUY"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  child: const Text("BUY / LONG"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _manualTrade("SELL"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text("SELL / SHORT"),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text("Open Positions", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ...openPositions.map((p) => ListTile(
                title: Text("${p['pair']} (${p['type']}) - Amount: \$${p['amount'].toStringAsFixed(1)}"),
                subtitle: Text("Entry: \$${p['entry'].toStringAsFixed(2)}"),
                trailing: IconButton(
                  icon: const Icon(Icons.close, color: Colors.red),
                  onPressed: () => _closePosition(p),
                ),
              )),
        ],
      ),
    );
  }

  void _manualTrade(String type) {
    double amt = double.tryParse(amountCtrl.text) ?? 10.0;
    double price = livePrices[selectedPair] ?? 100.0;
    double slP
