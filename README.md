# KillClock

**Boss kill-time estimator for World of Warcraft 1.12.1 (vanilla / OctoWoW / Turtle-style servers).**

KillClock tells you how long a boss fight has left, so you can save big cooldowns like **Death Wish** for the last 30 seconds and the execute phase. It was made for Warriors, but you can track any cooldown.

---

## Installation

1. Download the addon: on GitHub, click **Code → Download ZIP** (or grab a release if there is one).
2. Unzip it into `World of Warcraft\Interface\AddOns\`.
3. **Rename the folder to `KillClock`.** GitHub names it `KillClock-main` (or `killclock-main`), and WoW won't load an addon whose folder name doesn't match its `.toc` file.
   You should end up with `Interface\AddOns\KillClock\KillClock.toc`.
4. Restart the game. Reloading the UI is not enough for a newly added addon.
5. On the character screen, click **AddOns** and make sure KillClock is checked.
   If it shows *out of date*, tick **Load out of date AddOns**.

---

## Quick start

1. Log in. A small **KillClock** window and a **minimap button** with the Death Wish icon appear.
2. **Shift-click the minimap button** (or type `/kc test`) to start a **test fight**. This is a simulated fight on a fake boss that runs through the whole display: the countdown, the colours, the execute timer, the Death Wish advice and the final 30-second alert. No target is needed.
3. While the test is running, **drag the window** where you want it.
4. **Right-click the minimap button** (or type `/kc`) to open **Settings** and adjust the font sizes, scale and so on.
5. In Settings, tick **Lock window position**. You're ready to raid.

---

## What the window shows

```
Ragnaros  64%                 <- boss name and current HP
Kill in 1:42                  <- estimated time until the boss dies
Execute in 1:10  |  2:05 / 3:47 (own)   <- time until 20% HP | elapsed / expected total (source)
Death Wish: ready - hold 1:12 <- what to do with your cooldown
```

**The "Kill in" colour**
- Green: more than a minute left
- Yellow: getting close (alert time + 30 seconds)
- Red: inside the final window (30 seconds by default), so pop your cooldowns

**The cooldown line**

| Message | Meaning |
|---|---|
| `use NOW, back in time for the end` | The fight is long enough to use it now **and** have it back for the last 30 seconds. |
| `ready - hold 1:12` | Save it. It'll be time in 1:12. |
| `USE NOW` | You are in the final window. |
| `CD 0:45` | On cooldown, but it will be back before the boss dies. |
| `CD 2:10 (not back before kill)` | On cooldown, and it won't be back in time. |

When the fight reaches its last 30 seconds, a red **">> LAST 30s - DEATH WISH NOW <<"** message flashes on screen with the raid warning sound.

**Source tags** next to the expected total:
- `(own)`: average of your own recorded kills of this boss
- `(BW)`: taken from your BigWigs kill records
- `(test)`: test fight
- `DPS 72%`: how much of the estimate currently comes from live raid DPS (blend mode)

---

## How the estimate works

KillClock combines two sources:

1. **Live HP trend.** Twice a second it reads the boss's HP, from your target or any raid member's target. It fits a line through the last 20 seconds of data and extends it to 0% (kill) and 20% (execute).
2. **Past kill times.** Every kill is recorded automatically, and the average of your last 5 kills gives an expected fight length. If you haven't killed a boss yet with KillClock, it uses **BigWigs Boss Records** when available.

In the default **blend** mode, the estimate mixes the two. **How fast it switches to raid DPS depends on how long the boss usually takes:**

- **Short fights** (45s or less in your data): the live raid DPS counts for half the estimate from the start, and for all of it after about 15 seconds. A past kill time says little about a 40-second fight. What matters is how hard the raid is hitting right now.
- **Long fights** (4 minutes or more): the estimate leans on your past kills at the start, while raid damage is still ramping up, and moves fully to the live trend over the first minute.
- Anything in between is scaled smoothly between the two.

The window shows the current mix next to the expected length, e.g. `2:05 / 3:47 (own, DPS 72%)`. You can change what counts as a short or long fight in Settings.

**Bosses with phases** where they don't lose HP (Ragnaros submerging, Nefarian phase 1, Vaelastrasz, C'Thun…) confuse the live trend. For those, set **Estimate** to `history` in Settings once you have a kill or two recorded.

---

## Minimap button

| Action | Effect |
|---|---|
| Left-click | Show / hide the window (the icon turns grey when hidden) |
| Right-click | Open Settings |
| Shift-click | Start / stop a test fight |
| Drag | Move the button around the minimap |

If you use a minimap button collector (e.g. MinimapButtonBag), the button may end up inside it. It works the same there.

---

## Settings window

Open it with `/kc` or by right-clicking the minimap button. Press **Escape** to close it.

**Display**
- **Kill timer font size**: the big "Kill in" countdown
- **Boss name font size**, **Info lines font size**
- **Window scale**, **Background opacity** (0% = text only, no box)
- **Outlined text**: easier to read over spell effects
- **Lock window position**: stops accidental dragging
- **Hide window** / **Only show during boss fights**
- **Show minimap button**

The window resizes itself to fit the text.

**Timing**
- **Alert at last**: when the final-window alert fires (default 30s)
- **Live trend window**: how many seconds of HP history the live estimate uses. Shorter reacts faster, longer is steadier.
- **Past kills averaged**: how many recent kills make up the expected length
- **Test fight length**: duration of the simulated test fight
- **Cooldown length**: the cooldown of the tracked spell (Death Wish = 3:00)
- **Tracked cooldown**: the spell name, exactly as in your spellbook. Press Enter to apply. Use your client's language, e.g. `Souhait mortel` on a French client.
- **Short fight (trust DPS)** / **Long fight (trust kills)**: fight lengths that set how quickly the blend switches to live raid DPS (defaults 45s and 4:00)
- **Estimate**: `blend` (default), `live` (HP trend only) or `history` (past kills only)
- **BigWigs times**: which BigWigs record to use: `last` kill, `best` kill, `mid` (average of the two) or `off`
- **Play sound on alert**

**Buttons**: *Start test fight*, *Import BigWigs* (copies BigWigs times into KillClock's own history), *Show history*.

---

## BigWigs integration

BigWigs has a **Boss Records** module that saves your best and last kill time for every boss. KillClock reads it automatically, as long as **BigWigs is enabled** in your AddOns list. You don't need BigWigs' Boss Records module switched on for KillClock to read old records. Switch it on if you want BigWigs to keep recording new ones.

- `/kc bw` lists every BigWigs record KillClock can see.
- `/kc import` copies them into KillClock, so you can disable BigWigs afterwards and keep the data.

KillClock's own recorded kills always take priority over BigWigs times.

---

## Slash commands

Everything below can also be done from the Settings window.

| Command | Description |
|---|---|
| `/kc` | Open / close Settings |
| `/kc help` | List all commands in chat |
| `/kc test` | Start / stop a test fight |
| `/kc show`, `/kc hide`, `/kc toggle` | Show / hide the window |
| `/kc lock`, `/kc unlock` | Lock / unlock the window position |
| `/kc fight` | Toggle "only show during boss fights" |
| `/kc minimap` | Show / hide the minimap button |
| `/kc threshold 30` | Alert when this many seconds are left |
| `/kc mode blend\|live\|history` | How the estimate is made |
| `/kc window 20` | Seconds of HP data for the live trend |
| `/kc spell Death Wish` | Which cooldown to track |
| `/kc set 3:45 Ragnaros` | Add a kill time by hand (or target the boss and `/kc set 3:45`) |
| `/kc history` | List your recorded kills (count, average, best) |
| `/kc reset Ragnaros` / `/kc reset all` | Clear history for one boss / everything |
| `/kc bw [last\|best\|mid\|off]` | Show BigWigs records / choose which time to use |
| `/kc import` | Copy BigWigs times into KillClock |
| `/kc track` | Treat your current target as a boss (for bosses the game doesn't flag as one); with no target, clears it |
| `/kc sound` | Toggle the alert sound |

---

## FAQ

**The window doesn't appear in a fight.**
KillClock starts when you are in combat and someone in the raid targets a boss. Check that the window isn't hidden (the minimap icon is grey when it is) and that "Only show during boss fights" is set the way you want. For a boss the game doesn't flag as a boss, target it and type `/kc track`.

**"Kill in" shows `--:--`.**
The live trend needs about 5 seconds of HP data, and the boss has to be losing HP. If you have no past kills of this boss, the first seconds show `--:--`.

**The estimate jumps around on a phased boss.**
Use `/kc mode history` (or Estimate: history in Settings) for that boss.

**Death Wish line is missing.**
The spell name must match your spellbook exactly (including language). Set it under **Tracked cooldown** in Settings.

**Where is my data saved?**
In `WTF\Account\<ACCOUNT>\SavedVariables\KillClock.lua`. It's written when you log out or reload.
