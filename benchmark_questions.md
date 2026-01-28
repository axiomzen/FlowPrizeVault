# Benchmark Simulation - Configuration Questions

Please fill in your answers after each question. Delete the placeholder text and type your response.

---

## 1. User Scale Range

What range of users do you want to test?

**Suggested options**: 10, 50, 100, 250, 500, 1000, 5000, 10000

**Your answer**: 10 to 10000, I want to find the upper limit that I can process in a single batch is my main goal

---

## 2. Batch Size Testing

For `processPoolDrawBatch(limit)`, what batch sizes should we test?

Note: Flow mainnet computation limit is ~9,999 units per transaction.

**Suggested options**: 10, 25, 50, 100, 200, 500

**Your answer**: find maximum automatically.  The goal is that when a round ends, I can send as few trasnactions as possible so that I can process the round as fast as possible py putting in the max limit with the max gas limit on my transactions

---

## 3. Deposit Complexity

Should users have simple or realistic deposit patterns?

- **simple**: Single deposit at start (faster, best-case computation)
- **realistic**: Multiple deposits/withdrawals per user (slower, worst-case computation)

**Your answer**: simple for now

---

## 4. Output Format

What output format is most useful?

- **terminal**: Table printed to console
- **csv**: CSV file for spreadsheet/analysis
- **json**: JSON file for programmatic use
- **all**: All of the above

**Your answer**: all

---

## 5. Build Approach

Should I build on existing infrastructure or create something new?

- **extend**: Extend existing `test_prize_savings.py`
- **new-python**: New lightweight Python script
- **bash**: Simple bash script with flow CLI

**Your answer**: new-python

---

## 6. Gas Price for Cost Calculation

What gas price should I use for cost estimates? (in FLOW per computation unit)

Note: You can provide multiple values for comparison, or say "use defaults"

**Your answer**: skip-cost calculation for now, just deal in Computation units

---

## 7. Time Budget

How long is acceptable for the full simulation to run?

- **quick**: ~5 minutes (fewer data points)
- **moderate**: ~15-30 minutes (good coverage)
- **thorough**: ~1 hour+ (comprehensive data)

**Your answer**: Would it be possible to do a quick benchmark such that we can verify results are accurate, then we can scale up?

---

## 8. Any Additional Requirements?

Anything else I should know or include?

**Your answer**: The ultimate goal is that I want to be able to know how many users I can process in a single batch such that I can speed up the process of finishing a draw and know roughly how long it will take to fully process a draw depending on the number of participants.  if there is more informaiton you can learn about profiling and finding parts of the process that are particularly computationlly expensive adn can be optimized, that would also be beneficial


---

# Summary (I'll fill this in after reading your answers)

Once you've filled in your answers, save the file and let me know. I'll read it and proceed with the implementation.
