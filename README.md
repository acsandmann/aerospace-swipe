# aerospace workspace switching with trackpad swipes

aerospace-swipe detects x-fingered(defaults to 3) swipes on your trackpad and correspondingly switches between [aerospace](https://github.com/nikitabobko/AeroSpace) workspaces.

## features
- fast swipe detection and forwarding to aerospace (uses aerospace server's socket instead of cli)
- works with any number of fingers (default is 3, can be changed in config)
- skips empty workspaces (if enabled in config)
- ignores your palm if it is resting on the trackpad
- haptics on swipe (this is off by default)
- customizable swipe directions (natural or inverted)
- swipe will wrap around workspaces (ex 1-9 workspaces, swipe right from 9 will go to 1)
- utilizes [yyjson](https://github.com/ibireme/yyjson) for performant json ser/de

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
### script
```bash
curl -sSL https://raw.githubusercontent.com/acsandmann/aerospace-swipe/main/install.sh | bash
```
### manual
   ```bash
   git clone https://github.com/acsandmann/aerospace-swipe.git
   cd aerospace-swipe

   make install # installs a launchd service
   ```
## uninstallation
### script
```bash
curl -sSL https://raw.githubusercontent.com/acsandmann/aerospace-swipe/main/uninstall.sh | bash
```
### manual
```bash
make uninstall
```
