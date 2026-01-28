#!/usr/bin/env python3
"""
Generate visualization charts for benchmark results.
Requires: pip install matplotlib
"""

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np

# Benchmark data
data = [
    (10, 43, True),
    (50, 178, True),
    (100, 340, True),
    (500, 1609, True),
    (1000, 3250, True),
    (2000, 6460, True),
    (3000, 9768, True),
    (3050, 9905, True),
    (3075, 9948, True),
    (3080, 10050, False),  # Estimated (exceeded)
    (3090, 10082, False),  # Estimated (exceeded)
    (3100, 10115, False),  # Estimated (exceeded)
]

users = [d[0] for d in data]
computation = [d[1] for d in data]
success = [d[2] for d in data]

# Create figure with two subplots
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))

# ============================================================
# Chart 1: Computation vs Users (main scaling chart)
# ============================================================

# Plot successful tests
success_users = [d[0] for d in data if d[2]]
success_comp = [d[1] for d in data if d[2]]
ax1.scatter(success_users, success_comp, c='green', s=100, zorder=5, label='Within limit')

# Plot failed tests
fail_users = [d[0] for d in data if not d[2]]
fail_comp = [d[1] for d in data if not d[2]]
ax1.scatter(fail_users, fail_comp, c='red', s=100, marker='x', zorder=5, label='Exceeded limit')

# Linear regression line
x_line = np.linspace(0, 3500, 100)
y_line = 10 + 3.25 * x_line
ax1.plot(x_line, y_line, 'b--', alpha=0.7, label='Linear model: 10 + 3.25x')

# Limit line
ax1.axhline(y=9999, color='red', linestyle='-', linewidth=2, label='9,999 limit')

# Safe zone shading
ax1.fill_between([0, 3500], [0, 0], [9999, 9999], alpha=0.1, color='green')
ax1.fill_between([0, 3500], [9999, 9999], [12000, 12000], alpha=0.1, color='red')

# Annotations
ax1.annotate('SAFE ZONE', xy=(1500, 5000), fontsize=12, color='green', alpha=0.7, fontweight='bold')
ax1.annotate('EXCEEDS LIMIT', xy=(1500, 10500), fontsize=12, color='red', alpha=0.7, fontweight='bold')
ax1.annotate('Max: ~3,075 users', xy=(3075, 9948), xytext=(2200, 8500),
            fontsize=10, arrowprops=dict(arrowstyle='->', color='black'))

ax1.set_xlabel('Number of Users', fontsize=12)
ax1.set_ylabel('Computation Units', fontsize=12)
ax1.set_title('processPoolDrawBatch Computation Scaling', fontsize=14, fontweight='bold')
ax1.legend(loc='upper left')
ax1.set_xlim(0, 3500)
ax1.set_ylim(0, 12000)
ax1.grid(True, alpha=0.3)

# ============================================================
# Chart 2: Computation per User (efficiency)
# ============================================================

comp_per_user = [
    (10, 4.30),
    (50, 3.56),
    (100, 3.40),
    (500, 3.22),
    (1000, 3.25),
    (2000, 3.23),
    (3000, 3.26),
    (3050, 3.25),
    (3075, 3.24),
]

cpu_users = [d[0] for d in comp_per_user]
cpu_values = [d[1] for d in comp_per_user]

ax2.bar(range(len(cpu_users)), cpu_values, color='steelblue', edgecolor='black')
ax2.set_xticks(range(len(cpu_users)))
ax2.set_xticklabels([str(u) for u in cpu_users], rotation=45)
ax2.axhline(y=3.25, color='red', linestyle='--', label='Average: 3.25')

ax2.set_xlabel('Number of Users', fontsize=12)
ax2.set_ylabel('Computation per User', fontsize=12)
ax2.set_title('Computation Efficiency by Pool Size', fontsize=14, fontweight='bold')
ax2.legend()
ax2.set_ylim(0, 5)
ax2.grid(True, alpha=0.3, axis='y')

# Add value labels on bars
for i, (u, v) in enumerate(comp_per_user):
    ax2.annotate(f'{v:.2f}', xy=(i, v + 0.1), ha='center', fontsize=9)

plt.tight_layout()
plt.savefig('benchmark/results/benchmark_chart.png', dpi=150, bbox_inches='tight')
print("Chart saved to: benchmark/results/benchmark_chart.png")

# Also show if running interactively
plt.show()
