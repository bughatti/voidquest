# VoidQuest Changelog

## 0.3.13

- **Nothing about other players is saved any more:** the short list of players who had just logged off (it kept the online count right after a reload) now lasts only for your session, and the old saved list is deleted.

## 0.3.12

- **The way there, for quests in another zone (with VoidGPS):** hover a quest and its tooltip shows how to get to its next stop (the turn-in NPC, the giver or the objective), step by step, for example "1. Fly to Orgrimmar (from Camp Taurajo) 2. Take the zeppelin outside Orgrimmar to Grom'gol 3. Walk 832 yd to Hemet Nesingwary". **Shift-click** the quest and VoidGPS guides you leg by leg. The step at the top of the panel gets a "Way there" line too; click it to be guided.
- **Quests ready to turn in say so first:** a green **Turn in:** in front of the name. At the end of the line it was the first thing cut off on a long line, so it was hard to see which quest was done.

## 0.3.11

- **Fixed: the step you're on now shows its details on hover.** The top line of the panel (and its objective line under it) only said "Click: set a map pin". It now shows the same tooltip as the quest lines below: what to do, the story, your progress on each objective, the quest level and who in your group has it.

## 0.3.10

- **Fixed: box borders missing a side.** Depending on where a window sat on screen, its left, right or bottom line could vanish. Borders are now exactly one screen pixel and can't round away.

## 0.3.9 (beta)

- **WoW Forever: quest sharing moved to a new password-protected channel, a fresh one every day.** The old channel was open: anyone could join it by hand, become its owner and ban players, and a banned player's sharing silently stopped (the players box showed "—"). Now every VoidQuest player joins that day's channel with its password, and at 00:00 UTC everyone moves to the next one together, so even if someone gets in, it only lasts until the next day. Players on older versions still get whispers but aren't counted until they update.
- **"blocked" in the players box** when the game won't let you into the sharing channel, and `/vq net` says why.

## 0.3.8 (beta)

- **WoW Forever: see what quest sharing is doing.** `/vq net` now also lists the sharing traffic since the counter started: questions and new quest givers sent to and received from other VoidQuest players, how often nobody else was online, and how often a question had nothing new to answer. Most quest givers already ship with the addon, so sharing is quiet by design; this shows it's working.

## 0.3.7 (beta)

- **Quick switch for the quest panel:** left-click the Void hub button by your minimap and a Quick switches box opens next to the addon icons, with Quest panel on/off (also `/vquick`). In combat it switches when the fight ends.

## 0.3.6 (beta)

- **Fixed: clicks in the panel didn't always land.** While you quest the panel redraws often (loot, kills, quest updates), and a redraw between pressing and releasing the mouse button lost the click. The panel and My Quests now wait for you to let go before redrawing.

## 0.3.5 (beta)

- **Fixed: after a /reload mid-fight the quest item buttons didn't work.** Their setup is blocked in combat; it now happens when combat ends.
- **Fixed: in a WoW Forever dungeon, Blizzard's quest tracker came back on top of the panel.** It only comes back where it holds objectives you need (delves, the Labyrinth, retail dungeons); your setting applies everywhere else.

## 0.3.4 (beta)

- **Share quests quicker.** In a group, a **Share** button in the panel offers your group every quest you have that someone in it doesn't; alt-click a quest line to share just that one.
- **The whole quest text in the tooltip.** Hovering a quest line showed only the start of its story; it now shows all of it.
- **Right-click a quest line** opens it in VoidMap's quest page when VoidMap is installed.
- **WoW Forever: grey quests follow Blizzard.** A low-level quest no longer gets a "!" on the map (or becomes the guide's next pick-up) unless Low-Level Quests is on in the map's Filter, the same as the "!" over the quest giver's head. Before, a giver like Derek Swiftdigger had a pin but nothing over his head.

## 0.3.3 (beta)

- **WoW Forever: the players box is right after a /reload.** Players who logged off stay on the sharing channel's list; VoidQuest already left them out once a message to them bounced, but forgot that on every reload, so the count jumped up for a minute. It now remembers.

## 0.3.2 (beta)

- **A yellow star marks grey quests worth keeping.** When a quest in your log turns grey, a small star in front of its name means it still matters: a dungeon, elite or class quest, a blue or better reward, or a chain that leads to one. No star = safe to abandon. Hover a grey quest to see why. (Replaces the [keep] / [low] tags.)
- **WoW Forever: Min / Mid / Max now work.** Min = important quests only (the starred kind), Mid = + every quest on a known quest chain, Max = every quest. It decides what the guide's "Next: Pick up" line and the map's "!" suggest; quests in your log always show. Forever starts on Max, the same as before.
- **WoW Forever: the zone list (/vq fz) stars the important quests.**
- **WoW Forever: blue rewards count before you pick a quest up**, so a quest is starred and kept on Min from the start.
- **/vq chains** also shows how many quests in your zone each density keeps.

## 0.3.1 (beta)

- **WoW Forever: the players box shows the right VoidQuest count.** VoidGather, VoidQuest and VoidSweep each read their own sharing channel's member list, but the game hands out only one list at a time, so they took it from each other and the count jumped around. They now take turns.
- **Offline players stay off the count.** A player who logged off stays at 0 until a message to them goes through again. Before, they came back as "online" every 30 minutes.

## 0.3.0 (beta)

- **WoW Forever: thousands of quest givers, turn-ins and quest chains out of the box.** VoidQuest now ships data from NorgannonDB (about 4,500 quest givers with their spots, turn-in NPCs, and 3,600 chain links), instead of only the givers players had found so far (176). The map's "!" markers, the zone list and the grey quest keep / drop marks all use it. Your own finds still win where they differ.
- **Grey quests are graded on real chains**, so a grey quest that leads to a good reward or a dungeon quest is marked keep.
- **Lighter sharing.** VoidQuest only shares quest givers the shipped data doesn't already have.
- **Licence: VoidQuest is now GPL-3.0** (was MIT), because it includes NorgannonDB's data. See Credits in the README.

## 0.2.6 (beta)

- **Grey quests: keep or drop.** Grey quest lines are marked **[keep]** when they still matter (a dungeon, raid, elite or class quest, a blue reward, or a chain leading to one) or **[low]** when they're safe to abandon. Hover for why; `/vq chains` lists them.
- **WoW Forever: quest chains.** Blizzard doesn't give addons Classic quest chains, so VoidQuest learns them as you play: turn a quest in and the next one the NPC offers is its follow-up. This update ships 78 chain links already found.
- **Where quest items come from.** The quest line's tooltip names the mob or object your quest item drops from, learned from what you loot. `/vq drops` lists it. Nothing is drawn on your map.
- **WoW Forever: 176 known quest givers** (was 148).
- **Fixed:** hovering a quest with a money reward in the Forever zone list caused an error. Sharing no longer breaks while the game's chat lockdown is on (encounters), and joining the sharing channel waits until it's allowed.

## 0.2.5 (beta)

- **Leftover quest items.** Quest items often stay in your bags after the quest, and it's hard to tell what you can throw away. VoidQuest now checks each one: still needed (by a quest in your log, or it starts a quest you haven't done), **safe to destroy** (every quest it was tied to is turned in and can't be done again), or **probably not needed** (nothing in your log needs it, but it can't be sure what it was for). The reason shows in the item's tooltip, and `/vq leftovers` lists them. With VoidBags 1.2.28 they're marked in your bags. Nothing is ever destroyed for you.

## 0.2.4 (beta)

- **Quest item buttons for every quest, near the quest.** Each quest item gets its own button beside the panel (up to 6), shown only while you're near that quest (within about 1,000 yards, or in its zone when the game doesn't know where it is), with the closest on top. Before, one button stuck to a single quest's item, even a continent away.
- **WoW Forever: items from your bags.** Most Classic quests never tell the game which item is theirs (a flare gun to fire, a totem to place), so there was no button. VoidQuest now learns the item a quest hands you when you accept it, and otherwise matches an item the quest's text names. `/vq items` lists what it found.
- **Dungeons: the dungeon's quests first.** Inside Wailing Caverns the lines listed your Barrens quests and hid the dungeon's own behind "+8 more". Inside a dungeon or raid, its quests now lead and outdoor quests wait under "+N more".

## 0.2.3 (beta)

- **Quest lines are coloured by level**, like the quest log: gray (far below you), green, yellow (your level), orange, red (too high for now). Hover a line for its level.
- **See who in your group is on each quest**: a small blue badge at the right of a line counts the group members who have it too, and the line's tooltip names them. Works in parties and raids.
- **Reward advice on quest choices**: a green arrow on the reward that's an upgrade for you (with VoidGear installed it compares stats for your class and spec, otherwise item level), and a gold coin on the one worth the most gold (most quest rewards bind when picked up, so that's the vendor price). Hover the reward for why. You still pick; `/vq rewards` turns it off.
- **WoW Forever:** ships with 148 known quest givers (was 122).

## 0.2.2 (beta)

- **Read a quest by hovering it.** The tooltip on a quest line now shows what to do and the start of the quest's story, plus your progress.
- **Right-click a quest line** to open the whole quest in the quest log (left-click still tracks it). Works in the "My Quests" list too, which now has the same tooltip.
- Settings buttons are wide enough for their text ("My quests (all, not just campaign)..." spilled out), and the leveling coach's line follows the panel's width when you resize it.

## 0.2.1 (beta)

- **Drag to resize the panel** — a grip in its bottom-right corner. Bigger shows more quests, wider fits longer names.
- **Zones and Dungeons tabs** (WoW Forever) — click to switch the quests under the guide. Dungeons groups your dungeon quests under each dungeon's name (Wailing Caverns, Ruins of Lordaeron...). On retail, dungeon quests get their own group at the bottom of the list.
- **The panel fills up** — no more "+1 more" over empty space; quests from other zones show under "Other zones" when there's room.
- The guide no longer jumps to a dungeon quest just because you walk past its entrance.

## 0.2.0 (beta)

First public release.

- **Guide panel** with the next step pinned: campaign and zone guides built live from the game, and a leveling coach.
- **Follows the quest nearest to you** and lists your quests in the zone you're in first.
- **Hands-free** accept and turn-in (optional), pausing on reward choices.
- **WoW Forever:** every quest in a zone with level, XP and rewards; "!" on the map for quests whose giver is known; too-high quests kept off the map; quest givers shared with other VoidQuest players online (a spot is used once two players agree); ships with 122 known quest starts.
- **Players online box** shared with VoidGather and VoidSweep (`/vq box`).
