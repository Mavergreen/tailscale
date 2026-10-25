package certstoretest

/*
#cgo CFLAGS: -Werror=implicit-function-declaration
#cgo LDFLAGS: -framework CoreFoundation -framework Security
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

static OSStatus evaluate(const UInt8 *der, CFIndex len, Boolean *trusted, CFIndex *code, Boolean *osstatusDomain) {
	CFDataRef data = CFDataCreate(kCFAllocatorDefault, der, len);
	SecCertificateRef cert = data ? SecCertificateCreateWithData(kCFAllocatorDefault, data) : NULL;
	SecPolicyRef policy = SecPolicyCreateSSL(true, NULL);
	SecTrustRef trust = NULL;
	CFErrorRef error = NULL;
	OSStatus s = cert && policy ? SecTrustCreateWithCertificates(cert, policy, &trust) : errSecParam;
	if (s == errSecSuccess) {
		*trusted = SecTrustEvaluateWithError(trust, &error);
		*code = error ? CFErrorGetCode(error) : 0;
		*osstatusDomain = error ? CFEqual(CFErrorGetDomain(error), kCFErrorDomainOSStatus) : false;
	}
	if (error) CFRelease(error);
	if (trust) CFRelease(trust);
	if (policy) CFRelease(policy);
	if (cert) CFRelease(cert);
	if (data) CFRelease(data);
	return s;
}

static OSStatus emptyChain(Boolean *isNull) {
	CFArrayRef none = CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
	SecPolicyRef policy = SecPolicyCreateBasicX509();
	SecTrustRef trust = NULL;
	OSStatus s = SecTrustCreateWithCertificates(none, policy, &trust);
	if (s == errSecSuccess) {
		CFArrayRef chain = SecTrustCopyCertificateChain(trust);
		*isNull = chain == NULL;
		if (chain) CFRelease(chain);
		CFRelease(trust);
	}
	CFRelease(policy);
	CFRelease(none);
	return s;
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

type trustResult struct {
	trusted        bool
	code           int
	osstatusDomain bool
}

func evaluateSSL(der []byte) (trustResult, error) {
	var trusted, domain C.Boolean
	var code C.CFIndex
	s := C.evaluate((*C.UInt8)(unsafe.Pointer(&der[0])), C.CFIndex(len(der)), &trusted, &code, &domain)
	if s != 0 {
		return trustResult{}, fmt.Errorf("SecTrustCreateWithCertificates: OSStatus %d", s)
	}
	return trustResult{trusted: trusted != 0, code: int(code), osstatusDomain: domain != 0}, nil
}

func emptyChainIsNull() (bool, error) {
	var isNull C.Boolean
	if s := C.emptyChain(&isNull); s != 0 {
		return false, fmt.Errorf("SecTrustCreateWithCertificates: OSStatus %d", s)
	}
	return isNull != 0, nil
}
