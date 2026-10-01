# Focus Timer

A small macOS timer that floats above your other windows and shows time passing as something physical: sand running through an hourglass, wax drifting in a lava lamp, water dripping into a glass column, a candle burning down, snow settling in a globe, a dial whose coloured disc shrinks, a sun sinking into the sea, or a tree that grows while you work and blossoms when you are done.

![The eight styles](docs/styles.png)

Everything is drawn and synthesised in code. There are no image or sound files: the sand, water, flame, wax, snow, clockwork, sky and tree are simulated, and each style has its own sound generated live from the simulation (the drip you see is the plink you hear).

It is built around what the research on attention and ADHD keeps finding: time you can *see* beats time you have to read, steady sound beats sound with surprises in it, blocks should be short with breaks built in, and the end of a block should be a check-in rather than an alarm.

## Install

Download `Focus.Timer.app.zip` from the [Releases](../../releases) page, unzip it and move **Focus Timer.app** to your Applications folder.

The app is not notarised by Apple, so the first time you open it macOS will say it cannot verify the developer. Right-click the app and choose **Open**, or go to **System Settings › Privacy & Security** and click **Open Anyway**. This is only needed once.

Requires macOS 14 or later on Apple Silicon.

## Use

- **Click** the timer to start or pause. On the hourglass, **double-click** to turn it over: the time already used becomes the new remaining time.
- **Scroll** over it to set the minutes. **Hold ⌥ and scroll** to resize it.
- **Drag** it anywhere; it remembers its place.
- **Move the mouse over it** and it answers: the candle flame leans toward the cursor, the lava lamp's wax drifts toward it, water ripples where you cross it, the snow scatters, the tree sways in the gust, the dial's reflection follows you, and the hourglass tilts a little.
- **Right-click** (or use the menu-bar icon) for timers (10 to 90 minutes, or custom), a focus-task label, breaks, the gentle warning, the eight **Styles** and their colours, the wooden or metal **Frame** finish, sizes, sound, a chime when done, keep-on-top and open-at-login.

## Built for attention

- **A progress ring on the time badge.** The ring is the time left, so every style reads at a glance, even the lava lamp. The Focus Disc makes the whole object a ring.
- **Breaks that start themselves.** When a block ends you get a soft chime, a "Done" badge and two choices under it: **+5 min** if the work is flowing, or **Break**. Do nothing and the break starts by itself after a few seconds. The break runs in the same style with a cool teal badge, then the timer resets itself and waits, ready for the next block. A long break comes round every fourth block (all adjustable in the **Breaks** menu).
- **A gentle warning, not an alarm.** Five minutes before the end (or 2, 10, or off) the badge warms toward amber and the sound softens. Nothing beeps.
- **Sounds sorted by what they do to attention.** The Sound menu lists the style's own live sound, then **Steady** sounds for focus (white, brown and pink noise, soft hiss) with nothing in them to pull your attention, then **Textured** sounds (ocean, rain, fireplace) that are nicer on a break.
- **Nothing sudden.** No style has a knock, a bell or a tick during a focus block.

## Styles

| Style | What you watch | Live sound |
|---|---|---|
| Sand hourglass | Grains fall and pile up with a true angle of repose; turn it over to reuse the time | Sand on glass, softer as the bed builds |
| Lava lamp | Wax warms, rises, drips down and merges; level marks on the glass | A warm hum |
| Water clock | Drops fall into a glass column: splash crown, jet, rings, rising level | Each drop's plink (or cave drips with an echo) |
| Candle | A jar candle burns down; the flame leans in draughts and follows the cursor | The flame's flutter |
| Snow globe | Snow settles over a cabin in the woods; shake it to stir it up | A winter wind that eases as the snow settles |
| Focus disc | A desk dial whose coloured disc shrinks as the time passes; the second hand steps like a real quartz movement, overshoot and all | A soft clockwork whir |
| Horizon | Through a brass porthole, the sun sinks into the sea over the block: afternoon blue, gold, dusk, first stars. The glitter path on the water is the wave facets catching the sun. On a break, the sun rises again | Evening air: a breeze and distant surf |
| Focus tree | A sapling grows while you work and blossoms when the block ends. Every branch is a damped spring in a gusting wind; petals fall during the break; the next block plants a new tree | Leaves rustling with the gusts |

## Build from source

You need Xcode's command-line tools (`xcode-select --install`).

```bash
./build.sh
```

This compiles the Swift sources, packages **Focus Timer.app** with its icon and installs it to `~/Applications`.

## Licence

MIT. See [LICENSE](LICENSE).
