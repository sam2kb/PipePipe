# PipePipe — Subscriptions-Only Restricted Mode

This fork turns PipePipe into an administratively locked-down video client. While
**Restricted Mode** is active, only videos whose channel is already in PipePipe's own
subscription list can be opened or played, service-wide search and every discovery surface are
gone, and the subscription list is read-only.

Restricted Mode is switched on and off **only** by the presence of a filesystem sentinel that an
administrator creates or removes over ADB. There is deliberately no in-app toggle and no
preference that can create or remove it.

* base: PipePipe `v5.4.0` (`main` @ `7349b0f`), client submodule `PipePipeClient` @ `c2a166f`
* branch: `feature/subscriptions-only-restricted-mode`
* new client package: `org.schabi.newpipe.restricted`
* no changes to `PipePipeExtractor`, no database schema change

---

## 1. The sentinel file

| | |
|---|---|
| file name | `.subscriptions_only.lock` |
| directory | `Context.getExternalFilesDir(null)` (app-specific external storage) |
| debug build | `/sdcard/Android/data/InfinityLoop1309.NewPipeEnhanced.debug/files/.subscriptions_only.lock` |
| release build | `/sdcard/Android/data/InfinityLoop1309.NewPipeEnhanced/files/.subscriptions_only.lock` |
| application ID | `InfinityLoop1309.NewPipeEnhanced` (release), `…NewPipeEnhanced.debug` (debug) |

`RestrictedModeManager.isEnabled()` stats that file on **every** authorization decision; nothing is
memoised, so a change made while the app is running is honoured immediately. The app creates the
directory during `App.onCreate()` so ADB always has a target.

### Exact ADB workflow

Replace `<ID>` with the application ID of the build you installed
(`InfinityLoop1309.NewPipeEnhanced.debug` for the debug APK, `InfinityLoop1309.NewPipeEnhanced` for
the release APK).

```bash
ID=InfinityLoop1309.NewPipeEnhanced.debug
LOCK=/sdcard/Android/data/$ID/files/.subscriptions_only.lock

# --- 1. subscribe to every approved channel while Restricted Mode is OFF -------------
#        (normal PipePipe UI; the sentinel must not exist yet)

# --- 2. turn Restricted Mode ON -------------------------------------------------------
adb shell touch $LOCK
adb shell am force-stop $ID

# --- 3. (later) edit the approved channel list ----------------------------------------
adb shell rm -f $LOCK
adb shell am force-stop $ID
#        … change subscriptions in the PipePipe UI, then:
adb shell touch $LOCK
adb shell am force-stop $ID

# --- check the current state ----------------------------------------------------------
adb shell ls -la /sdcard/Android/data/$ID/files/
```

A restart is not strictly required for enforcement (the sentinel is re-read constantly), but it is
the documented procedure: it rebuilds the tabs, menus and drawer from the new state.

### If ADB cannot write into the app-specific directory

Some Android builds restrict the `shell` user's access to `/sdcard/Android/data`. The app-specific
external directory is still the right primary location, because it is the only one that satisfies
all three requirements at once (ADB can create/remove the file, PipePipe can read it **without any
storage permission**, and an ordinary app cannot modify it). If `adb shell touch` is refused on
your build, use one of these instead:

```bash
# debuggable builds (the debug APK): the app's own uid creates the file
adb shell run-as $ID sh -c 'touch files/.subscriptions_only.lock'     # relative to /data/data/$ID
adb shell run-as $ID sh -c 'rm -f files/.subscriptions_only.lock'

# root / device-owner builds
adb root && adb shell touch /data/data/$ID/files/.subscriptions_only.lock
adb root && adb shell rm -f /data/data/$ID/files/.subscriptions_only.lock
```

Those fallbacks use the app's **private** files directory
(`/data/data/<ID>/files/.subscriptions_only.lock`). `RestrictedModeManager` checks both locations
and treats "any sentinel present" as Restricted Mode ON, so all variants toggle the same mode and a
leftover fallback sentinel cannot silently unlock the app. See
[§7 Limitations](#7-known-limitations-and-bypasses) for the consequences.

---

## 1b. The comments switch (second sentinel)

Comments can be switched off independently of Restricted Mode, through a second sentinel that
follows exactly the same rules:

```
<sdcard>/Android/data/<applicationId>/files/.comments_off.lock
/data/data/<applicationId>/files/.comments_off.lock          (fallback)
```

While it exists, a video page **does not offer a Comments tab at all**: the tab is not built and the
comments fragment never asks the service for comments, so the replies of a comment (only reachable
from the comment list) cannot be opened either. Playback, subscriptions, search and every other
surface are untouched, so the switch can be used on its own or together with Restricted Mode.

```bash
ID=InfinityLoop1309.NewPipeEnhanced.debug
LOCK=/sdcard/Android/data/$ID/files/.comments_off.lock

# --- switch comments off ---------------------------------------------------
adb shell touch $LOCK
adb shell am force-stop $ID

# --- switch comments on again ----------------------------------------------
adb shell rm -f $LOCK
adb shell am force-stop $ID

# --- fallback for a secondary profile / when ADB cannot write the app dir ---
#     debuggable builds (the debug APK) only: the app's own uid creates the file
adb shell run-as $ID --user 13 sh -c 'touch files/.comments_off.lock'
adb shell run-as $ID --user 13 sh -c 'rm -f files/.comments_off.lock'
```

Like the Restricted Mode sentinel it is re-read from the filesystem on every decision and never
memoised; the restart is only there so that the tabs and menus that were already built are rebuilt.

## 2. What Restricted Mode enforces

```
Restricted Mode OFF  ->  completely normal PipePipe
Restricted Mode ON   ->  a video/channel is allowed only if (serviceId, canonical channel URL)
                         is a row of PipePipe's own subscriptions table right now
```

Identity is always `(serviceId, canonical channel URL)`, never the channel name.
`RestrictedChannelUrl` is the single canonicalisation function (used for the database lookup, for
the queue filter and for the channel page check), so the same channel cannot be authorized through
one URL shape and denied through another.

Everything fails **closed**: a missing uploader URL, a URL that is not recognisably a channel, an
unavailable database, an unexpected deep link — all deny.

| Surface | Restricted Mode behaviour |
|---|---|
| Main/global search | icon hidden, `NavigationHelper.openSearchFragment/openSearch` refuse, `SearchFragment` refuses to run, `ExtractorHelper.searchFor` refuses, `MainActivity` search intents are bounced back |
| Search suggestions | remote suggestions return empty |
| Trending / Popular / other kiosks | tabs removed, drawer entries not built, `NavigationHelper.openKioskFragment` refuses, `KioskFragment.loadResult` errors instead of loading |
| Related videos | tab dropped, side list dropped, "append related to playlist" disabled |
| Autoplay / auto-queue | auto-queue controller disabled (autoplay of the *next already queued, authorized* item still works) |
| Downloads | download action, download library and the download choice in the share dialog disabled (the library cannot be authorized per channel and opens its files in an external player) |
| Channel-local search | allowed, but only for an already authorized (subscribed) channel |
| Feed search, subscription-list filter | unaffected (local only, never reaches the extractor) |
| Subscriptions | read-only: subscribe/unsubscribe hidden and refused at the manager; the import/export actions of the Subscriptions tab refuse (that row also carries the local filter box, which keeps working); the whole-database restore is disabled; the import service refuses to start |
| Channel pages | only subscribed channels open (checked at navigation, on the resolved `ChannelInfo`, in list adapters, when the channel content loads, and for channel tabs) |
| Pinned "Channel" main tabs | removed from the tab bar when the channel is not subscribed |
| Video pages | authorized on the resolved `StreamInfo`; otherwise an error page + `This video is not from a subscribed channel.` |
| Queues (local, remote, feed, history, restored) | each entry is authorized individually on its own uploader channel; entries without one are dropped |
| Main / popup / background player, enqueue, enqueue-next, shuffle | queue is filtered before it is serialized into the player intent, again when the player receives it, and each item is authorized twice when its media source is resolved: once on the queue entry's own metadata and once on the `StreamInfo` that was actually resolved |
| Notification / media-button / media-session resume, Android Auto | same single player funnel, therefore the same check |
| Open in browser / external player / Kodi / Share | buttons hidden in the player and the item menus, click handlers and helpers refuse |
| Download | authorized on the resolved stream before the download dialog opens |
| History, bookmarks, local playlists | still visible; playback of unauthorized entries fails as above |

---

## 3. Where authorization is enforced (security path)

The lower layers are the security boundary; hiding a button is only convenience. Every layer is
independent, so a bug or a missed call site in one is caught by the next.

```
service-wide search   NavigationHelper.openSearchFragment / openChannelSearchFragment / openSearch
                      -> SearchFragment.onViewCreated + SearchFragment.search()
                      -> ExtractorHelper.searchFor / getMoreSearchItems / suggestionsFor   [data layer]

channel navigation    NavigationHelper.openChannelFragment (both overloads)
                      -> BaseListFragment item click
                      -> ChannelFragment.handleResult(ChannelInfo)                      [post-load check]
                      -> ChannelVideosFragment.loadResult()      [also covers a pinned Channel tab]
                         (a ChannelTabFragment is only ever created from an authorized channel page,
                          and its URL is the channel URL plus a service-specific tab suffix, so it
                          is not authorized on its own)

direct URLs/intents   RouterActivity -> MainActivity.handleIntent -> the guarded navigation helpers
                      -> VideoDetailFragment stream authorization                        [authoritative]

video detail          VideoDetailFragment.runWorker(): the resolved StreamInfo is authorized
                      before handleResult()/showContent()/autoplay                       [authoritative]

queues                PlayQueue.appendInternal()  — nothing unauthorized can enter a queue
                      NavigationHelper.getPlayerIntent/openVideoDetail — filtered before serialization
                      PlayerStartController.handleIntent — filtered again for every service intent

main player           } MediaSourceManager.getLoadedMediaSource(): (1) the uploader channel of the
popup player          } queue entry and (2) the uploader channel of the StreamInfo that was actually
background player     } resolved are both authorized, and a rejection becomes a permanent source
autoplay              } error. This is the single funnel through which every playable item must
notification resume   } pass, including preloaded neighbours, lazily fetched queue pages and
media-session         } media-session selections. A queue entry whose metadata claims an approved
                      } channel but resolves to a video from another one is therefore still denied.
                      }                                                                  [authoritative]

subscriptions         SubscriptionManager.insertSubscription / insertAll / upsertAll / delete*(),
                      ChannelVideosFragment subscribe button, SubscriptionsImportService,
                      BackupSettingsFragment import/restore/clear
```

`RestrictedModeException` marks a refusal in logs and error reports.

---

## 4. Building

The toolchain is disposable and lives in Docker; nothing is installed on the host.

```bash
# one-time: Android SDK + JDK 25 image (~2 GB)
docker build -t pipepipe-android-build -f tools/restricted-mode/Dockerfile tools/restricted-mode

# debug APKs (signed with the Android debug key, installable as-is)
tools/restricted-mode/build.sh :app:assembleDebug

# unit tests
tools/restricted-mode/build.sh :app:testDebugUnitTest

# release APKs signed with a throwaway key generated into .build/
tools/restricted-mode/build-release.sh
```

Outputs land in `PipePipeClient/app/build/outputs/apk/<variant>/`, one file per ABI
(`PipePipe_5.4.0-<abi>-<variant>.apk`).

Install and check:

```bash
adb install -r PipePipeClient/app/build/outputs/apk/debug/PipePipe_5.4.0-arm64-v8a-debug.apk
adb shell pm list packages | grep NewPipeEnhanced
```

---

## 5. Tests performed

`:app:testDebugUnitTest` — 23 tests, all passing:

* `RestrictedChannelUrlTest` covers the canonicalisation the authorization rests on: the stored
  `/channel/UC…` URL is its own key and is idempotent, `m.`/`www.`/trailing-slash/`/videos` variants
  collapse onto it, `@handle`/`/c/`/`/user/` never equal a channel-id key, two channels or two
  services never share a key, and every non-channel input (video, playlist, bare id, empty,
  malformed, non-HTTP, look-alike host, `..` path) has **no** key — the fail-closed case.
* `RestrictedQueueFilterTest` covers the queue decision table: a subscribed uploader is allowed,
  anything else denied, a missing or non-channel uploader denied, an empty allowlist denies
  everything, the uploader *name* is never identity, and a mixed queue keeps exactly its subscribed
  entries.

The first device test also found a crash on launch with Restricted Mode on and an **empty
subscriptions database** (an install locked before anything was subscribed); it is fixed.

Not verified on-device: Android Auto, casting, and switching users while a queue is playing.

## 6. Manual verification procedure

Each block is run once with the sentinel absent (**OFF**) and once present (**ON**).

* **OFF** — stock behaviour: global search, adding subscriptions, pasted/shared URLs, Trending,
  Related Videos, and main/popup/background playback with autoplay all work.
* **ON, subscribed channel** — channel page, feed, channel videos, all three player types and
  autoplay (between approved entries) work; channel-local search works.
* **ON, empty database** — the app opens on the empty Subscriptions screen without an error.
* **ON, non-subscribed content is refused** — direct channel and video URLs, share intents, history
  entries, bookmarks, playlist items, queue entries, popup/background playback, notification
  resume, autoplay/enqueue, and pinned channel tabs.
* **ON, search** — no search icon, `KEY_OPEN_SEARCH` and shared text report that search is disabled,
  no Trending entry in the drawer.
* **ON, subscriptions are read-only** — no subscribe button, import/export reports the read-only
  message, the import service refuses direct `am startservice` calls.
* **ON, no downloads or hand-off** — no Downloads entry or download control, no share/open-in-
  browser/play-with-Kodi actions, import/restore/clear disabled in Settings.
* **Sentinel** — absent → unrestricted; created → restricted after a restart; removed → free again.

---

## 7. Known limitations and bypasses

These are the results of the implementation audit. They are deliberate trade-offs or residual
risks, not oversights.

1. **ADB is administrator access.** Anybody who can run `adb shell` on the device can remove the
   sentinel, and on a debuggable build can also read the database. That matches the threat model in
   the task: ADB/root/device-owner access *is* administrator access. Install the **release** APK for
   a deployment, so the app is not debuggable.
2. **The sentinel directory is app-specific external storage.** It is writable by ADB (by design)
   and not by ordinary apps on Android 10+, but a rooted device or a device owner can change it.
   The fallback sentinel in the app's private directory is stronger, but on a release build it is
   only reachable with root/`run-as`.
3. **`getExternalFilesDir(null) == null` does not disable the check.** The private-directory
   sentinel is still consulted, so an unavailable external volume cannot silently unlock a device
   that was locked through the `run-as`/root path. If neither sentinel exists, the mode is off —
   which is the documented OFF state.
4. **A video whose uploader URL YouTube exposes only as `@handle`/`/c/`/`/user/`, while the
   subscription row stores `/channel/UC…`, is denied.** The two forms cannot be mapped onto each
   other locally without a network lookup, and the mode fails closed. In practice the extractor
   returns `/channel/UC…` for video items; the affected case is a channel that was subscribed from
   a legacy URL shape. Remedy: subscribe to the channel from its `/channel/UC…` page.
5. **Items without an uploader URL are dropped from queues**, as the design requires. In practice
   this is rare rather than common: the extractor fills the uploader URL for channel, playlist,
   search and RSS-feed items, and `SparseItemUtil.fetchItemInfoIfSparse()` already resolves an item
   whose metadata is sparse into a full `StreamInfo` before the queue is built for the item-menu
   actions. The residual case is a genuinely sparse item inside a bulk queue ("play all"), which is
   dropped instead of played.
6. **Channel pages are authorized by URL, not by content.** A subscribed channel's page may still
   list videos from other channels (collaborations, featured channels); those are denied at
   playback time, not removed from the list.
7. **Streams already playing are not interrupted when the sentinel appears.** The check runs when a
   media source is resolved, so the item that is already playing finishes and the next one is
   denied. The documented administration procedure (restart the app) removes even that window.
8. **Restricted Mode with an empty subscription list makes the app show nothing playable.** That is
   the intended fail-closed result of locking a device before subscribing to anything; the fix is
   to unlock, subscribe, and lock again.
9. **Downloads are disabled entirely while restricted** (action, library and the share-dialog
   choice). Offline playback of approved videos is therefore unavailable until the sentinel is
   removed. This is deliberate: the download records carry no channel identity that could be
   authorized, and the download library opens its files in an external player.
10. **Whole-database restore (`import_data`) is disabled while restricted**, because it replaces the
   subscriptions table without going through the DAO. Restoring a backup is an administrator
   action: remove the sentinel first.
11. **`MediaButtonReceiver` is an exported receiver** that forwards media-button intents to the
   player service. It cannot inject a queue (the queue travels through an in-process
   `SerializedCache` key), and everything it can reach is re-authorized in the player.
12. **The long-press "Unsubscribe" entries in the subscriptions lists are still shown**, but the
   mutation is refused by `SubscriptionManager` with `Subscriptions are read-only in Restricted
   Mode.` Removing the entries from those two context menus as well would be cosmetic; the write
   guard is the boundary.
13. **The import/export row in the Subscriptions tab stays visible** (collapsed by default) and its
    actions report that subscriptions are read-only. It is kept on purpose: the same view carries
    the local filter search box, which the design keeps available, and the row is referenced from
    several lifecycle callbacks. The import itself is refused by the UI, by `NavigationHelper`, by
    the import service and by `SubscriptionManager`.
14. **Notifications for an approved channel are unaffected**, and tapping one opens the channel page
    through the same guard.
15. **A service whose `StreamInfo` carries no uploader URL at all is denied**, even for a
    subscribed channel, because the resolved-stream check fails closed. YouTube always exposes one
    (`YoutubeStreamExtractor` throws instead of returning an empty value), so this affects other
    services only.
16. **The mode does not sandbox the rest of Android.** It stops PipePipe from being a route to
    unauthorized content; it does not stop a browser, another video app or a second copy of
    PipePipe installed by the user.

---

## 8. Files changed

New (client):

```
PipePipeClient/app/src/main/java/org/schabi/newpipe/restricted/RestrictedModeManager.kt
PipePipeClient/app/src/main/java/org/schabi/newpipe/restricted/RestrictedChannelAccess.kt
PipePipeClient/app/src/main/java/org/schabi/newpipe/restricted/RestrictedChannelUrl.kt
PipePipeClient/app/src/main/java/org/schabi/newpipe/restricted/RestrictedQueueFilter.kt
PipePipeClient/app/src/main/java/org/schabi/newpipe/restricted/RestrictedModeException.kt
PipePipeClient/app/src/test/java/org/schabi/newpipe/restricted/RestrictedChannelUrlTest.kt
PipePipeClient/app/src/test/java/org/schabi/newpipe/restricted/RestrictedQueueFilterTest.kt
```

Modified (client): `App.java`, `MainActivity.java`, `RouterActivity.java`,
`database/subscription/SubscriptionDAO.kt`, `error/ErrorInfo.kt`, `fragments/MainFragment.java`,
`fragments/detail/VideoDetailFragment.java`, `fragments/list/BaseListFragment.java`,
`fragments/list/channel/ChannelFragment.java`, `fragments/list/channel/ChannelTabFragment.java`,
`fragments/list/channel/ChannelVideosFragment.java`,
`fragments/list/kiosk/KioskFragment.java`, `fragments/list/search/SearchFragment.java`,
`info_list/dialog/InfoItemDialog.java`, `info_list/dialog/StreamDialogDefaultEntry.java`,
`local/subscription/SubscriptionFragment.kt`, `local/subscription/SubscriptionManager.kt`,
`local/subscription/services/SubscriptionsImportService.java`, `player/AutoQueueController.kt`,
`player/PlayerClickController.kt`, `player/PlayerLayoutController.kt`,
`player/PlayerService.java`, `player/PlayerServiceForAuto.java`,
`player/PlayerStartController.kt`, `player/playback/MediaSourceManager.java`,
`player/playqueue/PlayQueue.java`, `settings/BackupSettingsFragment.java`,
`util/ExtractorHelper.java`, `util/NavigationHelper.java`, `res/values/strings.xml`, `app/build.gradle`
(test-only `testOptions`).

New (fork root): `RESTRICTED_MODE.md`,
`tools/restricted-mode/{Dockerfile,build.sh,build-release.sh}`.
