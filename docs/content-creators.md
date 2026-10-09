# For content creators: make your mod a content pack

If your mod adds furniture, decorations, items, armour or people to the game, quests made with Conjunction can use
them. When a player downloads such a quest and lacks your mod, Conjunction tells them which mod is missing, which
version, what the quest needs from it and where to get it (your Nexus page).

Your mod keeps its files, its upload and its page. Conjunction adds two small files to it, the **pack card**.

## What it takes

1. In the game with Conjunction's editor: **Project** > **Build** > **Content pack**.
2. Pick your mod from the list (every mod in the game's `dlc` and `Mods` folders) or **Other folder** for the one
   you are about to upload.
3. The window shows what is in it and what others would trip over:

   | mark   | meaning                                                                          |
   |--------|----------------------------------------------------------------------------------|
   | check  | fine                                                                             |
   | wrench | Conjunction does it when you press **Write pack card**                             |
   | warning| works, but quests and players will stumble over it; worth fixing in the mod      |
   | info   | good to know                                                                     |

4. Fill in **Name**, **Version**, **Author**, **Link** (your Nexus page), press **Write pack card**.
5. Upload the mod as always. The folder now also holds:

   - `conjunction_pack.yml`, the card: id, name, version, author, link, what kinds of things it brings
   - `conjunction_index.json`, the table of contents: every template and item with its name and kind (the Asset
     Browser shows them; quests name them)

Write the card again whenever the mod changes (the window says so when the contents are out of date). Raise the
version when you add things: quests made with the new version ask for it or a newer one.

## New furniture from 3D files

If you have models and no mod yet: **Content pack** > **From 3D files**, pick a folder:

    my_furniture/
      oak_chair.fbx
      oak_chair_d.png        colour (also _diffuse, _albedo, _basecolor; png, tga, jpg)
      oak_chair_n.png        normal map (optional)
      long_table.fbx
      long_table_d.png

The window lists every piece with the textures it found. **Build pack** imports each file with REDkit (this may take some
time), gives the meshes the game's standard material with your textures, makes a placeable thing of each,
cooks the pack, installs it and writes its card. The folder it lands in (`<game>\dlc\dlc<pack>`) is what you upload.

Models: metres, Z up (Blender: export FBX with Forward -Z, Up Y), the origin where the piece stands on the ground.
Each piece gets a box around it as collision (the player bumps into it).

The same folder can hold:

- **Decals**: pictures painted onto the world (posters, signs, coats of arms, stains): `<name>.decal.png` (the
  longer side 1 m) or `<name>.decal.2x1.png` (2 m wide, 1 m high). A decal projects straight down onto what is
  below it; turned upright (pitch 90) it goes onto a wall.
- **Items**: `items.yml`, one entry per item; `base` is a game item it is like (its icon, category, tags, price,
  weight; you can set each one yourself), `text` makes it a letter or a book:

      oak_goblet:
        name: Oak goblet
        description: A goblet carved from oak.
        base: Goblet
        price: 12
      old_map:
        name: Old map
        text: X marks the spot - under the old oak.

  In the game an item is called `<pack>_own_<id>` (`medieval_furniture_own_oak_goblet`).

## What makes a pack work well with everyone's quests

- **New things in a folder of their own**: `dlc\<your mod>\...`. A file at one of the game's own paths replaces the
  game's file for everyone; a quest that uses it shows the game's version to players who lack your mod.
- **Item names of their own**: an item called like one of the game's (`Ruby dust`) changes the game's item. Give
  new items a prefix (`mf_oak_goblet`).
- **Readable names**: every item's `localisation_key_name` with a text in your `en.w3strings` (else quests and the
  Asset Browser show the raw name). Templates read their `displayName` the same way.
- **Icons**: an `icon_path` for every item.
- **Lower-case item names** (`a-z`, `0-9`, `_`): quests give them straight by their name, the safest way.

## How quests see your mod

Conjunction knows what is installed in the game it runs on. A quest made with your things carries your pack's id,
name, version, link and the list of things it took (in `conjunction_quest.yml`). A player's
Conjunction looks for your card in their game folders (any folder name: mod managers may rename it). Found and new
enough: the quest plays. If it is missing, the quest waits, and the **Library** shows:

    Needs Medieval Furniture 1.2 by Carpenter                 [Get]
    For: oak chair, long table, Oak goblet

## Mods with no pack card

Quest authors can still use things from mods that have no card. Conjunction then knows the mod by its folder name,
and the quest's author types its name, version and link on the **Build** tab (under **Mods it uses**). A pack card
works under any folder name a mod manager gives the mod.
