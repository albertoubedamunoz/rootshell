// Package hook turns agent hook payloads (Claude Code, Codex) into
// notification events. Parse is pure; Route reads the environment.
package hook

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"time"

	"github.com/kitknox/rootshell/push/envelope"
)

const (
	MaxBody = 200

	tmuxTimeout = 300 * time.Millisecond
)

// ErrIgnore means the payload is valid but should not produce a notification.
var ErrIgnore = errors.New("hook: event ignored")

type Event struct {
	Agent     string // claude-code | codex
	AgentName string // Claude Code | Codex
	Status    string // done | blocked
	Title     string
	Body      string
	Thread    string
	EID       string
	SessionID string
	Cwd       string
}

// Header builds the envelope header for this event with the given route.
func (e *Event) Header(route *envelope.Route) *envelope.Header {
	return &envelope.Header{Kind: "agent", Agent: e.Agent, Status: e.Status, Title: e.Title, Body: e.Body, Thread: e.Thread, Route: route}
}

type payload struct {
	SessionID            string          `json:"session_id"`
	TranscriptPath       string          `json:"transcript_path"`
	Cwd                  string          `json:"cwd"`
	HookEventName        string          `json:"hook_event_name"`
	StopHookActive       bool            `json:"stop_hook_active"`
	LastAssistantMessage string          `json:"last_assistant_message"`
	NotificationType     string          `json:"notification_type"`
	Message              string          `json:"message"`
	Title                string          `json:"title"`
	TurnID               string          `json:"turn_id"`
	ToolName             string          `json:"tool_name"`
	ToolInput            json.RawMessage `json:"tool_input"`

	// Codex legacy `notify` payload.
	Type                string `json:"type"`
	ThreadID            string `json:"thread-id"`
	LegacyTurnID        string `json:"turn-id"`
	LegacyLastAssistant string `json:"last-assistant-message"`
}

// Parse decodes a hook payload. Returns ErrIgnore for events that should not notify.
func Parse(data []byte) (*Event, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("hook: bad json: %w", err)
	}
	var p payload
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("hook: bad payload: %w", err)
	}
	_, hasTranscript := raw["transcript_path"]
	_, hasTurn := raw["turn_id"]
	switch {
	case hasTranscript:
		return parseClaude(&p)
	case hasTurn:
		return parseCodex(&p)
	case p.Type == "agent-turn-complete":
		return parseCodexLegacy(&p)
	}
	return nil, errors.New("hook: unrecognized payload")
}

func parseClaude(p *payload) (*Event, error) {
	if p.StopHookActive {
		return nil, ErrIgnore
	}
	e := &Event{Agent: "claude-code", AgentName: "Claude Code", SessionID: p.SessionID, Cwd: p.Cwd}
	var salt string
	switch p.HookEventName {
	case "Stop":
		e.Status = "done"
		e.Body = Summarize(p.LastAssistantMessage, MaxBody)
		salt = transcriptSalt(p)
	case "Notification":
		switch p.NotificationType {
		case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
			e.Status = "blocked"
		case "idle_prompt", "agent_completed":
			e.Status = "done"
		default:
			return nil, ErrIgnore
		}
		e.Body = Summarize(p.Message, MaxBody)
		salt = p.NotificationType + "|" + hashOf(p.Message)
	case "PreToolUse":
		if p.ToolName != "AskUserQuestion" {
			return nil, ErrIgnore
		}
		e.Status = "blocked"
		e.Body = Summarize(firstQuestion(p.ToolInput), MaxBody)
		if e.Body == "" {
			e.Body = "Claude Code is asking you a question"
		}
		salt = "ask|" + hashOf(string(p.ToolInput))
	default:
		return nil, ErrIgnore
	}
	finish(e, p.HookEventName, salt)
	return e, nil
}

func parseCodex(p *payload) (*Event, error) {
	if p.StopHookActive {
		return nil, ErrIgnore
	}
	e := &Event{Agent: "codex", AgentName: "Codex", SessionID: p.SessionID, Cwd: p.Cwd}
	switch p.HookEventName {
	case "Stop":
		e.Status = "done"
		e.Body = Summarize(p.LastAssistantMessage, MaxBody)
		finish(e, "Stop", p.TurnID)
	case "PermissionRequest":
		e.Status = "blocked"
		e.Body = Summarize(codexApproval(p), MaxBody)
		finish(e, "PermissionRequest", p.TurnID+"|"+hashOf(p.ToolName+"|"+string(p.ToolInput)))
	default:
		return nil, ErrIgnore
	}
	return e, nil
}

// firstQuestion extracts tool_input.questions[0].question from AskUserQuestion input.
func firstQuestion(raw json.RawMessage) string {
	var in struct {
		Questions []struct {
			Question string `json:"question"`
		} `json:"questions"`
	}
	if json.Unmarshal(raw, &in) != nil || len(in.Questions) == 0 {
		return ""
	}
	return strings.TrimSpace(in.Questions[0].Question)
}

// codexApproval describes a Codex PermissionRequest from tool_input.command
// (string or argv array) or tool_name.
func codexApproval(p *payload) string {
	var in struct {
		Command json.RawMessage `json:"command"`
	}
	if json.Unmarshal(p.ToolInput, &in) == nil && len(in.Command) > 0 {
		var s string
		var argv []string
		switch {
		case json.Unmarshal(in.Command, &s) == nil:
		case json.Unmarshal(in.Command, &argv) == nil:
			s = strings.Join(argv, " ")
		}
		if s = strings.TrimSpace(s); s != "" {
			return "Codex wants to run: " + s
		}
	}
	if p.ToolName != "" {
		return "Codex needs your approval to use " + p.ToolName
	}
	return "Codex needs your approval"
}

func parseCodexLegacy(p *payload) (*Event, error) {
	e := &Event{Agent: "codex", AgentName: "Codex", SessionID: p.ThreadID, Cwd: p.Cwd, Status: "done"}
	e.Body = Summarize(p.LegacyLastAssistant, MaxBody)
	salt := p.LegacyTurnID
	if salt == "" {
		salt = hashOf(p.LegacyLastAssistant)
	}
	finish(e, "Stop", salt)
	return e, nil
}

func finish(e *Event, event, salt string) {
	e.Title = e.AgentName
	if base := filepath.Base(strings.TrimRight(e.Cwd, "/")); e.Cwd != "" && base != "." && base != "/" {
		e.Title = e.AgentName + " · " + base
	}
	e.Body = Redact(e.Body)
	e.Thread = hashOf(e.Agent + "|" + e.SessionID)[:16]
	e.EID = hashOf(e.Agent + "|" + e.SessionID + "|" + salt + "|" + event)[:24]
}

// transcriptSalt prefers the transcript mtime so re-fired Stop hooks for the
// same turn dedupe; falls back to hashing the message.
func transcriptSalt(p *payload) string {
	if st, err := os.Stat(p.TranscriptPath); err == nil {
		return fmt.Sprintf("mtime:%d", st.ModTime().UnixNano())
	}
	return hashOf(p.LastAssistantMessage)
}

func hashOf(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// Route reads pane, tmux and host identity from the environment.
func Route(ctx context.Context, cwd string) *envelope.Route {
	r := &envelope.Route{Pane: os.Getenv("LC_ROOTSHELL_PANE"), TmuxPane: os.Getenv("TMUX_PANE"), Cwd: cwd}
	if os.Getenv("TMUX") != "" {
		r.TmuxSession = tmuxSession(ctx)
	}
	r.Host = hostLabel()
	return r
}

func tmuxSession(ctx context.Context) string {
	ctx, cancel := context.WithTimeout(ctx, tmuxTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "tmux", "display-message", "-p", "#S").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func hostLabel() string {
	host, _ := os.Hostname()
	host, _, _ = strings.Cut(host, ".")
	name := os.Getenv("USER")
	if name == "" {
		if u, err := user.Current(); err == nil {
			name = u.Username
		}
	}
	switch {
	case name == "" && host == "":
		return ""
	case name == "":
		return host
	case host == "":
		return name
	}
	return name + "@" + host
}
