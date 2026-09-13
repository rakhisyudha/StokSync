package auth

import (
	"context"
	"net/http"
	"strings"

	"github.com/google/uuid"
)

type contextKey struct{}

// Identity is the account/device identity validated from an access token.
type Identity struct {
	UserID   uuid.UUID
	DeviceID uuid.UUID
	TokenID  uuid.UUID
}

// IdentityFromContext returns the identity installed by RequireAccessToken.
func IdentityFromContext(ctx context.Context) (Identity, bool) {
	if ctx == nil {
		return Identity{}, false
	}
	identity, ok := ctx.Value(contextKey{}).(Identity)
	return identity, ok && identity.UserID != uuid.Nil && identity.DeviceID != uuid.Nil
}

// RequireAccessToken validates a bearer access token and exposes its identity
// to downstream handlers. It deliberately performs no token or credential
// logging.
func RequireAccessToken(manager *TokenManager) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := accessClaimsFromRequest(manager, r)
			if !ok {
				w.Header().Set("WWW-Authenticate", `Bearer realm="stoksync"`)
				writeAuthError(w, http.StatusUnauthorized, "unauthorized")
				return
			}
			identity := Identity{UserID: claims.UserID, DeviceID: claims.DeviceID, TokenID: claims.ID}
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), contextKey{}, identity)))
		})
	}
}

// RequireAuth is the service-bound form used by the Chi auth routes and later
// protected product/sync routes.
func (s *Service) RequireAuth(next http.Handler) http.Handler {
	if s == nil {
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			writeAuthError(w, http.StatusUnauthorized, "unauthorized")
		})
	}
	return RequireAccessToken(s.tokens)(next)
}

func accessClaimsFromRequest(manager *TokenManager, r *http.Request) (AccessClaims, bool) {
	if manager == nil || r == nil {
		return AccessClaims{}, false
	}
	parts := strings.Fields(r.Header.Get("Authorization"))
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return AccessClaims{}, false
	}
	claims, err := manager.ValidateAccessToken(parts[1])
	if err != nil {
		return AccessClaims{}, false
	}
	return claims, true
}
