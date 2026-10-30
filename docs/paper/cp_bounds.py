#!/usr/bin/env python3
"""Exact one-sided Clopper-Pearson bounds behind the paper's admission tables.

    python3 docs/paper/cp_bounds.py

Prints the minimum number of judged runs that certifies a verdict at a
given lower bound on precision, for 0, 1 and 2 wrongful stops, and the
upper bounds quoted for Chalk's 51 real runs. Pure Python, no SciPy.
"""
from math import comb

ALPHA = 0.05


def tail_ge(x, n, p):
    """P(X >= x) for X ~ Binomial(n, p)."""
    return sum(comb(n, k) * p**k * (1 - p) ** (n - k) for k in range(x, n + 1))


def lower(x, n, alpha=ALPHA):
    """One-sided (1 - alpha) lower bound on p after x successes in n."""
    if x == 0:
        return 0.0
    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if tail_ge(x, n, mid) < alpha:
            lo = mid
        else:
            hi = mid
    return lo


def upper(x, n, alpha=ALPHA):
    """One-sided (1 - alpha) upper bound on p after x events in n."""
    return 1 - lower(n - x, n, alpha)


def minimum_n(errors, target):
    n = errors + 1
    while lower(n - errors, n) < target:
        n += 1
    return n


if __name__ == "__main__":
    print("errors  target  min_n  bound")
    for target in (0.90, 0.95):
        for errors in (0, 1, 2):
            n = minimum_n(errors, target)
            print(f"{errors:6d}  {target:.2f}  {n:5d}  {lower(n - errors, n):.4f}")
    print()
    for x, n in ((18, 20), (19, 20), (20, 20), (28, 28), (45, 45)):
        print(f"lower({x}/{n}) = {lower(x, n):.4f}")
    print(f"upper(0 failures / 51) = {upper(0, 51):.4f}")
    print(f"upper(4 blockers / 51) = {upper(4, 51):.4f}")
