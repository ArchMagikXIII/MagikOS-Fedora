# Performance tweaks

These are optional performance optimizations applied to this system.

## CPU
- Tuned profile: throughput-performance
- CPU governor: performance

## Memory
- vm.swappiness: 10 (reduce swap usage, prefer RAM)
- vm.vfs_cache_pressure: 50
- vm.dirty_ratio: 10, vm.dirty_background_ratio: 5

## Storage (sda)
- I/O scheduler: mq-deadline
- nr_requests: 256
- read_ahead_kb: 2048

To persist across reboots, the sysctl settings are stored in `/etc/sysctl.d/99-performance.conf`. Disk scheduler tweaks can be applied at boot via systemd if needed.
