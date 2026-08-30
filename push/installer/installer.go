// Package installer merges the rootshell-notify hook into Claude Code and
// Codex hook files, tagging its entries so uninstall removes exactly them.
package installer

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/kitknox/rootshell/push/config"
)

const (
	Tag         = "push"
	TagKey      = "_rootshell"
	Command     = "rootshell-notify hook"
	HookTimeout = 10

	CodexTrustNote = "Codex requires you to trust new hooks: run `codex` then `/hooks`, review the rootshell entry and mark it trusted."
)

type Tool string

const (
	ClaudeCode Tool = "claude-code"
	Codex      Tool = "codex"
)

var Tools = []Tool{ClaudeCode, Codex}

func ParseTool(s string) (Tool, error) {
	switch Tool(s) {
	case ClaudeCode, Codex:
		return Tool(s), nil
	}
	return "", fmt.Errorf("unknown tool %q (want claude-code or codex)", s)
}

func (t Tool) Name() string {
	if t == Codex {
		return "Codex"
	}
	return "Claude Code"
}

func (t Tool) events() []string {
	if t == Codex {
		return []string{"Stop"}
	}
	return []string{"Stop", "Notification", "PreToolUse"}
}

func (t Tool) command() string {
	return Command + " --agent " + string(t)
}

// matchers restricts an event to specific tools; PreToolUse only fires for questions.
var matchers = map[string]string{"PreToolUse": "AskUserQuestion"}

// Path returns the hook file for the tool, project-local when project is set.
func Path(t Tool, project bool) (string, error) {
	base := "."
	if !project {
		var err error
		if base, err = os.UserHomeDir(); err != nil {
			return "", err
		}
	}
	if t == Codex {
		return filepath.Join(base, ".codex", "hooks.json"), nil
	}
	return filepath.Join(base, ".claude", "settings.json"), nil
}

type Result struct {
	Path    string
	Changed bool
}

type Status struct {
	Tool      Tool
	Path      string
	Exists    bool
	Installed bool
}

func Install(t Tool, project bool) (Result, error) {
	return apply(t, project, func(doc map[string]any) bool { return install(doc, t) })
}

func Uninstall(t Tool, project bool) (Result, error) {
	return apply(t, project, uninstall)
}

func GetStatus(t Tool, project bool) (Status, error) {
	path, err := Path(t, project)
	if err != nil {
		return Status{}, err
	}
	st := Status{Tool: t, Path: path}
	doc, exists, err := load(path)
	if err != nil {
		return st, err
	}
	st.Exists = exists
	st.Installed = installed(doc, t)
	return st, nil
}

// OnPath reports whether rootshell-notify resolves on $PATH.
func OnPath() (string, bool) {
	p, err := exec.LookPath("rootshell-notify")
	return p, err == nil
}

func apply(t Tool, project bool, mutate func(map[string]any) bool) (Result, error) {
	path, err := Path(t, project)
	if err != nil {
		return Result{}, err
	}
	doc, exists, err := load(path)
	if err != nil {
		return Result{Path: path}, err
	}
	original, _ := os.ReadFile(path)
	if !mutate(doc) {
		return Result{Path: path}, nil
	}
	if exists {
		if _, err := os.Stat(path + ".bak"); errors.Is(err, os.ErrNotExist) {
			if err := config.WriteFileAtomic(path+".bak", original, 0o600); err != nil {
				return Result{Path: path}, err
			}
		}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return Result{Path: path}, err
	}
	perm := os.FileMode(0o600)
	if st, err := os.Stat(path); err == nil {
		perm = st.Mode().Perm()
	}
	if err := config.WriteFileAtomic(path, buf.Bytes(), perm); err != nil {
		return Result{Path: path}, err
	}
	return Result{Path: path, Changed: true}, nil
}

func load(path string) (map[string]any, bool, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{}, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	doc := map[string]any{}
	if len(bytes.TrimSpace(raw)) == 0 {
		return doc, true, nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&doc); err != nil {
		return nil, true, fmt.Errorf("%s: %w", path, err)
	}
	return doc, true, nil
}

func ourEntry(event string, t Tool) map[string]any {
	g := map[string]any{
		"hooks": []any{map[string]any{
			"type": "command", "command": t.command(), "async": true, "timeout": HookTimeout, TagKey: Tag,
		}},
	}
	if m := matchers[event]; m != "" {
		g["matcher"] = m
	}
	return g
}

func isOurs(h any) bool {
	m, ok := h.(map[string]any)
	return ok && m[TagKey] == Tag
}

func groupHasOurs(g any) bool {
	m, ok := g.(map[string]any)
	if !ok {
		return false
	}
	inner, _ := m["hooks"].([]any)
	for _, h := range inner {
		if isOurs(h) {
			return true
		}
	}
	return false
}

func hookIsCurrent(h any, t Tool) bool {
	m, ok := h.(map[string]any)
	return ok && isOurs(m) && m["type"] == "command" && m["command"] == t.command() && m["async"] == true && timeoutIsCurrent(m["timeout"])
}

func timeoutIsCurrent(v any) bool {
	switch n := v.(type) {
	case int:
		return n == HookTimeout
	case float64:
		return n == HookTimeout
	case json.Number:
		i, err := n.Int64()
		return err == nil && i == HookTimeout
	default:
		return false
	}
}

func groupHasCurrent(g any, t Tool) bool {
	m, ok := g.(map[string]any)
	if !ok {
		return false
	}
	for _, h := range asList(m["hooks"]) {
		if hookIsCurrent(h, t) {
			return true
		}
	}
	return false
}

func hooksMap(doc map[string]any) map[string]any {
	m, _ := doc["hooks"].(map[string]any)
	return m
}

func installed(doc map[string]any, t Tool) bool {
	hooks := hooksMap(doc)
	if hooks == nil {
		return false
	}
	for _, ev := range t.events() {
		found := false
		for _, g := range asList(hooks[ev]) {
			if groupHasCurrent(g, t) {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

func install(doc map[string]any, t Tool) bool {
	hooks := hooksMap(doc)
	if hooks == nil {
		hooks = map[string]any{}
	}
	changed := false
	for _, ev := range t.events() {
		groups := asList(hooks[ev])
		has := false
		for _, g := range groups {
			m, ok := g.(map[string]any)
			if !ok {
				continue
			}
			for _, h := range asList(m["hooks"]) {
				hm, ok := h.(map[string]any)
				if !ok || !isOurs(hm) {
					continue
				}
				has = true
				if !hookIsCurrent(hm, t) {
					hm["type"] = "command"
					hm["command"] = t.command()
					hm["async"] = true
					hm["timeout"] = HookTimeout
					changed = true
				}
			}
		}
		if has {
			continue
		}
		hooks[ev] = append(groups, ourEntry(ev, t))
		changed = true
	}
	if changed {
		doc["hooks"] = hooks
	}
	return changed
}

func uninstall(doc map[string]any) bool {
	hooks := hooksMap(doc)
	if hooks == nil {
		return false
	}
	changed := false
	for ev, v := range hooks {
		groups, ok := v.([]any)
		if !ok {
			continue
		}
		var kept []any
		touched := false
		for _, g := range groups {
			m, ok := g.(map[string]any)
			if !ok || !groupHasOurs(g) {
				kept = append(kept, g)
				continue
			}
			changed, touched = true, true
			var inner []any
			for _, h := range asList(m["hooks"]) {
				if !isOurs(h) {
					inner = append(inner, h)
				}
			}
			if len(inner) > 0 {
				m["hooks"] = inner
				kept = append(kept, m)
			}
		}
		if !touched {
			continue
		}
		if len(kept) == 0 {
			delete(hooks, ev)
		} else {
			hooks[ev] = kept
		}
	}
	if changed && len(hooks) == 0 {
		delete(doc, "hooks")
	}
	return changed
}
