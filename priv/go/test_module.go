package main

import (
	"encoding/json"
	"erlport/erlport/erlang"
	"erlport/erlport/erlproto"
	"flag"
	"fmt"
	"os"
	"strings"
)

// All functions receive JSON strings (as []byte from Erlang binary)
// and return JSON strings (as []byte to become Erlang binary)
// This matches the Python pattern used in erlcracker

// fibonacci calculates the nth Fibonacci number
// Input: JSON integer n
// Output: JSON integer (nth fibonacci number)
func fibonacci(jsonInput []byte) []byte {
	var n int
	if err := json.Unmarshal(jsonInput, &n); err != nil {
		panic(err)
	}

	result := fib(n)
	jsonOutput, err := json.Marshal(result)
	if err != nil {
		panic(err)
	}
	return jsonOutput
}

func fib(n int) int {
	if n <= 1 {
		return n
	}
	return fib(n-1) + fib(n-2)
}

// processUser processes user data and returns enhanced version
// Input: JSON map with keys: id, name, email
// Output: JSON map with processed data
func processUser(jsonInput []byte) []byte {
	var user map[string]interface{}
	if err := json.Unmarshal(jsonInput, &user); err != nil {
		panic(err)
	}

	name := user["name"].(string)
	email := user["email"].(string)

	result := map[string]interface{}{
		"id":        user["id"],
		"name":      strings.ToUpper(name),
		"email":     strings.ToLower(email),
		"processed": true,
	}

	jsonOutput, err := json.Marshal(result)
	if err != nil {
		panic(err)
	}
	return jsonOutput
}

// echo returns the input unchanged
// Input: any JSON-serializable data
// Output: same data
func echo(jsonInput []byte) []byte {
	// Just return the JSON as-is
	return jsonInput
}

// batchSum sums a list of numbers
// Input: JSON array of numbers
// Output: JSON integer (sum)
func batchSum(jsonInput []byte) []byte {
	var numbers []interface{}
	if err := json.Unmarshal(jsonInput, &numbers); err != nil {
		panic(err)
	}

	sum := 0.0
	for _, num := range numbers {
		// Handle different numeric types from JSON
		switch v := num.(type) {
		case float64:
			sum += v
		case int:
			sum += float64(v)
		case int64:
			sum += float64(v)
		}
	}

	jsonOutput, err := json.Marshal(int(sum))
	if err != nil {
		panic(err)
	}
	return jsonOutput
}

func main() {
	// Parse command-line flags for erlport communication
	var packet int
	var stdio bool
	var noUseStdio bool
	var compressed int
	var bufferSize int

	flag.IntVar(&packet, "packet", 4, "Message length sent in N bytes")
	flag.BoolVar(&stdio, "use_stdio", true, "Use stdin/stdout")
	flag.BoolVar(&noUseStdio, "nouse_stdio", false, "Use fd3/fd4")
	flag.IntVar(&compressed, "compressed", 0, "Compression level")
	flag.IntVar(&bufferSize, "buffer_size", 65536, "Buffer size")

	flag.Parse()

	useStdio := stdio && !noUseStdio

	// Create port for communication with Erlang
	port, err := erlproto.NewPort(packet, useStdio, compressed, bufferSize)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating port: %v\n", err)
		os.Exit(1)
	}

	// Create message handler
	handler := erlang.NewMessageHandler(port)

	// Register functions that can be called from Erlang
	// Note: Go runtime uses flat namespace (module parameter is ignored)
	// Each function receives []byte (Erlang binary with JSON) and returns []byte
	handler.Register("fibonacci", fibonacci)
	handler.Register("process_user", processUser)
	handler.Register("echo", echo)
	handler.Register("batch_sum", batchSum)

	// Start message loop (blocks until port closes)
	handler.Start()
}
