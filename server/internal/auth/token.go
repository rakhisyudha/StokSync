package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
)

const (
	accessTokenAlgorithm = "HS256"
	accessTokenType      = "JWT"
	accessTokenUse       = "access"
	accessTokenClockSkew = 30 * time.Second
)

var ErrInvalidAccessToken = errors.New("invalid access token")

// AccessClaims is the validated identity carried by an access token.
type AccessClaims struct {
	UserID    uuid.UUID
	DeviceID  uuid.UUID
	ID        uuid.UUID
	IssuedAt  time.Time
	ExpiresAt time.Time
	Issuer    string
	Audience  string
}

// TokenManager signs and validates short-lived access JWTs. The secret is
// copied and never exposed through the public API.
type TokenManager struct {
	secret   []byte
	issuer   string
	audience string
	ttl      time.Duration
	now      func() time.Time
}

type jwtHeader struct {
	Algorithm string `json:"alg"`
	Type      string `json:"typ"`
}

type jwtPayload struct {
	Issuer   string `json:"iss"`
	Audience string `json:"aud"`
	Subject  string `json:"sub"`
	DeviceID string `json:"device_id"`
	TokenID  string `json:"jti"`
	TokenUse string `json:"token_use"`
	IssuedAt int64  `json:"iat"`
	Expires  int64  `json:"exp"`
}

// NewTokenManager configures a symmetric HS256 access-token issuer. A secret
// shorter than 32 bytes is rejected to prevent accidental weak deployments.
func NewTokenManager(secret, issuer, audience string, ttl time.Duration, now func() time.Time) (*TokenManager, error) {
	secret = strings.TrimSpace(secret)
	issuer = strings.TrimSpace(issuer)
	audience = strings.TrimSpace(audience)
	if len([]byte(secret)) < 32 {
		return nil, errors.New("access token secret must be at least 32 bytes")
	}
	if issuer == "" {
		return nil, errors.New("access token issuer must not be empty")
	}
	if audience == "" {
		return nil, errors.New("access token audience must not be empty")
	}
	if ttl <= 0 {
		return nil, errors.New("access token lifetime must be greater than zero")
	}
	if now == nil {
		now = time.Now
	}
	return &TokenManager{
		secret:   append([]byte(nil), []byte(secret)...),
		issuer:   issuer,
		audience: audience,
		ttl:      ttl,
		now:      now,
	}, nil
}

// IssueAccessToken creates a signed bearer token bound to one account/device.
func (m *TokenManager) IssueAccessToken(userID, deviceID uuid.UUID) (string, time.Time, error) {
	if m == nil || userID == uuid.Nil || deviceID == uuid.Nil {
		return "", time.Time{}, errors.New("token manager or token identity is invalid")
	}
	now := m.now().UTC().Truncate(time.Second)
	expiresAt := now.Add(m.ttl)
	if !expiresAt.After(now) {
		return "", time.Time{}, errors.New("access token lifetime overflow")
	}
	payload := jwtPayload{
		Issuer:   m.issuer,
		Audience: m.audience,
		Subject:  userID.String(),
		DeviceID: deviceID.String(),
		TokenID:  uuid.New().String(),
		TokenUse: accessTokenUse,
		IssuedAt: now.Unix(),
		Expires:  expiresAt.Unix(),
	}
	return m.sign(jwtHeader{Algorithm: accessTokenAlgorithm, Type: accessTokenType}, payload), expiresAt, nil
}

// ValidateAccessToken verifies the signature and all identity/time claims.
func (m *TokenManager) ValidateAccessToken(token string) (AccessClaims, error) {
	if m == nil || token == "" {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	var header jwtHeader
	if json.Unmarshal(headerBytes, &header) != nil || header.Algorithm != accessTokenAlgorithm || header.Type != accessTokenType {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	var payload jwtPayload
	if json.Unmarshal(payloadBytes, &payload) != nil {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	mac := hmac.New(sha256.New, m.secret)
	_, _ = mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return AccessClaims{}, ErrInvalidAccessToken
	}

	userID, err := uuid.Parse(payload.Subject)
	if err != nil || userID == uuid.Nil {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	deviceID, err := uuid.Parse(payload.DeviceID)
	if err != nil || deviceID == uuid.Nil {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	tokenID, err := uuid.Parse(payload.TokenID)
	if err != nil || tokenID == uuid.Nil {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	if payload.Issuer != m.issuer || payload.Audience != m.audience || payload.TokenUse != accessTokenUse {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	if payload.IssuedAt <= 0 || payload.Expires <= payload.IssuedAt {
		return AccessClaims{}, ErrInvalidAccessToken
	}
	now := m.now().UTC()
	if payload.IssuedAt > now.Add(accessTokenClockSkew).Unix() || payload.Expires <= now.Unix() {
		return AccessClaims{}, ErrInvalidAccessToken
	}

	return AccessClaims{
		UserID:    userID,
		DeviceID:  deviceID,
		ID:        tokenID,
		IssuedAt:  time.Unix(payload.IssuedAt, 0).UTC(),
		ExpiresAt: time.Unix(payload.Expires, 0).UTC(),
		Issuer:    payload.Issuer,
		Audience:  payload.Audience,
	}, nil
}

func (m *TokenManager) sign(header jwtHeader, payload jwtPayload) string {
	headerBytes, _ := json.Marshal(header)
	payloadBytes, _ := json.Marshal(payload)
	headerPart := base64.RawURLEncoding.EncodeToString(headerBytes)
	payloadPart := base64.RawURLEncoding.EncodeToString(payloadBytes)
	mac := hmac.New(sha256.New, m.secret)
	_, _ = mac.Write([]byte(headerPart + "." + payloadPart))
	signature := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return fmt.Sprintf("%s.%s.%s", headerPart, payloadPart, signature)
}
