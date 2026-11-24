# Release notes

The generator (`release-notes.sh`, from mavericks-shipyard) writes the notes file for every
release: the title, a "What changed" section (a new-upstream link, or a repackage/packaging-only
line), a "Build ingredients" section when a pin moved, and the footer. That file becomes both the
Sparkle appcast `<description>` and the GitHub Release body -- the same bytes, read twice.

What a release says beyond that is files, one sentence each, under `release-notes/<full-version>/`
(e.g. `release-notes/1.104.7-mavericks.12/changes/standalone-archive`): `changes/<slug>`, one per
user-visible change, ordered by slug. `notice` here is the standing first line of every release's
footer. Every one of them must pass shipyard's `check-release-sentence.sh`.

Most releases have no directory here at all, and that's fine: the generator's own sections are the
whole note. A tag pushed by hand (as opposed to a dispatch-cut auto-release) still requires at least
one `changes/` sentence before release.yml will build it -- see the version-decision step in
`.github/workflows/release.yml`.
