# bezier

arc, rebuilt in swift for macos.

![onboarding](docs/onboarding.png)

## about

tabs live in a sidebar, grouped into spaces, with a command bar, split view and mini windows for links from other apps. no accounts, no sync.

it runs on webkit for now. chromium comes next.

## install

needs macos 14 or later and xcode 26. liquid glass shows up on macos 26.

```sh
scripts/build.sh release
open build/Bezier.app
```

coming from arc? settings › import brings over your spaces, pinned tabs and history.

## develop

```sh
scripts/build.sh
swift test
```

## status

early. [roadmap](ROADMAP.md) tracks what works and what doesn't.
