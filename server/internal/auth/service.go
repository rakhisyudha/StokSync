package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net/mail"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/stoksync/stoksync/server/internal/db"
)

const (
	defaultAccessTokenTTL  = 15 * time.Minute
	defaultRefreshTokenTTL = 90 * 24 * time.Hour
	defaultTokenIssuer     = "stoksync-api"
	defaultTokenAudience   = "stoksync-client"
	refreshTokenBytes      = 32
	maxEmailBytes          = 254
	maxDeviceNameBytes     = 128
	maxPlatformBytes       = 64
)

var (
	ErrInvalidCredentials  = errors.New("invalid credentials")
	ErrInvalidInput        = errors.New("invalid authentication input")
	ErrEmailTaken          = errors.New("email is already registered")
	ErrDeviceOwnership     = errors.New("device belongs to another account")
	ErrInvalidRefreshToken = errors.New("invalid refresh token")
	ErrRefreshTokenExpired = errors.New("refresh token expired")
	ErrRefreshTokenReuse   = errors.New("refresh token reuse detected")
)

// Config controls password and session behavior. AccessTokenSecret is
// mandatory and must be supplied from deployment secret management.
type Config struct {
	AccessTokenSecret string
	AccessTokenTTL    time.Duration
	RefreshTokenTTL   time.Duration
	TokenIssuer       string
	TokenAudience     string
	PasswordHashCost  int
	Clock             func() time.Time
}

// LoginInput is shared by login and device-registration/account-registration
// flows. DeviceID is generated and persisted by the client installation.
type LoginInput struct {
	Email      string
	Password   string
	DeviceID   uuid.UUID
	DeviceName string
	Platform   string
}

// Session contains a short-lived access token and a one-time-use opaque
// refresh token. Callers must deliver it only over HTTPS.
type Session struct {
	UserID               uuid.UUID
	DeviceID             uuid.UUID
	AccessToken          string
	AccessTokenExpiresAt time.Time
	RefreshToken         string
}

// Service owns account authentication and device-bound refresh sessions.
type Service struct {
	pool                  *db.Pool
	hasher                *PasswordHasher
	tokens                *TokenManager
	refreshTokenTTL       time.Duration
	now                   func() time.Time
	refreshTokenGenerator func() (string, error)
}

type transactionOutcome struct {
	session Session
	authErr error
}

// NewService creates the database-backed authentication service.
func NewService(pool *db.Pool, config Config) (*Service, error) {
	if pool == nil {
		return nil, errors.New("auth database pool must not be nil")
	}
	if config.AccessTokenTTL == 0 {
		config.AccessTokenTTL = defaultAccessTokenTTL
	}
	if config.RefreshTokenTTL == 0 {
		config.RefreshTokenTTL = defaultRefreshTokenTTL
	}
	if config.TokenIssuer == "" {
		config.TokenIssuer = defaultTokenIssuer
	}
	if config.TokenAudience == "" {
		config.TokenAudience = defaultTokenAudience
	}
	if config.Clock == nil {
		config.Clock = time.Now
	}
	if config.RefreshTokenTTL <= 0 {
		return nil, errors.New("refresh token lifetime must be greater than zero")
	}
	hasher, err := NewPasswordHasher(config.PasswordHashCost)
	if err != nil {
		return nil, err
	}
	tokens, err := NewTokenManager(
		config.AccessTokenSecret,
		config.TokenIssuer,
		config.TokenAudience,
		config.AccessTokenTTL,
		config.Clock,
	)
	if err != nil {
		return nil, err
	}
	return &Service{
		pool:                  pool,
		hasher:                hasher,
		tokens:                tokens,
		refreshTokenTTL:       config.RefreshTokenTTL,
		now:                   config.Clock,
		refreshTokenGenerator: randomRefreshToken,
	}, nil
}

// Register creates an account, registers its first device, and returns a
// session atomically. The route is optional for deployments that provision
// users out of band; keeping it here makes the account lifecycle testable.
func (s *Service) Register(ctx context.Context, input LoginInput) (Session, error) {
	input, err := normalizeLoginInput(input)
	if err != nil {
		return Session{}, err
	}
	if len([]byte(input.Password)) < MinRegistrationPasswordBytes {
		return Session{}, ErrInvalidInput
	}
	passwordHash, err := s.hasher.Hash(input.Password)
	if err != nil {
		return Session{}, err
	}
	userID := uuid.New()
	outcome, err := db.WithTxResult(ctx, s.pool, func(queries *db.Queries) (transactionOutcome, error) {
		if _, err := queries.InsertUser(ctx, db.CreateUserParams{
			ID:           userID,
			Email:        input.Email,
			PasswordHash: passwordHash,
		}); errors.Is(err, pgx.ErrNoRows) {
			return transactionOutcome{authErr: ErrEmailTaken}, nil
		} else if err != nil {
			return transactionOutcome{}, err
		}
		outcome, err := s.issueSessionInTransaction(ctx, queries, userID, input)
		if err != nil {
			return transactionOutcome{}, err
		}
		if outcome.authErr != nil {
			// A registration that cannot claim its requested device must not
			// leave a partial account row behind.
			return transactionOutcome{}, outcome.authErr
		}
		return outcome, nil
	})
	if err != nil {
		return Session{}, err
	}
	return outcome.session, outcome.authErr
}

// Login validates credentials and registers or refreshes the supplied device
// in the same transaction as its new refresh-token record.
func (s *Service) Login(ctx context.Context, input LoginInput) (Session, error) {
	input, err := normalizeLoginInput(input)
	if err != nil {
		return Session{}, err
	}
	user, err := s.pool.Queries().GetUserByEmail(ctx, input.Email)
	if errors.Is(err, pgx.ErrNoRows) {
		_ = s.hasher.VerifyDummy(input.Password)
		return Session{}, ErrInvalidCredentials
	}
	if err != nil {
		return Session{}, err
	}
	if !s.hasher.Verify(user.PasswordHash, input.Password) {
		return Session{}, ErrInvalidCredentials
	}
	return s.issueSession(ctx, user.ID, input)
}

// Refresh consumes a valid refresh token and creates its replacement in one
// transaction. A reused token revokes all active sessions on that device.
func (s *Service) Refresh(ctx context.Context, rawToken string) (Session, error) {
	rawToken = strings.TrimSpace(rawToken)
	if !isRefreshTokenShapeValid(rawToken) {
		return Session{}, ErrInvalidRefreshToken
	}
	tokenHash := HashRefreshToken(rawToken)
	outcome, err := db.WithTxResult(ctx, s.pool, func(queries *db.Queries) (transactionOutcome, error) {
		stored, err := queries.GetRefreshTokenForUpdate(ctx, tokenHash)
		if errors.Is(err, pgx.ErrNoRows) {
			return transactionOutcome{authErr: ErrInvalidRefreshToken}, nil
		}
		if err != nil {
			return transactionOutcome{}, err
		}
		if stored.RevokedAt != nil {
			if _, err := queries.RevokeDeviceRefreshTokens(ctx, stored.UserID, stored.DeviceID); err != nil {
				return transactionOutcome{}, err
			}
			return transactionOutcome{authErr: ErrRefreshTokenReuse}, nil
		}
		if !s.now().Before(stored.ExpiresAt) {
			if _, err := queries.RevokeRefreshToken(ctx, stored.ID); err != nil {
				return transactionOutcome{}, err
			}
			return transactionOutcome{authErr: ErrRefreshTokenExpired}, nil
		}

		rawReplacement, err := s.refreshTokenGenerator()
		if err != nil {
			return transactionOutcome{}, err
		}
		session, refreshParams, err := s.newSession(stored.UserID, stored.DeviceID, rawReplacement)
		if err != nil {
			return transactionOutcome{}, err
		}
		if _, err := queries.MarkRefreshTokenRotated(ctx, stored.ID); err != nil {
			return transactionOutcome{}, err
		}
		if _, err := queries.InsertRefreshToken(ctx, refreshParams); err != nil {
			return transactionOutcome{}, err
		}
		return transactionOutcome{session: session}, nil
	})
	if err != nil {
		return Session{}, err
	}
	return outcome.session, outcome.authErr
}

// RevokeRefreshToken revokes one opaque token if it exists. Missing tokens are
// treated as an idempotent success for logout-style callers.
func (s *Service) RevokeRefreshToken(ctx context.Context, rawToken string) error {
	rawToken = strings.TrimSpace(rawToken)
	if !isRefreshTokenShapeValid(rawToken) {
		return nil
	}
	tokenHash := HashRefreshToken(rawToken)
	return db.WithTx(ctx, s.pool, func(queries *db.Queries) error {
		stored, err := queries.GetRefreshTokenForUpdate(ctx, tokenHash)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		_, err = queries.RevokeRefreshToken(ctx, stored.ID)
		return err
	})
}

// RevokeDeviceSessions invalidates all active refresh tokens for one validated
// account/device identity without deleting audit rows.
func (s *Service) RevokeDeviceSessions(ctx context.Context, userID, deviceID uuid.UUID) error {
	if userID == uuid.Nil || deviceID == uuid.Nil {
		return ErrInvalidInput
	}
	return db.WithTx(ctx, s.pool, func(queries *db.Queries) error {
		_, err := queries.RevokeDeviceRefreshTokens(ctx, userID, deviceID)
		return err
	})
}

// HashRefreshToken returns the hex SHA-256 digest persisted by the server.
// It is safe to use in tests and never returns the bearer value.
func HashRefreshToken(rawToken string) string {
	digest := sha256.Sum256([]byte(rawToken))
	return fmt.Sprintf("%x", digest[:])
}

func (s *Service) issueSession(ctx context.Context, userID uuid.UUID, input LoginInput) (Session, error) {
	outcome, err := db.WithTxResult(ctx, s.pool, func(queries *db.Queries) (transactionOutcome, error) {
		return s.issueSessionInTransaction(ctx, queries, userID, input)
	})
	if err != nil {
		return Session{}, err
	}
	return outcome.session, outcome.authErr
}

func (s *Service) issueSessionInTransaction(ctx context.Context, queries *db.Queries, userID uuid.UUID, input LoginInput) (transactionOutcome, error) {
	if _, err := queries.RegisterDevice(ctx, db.RegisterDeviceParams{
		ID:       input.DeviceID,
		UserID:   userID,
		Name:     input.DeviceName,
		Platform: input.Platform,
	}); errors.Is(err, pgx.ErrNoRows) {
		return transactionOutcome{authErr: ErrDeviceOwnership}, nil
	} else if err != nil {
		return transactionOutcome{}, err
	}
	rawToken, err := s.refreshTokenGenerator()
	if err != nil {
		return transactionOutcome{}, err
	}
	session, refreshParams, err := s.newSession(userID, input.DeviceID, rawToken)
	if err != nil {
		return transactionOutcome{}, err
	}
	if _, err := queries.InsertRefreshToken(ctx, refreshParams); err != nil {
		return transactionOutcome{}, err
	}
	return transactionOutcome{session: session}, nil
}

func (s *Service) newSession(userID, deviceID uuid.UUID, rawRefreshToken string) (Session, db.CreateRefreshTokenParams, error) {
	accessToken, accessExpiresAt, err := s.tokens.IssueAccessToken(userID, deviceID)
	if err != nil {
		return Session{}, db.CreateRefreshTokenParams{}, err
	}
	createdAt := s.now().UTC()
	return Session{
			UserID:               userID,
			DeviceID:             deviceID,
			AccessToken:          accessToken,
			AccessTokenExpiresAt: accessExpiresAt,
			RefreshToken:         rawRefreshToken,
		}, db.CreateRefreshTokenParams{
			ID:        uuid.New(),
			UserID:    userID,
			DeviceID:  deviceID,
			TokenHash: HashRefreshToken(rawRefreshToken),
			ExpiresAt: createdAt.Add(s.refreshTokenTTL),
		}, nil
}

func normalizeLoginInput(input LoginInput) (LoginInput, error) {
	email, err := normalizeEmail(input.Email)
	if err != nil {
		return LoginInput{}, ErrInvalidInput
	}
	if len(input.Password) == 0 || len([]byte(input.Password)) > MaxPasswordBytes {
		return LoginInput{}, ErrInvalidInput
	}
	if input.DeviceID == uuid.Nil {
		return LoginInput{}, ErrInvalidInput
	}
	input.DeviceName = strings.TrimSpace(input.DeviceName)
	input.Platform = strings.TrimSpace(input.Platform)
	if input.DeviceName == "" || len([]byte(input.DeviceName)) > maxDeviceNameBytes || input.Platform == "" || len([]byte(input.Platform)) > maxPlatformBytes {
		return LoginInput{}, ErrInvalidInput
	}
	input.Email = email
	return input, nil
}

func normalizeEmail(raw string) (string, error) {
	email := strings.ToLower(strings.TrimSpace(raw))
	if email == "" || len([]byte(email)) > maxEmailBytes || strings.ContainsAny(email, "\r\n\t ") {
		return "", ErrInvalidInput
	}
	parsed, err := mail.ParseAddress(email)
	if err != nil || parsed.Address != email || !strings.Contains(email, "@") {
		return "", ErrInvalidInput
	}
	return email, nil
}

func isRefreshTokenShapeValid(token string) bool {
	if len(token) < 43 || len(token) > 128 || strings.ContainsAny(token, " \t\r\n") {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	return err == nil && len(decoded) == refreshTokenBytes
}

func randomRefreshToken() (string, error) {
	bytes := make([]byte, refreshTokenBytes)
	if _, err := rand.Read(bytes); err != nil {
		return "", fmt.Errorf("generate refresh token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}
