package auth

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestSummarizeBody covers the reduction applied to a non-200 body before it
// becomes an error string (#358, item 3). The destination is
// a.LastAPIStatus, which view.go draws per account, so a newline in it does
// not just look wrong -- it breaks the table apart -- and a control character
// in it makes `claude-docker-tui --json` unparseable.
func TestSummarizeBody(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"empty", "", "(empty body)"},
		{"whitespace only", "\n\t  \r\n", "(no printable content)"},
		{"single line passes through", "upstream rejected", "upstream rejected"},
		{"newlines collapse", "line one\nline two\nline three", "line one line two line three"},
		{"tabs and CR collapse", "a\tb\r\nc", "a b c"},
		{"runs of whitespace collapse", "a     b", "a b"},
		{"control characters collapse", "a\x00\x07b", "a b"},
		{"surrounding whitespace is trimmed", "  hello  ", "hello"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := summarizeBody([]byte(tc.in)); got != tc.want {
				t.Errorf("summarizeBody(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestSummarizeBodyTruncates(t *testing.T) {
	got := summarizeBody([]byte(strings.Repeat("x", 5000)))
	if len([]rune(got)) > maxErrorBodyRunes+3 {
		t.Errorf("summary is %d runes, want at most %d", len([]rune(got)), maxErrorBodyRunes+3)
	}
	if !strings.HasSuffix(got, "...") {
		t.Error("a truncated summary should say so")
	}
}

// TestFetchUsageBoundsAProxyErrorPage is the end-to-end shape: a proxy answers
// 502 with a full HTML page, and the whole of it used to become the error.
func TestFetchUsageBoundsAProxyErrorPage(t *testing.T) {
	page := "<html>\n<head><title>502 Bad Gateway</title></head>\n<body>\n" +
		strings.Repeat("<p>the upstream server did not respond</p>\n", 500) +
		"</body>\n</html>\n"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte(page))
	}))
	defer srv.Close()

	_, err := fetchUsageFrom(srv.URL, "token")
	if err == nil {
		t.Fatal("expected an error for 502")
	}
	msg := err.Error()

	if strings.ContainsAny(msg, "\n\r\t") {
		t.Errorf("error string must be one line, got:\n%q", msg)
	}
	if len(msg) > 400 {
		t.Errorf("error string is %d bytes; the whole page reached it", len(msg))
	}
	if !strings.Contains(msg, "502") {
		t.Errorf("error should name the status, got: %q", msg)
	}
}

// TestFetchUsageOn429IsARateLimitError pins that the rate-limit verdict is the
// status alone; RateLimitError carries no body.
func TestFetchUsageOn429IsARateLimitError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte("slow down\nplease\n"))
	}))
	defer srv.Close()

	_, err := fetchUsageFrom(srv.URL, "token")
	var rl *RateLimitError
	if !errors.As(err, &rl) {
		t.Fatalf("expected *RateLimitError, got %T: %v", err, err)
	}
}

// TestFetchUsageParsesAGoodResponse keeps the bounding from passing by
// rejecting everything.
func TestFetchUsageParsesAGoodResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"five_hour":{"utilization":42.0,"resets_at":"2026-08-17T12:00:00Z"}}`))
	}))
	defer srv.Close()

	resp, err := fetchUsageFrom(srv.URL, "token")
	if err != nil {
		t.Fatalf("fetchUsageFrom: %v", err)
	}
	if resp.FiveHour == nil || int(resp.FiveHour.Utilization) != 42 {
		t.Fatalf("unexpected response: %+v", resp)
	}
}

// TestFetchUsageReportsAReadErrorAsARead pins the other half of item 3: a
// connection that drops mid-body used to reach json.Unmarshal and resurface
// as "parse usage response", blaming the decoder for a transport failure.
//
// Content-Length promises more than the handler writes, then the connection is
// hijacked and closed, so io.ReadAll returns io.ErrUnexpectedEOF.
func TestFetchUsageReportsAReadErrorAsARead(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Error("ResponseWriter is not a Hijacker")
			return
		}
		conn, buf, err := hj.Hijack()
		if err != nil {
			t.Errorf("hijack: %v", err)
			return
		}
		_, _ = buf.WriteString("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n")
		_, _ = buf.WriteString(`{"five_hour":`)
		_ = buf.Flush()
		_ = conn.Close()
	}))
	defer srv.Close()

	_, err := fetchUsageFrom(srv.URL, "token")
	if err == nil {
		t.Fatal("expected an error from a truncated body")
	}
	if strings.Contains(err.Error(), "parse usage response") {
		t.Errorf("a transport failure must not be reported as a parse failure, got: %v", err)
	}
	if !strings.Contains(err.Error(), "read usage response") {
		t.Errorf("error should name the read, got: %v", err)
	}
}
