# Falling Tower meteor automation

An OpenOS application for **GTNH 2.9.0 development**, pinned to modpack commit [`9ad74ced`](https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/tree/9ad74cedbe761bbd442451786eff7a14a644c3d5) (`2.9.0-nightly-2026-09-30-02`), not 2.8.4 stable. The immutable catalogue contains all 57 meteor definitions, focus metadata, LP costs, weighted generated blocks, fillers, and reagent effects. Detailed provenance and Blood Magic formulas: [SOURCES.md](SOURCES.md).

## Required hardware

- OpenOS computer, Tier III GPU and screen, keyboard, sufficient RAM, and writable storage. UI uses **160×50, 8-bit colour**, restoring previous resolution, depth, and colours on exit.
- One **block ME Interface**, connected to the desired network and an OC Adapter. It must also touch the transposer. No database upgrade or export bus is required.
- One transposer with three distinct sides: the ME Interface's own inventory, the blood-orb inventory, and the drop inventory. Only the latter two are additional inventories.
- Two distinct redstone I/O component addresses: ritual activation and filler control/completion.
- Any number of **GT Ore Drilling Plants I–IV** attached through OC Adapters. The program enumerates `gt_machine`, verifies `getName()`, and selects exactly `multimachine.oredrill1` through `multimachine.oredrill4`. Basic miners, pumps, void miners, and unrelated machines are excluded and never controlled.
- The filler and the ritual activator are external mechanisms built by the player; the application controls their specified I/O contracts.

**Display startup:** Tier III's native size is **160×50**. OC's `gpu.setResolution` returns whether the resolution *changed*, so `false` is normal when that size is already active. Meteor verifies the resulting dimensions rather than treating an unchanged resolution as unsupported.

### ME staging

Dedicate one ME Interface configuration/storage slot to Meteor, normally slot **1**. Configure this same slot in the TUI. Leave it unconfigured before first use. The application requests exactly one matching item in that slot, transfers exactly one into the drop inventory, then clears its reservation. Clearing lets unused staging stock return to ME.

Do not use this interface for processing patterns or let another controller configure its reserved slot. The ME address must refer to the same block that the transposer reads on its source side. Keep its channel and energy available.

**Autocraft status:** the pinned OC `CraftingStatus.save()` mutates the live `failed` flag for unfinished requests, even if ME keeps crafting; `hasFailed()` alone can therefore report `true, "no link"` for an active job. Meteor checks `isCanceled()` first: it follows a live crafting link and also reports rejected requests when no link was created. `hasFailed()` only classifies an already-stopped request as failed versus canceled. Both stop the cycle; ongoing jobs still time out, never duplicate their request, and must provide the exact input before extraction. Restored unfinished status objects without a live link still fault; this does not relax interrupted-cycle recovery.

### Orb and ritual

Place a bound blood orb in the configured orb slot. Set the exact owner name; it must also own the activation crystal and ritual. `networkEssence` is read live from the orb's OC descriptor, **not** from a guessed NBT field or a cached LP value.

**Do not wire the ritual pulse directly to the Master Ritual Stone.** Blood Magic's MRS redstone input pauses a ritual; it cannot activate an inactive Mark of the Falling Tower. Wire the output to an **edge-triggered item activator** that uses the appropriate owner-bound activation crystal on the MRS once per pulse. Keep the MRS itself unpowered and inactive before a cycle. Verify the activator fires once, not repeatedly while held high.

The application sends a high pulse of at least **0.25 seconds**, then returns low. It checks:

```text
live LP >= meteor LP + activation LP (100000) + configured reserve LP
```

Checks occur before delivery and again immediately before pulsing. There is **no post-activation LP-decrease check**: after the configured impact wait, plants start whether or not an LP drop was observable. A failed activation is therefore not detected through LP; commission the crystal activator and impact timing physically. The dashboard shows the last checked LP value. Other soul-network consumers can race any pre-activation LP read: use a reserve and avoid sharing the ritual network with uncontrolled drains.

### Drop inventory and catalyst

The output inventory has separate focus and catalyst slots, normally **1** and **2**. Your extraction/drop mechanism must route:

- Catalyst to the Alchemic Calcinator and reagent-transfer path.
- Focus to the one-block area above the MRS used by Falling Tower.

The application waits for the drop inventory to drain. After catalyst delivery, it waits a **hard-coded 30 seconds** for melting and transfer before delivering the focus. Default catalyst: **Orbis Terrae**, `AWWayofTime:bloodMagicBaseAlchemyItems:2`; one item supplies the ritual's 1000 AR unit. `Use catalyst globally` disables this step when desired.

Keep the reagent path isolated and use only the intended reagent. A consumed inventory item is not proof that a blocked pipe delivered AR. The listed hardware has no calcinator/reagent sensor. Recipe detail shows base meteor radius; Orbis Terrae modifies impact radius and filler chance as recorded in the immutable catalogue and SOURCES.

### Ore Drilling Plants

Place plants above the meteor and configure their work areas to cover it. Supply mining pipes, drilling fluid, sufficient power, maintenance, and unblocked outputs. Start with pipes retracted and plants disabled. Attach an adapter to each plant controller; no address list is maintained by hand.

Completion requires every discovered plant to:

1. Report active work with a positive maximum progress during this cycle.
2. Subsequently disable itself and report neither active work nor work to do.

Normal `MTEDrillerBase` completion follows upward pipe retraction. The controller reads the native work/allowed/active/progress callbacks; it does not inventory-count pipes or parse localized sensor text. An enabled but idle plant is not complete. A plant stopping before observed work, disconnection, or changed topology faults; a plant waiting for inputs/output or stalled retraction times out rather than authorizing cleanup.

**API limitation:** stock OC/Computronics callbacks do not expose the plant's shutdown reason. Power loss, maintenance failure, or external disabling **after observed work can resemble normal completion**. Reliable supplies, valid fake-player permissions, coverage, and exclusive machine control are required installation invariants. Do not rely on the software to distinguish those shutdowns before destructive filler cleanup; use a physical fault interlock if needed.

Ore Drilling Plants collect recognized ores. Catalogue entries containing decorative blocks, sands, hives, or other non-ores are visibly marked; valuable non-ore blocks require a suitable collection mechanism before filler cleanup. The catalogue retains those recipes without inventing ore outputs.

### Filler

- Filler output is **held high** for the entire cleanup operation.
- Input HIGH means **no work to do**. It may remain HIGH while inactive; this does not prevent starting another cycle or acknowledging recovery.
- After enabling, the controller waits for **Filler input settle**, default **1 second**, before accepting a HIGH level or a latched completion pulse. Increase this beyond your filler's startup/circuit latency so inactive HIGH is not mistaken for a completed cleanup.
- Completion pulses are latched from `redstone_changed` while the filler is enabled. A pulse from before enabling is discarded.
- Completion turns the filler output off and completes the cycle. No subsequent LOW edge is required; an already-clear area may stay HIGH throughout.

Use different input/output sides and separate wiring to prevent enable feeding back as no-work. The signal must describe the controlled cleanup area once enabled, not merely machine inactivity. Add a physical emergency-off/watchdog interlock if operating unattended: software cannot shut down a disconnected or unpowered redstone component.

## TUI workflow

Run `meteor`, or `meteor --config /path/config.cfg`. Default mutable configuration: `/etc/meteor/config.cfg`. Upgrades do not replace this file.

1. **M → Hardware setup**: choose discovered component addresses, numeric sides and slots, and exact orb owner. OC sides: `0 down`, `1 up`, `2 north/back`, `3 south/front`, `4 west/right`, `5 east/left`; use the actual component's orientation.
2. **Ore → product mappings**: select a generated ore key, then **+ Add product from slot** (or **A**). Put a physical sample in an inventory next to the configured transposer. Choose its **side (0–5)** and **1-based slot**, then **Capture and add exact sample**. A filled fluid container automatically registers its **contained fluid**; other items, including empty containers, register as **items**. Empty slots and failed reads are rejected. Sampling is read-only: the item is never transferred, drained, or consumed, and ME need not be connected. A spare slot in the orb inventory works; leave the configured orb slot untouched. Items preserve exact metadata/NBT; fluids use their registry name and stock targets in **mB**. Mappings record membership only—no per-ore yields or predicted output quantities. The physical sample need not remain afterward. **Tab** cancels side/slot edits or returns to the selected ore mapping without changing configuration.
3. **Product policies**: the union of mapped products is aggregated by exact identity. Set active, selected meteor, target stock, and **Autocraft missing inputs**. A product shared by several ores/meteors appears once; only eligible meteors are offered.
4. **Manual meteor recipe**: inspect focus, catalyst, separate LP costs, and paged ore weights. Run once or loop. Manual autocrafting permission is separate from each stock policy.
5. **Automatic**: below-target active products trigger their selected meteors, one complete cycle at a time. Competing deficits are chosen round-robin. A target absent from a successful exact ME lookup counts as **zero**, including when only other metadata/NBT variants exist. A failed ME/API observation is still an error, never fabricated zero stock.

Keyboard: arrows/Enter select; **Tab back/cancel**; `/` filter; PgUp/PgDn page; Home/End list bounds. **Backspace** deletes text in value forms. Esc is reserved by Minecraft's GUI and is not forwarded to Meteor. Dashboard shortcuts: **M** actions, **A** automatic, **S** emergency stop, **Q** quit. Lists also support touch and scrolling; value forms support clipboard paste. `D` removes an ore-product mapping. **All machine statuses** exposes every discovered plant, beyond the dashboard's short summary.

Dialogs never call `event.pull` or block the controller. Stop before changing settings. Hardware edits remain possible in a fault so disconnected wiring can be repaired. Saves validate the new settings; failures restore the in-memory values and preserve the prior file.

**ME memory use:** product registration reads only the selected physical inventory slot and its contained fluid. There is no ME search, network enumeration, retained ME iterator, or bulk fluid-list query. Stock monitoring uses `getItemInNetwork` / `getFluidInNetwork` per mapped product. Sampling requires only the configured transposer; complete ME, ritual, and mining wiring is still required before running automation.

Persistence explicitly flushes buffered writes before closing and renaming temporary files. OpenOS file close may return no values on success; a missing success boolean is not an error. Reported flush/close failures prevent replacing installed settings or clearing the ritual journal.

### Identity and NBT

Item matching uses registry name, **damage/meta**, `hasTag`, and the **opaque binary OC `tag`** when present. Fluid matching uses only its **registry name**. Item/fluid kind remains part of identity, so a cell item and its contained fluid are different products. Display labels, runtime numeric IDs, and abbreviated UI fingerprints are never matching keys. Same-name GT meta-items and same-metadata items with different NBT remain distinct through sampling, policies, persistence, counts, crafting, and transfer checks.

For tagged item products, enable server-side OpenComputers `integration.vanilla.allowItemStackNBTTags`; keep `misc.allowItemStackInspection` enabled. The settings live in the OC configuration under its `opencomputers` root. Numeric converter IDs are not needed. The program never weakens an unreadable NBT descriptor to name/meta matching.

Fluid-container sampling uses OC's `getFluidInContainerInSlot(side, slot)`, which supports both Forge `FluidContainerRegistry` entries and dynamic `IFluidContainerItem` implementations. The container's item NBT need not be exposed to identify its fluid. Under the GTNH assumption that fluids are defined by their registry identity, fluid NBT is ignored; no per-mod cell IDs or NBT layouts are maintained. Existing untagged-fluid mappings and stock policies retain their saved identity keys.

The pinned meteor focus definitions contain no NBT. They are deliberately treated as untagged exact inputs; similarly named tagged player-customized machines are not consumed by fuzzy matching.

## Sequence and recovery

```text
LP guard → catalyst fetch/craft → delivery → fixed 30s melt wait
         → focus fetch/craft → delivery → live LP guard → activation pulse
         → impact wait → all Ore Drilling Plants stop after work
         → filler held high → input settle → no-work HIGH or completion pulse → filler off
         → processing cooldown → fresh ME stock → next serial cycle
```

`Meteor wait` defaults to **15 seconds**, with a minimum of 15. This is a configurable physical settling delay, not an impact sensor: the projectile starts at Y=257 and moves downward each server tick. Increase it on lagging servers. Ensure the impact volume is empty and collision geometry is correct; the supplied hardware cannot observe the projectile or prove coverage. Use processing cooldown long enough for your ore pipeline to update ME stock; target counts are real ME quantities, not predictions from random meteor weights.

Starting a cycle writes a durable dirty journal **before** external effects. Stop during a cycle, exceptions, timeouts, or a restart with dirty/partial journal latch a fault. All reachable outputs are set low and plants disabled; a partially staged input is not replayed. Auto/loop modes never resume automatically after restarting the application.

**Recovery requires inspection**: remove stray/dropped focus items, ensure the MRS is inactive, clear the meteor area or finish the abandoned operation manually, retract and stop the plants, and empty both drop slots. Then acknowledge **Reset / recovery**; idle filler HIGH is allowed. Recovery clears the dedicated ME reservation and journal; it does not restart auto/loop. Software status and filler signals do not replace these physical inspections.

## Development and verification

```sh
lua5.2 packages/meteor/tests/run.lua
python3 packages/meteor/tools/import_catalog.py /path/to/GT-New-Horizons-Modpack \
  --revision 9ad74cedbe761bbd442451786eff7a14a644c3d5 --output /tmp/catalog.lua
cmp packages/meteor/lib/meteor/catalog.lua /tmp/catalog.lua
```

Observed verification: **47 deterministic behavioural tests** and Lua 5.2 syntax checks passed. The host smoke ran the actual launcher and Tier III TUI through physical-slot registration with ME disconnected: keyboard/touch selected an exact-NBT item and a filled cell whose item NBT was hidden, saved/reloaded both products, and preserved an existing fluid policy. After reconnecting, the dashboard displayed **17 items / 288 mB** through three targeted stock lookups, with no ME enumeration, input staging, crafting, or ritual activation. Shutdown restored the initial 80×25 display and color depth. Regressions cover empty/invalid slots, callback failures, item metadata/NBT distinctions, fluid identity across container types, duplicate mappings, cancellation, active-automation edit protection, failed-save rollback/retry, persisted fluid policies, and the existing ritual/mining/filler/autocraft safety paths. No live Minecraft instance or OC devices were available; installation wiring and server-crash behavior must be verified in-game.

Display clipping preserves strings that already fit and selects complete Unicode code-point prefixes for longer strings. It does not use OC's `unicode.wtrunc`: the pinned implementation reads past short strings for oversized width requests and can slice a UTF-16 surrogate pair. The inaccurate, unused host-side `wtrunc` helper was removed.

OC component proxy methods are callable tables with `__call`, not necessarily Lua functions. Capability checks accept both callable forms but reject missing/non-callable fields. The machine fixture models native callable method objects; a launcher smoke also wrapped the GPU methods and completed exact-input autocrafting, the 30-second catalyst delay, activation, both plants, filler, a clean journal, and shutdown.

Integration sources:

- [GT5 MTEDrillerBase: retraction and shutdown lifecycle](https://github.com/GTNewHorizons/GT5-Unofficial/blob/bf2a8219cd7dd043a4a8940abc633552588015b3/src/main/java/gregtech/common/tileentities/machines/multi/MTEDrillerBase.java)
- [GT5 MTEOreDrillingPlantBase: ore processing and work area](https://github.com/GTNewHorizons/GT5-Unofficial/blob/bf2a8219cd7dd043a4a8940abc633552588015b3/src/main/java/gregtech/common/tileentities/machines/multi/MTEOreDrillingPlantBase.java)
- [Computronics: native machine callbacks](https://github.com/GTNewHorizons/Computronics/blob/7e94219667f95354e9f721c0b4532173681a70e9/src/main/java/pl/asie/computronics/integration/gregtech/gregtech5/DriverMachine.java)
- [OC: ME interface configuration](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/integration/appeng/internal/InterfaceEnvironmentBase.scala)
- [OC: Tier III screen dimensions](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/Settings.scala#L528)
- [OC: resolution changed/not-changed return contract](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/server/component/GraphicsCard.scala#L403-L421)
- [OC: GUI key forwarding excludes Esc](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/client/gui/traits/InputBuffer.scala#L79-L85)
- [OpenOS: buffered close and explicit flush](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/resources/assets/opencomputers/loot/openos/lib/buffer.lua#L33-L59)
- [OC: callable component method objects and proxy construction](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/resources/assets/opencomputers/lua/machine.lua#L1285-L1374)
- [OC: native Unicode width/truncation implementation](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/server/machine/luac/UnicodeAPI.scala#L77-L99)
- [OC: exact product lookups and ritual-input filters](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/integration/appeng/NetworkControl.scala#L132-L273)
- [OC: physical item sampling and database storage](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/server/component/traits/WorldInventoryAnalytics.scala#L93-L145)
- [OC: cross-mod fluid-container sampling](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/server/component/traits/WorldFluidContainerAnalytics.scala#L35-L59)
- [OC: crafting-status computation, live-link callbacks, and save/load failure flag](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/integration/appeng/NetworkControl.scala#L534-L585)
