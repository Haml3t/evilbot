# Game streaming (gpu-desktop -> laptop)

Hand-configured on the operator's machines, outside Ansible/Terraform. Recorded
here so the setup can be rebuilt. Personal machines are not infrastructure (see
`fleet/inventory.yaml`), so this is a how-to rather than managed state.

## Host: gpu-desktop (Ubuntu 22.04, RTX 3090, X11/i3)

- **Sunshine** `2026.914.233613`, installed from the GitHub release `.deb`
  (`sunshine_<ver>-1+ubuntu22.04_amd64.deb`). There is no apt repo, so
  `apt upgrade` never updates it. To update:
  ```
  systemctl --user stop app-dev.lizardbyte.app.Sunshine.service
  sudo apt install ./sunshine_<ver>-1+ubuntu22.04_amd64.deb
  systemctl --user start app-dev.lizardbyte.app.Sunshine.service
  ```
  Use `apt install ./file.deb`, not `dpkg -i`, so new dependencies are pulled in.
- Runs as a **user** service: `app-dev.lizardbyte.app.Sunshine.service`,
  enabled under `graphical-session.target`. Capture is NvFBC, encode is
  h264/hevc NVENC (the 3090 has no AV1 encode).
- Config, credentials hash, paired clients and the app list live in
  `~/.config/sunshine/` (`sunshine.conf`, `sunshine_state.json`, `apps.json`).
  Package upgrades don't touch them. The web UI is at https://localhost:47990.
  Credentials are set by the operator; to reset them:
  `sunshine --creds <user> <pass>` with the service stopped.
- **Required setting:** `system_tray = disabled` in `sunshine.conf`.
  2026.914 aborts (SIGABRT, core dump) right after "Starting system tray" on
  this i3 session. After 5 crashes systemd stops restarting it; clear that with
  `systemctl --user reset-failed app-dev.lizardbyte.app.Sunshine.service`.
- Rollback: install the previous `.deb` with `sudo apt install --allow-downgrades`.
- **Firewall (ufw)**, LAN only:
  ```
  sudo ufw allow from 192.168.0.0/24 proto tcp to any port 47984,47989,48010 comment sunshine
  sudo ufw allow from 192.168.0.0/24 proto udp to any port 47998:48000 comment sunshine
  ```
  The web UI port 47990 is deliberately not opened.
- **Minecraft (Java):** Prism Launcher as a **system** flatpak
  (`flatpak install flathub org.prismlauncher.PrismLauncher`). Flathub is a
  system-wide remote on this machine, so `--user` installs fail with "No remote
  refs found". Instance `Minecraft` = Fabric + **Fabric API** + **Controlify**
  (controller support; Java edition has none built in).
  Sunshine app command: `flatpak run org.prismlauncher.PrismLauncher --launch Minecraft`.
- Other Sunshine apps (Steam, PS3 emulator) were set up earlier and live in `apps.json`.
- **VRAM:** vLLM (donnertune) holds about 21.7 of 24 GB. Unmodded Minecraft plus
  the encoder fit in what's left; shaders won't. Stop vLLM while playing if needed.

## Client: laptop (Ubuntu 22.04, Intel HD 620)

- Moonlight is a **per-user** flatpak (`com.moonlight_stream.Moonlight`), so the
  `hermes` account can't see it. Update with
  `flatpak update --user com.moonlight_stream.Moonlight`. 1080p60 with hardware
  decoding (VA-API) is the right ceiling for this iGPU.
- Xbox controller goes through the Microsoft wireless dongle with the **xone**
  DKMS driver (0.5.8, `xone_dongle`/`xone_gip`). DKMS rebuilds it on kernel
  updates; check with `dkms status`. Moonlight passes the controller through and
  Sunshine presents it to the host as a virtual Xbox One pad (udev rules from the
  Sunshine package grant `/dev/uinput` access).
