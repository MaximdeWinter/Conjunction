Conjunction

Conjunction is an editor inside The Witcher 3. You can fly freely, place NPCs and objects, and
build a quest from a node based graph system. It aims to offer an easy entry to beginners, while still having the
depth for more advanced quest makers.

Build & Play turns the project into a mod and loads it into the running game. Export makes a folder with a zip to
upload. Players need only the quest zip.


Early access

Conjunction is a large project and in early access. Expect bugs, and please report them in the Bugs tab of its Nexus
page.


What is needed?

- The Witcher 3 Remastered 5.0, 5.01 or 5.01c (DirectX 12)
- TW3SE 1.3.3 or newer (https://www.nexusmods.com/witcher3/mods/13837)
- The Witcher 3 REDkit, for Build & Play and Export
- The radish modding tools (https://www.nexusmods.com/witcher3/mods/3620), for Build & Play and Export


Install

1. Install TW3SE.
2. Download the radish modding tools zip (Manual download). Do not install it, Conjunction will do it for you.
3. Unpack the Conjunction zip into the game folder (the one with bin, content, dlc), or use a mod manager.
4. Start the game as usual and press F8 in the main menu.

Press F8 in the main menu of The Witcher 3 to open the Conjunction panel. New project creates a new project, Open
ingame starts it in a session of its own. Saving is deactivated during a session, so your save files don't get
confused.

To update, unpack the new zip over the old files.


In the game

F8 switches between editing and playing. While you edit, the game stands still and you fly the camera. While you
play, you control Geralt as usual. Esc opens the game's menu.

Build & Play saves the session, puts the new build of the quest into the game and loads the session again (about 25
seconds). You stand where you stood. A project that changes the game's own quests restarts the game.

F11 takes a screenshot (Documents\Conjunction\screenshots).


AI agent interface

While the game runs, other programs on your PC can control Conjunction through TW3SE's local interface (a named pipe
of your PC). It is made for AI agents and scripts: a coding assistant on your PC can build and test a quest for you.

Through it, a program can:

- read Conjunction's windows, click and type in them
- take screenshots of the game with Conjunction's windows
- read and change the open quest and its places, build it, Build & Play
- send commands to the game
- run Lua code inside Conjunction

Conjunction has no AI of its own and sends nothing to an AI service. Any program running on your PC can use the
interface while the game runs.

Disclaimer: I created this interface because it helps with jumpstarting your idea if you have a bigger quest in mind.
AI agents are just a tool and don't replace your creativity. Always test your quests before releasing them.


Folders

Everything Conjunction keeps is in Documents\Conjunction: your projects, quests to play, exports, bug reports,
screenshots, the radish modding tools and its settings.

In the game folder:

- bin\x64_dx12\tw3se\mods\conjunction: the editor
- bin\x64_dx12\tw3se\plugins: cj_core.dll, cj_qt.dll and Qt (cj_qt)
- Mods\modConjunction: the editor's scripts
- Mods\modConjunctionRuntime: the scripts every quest made with Conjunction calls
- Mods\modConjunctionSessions: the sessions (made at the first start)
- dlc\dlcconjunctiontexts: texts for scenes


Credits

- radish modding tools: rmemr
- The Witcher 3 REDkit / wcc_lite: CD PROJEKT RED
- The quest graph follows the look and the wire router of PathView by milanofthe (MIT)

The software inside Conjunction and its licenses: THIRD_PARTY_NOTICES.txt and the licenses folder.


License

You may use Conjunction and change it for your own use. Quests and mods made with it belong to their creator.
Conjunction itself (also changed) may only be downloaded from its official pages. A credit ("Made with Conjunction")
is welcome. The full text is in LICENSE.txt.
