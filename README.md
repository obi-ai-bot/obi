# Oby

Oby is Deskree's assistant for developers, with Oby the character as its face. macOS first, then iOS, then watchOS.

```
Oby.xcodeproj    the app (SwiftUI)
Oby/             app sources
Character/       Oby the character, published from the dev branch (see Character/README.md)
```

Open `Oby.xcodeproj` in Xcode 27 and run the `Oby` scheme on "My Mac".

## Branches

- `main`: the app. Changes land through pull requests.
- `dev`: Sangam's working copy of the character. `dev`'s `publish.sh` builds the package and opens a pull request that updates `Character/` on `main`.
