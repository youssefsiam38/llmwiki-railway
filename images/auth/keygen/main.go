// llmwiki-keys: derive Supabase Auth's JWT keys from two template-generated secrets.
//
// LLM Wiki's API and MCP server accept only asymmetrically signed Supabase tokens (ES256), verified
// against Supabase Auth's public JWKS, and MCP clients such as Claude receive such tokens from Supabase
// Auth's OAuth server. Railway can generate random strings for a template, not key pairs, so the P-256
// signing key is derived here from LLMWIKI_SIGNING_KEY_SEED at every start. The same seed always gives
// the same key and key id, so a redeploy never signs anyone out; a new seed rotates the key.
//
// The legacy HS256 secret (JWT_SECRET) is added as a verify-only key: the anon and service-role API
// keys are HS256 tokens signed with it. Supabase Auth never publishes symmetric keys in its JWKS.
//
//	llmwiki-keys jwt-keys   GOTRUE_JWT_KEYS value (private; printed for the entrypoint only)
//	llmwiki-keys jwks       the public JWKS, for tests
//
// Secrets are read from the environment, never from argv.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
)

const derivationLabel = "llmwiki-railway es256 signing key v1"

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "llmwiki-keys: "+format+"\n", args...)
	os.Exit(2)
}

// signingKey derives a valid P-256 scalar: HMAC-SHA256(seed, label || counter), retried in the
// negligible case that the value is zero or not below the group order.
func signingKey(seed []byte) *ecdsa.PrivateKey {
	for counter := byte(0); counter < 16; counter++ {
		mac := hmac.New(sha256.New, seed)
		mac.Write([]byte(derivationLabel))
		mac.Write([]byte{counter})
		if key, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), mac.Sum(nil)); err == nil {
			return key
		}
	}
	fail("could not derive a signing key from LLMWIKI_SIGNING_KEY_SEED")
	return nil
}

func main() {
	if len(os.Args) != 2 || (os.Args[1] != "jwt-keys" && os.Args[1] != "jwks") {
		fail("usage: llmwiki-keys jwt-keys|jwks")
	}
	seedHex := os.Getenv("LLMWIKI_SIGNING_KEY_SEED")
	seed, err := hex.DecodeString(seedHex)
	if err != nil || len(seed) < 32 {
		fail("LLMWIKI_SIGNING_KEY_SEED must be at least 64 hexadecimal characters")
	}
	secret := os.Getenv("JWT_SECRET")
	if len(secret) < 32 {
		fail("JWT_SECRET must be at least 32 characters")
	}

	key := signingKey(seed)
	pub, err := key.PublicKey.Bytes() // 0x04 || X || Y
	if err != nil || len(pub) != 65 {
		fail("could not encode the public key")
	}
	d, err := key.Bytes()
	if err != nil {
		fail("could not encode the private key")
	}
	x, y := b64(pub[1:33]), b64(pub[33:])
	// RFC 7638 thumbprint as the key id: stable, and derived from public material only.
	thumb := sha256.Sum256([]byte(`{"crv":"P-256","kty":"EC","x":"` + x + `","y":"` + y + `"}`))
	kid := b64(thumb[:])

	public := map[string]any{"kty": "EC", "crv": "P-256", "x": x, "y": y, "kid": kid, "alg": "ES256", "use": "sig", "key_ops": []string{"verify"}}
	var out any
	if os.Args[1] == "jwks" {
		out = map[string]any{"keys": []any{public}}
	} else {
		private := map[string]any{"kty": "EC", "crv": "P-256", "x": x, "y": y, "d": b64(d), "kid": kid, "alg": "ES256", "use": "sig", "key_ops": []string{"sign", "verify"}}
		legacy := map[string]any{"kty": "oct", "k": b64([]byte(secret)), "kid": "legacy-hs256", "alg": "HS256", "use": "sig", "key_ops": []string{"verify"}}
		out = []any{private, legacy}
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		fail("could not write the keys")
	}
}
