# Libs

Vendored third-party libraries, loaded first by the `.toc` (spec 000 §3).

| Library | Version | Purpose |
|---|---|---|
| LibStub | minor 2 | Library versioning shim everything else depends on |
| CallbackHandler-1.0 | minor 6 | Event dispatch, required by LibDBIcon |
| LibDataBroker-1.1 | minor 3 | The data-object the minimap button is built from |
| LibDBIcon-1.0 | rev 20 | Minimap button (spec 000 file layout, `UI/Minimap.lua`) |

**Vendored, not submoduled.** A 3.3.5a addon is distributed as a folder a player drops into
`Interface/AddOns`, so every dependency has to be in the tree. This is also why the versions
above are pinned by copy rather than by a manifest — there is no package manager in this
ecosystem.

These are the copies shipped with PlayerbotManager on the development machine, chosen because
they are known to work on this exact client build. All four are public-domain or
BSD-style licensed and are redistributable; each carries its own licence header.

**Do not edit these files.** LibStub in particular is version-guarded: an edited copy with an
unchanged minor number will be silently ignored in favour of whichever other addon loaded first,
which produces bugs that appear and disappear depending on the player's addon list. If one needs
updating, replace the whole file and update the table above.
