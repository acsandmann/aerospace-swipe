# aerospace workspace switching with trackpad swipes

This project uses an undocumented macOS framework (`MultitouchSupport.framework`) to detect three-finger swipes on your trackpad and switch between workspaces (using the `aerospace` tiling window manager).

## features
- fast swipe detection and forwarding to aerospace (uses aerospace server's socket instead of cli)
- haptics on swipe (must be enabled in configuration)
- customizable swipe directions (natural or inverted)
- swipe will wrap around workspaces (1-9 workspaces, swipe right from 9 will go to 1)

## configuration
config file is optional and only needed if you want to change the default settings(default settings are shown in the example below)

> to restart after changing the config file, run `make restart`(this just unloads and reloads the launch agent)

```jsonc
// ~/.config/aerospace-swipe/config.json
{
  "haptic": false,
  "natural_swipe": false,
  "wrap_around": true,
  "skip_empty": true,
  "fingers": 3
}
```

## installation

   ```bash
   git clone https://github.com/acsandmann/aerospace-swipe.git
   cd aerospace-swipe

   make install
   ```
## uninstallation

   ```bash
   make uninstall
   ```
