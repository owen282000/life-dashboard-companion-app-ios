# LD design kit

The A2b look for the iOS redesign. Screens live in `Screens/LD/`, the kit here. The boards are the visual truth; this list says what to reach for.

## Rules of the kit

- Every block carries its own outer margin, as on the boards. Stack blocks directly in `LDScreen`, without extra padding or spacing.
- Labels take a string literal, which lands in the String Catalog. Runtime data and most secondary text take a `Text`: `Text("Grant")`, or `Text(verbatim: host)` for data.
- Colours come from `LDTheme`, fonts from `LDType`. Never a literal, so the Appearance setting keeps working.

## Going somewhere

`LDRoute` lists every pushed page, `LDSheetRoute` every sheet. Both are mapped to screens once, in `LDRoute.swift`.

```swift
// Pushing
LDRow("Advanced", value: Text("Daily totals")).ldLink(to: .advanced)
LDTile("More", subtitle: Text("Backup, about"), systemImage: LDSymbol.more).ldLink(to: .more)
LDButton("Pick what to send", route: .whatToSend)
NavigationLink(value: LDRoute.more) { Text("More") }

// From code, and for sheets
@EnvironmentObject private var navigator: LDNavigator
navigator.push(.logDetail(id: log.id))
navigator.present(.webhookDestination(address: url))

// Something that cannot start while a sheet is up
navigator.dismissSheet { pairing.startScan() }
navigator.dismissSheet { navigator.push(.backfillRun) }
```

A sheet has its own NavigationStack but no route table: it cannot push an `LDRoute`, so close it first as above. Set your own title in your screen: `.navigationTitle` with `.navigationBarTitleDisplayMode(.inline)` on a pushed page, `.navigationTitle` with `.ldSheetToolbar(...)` in a sheet. The root screens of the tabs have no bar. `PairedResultView` is not routed: it belongs inside `PairingSheet`, so its init is free to change. The inits that `LDRoute.swift` calls must stay: `TypeCategoryScreen(category:)`, `BackfillScreen(stage:)`, `WebhookDestinationScreen(address:)`, `LogDetailScreen(logID:)` and every other screen without arguments. `OnboardingFlowView(onFinish:)` is called by the gate in ContentView.

## Layout

| Name | What it does |
| --- | --- |
| `LDScreen(background:content:pinned:footer:)` | The ground and the scrolling. `pinned` sits at the bottom while all fits and scrolls along when it does not. `footer` stays fixed below. `pinned`, `footer` and `background` are optional. In a sheet pass `background: LDTheme.sheet`. A Spacer in `content` does nothing: use `pinned`. |
| `LDFooterBar { }` | The buttons in a `footer`, with the hairline above. Give its buttons `inset: 0`. |
| `LDGap(12)` | Fixed space between blocks. |
| `LDDivider`, `LDHairline` | The two line colours. `LDCard` draws its own dividers. |

## Text

| Name | What it does |
| --- | --- |
| `LDHeading("...")` | 30 bold heading, also takes a `Text`. |
| `LDSectionLabel("...")` | The small label above a card. |
| `LDNote("...", color:, top:, size:)` | Body text: 14 by default, 13 for footnotes, 16 for intros. |

## Cards and rows

| Name | What it does |
| --- | --- |
| `LDCard(bottom:) { }` | Rows on a tile surface, with dividers between them. `if` and `ForEach` are counted per row. |
| `LDRow("Name", subtitle:, value:, valueColor:, showsChevron:)` | 50 high, 62 with a subtitle. Draws only: add `.ldLink(to:)` or `.ldButton { }`. `showsChevron: false` is the plain row. |
| `LDToggleRow("Name", subtitle:, isOn:)` | System Toggle in the accent. |
| `LDFieldRow("Label", text:, prompt:, mono:, isSecure:) { trailing }` | Small label over an editable value. `trailing` is optional, for a reveal button. Keyboard modifiers go on the outside. |
| `LDFieldRow("Label", value: Text(...))` | The same look, read only. |
| `LDDestinationRow(Text, status: Text, statusColor:)` | A destination on Home. Full width, draws only. |
| `LDOption("Title", subtitle:, isSelected:, mark: .radio or .check) { }` | A card to pick, a real button. |
| `LDChevron` | The row chevron. It follows the reading direction. |

## Controls

| Name | What it does |
| --- | --- |
| `LDSegmented(selection:, segments: [LDSegment(value, "Title")])` | The segmented control. |
| `LDChips { LDChip("Essentials", isSelected:) { } }` | Chips that wrap. `LDChip.removable(Text) { }` has an x, `width: 44` is a day chip. |
| `LDButton("Title", kind:, size:, fullWidth:, inset:) { }` | `kind` is `.primary`, `.ghost` or `.danger`, `size` is `.regular`, `.medium` or `.small`. Or `route:` instead of an action. |
| `LDButtonStyle(kind, size:, fullWidth:)` | The same look for your own Link or ShareLink. |
| `LDTextButton("Title") { }` | Text as a button, as Add destination. |
| `LDPressStyle` (`.buttonStyle(.ldPress)`) | Dims on press, for your own Link around a row. |
| `ldButton { }`, `ldLink(to:)` | Make a row, tile or destination row tappable. |
| `ldSheetToolbar(cancel:, confirm:, canConfirm:, onCancel:, onConfirm:)` | Cancel and Save in a sheet, both close it. `cancel: "Done"` when there is nothing to save. |

## Showing things

| Name | What it does |
| --- | --- |
| `LDBanner("Title", message:) { LDBannerAction("Fix") { } }` | The warning card, actions optional. |
| `LDKeyValueList([LDKeyValue("Key", Text(...), color:)])` | Labels and Space Mono values on a card. |
| `LDCodeBlock(text:, color:)` | Text as it is in Space Mono, long lines scroll sideways. |
| `LDProgressBar(value:)` | The 8 high bar of a backfill. Give it an `accessibilityLabel`. |
| `LDTile("Title", subtitle:, systemImage:)` | Draws only, add `.ldLink(to:)` or `.ldButton { }`. Names of the symbols are in `LDSymbol`. |
| `LDTileGrid { }` | Two columns, equal height per row. Goes in `pinned`. |

## Line and motion

| Name | What it does |
| --- | --- |
| `PulseLine(variant: .normal, .warning or .flat)` | The heartbeat from the left screen edge. Draws in on appear. |
| `SparkLine(values:, color:, height:)` | A series ending in a dot. Empty without values. |
| `PulseProgress(step:, of:)` | The onboarding line, draws on from the previous step. |
| `ldStaggerRise(index)` | Rises and fades in on appear, with `index` as its place in the stagger. |
| `ldTabEnter()` | The slide of a tab switch. ContentView already sets it on each tab's root screen. |
| `@Environment(\.ldTabDirection)` | `.forward`, `.backward` or `.none`: back to none 350 ms after the switch. |

All motion is off with Reduce Motion.

## Fonts

`Fonts/` holds Space Grotesk Regular, Medium and Bold, Space Mono Regular and Bold, and each family's OFL licence, all in the app bundle. Space Mono is as it comes from github.com/google/fonts. That repo has Space Grotesk only as a variable font, whose named instances have no PostScript names of their own, so the three static files are made from it:

```
fonttools varLib.instancer "SpaceGrotesk[wght].ttf" wght=700 --update-name-table -o SpaceGrotesk-Bold.ttf
```

Use the names in `LDFontName` through `LDType`. `LDKitTests` fails when a name stops resolving.

Space Grotesk's natural line height is 1.276 times its size. The heading's 34 points is tighter than that, so lines of a heading after the first are 4 points further apart than on the board.
