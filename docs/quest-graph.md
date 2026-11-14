# The quest graph

Every block, card and dialogue option of the **Quest** tab. A first walk through: [first-quest.md](first-quest.md).

## The Quest tab

- **The name at the top** is the quest's name in the journal. **···** beside it lists the project's quests, see
  [Several quests in one project](#several-quests-in-one-project).
- **In this quest** lists the quest's NPCs, objects and items and the steps that use them.
- **Quest graph** shows the quest block by block, as the game runs it. Changes made there go into the build.
- **Jump to** shows a chapter or a branch of a long quest.

## Steps and the order

A quest runs from **QUEST STARTS** down. When a step is done, the quest follows its line to the next one.

A step's **output** is the small square at its bottom. A step that can go several ways has one output per way: a
dialogue's endings, a choice's branches, **won** and **lost** of a game. An output leads to

- the next step (drag it onto that step),
- a **branch** of its own (drag it into the empty graph),
- an **End**.

A branch is a column of its own, in its own colour. At its end it rejoins the story after the step that split, or
ends the quest.

**QUEST STARTS** has the journal section (**Main quest**, **Side quest**, **Contract**, **Treasure hunt**), **Plays
as**, a suggested **Level**, the journal entry (**Description**) and when the quest starts:

| Starts | the quest begins |
|---|---|
| Starts automatically | as soon as the game is loaded |
| With a game quest ... | as soon as that quest of the game starts (at once when it has started already) |
| After a game quest ... | once that quest of the game is over |

The last two open the **story map** (also **View** > **Story map**): every quest of the game by level and region.
Click a quest to see what its prerequisites are: they are highlighted in gold, quests that depend on it are highlighted in blue. **Start my quest with this** or **Start my quest after this**
takes it.

## The blocks

The **▾** beside a step's kind chooses what it is.

| Block | What it is |
|---|---|
| **Goal** | something the player has to do. The journal shows it as an objective |
| **Action** | something the game does. The quest goes on at once |
| **Choice** | branches |
| **Meanwhile** | a track alongside the story |
| **Chapter** | a heading for a part of a long quest |
| **End** | completed or failed |

### Goals

The family is the step's colour in the graph.

| Family | Kind | The player has to ... |
|---|---|---|
| People (blue) | Talk | talk to an NPC |
| | Deliver | hand over an item in a dialogue (a Talk with an option that gives an item) |
| | Follow | follow an NPC, or lead one who follows |
| Places (green) | Go to | reach a spot, leave an area, come near someone or something, or look at it for some seconds |
| | Wait | let game time pass, or wait until a time of day |
| | Wait until | wait until a fact is set |
| | Wait for | wait for a fight to start or end, the witcher senses, or the player's health to drop to a share |
| Things (yellow) | Loot | search a container (or take certain items out of it) |
| | Examine | examine an object |
| | Use | switch an object on or off, or use an item on it (a key on a gate) |
| | Collect | carry an item |
| | Equip | equip one or more items |
| | Read | read a letter or a book |
| | Notice | read a notice on a notice board |
| | Find clues | find clues with the witcher senses. The journal counts them |
| Fights and games (red) | Kill | kill one or more targets, or a group around a point |
| | Defeat | fight until the opponent yields |
| | Fist fight | win a fist fight. Has an output for a lost fight |
| | Gwent | win a game of gwent against one of the game's decks. Has an output for a lost game |
| | Race | win a race on foot against an NPC along a drawn way |
| Combined | All of these | complete several goals in any order |

### Actions

| Group | Kind | What happens |
|---|---|---|
| Player | Says | a subtitled line of the player or an NPC. The game continues |
| | Reward | crowns, experience and items |
| | Item | the player gets or loses an item |
| | Teleport | the player is moved to a point |
| | Travel | the player is moved to another region |
| | Play as | Geralt or Ciri from here on |
| | Portal | a portal to a point, two-way if wanted |
| | Draw weapon | the steel or silver sword, the fists, or sheathed |
| | Block controls | fast travel, meditation, the horse, running, weapons, signs or the map blocked (or unblocked) |
| People | Hostile | an NPC attacks the player (or turns friendly again) |
| | Immortal | an NPC cannot die, or is only knocked out |
| | Walk to | an NPC walks or runs to a point |
| | Stands | an NPC stands elsewhere from now on, doing one of the game's activities (sit, kneel, search the ground) |
| | Patrol | an NPC walks a round between points |
| | Journal entry | a page about a character in the journal |
| | Hide object | an NPC or object leaves the world, or comes back |
| | Goes away | an NPC leaves the world |
| | Health | an NPC's or the player's health is set to a share |
| | Attacks | an NPC attacks someone (or stops) |
| | No talking | an NPC cannot be talked to (or can again) |
| | Change look | an NPC gets another appearance |
| | Merchant | trading with an NPC on or off |
| | Boss health bar | the big health bar of an opponent shows or hides |
| World | Show place / Hide place | a location of the project appears or disappears |
| | Door | a door opens, closes, locks or unlocks |
| | Lock | an object is locked or unlocked |
| | Switch | a lever, fire or lamp on or off |
| | Lights | candles, torches and lamps on or off |
| | Effect | fire, smoke or glow of an object on or off |
| | Clue (senses) | a clue for the witcher senses shows or hides |
| | Part on/off | a part of a thing on or off, for example what the player can use or talk to |
| | Look of a thing | a thing gets another look, for example a burnt house |
| | Move a thing | a thing plays one of its own moves, for example a gate goes up |
| | Sound | a sound plays |
| | Creatures nearby | the game's own creatures in an area off or back on |
| | Highlight | the witcher senses show an object as a clue or as usable |
| Mood | Fade | the screen fades to black or white, or back |
| | Camera shake | the camera shakes |
| | Weather | the weather changes |
| | Time of day | the time of day is set |
| Screen | Journal note | a paragraph in the quest's journal entry |
| | Message | a line on screen |
| | Tutorial | a hint box with key icons |
| | Autosave | the game saves |
| | Time passes | "A few hours later" on a black screen |
| Advanced | At random | one of several branches at random |
| | Parallel track / Stop track | a parallel track starts or stops |
| | Set fact | a fact other steps and options can check |
| | Game function | one of the game's own quest functions |

### Choices

| Kind | The quest takes ... |
|---|---|
| Either / or | the branch whose goal the player completes first |
| At random | one branch at random |
| If | the **yes** or the **no** branch, by a [condition](#conditions) |

### Meanwhile, Chapter, End

- **Meanwhile** runs a column of steps alongside the story (a timer, remarks of a companion). **Stop track** ends it.
- **Chapter** is a heading across the graph. **Jump to** lists the chapters.
- **End** closes the quest as **completed** or **failed**. A quest can have several Ends.

## The card

- **The top line** is the objective the journal shows. Type over it for your own.
- **Missing: ...** in red names what the step still needs.
- **The eye** shows the step's spots and ways in the world all the time, else only while its card is open.
- **···**: **Play from here**, **Duplicate**, **Remove**. A right click on the step opens the same menu.
- Rare options are under **more**.

### NPCs and objects of a step

**who**, **what** and **in** offer:

- **Pick in world**: one of this project's NPCs or objects. Door, Lights, Effect, Hide object, Containers,
  Highlight, Map pin, Clue, Part, Look of a thing and Move a thing also take a thing the game placed: a candle in an
  inn, a door of the city. So do Loot (a chest of the game), Examine (a clue of the game) and Use (a lever, a gate).
  **Show what fits (30 m)** marks everything within 30 m the step can use. A thing with more than one action (a
  chest: loot it, unlock it) gets the line **by** on Use and Examine: the action the player has to do.
- **Create a new person** (or **container**, **thing**): the Asset Browser on that kind.
- the ones already placed in this project, and **Go to** to fly there.

NPCs and objects belong to a **location** (**Places** tab). Its objects appear when the quest starts; **Show place**
and **Hide place** change that later. A location can also hold a **hide area**, see
[world-changes.md](world-changes.md).

### Every time

**Go to**, **Wait until**, **Wait** and **Talk** can repeat: **every time** on the card gives the step an output
**every time**. What follows it runs each time, the first time too. The story goes on once.

- **Go to**: each time the player comes into the area again
- **Wait until**: each time the fact is set
- **Wait**: each time the time has passed
- **Talk**: the questions under **when talked to again** can be asked again, else the whole dialogue plays again

**until** ends the repeating: with the quest, when a fact is set, or when the story reaches a step.

## Conditions

**If** and **Wait until** check one condition or several (**+ condition**):

| Condition | holds when |
|---|---|
| fact | a fact compares to a value (=, !=, >=, >, <=, <) |
| branch | an earlier branch was taken |
| area | the player is in an area |
| item | the player has an item, a number of times (If only) |
| quest state | a quest or objective of the game is running, done or failed |
| time of day | the time is between two times (22:00 to 04:00 runs past midnight) |
| someone there | an NPC or creature is there |
| fight | the player is fighting |

**not** reverses a condition. With several: **all of these** must hold, or **one of them** is enough.

## Dialogues

**Edit dialogue** (or a double click on the Talk) opens the dialogue editor.

**At the top**: **Back**, the dialogue's name and its characters. **+ character** adds NPCs, **+ camera** a camera
of your own, **+ spot** where a speaker stands.

**The blocks**:

- **Line**: something a character says. Click the name to change the speaker. **Enter** starts the next line.
- **Choice**: options the player picks from, each with its own lines.
- **If**: lines by a condition (for example an earlier fact the player achieves in the quest).

**A line** can have a voice (green speech mark: with lipsync; **Find another** lists the game's voiced lines and the
recordings of voice packs), a **Gesture**, a **Mood**, a **Camera**, a **Pose**, where the speaker **Looks at**,
**Extras** (a sound, a thing in the hand, a fade) and its **Length**. Without a voiceline the mouth moves to the text.
Listening to the game's voices needs [vgmstream](https://vgmstream.org) (`vgmstream-cli.exe` in the PATH).

**An option** can show only **Once** or under a condition (**+**), and do something under **Effects**:

- **Main option** (yellow, first)
- **Player pays crowns**
- **Persuade with Axii**
- **Player gives an item**: shown only while the player carries it
- **Player receives something**
- **Opens the shop**

**How an option ends**:

| ending | what happens |
|---|---|
| continue dialogue | the lines go on below |
| back to choice | the choice is shown again (for questions) |
| back to previous choice | the choice before is shown again |
| end: continue | the Talk is done, the quest goes on |
| end: repeatable | the dialogue ends, the player can come back later |
| end: fail quest | the quest fails |

Each ending is an output of the Talk in the graph.

## Mouse and keys in the graph

| To | Do |
|---|---|
| add a step after the selected one | click a block |
| put a step in between | drag a block onto a line or a step |
| start a branch | drag an output into the empty graph |
| lead an output elsewhere | drag it onto a step or an End |
| reorder | drag a step onto a line or another step |
| copy a step, also into another quest or project | Ctrl+C, Ctrl+V over the Quest tab, or **···** |
| move around | drag the empty graph; the wheel zooms; a double click on the empty graph shows all of it |

## Colours

- goals: people blue, places green, things yellow, fights and games red, time grey
- actions teal, choices purple, parallel tracks pink, chapters light grey
- each branch has its own colour on its steps' left edge and its lines
- ends: completed green, failed red
- a red dot: something is missing
- **NOW**, **DONE**, **FAILED**: where the player is in the running game

## Testing

- **Build** > **Check** plays the quest through with a stand-in player and says where a branch gets stuck.
- **Build & Play** (about 25 seconds) puts the new build into the session. The quest starts fresh.
- **Play from here** starts the quest at a step, with the items of the steps before.

## Several quests in one project

**···** beside the quest's name lists the project's quests; **+ New quest in this project** makes another. They share
the project's NPCs and locations and go into the project's one mod. In the game each is a quest of its own.

Only the open project is in the game. The mods of your other projects are moved to `<game>\_conjunction_parked` while
you build.
