# Build and install the Rainbow mapper 682 core

Release: mapper682-20260911 (2026-09-11).

This is an unofficial derivative of MiSTer-devel/NES_MiSTer, based on FPGANES
by Ludvig Strigeus. Upstream authors' copyright and license notices are retained.
The release includes the Rainbow banking, VRC6 audio, IRQ, scrolling and extended
sprite changes in this branch. The final sprite correction aligns both bitplane
fetches with the original sprite OAM index and includes PPU dot 320.

## Install

Copy NES_RAINBOW_20260911.rbf to the MiSTer SD card's _Console folder
(or another core folder beneath /media/fat). Select that core and load your
Rainbow mapper 682 ROM from games/NES. No compilation is required.
Use Extra Sprites: Off when comparing with Mesen's normal NES sprite limit.

## Build from source

Use the source archive accompanying this release, or check out the release tag:

```sh
git clone --branch mapper682-20260911 https://github.com/Elrinth/NES_MiSTer.git
cd NES_MiSTer
quartus_sh --flow compile NES
```

Use Intel/Altera Quartus Prime Lite 17.0 with Cyclone V device support. The build
used the theypsilon/quartus-lite-c5:17.0 Docker environment. NES.qsf sets seed 6;
the generated binary is output_files/NES.rbf. Quartus must be on PATH in the
build environment. The vendor toolchain is obtained separately, not bundled.
No Git submodules are required. Timing must pass before distributing a rebuild;
the supplied RBF's recorded minimum slack is +0.175 ns with zero TNS.
Different tool environments may produce a different binary hash.

The matching core-source hashes and timing report are in releases/mapper682-20260911/.
Regression instructions and their scope are in tests/mapper682/README.md.
The user confirmed expected hardware results, including original Vector Redirect.
This does not claim every Rainbow feature or all possible games were validated.

Window Split overwrites CHR RAM test signatures. Reload the test ROM before
running CHR RAM after Window Split; the subsequent failure is a test interaction.

See COPYING, THIRD_PARTY_NOTICES.txt and DISTRIBUTION.md for inherited terms.

The internal name is NES_RAINBOW. MiSTer uses NES_RAINBOW.CFG and defaults
to games/NES_RAINBOW. Existing files are not moved; browse to games/NES if needed.
This renamed rebuild passed timing but has not yet been tested on physical MiSTer.
It does not change scrolling logic.
