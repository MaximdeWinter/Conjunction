# For content creators: make your mod a content pack

If your mod adds furniture, decorations, items, armour or people from outside of The Witcher 3, quests made with Conjunction can use them. A player
who lacks your mod is told which version the quest needs and where to get it (your Nexus page).

Your mod keeps its files, its upload and its page. Conjunction adds two small files to it, the **pack card**.

## What it takes

1. In the game: **Build** > **Content pack**.
2. Pick your mod from the list, or **Other folder** for the one you are about to upload.
3. The window shows what is in it:

   | mark   | meaning                                                   |
   |--------|-----------------------------------------------------------|
   | check  | fine                                                      |
   | wrench | Conjunction fixes it at **Write pack card**               |
   | warning| works, but quests and players will stumble over it        |
   | info   | good to know                                              |

4. Fill in **Name**, **Version**, **Author**, **Link** (your Nexus page), press **Write pack card**.
5. Upload the mod as always. The folder now also holds:

   - `conjunction_pack.yml`: the card
   - `conjunction_index.json`: every template and item with its name and kind

Write the card again when the mod changes. Raise the version when you add things: quests made with the new version
ask for it or a newer one.

## New furniture from 3D files

If you have models and no mod yet: **Content pack** > **From 3D files**, pick a folder:

    my_furniture/
      oak_chair.fbx
      oak_chair_d.png        colour (also _diffuse, _albedo, _basecolor; png, tga, jpg)
      oak_chair_n.png        normal map (optional)
      long_table.fbx
      long_table_d.png

**Build pack** imports each file with REDkit (may take some time), makes a placeable thing of each, cooks the pack,
installs it and writes its card. The folder it lands in (`<game>\dlc\dlc<pack>`) is what you upload.

Models: metres, Z up (Blender: export FBX with Forward -Z, Up Y), the origin where the piece stands on the ground.
Each piece gets a box around it as collision.

The same folder can hold:

- **Decals**: pictures painted onto the world (posters, signs, stains): `<name>.decal.png` (the longer side 1 m) or
  `<name>.decal.2x1.png` (2 m wide, 1 m high). A decal projects straight down; turned upright (pitch 90) it goes onto
  a wall.
- **Items**: `items.yml`, one entry per item. `base` is a game item it is like (icon, category, tags, price, weight;
  each can be set), `text` makes it a letter or a book:

      oak_goblet:
        name: Oak goblet
        description: A goblet carved from oak.
        base: Goblet
        price: 12
      old_map:
        name: Old map
        text: X marks the spot - under the old oak.

  In the game an item is called `<pack>_own_<id>` (`medieval_furniture_own_oak_goblet`).

## What makes a pack work well

- **New things in a folder of their own**: `dlc\<your mod>\...`. A file at one of the game's own paths replaces the
  game's file for everyone.
- **Item names of their own**: an item called like one of the game's (`Ruby dust`) changes the game's item. Give new
  items a prefix (`mf_oak_goblet`).
- **Readable names**: every item's `localisation_key_name` with a text in your `en.w3strings`, else quests show the
  raw name. Templates read their `displayName` the same way.
- **Icons**: an `icon_path` for every item.
- **Lower-case item names** (`a-z`, `0-9`, `_`).

## How quests see your mod

A quest made with your things names your pack. Conjunction finds the card under any folder name a mod manager gives
the mod. If it is missing or too old, the quest waits, and the **Library** shows:

    Needs Medieval Furniture 1.2 by Carpenter                 [Get]
    For: oak chair, long table, Oak goblet

Mods without a pack card work too: the quest's author types their name, version and link on the **Build** tab (under
**Mods it uses**).
