# SimpleHealAI

A powerful, light-weight auto-targeting and auto-ranking healing addon for Vanilla WoW (1.12).

## Features

- **Smart Target Selection**: Automatically finds the lowest HP party or raid member within 40 yards.
- **Dynamic Rank Picking**:
  - **Efficient Mode**: Calculates the best healing-per-mana ratio based on the target's actual health deficit.
  - **Smart Mode**: Picks the smallest possible rank that covers the deficit to minimize overhealing.
- **SuperWoW Integration**: Uses SuperWoW features for precise range checks and Line of Sight (LOS) detection when available.
- **LOS Toggle**: Option to enable or disable Line of Sight checks for healing (requires SuperWoW).
- **Auto-Target Restore**: Automatically switches back to your previous target after casting a heal.
- **Class Support**: Works for Shaman, Priest, Paladin, and Druid.
- **Configurable Threshold**: Set the health percentage at which the AI should start healing.

## Commands

- `/heal` or `/sheal` - Triggers the smart healing logic.
- `/heal fast` - Uses faster, lower-rank heals (Lesser Healing Wave, Flash Heal, etc.).
- `/heal config` - Opens the settings menu.
- `/heal scan` - Manually rescans your spellbook for new ranks.

## Installation

1. Download the repository as a ZIP.
2. Extract into your World of Warcraft `Interface\AddOns` folder.
3. Ensure the folder name is exactly `SimpleHealAI`.

## Requirements

- **SuperWoW** (Optional but highly recommended for Range and LOS features).
- **UnitXP** (Included in modern vanilla clients/SuperWoW).
