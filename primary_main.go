package main

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	timestampLayout = "2006-01-02T15:04:05Z"
	remotePort      = "4000"
	blockSize       = 512
)

func main() {
	devicesFlag := flag.String("devices", "", "Comma-separated block device paths (e.g. /dev/sda,/dev/sdb)")
	remoteIP := flag.String("remote-ip", "", "Remote computer IP address")
	keyFlag := flag.String("pr-key", "", "Persistent reservation key in hex")
	logFile := flag.String("log-file", "", "Log file path (optional)")
	flag.Parse()

	if *devicesFlag == "" || *remoteIP == "" {
		flag.Usage()
		os.Exit(1)
	}

	if *logFile != "" {
		setupLogFile(*logFile)
	}

	devices := strings.Split(*devicesFlag, ",")
	log.Printf("managing %d devices: %v", len(devices), devices)

	for _, dev := range devices {
		disableReadAhead(dev)
	}

	key, err := reservationKey(*keyFlag)
	if err != nil {
		log.Fatalf("invalid reservation key: %v", err)
	}
	log.Printf("using persistent reservation key: %s", key)

	acquireAllDevices(devices, key)

	for _, dev := range devices {
		go writeTimestampToDeviceLoop(dev)
	}
	go writeTimestampToRemoteLoop(*remoteIP)

	select {}
}

func acquireAllDevices(devices []string, key string) {
	overallStart := time.Now()
	var wg sync.WaitGroup
	errs := make([]error, len(devices))

	for i, dev := range devices {
		wg.Add(1)
		go func(idx int, device string) {
			defer wg.Done()
			if err := registerReservationKey(device, key); err != nil {
				errs[idx] = fmt.Errorf("%s: register failed: %w", device, err)
				return
			}
			if err := acquireOrPreempt(device, key); err != nil {
				errs[idx] = fmt.Errorf("%s: acquire failed: %w", device, err)
			}
		}(i, dev)
	}
	wg.Wait()

	totalDur := time.Since(overallStart)
	failed := 0
	for _, e := range errs {
		if e != nil {
			log.Printf("ERROR: %v", e)
			failed++
		}
	}

	if failed > 0 {
		log.Fatalf("failed to acquire %d/%d devices in %v", failed, len(devices), totalDur.Round(time.Millisecond))
	}
	log.Printf("=== ALL %d DEVICES ACQUIRED in %v ===", len(devices), totalDur.Round(time.Millisecond))
}

func acquireOrPreempt(device, key string) error {
	overallStart := time.Now()

	reserveStart := time.Now()
	err := takeExclusiveAccessReservation(device, key)
	reserveDur := time.Since(reserveStart)
	if err == nil {
		log.Printf("[%s] reservation acquired (%v)", device, reserveDur.Round(time.Millisecond))
		return nil
	}

	holderKey, readErr := readReservationHolderKey(device)
	if readErr != nil {
		return fmt.Errorf("could not read reservation holder: %w", readErr)
	}
	if holderKey == "" {
		return fmt.Errorf("no reservation holder but reserve failed: %w", err)
	}
	if holderKey == key {
		log.Printf("[%s] we already hold the reservation", device)
		return nil
	}

	preemptStart := time.Now()
	if err := preemptReservation(device, key, holderKey); err != nil {
		return fmt.Errorf("preempt failed: %w", err)
	}
	preemptDur := time.Since(preemptStart)

	if err := takeExclusiveAccessReservation(device, key); err != nil {
		return fmt.Errorf("reserve after preempt failed: %w", err)
	}

	totalDur := time.Since(overallStart)
	log.Printf("[%s] === TAKEOVER: preempted %s (preempt %v, total %v) ===",
		device, holderKey, preemptDur.Round(time.Millisecond), totalDur.Round(time.Millisecond))
	return nil
}

// --- SCSI PR helpers ---

func reservationKey(flagKey string) (string, error) {
	trimmed := strings.TrimSpace(flagKey)
	if trimmed != "" {
		if !strings.HasPrefix(trimmed, "0x") {
			return "", fmt.Errorf("key must have 0x prefix")
		}
		return trimmed, nil
	}
	var raw [8]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("generate random key: %w", err)
	}
	key := binary.BigEndian.Uint64(raw[:])
	if key == 0 {
		key = 1
	}
	return fmt.Sprintf("0x%016x", key), nil
}

func registerReservationKey(device, key string) error {
	return runSgPersist(device, "--out", "--register-ignore", fmt.Sprintf("--param-sark=%s", key))
}

func takeExclusiveAccessReservation(device, key string) error {
	return runSgPersist(device, "--out", "--reserve", fmt.Sprintf("--param-rk=%s", key), "--prout-type=5")
}

func readReservationHolderKey(device string) (string, error) {
	cmd := exec.Command("sg_persist", "--in", "--read-reservation", device)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("sg_persist --read-reservation: %w\noutput: %s", err, strings.TrimSpace(string(out)))
	}
	for _, line := range strings.Split(string(out), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "Key=") {
			return strings.TrimSpace(strings.TrimPrefix(trimmed, "Key=")), nil
		}
	}
	return "", nil
}

func preemptReservation(device, myKey, theirKey string) error {
	return runSgPersist(device, "--out", "--preempt",
		fmt.Sprintf("--param-rk=%s", myKey),
		fmt.Sprintf("--param-sark=%s", theirKey),
		"--prout-type=5")
}

func runSgPersist(device string, args ...string) error {
	fullArgs := append(args, device)
	cmd := exec.Command("sg_persist", fullArgs...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("sg_persist %v failed: %w, output: %s", args, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// --- logging ---

func setupLogFile(path string) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		log.Fatalf("failed to create log directory %s: %v", dir, err)
	}
	if info, err := os.Stat(path); err == nil && info.Size() > 0 {
		rotated := fmt.Sprintf("%s.%s", path, time.Now().Format("20060102T150405"))
		if err := os.Rename(path, rotated); err != nil {
			log.Printf("warning: could not rotate log %s: %v", path, err)
		}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		log.Fatalf("failed to open log file %s: %v", path, err)
	}
	log.SetOutput(f)
}

func disableReadAhead(device string) {
	devName := filepath.Base(device)
	sysPath := fmt.Sprintf("/sys/block/%s/queue/read_ahead_kb", devName)
	if err := os.WriteFile(sysPath, []byte("0"), 0644); err != nil {
		log.Printf("warning: could not disable read-ahead on %s: %v", device, err)
	} else {
		log.Printf("disabled read-ahead on %s", device)
	}
}

// --- device I/O ---

func alignedBuffer(size int) []byte {
	buf := make([]byte, size+blockSize)
	offset := int(blockSize - uintptr(unsafe.Pointer(&buf[0]))%uintptr(blockSize))
	if offset == blockSize {
		offset = 0
	}
	return buf[offset : offset+size]
}

func writeTimestampToDeviceLoop(device string) {
	f, err := os.OpenFile(device, os.O_WRONLY|syscall.O_DIRECT, 0)
	if err != nil {
		log.Fatalf("failed to open block device %q: %v", device, err)
	}
	defer f.Close()

	buf := alignedBuffer(blockSize)
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		for i := range buf {
			buf[i] = 0
		}
		ts := "primary:" + time.Now().UTC().Format(timestampLayout)
		copy(buf, ts)
		if _, err := f.WriteAt(buf, 0); err != nil {
			log.Printf("[%s] write failed: %v", device, err)
		}
	}
}

// --- TCP heartbeat ---

func writeTimestampToRemoteLoop(remoteIP string) {
	address := net.JoinHostPort(remoteIP, remotePort)
	for {
		conn, err := net.DialTimeout("tcp", address, 2*time.Second)
		if err != nil {
			log.Printf("tcp connect to %s failed: %v", address, err)
			time.Sleep(1 * time.Second)
			continue
		}
		log.Printf("connected to %s", address)
		if err := streamTimestamps(conn); err != nil {
			log.Printf("connection to %s terminated: %v", address, err)
		}
		_ = conn.Close()
		time.Sleep(500 * time.Millisecond)
	}
}

func streamTimestamps(conn net.Conn) error {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		ts := time.Now().UTC().Format(timestampLayout) + "\x00"
		if err := conn.SetWriteDeadline(time.Now().Add(1 * time.Second)); err != nil {
			return fmt.Errorf("set write deadline: %w", err)
		}
		if err := writeAllWithDeadline(conn, []byte(ts)); err != nil {
			return err
		}
	}
	return nil
}

func writeAllWithDeadline(conn net.Conn, buf []byte) error {
	for len(buf) > 0 {
		n, err := conn.Write(buf)
		if err != nil {
			if errors.Is(err, os.ErrDeadlineExceeded) {
				return fmt.Errorf("write exceeded deadline: %w", err)
			}
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				return fmt.Errorf("write exceeded deadline: %w", err)
			}
			return fmt.Errorf("write failed: %w", err)
		}
		if n == 0 {
			return io.ErrUnexpectedEOF
		}
		buf = buf[n:]
	}
	if err := conn.SetWriteDeadline(time.Time{}); err != nil {
		return fmt.Errorf("clear write deadline: %w", err)
	}
	return nil
}
