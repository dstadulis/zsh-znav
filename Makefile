# SPDX-License-Identifier: MIT

ZNAV_BENCH_ITERS ?= 1000

.PHONY: all check lint test proof bench install uninstall

all: test

lint:
	zsh -n znav.plugin.zsh zsh-znav.plugin.zsh functions/znav functions/_znav functions/_znav_chpwd functions/_znav_directory_name functions/_znav_zshexit functions/_znav_precmd_once install.sh uninstall.sh tests/*.zsh benchmarks/*.zsh
	test -x install.sh && test -x uninstall.sh && test -x benchmarks/run_bench.zsh && test -x benchmarks/info_efficiency.py && test -x benchmarks/update_readme.py

test: lint
	zsh ./tests/run_tests.zsh

proof:
	python3 ./proofs/verify_all.py
	python3 ./tests/audit_proofs.py

check: test proof

bench:
	ZNAV_BENCH_ITERS=$(ZNAV_BENCH_ITERS) zsh ./benchmarks/run_bench.zsh

install:
	./install.sh

uninstall:
	./uninstall.sh
