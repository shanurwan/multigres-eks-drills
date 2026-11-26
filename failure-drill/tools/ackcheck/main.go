// ackcheck writes uniquely keyed rows through a Postgres endpoint, records
// which commits the server acknowledged, and later verifies that every
// acknowledged row is still present.
//
//	ackcheck run    -dsn ... -run r1 -workers 8 -rate 50 -duration 5m -out dir
//	ackcheck verify -dsn ... -run r1 -out dir
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const ddl = `CREATE TABLE IF NOT EXISTS ackcheck (
	run    text        NOT NULL,
	worker int         NOT NULL,
	seq    bigint      NOT NULL,
	at     timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (run, worker, seq)
)`

// outcome of one insert attempt
const (
	ok        = "ok"        // commit acknowledged
	failed    = "failed"    // error before the statement was sent: definitely not written
	ambiguous = "ambiguous" // error after sending: may or may not be written
)

type event struct {
	T      int64  `json:"t"` // unix micro at completion
	Worker int    `json:"w"`
	Seq    int64  `json:"s"`
	Result string `json:"r"`
	LatUS  int64  `json:"lat"`
	Err    string `json:"e,omitempty"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: ackcheck run|verify [flags]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "run":
		runCmd(os.Args[2:])
	case "verify":
		verifyCmd(os.Args[2:])
	default:
		fmt.Fprintln(os.Stderr, "unknown command", os.Args[1])
		os.Exit(2)
	}
}

func connect(ctx context.Context, dsn string, notice func(*pgconn.Notice)) (*pgx.Conn, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	// Simple protocol: no server-side prepared statements, so a reconnect to
	// a new primary behind the gateway never meets a missing statement.
	cfg.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	cfg.ConnectTimeout = 3 * time.Second
	if notice != nil {
		cfg.OnNotice = func(_ *pgconn.PgConn, n *pgconn.Notice) { notice(n) }
	}
	return pgx.ConnectConfig(ctx, cfg)
}

// noticeSink receives every NOTICE/WARNING the server sends, tagged with the
// worker and the key being written. A WARNING about cancelling the wait for
// synchronous replication means the commit was acknowledged without a
// standby confirming it.
var noticeSink func(worker int, seq int64, n *pgconn.Notice)

// churnMode closes the connection after every attempt.
var churnMode bool

func runCmd(args []string) {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	dsn := fs.String("dsn", os.Getenv("DATABASE_URL"), "Postgres DSN (the gateway)")
	run := fs.String("run", "", "run id")
	workers := fs.Int("workers", 8, "concurrent writers, one connection each")
	rate := fs.Float64("rate", 50, "inserts per second per worker")
	duration := fs.Duration("duration", 5*time.Minute, "how long to write")
	timeout := fs.Duration("timeout", 5*time.Second, "per-statement timeout")
	out := fs.String("out", ".", "output directory")
	churn := fs.Bool("churn", false, "open a new connection for every insert, so every write also authenticates")
	_ = fs.Parse(args)
	churnMode = *churn
	if *run == "" {
		fmt.Fprintln(os.Stderr, "-run is required")
		os.Exit(2)
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	setup, err := connect(ctx, *dsn, nil)
	if err != nil {
		fatal(fmt.Errorf("connect: %w", err))
	}
	if _, err := setup.Exec(ctx, ddl); err != nil {
		fatal(fmt.Errorf("create table: %w", err))
	}
	_ = setup.Close(ctx)

	f, err := os.Create(filepath.Join(*out, *run+".events.jsonl"))
	if err != nil {
		fatal(err)
	}
	defer f.Close()
	events := make(chan event, 4096)
	var wg sync.WaitGroup
	done := make(chan struct{})
	go func() {
		w := bufio.NewWriter(f)
		enc := json.NewEncoder(w)
		for e := range events {
			_ = enc.Encode(e)
		}
		_ = w.Flush()
		close(done)
	}()

	nf, err := os.Create(filepath.Join(*out, *run+".notices.jsonl"))
	if err != nil {
		fatal(err)
	}
	defer nf.Close()
	var nmu sync.Mutex
	nenc := json.NewEncoder(nf)
	noticeSink = func(worker int, seq int64, n *pgconn.Notice) {
		nmu.Lock()
		defer nmu.Unlock()
		_ = nenc.Encode(map[string]any{
			"t": time.Now().UnixMicro(), "w": worker, "s": seq, "severity": n.Severity,
			"code": n.Code, "msg": n.Message, "detail": n.Detail,
		})
	}

	end := time.Now().Add(*duration)
	interval := time.Duration(float64(time.Second) / *rate)
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			writer(ctx, *dsn, *run, worker, interval, *timeout, end, events)
		}(i)
	}
	wg.Wait()
	close(events)
	<-done
	fmt.Printf("run %s finished; events in %s\n", *run, f.Name())
}

func writer(ctx context.Context, dsn, run string, worker int, interval, timeout time.Duration, end time.Time, events chan<- event) {
	var conn *pgx.Conn
	var seq int64
	notice := func(n *pgconn.Notice) {
		if noticeSink != nil {
			noticeSink(worker, seq, n)
		}
	}
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for time.Now().Before(end) {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		seq++ // every attempt gets a fresh key, so ambiguous attempts never collide with retries
		start := time.Now()
		if conn == nil || conn.IsClosed() {
			cctx, cancel := context.WithTimeout(ctx, timeout)
			c, err := connect(cctx, dsn, notice)
			cancel()
			if err != nil {
				events <- event{T: time.Now().UnixMicro(), Worker: worker, Seq: seq, Result: failed, LatUS: since(start), Err: short(err)}
				continue
			}
			conn = c
		}
		sctx, cancel := context.WithTimeout(ctx, timeout)
		_, err := conn.Exec(sctx, "INSERT INTO ackcheck (run, worker, seq) VALUES ($1, $2, $3)", run, worker, seq)
		cancel()
		e := event{T: time.Now().UnixMicro(), Worker: worker, Seq: seq, LatUS: since(start)}
		switch {
		case err == nil:
			e.Result = ok
		case pgconn.SafeToRetry(err) || isServerError(err):
			// Not sent, or the server answered with an error: an autocommit
			// INSERT that gets an ErrorResponse is rolled back.
			e.Result, e.Err = failed, short(err)
		default:
			e.Result, e.Err = ambiguous, short(err)
		}
		if err != nil || churnMode {
			// A broken connection may point at the old primary; start fresh.
			_ = conn.Close(context.Background())
			conn = nil
		}
		events <- e
	}
	if conn != nil {
		_ = conn.Close(context.Background())
	}
}

type summary struct {
	Run              string           `json:"run"`
	Attempts         int              `json:"attempts"`
	Acked            int              `json:"acked"`
	Failed           int              `json:"failed"`
	Ambiguous        int              `json:"ambiguous"`
	LostAcked        int              `json:"lost_acked"`
	LostAckedSample  []string         `json:"lost_acked_sample,omitempty"`
	AckedSyncWarn    int              `json:"acked_with_syncrep_warning"`
	LostSyncWarn     int              `json:"lost_with_syncrep_warning"`
	Notices          map[string]int   `json:"notices"`
	AmbiguousPresent int              `json:"ambiguous_present"`
	FailedPresent    int              `json:"failed_present"`
	Unexpected       int              `json:"unexpected_rows"`
	FirstEvent       string           `json:"first_event"`
	LastEvent        string           `json:"last_event"`
	Outages          []outage         `json:"outages"`
	ErrorKinds       map[string]int   `json:"error_kinds"`
	LatencyMS        map[string]int64 `json:"ok_latency_ms"`
}

// outage is a period in which no worker got an acknowledged commit.
type outage struct {
	From      string  `json:"from"`
	To        string  `json:"to"`
	Seconds   float64 `json:"seconds"`
	ErrorsIn  int     `json:"errors_in_window"`
	FirstErr  string  `json:"first_error,omitempty"`
}

func verifyCmd(args []string) {
	fs := flag.NewFlagSet("verify", flag.ExitOnError)
	dsn := fs.String("dsn", os.Getenv("DATABASE_URL"), "Postgres DSN")
	run := fs.String("run", "", "run id")
	out := fs.String("out", ".", "directory holding <run>.events.jsonl")
	gap := fs.Duration("gap", time.Second, "minimum gap between acks that counts as an outage")
	wait := fs.Duration("wait", 2*time.Minute, "how long to keep retrying the connection")
	_ = fs.Parse(args)

	evs, err := readEvents(filepath.Join(*out, *run+".events.jsonl"))
	if err != nil {
		fatal(err)
	}
	ctx := context.Background()
	// The cluster may still be recovering from the fault; keep trying.
	var conn *pgx.Conn
	deadline := time.Now().Add(*wait)
	for {
		conn, err = connect(ctx, *dsn, nil)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			fatal(fmt.Errorf("connect for verify: %w", err))
		}
		time.Sleep(2 * time.Second)
	}
	defer conn.Close(ctx)
	rows, err := conn.Query(ctx, "SELECT worker, seq FROM ackcheck WHERE run = $1", *run)
	if err != nil {
		fatal(err)
	}
	present := map[string]bool{}
	for rows.Next() {
		var w int
		var s int64
		if err := rows.Scan(&w, &s); err != nil {
			fatal(err)
		}
		present[key(w, s)] = true
	}
	if err := rows.Err(); err != nil {
		fatal(err)
	}

	sm := summary{Run: *run, ErrorKinds: map[string]int{}, LatencyMS: map[string]int64{}, Notices: map[string]int{}}
	syncWarn := map[string]bool{}
	if nf, err := os.Open(filepath.Join(*out, *run+".notices.jsonl")); err == nil {
		sc := bufio.NewScanner(nf)
		for sc.Scan() {
			var n struct {
				W   int    `json:"w"`
				S   int64  `json:"s"`
				Msg string `json:"msg"`
			}
			if json.Unmarshal(sc.Bytes(), &n) != nil {
				continue
			}
			sm.Notices[n.Msg]++
			if strings.Contains(n.Msg, "synchronous replication") {
				syncWarn[key(n.W, n.S)] = true
			}
		}
		nf.Close()
	}
	attempted := map[string]bool{}
	var okLat []int64
	for _, e := range evs {
		k := key(e.Worker, e.Seq)
		attempted[k] = true
		sm.Attempts++
		switch e.Result {
		case ok:
			sm.Acked++
			okLat = append(okLat, e.LatUS)
			if syncWarn[k] {
				sm.AckedSyncWarn++
			}
			if !present[k] {
				sm.LostAcked++
				if syncWarn[k] {
					sm.LostSyncWarn++
				}
				if len(sm.LostAckedSample) < 20 {
					sm.LostAckedSample = append(sm.LostAckedSample, k)
				}
			}
		case failed:
			sm.Failed++
			sm.ErrorKinds[e.Err]++
			if present[k] {
				sm.FailedPresent++
			}
		case ambiguous:
			sm.Ambiguous++
			sm.ErrorKinds[e.Err]++
			if present[k] {
				sm.AmbiguousPresent++
			}
		}
	}
	for k := range present {
		if !attempted[k] {
			sm.Unexpected++
		}
	}
	if len(evs) > 0 {
		sm.FirstEvent = ts(evs[0].T)
		sm.LastEvent = ts(evs[len(evs)-1].T)
	}
	sm.Outages = outages(evs, *gap)
	sort.Slice(okLat, func(i, j int) bool { return okLat[i] < okLat[j] })
	for _, p := range []float64{50, 95, 99, 100} {
		if len(okLat) > 0 {
			i := int(p/100*float64(len(okLat))) - 1
			if i < 0 {
				i = 0
			}
			sm.LatencyMS[fmt.Sprintf("p%v", p)] = okLat[i] / 1000
		}
	}
	b, _ := json.MarshalIndent(sm, "", "  ")
	fmt.Println(string(b))
	_ = os.WriteFile(filepath.Join(*out, *run+".summary.json"), b, 0o644)
	if sm.LostAcked > 0 || sm.Unexpected > 0 {
		os.Exit(1)
	}
}

func outages(evs []event, gap time.Duration) []outage {
	sorted := append([]event(nil), evs...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].T < sorted[j].T })
	var res []outage
	var lastOK int64 = -1
	errs := 0
	first := ""
	for _, e := range sorted {
		if e.Result != ok {
			errs++
			if first == "" {
				first = e.Err
			}
			continue
		}
		if lastOK >= 0 && time.Duration(e.T-lastOK)*time.Microsecond >= gap && errs > 0 {
			res = append(res, outage{From: ts(lastOK), To: ts(e.T), Seconds: float64(e.T-lastOK) / 1e6, ErrorsIn: errs, FirstErr: first})
		}
		lastOK, errs, first = e.T, 0, ""
	}
	return res
}

func readEvents(path string) ([]event, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var evs []event
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		var e event
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			return nil, err
		}
		evs = append(evs, e)
	}
	return evs, sc.Err()
}

func key(w int, s int64) string { return strconv.Itoa(w) + "/" + strconv.FormatInt(s, 10) }
func since(t time.Time) int64   { return time.Since(t).Microseconds() }
func ts(us int64) string        { return time.UnixMicro(us).UTC().Format("15:04:05.000") }

func short(err error) string {
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		return pg.Code + " " + pg.Message
	}
	s := err.Error()
	if i := strings.LastIndex(s, ": "); i > 0 && len(s) > 120 {
		s = s[i+2:]
	}
	if len(s) > 120 {
		s = s[:120]
	}
	return s
}

func isServerError(err error) bool {
	var pg *pgconn.PgError
	return errors.As(err, &pg)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "ackcheck:", err)
	os.Exit(1)
}
