# Meteor catalogue sources

`lib/meteor/catalog.lua` is generated data.  It is not a hand-maintained list of
ore blocks and MUST be regenerated when the pack's Blood Magic meteor config
changes.  The checked-in snapshot is the 57 top-level meteor files and five
reagent files in the GTNH 2.9 development config at:

- GTNH modpack/config revision: `9ad74cedbe761bbd442451786eff7a14a644c3d5`
  (`2.9.0-nightly-2026-09-30-02`)
- Blood Magic source revision: `10a36f6413b8a7ce6ebf16ca8b04614ff15566cd`
- OpenComputers source revision: `1e4559ff5f2443695cb28c7cdc9fba87219a862b`

The catalogue records these source revisions in `catalog.source` and stores
each original JSON object under `recipe.raw`.  This preserves fields that are
not currently needed by the controller.

## Reproducing the generated file

The importer uses only the Python standard library.  Its source argument may
be a modpack root, a `config` directory, or the
`config/BloodMagic/meteors` directory:

```text
python3 packages/meteor/tools/import_catalog.py \
  /path/to/modpack \
  --revision <GTNH-config-commit> \
  --output packages/meteor/lib/meteor/catalog.lua
```

Meteor files are read in byte-name order, so ordering is stable and does not
depend on filesystem enumeration.  `--revision` is optional for a local
snapshot, but SHOULD be supplied for a pinned build.  The importer rejects
malformed JSON, missing focus items, missing ore arrays, and malformed
component strings rather than silently dropping a recipe.

## Data contract and identities

The module returns an immutable table with `activationLP = 100000`,
`source`, and `recipes`.  Each recipe has its source filename `id` and `label`,
focus descriptor, default catalyst descriptor, base meteor `lp`, radius, ore
components, filler components, filler chance, raw source, and reagent amount.
`catalyst_quantity = 1` is explicit.  `recipe.reserve_lp` is the ritual
activation plus the meteor cost; a controller that also applies its configured
LP reserve SHOULD calculate `catalog.activationLP + recipe.lp +
config.reserveLP` rather than treating reagent effects as an LP surcharge.

The default catalyst is the exact item ID
`AWWayofTime:bloodMagicBaseAlchemyItems:2` (registry name
`AWWayofTime:bloodMagicBaseAlchemyItems`, metadata 2).  Blood Magic registers
one such item as one `orbisTerrae` reagent stack of 1000 AR.  The summon ritual
attempts to drain 1000 AR per available reagent, so one catalyst item supplies
one Orbis Terrae effect unit; Orbis Terrae does not alter LP cost.

Component keys are preserved exactly as either `OREDICT:<name>` or
`mod:item:meta`; `weight` is separate from the key, and `filler` is separate
from `ores`.  `raw` retains the original component string, including optional
reagent requirements.  No block registry is consulted by the importer and no
fixed number of blocks is inferred.  At impact Blood Magic resolves an
OREDICT key to the first registered block stack and then samples each surviving
component by its relative weight.  This means an ore dictionary key is not a
promise of a particular concrete block or yield.

Focus descriptors have `kind`, registry `name`, integer `damage`, and
`hasTag=false`.  All 57 current focus strings are untagged and contain no NBT.
Blood Magic's config format does not support NBT focus matching.  This is also
important for OpenComputers: `ConverterItemStack` only exposes compressed NBT
when `allowItemStackNBTTags` is enabled; a tagged identity MUST NOT be merged
with an untagged one merely because registry name and damage match.

Product registration reads a physical sample through the existing transposer;
it does not enumerate ME storage. `getFluidInContainerInSlot(side, slot)` checks
Forge's `FluidContainerRegistry` and then `IFluidContainerItem`, so filled cells
from either mechanism resolve to their contained fluid without interpreting
mod-specific metadata or item NBT in Lua. Noncontainers and empty containers
register as exact items; empty slots are rejected. Fluids use registry-name-only
identity under the GTNH no-distinct-fluid-NBT assumption. Numeric runtime IDs,
container identity, and contained amount are not fluid identity fields.

Sampling sources at the pinned OpenComputers revision:
- [Physical item descriptor](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/integration/vanilla/ConverterItemStack.scala#L20-L61)
- [Cross-mod fluid-container lookup](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/server/component/traits/WorldFluidContainerAnalytics.scala#L35-L59)
- [Fluid descriptor fields](https://github.com/GTNewHorizons/OpenComputers/blob/1e4559ff5f2443695cb28c7cdc9fba87219a862b/src/main/scala/li/cil/oc/integration/vanilla/ConverterFluidStack.scala#L11-L24)

## Ore-miner safety and non-ore outputs

The complete source lists are retained, including blocks which are not ores.
Each recipe has a conservative `ore_miner` annotation.  `safe_candidate=true`
means every source component is spelled `OREDICT:ore*`; `false` lists every
direct block or other dictionary key requiring manual review.  This is a
candidate filter, not a claim that a runtime dictionary entry is a GT ore.
Direct blocks that happen to be ore blocks are intentionally still marked
unverified because the importer has no Forge/GregTech registry.  A controller
MUST NOT hide or reinterpret a recipe solely to make it fit an ore-miner
workflow.

The current recipes with at least one non-canonical (and therefore
ore-miner-unverified) source component are:

```text
AncientDebrisMeteor  BeeHive             BotGaia
EFRAmethyst          ElvenGateway         FallingSandsMeteor
HoneyWax             Marimorphosis        Netherite
RainbowCaelestis     RainbowGlassMeteor  SkyStoneMeteor
SoulInducedMeteor    SuperGTStones       T1RocketStones
T2RocketStones       T3RocketStones       T4RocketStones
T5RocketStones       T6RocketStones       T7RocketStones
T8RocketStones       TnTMeteor            VanillaOresMeteor
WarpTaintMeteor      Water
```

Examples include bee hives, honey, sand, rocket-world stone, glass, TNT,
water/ice, Botania blocks, and soul sand.  They remain in `recipes` with their
weights and are not converted into fabricated ore IDs.

## Blood Magic ritual facts and formulas

The following behavior is from the pinned Blood Magic implementation, not an
assumption made by the importer:

- `RitualEffectSummonMeteor` checks the owner's current LP against the
  recipe's meteor cost before consuming the focus.  On success it drains up
to 1000 AR from each reagent present in the master ritual stone, decrements
  one focus item, spawns the projectile at Y=257, marks the ritual inactive,
  and debits the meteor LP.  The 100,000 LP activation cost is charged earlier
  by `TEMasterStone.activateRitual`, after ritual start succeeds.  Thus a
  safe controller reserve is activation LP + recipe LP + its own configured
  reserve; reagent effects add no LP.
- Master-ritual redstone is a run gate, not an activation pulse: while
  `getBlockPowerInput(...) > 0`, a running ritual is stopped with the REDSTONE
  break method and no effect is performed.  When power returns to zero,
  running resumes.  Activation still requires the owner-bound activation
  crystal and a valid ritual structure.
- For a meteor with base radius `r`, supplied reagent effects use
  `max(1, r + largest_positive_radius_change + largest_negative_radius_change)`.
  The default `orbisTerrae` file sets `radiusChange=2` and
  `fillerChanceChange=20`; `terrae` sets both corresponding values to 1 and
  10.  Only the largest positive and largest negative changes are selected.
- If base filler chance is zero, reagent changes do not add filler.  Otherwise
  raw filler changes are applied first; the integer change branch is
  `100 * (chance + change) / (100 + change)`, clamped to 0..100, with the
  positive branch taking precedence when both a positive and negative integer
  change are present.  A reagent with a configured filler list can replace
  the original filler list after reagent-gated components are filtered.

The summon has no fixed server-side sleep or timer.  After a successful ritual,
`EntityMeteor` is spawned at `(x + 0.5, 257, z + 0.5)` with `motionY = -1.0`.
`EnergyBlastProjectile.onUpdate` advances and collision-tests one block per
game tick, so terrain at impact height `y` is reached after approximately
`257 - y` ticks (about `(257-y)/20` seconds), subject to entity collision and
the exact first-tick trace.  The projectile's inherited `maxTicksInAir` is 600
ticks; if it finds no collision before then it is discarded.  On collision,
the meteor impact is performed immediately and the projectile is killed.  A
controller wait is therefore an operational timeout, not a guaranteed summon
delay or yield guarantee.
- Impact places blocks only at air positions in the integer spherical lattice
  `i*i + j*j + k*k < (radius + 0.5)^2`.  Its explosion, if enabled by the
  Blood Magic configuration and reagent effects, has strength `4 * radius`.
  Therefore neither a fixed block count nor guaranteed ore yield can be
  derived from a recipe; world occupancy, radius modifiers, filler chance,
  and independent weighted choices all matter.

Primary source paths for these facts are:

```text
Blood Magic src/main/java/.../Meteor.java
Blood Magic src/main/java/.../MeteorComponent.java
Blood Magic src/main/java/.../MeteorReagentRegistry.java
Blood Magic src/main/java/.../RitualEffectSummonMeteor.java
Blood Magic src/main/java/.../TEMasterStone.java
Blood Magic raw/meteors/README
Blood Magic raw/meteor-reagents/README
Blood Magic raw/meteor-reagents/orbisTerrae.json
OpenComputers src/main/scala/li/cil/oc/integration/vanilla/ConverterItemStack.scala
```

The source paths above are relative to the pinned clones and are included to
make formula or lifecycle changes auditable when regenerating the snapshot.
