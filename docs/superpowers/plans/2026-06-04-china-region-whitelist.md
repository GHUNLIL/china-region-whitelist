# China Region Whitelist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an offline interactive region whitelist script that denies all inbound traffic except selected mainland China province or city IP ranges.

**Architecture:** The project ships local region metadata and CIDR files. `install.sh` orchestrates interactive selection and firewall actions, while `tools/firewall_lib.sh` owns parsing and command rendering for testability.

**Tech Stack:** Bash, ipset, iptables, Python standard library tests.

---

### Task 1: Project Documents

**Files:**
- Create: `docs/superpowers/specs/2026-06-04-china-region-whitelist-design.md`
- Create: `docs/superpowers/plans/2026-06-04-china-region-whitelist.md`

- [x] **Step 1: Write the accepted design spec**

Record offline data, interactive selection, full inbound denial, and SSH lockout protection.

- [x] **Step 2: Write the implementation plan**

Record file responsibilities, test-first order, and verification commands.

### Task 2: Data Preparation

**Files:**
- Create: `tools/prepare_data.py`
- Create: `data/regions.json`
- Create: `data/regions/*.txt`

- [ ] **Step 1: Create local data directories**

Create `data/regions` and `vendor`.

- [ ] **Step 2: Download metowolf cncity index and city CIDR files on the development machine**

Use GitHub only during project preparation, not on the server.

- [ ] **Step 3: Optionally copy a local `ipipfree.ipdb` reference file with `--ipdb` when preparing private bundles**

Keep it as a local reference asset.

### Task 3: Tests

**Files:**
- Create: `tests/test_firewall_lib.py`
- Create: `tests/fixtures/regions.json`
- Create: `tests/fixtures/regions/*.txt`

- [ ] **Step 1: Write tests that call Bash helpers through subprocess**

Cover region listing, city listing, CIDR expansion, de-duplication, and dry-run command rendering.

- [ ] **Step 2: Run tests and confirm they fail before implementation**

Run `python -m unittest discover -s tests -v`.

### Task 4: Bash Helpers

**Files:**
- Create: `tools/firewall_lib.sh`

- [ ] **Step 1: Implement metadata and CIDR helpers**

Use Python one-liners for JSON parsing so the shell script does not depend on `jq`.

- [ ] **Step 2: Implement dry-run firewall command rendering**

Render commands without executing them.

- [ ] **Step 3: Run tests and confirm they pass**

Run `python -m unittest discover -s tests -v`.

### Task 5: Entrypoint

**Files:**
- Create: `install.sh`
- Create: `README.md`

- [ ] **Step 1: Implement interactive province and city selection**

Support full province and multiple cities.

- [ ] **Step 2: Implement `apply`, `dry-run`, `status`, and `clear`**

Use managed chain and managed ipset names.

- [ ] **Step 3: Document offline use and recovery**

Explain dry-run, apply, status, clear, and SSH safety prompt.

### Task 6: Verification

**Files:**
- Modify: all generated scripts as needed

- [ ] **Step 1: Run Python tests**

Run `python -m unittest discover -s tests -v`.

- [ ] **Step 2: Run Bash syntax checks**

Run `bash -n install.sh tools/firewall_lib.sh`.

- [ ] **Step 3: Run local dry-run smoke test if Bash is available**

Run `bash install.sh dry-run` and verify generated commands are coherent.
