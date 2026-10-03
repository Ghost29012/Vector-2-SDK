# Vector 2 SDK

A level editor and modding toolkit for Vector 2, made by Ghost29012 (ghosted).

The idea is pretty simple: make custom rooms and project content without having
to write every bit of XML by hand. You can still edit the XML directly when you
want to.

## What's in here

- A room editor for placing and editing level objects.
- Trigger tools and a local, model-free XML assistant with repair previews.
- Project Manager for organizing custom game content.
- Tools for traps, characters, models, animations, and other project content.

The game-side Unity project is here:
[Vector 2 Mod Unity Project](https://github.com/Ghost29012/Vector-2-Mod-Unity-Project).

## Running it

Grab the macOS app from [Releases](https://github.com/Ghost29012/Vector-2-SDK/releases).
The editor needs macOS 14 or newer.

To build from source, open `Vector2 level editor.xcodeproj` in Xcode, select the
`Vector2 level editor` scheme, and build for your Mac. Use your own signing
settings if you want a signed build.

## Backgrounds in this release

The per-room Background Designer in Tools is disabled for now.
The Project Manager background-pool designer is still available.

## License and credits

Original work made for this project uses the
[Vector 2 SDK Non-Commercial License](LICENSE.md).

Vector 2 and its original game assets belong to Nekki. This is an unofficial fan
project, not a Nekki release. Existing third-party credits and licenses still
apply to their respective code and assets.
