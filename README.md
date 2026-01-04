# SimpleHealAI

SimpleHealAI is a lightweight healing assistant for World of Warcraft 1.12.1. It provides automated targeting and spell rank selection to optimize healing efficiency and output.

## Requirements

The following dependencies are required for core functionality:

* **SuperWoW (SuperAPI)**: Enables direct casting without target switching.
* **UnitXP (SP3)**: Provides accurate line-of-sight and 3D distance calculations.

## Core Features

* **Targeting**: Automatically selects the lowest health member in your party or raid who is within range and line of sight.
* **Direct Casting**: Utilizes the SuperWoW API to cast spells directly on targets, preserving your current selection.
* **Intelligent Ranking**:
    * **Efficient Mode**: Selects ranks based on the best healing-per-mana ratio.
    * **Smart Mode**: Selects the smallest rank required to cover the target's health deficit.
* **Mana Monitoring**: Includes a low-mana notifier that triggers an emote and visual alert at a configurable threshold.

## Commands

* `/heal`: Performs the smart healing action.
* `/heal config`: Opens the configuration menu.
* `/heal scan`: Rescans the spellbook for updated ranks.

## Settings

* **Heal Mode**: Switch between Efficient and Smart ranking logic.
* **Line of Sight**: Toggle whether line-of-sight checks are performed before casting.
* **Heal Threshold**: Configure the health percentage at which the assistant begins healing.
* **Low Mana Emote**: Toggle and set the threshold for automatic mana notifications.

## Installation

1. Ensure SuperWoW and UnitXP are installed.
2. Place the `SimpleHealAI` folder into your `Interface\AddOns` directory.
3. Restart the game client or reload the UI.