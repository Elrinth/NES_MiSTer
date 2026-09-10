# Compiled core distribution review — 2026-09-10

The repository's [COPYING](COPYING) contains GNU GPL version 3. It permits
modified source and object-code distribution subject to its conditions. For an
online RBF release, sections 4–6 require retaining notices, identifying changes,
supplying the license and offering the corresponding source with equivalent
access alongside the binary. A release tag must identify the actual sources,
including project and build files. See the [official GPLv3 text](https://www.gnu.org/licenses/gpl-3.0.html).

## Unresolved inherited license interaction

The complete core has additional third-party notices:

- [T65](rtl/t65/T65.vhd) permits synthesized redistribution, requiring its
  copyright, conditions and disclaimer in accompanying documentation/materials.
- [VRC7's eseopll wrapper](rtl/SOUND/OPLL/eseopll.vhd) and
  [VM2413](rtl/SOUND/OPLL/VM2413/opll.vhd) prohibit sale and commercial
  product/activity use without prior written permission (condition 3). Binary
  redistribution also requires the copyright, conditions and disclaimer.
- That OPLL code is included by [files.qip](files.qip) and
  [OPLL.qip](rtl/SOUND/OPLL/OPLL.qip), and instantiated by
  [VRC.sv](rtl/mappers/VRC.sv). It is not an unused reference file.
- Altera-generated PLL files, such as [pll_audio.v](sys/pll_audio.v), retain
  separate vendor notices restricting use to Altera PLDs. The target MiSTer
  DE10-Nano uses an Altera/Intel Cyclone V; preserve these notices.

The OPLL condition adds a restriction relative to GPLv3's downstream freedoms
(section 10). Making the download free does not by itself resolve this license
compatibility question for the combined core. No applicable exception or extra
permission was established in this review. This is not a finding that every
upstream distribution is unlawful; the top-level GPL label alone does not
establish clearance for this new combined binary release.

This fork is distributed as a free download with matching source and inherited
license notices, following upstream's practice of publishing compiled RBF files:
[upstream RBF directory](https://github.com/MiSTer-devel/NES_MiSTer/tree/master/releases).
That practice does not itself resolve the license interaction described above.
No third-party terms have been removed or relicensed, and this note does not
claim legal clearance for every downstream use. Commercial redistribution in
particular must account for the OPLL restriction.

Release materials include the tested RBF, SHA-256, matching source archive,
COPYING, third-party notices and build/install instructions. Official test ROMs
are linked rather than bundled in the release package. This review concerns
the core, not separate game artwork, audio or ROMs.
