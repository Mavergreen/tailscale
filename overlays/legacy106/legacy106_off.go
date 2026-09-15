//go:build !darwin_10_6

// Placeholder for non-10.6 floors: every real definition in this package is
// darwin_10_6-tagged (see legacy106.go for why), but a package with zero
// buildable files is an import error -- so the blank imports in the patched
// upstream files need this file to exist on every floor.
package legacy106
