package hook

import (
	"regexp"
	"strings"
	"unicode"
)

const redacted = "[redacted]"

var (
	pemRe      = regexp.MustCompile(`(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(-----END [A-Z ]*PRIVATE KEY-----|$)`)
	kvRe       = regexp.MustCompile(`(?i)\b(api[_-]?key|token|secret|password|passwd|pwd|authorization)\s*[=:]\s*(bearer\s+)?\S+`)
	bearerRe   = regexp.MustCompile(`(?i)\bBearer\s+\S+`)
	keyShapeRe = regexp.MustCompile(`\b(sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})`)
	hexRunRe   = regexp.MustCompile(`\b[A-Fa-f0-9]{40,}\b`)
	b64RunRe   = regexp.MustCompile(`[A-Za-z0-9+/_-]{40,}={0,2}`)
)

// Redact scrubs credential-shaped substrings from free text.
func Redact(s string) string {
	s = pemRe.ReplaceAllString(s, redacted)
	s = kvRe.ReplaceAllString(s, "${1}="+redacted)
	s = bearerRe.ReplaceAllString(s, "Bearer "+redacted)
	s = keyShapeRe.ReplaceAllString(s, redacted)
	s = hexRunRe.ReplaceAllString(s, redacted)
	s = b64RunRe.ReplaceAllStringFunc(s, func(m string) string {
		if looksLikeSecret(m) {
			return redacted
		}
		return m
	})
	return s
}

// looksLikeSecret separates base64 blobs from long paths and slugs: it
// needs mixed case plus digits and must not read like a filesystem path.
func looksLikeSecret(m string) bool {
	if strings.HasPrefix(m, "/") || strings.Count(m, "/") > 2 {
		return false
	}
	var upper, lower, digit bool
	for _, r := range m {
		switch {
		case unicode.IsUpper(r):
			upper = true
		case unicode.IsLower(r):
			lower = true
		case unicode.IsDigit(r):
			digit = true
		}
	}
	return upper && lower && digit
}
