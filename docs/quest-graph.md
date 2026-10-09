# The quest graph

Everything about building a quest on the **Quest** tab: how steps follow each other, every block and kind, the
cards, dialogues, conditions and testing. For a first walk through, see [first-quest.md](first-quest.md).

## The Quest tab

**Project** > **Quest** shows the quest of the open project.

- **The name at the top** is the quest's name in the journal. **···** beside it lists the project's quests (a
  project can hold several, see [Several quests in one project](#several-quests-in-one-project)).
- **In this quest** opens a window with the quest's NPCs, objects and items and the steps that use them. A click
  jumps there.
- **Quest graph** opens the same quest as the game runs it, block by block. It is the deep view for experienced
  modders; changes made there are kept with the project and used by the build.
- **Jump to** (in a long quest) shows a chapter or a branch.
- **The blocks** on the left, **the graph** in the middle, **the card** of the selected step below it.

## Steps and the order

A quest is a chain of **steps**. It starts at **QUEST STARTS** and runs from top to bottom. The line between two
steps is the order: when a step is done, the quest follows its line to the next one.

Every step has an **output**, the small square at its bottom. A step whose quest can go several ways has one labelled
output per way: a dialogue's endings (**continue**, **repeatable**), a choice's branches, **won** and **lost** of a
game. Until every output leads somewhere, the step says `output not wired`. An output leads to

- the next step below (drag it onto that step),
- a **branch** of its own: drag it into the empty graph, and a new column starts there,
- an **End**, which closes the quest.

A branch is a column of its own to the right, in its own colour. At its end it **rejoins the story** at the step
after the one that split, or ends the quest (**End quest: success**, **End quest: failure**).

**QUEST STARTS** holds the quest's own settings on its card: its section in the journal (**Main quest**, **Side
quest**, **Contract**, **Treasure hunt**), who the player plays (**Plays as**), a suggested **Level** and the journal
entry (**Description**).

**Starts** says when the quest begins:

| Starts | the quest begins |
|---|---|
| Starts automatically | at once, as soon as the game is loaded |
| With a game quest ... | as soon as the chosen quest of the game starts (or right away, when it has started in this save already) |
| After a game quest ... | once the chosen quest of the game is over |

The last two open the **story map** (also under **View** > **Story map**): every quest of the game on a timeline,
by level and region. Click a quest: what it waits for lights up in gold, what waits for it in blue. **Start my quest
with this** or **Start my quest after this** takes it, and the card shows `With: Family Matters` or
`After: Family Matters`. The quest enters the journal and its NPCs the world when it starts.

## The blocks

Six blocks sit on the left. Each makes a step; the **▾** next to the step's kind chooses what exactly it is.

| Block | What it is |
|---|---|
| **Goal** | something the player has to do. The quest waits until it is done, and the journal shows it as an objective |
| **Action** | something the game does by itself. It happens at once and the quest goes on |
| **Choice** | splits the quest into branches |
| **Meanwhile** | a parallel track: steps that run alongside the story |
| **Chapter** | a heading for a part of a long quest, a line across the graph |
| **End** | closes the quest as completed or failed |

### Goals

Grouped by family. The family is the step's colour in the graph.

| Family | Kind | The player has to ... |
|---|---|---|
| People (blue) | Talk | talk to an NPC (a dialogue) |
| | Deliver | hand over an item in a dialogue. A Talk with an option that gives an item becomes a Deliver |
| | Follow | follow an NPC, or lead one who follows |
| Places (green) | Go to | reach a location (a spot with a distance), or leave an area, or come near a character |
| | Wait | let game time pass, or wait until a time of day |
| | Wait until | wait until a fact is set |
| | Wait for | wait for a fight to start or end, the witcher senses, or the player's health to drop to a share |
| Things (yellow) | Loot | search a container (or take certain items out of it) |
| | Examine | examine an object |
| | Use | use an object: switch it on or off, or use an item on it (a key on a gate) |
| | Collect | carry an item. Done as soon as it is in the inventory |
| | Equip | equip one or more items |
| | Read | read a letter or a book |
| | Notice | read a notice on a notice board |
| | Find clues | find clues with the witcher senses. Each clue gets a comment of the player, the journal counts them |
| Fights and games (red) | Kill | kill one or more targets, or a group placed around a point |
| | Defeat | fight until the opponent yields (nobody dies) |
| | Fist fight | win a fist fight. Has an output for a lost fight |
| | Gwent | win a game of gwent against one of the game's decks. Has an output for a lost game |
| | Race | win a race on foot against an NPC along a drawn way |
| Combined | All of these | complete several goals in any order. Done when all are done |

**Either / or** (a Choice) takes several goals, one on each branch: the first one done decides the branch.

### Actions

Grouped by what they touch.

| Group | Kind | What happens |
|---|---|---|
| Player | Says | a subtitled line of the player or an NPC. The game continues |
| | Reward | crowns, experience and items |
| | Item | the player gets or loses an item |
| | Teleport | the player is moved to a point |
| | Travel | the player is moved to another region (with a loading screen) |
| | Play as | the player character switches (Geralt, Ciri) from here on |
| | Portal | a portal to a point, two-way if wanted. Stays open from here on |
| | Draw weapon | the player draws the steel or silver sword, the fists, or sheathes |
| | Block controls | fast travel, meditation, the horse, running, weapons, signs or the map are blocked (or unblocked) |
| People | Hostile | an NPC attacks the player (or turns friendly again) |
| | Immortal | an NPC cannot die, or is only knocked out |
| | Walk to | an NPC walks or runs to a point |
| | Stands | an NPC stands elsewhere from now on, doing one of the game's activities there (sit, kneel, search the ground) |
| | Patrol | an NPC walks a round between points |
| | Journal entry | a page about a character in the journal |
| | Hide object | an NPC or object leaves the world, or comes back |
| | Goes away | an NPC leaves the world |
| | Health | an NPC's or the player's health is set to a share |
| | Attacks | an NPC attacks someone (or stops) |
| | No talking | an NPC cannot be talked to (or can again) |
| | Change look | an NPC gets another appearance |
| | Merchant | trading with an NPC is turned on or off |
| | Boss health bar | the big health bar of an opponent shows or hides |
| World | Show place / Hide place | a location of the project appears or disappears with all its objects |
| | Door | a door opens, closes, locks or unlocks |
| | Lock | an object is locked or unlocked |
| | Switch | a lever, fire or lamp is turned on or off |
| | Lights | candles, torches and lamps are turned on or off |
| | Effect | fire, smoke or glow of an object is turned on or off |
| | Sound | a sound plays |
| | Creatures nearby | the game's own creatures in an area (wolves, drowners) are turned off or back on |
| | Highlight | the witcher senses show an object as a clue or as usable |
| Mood | Fade | the screen fades to black or white, or back |
| | Camera shake | the camera shakes |
| | Weather | the weather changes |
| | Time of day | the time of day is set |
| Screen | Journal note | a paragraph is added to the quest's journal entry |
| | Message | a line shows on screen |
| | Tutorial | a hint box with key icons |
| | Autosave | the game saves |
| | Time passes | "A few hours later" on a black screen |
| Advanced | At random | one of several branches is picked at random |
| | Parallel track / Stop track | a parallel track starts or stops (the same as the Meanwhile block) |
| | Set fact | a fact is set that other steps and options can check |
| | Game function | one of the game's own quest functions, with its fields |

### Choices

| Kind | The quest takes ... |
|---|---|
| Either / or | the branch whose goal the player completes first. The other goals leave the journal |
| At random | one branch, picked at random |
| If | the **yes** or the **no** branch, by a condition (an earlier branch, a fact and more, see [Conditions](#conditions)) |

### Meanwhile, Chapter, End

- **Meanwhile** starts a parallel track: a column of steps that runs alongside the story (a timer, remarks of a
  companion, an ambush now and then). **Stop track** ends it.
- **Chapter** is a heading with a line across the graph. **Jump to** lists the chapters.
- **End** closes the quest right there as **completed** or **failed**. A quest can have several Ends.

## The card

Click a step to open its card below the graph.

- **The top line** is the objective the journal shows for a goal. It is made from the step; type over it to use your
  own.
- **Missing: ...** in red names what the step still needs (`Missing: character`). The step in the graph shows the
  same.
- **The eye** shows the step's spots, ways and circles in the world all the time. Off: only while its card is open.
- **···**: **Play from here**, **Duplicate**, **Remove**. A right click on the step in the graph opens the same menu.
- The fields below depend on the kind. Some steps fold rare options away under **more**.

### NPCs and objects of a step

A step that needs an NPC or an object asks for it (**who**, **what**, **in**). Its list offers

- **Pick in world**: click one of this project's NPCs or objects in the world,
- **Create a new person** (or **container**, **thing**): the Asset Browser opens on that kind; **Place** and a click
  into the world put it down,
- the ones already placed in this project, with a search, and **Go to** to fly to the chosen one.

In the Asset Browser a green speech mark shows an NPC that can speak in a dialogue (the mouth moves with the lines),
a red one an NPC that stays silent.

NPCs and objects belong to a **location** of the project (**Places** tab). A location's objects appear when the quest
starts; **Show place** and **Hide place** bring them in and out of the world later. A location can also hold a
**hide area**, see [world-changes.md](world-changes.md).

### Every time

**Go to**, **Wait until**, **Wait** and **Talk** can repeat: **every time** on the card. The step gets one more output,
**every time**. What follows it runs each time the goal is done, the first time too. The story goes on once, and the
objective is ticked off once.

- **Go to**: each time the player comes into the area again (after leaving it)
- **Wait until**: each time the fact is set (it is removed and waited for again)
- **Wait**: each time the time has passed
- **Talk**: the NPC can be talked to again. Under **when talked to again** go the questions that may be asked again.
  Otherwise the whole dialogue plays again.

**until** says when the repeating stops: with the quest (the default), when a fact is set, or when the story
reaches a step.

## Conditions

**If** and **Wait until** check one condition or several (**+ condition**). Each condition is one of

| Condition | holds when |
|---|---|
| fact | a fact compares to a value (=, !=, >=, >, <=, <) |
| branch | an earlier branch was taken |
| area | the player is in an area (a spot with a distance) |
| item | the player has an item, a number of times (If only; waiting for an item is a Collect) |
| quest state | a quest or objective of the game is running, done or failed |
| time of day | the time is between two times (22:00 to 04:00 runs past midnight) |
| someone there | an NPC or creature is there |
| fight | the player is fighting |

**not** reverses a condition. With several: **all of these** must hold, or **one of them** is enough. An If's **no**
is always the exact reverse of its **yes**, so exactly one of the two branches is taken.

## Dialogues

A Talk's card holds a short dialogue at a glance; **Edit dialogue** (or a double click on the step) opens the
dialogue editor. It is built like the quest, from top to bottom.

**At the top**: **Back** to the quest, the dialogue's name, and the characters in it. The player is always there;
**+ character** adds more NPCs. **+ camera** sets a camera of your own, **+ spot** a position in the dialogue where a
speaker stands.

**The blocks**:

- **Line**: something a character says. Click the name to change the speaker. **Enter** starts the next line, by the
  other speaker.
- **Choice**: options the player picks from. Each option has its own branch of lines.
- **If**: a branch of lines that depends on a condition.

**A line** can have a voice (the speech mark: green with a voice, red without; **Find another** lists the game's voiced
lines and the recordings of voice packs), a **Gesture** (**Find another ...** lists the game's scene animations a
character can play), a **Mood**, a **Camera**, a **Pose**, where the speaker **Looks at**, **Extras** (a sound, a thing
in the hand, a fade) and its **Length**. Without a voice the mouth moves to the text by itself.

**An option** is spoken by the player. It can be shown only **Once**, only under a condition (**+**), and it can do
something under **Effects**:

- **Main option** (yellow, first)
- **Player pays crowns**
- **Persuade with Axii**
- **Player gives an item**: shown only while the player carries it; choosing it takes the item
- **Player receives something**
- **Opens the shop**

**How an option ends**:

| ending | what happens |
|---|---|
| continue dialogue | the lines go on below |
| back to choice | the choice is shown again (for questions) |
| back to previous choice | the choice before is shown again |
| end: continue | the Talk is done, the quest goes on |
| end: repeatable | the dialogue ends, the Talk stays open; the player can come back later |
| end: fail quest | the quest fails |

In the quest graph each ending of the dialogue is an output of the Talk.

## Mouse and keys in the graph

| To | Do |
|---|---|
| add a step after the selected one | click a block |
| put a step in between | drag a block onto a line or a step |
| start a branch | drag an output into the empty graph |
| lead an output elsewhere | drag it onto a step, back onto its own step (on down), or onto an End |
| reorder | drag a step onto a line or another step |
| open a step's card | click it |
| open a dialogue | double click the Talk |
| Play from here, Duplicate, Remove | right click a step, or **···** on its card |
| move around | drag the empty graph; the mouse wheel zooms; a double click on the empty graph shows all of it |
| undo | Ctrl+Z |

## Colours

- goals by family: people blue, places green, things yellow, fights and games red, time grey
- actions teal, choices purple, parallel tracks pink, chapters light grey
- every branch has its own colour: its steps carry it on their left edge, its lines are drawn in it
- ends: completed green, failed red
- a red dot on a step: something is still missing
- **NOW**, **DONE**, **FAILED** on a step: where the player is in the running game

## Testing

- **Build** > **Check** (seconds): plays the quest through with a stand-in player.
  If a branch would get stuck (a goal nobody can reach, a wait for a fact nothing sets, an output that leads
  nowhere), it says where.
- **Build & Play** (the bar, or the Build tab; one to two minutes): the game saves and closes, the quest is built
  into a mod, the game starts again with that save. The quest starts fresh.
- **Play from here** (a step's menu): builds and starts the quest at that step, with the items the steps before
  would have given.
- While the game runs, the graph marks where the player is (**NOW**, **DONE**, **FAILED**).

## Several quests in one project

**···** beside the quest's name lists the project's quests: a click opens one, **+ New quest in this project** makes
another. They share the project's NPCs and locations and are built into the project's one mod. In the game each is a
quest of its own, with its own journal entry, and ends on its own.

Only the open project is in the game. The mods of Conjunction's other projects are moved aside while you build
(into `<game>\_conjunction_parked`), so their NPCs and objects leave the world.
