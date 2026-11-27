// authload drives Supabase Auth (GoTrue) the way an app's users do, and
// records what every request got back, so a failover can be judged by what
// users saw rather than by what the database logged.
//
//	authload seed -url http://auth:9999 -users 200 -out users.json
//	authload run  -url http://auth:9999 -users-file users.json -rate 20 -duration 6m -out events.jsonl
//
// Each "run" operation picks a seeded user and does one of
//
//	login   POST /token?grant_type=password with the right password
//	wrong   the same with a wrong password (a control: what a real typo returns)
//	user    GET /user with the access token from the user's last login
//	refresh POST /token?grant_type=refresh_token with the last refresh token
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"golang.org/x/time/rate"
)

type user struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type event struct {
	T      int64  `json:"t"` // unix micro at completion
	Op     string `json:"op"`
	User   int    `json:"u"`
	Status int    `json:"st"` // 0 = no HTTP response (timeout, connection error)
	Code   string `json:"code,omitempty"`
	Msg    string `json:"msg,omitempty"`
	LatUS  int64  `json:"lat"`
}

var client = &http.Client{Timeout: 10 * time.Second}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: authload seed|run [flags]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "seed":
		seed(os.Args[2:])
	case "run":
		run(os.Args[2:])
	default:
		fmt.Fprintln(os.Stderr, "unknown command", os.Args[1])
		os.Exit(2)
	}
}

func seed(args []string) {
	fs := flag.NewFlagSet("seed", flag.ExitOnError)
	url := fs.String("url", "http://auth:9999", "Auth base URL")
	n := fs.Int("users", 200, "users to sign up")
	out := fs.String("out", "users.json", "where to write the users")
	_ = fs.Parse(args)
	tag := time.Now().UTC().Format("0102150405")
	var users []user
	for i := 0; i < *n; i++ {
		u := user{Email: fmt.Sprintf("u%s-%04d@drill.test", tag, i), Password: fmt.Sprintf("pw-%s-%04d-%d", tag, i, rand.Int63())}
		st, body, err := post(*url+"/signup", map[string]string{"email": u.Email, "password": u.Password}, "")
		if err != nil || st != 200 {
			fatal(fmt.Errorf("signup %s: status %d err %v body %s", u.Email, st, err, trunc(body)))
		}
		users = append(users, u)
	}
	b, _ := json.MarshalIndent(users, "", " ")
	if err := os.WriteFile(*out, b, 0o600); err != nil {
		fatal(err)
	}
	fmt.Printf("signed up %d users\n", len(users))
}

type session struct {
	mu      sync.Mutex
	access  string
	refresh string
}

func run(args []string) {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	url := fs.String("url", "http://auth:9999", "Auth base URL")
	usersFile := fs.String("users-file", "users.json", "users from seed")
	rps := fs.Float64("rate", 20, "operations per second in total")
	workers := fs.Int("workers", 16, "concurrent clients")
	duration := fs.Duration("duration", 6*time.Minute, "how long to run")
	wrongPct := fs.Int("wrong-pct", 5, "percent of operations that log in with a wrong password")
	out := fs.String("out", "events.jsonl", "output file")
	_ = fs.Parse(args)

	b, err := os.ReadFile(*usersFile)
	if err != nil {
		fatal(err)
	}
	var users []user
	if err := json.Unmarshal(b, &users); err != nil {
		fatal(err)
	}
	sessions := make([]session, len(users))

	f, err := os.Create(*out)
	if err != nil {
		fatal(err)
	}
	defer f.Close()
	bw := bufio.NewWriter(f)
	defer bw.Flush()
	var wmu sync.Mutex
	emit := func(e event) {
		line, _ := json.Marshal(e)
		wmu.Lock()
		bw.Write(line)
		bw.WriteByte('\n')
		wmu.Unlock()
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, *duration)
	defer cancel()
	lim := rate.NewLimiter(rate.Limit(*rps), 1)

	var wg sync.WaitGroup
	for w := 0; w < *workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			r := rand.New(rand.NewSource(int64(w) + time.Now().UnixNano()))
			for {
				if err := lim.Wait(ctx); err != nil {
					return
				}
				i := r.Intn(len(users))
				u, s := users[i], &sessions[i]
				s.mu.Lock()
				access, refresh := s.access, s.refresh
				s.mu.Unlock()
				op := "login"
				switch p := r.Intn(100); {
				case p < *wrongPct:
					op = "wrong"
				case access != "" && p < 55:
					op = "user"
				case refresh != "" && p < 70:
					op = "refresh"
				}
				start := time.Now()
				var st int
				var body []byte
				var err error
				// A request in flight when the run ends still finishes and is recorded.
				switch op {
				case "login":
					st, body, err = post(*url+"/token?grant_type=password", map[string]string{"email": u.Email, "password": u.Password}, "")
				case "wrong":
					st, body, err = post(*url+"/token?grant_type=password", map[string]string{"email": u.Email, "password": u.Password + "-typo"}, "")
				case "refresh":
					st, body, err = post(*url+"/token?grant_type=refresh_token", map[string]string{"refresh_token": refresh}, "")
				case "user":
					st, body, err = get(*url+"/user", access)
				}
				e := event{T: time.Now().UnixMicro(), Op: op, User: i, Status: st, LatUS: time.Since(start).Microseconds()}
				if err != nil {
					e.Msg = trunc([]byte(err.Error()))
				} else if st != 200 {
					e.Code, e.Msg = errorOf(body)
				} else if op == "login" || op == "refresh" {
					var tok struct {
						AccessToken  string `json:"access_token"`
						RefreshToken string `json:"refresh_token"`
					}
					if json.Unmarshal(body, &tok) == nil && tok.AccessToken != "" {
						s.mu.Lock()
						s.access, s.refresh = tok.AccessToken, tok.RefreshToken
						s.mu.Unlock()
					}
				}
				emit(e)
			}
		}(w)
	}
	wg.Wait()
}

func post(url string, body any, bearer string) (int, []byte, error) {
	b, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	return do(req, bearer)
}

func get(url, bearer string) (int, []byte, error) {
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, url, nil)
	return do(req, bearer)
}

func do(req *http.Request, bearer string) (int, []byte, error) {
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	return resp.StatusCode, b, nil
}

// errorOf pulls the error code and message out of an Auth error body. Newer
// responses carry error_code/msg, older ones error/error_description.
func errorOf(b []byte) (string, string) {
	var e struct {
		ErrorCode string `json:"error_code"`
		Msg       string `json:"msg"`
		Message   string `json:"message"`
		Err       string `json:"error"`
		ErrDesc   string `json:"error_description"`
	}
	if json.Unmarshal(b, &e) != nil {
		return "", trunc(b)
	}
	code := e.ErrorCode
	if code == "" {
		code = e.Err
	}
	msg := e.Msg
	if msg == "" {
		msg = e.Message
	}
	if msg == "" {
		msg = e.ErrDesc
	}
	return code, trunc([]byte(msg))
}

func trunc(b []byte) string {
	if len(b) > 300 {
		b = b[:300]
	}
	return string(b)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
