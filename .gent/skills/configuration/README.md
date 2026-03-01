# Gent Configuration Examples

This directory contains example configuration files that demonstrate different aspects of customizing gent.

## Files

- **`SKILL.md`** — Quick start guide and common customizations
- **`references/`** — Detailed documentation by topic:
  - `colors.md` — Complete color customization guide
  - `hooks.md` — All hook types and examples
  - `tools.md` — Custom tool creation
  - `commands.md` — Slash command creation
  - `widgets.md` — Widget system architecture
  - `advanced.md` — Registers, API config, conditional config
- **`example-init.janet`** — Basic configuration example with common customizations
- **`cyberpunk-theme.janet`** — Custom color theme example with neon colors
- **`dev-workflow.janet`** — Development-focused configuration with auto-formatting and git integration
- **`productivity.janet`** — Productivity features like notes, bookmarks, and session management
- **`custom-widgets.janet`** — Advanced UI customization with custom widgets and layouts

## Key Topics Covered

### Basic Configuration
- Color themes and UI customization
- Hooks for extending behavior  
- Custom tools and slash commands
- Data storage with registers

### UI Architecture & Widgets
- Understanding the widget system
- Creating custom widgets
- Layout management and constraints
- Event handling and rendering
- Inter-widget communication

### Development Features
- Auto-formatting integration
- Git workflow tools
- Project-specific configuration
- Testing and linting integration

### Productivity Tools
- Note-taking and categorization
- Bookmark management
- Session statistics and uptime tracking
- Clipboard integration

## Usage

### As a Skill

Activate the configuration skill to get comprehensive help:

```
/skill:configuration
```

### Copy Examples

Copy any of the example files to your configuration:

```bash
# Copy basic example
cp .gent/skills/configuration/example-init.janet ~/.gent/init.janet

# Or manually copy parts you want
```

### Mix and Match

You can combine features from different examples in your `~/.gent/init.janet`:

```janet
# Load the cyberpunk theme
(dofile ".gent/skills/configuration/cyberpunk-theme.janet")

# Add productivity features
(dofile ".gent/skills/configuration/productivity.janet")

# Add custom widgets
(dofile ".gent/skills/configuration/custom-widgets.janet")
(register-all-custom-widgets)
(setup-dual-pane-layout)

# Add your own customizations
(import core/tools :as tools)
(tools/register "my-tool" {...})
```

## Configuration Locations

- **`~/.gent/init.janet`** — User-level configuration (affects all projects)
- **`.gent/init.janet`** — Project-level configuration (only this project)
- **Files via `-l`** — Load additional configuration files at startup

## Getting Started

1. Create `~/.gent/init.janet`:
   ```bash
   mkdir -p ~/.gent
   touch ~/.gent/init.janet
   ```

2. Start with the example configuration:
   ```bash
   cp .gent/skills/configuration/example-init.janet ~/.gent/init.janet
   ```

3. Restart gent or use `eval_janet` to test changes

4. Customize to your needs using the comprehensive guide in `SKILL.md`

## Advanced UI Customization

The `custom-widgets.janet` file shows how to:

- Create custom widgets (system monitor, file browser, tabbed interface)
- Design custom layouts (sidebar, dual-pane, monitoring layouts)
- Handle widget events and inter-widget communication
- Build complex interactive UI components

Example widget creation:
```janet
# Load custom widgets
(dofile ".gent/skills/configuration/custom-widgets.janet")

# Register them
(register-all-custom-widgets)

# Use a custom layout
(setup-dual-pane-layout)  # File browser + chat
```

## Testing Configuration

Use the `eval_janet` tool to test configuration code before adding it to your init file:

```
Test this configuration snippet:
(import widgets/chat :as chat)
(chat/set-theme :dark)
```

## Need Help?

- Read `SKILL.md` for quick start and common use cases
- Browse `references/` for detailed topics
- Use `/skill:configuration` to activate the skill
- Use `eval_janet` to test Janet code interactively
- Check `/tools`, `/hooks`, `/skills` to see what's available
- Explore `custom-widgets.janet` for advanced UI examples