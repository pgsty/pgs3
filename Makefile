SHELL := /usr/bin/env bash

CARGO ?= cargo
PG_MAJOR ?= 17

define find_pg_config
$(strip $(shell \
	for candidate in \
		/usr/lib/postgresql/$(1)/bin/pg_config \
		/opt/homebrew/opt/postgresql@$(1)/bin/pg_config \
		/usr/local/opt/postgresql@$(1)/bin/pg_config; do \
		if test -x "$$candidate"; then printf '%s' "$$candidate"; exit 0; fi; \
	done; \
	printf '%s' /usr/lib/postgresql/$(1)/bin/pg_config))
endef

PG_CONFIG_17 ?= $(call find_pg_config,17)
PG_CONFIG_18 ?= $(call find_pg_config,18)
PG_CONFIG ?= $(PG_CONFIG_$(PG_MAJOR))
PGRX_FEATURE := pg$(PG_MAJOR)

.PHONY: fmt fmt-check print-pg-config check check-matrix clippy clippy-matrix lib-unit lib-unit-matrix unit package package-matrix \
	sql-test sql-test-matrix upgrade-static upgrade-test upgrade-test-matrix image image-matrix client-image http-smoke \
	http-smoke-matrix client-test client-test-matrix integration-lint acceptance verify \
	ceph-image ceph-collect ceph-lint ceph-test ceph-test-matrix \
	reliability-static crash-test fast-stop-test reload-test standby-test \
	lifecycle-test reliability-test robustness-static robustness-test \
	fuzz-static fuzz-test scale-static scale-test benchmark-static benchmark-smoke benchmark-test

fmt:
	$(CARGO) fmt --all

fmt-check:
	$(CARGO) fmt --all -- --check

print-pg-config:
	@printf '%s\n' '$(PG_CONFIG)'

check:
	PGRX_PG_CONFIG_PATH=$(PG_CONFIG) $(CARGO) check --no-default-features --features $(PGRX_FEATURE)

check-matrix:
	$(MAKE) check PG_MAJOR=17
	$(MAKE) check PG_MAJOR=18

clippy:
	PGRX_PG_CONFIG_PATH=$(PG_CONFIG) $(CARGO) clippy --no-default-features --features $(PGRX_FEATURE) --all-targets -- -D warnings

clippy-matrix:
	$(MAKE) clippy PG_MAJOR=17
	$(MAKE) clippy PG_MAJOR=18

lib-unit:
	PGRX_PG_CONFIG_PATH=$(PG_CONFIG) $(CARGO) test --no-default-features --features $(PGRX_FEATURE) --lib

lib-unit-matrix:
	$(MAKE) lib-unit PG_MAJOR=17
	$(MAKE) lib-unit PG_MAJOR=18

unit:
	$(CARGO) test --manifest-path tests/wire/Cargo.toml --locked

package:
	$(CARGO) pgrx package --pg-config $(PG_CONFIG) --no-default-features --features $(PGRX_FEATURE)

package-matrix:
	$(MAKE) package PG_MAJOR=17
	$(MAKE) package PG_MAJOR=18

sql-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} scripts/test-sql.sh

sql-test-matrix:
	$(MAKE) sql-test PG_MAJOR=17
	$(MAKE) sql-test PG_MAJOR=18

upgrade-static:
	PG_MAJOR=$(PG_MAJOR) tests/upgrade/run.sh --static-only --pg $(PG_MAJOR)

upgrade-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/upgrade/run.sh --pg $(PG_MAJOR)

upgrade-test-matrix:
	$(MAKE) upgrade-test PG_MAJOR=17
	$(MAKE) upgrade-test PG_MAJOR=18

image:
	scripts/build-images.sh $(PG_MAJOR)

image-matrix:
	scripts/build-images.sh 17 18

client-image:
	scripts/build-client-image.sh

ceph-image:
	scripts/build-ceph-image.sh

ceph-collect:
	tests/ceph/collect-only.sh

ceph-lint:
	bash -n scripts/build-ceph-image.sh tests/ceph/collect-only.sh \
		tests/ceph/container_run.sh tests/ceph/run-ceph.sh
	python3 -m py_compile tests/ceph/selection.py tests/ceph/summarize.py \
		tests/ceph/write_config.py tests/ceph/pgs3_adapter.py \
		tests/ceph/adapter_selftest.py tests/ceph/test_harness.py
	python3 -m unittest tests/ceph/test_harness.py

ceph-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		PGS3_SKIP_CEPH_BUILD=$${PGS3_SKIP_CEPH_BUILD:-0} \
		tests/ceph/run-ceph.sh --pg $(PG_MAJOR)

ceph-test-matrix:
	$(MAKE) ceph-test PG_MAJOR=17
	$(MAKE) ceph-test PG_MAJOR=18

http-smoke:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/integration/run-acceptance.sh --mode http-smoke --pg $(PG_MAJOR)

http-smoke-matrix:
	$(MAKE) http-smoke PG_MAJOR=17
	$(MAKE) http-smoke PG_MAJOR=18

client-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		PGS3_MANDATORY=$${PGS3_MANDATORY:-1} \
		tests/integration/run-acceptance.sh --mode clients --pg $(PG_MAJOR)

client-test-matrix:
	$(MAKE) client-test PG_MAJOR=17
	$(MAKE) client-test PG_MAJOR=18

reliability-static:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/reliability/run.sh --static-only --pg $(PG_MAJOR)

crash-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/reliability/run.sh --scenario crash --pg $(PG_MAJOR)

fast-stop-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/reliability/run.sh --scenario fast-stop --pg $(PG_MAJOR)

reload-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/reliability/run.sh --scenario reload --pg $(PG_MAJOR)

standby-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/reliability/run.sh --scenario standby --pg $(PG_MAJOR)

lifecycle-test: fast-stop-test reload-test

reliability-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/reliability/run.sh --scenario all --pg $(PG_MAJOR)

robustness-static:
	PG_MAJOR=$(PG_MAJOR) tests/robustness/run.sh --static-only --pg $(PG_MAJOR)

robustness-test:
	PG_MAJOR=$(PG_MAJOR) tests/robustness/run.sh --pg $(PG_MAJOR)

fuzz-static:
	PG_MAJOR=$(PG_MAJOR) tests/fuzz/run.sh --static-only --pg $(PG_MAJOR)

fuzz-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/fuzz/run.sh --pg $(PG_MAJOR)

scale-static:
	PG_MAJOR=$(PG_MAJOR) tests/scale/run.sh --static-only --pg $(PG_MAJOR)

scale-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/scale/run.sh --pg $(PG_MAJOR)

benchmark-static:
	PG_MAJOR=$(PG_MAJOR) tests/benchmark/run.sh --static-only --pg $(PG_MAJOR)

benchmark-smoke:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/benchmark/run.sh --profile smoke --pg $(PG_MAJOR)

benchmark-test:
	PG_MAJOR=$(PG_MAJOR) PGS3_SKIP_BUILD=$${PGS3_SKIP_BUILD:-0} \
		tests/benchmark/run.sh --profile acceptance --pg $(PG_MAJOR)

integration-lint:
	bash -n $$(find scripts tests/integration tests/ceph tests/reliability \
		tests/robustness tests/fuzz tests/scale tests/benchmark tests/upgrade \
		-type f -name '*.sh' -print | sort)
	python3 -m py_compile $$(find scripts tests/integration tests/ceph \
		tests/reliability tests/robustness tests/fuzz tests/scale tests/benchmark tests/upgrade \
		-type f -name '*.py' -print | sort)
	python3 -m unittest discover --start-directory tests/integration --pattern 'test_*.py'
	python3 -m unittest tests/ceph/test_harness.py
	python3 -m unittest discover --start-directory tests/reliability --pattern 'test_*.py'
	python3 -m unittest discover --start-directory tests/robustness --pattern 'test_*.py'
	python3 -m unittest discover --start-directory tests/fuzz --pattern 'test_*.py'
	python3 -m unittest discover --start-directory tests/scale --pattern 'test_*.py'
	python3 -m unittest discover --start-directory tests/benchmark --pattern 'test_*.py'
	python3 -m unittest discover --start-directory tests/upgrade --pattern 'test_*.py'
	python3 tests/integration/sigv4_probe.py --self-test

# The release gate is deliberately mandatory. Missing Docker/FUSE/client
# capabilities fail or record BLOCKED and return nonzero; nothing is silently
# counted as a pass. The orchestrator still runs every independent gate so one
# failure cannot hide later benchmark or compatibility results.
acceptance:
	scripts/acceptance-all.sh

verify: fmt-check check-matrix clippy-matrix lib-unit-matrix unit package-matrix sql-test-matrix upgrade-test-matrix
