{
  pid = $1
  parent[pid] = $2
  cpu[pid] = $3
  rss[pid] = $4
  $1 = $2 = $3 = $4 = ""
  sub(/^[[:space:]]+/, "")
  command[pid] = $0
  ids[++count] = pid
}

function owned_by_app(pid, cursor, steps) {
  cursor = parent[pid]
  while (cursor && cursor != 1 && steps++ <= count) {
    if (cursor == app_pid) return 1
    cursor = parent[cursor]
  }
  return 0
}

END {
  for (row_index = 1; row_index <= count; row_index++) {
    pid = ids[row_index]
    if (pid == app_pid) {
      printf "%s\t%s\t%s\t%s\t%s\tapp\t%s\t%s\n", captured_at, pid, parent[pid], cpu[pid], rss[pid], app_pid, command[pid]
    } else if (command[pid] ~ /com\.apple\.WebKit\.(WebContent|GPU|Networking)/ && owned_by_app(pid)) {
      printf "%s\t%s\t%s\t%s\t%s\tapp-owned-webkit-process\t%s\t%s\n", captured_at, pid, parent[pid], cpu[pid], rss[pid], app_pid, command[pid]
    }
  }
}
