import 'dart:async';
import 'dart:convert';
import 'dart:math';
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
        scaffoldBackgroundColor: const Color(0xFF0D0E12),
        primaryColor: const Color(0xFF1E222D),
        cardColor: const Color(0xFF181C27),
        colorScheme: const ColorScheme.dark(primary: Colors.amber, secondary: Colors.cyanAccent),
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
  StreamSubscription? _wsSub;
  Timer? _restTimer;
  Timer? _reloadTimer;

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
    _startPricePolling();
    _reloadTimer = Timer.periodic(const Duration(minutes: 3), (_) => _loadData());
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _wsChannel?.sink.close();
    _restTimer?.cancel();
    _reloadTimer?.cancel();
    amountCtrl.dispose();
    slCtrl.dispose();
    tpCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    List<Candle> c = await Fetcher.getKlines(selectedPair, selectedTF);
    if (c.length < 250 || !mounted) return;
    IndicatorResult ind = TechnicalAnalysis.compute(c);
    List<StrategyResult> strats = StrategyEngine.evaluateAll(c, ind);
    setState(() {
      currentCandles = c;
      currentIndicators = ind;
      currentStrategies = strats;
      livePrices[selectedPair] = c.last.close;
    });
    _calculateTopSignal(c, ind, strats);
    _connectWebSocket();
  }

  void _calculateTopSignal(List<Candle> c, IndicatorResult ind, List<StrategyResult> strats) {
    var proven = strats.where((s) => s.isProven).toList();
    int buyVotes = proven.where((s) => s.signal == 1).length;
    int sellVotes = proven.where((s) => s.signal == -1).length;

    double entry = c.last.close;
    double atr = ind.atr.last ?? (entry * 0.02);

    int finalScore = 0;
    String dir = "NO TRADE";
    String reason = "Proven strategies me agreement nahi hai (ya koi strategy proven nahi). Abhi trade mat lo.";

    if (buyVotes >= 2 && buyVotes > sellVotes) {
      dir = "BUY";
      finalScore = buyVotes;
      reason = "$buyVotes proven strategies ne Buy signal diya hai.";
    } else if (sellVotes >= 2 && sellVotes > buyVotes) {
      dir = "SELL";
      finalScore = sellVotes;
      reason = "$sellVotes proven strategies ne Sell signal diya hai.";
    }

    double sl = dir == "SELL" ? entry + (1.5 * atr) : entry - (1.5 * atr);
    double tp = dir == "SELL" ? entry - (3.0 * atr) : entry + (3.0 * atr);

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
    _wsSub?.cancel();
    _wsChannel?.sink.close();
    try {
      final name = "${selectedPair.toLowerCase()}usdt@kline_$selectedTF";
      _wsChannel = WebSocketChannel.connect(Uri.parse("wss://data-stream.binance.vision/ws/$name"));
      _wsSub = _wsChannel!.stream.listen((message) {
        final data = jsonDecode(message as String);
        final k = data['k'];
        if (k == null || currentCandles.isEmpty || !mounted) return;
        final close = double.parse(k['c'].toString());
        final t = k['t'] as int;
        setState(() {
          livePrices[selectedPair] = close;
          final last = currentCandles.last;
          if (last.time == t) {
            currentCandles[currentCandles.length - 1] = Candle(
              time: t, open: last.open, high: max(last.high, close), low: min(last.low, close), close: close, volume: last.volume);
          } else {
            currentCandles.add(Candle(
              time: t,
              open: double.parse(k['o'].toString()),
              high: double.parse(k['h'].toString()),
              low: double.parse(k['l'].toString()),
              close: close,
              volume: double.parse(k['v'].toString())));
          }
        });
      }, onError: (_) {});
    } catch (_) {}
  }

  void _startPricePolling() {
    _restTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final prices = await Fetcher.getPrices(pairs);
      if (prices.isEmpty || !mounted) return;
      setState(() => livePrices.addAll(prices));
      prices.forEach(_checkPositionsTrigger);
    });
  }

  void _checkPositionsTrigger(String pair, double price) {
    List<Map<String, dynamic>> remaining = [];
    bool changed = false;
    for (var pos in openPositions) {
      if (pos['pair'] == pair) {
        bool isLong = pos['type'] == 'BUY';
        double sl = pos['sl'];
        double tp = pos['tp'];
        bool hitSl = isLong ? price <= sl : price >= sl;
        bool hitTp = isLong ? price >= tp : price <= tp;
        if (hitSl || hitTp) {
          double exitPrice = hitTp ? tp : sl;
          double pnl = (isLong ? (exitPrice - pos['entry']) : (pos['entry'] - exitPrice)) / pos['entry'] * pos['amount'];
          pnl -= pos['amount'] * 0.002;
          demoBalance += pos['amount'] + pnl;
          tradeHistory.insert(0, {'pair': pair, 'type': pos['type'], 'pnl': pnl, 'reason': hitTp ? 'Target Hit' : 'Stop-Loss Hit'});
          changed = true;
          continue;
        }
      }
      remaining.add(pos);
    }
    if (changed) setState(() => openPositions = remaining);
  }

  void _executeAutoTrade(String dir, double entry, double sl, double tp) {
    if (openPositions.length >= 3) return;
    if (openPositions.any((p) => p['pair'] == selectedPair)) return;
    double risk = demoBalance * 0.01;
    double dist = (entry - sl).abs() / entry;
    double amount = dist == 0 ? risk : min(demoBalance, risk / dist);
    if (amount < 1) return;
    setState(() {
      demoBalance -= amount;
      openPositions.add({'pair': selectedPair, 'type': dir, 'entry': entry, 'amount': amount, 'sl': sl, 'tp': tp});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("WOLFIES HIT BOT", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.amber)),
        backgroundColor: const Color(0xFF141721),
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: Chip(
              label: Text("Demo: \$${demoBalance.toStringAsFixed(1)}", style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
              backgroundColor: const Color(0xFF1E222D),
            ),
          )
        ],
      ),
      body: IndexedStack(index: _currentIndex, children: [_buildSignalsTab(), _buildChartsTab(), _buildDemoTab(), _buildSeekhoTab()]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        selectedItemColor: Colors.amber,
        unselectedItemColor: Colors.grey,
        backgroundColor: const Color(0xFF141721),
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

  Widget _buildSignalsTab() {
    final t = topOpportunity;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: DropdownButton<String>(
                value: selectedPair,
                isExpanded: true,
                dropdownColor: const Color(0xFF1E222D),
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
                dropdownColor: const Color(0xFF1E222D),
                items: timeframes.map((x) => DropdownMenuItem(value: x, child: Text("Timeframe: $x"))).toList(),
                onChanged: (v) {
                  if (v != null) {
                    setState(() => selectedTF = v);
                    _loadData();
                  }
                },
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Card(
            color: const Color(0xFF1E222D),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text("${t?.pair ?? selectedPair} (${t?.timeframe ?? selectedTF})", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: t?.direction == "BUY" ? Colors.green : (t?.direction == "SELL" ? Colors.red : Colors.grey),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(t?.direction ?? "LOADING", style: const TextStyle(fontWeight: FontWeight.bold)),
                    )
                  ]),
                  const Divider(color: Colors.white24, height: 20),
                  Text("Reason: ${t?.reason ?? 'Analyzing...'}", style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 10),
                  if (t != null && t.direction != "NO TRADE")
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text("Entry: \$${t.entry.toStringAsFixed(2)}"),
                      Text("SL: \$${t.sl.toStringAsFixed(2)}", style: const TextStyle(color: Colors.redAccent)),
                      Text("TP: \$${t.tp.toStringAsFixed(2)}", style: const TextStyle(color: Colors.greenAccent)),
                    ]),
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
            color: const Color(0xFF141721),
            child: CustomPaint(
              painter: CandlestickPainter(
                candles: currentCandles,
                ema9: currentIndicators?.ema9 ?? [],
                ema21: currentIndicators?.ema21 ?? [],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text("Strategy Backtest (fees ke baad)", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Table(
            border: TableBorder.all(color: Colors.white10),
            children: [
              const TableRow(decoration: BoxDecoration(color: Color(0xFF1E222D)), children: [
                Padding(padding: EdgeInsets.all(6), child: Text("Strategy", style: TextStyle(fontWeight: FontWeight.bold))),
                Padding(padding: EdgeInsets.all(6), child: Text("Signal", style: TextStyle(fontWeight: FontWeight.bold))),
                Padding(padding: EdgeInsets.all(6), child: Text("Win %", style: TextStyle(fontWeight: FontWeight.bold))),
                Padding(padding: EdgeInsets.all(6), child: Text("Proven", style: TextStyle(fontWeight: FontWeight.bold))),
              ]),
              ...currentStrategies.map((s) => TableRow(children: [
                    Padding(padding: const EdgeInsets.all(6), child: Text(s.name, style: const TextStyle(fontSize: 12))),
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(s.signal == 1 ? "BUY" : (s.signal == -1 ? "SELL" : "WAIT"),
                          style: TextStyle(color: s.signal == 1 ? Colors.green : (s.signal == -1 ? Colors.red : Colors.grey), fontSize: 12)),
                    ),
                    Padding(padding: const EdgeInsets.all(6), child: Text("${s.winRate.toStringAsFixed(0)}% (${s.totalTrades})", style: const TextStyle(fontSize: 12))),
                    Padding(padding: const EdgeInsets.all(6), child: Icon(s.isProven ? Icons.check_circle : Icons.cancel, color: s.isProven ? Colors.green : Colors.red, size: 16)),
                  ])),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildChartsTab() {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.1, crossAxisSpacing: 8, mainAxisSpacing: 8),
      itemCount: pairs.length,
      itemBuilder: (context, index) {
        String p = pairs[index];
        double price = livePrices[p] ?? 0.0;
        return Card(
          color: const Color(0xFF181C27),
          child: InkWell(
            onTap: () {
              setState(() {
                selectedPair = p;
                _currentIndex = 0;
              });
              _loadData();
            },
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text("$p/USDT", style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text("\$${price.toStringAsFixed(price < 10 ? 4 : 2)}", style: const TextStyle(fontSize: 16, color: Colors.amber)),
                const SizedBox(height: 8),
                const Text("Tap: chart + signal", style: TextStyle(color: Colors.green, fontSize: 11)),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDemoTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text("Balance: \$${demoBalance.toStringAsFixed(2)}", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.amber)),
            ElevatedButton(
              onPressed: () => setState(() {
                demoBalance = 1000.0;
                openPositions.clear();
                tradeHistory.clear();
              }),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              child: const Text("Reset Demo"),
            )
          ]),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text("Auto Demo Bot (1% Risk)"),
            subtitle: const Text("Proven signal aane par demo trade khud khole (har 3 min check)."),
            value: autoBotActive,
            onChanged: (v) {
              setState(() => autoBotActive = v);
              if (v) _loadData();
            },
          ),
          const SizedBox(height: 12),
          TextField(controller: amountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "Trade Amount (USDT)", border: OutlineInputBorder())),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: slCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "SL %", border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: tpCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "TP %", border: OutlineInputBorder()))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: ElevatedButton(onPressed: () => _manualTrade("BUY"), style: ElevatedButton.styleFrom(backgroundColor: Colors.green), child: const Text("BUY / LONG"))),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton(onPressed: () => _manualTrade("SELL"), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text("SELL / SHORT"))),
          ]),
          const SizedBox(height: 16),
          const Text("Open Positions", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ...openPositions.map((p) => ListTile(
                title: Text("${p['pair']} (${p['type']}) \$${(p['amount'] as double).toStringAsFixed(1)}"),
                subtitle: Text("Entry ${(p['entry'] as double).toStringAsFixed(2)}  SL ${(p['sl'] as double).toStringAsFixed(2)}  TP ${(p['tp'] as double).toStringAsFixed(2)}"),
                trailing: IconButton(icon: const Icon(Icons.close, color: Colors.red), onPressed: () => _closePosition(p)),
              )),
          const SizedBox(height: 12),
          const Text("History", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ...tradeHistory.take(30).map((h) => ListTile(
                dense: true,
                title: Text("${h['pair']} ${h['type']} - ${h['reason']}"),
                trailing: Text((h['pnl'] as double).toStringAsFixed(2), style: TextStyle(color: (h['pnl'] as double) >= 0 ? Colors.greenAccent : Colors.redAccent, fontWeight: FontWeight.bold)),
              )),
          const Text("Fees 0.2% shamil. App khula ho tabhi SL/TP auto-close hota hai.", style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }

  void _manualTrade(String type) {
    double amt = double.tryParse(amountCtrl.text) ?? 10.0;
    double price = livePrices[selectedPair] ?? 0.0;
    double slP = double.tryParse(slCtrl.text) ?? 2.0;
    double tpP = double.tryParse(tpCtrl.text) ?? 4.0;
    if (price <= 0 || amt <= 0 || amt > demoBalance || openPositions.length >= 3) return;
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
        double slP = double.tryParse(slCtrl.text) ?? 2.0;
    double tpP = double.tryParse(tpCtrl.text) ?? 4.0;
    if (amt <= 0 || amt > demoBalance || openPositions.length >= 3) return;
    double sl = type == "BUY" ? price * (1 - slP / 100) : price * (1 + slP / 100);
    double tp = type == "BUY" ? price * (1 + tpP / 100) : price * (1 - tpP / 100);
    setState(() {
      demoBalance -= amt;
      openPositions.add({'pair': selectedPair, 'type': type, 'entry': price, 'amount': amt, 'sl': sl, 'tp': tp});
    });
  }

  void _closePosition(Map<String, dynamic> p) {
    double price = livePrices[p['pair']] ?? (p['entry'] as double);
    bool isLong = p['type'] == 'BUY';
    double pnl = (isLong ? (price - p['entry']) : (p['entry'] - price)) / p['entry'] * p['amount'];
    pnl -= p['amount'] * 0.002;
    setState(() {
      demoBalance += p['amount'] + pnl;
      openPositions.remove(p);
      tradeHistory.add({'pair': p['pair'], 'type': p['type'], 'pnl': pnl, 'reason': 'Manual Close'});
    });
  }

  Widget _buildSeekhoTab() {
    const lessons = {
      'USDT kya hai?': 'Ek coin jiski value lagbhag 1 dollar rehti hai. BTCUSDT ka matlab BTC ki price USDT me.',
      'BUY aur SELL': 'BUY: price badhne par profit. SELL (short): price girne par profit, ye futures me hota hai.',
      'Stop-loss (SL)': 'Loss limit price. SL ke bina trade kabhi mat lo.',
      'Target (TP)': 'Profit lene ki price. Ye app risk:reward 1:2 rakhta hai.',
      '1% risk rule': 'Ek trade me capital ka max 1% khone ka risk lo.',
      'Proven strategy': 'Wahi strategy gini jati hai jo fees ke baad train aur test dono me positive thi. Future ki guarantee nahi.',
      'Kab trade nahi?': 'Jab app NO TRADE dikhaye, SL na laga ho, ya aap loss recover karne ki jaldbazi me ho.',
      'Pehle kya karein?': 'Demo me 2-4 hafte chalayein. Positive result na aaye to real paise na lagayein.',
    };
    return ListView(children: [
      for (final e in lessons.entries)
        ExpansionTile(title: Text(e.key), children: [Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text(e.value))]),
    ]);
  }
}
