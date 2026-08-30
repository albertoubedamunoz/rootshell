package client

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/kitknox/rootshell/push/config"
	"github.com/kitknox/rootshell/push/envelope"
)

func testEnv(t *testing.T) *envelope.Envelope {
	sk, _ := envelope.GeneratePrivateKey()
	env, err := envelope.Seal(sk.PublicKey(), "evt-1", &envelope.Header{Kind: "generic", Title: "hi"})
	if err != nil {
		t.Fatal(err)
	}
	return env
}

func newTest(t *testing.T, h http.HandlerFunc) (*Client, *config.Device) {
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	c := New("test")
	c.RetryDelay = 0
	return c, &config.Device{Server: srv.URL, SenderCred: "rsc1.tok"}
}

func TestPush(t *testing.T) {
	calls := 0
	c, dev := newTest(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/v1/push" || r.Header.Get("Authorization") != "Bearer rsc1.tok" || r.Header.Get("User-Agent") != "rootshell-notify/test" {
			t.Errorf("bad request %s %v", r.URL.Path, r.Header)
		}
		b, _ := io.ReadAll(r.Body)
		if !bytes.Contains(b, []byte(`"priority":"high"`)) || !bytes.Contains(b, []byte(`"eid":"evt-1"`)) {
			t.Errorf("body %s", b)
		}
		if calls == 1 {
			w.WriteHeader(503)
			return
		}
		w.WriteHeader(202)
	})
	if err := c.Push(context.Background(), dev, testEnv(t), Options{Priority: "high"}); err != nil || calls != 2 {
		t.Fatalf("err=%v calls=%d", err, calls)
	}
}

func TestPushErrors(t *testing.T) {
	cases := []struct {
		status int
		body   string
		want   error
	}{
		{401, "", ErrUnauthorized},
		{410, "", ErrDeviceGone},
		{429, "", &ErrRateLimited{}},
		{400, `{"error":"bad_envelope","message":"nope"}`, &APIError{}},
	}
	for _, tc := range cases {
		calls := 0
		c, dev := newTest(t, func(w http.ResponseWriter, r *http.Request) {
			calls++
			w.Header().Set("Retry-After", "7")
			w.WriteHeader(tc.status)
			w.Write([]byte(tc.body))
		})
		err := c.Push(context.Background(), dev, testEnv(t), Options{})
		if err == nil || calls != 1 {
			t.Fatalf("%d: err=%v calls=%d", tc.status, err, calls)
		}
		switch want := tc.want.(type) {
		case *ErrRateLimited:
			var rl *ErrRateLimited
			if !errors.As(err, &rl) || rl.RetryAfter.Seconds() != 7 {
				t.Fatalf("429: %v", err)
			}
		case *APIError:
			var api *APIError
			if !errors.As(err, &api) || api.Code != "bad_envelope" || api.Message != "nope" {
				t.Fatalf("400: %v", err)
			}
		default:
			if !errors.Is(err, want) {
				t.Fatalf("%d: %v", tc.status, err)
			}
		}
	}
}

func TestNetworkErrorRetries(t *testing.T) {
	c := New("test")
	c.RetryDelay = 0
	dev := &config.Device{Server: "http://127.0.0.1:1", SenderCred: "rsc1.x"}
	if err := c.Push(context.Background(), dev, testEnv(t), Options{}); err == nil {
		t.Fatal("expected error")
	}
}
