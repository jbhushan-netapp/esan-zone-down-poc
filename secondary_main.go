package main

import (
	"bufio"
	"crypto/rand"
	"encoding/binary"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	timestampLayout  = "2006-01-02T15:04:05Z"
	listenPort       = "4000"
	blockSize        = 512
	maxWriteFailures = 3
)

type heartbeatTracker struct {
	mu       sync.Mutex
	lastTCP  time.Time
	lastDisk time.Time
}

func (h *heartbeatTracker) updateTCP() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.lastTCP = time.Now()
}

func (h *heartbeatTracker) updateDisk() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.lastDisk = time.Now()
}

func (h *heartbeatTracker) bothChannelsStale(timeout time.Duration) (stale bool, tcpAge, diskAge time.Duration, lastTCP, lastDisk time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	lastTCP = h.lastTCP
	lastDisk = h.lastDisk
	tcpAge = time.Since(lastTCP)
	diskAge = time.Since(lastDisk)
	stale = tcpAge > timeout && diskAge > timeout
	return
}

func (h *heartbeatTracker) reset() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.lastTCP = time.Now()
	h.lastDisk = time.Now()
}

func main() {
	devicesFlag := flag.String("devices", "", "Comma-separated block device paths")
	keyFlag := flag.String("pr-key", "", "Persistent reservation key in hex")
	timeout := flag.Duration("timeout", 10*time.Second, "Heartbeat timeout before takeover")
	logFile := flag.String("log-file", "", "Log file path (optional)")
	flag.Parse()

	if *devicesFlag == "" {
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

	registerAllKeys(devices, key)

	tracker := &heartbeatTracker{lastTCP: time.Now(), lastDisk: time.Now()}

	go listenForPrimaryHeartbeats(tracker)
	for _, dev := range devices {
		go readTimestampFromDeviceLoop(dev, tracker)
	}

	for {
		log.Printf("monitoring primary with %v timeout across %d devices (both channels must fail)", *timeout, len(devices))
		detectedAt, tcpAge, diskAge, lastTCP, lastDisk := waitForStaleHeartbeats(*timeout, tracker)

		performTakeover(devices, key, detectedAt, tcpAge, diskAge, lastTCP, lastDisk, *timeout)

		writeTimestampsUntilPreempted(devices)

		log.Println("=== PREEMPTED — returning to standby ===")
		tracker.reset()
		registerAllKeys(devices, key)
	}
}

func registerAllKeys(devices []string, key string) {
	var wg sync.WaitGroup
	for _, dev := range devices {
		wg.Add(1)
		go func(d string) {
			defer wg.Done()
			if err := registerReservationKey(d, key); err != nil {
				log.Printf("warning: [%s] register failed: %v", d, err)
			}
		}(dev)
	}
	wg.Wait()
	log.Printf("registered reservation key on %d devices", len(devices))
}

// --- log file management ---

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

// --- heartbeat receivers ---

func listenForPrimaryHeartbeats(tracker *heartbeatTracker) {
	ln, err := net.Listen("tcp", ":"+listenPort)
	if err != nil {
		log.Fatalf("failed to listen on port %s: %v", listenPort, err)
	}
	log.Printf("listening for primary heartbeats on :%s", listenPort)
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept failed: %v", err)
			continue
		}
		go handlePrimaryConnection(conn, tracker)
	}
}

func handlePrimaryConnection(conn net.Conn, tracker *heartbeatTracker) {
	defer conn.Close()
	log.Printf("primary connected from %s", conn.RemoteAddr())
	scanner := bufio.NewScanner(conn)
	scanner.Split(splitOnNull)
	for scanner.Scan() {
		ts := scanner.Text()
		if ts != "" {
			log.Printf("primary heartbeat (tcp): %s", ts)
			tracker.updateTCP()
		}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("primary connection read error: %v", err)
	}
	log.Printf("primary disconnected from %s", conn.RemoteAddr())
}

func splitOnNull(data []byte, atEOF bool) (advance int, token []byte, err error) {
	for i, b := range data {
		if b == 0 {
			return i + 1, data[:i], nil
		}
	}
	if atEOF && len(data) > 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}

func readTimestampFromDeviceLoop(device string, tracker *heartbeatTracker) {
	buf := alignedBuffer(blockSize)
	var lastRaw string
	for {
		raw, err := readTimestampFromDevice(device, buf)
		if err != nil {
			log.Printf("[%s] read failed: %v", device, err)
		} else if raw != lastRaw && raw != "" {
			lastRaw = raw
			role, ts := parseRoleTimestamp(raw)
			log.Printf("[%s] heartbeat (disk) from %s: %s", device, role, ts)
			tracker.updateDisk()
		}
		time.Sleep(1 * time.Second)
	}
}

func parseRoleTimestamp(raw string) (role, ts string) {
	if i := strings.Index(raw, ":"); i > 0 && i < len(raw)-1 {
		return raw[:i], raw[i+1:]
	}
	return "unknown", raw
}

func readTimestampFromDevice(device string, buf []byte) (string, error) {
	f, err := os.OpenFile(device, os.O_RDONLY|syscall.O_DIRECT, 0)
	if err != nil {
		return "", err
	}
	defer f.Close()
	n, err := f.ReadAt(buf, 0)
	if err != nil && n == 0 {
		return "", err
	}
	_, _, _ = syscall.Syscall6(syscall.SYS_FADVISE64, f.Fd(), 0, 0, 4, 0, 0)
	return strings.TrimRight(string(buf[:n]), "\x00 "), nil
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

// --- monitoring and takeover ---

func waitForStaleHeartbeats(timeout time.Duration, tracker *heartbeatTracker) (detectedAt time.Time, tcpAge, diskAge time.Duration, lastTCP, lastDisk time.Time) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		stale, ta, da, lt, ld := tracker.bothChannelsStale(timeout)
		if stale {
			return time.Now().UTC(), ta, da, lt, ld
		}
	}
	return
}

func performTakeover(devices []string, key string, detectedAt time.Time, tcpAge, diskAge time.Duration, lastTCP, lastDisk time.Time, timeout time.Duration) {
	overallStart := time.Now()
	log.Println("=== TAKEOVER STARTED ===")
	log.Printf("both heartbeat channels lost — tcp: %v, disk: %v (threshold %v)",
		tcpAge.Round(time.Second), diskAge.Round(time.Second), timeout)

	var wg sync.WaitGroup
	results := make([]string, len(devices))
	for i, dev := range devices {
		wg.Add(1)
		go func(idx int, device string) {
			defer wg.Done()
			devStart := time.Now()

			holderKey, _ := readReservationHolderKey(device)
			if holderKey != "" && holderKey != key {
				if err := preemptReservation(device, key, holderKey); err != nil {
					results[idx] = fmt.Sprintf("[%s] preempt FAILED: %v", device, err)
					return
				}
			}
			if err := takeExclusiveAccessReservation(device, key); err != nil {
				results[idx] = fmt.Sprintf("[%s] reserve FAILED: %v", device, err)
				return
			}
			results[idx] = fmt.Sprintf("[%s] acquired (%v)", device, time.Since(devStart).Round(time.Millisecond))
		}(i, dev)
	}
	wg.Wait()

	totalDur := time.Since(overallStart)
	completedAt := time.Now().UTC()

	log.Println("=== TAKEOVER COMPLETE — now acting as primary ===")
	log.Println("=== TAKEOVER REPORT ===")
	log.Printf("  last tcp heartbeat at:  %s", lastTCP.UTC().Format(timestampLayout))
	log.Printf("  last disk heartbeat at: %s", lastDisk.UTC().Format(timestampLayout))
	log.Printf("  tcp channel stale for:  %v", tcpAge.Round(time.Millisecond))
	log.Printf("  disk channel stale for: %v", diskAge.Round(time.Millisecond))
	log.Printf("  timeout threshold:      %v", timeout)
	log.Printf("  failure detected at:    %s", detectedAt.Format(timestampLayout))
	for _, r := range results {
		log.Printf("  %s", r)
	}
	log.Printf("  total takeover time:    %v", totalDur.Round(time.Millisecond))
	log.Printf("  takeover completed at:  %s", completedAt.Format(timestampLayout))
	log.Println("=======================")
}

// writeTimestampsUntilPreempted writes to all devices in parallel and returns
// when all devices report persistent write failures (preempted).
func writeTimestampsUntilPreempted(devices []string) {
	var preemptedCount atomic.Int32
	total := int32(len(devices))
	done := make(chan struct{})

	for _, dev := range devices {
		go func(device string) {
			f, err := os.OpenFile(device, os.O_WRONLY|syscall.O_DIRECT, 0)
			if err != nil {
				log.Printf("[%s] failed to open for writing: %v", device, err)
				if preemptedCount.Add(1) >= total {
					select {
					case done <- struct{}{}:
					default:
					}
				}
				return
			}
			defer f.Close()

			buf := alignedBuffer(blockSize)
			ticker := time.NewTicker(1 * time.Second)
			defer ticker.Stop()

			consecutiveFailures := 0
			for range ticker.C {
				for i := range buf {
					buf[i] = 0
				}
				ts := "secondary:" + time.Now().UTC().Format(timestampLayout)
				copy(buf, ts)
				if _, err := f.WriteAt(buf, 0); err != nil {
					consecutiveFailures++
					log.Printf("[%s] write failed (%d/%d): %v", device, consecutiveFailures, maxWriteFailures, err)
					if consecutiveFailures >= maxWriteFailures {
						log.Printf("[%s] preempted", device)
						if preemptedCount.Add(1) >= total {
							select {
							case done <- struct{}{}:
							default:
							}
						}
						return
					}
				} else {
					consecutiveFailures = 0
				}
			}
		}(dev)
	}

	<-done
	log.Println("all devices preempted — stopping writes")
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

func alignedBuffer(size int) []byte {
	buf := make([]byte, size+blockSize)
	offset := int(blockSize - uintptr(unsafe.Pointer(&buf[0]))%uintptr(blockSize))
	if offset == blockSize {
		offset = 0
	}
	return buf[offset : offset+size]
}
