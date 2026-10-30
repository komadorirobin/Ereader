# KOReader patches
KOReader patches, likely not useful for anybody else.

## Automatic installation and updates

Install [Ereader Patch Manager](https://github.com/komadorirobin/ereader-patch-manager.koplugin/releases/latest) to automatically discover, install, and update the numbered patches in this repository. The plugin preserves each patch's enabled or disabled state and creates a backup before replacing an existing file.

## [2-bookorbit-undo-opening.lua](2-bookorbit-undo-opening.lua)

Undo a newly opened, unread book before the first page turn (within 24 hours),
including its provisional BookOrbit reading and the specific Hardcover reading
created for that opening. Existing readings, progress and annotations are not
eligible for reset. Ratings, reviews, metadata and edition links are preserved.

This is a standalone user patch, **not a fork of `bookorbit.koplugin`**. It wraps
the stock plugin's lifecycle and API methods in memory; it neither replaces its
files nor copies its sync engine. It also works when the book was opened from
Bookshelf or SimpleUI because it observes KOReader's reader lifecycle.

### Requirements and use

1. Deploy the [BookOrbit server support](server-support/bookorbit-undo-opening/README.md)
   first: migration `0101_undo_reading_opening`
   and the authenticated `/api/v1/koreader/plugin/openings`, `/commit` and `/undo`
   endpoints. This is separate server work, not something a device patch installs.
2. Keep the official BookOrbit plugin enabled and configured for automatic sync.
   Keep BookOrbit as the only automatic Hardcover writer, using the Hardcover
   sync patch below if the separate Hardcover plugin is installed.
3. Sync patches in Patch Manager, enable this patch if necessary, and restart
   KOReader. Alternatively, install this file in `koreader/patches/` manually.
4. Use **Tools > BookOrbit > Undo accidental opening** while eligible. It is also
   in BookOrbit's menu sheet (2.0) or dashboard menu (1.5.5), and available as the gesture action
   **BookOrbit: undo accidental opening**. It does not add a Bookshelf-only menu.

The client holds automatic uploads for the provisional opening until you turn a
page or explicitly sync that book. A whole-library sweep waits while an opening
is held; sync for other individual books is unaffected. After a successful undo,
the book returns to its previous unread state/history position. KOReader's local
statistics database is not erased, but the accidental time interval is excluded
from future BookOrbit uploads, including full sweeps.

An unsent offline opening can be undone locally. If a request may already have
reached the server, it must be reconciled before local data is reset. A pending
undo can be retried explicitly after reconnecting. If Hardcover is unavailable,
the server keeps the owned reading ID for retry; it never guesses which reading
to delete. Older readings or later edits from another device prevent remote
undo. The server does not create a first-ever Hardcover library entry just for
a provisional opening; normal sync can do that after reading continues.

### Updates and safety

Tested against these stock BookOrbit plugin source sets:

- **1.5.5**: `2855dbb8a39d20bf711f01772e2678ef0625dd63`.
- **2.0.0** (BookOrbit 3.5.0): `c59dd0118fd0d5d0ecbd716d1d7fde2c97f8e2ea`.

Compatibility checks fingerprint the nine source files involved in lifecycle,
queues and API acknowledgement, plus the new menu sheet in 2.0. Each version
must match a complete tested source set; mixing files from supported releases
is not accepted. The version literal is ignored: a version-only bump or changes
outside those files need no patch update. Changes inside them require review and
regression tests; even a harmless edit may conservatively trigger the guard.
Never just regenerate the fingerprints to silence the warning.

The 2.0 adapter adds an undo row to the stock menu sheet without replacing its
layout or other actions. A stale menu cannot undo a different opening or account.
The new quiet manual-sync flow and file-manager reconnect handler retain the
same opening protections. No saved-state migration is required.

The guard runs **before plugin initialization**, before startup uploads can run.
For unknown code with no protected state, ordinary BookOrbit sync still works
but undo is unavailable. If a pending opening or excluded statistics exist,
BookOrbit is paused instead; KOReader and other plugins remain usable. Update
the patch with Patch Manager and restart once compatibility has been verified.

**Do not delete the `bookorbit_openings` setting or disable/remove this patch
without reconciling its state.** Its per-account excluded intervals must survive
plugin updates and sync-state rebuilds to prevent old accidental statistics
being uploaded again. Unreadable state also pauses BookOrbit rather than ignoring
the protection. Against a server without the new endpoints, the client releases
its provisional hold and falls back to ordinary sync; remote undo is unavailable.

Tests run without network, credentials, or user data. The adapter test loads real,
unmodified upstream source and verifies hashes, callable event handlers, menus,
queue completion, upload filtering, offline recovery and compatibility gating:

```sh
luajit tests/bookorbit_undo_state_test.lua
luajit tests/bookorbit_undo_patch_test.lua /path/to/bookorbit.koplugin
```

Run the adapter test separately against each source set above. It also checks
each protected file, mixed-version rejection, the 2.0 menu action and delayed
confirmation, and manual-sync ordering. Storage, transport and drawing widgets
are mocked; physical-device verification is still required after installation.

## [2-hardcover-bookorbit-sync.lua](https://github.com/komadorirobin/Ereader/blob/main/2-hardcover-bookorbit-sync.lua)

Use BookOrbit as the only automatic reading-sync source for Hardcover. Keep
KOReader-to-BookOrbit sync and BookOrbit's Hardcover status/progress sync enabled.
This patch requires the separate `hardcoverapp.koplugin` to remain enabled for
Bookshelf's Hardcover integration.

- Blocks the Hardcover plugin's automatic progress and status sync, including
  existing books with individual tracking enabled and the end-of-book check.
- Preserves Bookshelf's links, edition-ID auto-linking, metadata and ratings.
- Keeps the Hardcover plugin's own linking/edition selection local instead of
  writing the selected edition and current reading status back to Hardcover.
- Shows `Automatic reading sync: BookOrbit` in the Hardcover menu and disables
  its automatic tracking controls. Explicit manual Hardcover status/rating
  actions remain available; use BookOrbit for those too if you want one writer.
- Does not modify saved tracking preferences or remove existing duplicate reads.

Sync patches in Patch Manager, enable this patch if necessary, and restart
KOReader. To restore the old behavior, disable this patch and restart again.
There is no effect when the Hardcover plugin is absent or disabled.

Regression tests (using a local copy of Billiam's plugin, without network or a token):

```sh
luajit tests/hardcover_bookorbit_sync_test.lua /path/to/hardcoverapp.koplugin
```

# [2-custom-reader-header.lua](https://github.com/komadorirobin/Ereader/blob/main/2-custom-reader-header.lua)

Adds a custom header with "Author – Title" in left corner and "Battery % | Clock" in right corner. Needs localization if you're not Swedish. It also comes with a few folder rules which, again, is (likely) not useful for anybody else.

Bookmarked pages use the manga header's notched ribbon, hanging directly from
the screen's top edge instead of from a header band. It uses a dark fill on light
pages and a light fill on dark pages, with a contrasting outline. KOReader's
bookmark state and gestures are unchanged; its native corner icon is suppressed
only while this header is drawn on the reading screen. Removing the bookmark
refreshes the complete ribbon area. The header stays transparent, and its text
leaves room for the ribbon even with larger fonts. This patch works on its own;
the manga header is not required or modified.

**Svenska:** Bokmärkta sidor får manga-headerns bokmärkesband, men hängande direkt
från skärmens överkant. Headern förblir transparent och bandet får kontrast mot
ljusa och mörka sidor. Bokmärkesdata och gester ändras inte.

Both this patch and the manga header below draw only to KOReader's current screen
buffer. Page Scrubber and KOReader's native Page browser use a separate buffer
to generate page thumbnails, even when it has the same dimensions as the screen
and no special `render_mode` is set. Those previews still render the book page
but skip custom header drawing, battery queries and charging-monitor setup.
This avoids calling device power APIs from the thumbnail-rendering subprocess.
Normal reading, folder filters and header settings are unchanged.

First update Ereader Patch Manager to **1.1.2 or newer** and restart KOReader;
that release fixes the crash when enabling/disabling patches or opening details.
If you disabled the header to use Page Scrubber, synchronize the updated patches
in **Ereader Patch Manager > Synchronize patches now**, re-enable the header under
**Repository patches**, then restart KOReader. Synchronization preserves disabled
state, so it will not re-enable the patch for you.

# [2-header-manga.lua](https://github.com/komadorirobin/Ereader/blob/main/2-header-manga.lua)

Same as the above, but smaller font and with "current page/total pages" and "pages left", as well as an added thin line beneath 

Long author/title text is truncated with an ellipsis to fit the space left by the
status information, with a gap between the two blocks. A trailing volume label
(such as `Vol. 5` or `Volume 12`) has priority over the author/title: its measured
width is reserved first, so it remains visible when the title is truncated.
If the whole left-hand area runs out of space, only the status is shown. The white
background and bookmark ribbon are unchanged.

Header regression tests (mocked KOReader APIs, no device required):

```sh
luajit tests/prose_header_test.lua
luajit tests/manga_header_test.lua
luajit tests/header_thumbnail_test.lua
```

The prose tests cover ribbon parity with the manga patch, top-edge positioning,
light/dark contrast and fallback, bookmark removal, native-icon suppression,
text spacing, folder rules and both patch load orders.
The thumbnail tests cover each patch on its own and both load orders, cold and
already-active readers, screen-buffer replacement and return to normal reading.
They use mocked KOReader APIs; physical-device verification is still required.

# [2-footer-margin.lua](https://github.com/komadorirobin/Ereader/blob/main/2-footer-margin.lua)

Makes the manga/comic fill the entire screen beneath the header. Meant to be combined with [2-header-manga.lua](https://github.com/komadorirobin/Ereader/blob/main/2-header-manga.lua). Also meant for screen size 1264 x 1680.

# [2-footer-info-progress.lua](https://github.com/komadorirobin/Ereader/blob/main/2-footer-info-progress.lua)

Custom footer with "Chapter name" in left corner, "Current page/total pages", "Pages left in chapter", "Pages left in book", and "Percentage read" in right corner. Also a thin progress bar beneath.

## [2-bigme-frontlight.lua](2-bigme-frontlight.lua)

**Bigme frontlight compatibility — v0.1.0-beta.3.** Replaces Android-rejected
settings writes with Bigme's verified provider and avoids protected raw-key
reads. The integrated implementation is now device-tested on the matching
`bigme / hibreak / hibreak_eea / mt6877 / Android arm64` firmware profile.
Other profiles remain untouched; marketing names alone do not establish support.

KOReader's ordinary light controls and PowerD callers such as OrbitUI quick
controls use independent cold/warm scales 0–36. Off/on remembers/restores both
levels. The owner confirmed physical operation, restart readback and
bidirectional synchronization with Bigme's panel. This remains a beta:
independent raw-storage readback and every value on every firmware are not
verified. Provider responses alone are never treated as proof of raw persistence.

Loading performs no light command or Android settings write. Existing Android
permission to modify system settings is required; no root, permission grant,
APK/firmware replacement or security-policy change. Only six fixed light keys,
the verified OEM provider and two known hardware commands are used.

Synchronize in Ereader Patch Manager and restart KOReader. Existing disabled
copies remain disabled: verify the replacement is **0.1.0-beta.3** before
re-enabling. Never re-enable old failed backups. Disable all earlier Bigme
access/cold/warm, read-only settings, same-value provider and provider-roundtrip
diagnostics first; keep their logs/recovery files.

If KOReader cannot start, force-stop it and rename the failed patch so the
filename no longer ends in `.lua`. **Do not clear app data.** On any runtime
error, stop adjusting through KOReader, use Bigme's own panel to choose desired
levels, disable the patch and restart. No automatic retry or blind rollback.

Canonical source, release, license, tests and full bilingual instructions:
[koreader-bigme-frontlight Beta 3](https://github.com/komadorirobin/koreader-bigme-frontlight/releases/tag/v0.1.0-beta.3)
([svenska](https://github.com/komadorirobin/koreader-bigme-frontlight/blob/main/README.sv.md)).
This catalogue file is byte-identical to the standalone release; no new OrbitUI
or Patch Manager version is needed.

**Svenska:** Beta 3 ersätter nekade Android-skrivningar med Bigmes egen tjänst och
undviker blockerad råvärdesläsning. Kallt/varmt ljus, av/på med återställning,
återläsning efter omstart och synkning åt båda håll är bekräftade på den exakta
profilen ovan. Inte generellt stöd för alla Bigme-enheter. Rålagringen är inte
separat avläst och betastatus kvarstår.

Synkronisera i Patch Manager och starta om. Kontrollera **0.1.0-beta.3** innan en
tidigare avstängd kopia återaktiveras; återställ inga gamla felkopior. Inaktivera
alla tidigare Bigme-diagnostikpatchar och behåll loggar/återställningsfiler.
Ingen ny OrbitUI- eller Patch Manager-version krävs. Vid fel: använd Bigmes
egen ljusmeny, inaktivera patchen och starta om. Vid startproblem: tvångsavsluta
och byt filändelse i Androids filhanterare. Rensa inte appdata eller inställningar.
