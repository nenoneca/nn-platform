# Agent Knowledge Base

This folder contains the knowledge an AI agent needs to work effectively on this project.
Read the files relevant to your task before making changes.

## Index

| File | When to read |
|---|---|
| [project_structure.md](project_structure.md) | First time in the repo; before adding files or apps |
| [build_and_flash.md](build_and_flash.md) | Before building or flashing any firmware |
| [hardware_esp32c6.md](hardware_esp32c6.md) | Before touching BLE, 802.15.4, RF, or coexistence code |
| [library_node_mgr.md](library_node_mgr.md) | Before modifying or reusing the node_mgr library |
| [ble_ot_provisioning.md](ble_ot_provisioning.md) | Before touching the BLE provisioning app or protocol |
| [zephyr_patterns.md](zephyr_patterns.md) | Before writing any Zephyr firmware code |
| [known_issues.md](known_issues.md) | Before debugging; contains hard-won root causes |

## Quick-start checklist

1. Read `project_structure.md` to understand where things live.
2. For firmware changes: read `zephyr_patterns.md` + the relevant app doc.
3. For hardware/RF issues: always read `hardware_esp32c6.md` first.
4. Before debugging a new failure: scan `known_issues.md`.
5. Run a build to verify before claiming a fix is complete.
