# OpenComputers programs

OPPM repository with independently installable projects under `packages/`.

| Package | Purpose |
| --- | --- |
| [`meteor`](packages/meteor/README.md) | Blood Magic Mark of the Falling Tower, GT Ore Drilling Plants, ME stock scheduling, and Tier III TUI for GTNH 2.9 development |

## Install

On OpenOS with OPPM and an Internet Card:

```sh
wget https://raw.githubusercontent.com/hxjerry/gtnh-oc-scripts/master/register.lua /tmp/register-meteor.lua
/tmp/register-meteor.lua hxjerry/gtnh-oc-scripts
oppm install meteor
meteor
```

`register.lua` imports this repository's `programs.cfg` into `/etc/oppm.cfg`, preserving existing repositories. Global OpenPrograms registration is not required.

Read the [wiring and safety requirements](packages/meteor/README.md) before starting a cycle.

## Structure

```text
programs.cfg                 OPPM package declarations
register.lua                 OpenOS repository registration
packages/meteor/bin/         Installed executable
packages/meteor/lib/meteor/  Private package modules and immutable catalogue
packages/meteor/tools/       Development-only catalogue importer
packages/meteor/tests/       Host-side behavioural tests; not installed
```

Future projects get their own package directory and manifest entry. Meteor does not install global libraries, change OpenOS startup files, or overwrite its mutable configuration during upgrades.

## Development

```sh
lua5.2 packages/meteor/tests/run.lua
luac5.2 -p packages/meteor/lib/meteor/*.lua packages/meteor/bin/meteor.lua register.lua packages/meteor/tests/*.lua
```

Runtime target: OpenOS Lua 5.2. No third-party Lua dependencies. The tests simulate the OpenComputers component boundary; they do not claim Minecraft hardware certification.
