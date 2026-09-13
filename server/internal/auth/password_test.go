package auth

import (
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestPasswordHasherHashesAndVerifiesWithoutStoringPlaintext(t *testing.T) {
	t.Parallel()

	hasher, err := NewPasswordHasher(bcrypt.MinCost)
	if err != nil {
		t.Fatalf("NewPasswordHasher() error = %v", err)
	}
	password := "correct horse battery staple"
	hash, err := hasher.Hash(password)
	if err != nil {
		t.Fatalf("Hash() error = %v", err)
	}
	if hash == password || !strings.HasPrefix(hash, "$2") {
		t.Fatalf("hash = %q, want bcrypt material distinct from password", hash)
	}
	if !hasher.Verify(hash, password) {
		t.Error("Verify() rejected the original password")
	}
	if hasher.Verify(hash, "wrong password") {
		t.Error("Verify() accepted the wrong password")
	}
}

func TestPasswordHasherRejectsUnsupportedPasswordInputs(t *testing.T) {
	t.Parallel()

	hasher, err := NewPasswordHasher(bcrypt.MinCost)
	if err != nil {
		t.Fatalf("NewPasswordHasher() error = %v", err)
	}
	if _, err := hasher.Hash(""); err != ErrPasswordEmpty {
		t.Errorf("Hash(empty) error = %v, want ErrPasswordEmpty", err)
	}
	if _, err := hasher.Hash(strings.Repeat("x", MaxPasswordBytes+1)); err != ErrPasswordTooLong {
		t.Errorf("Hash(too long) error = %v, want ErrPasswordTooLong", err)
	}
	if hasher.VerifyDummy("not a secret that should be stored") {
		t.Error("VerifyDummy() accepted an unrelated password")
	}
}
