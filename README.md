# Tron

Battery charge limiter for Apple Silicon Macs (M1–M4). A small root launchd
daemon that caps charging at a set percentage by toggling the SMC charge keys —
keeping the battery off a constant 100% to slow wear.

## Install

```sh
./install.sh
```

Builds `tron.swift`, installs `/usr/local/bin/tron`, and starts the daemon.
Default limit is 80%.

If charging never starts on AC below the limit, macOS's own limiter is fighting
tron — turn off **System Settings → Battery → Charge Limit** (`sudo tron check`
confirms this).

## Use

```sh
sudo tron status                        # what it's doing right now
echo 75 | sudo tee /etc/tron-limit      # change the cap
echo drain | sudo tee /etc/tron-mode    # actively discharge to the cap (back: echo hold)
echo 35 | sudo tee /etc/tron-temp       # pause charging above this battery °C
sudo tron full                          # charge to 100% once, then revert
sudo tron drain-to 50                   # discharge to 50% once, then revert
sudo tron restart                       # clear a wedged SMC
```

Limit file takes 1–3 numbers, `TARGET [UP] [DOWN]` (UP/DOWN are offsets, not bounds):

- `80` → stop at 82%, recharge below 78% (default ±2 window)
- `80 1` → stop at 81%, recharge below 79%
- `80 1 2` → stop at 81%, recharge below 78% (asymmetric)

Edits apply on the next tick — no restart needed.

## How it works

Tron keeps the battery oscillating in a narrow band near the top (e.g. 79–81%)
instead of pinned at 100%, which is what wears the cell.

**hold** (default) — at the cap, charging is gated off but the **adapter stays
on**, so the Mac runs off wall power while the battery slowly discharges. When it
drops to the recharge floor, tron tops it back up, and the cycle repeats. So with
`80 1`: charge to 81%, hold off adapter power as it drains down to 79%, recharge
to 81%, repeat — a slow shallow cycle near the top instead of sitting at 100%.

**drain** — same band, but when the battery is *above* the cap, tron cuts the
adapter and runs the Mac off the battery to pull it down to the band fast. Use
this when you lower the cap and don't want to wait for natural discharge. Once
inside the band it behaves like hold.

The heat guard (`/etc/tron-temp`, default 35°C) blocks charging while the cell
is hot — holding and draining still work, since draining helps it cool.

## Uninstall

```sh
./uninstall.sh
```

Removes the daemon and re-enables normal charging.
