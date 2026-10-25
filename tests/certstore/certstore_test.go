package certstoretest

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/tailscale/certstore"
)

const keychainPassword = "certstore-test"

var (
	rootCert *x509.Certificate
	rsaLeaf  *x509.Certificate
	ecLeaf   *x509.Certificate
)

func security(args ...string) (string, error) {
	out, err := exec.Command("/usr/bin/security", args...).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("security %s: %v: %s", strings.Join(args, " "), err, out)
	}
	return string(out), nil
}

func searchList() ([]string, error) {
	out, err := security("list-keychains", "-d", "user")
	if err != nil {
		return nil, err
	}
	var list []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.Trim(strings.TrimSpace(l), `"`); l != "" {
			list = append(list, l)
		}
	}
	return list, nil
}

const keychainName = "certstore-test.keychain"

func withoutTestKeychains(list []string) []string {
	var kept []string
	for _, k := range list {
		if filepath.Base(k) != keychainName {
			kept = append(kept, k)
		}
	}
	return kept
}

func setSearchList(edit func([]string) []string) error {
	list, err := searchList()
	if err != nil {
		return err
	}
	next := edit(list)
	if len(next) == 0 {
		if len(list) != 0 {
			return fmt.Errorf("refusing to empty the search list %v", list)
		}
		return nil
	}
	_, err = security(append([]string{"list-keychains", "-d", "user", "-s"}, next...)...)
	return err
}

func issue(tmpl, parent *x509.Certificate, pub, signer any) *x509.Certificate {
	der, err := x509.CreateCertificate(rand.Reader, tmpl, parent, pub, signer)
	if err != nil {
		panic(err)
	}
	c, err := x509.ParseCertificate(der)
	if err != nil {
		panic(err)
	}
	return c
}

func template(serial int64, cn string, ca bool) *x509.Certificate {
	t := &x509.Certificate{
		SerialNumber:          big.NewInt(serial),
		Subject:               pkix.Name{Organization: []string{"Mavergreen certstore test"}, CommonName: cn},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		BasicConstraintsValid: true,
		IsCA:                  ca,
	}
	if ca {
		t.KeyUsage = x509.KeyUsageCertSign
	} else {
		t.KeyUsage = x509.KeyUsageDigitalSignature
		t.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}
		t.DNSNames = []string{cn}
	}
	return t
}

func writePEM(path, kind string, der []byte) error {
	return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: der}), 0o600)
}

func importInto(keychain, dir, name string, cert *x509.Certificate, key any) error {
	certPath := filepath.Join(dir, name+".crt")
	if err := writePEM(certPath, "CERTIFICATE", cert.Raw); err != nil {
		return err
	}
	if _, err := security("import", certPath, "-k", keychain, "-t", "cert", "-f", "pemseq"); err != nil {
		return err
	}
	if key == nil {
		return nil
	}
	var der []byte
	var kind string
	switch k := key.(type) {
	case *rsa.PrivateKey:
		der, kind = x509.MarshalPKCS1PrivateKey(k), "RSA PRIVATE KEY"
	case *ecdsa.PrivateKey:
		var err error
		if der, err = x509.MarshalECPrivateKey(k); err != nil {
			return err
		}
		kind = "EC PRIVATE KEY"
	}
	keyPath := filepath.Join(dir, name+".key")
	if err := writePEM(keyPath, kind, der); err != nil {
		return err
	}
	_, err := security("import", keyPath, "-k", keychain, "-t", "priv", "-f", "openssl", "-A")
	return err
}

func setUp(dir string) (cleanup func(), err error) {
	rootKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	rootCert = issue(template(1, "certstore-test-root", true), template(1, "certstore-test-root", true), &rootKey.PublicKey, rootKey)
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	rsaLeaf = issue(template(2, "certstore-test-rsa", false), rootCert, &rsaKey.PublicKey, rootKey)
	ecKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	ecLeaf = issue(template(3, "certstore-test-ec", false), rootCert, &ecKey.PublicKey, rootKey)

	keychain := filepath.Join(dir, keychainName)
	if _, err := security("create-keychain", "-p", keychainPassword, keychain); err != nil {
		return nil, err
	}
	cleanup = func() {
		if err := setSearchList(withoutTestKeychains); err != nil {
			fmt.Fprintln(os.Stderr, "remove", keychain, "from the keychain search list by hand:", err)
		}
		security("delete-keychain", keychain)
	}
	if err := setSearchList(func(list []string) []string { return append(withoutTestKeychains(list), keychain) }); err != nil {
		cleanup()
		return nil, err
	}
	if _, err := security("unlock-keychain", "-p", keychainPassword, keychain); err != nil {
		cleanup()
		return nil, err
	}
	for _, imp := range []struct {
		name string
		cert *x509.Certificate
		key  any
	}{{"root", rootCert, nil}, {"rsa", rsaLeaf, rsaKey}, {"ec", ecLeaf, ecKey}} {
		if err := importInto(keychain, dir, imp.name, imp.cert, imp.key); err != nil {
			cleanup()
			return nil, err
		}
	}
	return cleanup, nil
}

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "certstore-test")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	cleanup, err := setUp(dir)
	if err != nil {
		os.RemoveAll(dir)
		fmt.Fprintln(os.Stderr, "setting up a keychain with test identities:", err)
		os.Exit(1)
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		cleanup()
		os.RemoveAll(dir)
		os.Exit(1)
	}()
	code := m.Run()
	signal.Stop(signals)
	cleanup()
	os.RemoveAll(dir)
	os.Exit(code)
}

func identityFor(t *testing.T, want *x509.Certificate) (certstore.Identity, func()) {
	t.Helper()
	store, err := certstore.Open(certstore.User)
	if err != nil {
		t.Fatal(err)
	}
	idents, err := store.Identities()
	if err != nil {
		store.Close()
		t.Fatal(err)
	}
	var found certstore.Identity
	for _, id := range idents {
		if c, err := id.Certificate(); err == nil && c.Equal(want) {
			found = id
		}
	}
	done := func() {
		for _, id := range idents {
			id.Close()
		}
		store.Close()
	}
	if found == nil {
		done()
		t.Fatalf("certstore lists no identity for %q among %d", want.Subject.CommonName, len(idents))
	}
	return found, done
}

func digest(h crypto.Hash, msg []byte) []byte {
	switch h {
	case crypto.SHA256:
		d := sha256.Sum256(msg)
		return d[:]
	case crypto.SHA384:
		d := sha512.Sum384(msg)
		return d[:]
	default:
		d := sha512.Sum512(msg)
		return d[:]
	}
}

var hashes = []crypto.Hash{crypto.SHA256, crypto.SHA384, crypto.SHA512}

func TestRSAPKCS1v15SignatureVerifies(t *testing.T) {
	id, done := identityFor(t, rsaLeaf)
	defer done()
	signer, err := id.Signer()
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range hashes {
		d := digest(h, []byte("signed through certstore"))
		sig, err := signer.Sign(rand.Reader, d, h)
		if err != nil {
			t.Errorf("%v: certstore could not sign with the RSA identity: %v", h, err)
			continue
		}
		if err := rsa.VerifyPKCS1v15(rsaLeaf.PublicKey.(*rsa.PublicKey), h, d, sig); err != nil {
			t.Errorf("%v: certstore's RSA signature is not PKCS#1 v1.5 over the digest: %v", h, err)
		}
	}
}

func TestECDSASignatureVerifies(t *testing.T) {
	id, done := identityFor(t, ecLeaf)
	defer done()
	signer, err := id.Signer()
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range hashes {
		d := digest(h, []byte("signed through certstore"))
		sig, err := signer.Sign(rand.Reader, d, h)
		if err != nil {
			t.Errorf("%v: certstore could not sign with the ECDSA identity: %v", h, err)
			continue
		}
		if !ecdsa.VerifyASN1(ecLeaf.PublicKey.(*ecdsa.PublicKey), d, sig) {
			t.Errorf("%v: certstore's ECDSA signature does not verify over the digest", h)
		}
	}
}

func TestRSAPSSIsRefusedWithErrSecParam(t *testing.T) {
	id, done := identityFor(t, rsaLeaf)
	defer done()
	signer, err := id.Signer()
	if err != nil {
		t.Fatal(err)
	}
	d := digest(crypto.SHA256, []byte("signed through certstore"))
	sig, err := signer.Sign(rand.Reader, d, &rsa.PSSOptions{SaltLength: rsa.PSSSaltLengthEqualsHash, Hash: crypto.SHA256})
	if err == nil {
		if rsa.VerifyPSS(rsaLeaf.PublicKey.(*rsa.PublicKey), crypto.SHA256, d, sig, nil) != nil {
			t.Fatal("certstore returned an RSA-PSS signature that does not verify")
		}
		t.Skip("this macOS signs RSA-PSS; 10.9's Security has no RSA-PSS primitive")
	}
	if !strings.HasPrefix(err.Error(), "CFError -50") {
		t.Fatalf("RSA-PSS on a 10.9 key must fail as Apple's does for an unsupported algorithm (errSecParam, -50); got %v", err)
	}
}

func TestCertificateChainOfAnUntrustedLeaf(t *testing.T) {
	id, done := identityFor(t, rsaLeaf)
	defer done()
	chain, err := id.CertificateChain()
	if err != nil {
		t.Fatalf("certstore needs the chain even when it is untrusted: %v", err)
	}
	if len(chain) != 2 || !chain[0].Equal(rsaLeaf) || !chain[1].Equal(rootCert) {
		var names []string
		for _, c := range chain {
			names = append(names, c.Subject.CommonName)
		}
		t.Fatalf("chain = %v, want [leaf, the root found in the keychain]", names)
	}
}

func TestUntrustedChainIsRejected(t *testing.T) {
	r, err := evaluateSSL(rsaLeaf.Raw)
	if err != nil {
		t.Fatal(err)
	}
	if r.trusted {
		t.Fatal("SecTrustEvaluateWithError trusted a leaf under a root nobody trusts")
	}
	if r.code == 0 || !r.osstatusDomain {
		t.Fatalf("SecTrustEvaluateWithError must say why it refused, in kCFErrorDomainOSStatus; got code %d, OSStatus domain %v", r.code, r.osstatusDomain)
	}
	pool := x509.NewCertPool()
	pool.AddCert(rootCert)
	if _, err := rsaLeaf.Verify(x509.VerifyOptions{Intermediates: pool}); err == nil {
		t.Fatal("crypto/x509's platform verifier trusted a leaf under a root nobody trusts")
	}
}

func TestEmptyChainIsNull(t *testing.T) {
	isNull, err := emptyChainIsNull()
	if err != nil {
		t.Fatal(err)
	}
	if !isNull {
		t.Fatal("SecTrustCopyCertificateChain must return NULL for a trust with no certificates, as Apple's does; certstore then reports \"error getting certificate chain\"")
	}
}
