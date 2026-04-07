datacenter           = "litefs-dc"
log_level            = "WARN"
disable_update_check = true
enable_script_checks = false

# Tắt DNS port (không cần, tránh conflict)
ports {
  http  = 8500
  https = -1
  grpc  = -1
  dns   = -1
}

# Tăng tốc Raft election khi node fail
performance {
  raft_multiplier = 1
}
