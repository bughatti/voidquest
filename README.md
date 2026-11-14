# VoidQuest - Quest Guide & Quest Finder

**Works on:** WoW Midnight · WoW Forever

> **WoW Forever players: please update to the latest version.** Versions from before November 10, 2026 (0.3.19 and older) use the old sharing channel, so they can't share with current players and aren't counted in the Players online box. The CurseForge app updates it for you; if you installed by hand, download the newest file.

**A quest guide that reads the game live: your campaign, your zone, and the quest nearest to you, on Midnight and WoW Forever.**

VoidQuest shows one small panel with the next thing to do and pins it on your map. It builds its steps from the game itself (campaigns, quest lines, your quest log), so it covers new content on day one instead of waiting for a hand-written guide. On WoW Forever, where the map shows no quest givers, it ships with thousands of quest givers, turn-ins and quest chains (from NorgannonDB, see Credits) and fills the rest in as you and other VoidQuest players play. **Beta:** expect rough edges and tell us on Discord.

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
- **Ready to turn in, first** — a quest that's done starts its line with a green **Turn in:**, so you see it even when the line is long.
- **The way there** (with **VoidGPS**) — for a quest in another zone, the tooltip lists the steps to its next stop: "1. Fly to Orgrimmar (from Camp Taurajo) 2. Take the zeppelin outside Orgrimmar to Grom'gol 3. Walk 832 yd to Hemet Nesingwary". **Shift-click** the quest and VoidGPS guides you there.
- **Coloured by level** — quest lines use the quest log's colours: gray (far below you), green, yellow (your level), orange, red (too high for now).
- **Quest levels in front of the name** — "[30] Horde Presence", with **[30D]** for a dungeon quest, **[30R]** raid and **[30+]** elite (WoW Forever). Turn it off in settings.
- **Who in your group is on it** — a small blue badge at the right of a line counts the group members on that quest too; hover for their names.
- **Quest items, one click** — when a quest needs you to use an item ("fire the flare gun", "use the totem"), its button sits beside the panel while you're near that quest, closest quest on top, and goes away when you leave. On WoW Forever most quests never tell the game which item is theirs, so VoidQuest works it out: the item a quest hands you when you accept it, else an item the quest's text names. `/vq items` shows what it found.
- **In a dungeon, its quests first** — inside a dungeon or raid the lines list that dungeon's quests; your outdoor quests wait under "+N more".

### Leftover quest items
- **What you can throw away** — quest items often stay in your bags after the quest. VoidQuest checks each one: still needed by a quest in your log (or it starts a quest you haven't done), **safe to destroy** (every quest it was tied to is turned in, and none can be done again), or **probably not needed** (nothing in your log needs it, but some quests use an item before you have them). The reason is in the item's tooltip; `/vq leftovers` lists them. With **VoidBags**, leftovers get a red X or a yellow ? in your bags. Nothing is ever destroyed for you.

### Grey quests: keep or drop
- **A yellow star on grey quests worth keeping** — when a quest in your log turns grey, a small star in front of its name means it still matters: a dungeon, raid, elite or class quest, a blue or better reward, or a chain that leads to one ("probably leads to Leaders of the Fang (dungeon quest)"). **No star = safe to abandon.** Hover the line for why; `/vq chains` lists them. Nothing is ever abandoned for you.
- **Quest chains** (WoW Forever): Blizzard keeps Classic quest chains on its servers, so VoidQuest ships them (thousands, from NorgannonDB) and learns more as you play: turn a quest in and the next one the NPC offers is its follow-up.

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
- **Is this quest worth it for you?** — when an NPC offers you a quest (and at progress and turn-in), a box beside the quest window gives a verdict for your character: green **worth it for you** or grey **nothing lasting for you**. Under it: what kind of quest it is (**dungeon quest** and which dungeon, **raid**, **elite**, or **regular, out in the world**), which of its rewards are for your character ("Rewards for you: Quilboar Blaster"), the rest of the quest's chain (including "Goes into: <dungeon>" when the chain leads into one) (how many quests, how much XP, and what it leads to: an ability, a blue item you can use, a mount, a key), and for each faction the quest gives reputation with, what that faction has for you and at which standing, for example "Revered: <item> (one-handed sword)", next standing first. A faction that only sells caster gear says "nothing for your Rogue (caster gear)"; one that sells nothing says "reputation only". Until you're Honored with a capital, a goblin town or a faction with a reputation vendor, it also tells you that **Honored takes 10% off its vendors and trainers** (measured in game; for your own race's capital that includes your riding skill and mount). Hovering a quest line shows the short version.
- **The Quest Book** — like the achievements window, for quests (the **Book** button next to Zone, a key binding, or `/vq book`). Every zone with your progress (done / total), and filters for **done, can do now, in your log and later**. **Search quests by their rewards**: "off hand sword", "blue leather pants", "green cloak", "bag" (every word has to fit the same reward: slot, weapon or armor type, quality or name; quest names and zones work too). **Only what I can use** leaves out what your class can't wear or wield. Reward icons on every line (hover, shift-click to link); click a quest for the way to its giver. Rewards Blizzard's Forever data leaves out (Sword of Omen and 200+ more, mostly dungeon quests) are filled in from NorgannonDB; which of them you choose from comes from the game itself (your quest log, or a quest giver that showed you the quest), never a guess.
- **Bags** — every quest that gives a bag, with its size, and the bags you can buy, normal and reagent bags (herb, mining, skinning), with price, the nearest vendor and the way there.
- **Every quest in a zone** — a zone list with level, XP and rewards for all of Forever's quests (from Blizzard's own quest data), marked done, in your log, or still to do. Important ones have a yellow star.
- **Density** — Min (important quests only: dungeon, elite and class quests, blue rewards, and chains that lead to them), Mid (plus every quest on a known chain) or Max (every quest, the default). It decides what the guide suggests next and which "!" the map shows; quests in your log always show.
- **"!" on your map for quests you can take** — Forever's map shows none, so VoidQuest brings its own: thousands of quest givers ship with it, and it learns more as you play (where you picked a quest up, and every quest an NPC offers you, even ones you don't take).
- **Only quests you can take get a "!"** — VoidQuest checks what each quest needs before its giver offers it: your level, class and race, an earlier quest, a profession skill or a reputation. Quests for another class or race, quests closed off by one you did, and lead-ins whose quest you already have don't show at all; the rest come back when you can take them. Hover a quest in the zone list for why it's not yet.
- **Group up with players on the same quest** — Ctrl-click a quest in the panel (or `/vq group` for the one you track): VoidQuest finds the other VoidQuest players in your zone who have it and asks the 4 closest, with a pop-up showing your name, level and class and an Accept button. Whoever accepts gets your invite and joins on their own. Ctrl-click again to ask the next ones. A player who says no, or doesn't answer within 5 minutes, is never asked about that quest again. You're only asked when you're solo, out of combat and outside instances, at most once every 3 minutes; turn it off in settings.
- **Route plan: the best order for your quests** — the panel's **Route** button (or `/vq route`) plans the quests in your log: where to do each one, where to hand it in, in the order that wastes the least time, with turn-ins at the same NPC batched. **Quests you could pick up on the way** are added too (up to 8), when their giver is in a zone the route goes through and they're worth the detour: XP for the extra time at least as good as the rest of the plan. **The next quest in a chain** comes right after the turn-in that opens it ("Pick up (next in chain) …"), up to 3 links deep. A quest whose objectives are in different places (two flames here, one in the next zone) gets a stop in each place, and objectives you've already done are left out. **Areas to discover on the way**: an area you haven't discovered yet, in a zone the route goes through, is added when it costs at most 90 seconds of extra travel ("Discover Bramblescar (Explore The Barrens)"): Explore Azeroth is a Legacy point. **Your level counts:** a quest above you is planned as slower (about 20% more time per level), one below you as quicker, and a quest 2 or more levels above you waits until the turn-ins before it have brought you close to its level. When nobody knows yet where a quest is handed in, the plan sends you back to its giver and says "probably". The top line sums it up: "9 quests · about 1 h 20 min (25 min on the way) · 21,400 XP · ~16,000 XP/hour". Click a step and VoidGPS guides you there (the quest gets tracked). Dungeon, raid and elite quests are listed apart (bring a group), as are grey quests and quests with no known place yet. It plans again when your log changes. With **VoidGPS** the way between stops counts flight paths and zeppelins; the time to do a quest comes from what players took (see below), else a guess from what's left.
- **Hover an NPC: its quests for you** — a quest giver's tooltip lists the quests it has that you can take now, with their level ("Quest: [24] The Swarm Grows"), and a turn-in NPC's lists the quests in your log it takes ("Turn in: Horde Presence"). WoW Forever's own tooltips already show your progress on quest mobs ("Hatefury Rogue slain 3/7").
- **Quest history** — the Quest Book's tooltip says when you turned a quest in and at what level ("Done Nov 11, 2026 at level 33"), from this version on.
- **How long a quest really takes, and the XP per hour** — measured by VoidQuest players doing it solo at its level (within 2 levels, so an over-level player racing through doesn't count). Only the time spent working on it counts: grab a whole hub's quests and do them in any order, and each one gets just its own part. Shown in the quest's tooltip and in the box beside the quest window: "Takes about 10 min solo at its level · ~18,000 XP/hour".
- **Quests players give up on** — when players keep abandoning a quest after real work (10+ minutes, not finished, not grey for them), its tooltip and the quest window box say "Players often give up on this one".
- **See who's on your quests here** — a small grey number at the end of a quest line counts the other VoidQuest players in your zone on that quest (hover it for the line, Ctrl-click to group up). No pop-ups: arriving in a zone you get one chat line when players there share your quests ("3 VoidQuest players in The Barrens are on 2 of your quests"), at most once per zone every 30 minutes, and you can turn that line off.
- **Escort quests say why the giver may be missing** — while another player has an escort going, its giver is gone for everyone until it ends. The pickup line and the quest's tooltip say so ("if Lakota Windsong isn't here, another player is on the escort"), and once players have waited there, how long it usually takes.
- **A grey "!" says go get it first** — a quest whose giver is here but needs an earlier quest somewhere else gets a grey "!": "Go get *The Swarm Grows* from Korran in The Barrens first". Click it for the way there.
- **Shared with other VoidQuest players of your faction** — when you find a quest giver, a few other VoidQuest players online learn it, and you learn theirs. A spot is only used once two players agree on it. Horde and Alliance share separately (whispers don't cross factions, and the other side's quests are no use to you). See Privacy below.
- **Ships with quest givers, turn-ins and chains** — from NorgannonDB, plus the spots VoidQuest players have confirmed. Where players' finds differ, they win.
- **Players online box** — how many other VoidQuest players are online (shared with VoidGather and VoidSweep).
- **Find your quest's mobs** — one marker on the minimap for each unfinished objective of the quest you're tracking: on the minimap's edge pointing the way while it's far, at the spot once you're close, gone when you're there. Red = mobs to kill, yellow = something that drops the item you need, blue = an object to use, pale gold = the game's own objective point. Hover it for the mob, the quest, your count and how far. `/vq dots` turns them off.
- **Quest icon over nameplates** — a yellow **!** over every mob in view that counts for your unfinished objectives (the game's own quest data, so only the right ones), and a silver one over rares.
- **Learns where mobs really are, together** — when a quest mob's nameplate shows up, VoidQuest remembers the spot where you got **closest** to it (the game's own range checks: within 10 yards when you ride past), so the markers point at where they really are on Forever. **Hunters and druids:** point at a tracked mob's dot on the minimap and its exact spot is saved. Spots the shipped data doesn't have are shared with other VoidQuest players, and **once three players have seen a mob at the same spot, it's a marker for everyone**. Mobs of quests you've already done (or never took) count too: no icon for you, but their spots help everyone still on those quests.
- **Pins to another continent** take the zeppelin, and the boats VoidGPS has learned when it's installed.

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
| `/vq book` | WoW Forever: the Quest Book (every quest: done, can do, search by reward) |
| `/vq arrow` | Arrow on / off |
| `/vq box` | Show or hide the players online box |
| `/vq rewards` | Reward advice on quest choices on / off |
| `/vq items` | List the quest items VoidQuest found, which quest each is for, how far, and whether it's showing |
| `/vq leftovers` | List quest items in your bags that nothing needs anymore, and why |
| `/vq chains` | Grey quests in your log: starred (keep) or not, and why; on WoW Forever, how many quests here each density keeps |
| `/vq drops` | Where your quests' items have come from (mobs and objects you looted) |
| `/vq route` | WoW Forever: the route plan (best order for your quests) |
| `/vq group` | WoW Forever: ask VoidQuest players on your tracked quest to group (`/vq group test` tries it with yourself as the other player) |
| `/vq share` | WoW Forever: sharing (quest givers, rewards, escorts, quest-mob spots) on / off |
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

- **What's sent:** a quest's ID, the quest giver's NPC ID and name, the map and the spot; and for a quest you're offered or turn in, its reward item IDs and the reputation it gives (faction and amount). Nothing about you or your character. For an escort quest: that it is one (when a group member's escort start or an escort failing shows it), and how long the giver took to show up, in rough minutes. Rewards, reputation and escorts are only used once two players agree on them. **Group up** (only when you Ctrl-click a quest): the quest, your zone and rough spot go to the VoidQuest players online; the ones on it answer with how far they are, and the closest get your name, level and class in the pop-up. **Quest times:** for a quest you did solo at its level, how many minutes it took (rounded: 2, 5, 10 ... 60); and for one you gave up on after 10+ minutes, that you did. Held back 10-20 minutes like everything else, no names. **Players here:** your zone goes to a few VoidQuest players online when you arrive and every 5 minutes; only the ones in your zone answer, with the IDs of their unfinished quests. You only ever see a count, never their names. The group-asks setting turns being counted off too.
- **Quest mobs:** for a spot the shipped data doesn't have, the mob's NPC ID, the map, the spot and the quest it counts for. Used once three players agree. Rares that aren't quest mobs aren't sent.
- **Only to your own faction:** each faction has its own sharing channel.
- **How:** by hidden addon whisper to a few other VoidQuest players online. It never shows in chat.
- **Like any whisper, the players who get it can see which character sent it.** So your finds aren't sent live: they go out once you've left that map, or 10-20 minutes later, so they never show where you are right now.
- **Other players' names are never saved.** Reports are counted with a one-way code so two reports from the same player don't count twice.
- **Off switch:** `/vq share`, or the checkbox in settings. Retail sends nothing.

---

## Good to Know

- On WoW Forever, the few quest givers missing from the shipped data fill in as players use VoidQuest. Sharing only sends what the shipped data doesn't already have, so it stays light.
- The game has no way to ask for a quest's required level, so VoidQuest learns it from what quest givers offer you.
- Settings and learned quest givers are shared across your characters.

---

## Compatibility

- **WoW Midnight** 12.1.5 (Season 2)
- **WoW Forever**
- Works with VoidGather and VoidSweep (shared players online box), and with the rest of the Void addons.

---

## Credits

- **Quest givers, turn-ins and quest chains on WoW Forever** come from [NorgannonDB](https://github.com/zmarotrix/NorgannonDB) by Maro (GPL-3.0), which builds on [QuestieDB](https://github.com/Questie/Questie) (GPL-3.0) and pfQuest, and reads WoW Forever's own game tables. Thank you.
- Quest names, rewards and levels come from Blizzard's own game data. World of Warcraft is a trademark of Blizzard Entertainment.

---

*Part of the Void addon family by Vede · GPL-3.0 licensed · [Source & bug reports](https://github.com/bughatti/voidquest) · [All Void addons](https://www.curseforge.com/members/bughatti/projects) · free M+ & raid player lookups at [voidscout.io](https://voidscout.io) · more at [tinkerline.io](https://tinkerline.io/addons/voidquest/) · [Discord](https://discord.gg/7ZHmx7zMDh)*
