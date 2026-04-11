#!/usr/bin/env bash

python3 - <<'PY' > dk_numbers_20000.txt
import random

target = 20000
seen = set()
numbers = []

while len(numbers) < target:
    n = f"+45{random.randint(0, 99999999):08d}"
    if n not in seen:
        seen.add(n)
        numbers.append(n)

for n in numbers:
    print(n)
PY
