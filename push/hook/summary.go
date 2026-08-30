package hook

import (
	"regexp"
	"strings"
	"unicode"
)

var (
	fencedRe    = regexp.MustCompile("(?s)```.*?(```|$)")
	imageLinkRe = regexp.MustCompile(`!\[([^\]]*)\]\([^)]*\)`)
	linkRe      = regexp.MustCompile(`\[([^\]]*)\]\([^)]*\)`)
	urlRe       = regexp.MustCompile(`\bhttps?://\S+`)
	headingRe   = regexp.MustCompile(`(?m)^\s*(#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s*)`)
	emphasisRe  = regexp.MustCompile(`(\*\*|__|~~)`)
	spaceRe     = regexp.MustCompile(`\s+`)
)

// Summarize flattens markdown to plain text and trims to max runes on a
// sentence boundary, else a word boundary with an ellipsis.
func Summarize(s string, max int) string {
	s = fencedRe.ReplaceAllString(s, " ")
	s = imageLinkRe.ReplaceAllString(s, "$1")
	s = linkRe.ReplaceAllString(s, "$1")
	s = urlRe.ReplaceAllString(s, "")
	s = headingRe.ReplaceAllString(s, "")
	s = emphasisRe.ReplaceAllString(s, "")
	s = strings.ReplaceAll(s, "`", "")
	s = strings.TrimSpace(spaceRe.ReplaceAllString(s, " "))
	return truncate(s, max)
}

// minCut keeps a cut from producing a near-empty summary.
const minCut = 4

func isTerminator(r rune) bool {
	return strings.ContainsRune(".!?。！？", r)
}

func truncate(s string, max int) string {
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	// Prefer the last sentence end that leaves a reasonable amount of text.
	for i := max - 1; i >= minCut; i-- {
		if isTerminator(runes[i]) && (i+1 == len(runes) || unicode.IsSpace(runes[i+1]) || isTerminator(runes[i+1]) || runes[i] > 0x2000) {
			return strings.TrimSpace(string(runes[:i+1]))
		}
	}
	limit := max - 1 // room for the ellipsis
	for i := limit; i >= minCut; i-- {
		if unicode.IsSpace(runes[i]) {
			return strings.TrimRight(string(runes[:i]), " ,;:") + "…"
		}
	}
	return string(runes[:limit]) + "…"
}
