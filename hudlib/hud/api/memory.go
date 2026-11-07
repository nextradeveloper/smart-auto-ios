package api

import "runtime/debug"

// SetMemoryLimit caps the Go heap (soft limit, see runtime/debug.SetMemoryLimit) and
// returns the previous limit. The iOS broadcast upload extension is killed at about
// 50 MB, and the Go runtime is only one of several tenants of that budget.
func SetMemoryLimit(limitBytes int64) int64 {
	return debug.SetMemoryLimit(limitBytes)
}

// FreeMemory forces a GC and returns as much memory to the OS as possible. Called
// when iOS warns the extension about memory pressure.
func FreeMemory() {
	debug.FreeOSMemory()
}
