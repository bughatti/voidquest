# VoidQuest

**A quest guide that reads the game live: your campaign, your zone, and the quest nearest to you, on retail and WoW Forever.**

VoidQuest shows one small panel with the next thing to do and pins it on your map. It builds its steps from the game itself (campaigns, quest lines, your quest log), so it covers new content on day one instead of waiting for a hand-written guide. On WoW Forever, where the map shows no quest givers, it learns where quests start as you and other VoidQuest players play. **Beta:** expect rough edges and tell us on Discord.

---

## Features

### The guide panel
- **Next step, pinned** — the quest to pick up, the objective to finish or the NPC to turn in to, with a map pin and the arrow pointed at it.
- **Follows the quest nearest to you** — walk toward another quest's area and the panel switches to it. It only switches when another quest is clearly closer, so it doesn't flicker.
- **Your quests here first** — the lines under the step list the quests in the zone you're in, nearest first, then other zones' quests when there's room.
- **Drag to resize** — pull the corner grip to make the panel bigger or smaller; it fills the space with your quests, and only what doesn't fit becomes "+N more" (hover to list, click to open).
- **Zones and Dungeons tabs** (WoW Forever) — your zone's quests on one tab, dungeon quests on the other, grouped under each dungeon's name.
- **Click a line to track that quest** — your choice holds until you reach it or clear it. VoidQuest never takes over an arrow you set yourself.
- **Hover to read, right-click to open** — hovering a quest line shows what to do and the start of its story; right-click opens the whole quest in your quest log.
- **Coloured by level** — quest lines use the quest log's colours: gray (far below you), green, yellow (your level), orange, red (too high for now).
- **Who in your group is on it** — a small blue badge at the right of a line counts the group members on that quest too; hover for their names.
- **Quest items, one click** — when a quest needs you to use an item ("fire the flare gun", "use the totem"), its button sits beside the panel while you're near that quest, closest quest on top, and goes away when you leave. On WoW Forever most quests never tell the game which item is theirs, so VoidQuest works it out: the item a quest hands you when you accept it, else an item the quest's text names. `/vq items` shows what it found.
- **In a dungeon, its quests first** — inside a dungeon or raid the lines list that dungeon's quests; your outdoor quests wait under "+N more".

### Leftover quest items
- **What you can throw away** — quest items often stay in your bags after the quest. VoidQuest checks each one: still needed by a quest in your log (or it starts a quest you haven't done), **safe to destroy** (every quest it was tied to is turned in, and none can be done again), or **probably not needed** (nothing in your log needs it, but some quests use an item before you have them). The reason is in the item's tooltip; `/vq leftovers` lists them. With **VoidBags**, leftovers get a red X or a yellow ? in your bags. Nothing is ever destroyed for you.

### Grey quests: keep or drop
- **[keep] or [low] on grey quest lines** — a grey quest is marked **keep** when it still matters: a dungeon, raid, elite or class quest, a blue or better reward, or a chain that leads to one ("probably leads to Leaders of the Fang (dungeon quest)"). Otherwise it's **low value**, safe to abandon if you need the room. Hover the line for why; `/vq chains` lists them. Nothing is ever abandoned for you.
- **Quest chains are learned** (WoW Forever): Blizzard keeps Classic quest chains on its servers, so VoidQuest learns them as you play: turn a quest in and the next one the NPC offers is its follow-up. Every update ships the chains found so far.

### Where quest items come from
- **The quest line's tooltip names the source** — "Plainstrider Kidney: from Greater Plainstrider (12)", learned from what you loot. `/vq drops` lists it. Nothing is drawn on your map.

### Quest rewards
- **Upgrade or gold** — when a quest lets you choose, a green arrow marks the reward that's an upgrade for you (stat-based with VoidGear, otherwise item level) and a gold coin marks the one worth the most gold. Hover a reward for why. You still pick.

### Hands-free (optional)
- **Auto accept and turn in** — for the campaign you follow, or every quest if you want.
- **Pauses on reward choices** — you pick the item; single rewards are taken for you.

### Retail
- **Campaign guide** — follow your expansion's campaign chapter by chapter, or pick any campaign.
- **Zone guides** — every zone's storylines as a guide, built live from the game.
- **Leveling coach** — one line that says what to do next to reach max level (Chromie Time, the expansion intro, the zone that fits your level).
- **Density** — Min (campaign only), Mid (plus important side stories) or Max (everything).
- **Weekly coffer keys** — at max level, what's left this week and where.
- **Quests inside dungeons and delves** — the arrow points at the entrance, not at a random field.

### WoW Forever
- **Every quest in a zone** — a zone list with level, XP and rewards for all of Forever's quests (from Blizzard's own quest data), marked done, in your log, or still to do.
- **"!" on your map for quests whose giver is known** — Forever's map shows none, so VoidQuest learns them: where you picked a quest up, and every quest an NPC offers you, even ones you don't take.
- **Too-high quests stay off the map** — quests five or more levels above you, and quests a giver didn't offer you yet (level or an earlier quest first). They come back as you level.
- **Shared with other VoidQuest players** — when you find a quest giver, a few other VoidQuest players online learn it, and you learn theirs. A spot is only used once two players agree on it. See Privacy below.
- **Ships with the quest givers we've found** — every update carries the spots VoidQuest players have confirmed.
- **Players online box** — how many other VoidQuest players are online (shared with VoidGather and VoidSweep).

---

## Slash Commands

| Command | What it does |
|---|---|
| `/vq` | Show or hide the guide panel |
| `/vq config` | Settings |
| `/vq auto` | Hands-free on / off |
| `/vq density` | Cycle Min / Mid / Max |
| `/vq lines` | Pick which quest lines to show |
| `/vq campaign` | Pick a campaign to follow (retail) |
| `/vq quests` | All your quests |
| `/vq zones` | Zone guides (retail) / every quest in your zone (WoW Forever) |
| `/vq arrow` | Arrow on / off |
| `/vq box` | Show or hide the players online box |
| `/vq rewards` | Reward advice on quest choices on / off |
| `/vq items` | List the quest items VoidQuest found, which quest each is for, how far, and whether it's showing |
| `/vq leftovers` | List quest items in your bags that nothing needs anymore, and why |
| `/vq chains` | Grey quests in your log: keep or low value, and why |
| `/vq drops` | Where your quests' items have come from (mobs and objects you looted) |
| `/vq share` | WoW Forever: sharing quest givers on / off |
| `/vq net` | WoW Forever: check that sharing gets through |
| `/vq reset` | Put the panel back in the middle of the screen |

---

## Getting Started

1. Install with the CurseForge app, or copy the `VoidQuest` folder into
   `World of Warcraft/_retail_/Interface/AddOns/` (WoW Forever: `_forever_/Interface/AddOns/`).
2. Restart WoW or `/reload`.
3. The panel shows up with your next step. Right-click the minimap button for settings.

---

## Privacy & Data (WoW Forever sharing)

- **What's sent:** a quest's ID, the quest giver's NPC ID and name, the map and the spot. Nothing about you or your character.
- **How:** by hidden addon whisper to a few other VoidQuest players online. It never shows in chat.
- **Like any whisper, the players who get it can see which character sent it.** So your finds aren't sent live: they go out once you've left that map, or 10-20 minutes later, so they never show where you are right now.
- **Other players' names are never saved.** Reports are counted with a one-way code so two reports from the same player don't count twice.
- **Off switch:** `/vq share`, or the checkbox in settings. Retail sends nothing.

---

## Good to Know

- On WoW Forever, quest givers nobody has found yet aren't on the map. They fill in as players use VoidQuest, and every update ships more.
- The game has no way to ask for a quest's required level, so VoidQuest learns it from what quest givers offer you.
- Settings and learned quest givers are shared across your characters.

---

## Compatibility

- **WoW 12.1** (Midnight) and **WoW Forever**
- Works with VoidGather and VoidSweep (shared players online box), and with the rest of the Void addons.

---

*Part of the Void addon family by Vede · MIT licensed · [Source & bug reports](https://github.com/bughatti/voidquest) · [All Void addons](https://www.curseforge.com/members/bughatti/projects) · free M+ & raid player lookups at [voidscout.io](https://voidscout.io) · more at [tinkerline.io](https://tinkerline.io) · [Discord](https://discord.gg/7ZHmx7zMDh)*
