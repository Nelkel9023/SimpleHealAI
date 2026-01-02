# SimpleHealAI

A powerful, light-weight auto-targeting and auto-ranking healing addon for Vanilla WoW (1.12). 

> [!IMPORTANT]
> **SuperWoW** and **UnitXP** are **MANDATORY** for this addon to function. They enable precise range detection, Line of Sight checks, and direct spell casting.

## Features

- **Smart Target Selection**: Automatically finds the lowest HP party or raid member within 40 yards.
- **Direct Casting (SuperWoW)**: Casts heals directly on targets without switching your current target or flickering.
- **Auto-Cleansing**: Automatically detects and removes Magic, Poison, Curse, and Disease debuffs if the option is enabled.
- **Dynamic Rank Picking**:
  - **Efficient Mode**: Calculates the best healing-per-mana ratio based on the target's actual health deficit.
  - **Smart Mode**: Picks the smallest possible rank that covers the deficit to minimize overhealing.
- **Line of Sight (LOS) Check**: Advanced LOS detection to ensure you never waste mana on targets behind walls.
- **Configurable Threshold**: Set the health percentage (50-99%) at which the AI should start healing.
- **Class Support**: Full support for Shaman, Priest, Paladin, and Druid.
- **Redesigned Config UI**: Modern, clean configuration menu with standard WoW checkboxes.

## Commands

- `/heal` or `/sheal` - Triggers the smart healing logic.
- `/heal fast` - Uses faster, lower-rank heals (Lesser Healing Wave, Flash Heal, etc.).
- `/heal config` - Opens the settings menu.
- `/heal scan` - Manually rescans your spellbook for new ranks.

## Config Menu Options

- **Heal Mode**: Choose between **Efficient** (Mana conservation) and **Smart** (Deficit coverage).
- **Line of Sight Check**: Toggle visibility checks for targets.
- **Auto-Dispel Debuffs**: Toggle automatic cleansing of friendly units.
- **Chat Messages**:
  - **Off**: No chat output.
  - **All**: Show all healing actions.
  - **New**: Only show messages when target or spell rank changes.
- **Heal Threshold**: Adjust the HP percentage point where healing begins.

## Installation

1. Ensure you have **SuperWoW** installed.
2. Download the repository as a ZIP.
3. Extract into your World of Warcraft `Interface\AddOns` folder.
4. Ensure the folder name is exactly `SimpleHealAI`.