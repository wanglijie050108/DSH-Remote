// TURN 凭证（契约 §5）：username = "<expire_epoch>:<pair_id>"，credential = base64(HMAC-SHA1(S, username))
package contract

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"time"
)

const TurnTTLSeconds = 3600 // 契约 §5

func TurnUsername(pairID string, ttlSeconds int64, now time.Time) string {
	return fmt.Sprintf("%d:%s", now.Unix()+ttlSeconds, pairID)
}

func TurnCredential(secret, username string) string {
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(username))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// TurnUris 按 §5 固定三元：STUN + TURN/UDP + TURN/TCP（UDP 被封网络的兜底）
func TurnUris(host string) []string {
	return []string{
		fmt.Sprintf("stun:%s:3478", host),
		fmt.Sprintf("turn:%s:3478?transport=udp", host),
		fmt.Sprintf("turn:%s:3478?transport=tcp", host),
	}
}

type TurnCredentials struct {
	URIs       []string `json:"uris"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
	TTL        int64    `json:"ttl"`
}

func AllocTurn(secret, pairID, host string, ttlSeconds int64, now time.Time) TurnCredentials {
	username := TurnUsername(pairID, ttlSeconds, now)
	return TurnCredentials{
		URIs:       TurnUris(host),
		Username:   username,
		Credential: TurnCredential(secret, username),
		TTL:        ttlSeconds,
	}
}
