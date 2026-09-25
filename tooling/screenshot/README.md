# Taking a screenshot that is actually readable

The recipe used for every console capture in this tutorial and in
[`envoy-grpc-modernization`](https://github.com/ephico2real2/envoy-grpc-modernization).

Written for browser automation that exposes a `screenshot` and a `zoom` action,
but the reasoning applies to any capture tool.

Every rule here exists because breaking it produced an unreadable file that had
to be retaken. The numbers are measured, not estimated.

## 1. The one rule that matters: `zoom`, never `screenshot`

The `computer` tool's **`screenshot`** action captures the whole viewport and
downscales it to a fixed ceiling — output arrives **~1512 px wide regardless of
window size**. A 1600 px-wide console page has already lost detail before you
see it, and no window size fixes that.

The **`zoom`** action takes a `region` and renders *just that rectangle*:

```
zoom  region=[100, 80, 1280, 520]   →  1568 × 585   ≈ 2.5× the pixels per character
screenshot (same page, same window) →  1512 × 798   body text unreadable
```

**Use `zoom` with a region for every capture meant for a human or a document.**
Reserve `screenshot` for your own navigation — checking a click landed, finding
coordinates for the next action. Those are throwaway.

```
computer  action=zoom  region=[x0, y0, x1, y1]  save_to_disk=true
```

## 2. Shrink the window before you capture

Counterintuitive but it follows from the ceiling: fewer CSS pixels means each
one survives closer to 1:1.

| Window | Result |
|---|---|
| 1600 × 1000 | content downscaled hard, text mushy |
| **1280 × 900** | **the working default** |
| 1100 × 800 | better still for a dense table |

```
resize_window  width=1280  height=900
```

## 3. Crop the dead space — most pages are mostly empty

A typical console capture is ~40 % nothing: a left nav rail, and white space
below content that renders in the top ~500 px. Every pixel spent on emptiness is
a pixel not spent on text.

Find the content box, then pass it as the region:

- **Left edge** — start *after* the nav rail (≈ `x=100` on the OpenShift console)
- **Top edge** — just above the heading you want (`y=60`–`80`)
- **Right edge** — the window width, unless a column is genuinely empty
- **Bottom edge** — the last row of content, **not** the window bottom

```
[100, 80, 1280, 520]    a table of ~8 rows
[100, 60, 1280, 700]    a chart plus its legend
```

If you cannot see where content ends, take one throwaway `screenshot` to find
the coordinates, then `zoom` the region. That is what the throwaway is for.

**Regions are in the tool's coordinate frame, not your CSS window size.** After
`resize_window 1280x900` the frame reported was **1568 x 776**, and a region of
`[…, 1280, 850]` was rejected as out of bounds. Every screenshot result prints
its frame — read it and size regions against that, not against the window.

## 4. Match the theme to the UI, not to a rule

There is no universally better theme. Judge by contrast in the captured file.

**Dark mode for admin consoles** — the OpenShift console's light theme is
near-white on white: cards, page background and table rows are all within a few
shades, so a light capture reads as a washed-out sheet with text floating on it
and no visible structure. Dark mode gives the panels edges and the rows
separation, which is what makes a screenshot scannable.

**Light mode for content pages** — docs, dashboards with coloured charts,
anything printed. There the background is doing no work and white wins.

The test is simply: open the file. If you cannot immediately see where one panel
ends and the next begins, switch themes and retake.

Setting the theme on the OpenShift console (it does not always follow the OS):

```
navigate  /user-preferences/general   →  Theme  →  Dark
```

## 5. Capture the real state, not an empty one

A screenshot of a dashboard with no data is worse than no screenshot.

- **Graphs need history.** A `rate(...[2m])` query needs ≥ 2 minutes of traffic
  before the line means anything. Generate load, then capture.
- **Do not block waiting for it.** Kick off whatever produces the state, go do
  other work, and come back with a *single* bounded check. Never park a polling
  loop or a `run_in_background` waiter — they survive for hours, trip the
  background sweeper on every turn, and cost the user tokens for nothing.
- **Pages load lazily.** Panels often render empty first. Wait, then capture —
  `wait` caps at 10 s per call, so chain two.

## 6. Verify before shipping

Look at what you captured. Clipped text, a legend cut in half and a half-empty
frame are only visible in the file.

```sh
python3 tooling/screenshot/verify.py <file.png> [more.png ...]
```

It reports dimensions, flags captures too small to be legible, and measures the
uniform border — a large one means the region was too generous and should be
tightened.

## 7. Save and reference

- `save_to_disk=true` returns a path under a temp directory. **Copy it into the
  repo** — temp files vanish.
- Name for the content, not the tool: `hpa-scaled.jpg`, not `screenshot-41.png`.
- Group per subject: `docs/lab01/`, `docs/lab02/`.
- `chmod 644` — captures land as `600` and are then unreadable to others.
- Caption with what the reader should notice, and quote the numbers visible in
  the image so the text stays useful when the image does not load.

## Quick recipe

```
1. resize_window          1280 × 900
2. navigate               the page
3. wait                   10 s, twice if it renders lazily
4. computer screenshot    throwaway — find the content box
5. computer zoom          region=[x0,y0,x1,y1]  save_to_disk=true
6. verify.py              check it is legible and tight
7. cp into the repo       meaningful name, chmod 644
```

## Anti-patterns

| Don't | Do |
|---|---|
| `screenshot` for a deliverable | `zoom` with a region |
| Maximise the window first | 1280 × 900 |
| Capture the whole browser frame | crop to the content box |
| Ship without opening the file | run `verify.py`, and look |
| Park a poller waiting for data | do other work, check once |
| `screenshot-41.png` | `prometheus-targets.jpg` |
| Leave it at mode `600` | `chmod 644` |

## Batching

Browser actions batch. One `browser_batch` call can navigate, wait, and capture
several pages — far fewer round trips than one call each.

```
browser_batch [ navigate → wait → zoom(save) → navigate → wait → zoom(save) ]
```

Coordinates in a batch refer to the screenshot taken **before** the call, so do
not chain a capture whose region depends on a navigation inside the same batch.
