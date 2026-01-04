# SimpleHealAI 💉

**SimpleHealAI** is a premium, lightweight auto-targeting and auto-ranking healing assistant for World of Warcraft 1.12.1. Designed for efficiency and visual clarity, it leverages modern API extensions to provide a "smart" healing experience.

> [!IMPORTANT]
> **SuperAPI (SuperWoW)** and **UnitXP** are **MANDATORY** dependencies. They enable direct casting (no target switching), precise range detection, and Line of Sight checks.

---

## ✨ Features

- **🎯 Smart Target Selection**: Automatically prioritizes the lowest health party or raid member.
- **⚡ Direct Casting**: Casts spells directly via SuperAPI—no screen flickering or target loss.
- **🧪 Advanced Range & LoS**: Uses 3D distance and Line of Sight data to ensure every cast is valid.
- **✨ Auto-Dispel**: Intelligently cleanses Magic, Poison, Disease, and Curse based on your class.
- **📊 Dynamic Ranking**: 
  - **Efficient Mode**: Maximizes Healing-per-Mana (HPM).
  - **Smart Mode**: Covers the exact health deficit to prevent overhealing.
- **🖥️ Premium Config UI**: Simple, Blizzard-style menu to customize your healing behavior.

## ⌨️ Commands

| Command | Description |
| :--- | :--- |
| `/heal` | Smart healing/cleansing action. |
| `/heal fast` | Emergency heal (Lesser Healing Wave, Flash Heal, etc.). |
| `/heal config` | Open the configuration menu. |
| `/heal scan` | Rescan spellbook for new ranks. |

## ⚙️ Settings

- **Heal Mode**: Toggle between **Efficient** (Mana Conservation) and **Smart** (Max Output).
- **Line of Sight**: Enable/Disable LoS checks for targets.
- **Dispel**: Toggle automatic debuff cleansing.
- **Threshold**: Set the % HP at which the AI begins its work (default 90%).

---

## 🚀 Installation

1. Install **SuperAPI** and **UnitXP** addons.
2. Place the `SimpleHealAI` folder in your `Interface\AddOns` directory.
3. Restart WoW or `/reload`.

*Created for players who want to focus on the fight, not the health bars.*