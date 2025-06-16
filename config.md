# aerospace‑swipe advanced config
aside from the basic config options presented in the readme, aerospace-swipe exposes a number of so-called tuning knobs in order to fine tune the swipe detection to your liking. everyone's hands and fingers are different, so the defaults(as much time as i spent on them) may not work for you. this prescribes the available options and how to use them.

## option reference
beneath each key you will find its `type` and `default value`. thresholds expressed as percentages are relative to the full width of the track pad.

### `natural_swipe` · *bool* · default **false**

reverses logical direction so a physical swipe **right** moves **forward** instead of back.

### `wrap_around` · *bool* · default **true**

allows cycling from the last workspace directly to the first (and vice‑versa).

### `haptic` · *bool* · default **false**

triggers a short haptic pulse after every successful workspace switch.

### `skip_empty` · *bool* · default **true**

when *true*, empty workspaces are removed from the cycling order (`aerospace_list_workspaces()` is called with `!skip_empty`).

### `fingers` · *int* · default **3**

exact finger count required for a gesture to register.

### `distance_pct` · *float* · default **0.12**

horizontal travel needed (≥12%) before a **slow** swipe may fire.

### `velocity_pct` · *float* · default **0.50**

velocity threshold expressed as fraction of pad-width/sec.

* classifies a swipe as *fast* when `|v| ≥ velocity_pct × FAST_VEL_FACTOR`.
* fires immediately when `|avg_vel| ≥ velocity_pct`.
* works with `settle_factor` to decide when a motion has "coasted" to a stop.

### `settle_factor` · *float* · default **0.15**

fraction of `velocity_pct` under which a swipe is considered settled. lower values end flicks sooner; higher values wait longer.

### `min_step` · *float* · default **0.005**

minimum per‑frame horizontal movement each finger must keep while a **slow** gesture is tracked. prevents micro‑stutters from invalidating the gesture.

### `min_travel` · *float* · default **0.015**

aggregate travel required to transition from *idle* -> *armed* while moving slowly.

### `min_step_fast` · *float* · default **0.0**

reduced per frame requirement that applies only when the swipe is already classified as *fast*.

### `min_travel_fast` · *float* · default **0.006**

smaller distance threshold to arm a *fast* swipe.
