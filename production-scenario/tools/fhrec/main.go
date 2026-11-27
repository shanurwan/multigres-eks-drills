// fhrec records supafirehose's metrics stream (/ws/metrics, one snapshot
// every 100 ms) to a JSONL file, adding the time each snapshot arrived.
// supafirehose itself only shows the stream in its web UI.
//
//	fhrec -url ws://localhost:8080/ws/metrics -out metrics.jsonl -duration 6m
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	url := flag.String("url", "ws://localhost:8080/ws/metrics", "supafirehose metrics WebSocket")
	out := flag.String("out", "metrics.jsonl", "output file")
	duration := flag.Duration("duration", 6*time.Minute, "how long to record")
	flag.Parse()

	f, err := os.Create(*out)
	if err != nil {
		fatal(err)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	defer w.Flush()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	deadline := time.After(*duration)
	n := 0
	for {
		c, _, err := websocket.DefaultDialer.Dial(*url, nil)
		if err != nil {
			fmt.Fprintln(os.Stderr, "dial:", err)
			time.Sleep(time.Second)
			continue
		}
		msgs := make(chan []byte)
		go func() {
			defer close(msgs)
			for {
				_, b, err := c.ReadMessage()
				if err != nil {
					fmt.Fprintln(os.Stderr, "read:", err)
					return
				}
				msgs <- b
			}
		}()
	loop:
		for {
			select {
			case b, ok := <-msgs:
				if !ok {
					break loop
				}
				var raw json.RawMessage = b
				line, _ := json.Marshal(struct {
					RecvMS int64           `json:"recv_ms"`
					Msg    json.RawMessage `json:"msg"`
				}{time.Now().UnixMilli(), raw})
				w.Write(line)
				w.WriteByte('\n')
				if n++; n%50 == 0 {
					w.Flush()
				}
			case <-deadline:
				c.Close()
				fmt.Fprintf(os.Stderr, "recorded %d snapshots\n", n)
				return
			case <-stop:
				c.Close()
				return
			}
		}
		c.Close()
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
