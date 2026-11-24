# Contributing

Thanks for helping! Bug reports, ideas and pull requests are welcome — in English, Ukrainian or Russian.

- **Bug?** Open an issue with your Mac model (e.g. *MacBook Pro 13″ M1 2020*), macOS version and a photo of the Touch Bar if it looks wrong.
- **Build:** `./build.sh` (Command Line Tools only). `./build.sh --dmg` also makes the disk image.
- **Previews without a Touch Bar:** `VyshyvkaBar --render out.png`, `--forecast out.png`, `--welcome-window`, `--weather-window`, `--layout-window`.
- **Strings:** every UI string goes through `L.t("українська", "English")`; add the Russian translation to `Sources/Localization.swift`.
- Keep the style: thin linen outlines, embroidery red `#B42D3E`, no emoji in the UI.
