// loadgen publishes CI-like log lines to the JetStream stream consumed by ZincSearch nodes (spike 5 measurement tool).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"net/http"
	"sort"
	"os"
	"strings"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

var words = strings.Fields("compiling linking testing module package resolving downloading cache hit miss warning error info step build target artifact upload checksum passed failed retry timeout network registry image layer pull push deploy helm apply rollout ready pod node volume mount secret token config schema migrate index query window")

func line(r *rand.Rand, ln int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "2026-09-21T10:%02d:%02d.%03dZ [step-%d] ", (ln/60000)%60, (ln/1000)%60, ln%1000, ln/100000)
	for i, n := 0, 6+r.Intn(10); i < n; i++ {
		b.WriteString(words[r.Intn(len(words))])
		if r.Intn(4) == 0 {
			fmt.Fprintf(&b, "=%d", r.Intn(100000))
		}
		b.WriteByte(' ')
	}
	return b.String()
}

func main() {
	url := flag.String("url", "nats://127.0.0.1:4222", "NATS url")
	stream := flag.String("stream", "zinc", "stream")
	index := flag.String("index", "logs-t1-w38", "index")
	job := flag.String("job", "job-big", "job id")
	start := flag.Int("start", 1, "first line number")
	n := flag.Int("n", 1_000_000, "lines")
	batch := flag.Int("batch", 500, "lines per message")
	create := flag.Bool("create", false, "create stream and index mapping first")
	replicas := flag.Int("replicas", 1, "stream replicas")
	variant := flag.Int("variant", 1, "index schema variant 1..7")
	rate := flag.Int("rate", 0, "limit to this many lines per second (0 = unlimited)")
	probe := flag.Int("probe", 0, "measure publish-to-searchable latency with this many marker documents")
	node := flag.String("node", "http://127.0.0.1:4080", "node URL for probes")
	pad := flag.Bool("padid", false, "zero-padded line number in the document id (job:0000000123)")
	flag.Parse()

	nc, err := nats.Connect(*url)
	if err != nil {
		panic(err)
	}
	defer nc.Close()
	js, _ := jetstream.New(nc, jetstream.WithPublishAsyncMaxPending(256))
	if *create {
		_, err := js.CreateOrUpdateStream(context.Background(), jetstream.StreamConfig{Name: *stream, Subjects: []string{*stream + ".>"}, Storage: jetstream.FileStorage,
			MaxAge: 2 * time.Hour, Replicas: *replicas, Discard: jetstream.DiscardOld})
		if err != nil {
			panic(err)
		}
		off := map[string]any{"type": "date", "index": false, "store": false, "sortable": false, "aggregatable": false}
		props := map[string]any{
			"job":  map[string]any{"type": "keyword", "index": true},
			"ln":   map[string]any{"type": "numeric", "index": true, "sortable": true},
			"line": map[string]any{"type": "text", "index": true, "store": true},
		}
		body := map[string]any{}
		switch *variant {
		case 2: // line indexed, not stored separately (it stays in _source)
			props["line"] = map[string]any{"type": "text", "index": true, "store": false}
		case 3: // line neither indexed nor stored
			props["line"] = map[string]any{"type": "text", "index": false, "store": false}
		case 4: // v3 plus the automatic @timestamp switched off
			props["line"] = map[string]any{"type": "text", "index": false, "store": false}
			props["@timestamp"] = off
		case 6: // window key is the padded _id (range on _id); ln not indexed; one shard
			props["line"] = map[string]any{"type": "text", "index": false, "store": false}
			props["@timestamp"] = off
			props["ln"] = map[string]any{"type": "numeric", "index": false, "store": false, "sortable": false}
			body["shard_num"] = 1
		case 7: // v6 without the job index (the job is the id prefix)
			props["line"] = map[string]any{"type": "text", "index": false, "store": false}
			props["@timestamp"] = off
			props["ln"] = map[string]any{"type": "numeric", "index": false, "store": false, "sortable": false}
			props["job"] = map[string]any{"type": "keyword", "index": false, "store": false}
			body["shard_num"] = 1
		case 8: // v6 plus a full-text index of the line (needed for search inside a job, DAT-007); text is not stored twice
			props["line"] = map[string]any{"type": "text", "index": true, "store": false}
			props["@timestamp"] = off
			props["ln"] = map[string]any{"type": "numeric", "index": false, "store": false, "sortable": false}
			body["shard_num"] = 1
		case 9: // v8 with the "simple" analyzer: letters only, numbers are not indexed
			props["line"] = map[string]any{"type": "text", "index": true, "store": false, "analyzer": "simple"}
			props["@timestamp"] = off
			props["ln"] = map[string]any{"type": "numeric", "index": false, "store": false, "sortable": false}
			body["shard_num"] = 1
		case 5: // v4 in a single shard
			props["line"] = map[string]any{"type": "text", "index": false, "store": false}
			props["@timestamp"] = off
			body["shard_num"] = 1
		}
		body["mappings"] = map[string]any{"properties": props}
		m := map[string]any{"kind": "admin", "index": *index, "op": "create_index", "data": body}
		b, _ := json.Marshal(m)
		if _, err := js.Publish(context.Background(), *stream+".logs", b); err != nil {
			panic(err)
		}
		fmt.Println("stream and index created")
		if *n == 0 {
			return
		}
	}
	if *probe > 0 {
		var lat []float64
		for i := 0; i < *probe; i++ {
			id := fmt.Sprintf("probe:%d:%d", time.Now().UnixNano(), i)
			b, _ := json.Marshal(map[string]any{"kind": "docs", "index": *index, "docs": []map[string]any{{"id": id, "doc": map[string]any{"job": "probe", "ln": i, "line": "marker"}}}})
			if _, err := js.Publish(context.Background(), *stream+".logs", b); err != nil {
				panic(err)
			}
			t0 := time.Now()
			for {
				q := fmt.Sprintf(`{"query":{"term":{"_id":%q}},"size":1,"_source":false}`, id)
				req, _ := http.NewRequest("POST", *node+"/es/"+*index+"/_search", strings.NewReader(q))
				req.SetBasicAuth("admin", "Complexpass#123")
				req.Header.Set("Content-Type", "application/json")
				resp, err := http.DefaultClient.Do(req)
				if err == nil {
					var d struct{ Hits struct{ Total struct{ Value int } } }
					json.NewDecoder(resp.Body).Decode(&d)
					resp.Body.Close()
					if d.Hits.Total.Value > 0 {
						break
					}
				}
				time.Sleep(50 * time.Millisecond)
			}
			lat = append(lat, time.Since(t0).Seconds())
			time.Sleep(500 * time.Millisecond)
		}
		sort.Float64s(lat)
		fmt.Printf("publish->searchable over %d probes: p50=%.2fs p95=%.2fs max=%.2fs\n", len(lat), lat[len(lat)/2], lat[int(float64(len(lat))*0.95)], lat[len(lat)-1])
		return
	}
	r := rand.New(rand.NewSource(int64(*start)))
	t0 := time.Now()
	var raw int64
	for ln := *start; ln < *start+*n; {
		docs := make([]map[string]any, 0, *batch)
		for i := 0; i < *batch && ln < *start+*n; i, ln = i+1, ln+1 {
			l := line(r, ln)
			raw += int64(len(l)) + 1
			id := fmt.Sprintf("%s:%d", *job, ln)
			if *pad {
				id = fmt.Sprintf("%s:%010d", *job, ln)
			}
			docs = append(docs, map[string]any{"id": id, "doc": map[string]any{"job": *job, "ln": ln, "line": l}})
		}
		b, _ := json.Marshal(map[string]any{"kind": "docs", "index": *index, "docs": docs})
		for {
			if _, err := js.PublishAsync(*stream+".logs", b); err == nil {
				break
			}
			time.Sleep(time.Millisecond) // max pending reached: backpressure
		}
		if *rate > 0 {
			time.Sleep(time.Duration(float64(*batch) / float64(*rate) * float64(time.Second)))
		}
		if (ln-*start)%1_000_000 < *batch && ln > *start {
			fmt.Printf("%d lines, %.0f lines/s, raw %.0f MiB\n", ln-*start, float64(ln-*start)/time.Since(t0).Seconds(), float64(raw)/1048576)
		}
	}
	<-js.PublishAsyncComplete()
	fmt.Printf("published %d lines (%.0f MiB raw text) in %.1fs = %.0f lines/s\n", *n, float64(raw)/1048576, time.Since(t0).Seconds(), float64(*n)/time.Since(t0).Seconds())
	_ = os.Stdout
}
