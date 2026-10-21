# Fleet dashboard live core journey

## User outcome

The fleet dashboard shows live fleet state in a real browser at a 390px phone width: each lane with its task title and state on the Board, and the queue and wait reasons on Insights. The one-tap Stuck and Waiting tabs (`#/board?tab=stuck`, `tab=waiting`) hold only those lanes, and a home's count reads against its lane cap (`4 / 3`, amber when over) in the by-home view (`rows=home`), at 390px and 1280px.

## Drive

Run `done-done run core` from the repo root (it runs `bash fleet-dashboard/run-core-proof.sh` and sets `DONE_DONE_EVIDENCE_ROOT`). The script seeds a throwaway Firstmate home with agent lanes, in-flight, queued and held tasks and one landed task, builds and serves `fleet-dashboard/fm-dashboard.sh` from this checkout against that seed, opens the Board and Insights in headless Chrome with `chrome-devtools-axi`, and fails unless the expected lanes and reasons are on the page. It reads only the seed: stubs replace herdr, quota, device and service probes, and the queue reasons come from this checkout's fleet-flow reader. It needs a Firstmate `bin/` (`FM_BIN`, default `~/firstmate/bin`) for the dashboard's helper scripts.

## Evidence

`board-390.png` and `board.txt` show the Board lanes with their titles and states (Blocked, Main decides, waiting). `queue-390.png` and `queue.txt` show Insights with the queue and wait reasons ("Why work waits now", "Blocked · own note", "Lead reply", "Held"). Check that every lane named in the Board is one the seed wrote, and that no page text shows a raw path, id or internal word. `board-{active,stuck,waiting,homes}-{390,1280}.png` and `.txt` show the tabs and the cap; the run fails unless the Stuck tab lacks `m-build`, the Waiting tab lacks `m-stuck`, and both by-home views read `4 / 3`. Do not use a real fleet home as the proof.
