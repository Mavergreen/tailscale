// Package legacy106 supplies the libSystem symbols a 10.6 (Snow Leopard) floor
// needs beyond what the mavericks-golang toolchain already covers. Go's runtime
// references these only through dynamic-bind entries, which an archive cannot
// satisfy — as cgo C code the implementations land in a relocatable object on
// the link line and win over the dynamic import.
//
// This file is copied into the tailscale source tree (wrksrc/legacy106) by
// build_tailscale.sh and blank-imported from THREE roots, one per
// binary: the peercred patch (ipn/ipnauth — covers tailscaled), the
// systray patch (client/systray — the systray's graph does not reach
// ipn/ipnauth), and the tailscaled patch (cmd/tailscale — the CLI's
// graph does not reach ipn/ipnauth either). All three are needed. The build tag keeps every definition out of non-10.6
// floors: on 10.9 the Security constants below would otherwise statically
// satisfy certstore's references and shadow the REAL Security.framework
// values. build_tailscale.sh adds -tags=darwin_10_6 only for the 10.6 floor.

//go:build darwin_10_6

package legacy106

/*
#cgo LDFLAGS: -framework CoreFoundation -lobjc

#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

// arc4random_buf: 10.7+; real implementation via the ancient arc4random().
extern uint32_t arc4random(void);
__attribute__((used)) void arc4random_buf(void *buf, unsigned long n) {
	unsigned char *p = (unsigned char *)buf;
	while (n > 0) {
		uint32_t r = arc4random();
		unsigned long take = n < 4 ? n : 4;
		for (unsigned long i = 0; i < take; i++) { *p++ = (unsigned char)(r & 0xff); r >>= 8; }
		n -= take;
	}
}

// SecTransform-era Security constants (10.7+) referenced by certstore's C
// code as ordinary undefineds — cgo relocatables resolve them here. The
// transform-based sign path is MDM-only and dormant on a standard tailnet;
// the exact string values only matter if that path ever runs (10.6's
// Security matches dictionary keys by pointer anyway, and it has no
// SecTransform to hand them to).
const void *kSecDigestLengthAttribute      = (const void *)CFSTR("DigestLength");
const void *kSecDigestSHA2                 = (const void *)CFSTR("SHA2");
const void *kSecDigestTypeAttribute        = (const void *)CFSTR("DigestType");
const void *kSecInputIsAttributeName       = (const void *)CFSTR("InputIs");
const void *kSecInputIsDigest              = (const void *)CFSTR("Digest");
const void *kSecTransformInputAttributeName = (const void *)CFSTR("Input");

// ARC runtime entry points (10.7+) that modern clang emits even for
// -fno-objc-arc ObjC (bridging casts, strong-by-default compiler temp
// retention). 10.6's libobjc has objc_msgSend and the GC-era property
// helpers but none of these. Non-ARC semantics via message sends, NULL-safe
// per the ARC contract; the *ReturnValue variants only differ under real
// ARC's return-value optimization, which we cannot trigger from plain C.
typedef void *objc_id;
typedef void *objc_sel;
extern objc_id objc_msgSend(objc_id, objc_sel);
extern objc_sel sel_registerName(const char *);
static objc_id l106_send(objc_id o, const char *n) {
	return ((objc_id (*)(objc_id, objc_sel))objc_msgSend)(o, sel_registerName(n));
}
__attribute__((used)) void   objc_release(objc_id obj)  { if (obj) l106_send(obj, "release"); }
__attribute__((used)) objc_id objc_retain(objc_id obj)  { return obj ? l106_send(obj, "retain") : obj; }
__attribute__((used)) objc_id objc_autorelease(objc_id obj) { return obj ? l106_send(obj, "autorelease") : obj; }
__attribute__((used)) objc_id objc_retainAutoreleasedReturnValue(objc_id obj) { return objc_retain(obj); }
__attribute__((used)) objc_id objc_autoreleaseReturnValue(objc_id obj) { return objc_autorelease(obj); }
__attribute__((used)) void objc_storeStrong(objc_id *loc, objc_id obj) {
	objc_id prev = *loc;
	if (obj) objc_retain(obj);
	*loc = obj;
	if (prev) objc_release(prev);
}

// l106_used is a volatile pointer table referencing every function and
// l106_root writes the address of every shim function and global into
// a volatile pointer (each store is a spec-guaranteed observable side
// effect the compiler cannot eliminate, and each address reference
// prevents linker dead-code elimination of the target section).
// __attribute__((used)) on each function additionally prevents
// compiler-level elimination. A static-initializer array was tried and
// failed: CFSTR globals are not compile-time constants.
static void __attribute__((used)) l106_root(void) {
	void * volatile sink;
	sink = (void *)arc4random_buf;
	sink = (void *)objc_release;
	sink = (void *)objc_retain;
	sink = (void *)objc_autorelease;
	sink = (void *)objc_retainAutoreleasedReturnValue;
	sink = (void *)objc_autoreleaseReturnValue;
	sink = (void *)objc_storeStrong;
	sink = (void *)kSecDigestLengthAttribute;
	sink = (void *)kSecDigestSHA2;
	sink = (void *)kSecDigestTypeAttribute;
	sink = (void *)kSecInputIsAttributeName;
	sink = (void *)kSecInputIsDigest;
	sink = (void *)kSecTransformInputAttributeName;
	(void)sink;
}
*/
import "C"

// init roots every C definition against dead-code elimination: the linker
// strips unreferenced subsections, and nothing else in the binary
// references these (that is the whole point of the package). init() of an
// imported package always survives; the volatile stores in l106_root
// create an unoptimizable reference chain to every shim symbol.
func init() {
	C.l106_root()
}
