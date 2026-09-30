---
name: Orchard Twilight & Tactile Utility
colors:
  surface: '#fbf9f6'
  surface-dim: '#dbdad7'
  surface-bright: '#fbf9f6'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f5f3f0'
  surface-container: '#efeeeb'
  surface-container-high: '#eae8e5'
  surface-container-highest: '#e4e2df'
  on-surface: '#1b1c1a'
  on-surface-variant: '#4f444a'
  inverse-surface: '#30312f'
  inverse-on-surface: '#f2f0ed'
  outline: '#81737a'
  outline-variant: '#d3c2c9'
  surface-tint: '#814e6f'
  primary: '#310927'
  on-primary: '#ffffff'
  primary-container: '#4a1f3d'
  on-primary-container: '#be85a8'
  inverse-primary: '#f3b4da'
  secondary: '#44664d'
  on-secondary: '#ffffff'
  secondary-container: '#c3e9ca'
  on-secondary-container: '#486a51'
  tertiary: '#2b1400'
  on-tertiary: '#ffffff'
  tertiary-container: '#482600'
  on-tertiary-container: '#d28432'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#ffd8ed'
  primary-fixed-dim: '#f3b4da'
  on-primary-fixed: '#340b29'
  on-primary-fixed-variant: '#663756'
  secondary-fixed: '#c6eccd'
  secondary-fixed-dim: '#aad0b1'
  on-secondary-fixed: '#00210e'
  on-secondary-fixed-variant: '#2d4e37'
  tertiary-fixed: '#ffdcc0'
  tertiary-fixed-dim: '#ffb875'
  on-tertiary-fixed: '#2d1600'
  on-tertiary-fixed-variant: '#6b3b00'
  background: '#fbf9f6'
  on-background: '#1b1c1a'
  surface-variant: '#e4e2df'
typography:
  headline-xl:
    fontFamily: Newsreader
    fontSize: 2.25rem
    fontWeight: '400'
    lineHeight: 2.75rem
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Newsreader
    fontSize: 1.75rem
    fontWeight: '400'
    lineHeight: 2.25rem
    letterSpacing: -0.015em
  headline-md:
    fontFamily: Newsreader
    fontSize: 1.375rem
    fontWeight: '500'
    lineHeight: 1.75rem
    letterSpacing: -0.01em
  headline-sm:
    fontFamily: Newsreader
    fontSize: 1.125rem
    fontWeight: '500'
    lineHeight: 1.5rem
    letterSpacing: 0em
  body-lg:
    fontFamily: Manrope
    fontSize: 1rem
    fontWeight: '400'
    lineHeight: 1.5rem
    letterSpacing: -0.005em
  body-md:
    fontFamily: Manrope
    fontSize: 0.875rem
    fontWeight: '400'
    lineHeight: 1.375rem
    letterSpacing: 0em
  body-sm:
    fontFamily: Manrope
    fontSize: 0.8125rem
    fontWeight: '400'
    lineHeight: 1.25rem
    letterSpacing: 0.005em
  label-md:
    fontFamily: Manrope
    fontSize: 0.75rem
    fontWeight: '600'
    lineHeight: 1rem
    letterSpacing: 0.02em
  label-sm:
    fontFamily: Manrope
    fontSize: 0.6875rem
    fontWeight: '600'
    lineHeight: 0.875rem
    letterSpacing: 0.04em
  code-sm:
    fontFamily: JetBrains Mono
    fontSize: 0.75rem
    fontWeight: '400'
    lineHeight: 1.125rem
    letterSpacing: 0em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  gutter: 1rem
  gutter-compact: 0.75rem
  margin: 1.5rem
  margin-window: 1.25rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 0.875rem
  space-lg: 1.25rem
  space-xl: 1.75rem
---

## Brand & Style

This design system establishes a focused, desktop-first sensory experience that merges classic editorial warmth with native macOS precision. It rejects disposable SaaS patterns in favor of artisan desk-software craftsmanship: a serene twilight orchard atmosphere where local filesystem maintenance feels like curating an archival library rather than running a clinical terminal script.

The visual direction centers on:
- **Warm Editorial Minimalism**: Soft stone surfaces, generous internal gutters, literary serif titles, and balanced proportions that prioritize calm focus over aggressive urgency.
- **Physical Desktop Craft**: Subtle hairline borders, translucent frosted sidebars, tactile button depressions, and meticulous spatial alignment designed for fixed-canvas and split-view native utility windows.
- **Literary Restraint**: High contrast ink typography grounded on creamy, low-strain paper surfaces, evoking quiet concentration, artisanal tools, and lasting durability.

## Colors

The palette draws directly from the dimming light of an autumnal orchard, pairing deep, saturated plum pigments with grounded botanical greens, amber warns, and warm limestone surfaces.

### Semantic Tiers
- **Primary (`#4A1F3D`)**: Deep Damson Aubergine. Used for core actions, selected active states, focused indicators, and prominent decorative glyphs.
- **Secondary (`#496B52`)**: Orchard Leaf Green. Signifies successful reclamation, safe-to-prune verification, healthy volume partitions, and constructive milestones.
- **Tertiary (`#D98A38`)**: Spiced Amber. Applied strictly to cautionary actions, irreversible purge warnings, orphaned symbolic links, and pending space thresholds.
- **Neutral Base (`#FAF8F5`)**: Pale Orchard Stone. Serves as the primary canvas backing, creating a luminous, paper-like surface that avoids the harshness of stark digital white.

### Functional Substrates & Accents
- **Canvas Subsurface**: `#F4EFEB` (Muted Linen) for recessed panels, sidebar backgrounds, and grouped list containers.
- **Ink Primary**: `#1C181E` (Black Aubergine) providing optical depth for body text and high-priority metadata.
- **Ink Secondary**: `#6B6069` (Muted Twilight) for file paths, structural timestamps, and secondary captions.
- **Borders & Dividers**: `#E6DFD5` (Warm Hairline) calibrated to 1px optical weight for structural framing without visual clutter.
- **Mauve Accent**: `#9E778E` (Dusty Plum) used for subtle interactive hover backings, non-critical tags, and inactive file badge indicators.

## Typography

The typographical voice balances literary contemplation with mechanical inspection. 

- **Headings (`Newsreader`)**: Set with optical sizing and delicate serifs. Headings bring an editorial tempo to disk inspection, presenting system stats and drive partitions as curated volumes. Use normal or medium weights; avoid heavy bolding to preserve the calligraphic stroke contrast.
- **Body & Controls (`Manrope`)**: Provides a modern, geometric counterpart with humanist open apertures. Its clean geometry guarantees immediate legibility for complex paths, byte units, and dense file trees.
- **Monospace Code (`JetBrains Mono`)**: Reserved strictly for raw POSIX paths, disk hashes, terminal log views, and regex patterns. Set at slightly diminished optical scales to nest comfortably beside `Manrope` metadata.

## Layout & Spacing

Layout geometry follows standard dual-pane and three-pane macOS application architectures, tailored to a standard baseline window frame of 900x650 pixels.

### Grid & Composition
- **Structural Master Split**: A 220px–260px translucent primary sidebar anchored to the left, paired with an adaptable flexible canvas pane on the right.
- **Inner Content Rhythm**: A strict 8-point base module drives all layouts, with a 4-point micro-step for compact list structures and macOS toolbar items.
- **Gutter Distribution**: Internal panels, cards, and inspector inspectors maintain a `1rem` (`16px`) gutter to create clear spatial distinctions between drives, candidate groups, and metadata breakdowns.

### Window & Screen Adaptation
- **Desktop Utility Fixed/Scalable Canvas (Default 900x650)**: Sidebar maintains standard Apple HIG metrics with window control chrome (traffic lights) padded at `space-md` (`14px`) top-left. Margins within active panes settle at `margin-window` (`20px`).
- **Compact View (Below 768px)**: The navigation sidebar collapses into a floating popover or top-mounted segmented tool strip, dropping margins to `space-md` and gutters to `gutter-compact` (`12px`) for uncompromised path inspection.

## Elevation & Depth

This design system eschews theatrical, dramatic drop shadows in favor of quiet, physical Apple platform craftsmanship: layered materials, hairline borders, and subtle ambient occlusions.

### Depth Mechanics
1. **Window Surface (Base Level)**: Solid `#FAF8F5` representing the physical desktop foundation.
2. **Sidebars & Accessory Bars (Recessed / Frosted Level)**: Tinted glass with a backing color of `#F4EFEB` rendered with `backdrop-filter: blur(24px) saturate(180%)` and a 1px solid trailing border in `#E6DFD5`.
3. **Cards & Group Containers (Sub-surface Tier)**: Raised using tonal contrast (`#FFFFFF` in light mode) over the stone canvas, framed by a delicate border (`#E6DFD5`) with an ambient shadow: `0 1px 3px rgba(28, 24, 30, 0.04), 0 1px 2px rgba(28, 24, 30, 0.02)`.
4. **Active Modals & Floating Inspectors**: Floated above the work plane using a plum-tinted ambient occlusion: `0 12px 32px rgba(74, 31, 61, 0.08), 0 2px 6px rgba(28, 24, 30, 0.04)` enclosed with an edge highlight border (`rgba(255, 255, 255, 0.6)` inset).
5. **Physical Insets**: Search fields, terminal viewports, and table tracks use an inset micro-shadow (`inset 0 1px 2px rgba(28, 24, 30, 0.05)`) paired with surface tone `#EFE8DE`.

## Shapes

The curvature language conforms to level `2` (Rounded), mirroring contemporary macOS window conventions and balanced tactile controls.

- **Window Chrome**: Outer window frames use `12px` to `16px` corner curvature (`rounded-lg` / `rounded-xl`).
- **Cards & Data Groups**: Standard containers and modal sheets utilize `0.5rem` (`8px`) corners.
- **Buttons, Text Inputs, and Segmented Pickers**: Standard control targets use `0.375rem` (`6px`) to `0.5rem` (`8px`) radii, providing a defined, squircle-like physical boundary.
- **Status Tags & Micro Indicators**: File category badges and item counts scale from `0.25rem` (`4px`) up to fully pill-shaped counters for numeric flags.

## Components

### Buttons
- **Primary Action (Prune / Commit)**: Fill of `#4A1F3D` with `#FAF8F5` text, subtle top-edge bevel highlight (`inset 0 1px 0 rgba(255, 255, 255, 0.15)`), and 0.5rem roundedness. Hover darkens to `#3D1932`; active state triggers a 0.5px downward scale shift.
- **Secondary / Ghost**: Transparent or `#FFFFFF` container with a 1px solid `#E6DFD5` border, ink text `#1C181E`, and hover state tinting to `#F4EFEB`.
- **Destructive**: Tonal background `#FBF0EB` with deep amber-red typography (`#B84824`), escalating to solid warning states during confirmation sequences.

### Lists & File Rows
- **Dense Row Layout**: Height set to 32px or 36px. Alternating row fills are avoided; selections are signaled with a soft plum wash (`#FAF1F6`) framed by a 1px rounded highlight.
- **Typography Matrix**: Primary file name rendered in `Manrope 13px weight 500` (`#1C181E`), directory path trailing in `JetBrains Mono 11px` (`#6B6069`), and disk footprint right-aligned in `Manrope 12px weight 600`.

### Form Inputs & Filters
- **Text & Path Bars**: Inset surface `#F4EFEB` with a 1px border `#E6DFD5`. Focused state transitions border to `#4A1F3D` with a soft plum halo (`box-shadow: 0 0 0 3px rgba(74, 31, 61, 0.12)`).
- **Segmented Control**: Pill or rounded-sm enclosure with a sunken gutter (`#EDE6DC`), featuring a sliding thumb tab (`#FFFFFF`) backed by a crisp 0.5px border and micro-drop shadow.

### Checkboxes & Selection Controls
- **Checkboxes**: 14x14px square with 3px border radius. Unchecked state: `#FFFFFF` with `#D5CCC0` border. Checked state: Solid `#4A1F3D` fill with crisp white vector checkmark.

### Cards & Metrics Summaries
- **Storage Tier Breakdown**: `#FFFFFF` background with an `#E6DFD5` border. Features an editorial display header in `Newsreader` (e.g., "34.8 GB Purgeable") accented by an amber or plum storage bar meter.
- **Quick Action Tiles**: Square ratio cards with centered icons, subtle hover lift, and clear metadata counts below.

### Visual Window Accents
- **macOS Window Bar**: Integrated header layout (unified toolbar) housing traffic lights (close, minimize, zoom) separated by 8px, followed by an editorial center-title and discrete right-aligned utilities.