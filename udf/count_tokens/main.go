// count_tokens — a ClickHouse Cloud executable UDF, Native runtime (Go).
//
// Deploy as: type = executable_pool, runtime = Native, format = RowBinary,
// send_chunk_header = true, deterministic = true.
//
// Arguments: (model String, text String) -> UInt32
//
// Wire protocol (what ClickHouse sends on stdin / expects on stdout):
//   1. A chunk header: the row count as decimal text, then '\n'.
//   2. N RowBinary rows: each String is a LEB128 length followed by raw bytes.
//   3. We answer with N UInt32 values, little-endian, and flush once per chunk.
//   4. Repeat until stdin closes. The process is long-lived (pool).
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/tiktoken-go/tokenizer"
)

// models.json ships next to the binary in the zip. It lets you map new model
// names to an encoding without recompiling.
type modelRule struct {
	Prefix   string `json:"prefix"`
	Encoding string `json:"encoding"`
}

var (
	rules  []modelRule
	codecs = map[tokenizer.Encoding]tokenizer.Codec{}
	// Models we don't recognise get o200k_base. That is an approximation for
	// non-OpenAI tokenizers; see the blog post for how we handle those.
	defaultEncoding = tokenizer.O200kBase
)

// dataFile resolves a bundled data file relative to the executable. The sandbox
// does not start the process in the bundle directory (the working directory is
// `/`, the bundle is under `/scripts`), so a cwd-relative read fails.
func dataFile(name string) string {
	exe, err := os.Executable()
	if err != nil {
		exe = os.Args[0]
	}
	return filepath.Join(filepath.Dir(exe), name)
}

func loadRules() {
	path := dataFile("models.json")
	data, err := os.ReadFile(path)
	if err != nil {
		// Fail loudly: the zip always contains models.json, so a missing file
		// means the deployment is wrong, not that there are no rules.
		fmt.Fprintf(os.Stderr, "count_tokens: cannot read %s: %v\n", path, err)
		os.Exit(1)
	}
	if err := json.Unmarshal(data, &rules); err != nil {
		fmt.Fprintf(os.Stderr, "count_tokens: bad %s: %v\n", path, err)
		os.Exit(1)
	}
	// Longest prefix wins.
	sort.Slice(rules, func(i, j int) bool { return len(rules[i].Prefix) > len(rules[j].Prefix) })
}

func codec(enc tokenizer.Encoding) tokenizer.Codec {
	if c, ok := codecs[enc]; ok {
		return c
	}
	c, err := tokenizer.Get(enc)
	if err != nil {
		fmt.Fprintf(os.Stderr, "count_tokens: unsupported encoding %q: %v\n", enc, err)
		os.Exit(1)
	}
	codecs[enc] = c
	return c
}

func codecFor(model string) tokenizer.Codec {
	for _, r := range rules {
		if strings.HasPrefix(model, r.Prefix) {
			return codec(tokenizer.Encoding(r.Encoding))
		}
	}
	if c, err := tokenizer.ForModel(tokenizer.Model(model)); err == nil {
		return c
	}
	return codec(defaultEncoding)
}

func readString(r *bufio.Reader) (string, error) {
	n, err := binary.ReadUvarint(r)
	if err != nil {
		return "", err
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return "", err
	}
	return string(buf), nil
}

func main() {
	loadRules()
	in := bufio.NewReaderSize(os.Stdin, 1<<20)
	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	var u32 [4]byte

	for {
		header, err := in.ReadString('\n')
		if err == io.EOF && header == "" {
			return // ClickHouse closed the pipe; the pool process exits cleanly
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "count_tokens: reading chunk header: %v\n", err)
			os.Exit(1)
		}
		rows, err := strconv.Atoi(strings.TrimSpace(header))
		if err != nil {
			fmt.Fprintf(os.Stderr, "count_tokens: bad chunk header %q\n", header)
			os.Exit(1)
		}
		for i := 0; i < rows; i++ {
			model, err := readString(in)
			if err == nil {
				var text string
				if text, err = readString(in); err == nil {
					var n int
					if n, err = codecFor(model).Count(text); err == nil {
						binary.LittleEndian.PutUint32(u32[:], uint32(n))
						_, err = out.Write(u32[:])
					}
				}
			}
			if err != nil {
				fmt.Fprintf(os.Stderr, "count_tokens: row %d: %v\n", i, err)
				os.Exit(1)
			}
		}
		if err := out.Flush(); err != nil {
			os.Exit(1)
		}
	}
}
