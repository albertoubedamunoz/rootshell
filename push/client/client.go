// Package client talks to the rootshell push relay on behalf of a sender.
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/kitknox/rootshell/push/config"
	"github.com/kitknox/rootshell/push/envelope"
)

const (
	Timeout    = 10 * time.Second
	retryDelay = 2 * time.Second
)

var (
	ErrUnauthorized = errors.New("sender credential rejected (revoked or unknown); re-pair")
	ErrDeviceGone   = errors.New("device no longer registered; re-pair")
	ErrRetryable    = errors.New("relay temporarily unavailable")
)

type ErrRateLimited struct{ RetryAfter time.Duration }

func (e *ErrRateLimited) Error() string {
	return fmt.Sprintf("rate limited (retry after %s)", e.RetryAfter)
}

// APIError is a 4xx/5xx with a JSON {"error","message"} body.
type APIError struct {
	Status  int
	Code    string
	Message string
}

func (e *APIError) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("relay %d %s: %s", e.Status, e.Code, e.Message)
	}
	return fmt.Sprintf("relay %d %s", e.Status, e.Code)
}

type Options struct {
	Priority string // high | normal
}

type Client struct {
	HTTP       *http.Client
	UserAgent  string
	RetryDelay time.Duration
}

func New(version string) *Client {
	return &Client{HTTP: &http.Client{Timeout: Timeout}, UserAgent: "rootshell-notify/" + version, RetryDelay: retryDelay}
}

type pushReq struct {
	V        int    `json:"v"`
	Enc      string `json:"enc"`
	CT       string `json:"ct"`
	EID      string `json:"eid"`
	Priority string `json:"priority,omitempty"`
}

// Push delivers a sealed envelope; retries once on ErrRetryable or network errors.
func (c *Client) Push(ctx context.Context, dev *config.Device, env *envelope.Envelope, opts Options) error {
	body, err := json.Marshal(pushReq{V: env.V, Enc: env.Enc, CT: env.CT, EID: env.EID, Priority: opts.Priority})
	if err != nil {
		return err
	}
	return c.withRetry(ctx, func() error {
		req, err := http.NewRequestWithContext(ctx, "POST", strings.TrimRight(dev.Server, "/")+"/v1/push", bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+dev.SenderCred)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", c.UserAgent)
		resp, err := c.HTTP.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusAccepted {
			return statusError(resp)
		}
		return nil
	})
}

// Health checks GET /healthz.
func (c *Client) Health(ctx context.Context, server string) error {
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(server, "/")+"/healthz", nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", c.UserAgent)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("healthz: HTTP %d", resp.StatusCode)
	}
	return nil
}

func (c *Client) withRetry(ctx context.Context, f func() error) error {
	err := f()
	if err == nil || !retryable(err) {
		return err
	}
	select {
	case <-ctx.Done():
		return err
	case <-time.After(c.RetryDelay):
	}
	return f()
}

func retryable(err error) bool {
	if errors.Is(err, ErrRetryable) {
		return true
	}
	var ne net.Error
	if errors.As(err, &ne) {
		return true
	}
	// Transport errors (connection refused, EOF) surface as *url.Error.
	var api *APIError
	var rl *ErrRateLimited
	if errors.As(err, &api) || errors.As(err, &rl) || errors.Is(err, ErrUnauthorized) || errors.Is(err, ErrDeviceGone) {
		return false
	}
	return !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded)
}

func statusError(resp *http.Response) error {
	switch resp.StatusCode {
	case http.StatusUnauthorized:
		return ErrUnauthorized
	case http.StatusGone:
		return ErrDeviceGone
	case http.StatusTooManyRequests:
		ra := 5 * time.Second
		if s := resp.Header.Get("Retry-After"); s != "" {
			if n, err := strconv.Atoi(s); err == nil && n >= 0 {
				ra = time.Duration(n) * time.Second
			}
		}
		return &ErrRateLimited{RetryAfter: ra}
	case http.StatusServiceUnavailable:
		return ErrRetryable
	}
	api := &APIError{Status: resp.StatusCode}
	var body struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&body) == nil {
		api.Code, api.Message = body.Error, body.Message
	}
	if api.Code == "" {
		api.Code = http.StatusText(resp.StatusCode)
	}
	return api
}
