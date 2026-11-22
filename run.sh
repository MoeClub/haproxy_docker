#!/bin/sh
set -e

CONF_DIR="${CONF_DIR:-/etc/haproxy}"
MAP_FILE="${CONF_DIR}/haproxy.map"
DNS_CONF="${CONF_DIR}/dnsmasq.conf"
HAPROXY_CONF="${CONF_DIR}/haproxy.cfg"
TPROXY_CONF="${CONF_DIR}/haproxy-tproxy.cfg"

mkdir -p /var/run "${CONF_DIR}"

# 1. 首次启动备份干净的原始模板（.tpl），后续每次启动/restart 均从模板重新渲染
for f in "${DNS_CONF}" "${HAPROXY_CONF}" "${TPROXY_CONF}"; do
  if [ -f "${f}" ] && [ ! -f "${f}.tpl" ]; then
    cp -f "${f}" "${f}.tpl"
  fi
  if [ -f "${f}.tpl" ]; then
    cp -f "${f}.tpl" "${f}"
  fi
done
if [ -f "${MAP_FILE}" ] && [ ! -f "${MAP_FILE}.tpl" ]; then
  cp -f "${MAP_FILE}" "${MAP_FILE}.tpl"
fi
if [ -f "${MAP_FILE}.tpl" ] && grep -Eq '^# Auto-generated from (TABLE|ALLOW|DENY) ' "${MAP_FILE}" 2>/dev/null; then
  cp -f "${MAP_FILE}.tpl" "${MAP_FILE}"
fi

is_ipv4() {
  case "$1" in
    ""|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac
  ip_rem="$1."
  ip_cnt=0
  while [ -n "${ip_rem}" ]; do
    ip_oct="${ip_rem%%.*}"
    ip_rem="${ip_rem#*.}"
    ip_cnt=$((ip_cnt + 1))
    case "${ip_oct}" in ""|0[0-9]*) return 1 ;; esac
    [ "${ip_cnt}" -le 4 ] && [ "${ip_oct}" -le 255 ] || return 1
  done
  [ "${ip_cnt}" -eq 4 ]
}

is_port() {
  case "$1" in
    ""|0*|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

default_route_dev() {
  dev_out=$(ip -4 route show default table main 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  [ -n "${dev_out}" ] || dev_out=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  printf '%s' "${dev_out}"
}

# 2. 时区设置
if [ -n "${TZ}" ] && [ -e "/usr/share/zoneinfo/${TZ}" ]; then
  cp -rf "/usr/share/zoneinfo/${TZ}" /etc/localtime
fi

# 3. 识别全局参数 LOWAT 与运行模式开关（纯 IPv4 架构）
#    LOWAT 默认 131072（128KB），设为 0 则保持注释不启用 TCP_NOTSENT_LOWAT；
#    TPROXY 默认留空（或 0）为 SNI/Host 分流 + DNS 解锁模式；
#    设置 TPROXY=1 / <网卡或网段> / [SOURCE],[BIND:]PORT[,INPUT[,FWMARK]] 进入全端口透明 TCP 截断模式
lowat_raw=$(printf '%s' "${LOWAT:-131072}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
case "${lowat_raw}" in
  0|0k|0kb|0m|0mb|off|false|no|none) lowat="0" ;;
  *[0-9]k|*[0-9]kb)
    lowat_num="${lowat_raw%b}"; lowat_num="${lowat_num%k}"
    case "${lowat_num}" in
      *[!0-9]*|"") lowat="" ;;
      *) lowat_num=$(printf '%s' "${lowat_num}" | sed 's/^0*//'); lowat=$(( ${lowat_num:-0} * 1024 )) ;;
    esac
    ;;
  *[0-9]m|*[0-9]mb)
    lowat_num="${lowat_raw%b}"; lowat_num="${lowat_num%m}"
    case "${lowat_num}" in
      *[!0-9]*|"") lowat="" ;;
      *) lowat_num=$(printf '%s' "${lowat_num}" | sed 's/^0*//'); lowat=$(( ${lowat_num:-0} * 1048576 )) ;;
    esac
    ;;
  *[!0-9]*|"") lowat="" ;;
  *)
    lowat_num=$(printf '%s' "${lowat_raw}" | sed 's/^0*//')
    lowat=$(( ${lowat_num:-0} + 0 ))
    ;;
esac
if [ -z "${lowat}" ]; then
  echo "[WARN] Invalid LOWAT \"${LOWAT}\", falling back to default 131072." >&2
  lowat="131072"
fi

tproxy_raw=$(printf '%s' "${TPROXY}" | tr -d '[:space:]')
tproxy_lc=$(printf '%s' "${tproxy_raw}" | tr '[:upper:]' '[:lower:]')
HAPROXY_BIN=$(command -v haproxy || echo /usr/sbin/haproxy)
DNSMASQ_BIN=$(command -v dnsmasq || echo /usr/sbin/dnsmasq)

# =====================================================================
# 模式 B：TPROXY 通用透明四层 TCP 截断插口模式 (纯 IPv4 三层 TPROXY + 二层网桥 REDIRECT 双引擎)
# 支持极简与完整写法：
#   1) TPROXY=1 (或 auto)              : 全自动接管本机全部过境公网 TCP（透传原客户端源IP，复用宿主机原路由与NAT）
#   2) TPROXY=ipip-22 (或 192.168.x/24): 仅接管指定网卡或源网段（多个用 ; 连接）
#   3) TPROXY=[SOURCE],[BIND:]PORT[,INPUT[,FWMARK]] : 完整自定义
#        - SOURCE : 留空/client=透传客户端源IP(usesrc clientip)；local/*=使用本机自身出口IP；或填指定 IPv4
#        - [BIND:]PORT : 留空/0/auto 动态分配空闲高位端口；省略 BIND 或 BIND: 默认监听 127.0.0.1
#        - INPUT  : 默认 auto；填网卡/网段精准挂载；填 off/none 关闭自动 iptables
#        - FWMARK : 可选，显式指定出站连接 fwmark 与关联策略路由表号
# =====================================================================
if [ -n "${tproxy_lc}" ] && [ "${tproxy_lc}" != "0" ] && [ "${tproxy_lc}" != "false" ] && [ "${tproxy_lc}" != "off" ] && [ "${tproxy_lc}" != "no" ]; then
  TP_MARK="0x88"
  TP_OUT_MARK="0x89"
  TP_TABLE="108"
  TP_PRIO="200"
  OUT_PRIO="201"

  # 全量残留自愈清理函数：不依赖当前环境变量，跨 mangle / nat / filter 三表按特征清除任意端口遗留的脏规则
  sweep_ipt() {
    ipt_bin="$1"
    command -v "${ipt_bin}" >/dev/null 2>&1 || return 0

    # 1) 清理 mangle 表挂载规则与残留子链
    "${ipt_bin}" -t mangle -S 2>/dev/null | grep -E '^-A (PREROUTING|OUTPUT|POSTROUTING) .*(HAPROXY_(TP|DIV|MSS)_|--set-xmark 0x88/|CONNMARK --set-mark 0x88)' | while IFS= read -r rule; do
      del_args="-D ${rule#-A }"
      ( set -f; "${ipt_bin}" -t mangle ${del_args} ) 2>/dev/null || true
    done
    "${ipt_bin}" -t mangle -S 2>/dev/null | awk '/^-N HAPROXY_(TP|DIV|MSS)_/ {print $2}' | while IFS= read -r ch; do
      "${ipt_bin}" -t mangle -F "${ch}" 2>/dev/null || true
      "${ipt_bin}" -t mangle -X "${ch}" 2>/dev/null || true
    done

    # 2) 清理 nat 表二层网桥 REDIRECT 挂载规则与残留子链
    "${ipt_bin}" -t nat -S 2>/dev/null | grep -E '^-A PREROUTING .*HAPROXY_NAT_' | while IFS= read -r rule; do
      del_args="-D ${rule#-A }"
      ( set -f; "${ipt_bin}" -t nat ${del_args} ) 2>/dev/null || true
    done
    "${ipt_bin}" -t nat -S 2>/dev/null | awk '/^-N HAPROXY_NAT_/ {print $2}' | while IFS= read -r ch; do
      "${ipt_bin}" -t nat -F "${ch}" 2>/dev/null || true
      "${ipt_bin}" -t nat -X "${ch}" 2>/dev/null || true
    done

    # 3) 清理 filter 表 INPUT / OUTPUT 放行与防扫描规则及残留子链
    for fch in INPUT OUTPUT; do
      "${ipt_bin}" -S "${fch}" 2>/dev/null | grep -E "^-A ${fch} .*(HAPROXY_(IN|OUT)_|--mark 0x88([ /]|$))" | while IFS= read -r rule; do
        del_args="-D ${rule#-A }"
        ( set -f; "${ipt_bin}" ${del_args} ) 2>/dev/null || true
      done
    done
    "${ipt_bin}" -S 2>/dev/null | awk '/^-N HAPROXY_(IN|OUT)_/ {print $2}' | while IFS= read -r ch; do
      "${ipt_bin}" -F "${ch}" 2>/dev/null || true
      "${ipt_bin}" -X "${ch}" 2>/dev/null || true
    done
  }

  cleanup_tproxy() {
    sweep_ipt iptables
    sweep_ipt iptables-legacy
    while ip rule del pref "${TP_PRIO}" 2>/dev/null; do :; done
    while ip rule del pref "${OUT_PRIO}" 2>/dev/null; do :; done
    ip route flush table "${TP_TABLE}" 2>/dev/null || true
  }

  # 支持一键应急清理模式：TPROXY=clean (或 reset / clear)
  if [ "${tproxy_lc}" = "clean" ] || [ "${tproxy_lc}" = "clear" ] || [ "${tproxy_lc}" = "reset" ]; then
    cleanup_tproxy
    echo "[OK] All residual TPROXY/REDIRECT iptables rules and policy routes have been cleaned up."
    exit 0
  fi

  [ -f "${TPROXY_CONF}" ] || { echo "[ERROR] Missing ${TPROXY_CONF}" >&2; exit 1; }

  out_src=""; bind_ip=""; tproxy_port=""; auto_input=""; out_mark=""
  eval "$(printf '%s\n' "${tproxy_raw}" | awk '
    function parse_bp(s,    cpos, plc) {
      if (s == "" || s == "0" || tolower(s) == "auto") {
        b_ip = "127.0.0.1"; b_pt = "auto"; return
      }
      if (index(s, ":") > 0) {
        cpos = index(s, ":")
        b_ip = substr(s, 1, cpos - 1)
        b_pt = substr(s, cpos + 1)
      } else {
        b_ip = "127.0.0.1"
        b_pt = s
      }
      if (b_ip == "") b_ip = "127.0.0.1"
      if (b_ip == "*") b_ip = "0.0.0.0"
      plc = tolower(b_pt)
      if (plc == "0" || plc == "auto" || plc == "") b_pt = "auto"
    }
    {
      n = split($0, p, ",")
      if (n == 1) {
        tok = p[1]
        tlc = tolower(tok)
        src = "client"; mk = ""
        if (tlc == "1" || tlc == "true" || tlc == "yes" || tlc == "on" || tlc == "auto") {
          b_ip = "127.0.0.1"; b_pt = "auto"; inp = "auto"
        } else if (tok ~ /^[0-9]+$/ || index(tok, ":") > 0) {
          parse_bp(tok)
          inp = "auto"
        } else {
          b_ip = "127.0.0.1"; b_pt = "auto"; inp = tok
        }
      } else {
        src = p[1]
        parse_bp(p[2])
        inp = (n >= 3 && p[3] != "") ? p[3] : "auto"
        mk  = (n >= 4) ? p[4] : ""
      }

      slc = tolower(src)
      if (slc == "" || slc == "auto" || slc == "client" || slc == "clientip") {
        src = "client"
      } else if (slc == "local" || slc == "*" || slc == "0.0.0.0") {
        src = ""
      } else {
        gsub(/[^0-9a-zA-Z._-]/, "", src)
      }

      ilc = tolower(inp)
      if (ilc == "off" || ilc == "none" || ilc == "0" || ilc == "manual" || ilc == "false") {
        inp = ""
      } else if (ilc == "auto" || ilc == "all" || ilc == "1" || ilc == "true") {
        inp = "auto"
      } else {
        gsub(/[^0-9a-zA-Z_.\/+;-]/, "", inp)
      }

      gsub(/[^0-9a-zA-Z._-]/, "", b_ip)
      if (b_pt != "auto") gsub(/[^0-9a-zA-Z._-]/, "", b_pt)
      gsub(/[[:space:]]/, "", mk)
      mlc = tolower(mk)
      if (mlc == "" || mlc == "auto" || mlc == "off" || mlc == "none" || mlc == "false" || mlc ~ /^(0+|0x0+)$/) {
        mk = ""
      } else {
        gsub(/[^0-9xXa-fA-Fg-zG-Z_-]/, "", mk)
      }

      printf "out_src=\"%s\"\nbind_ip=\"%s\"\ntproxy_port=\"%s\"\nauto_input=\"%s\"\nout_mark=\"%s\"\n", src, b_ip, b_pt, inp, mk
    }
  ')"

  pick_free_port() {
    excl="${1:-0}"
    seed=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d '[:space:]')
    [ -n "${seed}" ] || seed="$$"
    awk -v seed="${seed}" -v excl="${excl}" '
      BEGIN {
        while ((getline < "/proc/net/tcp") > 0)  if ($2 ~ /:/) { p = $2; sub(/^.*:/, "", p); used[toupper(p)] = 1 }
        close("/proc/net/tcp")
        while ((getline < "/proc/net/tcp6") > 0) if ($2 ~ /:/) { p = $2; sub(/^.*:/, "", p); used[toupper(p)] = 1 }
        close("/proc/net/tcp6")
        if (excl + 0 > 0) used[sprintf("%04X", excl + 0)] = 1
        start = 10000 + (seed % 20000)
        for (i = 0; i < 20000; i++) {
          cand = 10000 + ((start - 10000 + i) % 20000)
          if (!(sprintf("%04X", cand) in used)) {
            print cand
            exit
          }
        }
        print (excl == 10888 ? 10889 : 10888)
      }
    '
  }

  [ "${tproxy_port}" = "auto" ] && tproxy_port=$(pick_free_port 0)

  if ! is_ipv4 "${bind_ip}" || ! is_port "${tproxy_port}"; then
    echo "[ERROR] Invalid TPROXY specification: \"${TPROXY}\"" >&2
    exit 1
  fi
  if [ -n "${out_src}" ] && [ "${out_src}" != "client" ] && ! is_ipv4 "${out_src}"; then
    echo "[ERROR] Invalid IPv4 SOURCE in TPROXY specification: \"${TPROXY}\"" >&2
    exit 1
  fi
  if [ -n "${out_mark}" ] && ! printf '%s\n' "${out_mark}" | grep -Eq '^(0[xX][0-9a-fA-F]+|[1-9][0-9]*)$'; then
    echo "[ERROR] Invalid FWMARK in TPROXY specification: \"${TPROXY}\"" >&2
    exit 1
  fi

  redir_port=""
  [ -n "${auto_input}" ] && redir_port=$(pick_free_port "${tproxy_port}")

  tproxy_bind_tmp="/tmp/tproxy.bind.$$"
  tproxy_out_tmp="/tmp/tproxy.out.$$"
  tproxy_flt_tmp="/tmp/tproxy.flt.$$"
  tproxy_http_tmp="/tmp/tproxy.http.$$"
  echo "    bind ${bind_ip}:${tproxy_port} transparent backlog 4096" > "${tproxy_bind_tmp}"
  [ -n "${redir_port}" ] && echo "    bind 0.0.0.0:${redir_port} backlog 4096" >> "${tproxy_bind_tmp}"

  : > "${tproxy_out_tmp}"
  sock_mark="${out_mark}"
  if [ "${out_src}" = "client" ]; then
    echo "    source 0.0.0.0 usesrc clientip" >> "${tproxy_out_tmp}"
    [ -z "${sock_mark}" ] && sock_mark="${TP_OUT_MARK}"
  elif [ -n "${out_src}" ]; then
    echo "    source ${out_src}" >> "${tproxy_out_tmp}"
    [ -z "${sock_mark}" ] && sock_mark="${TP_OUT_MARK}"
  fi
  if [ -n "${sock_mark}" ]; then
    echo "    tcp-request content set-bc-mark ${sock_mark}" >> "${tproxy_out_tmp}"
  fi

  # 解析可选的域名:端口黑白名单 ALLOW / DENY（互斥；同时有值时优先使用 ALLOW 并清空 DENY）
  allow_clean=$(printf '%s' "${ALLOW}" | tr -d '[:space:]')
  deny_clean=$(printf '%s' "${DENY}" | tr -d '[:space:]')
  filter_mode=""
  filter_raw=""
  allow_strict_port="0"
  filter_ports=""

  if [ -n "${allow_clean}" ]; then
    filter_mode="ALLOW"
    filter_raw="${ALLOW}"
    if [ -n "${deny_clean}" ]; then
      echo "[INFO] Both ALLOW and DENY are set; using ALLOW and clearing DENY." >&2
    fi
    DENY=""
    unset DENY
  elif [ -n "${deny_clean}" ]; then
    filter_mode="DENY"
    filter_raw="${DENY}"
  fi

  if [ -n "${filter_mode}" ]; then
    tmp_fmap="/tmp/tproxy.fmap.$$"
    tmp_fports="/tmp/tproxy.fports.$$"
    tmp_fstrict="/tmp/tproxy.fstrict.$$"
    : > "${tmp_fmap}"
    : > "${tmp_fports}"
    echo "0" > "${tmp_fstrict}"

    printf '%s\n' "${filter_raw}" | tr -d '\r' | tr ';' '\n' | awk \
      -v fmode="${filter_mode}" -v ports_out="${tmp_fports}" -v strict_out="${tmp_fstrict}" '
      function trim(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
      }
      {
        line = trim($0)
        if (line == "" || substr(line, 1, 1) == "#") next

        if (substr(line, 1, 1) == "+") {
          strict_port = 1
          sub(/^\++/, "", line)
          line = trim(line)
          if (line == "") next
        }

        if (substr(line, 1, 1) == "[" || index(line, ",") > 0 || split(line, cp, ":") > 2) {
          printf "[WARN] Skipping invalid %s entry: %s\n", fmode, line > "/dev/stderr"
          next
        }

        n_col = split(line, cp, ":")
        raw_dom = trim(cp[1])
        if (n_col == 2) {
          raw_pt = trim(cp[2])
          if (raw_pt !~ /^[1-9][0-9]*$/ || (raw_pt + 0) > 65535) {
            printf "[WARN] Skipping %s entry with invalid port \"%s\": %s\n", fmode, raw_pt, line > "/dev/stderr"
            next
          }
          n_pts = 1; pts[1] = raw_pt + 0
        } else {
          n_pts = 2; pts[1] = 80; pts[2] = 443
        }

        dom_low = tolower(raw_dom)
        if (substr(dom_low, 1, 1) == "^" || substr(dom_low, 1, 1) == "@") {
          granularity = "exact"
          dom = substr(dom_low, 2)
        } else if (substr(dom_low, 1, 2) == "*.") {
          granularity = "wild"
          dom = substr(dom_low, 3)
        } else {
          granularity = "both"
          dom = dom_low
        }
        sub(/^\*+/, "", dom)
        sub(/^\.+/, "", dom)
        sub(/\.+$/, "", dom)
        if (dom == "" || length(dom) > 253 || dom ~ /[^0-9a-z._-]/) {
          printf "[WARN] Skipping invalid domain in %s: %s\n", fmode, line > "/dev/stderr"
          next
        }
        if (dom ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
          printf "[WARN] Skipping IPv4 literal in %s (IP connections always pass through): %s\n", fmode, line > "/dev/stderr"
          next
        }

        for (pi = 1; pi <= n_pts; pi++) {
          pt = pts[pi]
          port_set[pt] = 1
          k = dom ":" pt
          dom_len[k] = length(dom)
          key_pt[k]  = pt
          keys[k]    = 1
          if (granularity == "exact" || granularity == "both") exact_map[k] = 1
          if (granularity == "wild"  || granularity == "both") wild_map[k]  = 1
        }
      }
      END {
        printf "%d\n", (strict_port ? 1 : 0) > strict_out
        for (p in port_set) {
          printf "%d\n", p >> ports_out
        }
        for (k in keys) {
          len = dom_len[k]
          pt  = key_pt[k]
          if (k in exact_map) printf "%d\t2\t%d\t%-42s 1\n", len, pt, "^" k
          if (k in wild_map)  printf "%d\t1\t%d\t%-42s 1\n", len, pt, "." k
        }
      }
    ' | sort -k1,1rn -k2,2rn -k3,3n | cut -f4- > "${tmp_fmap}"

    if [ ! -s "${tmp_fmap}" ]; then
      rm -f "${tmp_fmap}" "${tmp_fports}" "${tmp_fstrict}" "${tproxy_bind_tmp}" "${tproxy_out_tmp}"
      echo "[ERROR] No valid domain entries found in ${filter_mode}." >&2
      exit 1
    fi

    allow_strict_port=$(cat "${tmp_fstrict}")
    filter_ports=$(sort -n "${tmp_fports}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    {
      echo "# Auto-generated from ${filter_mode} environment variable (Mode B TPROXY)"
      cat "${tmp_fmap}"
    } > "${MAP_FILE}"
    rm -f "${tmp_fmap}" "${tmp_fports}" "${tmp_fstrict}"

    {
      printf '%s\n' "${filter_ports}" | tr ' ' '\n' | awk '
        NF > 0 {
          line = (line == "") ? $1 : (line " " $1)
          if (++n == 16) { printf "    acl filter_port dst_port %s\n", line; line = ""; n = 0 }
        }
        END { if (n > 0) printf "    acl filter_port dst_port %s\n", line }
      '
      if [ "${filter_mode}" = "ALLOW" ] && [ "${allow_strict_port}" = "1" ]; then
        echo '    tcp-request content reject if !filter_port'
      else
        echo '    tcp-request content accept if !filter_port'
      fi
      echo '    tcp-request inspect-delay 500ms'
      echo '    tcp-request content switch-mode http if HTTP'
      echo '    tcp-request content set-var(sess.host_log) req.ssl_sni if { req.ssl_hello_type 1 } { req.ssl_sni -m found }'
      echo '    tcp-request content set-var(sess.req_sni)  req.ssl_sni,lower,rtrim(.) if { req.ssl_hello_type 1 } { req.ssl_sni -m found }'
      echo '    tcp-request content set-var-fmt(sess.match_key) ^%[var(sess.req_sni)]:%[dst_port] if { var(sess.req_sni) -m len 1:253 } !{ var(sess.req_sni) -m reg ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ }'
      echo "    tcp-request content set-var(sess.hit) var(sess.match_key),map_end(${MAP_FILE}) if { var(sess.match_key) -m found }"
      if [ "${filter_mode}" = "DENY" ]; then
        echo '    tcp-request content reject if { var(sess.hit) -m found }'
      else
        echo '    tcp-request content reject if { var(sess.match_key) -m found } !{ var(sess.hit) -m found }'
      fi
      echo '    tcp-request content accept'
      echo '    use_backend http_tproxy_out if HTTP'
    } > "${tproxy_flt_tmp}"

    {
      echo 'backend http_tproxy_out'
      echo '    mode http'
      echo '    timeout http-request    5s'
      echo '    timeout http-keep-alive 60s'
      if [ "${out_src}" = "client" ]; then
        echo '    source 0.0.0.0 usesrc clientip'
      elif [ -n "${out_src}" ]; then
        echo "    source ${out_src}"
      fi
      echo '    http-request unset-var(sess.host_log)'
      echo '    http-request set-var(sess.host_log) req.hdr(host) if { req.hdr(host) -m found }'
      echo '    http-request reject if { req.hdr_cnt(host) gt 1 }'
      echo '    http-request set-var(txn.req_host)  req.hdr(host),host_only,lower,rtrim(.) if { req.hdr(host) -m found }'
      echo '    http-request set-var-fmt(txn.match_key) ^%[var(txn.req_host)]:%[dst_port] if { var(txn.req_host) -m len 1:253 } !{ var(txn.req_host) -m reg ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ }'
      echo "    http-request set-var(txn.hit) var(txn.match_key),map_end(${MAP_FILE}) if { var(txn.match_key) -m found }"
      if [ "${filter_mode}" = "DENY" ]; then
        echo '    http-request reject if { var(txn.hit) -m found }'
      else
        echo '    http-request reject if { var(txn.match_key) -m found } !{ var(txn.hit) -m found }'
      fi
      if [ -n "${sock_mark}" ]; then
        echo "    http-request set-bc-mark ${sock_mark}"
      fi
      echo '    http-request set-dst      dst'
      echo '    http-request set-dst-port dst_port'
      echo '    server next_hop_http 0.0.0.0:0'
    } > "${tproxy_http_tmp}"
  fi

  awk -v bind_file="${tproxy_bind_tmp}" -v out_file="${tproxy_out_tmp}" \
      -v flt_file="${tproxy_flt_tmp}" -v http_file="${tproxy_http_tmp}" \
      -v fmode="${filter_mode}" -v lowat="${lowat}" '
    (lowat + 0) > 0 && /^[[:space:]]*#[[:space:]]*tune\.notsent-lowat\.(client|server)[[:space:]]/ {
      sub(/#[[:space:]]*/, ""); sub(/[0-9]+/, lowat); print; next
    }
    fmode != "" && /^[[:space:]]*log-format[[:space:]]/ {
      print "    log-format \"%ci:%cp [TPROXY] %[var(sess.host_log)] => %fi:%fp [%B bytes, %Tt ms, %ts]\""
      next
    }
    /# BEGIN_TPROXY_BIND/ { print; while ((getline line < bind_file) > 0) print line; close(bind_file); skip=1; next }
    /# END_TPROXY_BIND/   { skip=0; print; next }
    /# BEGIN_TPROXY_FILTER/ && fmode != "" { print; while ((getline line < flt_file) > 0) print line; close(flt_file); skip=1; next }
    /# END_TPROXY_FILTER/   && fmode != "" { skip=0; print; next }
    /# BEGIN_TPROXY_OUT/  { print; while ((getline line < out_file) > 0) print line; close(out_file); skip=1; next }
    /# END_TPROXY_OUT/    { skip=0; print; next }
    /# BEGIN_TPROXY_HTTP_OUT/ && fmode != "" { print; while ((getline line < http_file) > 0) print line; close(http_file); skip=1; next }
    /# END_TPROXY_HTTP_OUT/   && fmode != "" { skip=0; print; next }
    !skip { print }
  ' "${TPROXY_CONF}" > "${TPROXY_CONF}.new" && mv -f "${TPROXY_CONF}.new" "${TPROXY_CONF}"
  rm -f "${tproxy_bind_tmp}" "${tproxy_out_tmp}" "${tproxy_flt_tmp}" "${tproxy_http_tmp}"

  echo "Run Mode     : TPROXY Universal Transparent Split-TCP Plug (IPv4)"
  if [ -n "${redir_port}" ]; then
    echo "Listen Bind  : L3=${bind_ip}:${tproxy_port} (TPROXY), L2=0.0.0.0:${redir_port} (REDIRECT)"
  else
    echo "Listen Bind  : ${bind_ip}:${tproxy_port} (TPROXY)"
  fi
  if [ "${out_src}" = "client" ]; then
    echo "Outbound Src : transparent clientip (inherits host routing & NAT)"
  else
    echo "Outbound Src : ${out_src:-local auto}"
  fi
  echo "Outbound Mark: ${out_mark:-auto (${sock_mark:-none})}"
  echo "TCP Lowat    : $([ "${lowat}" = "0" ] && echo "disabled (0)" || echo "${lowat} bytes")"
  if [ "${filter_mode}" = "DENY" ]; then
    echo "Domain Filter: DENY blacklist (ports: ${filter_ports}; unlisted ports: accept)"
  elif [ "${filter_mode}" = "ALLOW" ] && [ "${allow_strict_port}" = "1" ]; then
    echo "Domain Filter: ALLOW+ strict whitelist (ports: ${filter_ports}; unlisted ports: reject)"
  elif [ "${filter_mode}" = "ALLOW" ]; then
    echo "Domain Filter: ALLOW whitelist (ports: ${filter_ports}; unlisted ports: accept)"
  else
    echo "Domain Filter: disabled (pure L4 zero-copy passthrough)"
  fi
  echo "Auto Input   : ${auto_input:-disabled (manual iptables)}"
  if [ -n "${filter_mode}" ]; then
    echo "--- Active ${filter_mode} Rules (${MAP_FILE}) ---"
    grep -vE '^[[:space:]]*(#|$)' "${MAP_FILE}" || echo "(empty)"
    echo "------------------------------------------"
  fi

  "${HAPROXY_BIN}" -v | head -n 1
  "${HAPROXY_BIN}" -c -f "${TPROXY_CONF}"

  # 若显式关闭自动拦截 (off/none)，直接前台 exec 运行 HAProxy
  if [ -z "${auto_input}" ]; then
    exec "${HAPROXY_BIN}" -W -db -f "${TPROXY_CONF}"
  fi

  # 自动探测与宿主机一致的 iptables 后端（对比 nft 与 legacy 现有规则数，兼容全系发行版）
  IPT="iptables"
  nft_rules=$(iptables-save 2>/dev/null | grep -c '^-A ' || true)
  leg_rules=0
  if command -v iptables-legacy-save >/dev/null 2>&1; then
    leg_rules=$(iptables-legacy-save 2>/dev/null | grep -c '^-A ' || true)
  fi
  if [ "${leg_rules:-0}" -gt "${nft_rules:-0}" ] && command -v iptables-legacy >/dev/null 2>&1; then
    IPT="iptables-legacy"
  elif ! iptables -t mangle -L -n >/dev/null 2>&1 && command -v iptables-legacy >/dev/null 2>&1; then
    IPT="iptables-legacy"
  fi

  TP_CHAIN="HAPROXY_TP_${tproxy_port}"
  DIV_CHAIN="HAPROXY_DIV_${tproxy_port}"
  MSS_CHAIN="HAPROXY_MSS_${tproxy_port}"
  NAT_CHAIN="HAPROXY_NAT_${redir_port}"
  IN_CHAIN="HAPROXY_IN_${tproxy_port}"
  OUT_CHAIN="HAPROXY_OUT_${tproxy_port}"
  on_ip="${bind_ip}"
  [ "${on_ip}" = "0.0.0.0" ] && on_ip="127.0.0.1"
  WAN_DEV=$(default_route_dev)

  setup_tproxy() {
    cleanup_tproxy

    # 放宽 rp_filter（含 default 以覆盖后续动态创建的 VPN 虚拟网卡）并确保开启转发；绝不触碰宿主机 bridge-nf-call-iptables
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
      [ -w "${rp}" ] && echo 0 > "${rp}" 2>/dev/null || true
    done

    # 一次性扫描宿主机当前网桥，区分“配有 IPv4 网关地址的容器网桥”与“无 IP 的纯二层透传网桥”
    v4_bridges=""
    noip_bridges=""
    for br_dir in /sys/class/net/*/bridge; do
      [ -d "${br_dir}" ] || continue
      br_if=$(basename "$(dirname "${br_dir}")")
      if [ -n "$(ip -4 -o addr show dev "${br_if}" 2>/dev/null)" ]; then
        v4_bridges="${v4_bridges} ${br_if}"
      else
        noip_bridges="${noip_bridges} ${br_if}"
      fi
    done

    # 统一目标地址旁路助手：保护本机地址 (LOCAL) 与所有保留/私网/组播网段不被代理劫持
    add_bypass_dsts() {
      tbl="$1"; chn="$2"
      if ! "${IPT}" -t "${tbl}" -A "${chn}" -m addrtype --dst-type LOCAL -j RETURN 2>/dev/null; then
        ip -4 -o addr show 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' | while IFS= read -r lip; do
          [ -n "${lip}" ] && "${IPT}" -t "${tbl}" -A "${chn}" -d "${lip}/32" -j RETURN
        done
      fi
      for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        "${IPT}" -t "${tbl}" -A "${chn}" -d "${cidr}" -j RETURN
      done
    }

    # 若显式指定了非零 FWMARK（如 100 或 0x64）且宿主机存在对应路由表，自动挂载出站策略路由
    if [ -n "${out_mark}" ] && [ -n "$(ip route show table "${out_mark}" 2>/dev/null)" ]; then
      ip rule add pref "${OUT_PRIO}" fwmark "${out_mark}" lookup "${out_mark}"
    fi

    # 建立本地 TPROXY 接收路由表
    ip rule add pref "${TP_PRIO}" fwmark "${TP_MARK}" lookup "${TP_TABLE}"
    ip route replace local 0.0.0.0/0 dev lo table "${TP_TABLE}"

    # 建立已建连/回包快速分流链 (DIVERT) 与 MSS 自动钳制链
    "${IPT}" -t mangle -N "${DIV_CHAIN}" 2>/dev/null || "${IPT}" -t mangle -F "${DIV_CHAIN}"
    "${IPT}" -t mangle -A "${DIV_CHAIN}" -j MARK --set-mark "${TP_MARK}"
    "${IPT}" -t mangle -A "${DIV_CHAIN}" -j ACCEPT

    "${IPT}" -t mangle -N "${MSS_CHAIN}" 2>/dev/null || "${IPT}" -t mangle -F "${MSS_CHAIN}"
    "${IPT}" -t mangle -A "${MSS_CHAIN}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    "${IPT}" -t mangle -I POSTROUTING 1 -p tcp -j "${MSS_CHAIN}"

    # 建立三层接口透明拦截链 (TP_CHAIN)：二层桥接帧自动旁路交由下方 NAT_CHAIN 处理
    "${IPT}" -t mangle -N "${TP_CHAIN}" 2>/dev/null || "${IPT}" -t mangle -F "${TP_CHAIN}"
    "${IPT}" -t mangle -A "${TP_CHAIN}" -i lo -j RETURN
    "${IPT}" -t mangle -A "${TP_CHAIN}" -m conntrack --ctstate DNAT -j RETURN 2>/dev/null || true
    "${IPT}" -t mangle -A "${TP_CHAIN}" -m conntrack --ctdir REPLY -j RETURN 2>/dev/null || true
    has_physdev=0
    if "${IPT}" -t mangle -A "${TP_CHAIN}" -m physdev --physdev-in + -j RETURN 2>/dev/null; then
      has_physdev=1
    else
      for br_if in ${v4_bridges} ${noip_bridges}; do
        "${IPT}" -t mangle -A "${TP_CHAIN}" -i "${br_if}" -j RETURN
      done
    fi
    add_bypass_dsts mangle "${TP_CHAIN}"
    "${IPT}" -t mangle -A "${TP_CHAIN}" -p tcp -j TPROXY --on-ip "${on_ip}" --on-port "${tproxy_port}" --tproxy-mark "${TP_MARK}"

    # 建立二层网桥容器专用拦截链 (NAT_CHAIN)：仅接管二层网桥发往外部公网的新建 TCP
    nat_ok=0
    nat_physdev=0
    if [ -n "${redir_port}" ] && "${IPT}" -t nat -L -n >/dev/null 2>&1; then
      "${IPT}" -t nat -N "${NAT_CHAIN}" 2>/dev/null || "${IPT}" -t nat -F "${NAT_CHAIN}"
      "${IPT}" -t nat -A "${NAT_CHAIN}" -i lo -j RETURN
      "${IPT}" -t nat -A "${NAT_CHAIN}" -m mark --mark "${TP_MARK}" -j RETURN 2>/dev/null || true
      if [ "${has_physdev}" = "1" ] && "${IPT}" -t nat -A "${NAT_CHAIN}" -m physdev ! --physdev-in + -j RETURN 2>/dev/null; then
        nat_physdev=1
        for br_if in ${noip_bridges}; do
          "${IPT}" -t nat -A "${NAT_CHAIN}" -i "${br_if}" -j RETURN
        done
      fi
      add_bypass_dsts nat "${NAT_CHAIN}"
      if "${IPT}" -t nat -A "${NAT_CHAIN}" -p tcp -j REDIRECT --to-ports "${redir_port}" 2>/dev/null; then
        nat_ok=1
      else
        "${IPT}" -t nat -F "${NAT_CHAIN}" 2>/dev/null || true
        "${IPT}" -t nat -X "${NAT_CHAIN}" 2>/dev/null || true
      fi
    fi

    # 建立本机 INPUT / OUTPUT 防火墙独立子链：放行代理流量，并严格封死外部直连探测 redir_port
    "${IPT}" -N "${IN_CHAIN}" 2>/dev/null || "${IPT}" -F "${IN_CHAIN}"
    "${IPT}" -A "${IN_CHAIN}" -p tcp -m mark --mark "${TP_MARK}" -j ACCEPT
    if [ "${nat_ok}" = "1" ]; then
      "${IPT}" -A "${IN_CHAIN}" -p tcp --dport "${redir_port}" -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null || \
        "${IPT}" -A "${IN_CHAIN}" -p tcp --dport "${redir_port}" ! -i "${WAN_DEV:-lo}" -j ACCEPT
      "${IPT}" -A "${IN_CHAIN}" -p tcp --dport "${redir_port}" -j DROP
    fi
    "${IPT}" -I INPUT 1 -p tcp -j "${IN_CHAIN}"

    "${IPT}" -N "${OUT_CHAIN}" 2>/dev/null || "${IPT}" -F "${OUT_CHAIN}"
    "${IPT}" -A "${OUT_CHAIN}" -p tcp -m connmark --mark "${TP_MARK}" -j ACCEPT 2>/dev/null || true
    [ -n "${sock_mark}" ] && "${IPT}" -A "${OUT_CHAIN}" -p tcp -m mark --mark "${sock_mark}" -j ACCEPT 2>/dev/null || true
    if [ "${nat_ok}" = "1" ]; then
      "${IPT}" -A "${OUT_CHAIN}" -p tcp --sport "${redir_port}" -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null || true
    fi
    "${IPT}" -I OUTPUT 1 -p tcp -j "${OUT_CHAIN}"

    # 二层 nat PREROUTING 统一追加助手（让宿主机 DOCKER / KUBE-SERVICES / 自定义 DNAT 永远优先执行）
    attach_l2() {
      [ "${nat_ok}" = "1" ] || return 0
      mode="$1"; val="$2"
      if [ "${nat_physdev}" = "1" ]; then
        case "${mode}" in
          not_wan) "${IPT}" -t nat -A PREROUTING ! -i "${val}" -p tcp -j "${NAT_CHAIN}"
                   echo "Attached L2  : nat PREROUTING ! -i ${val} -p tcp -> ${NAT_CHAIN} (${IPT})" ;;
          all)     "${IPT}" -t nat -A PREROUTING -p tcp -j "${NAT_CHAIN}"
                   echo "Attached L2  : nat PREROUTING (all bridges) -p tcp -> ${NAT_CHAIN} (${IPT})" ;;
          cidr)    "${IPT}" -t nat -A PREROUTING -s "${val}" -p tcp -j "${NAT_CHAIN}"
                   echo "Attached L2  : nat PREROUTING -s ${val} -p tcp -> ${NAT_CHAIN} (${IPT})" ;;
          iface)   "${IPT}" -t nat -A PREROUTING -i "${val}" -p tcp -j "${NAT_CHAIN}"
                   echo "Attached L2  : nat PREROUTING -i ${val} -p tcp -> ${NAT_CHAIN} (${IPT})" ;;
        esac
      else
        for br_if in ${v4_bridges}; do
          [ "${mode}" = "not_wan" ] && [ "${br_if}" = "${val}" ] && continue
          case "${mode}" in
            not_wan|all)
              "${IPT}" -t nat -A PREROUTING -i "${br_if}" -p tcp -j "${NAT_CHAIN}"
              echo "Attached L2  : nat PREROUTING -i ${br_if} -p tcp -> ${NAT_CHAIN} (${IPT})" ;;
            cidr)
              [ "${br_if}" = "${WAN_DEV}" ] && continue
              "${IPT}" -t nat -A PREROUTING -i "${br_if}" -s "${val}" -p tcp -j "${NAT_CHAIN}"
              echo "Attached L2  : nat PREROUTING -i ${br_if} -s ${val} -p tcp -> ${NAT_CHAIN} (${IPT})" ;;
            iface)
              case "${val}" in
                *+) case "${br_if}" in "${val%+}"*) ;; *) continue ;; esac ;;
                *)  [ "${br_if}" = "${val}" ] || continue ;;
              esac
              "${IPT}" -t nat -A PREROUTING -i "${br_if}" -p tcp -j "${NAT_CHAIN}"
              echo "Attached L2  : nat PREROUTING -i ${br_if} -p tcp -> ${NAT_CHAIN} (${IPT})" ;;
          esac
        done
      fi
    }

    # 1) 挂载新连接入口规则
    if [ "${auto_input}" = "auto" ]; then
      if [ -n "${WAN_DEV}" ]; then
        "${IPT}" -t mangle -I PREROUTING 1 ! -i "${WAN_DEV}" -p tcp -j "${TP_CHAIN}"
        echo "Attached L3  : mangle PREROUTING ! -i ${WAN_DEV} -p tcp -> ${TP_CHAIN} (${IPT})"
        attach_l2 not_wan "${WAN_DEV}"
      else
        "${IPT}" -t mangle -I PREROUTING 1 -p tcp -j "${TP_CHAIN}"
        echo "Attached L3  : mangle PREROUTING (all transit interfaces) -p tcp -> ${TP_CHAIN} (${IPT})"
        attach_l2 all ""
      fi
    else
      # 使用 ; 分隔多路输入（保留网卡末尾通配符 + 如 vpns+）
      printf '%s\n' "${auto_input}" | tr ';' '\n' | awk '
        { gsub(/[[:space:]]/, ""); if ($0 != "" && !seen[$0]++) print $0 }
      ' | while IFS= read -r clean_in; do
        if printf '%s\n' "${clean_in}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'; then
          "${IPT}" -t mangle -I PREROUTING 1 -s "${clean_in}" -p tcp -j "${TP_CHAIN}"
          echo "Attached L3  : mangle PREROUTING -s ${clean_in} -p tcp -> ${TP_CHAIN} (${IPT})"
          attach_l2 cidr "${clean_in}"
        else
          "${IPT}" -t mangle -I PREROUTING 1 -i "${clean_in}" -p tcp -j "${TP_CHAIN}"
          echo "Attached L3  : mangle PREROUTING -i ${clean_in} -p tcp -> ${TP_CHAIN} (${IPT})"
          attach_l2 iface "${clean_in}"
        fi
      done
    fi

    # 2) 将已建连透明 Socket 与回包追踪规则插入 mangle PREROUTING 最顶端（优先级高于 TP_CHAIN）
    if [ -n "${out_src}" ] && [ -n "${sock_mark}" ]; then
      "${IPT}" -t mangle -I OUTPUT 1 -p tcp -m mark --mark "${sock_mark}" -j CONNMARK --set-mark "${TP_MARK}"
      "${IPT}" -t mangle -I PREROUTING 1 -p tcp -m conntrack --ctdir REPLY -m connmark --mark "${TP_MARK}" -j "${DIV_CHAIN}"
    fi
    "${IPT}" -t mangle -I PREROUTING 1 -p tcp -m socket --transparent -j "${DIV_CHAIN}" 2>/dev/null || true
  }

  # 先拉起 HAProxy 监听端口并立即注册退出清理钩子，确认监听端口均进入 LISTEN 后再挂载 PREROUTING 流量
  "${HAPROXY_BIN}" -W -db -f "${TPROXY_CONF}" &
  HP_PID="$!"
  trap 'kill -HUP "${HP_PID}" 2>/dev/null || true' HUP
  trap 'echo "[INFO] Cleaning up TPROXY/REDIRECT rules..."; cleanup_tproxy; kill -TERM "${HP_PID}" 2>/dev/null || true; wait "${HP_PID}" 2>/dev/null || true; exit 0' TERM INT QUIT USR1

  if [ -r /proc/net/tcp ]; then
    tp_hex=$(printf '%04X' "${tproxy_port}")
    rd_hex=""
    [ -n "${redir_port}" ] && rd_hex=$(printf '%04X' "${redir_port}")
    i=0
    while [ "${i}" -lt 50 ]; do
      kill -0 "${HP_PID}" 2>/dev/null || break
      if awk -v p1=":${tp_hex}$" -v p2="${rd_hex:+:${rd_hex}$}" '
        $4 == "0A" {
          if ($2 ~ p1) ok1 = 1
          if (p2 != "" && $2 ~ p2) ok2 = 1
        }
        END { exit !(ok1 && (p2 == "" || ok2)) }
      ' /proc/net/tcp 2>/dev/null; then
        break
      fi
      sleep 0.1 2>/dev/null || sleep 1
      i=$((i + 1))
    done
  else
    sleep 1
  fi
  if ! kill -0 "${HP_PID}" 2>/dev/null; then
    echo "[ERROR] HAProxy failed to start." >&2
    exit 1
  fi

  setup_tproxy

  while kill -0 "${HP_PID}" 2>/dev/null; do
    wait "${HP_PID}" || true
  done
  cleanup_tproxy
  exit 1
fi

# =====================================================================
# 模式 A（默认 TPROXY=0）：SNI / Host 动态分流 + Dnsmasq 解锁模式（纯 IPv4）
# =====================================================================
device="${DEVICE}"
[ -n "${device}" ] || device=$(default_route_dev)
if [ -z "${device}" ]; then
  device=$(ls -1 /sys/class/net | grep -v '^lo$' | head -n 1)
fi
[ -n "${device}" ] || { echo "[ERROR] No network device found." >&2; exit 1; }

# 探测本机公网 IPv4 (ADDR)
addr=$(printf '%s' "${ADDR}" | tr -d '[:space:]')
if [ -n "${addr}" ] && ! is_ipv4 "${addr}"; then
  echo "[WARN] Invalid IPv4 ADDR \"${ADDR}\", falling back to auto-detection." >&2
  addr=""
fi

fetch_ip_api() {
  if command -v wget >/dev/null 2>&1; then
    wget -qO- -T 3 "$1" 2>/dev/null | tr -d '[:space:]' || true
  elif command -v curl >/dev/null 2>&1; then
    curl -4 -fsSL -m 3 "$1" 2>/dev/null | tr -d '[:space:]' || true
  fi
}

if [ -z "${addr}" ]; then
  for api in "https://checkip.amazonaws.com/" "https://ipv4.icanhazip.com/" "https://api.ipify.org"; do
    raw_ip=$(fetch_ip_api "${api}")
    if is_ipv4 "${raw_ip}"; then
      addr="${raw_ip}"
      break
    fi
  done
  if [ -z "${addr}" ]; then
    addr=$(ip -4 addr show "${device}" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1)
    [ -n "${addr}" ] && echo "[WARN] Public IPv4 auto-detect timed out, falling back to NIC IPv4: ${addr}" >&2
  fi
fi

if [ -z "${addr}" ]; then
  echo "[ERROR] Cannot determine IPv4 address." >&2
  exit 1
fi

uport=$(printf '%s' "${UPORT:-53}" | tr -d '[:space:]')
if ! is_port "${uport}"; then
  echo "[WARN] Invalid UPORT \"${UPORT}\", falling back to 53." >&2
  uport="53"
fi

port_lc=$(printf '%s' "${PORT:-3535}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
case "${port_lc}" in
  0|off|false|no|none) port="0" ;;
  *)
    if is_port "${port_lc}"; then
      port="${port_lc}"
    else
      echo "[ERROR] Invalid DNS listen PORT: \"${PORT}\"" >&2
      exit 1
    fi
    ;;
esac

udns_list="${UDNS:-8.8.4.4;1.1.1.1}"
primary_udns=""
primary_uport="${uport}"

echo "Run Mode     : SNI/Host Proxy + DNS Unlock (IPv4)"
echo "Upstream DNS : ${udns_list} (port: ${uport})"
echo "Hijack DNS   : ${addr} (port: ${port}, dev: ${device})"
echo "TCP Lowat    : $([ "${lowat}" = "0" ] && echo "disabled (0)" || echo "${lowat} bytes")"

haproxy_ns_tmp="/tmp/haproxy.ns.$$"
dnsmasq_ns_tmp="/tmp/dnsmasq.ns.$$"
: > "${haproxy_ns_tmp}"
: > "${dnsmasq_ns_tmp}"

idx=1
set -f
for ns in $(printf '%s' "${udns_list}" | tr ';' ' '); do
  clean_ns=$(printf '%s' "${ns}" | tr -d '[:space:]')
  [ -n "${clean_ns}" ] || continue
  case "${clean_ns}" in
    *#* ) ns_ip="${clean_ns%%#*}"; ns_pt="${clean_ns#*#}" ;;
    *:* ) ns_ip="${clean_ns%%:*}"; ns_pt="${clean_ns#*:}" ;;
    *   ) ns_ip="${clean_ns}";     ns_pt="${uport}" ;;
  esac
  if ! is_ipv4 "${ns_ip}" || ! is_port "${ns_pt}"; then
    echo "[WARN] Skipping invalid IPv4 upstream DNS entry: ${clean_ns}" >&2
    continue
  fi
  if [ "${idx}" -eq 1 ]; then
    primary_udns="${ns_ip}"
    primary_uport="${ns_pt}"
  fi
  echo "    nameserver up${idx} ${ns_ip}:${ns_pt}" >> "${haproxy_ns_tmp}"
  echo "server=${ns_ip}#${ns_pt}" >> "${dnsmasq_ns_tmp}"
  idx=$((idx + 1))
done
set +f
[ -n "${primary_udns}" ] || primary_udns="8.8.4.4"

if [ -f "${HAPROXY_CONF}" ]; then
  awk -v ns_file="${haproxy_ns_tmp}" -v map_file="${MAP_FILE}" -v lowat="${lowat}" '
    (lowat + 0) > 0 && /^[[:space:]]*#[[:space:]]*tune\.notsent-lowat\.(client|server)[[:space:]]/ {
      sub(/#[[:space:]]*/, ""); sub(/[0-9]+/, lowat); print; next
    }
    /# BEGIN_UPSTREAM_DNS/ {
      print
      if ((getline line < ns_file) > 0) {
        print line
        while ((getline line < ns_file) > 0) print line
        skip = 1
      }
      close(ns_file)
      next
    }
    /# END_UPSTREAM_DNS/ { skip = 0; print; next }
    !skip {
      if (map_file != "/etc/haproxy/haproxy.map") {
        while ((p = index($0, "/etc/haproxy/haproxy.map")) > 0) {
          $0 = substr($0, 1, p - 1) map_file substr($0, p + 24)
        }
      }
      print
    }
  ' "${HAPROXY_CONF}" > "${HAPROXY_CONF}.new" && mv -f "${HAPROXY_CONF}.new" "${HAPROXY_CONF}"
fi

if [ -f "${DNS_CONF}" ]; then
  awk -v dev="${device}" -v pt="${port}" -v ip4="${addr}" -v ns_file="${dnsmasq_ns_tmp}" '
    /^interface=/    { print "interface=" dev; next }
    /^port=/         { print "port=" pt; next }
    /^address=\/#\// { print "address=/#/" ip4; next }
    /# BEGIN_UPSTREAM_DNS/ {
      print
      if ((getline line < ns_file) > 0) {
        print line
        while ((getline line < ns_file) > 0) print line
        skip = 1
      }
      close(ns_file)
      next
    }
    /# END_UPSTREAM_DNS/ { skip = 0; print; next }
    !skip { print }
  ' "${DNS_CONF}" > "${DNS_CONF}.new" && mv -f "${DNS_CONF}.new" "${DNS_CONF}"
fi
rm -f "${haproxy_ns_tmp}" "${dnsmasq_ns_tmp}"

# 解析环境变量 TABLE 与 DNS，生成 haproxy.map 并统一去重写入 dnsmasq 例外直通解析项
tmp_dns="/tmp/dns.lo.$$"
: > "${tmp_dns}"

if [ -n "${TABLE}" ]; then
  tmp_raw="/tmp/routes.raw.$$"
  : > "${tmp_raw}"

  printf '%s\n' "${TABLE}" | tr ';' '\n' | awk -v dns_out="${tmp_dns}" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      line = trim($0)
      if (line == "" || substr(line, 1, 1) == "#") next

      n = split(line, parts, ",")
      raw_src = trim(parts[1])
      dst     = (n >= 2) ? trim(parts[2]) : ""
      mode    = (n >= 3) ? tolower(trim(parts[3])) : ""

      if (index(raw_src, ":") > 0) {
        printf "[WARN] Skipping invalid TABLE entry (\":\" is only for port, use \",\" to separate fields): %s\n", line > "/dev/stderr"
        next
      }

      src_low = tolower(raw_src)
      if (substr(src_low, 1, 1) == "^" || substr(src_low, 1, 1) == "@") {
        granularity = "exact"
        src = substr(src_low, 2)
      } else if (substr(src_low, 1, 2) == "*.") {
        granularity = "wild"
        src = substr(src_low, 3)
      } else {
        granularity = "both"
        src = src_low
      }
      sub(/^\*+/, "", src)
      sub(/^\.+/, "", src)
      sub(/\.+$/, "", src)
      if (src == "" || length(src) > 253 || src ~ /[^0-9a-z._-]/) {
        printf "[WARN] Skipping invalid domain in TABLE: %s\n", line > "/dev/stderr"
        next
      }

      if (mode == "" && tolower(dst) ~ /[[:space:]]+proxy(_protocol)?$/) {
        mode = "proxy"
        sub(/[[:space:]]+[pP][rR][oO][xX][yY](_[pP][rR][oO][tT][oO][cC][oO][lL])?$/, "", dst)
        dst = trim(dst)
      }

      if (substr(dst, 1, 1) == "[" || split(dst, hp_chk, ":") > 2) {
        printf "[WARN] Skipping invalid IPv4 TABLE target (\":\" is only for host:port, use \",\" before flag): %s\n", line > "/dev/stderr"
        next
      }

      if (mode == "proxy_protocol" || mode == "proxy-v2" || mode == "proxy_v2") mode = "proxy"
      if (mode == "proxy_v1") mode = "proxy-v1"
      if (mode != "" && mode != "proxy" && mode != "proxy-v1" && mode != "http") {
        printf "[WARN] Skipping TABLE entry with unknown flag \"%s\" (allowed: proxy, proxy-v1, http): %s\n", mode, line > "/dev/stderr"
        next
      }

      has_custom_dst = (dst != "" && dst != "*") ? 1 : 0
      if (!has_custom_dst && mode == "") {
        map_val = "*"
      } else {
        if (!has_custom_dst) {
          host_port = (mode == "http") ? "*:80" : "*:443"
        } else if (dst ~ /^[0-9]+$/) {
          if ((dst + 0) < 1 || (dst + 0) > 65535 || substr(dst, 1, 1) == "0") {
            printf "[WARN] Skipping TABLE entry with invalid port \"%s\": %s\n", dst, line > "/dev/stderr"
            next
          }
          host_port = "*:" dst
        } else if (index(dst, ":") > 0) {
          split(dst, hp_chk, ":")
          d_host = trim(hp_chk[1])
          d_port = trim(hp_chk[2])
          if (d_host == "") d_host = "*"
          if (d_port !~ /^[1-9][0-9]*$/ || (d_port + 0) > 65535 || (d_host != "*" && (length(d_host) > 253 || d_host ~ /[^0-9a-zA-Z._-]/))) {
            printf "[WARN] Skipping TABLE entry with invalid target \"%s\": %s\n", dst, line > "/dev/stderr"
            next
          }
          host_port = d_host ":" d_port
        } else {
          if (length(dst) > 253 || dst ~ /[^0-9a-zA-Z._-]/) {
            printf "[WARN] Skipping TABLE entry with invalid target \"%s\": %s\n", dst, line > "/dev/stderr"
            next
          }
          host_port = dst ":" ((mode == "http") ? "80" : "443")
        }

        map_val = (mode != "") ? (host_port "/" mode) : host_port
      }

      domains[src] = 1
      if (granularity == "exact") {
        if (!exp_exact[src]) { exact_map[src] = map_val; exp_exact[src] = 1 }
      } else if (granularity == "wild") {
        if (!exp_wild[src])  { wild_map[src]  = map_val; exp_wild[src]  = 1 }
      } else {
        if (!exp_exact[src] && !(src in exact_map)) exact_map[src] = map_val
        if (!exp_wild[src]  && !(src in wild_map))  wild_map[src]  = map_val
      }

      if (has_custom_dst && index(src, ".") > 0) {
        printf "%s\n", src >> dns_out
      }
    }
    END {
      for (d in domains) {
        len = length(d)
        if (d in exact_map) {
          printf "%d\t2\t%-38s %s\n", len, "^" d, exact_map[d]
        }
        if (d in wild_map) {
          printf "%d\t1\t%-38s %s\n", len, "." d, wild_map[d]
        }
      }
    }
  ' | sort -k1,1rn -k2,2rn | cut -f3- > "${tmp_raw}"

  {
    echo "# Auto-generated from TABLE environment variable"
    cat "${tmp_raw}"
  } > "${MAP_FILE}"
  rm -f "${tmp_raw}"
fi

if [ -f "${DNS_CONF}" ] && { [ -s "${tmp_dns}" ] || [ -n "${DNS}" ]; }; then
  {
    [ -s "${tmp_dns}" ] && cat "${tmp_dns}"
    [ -n "${DNS}" ] && printf '%s\n' "${DNS}" | tr ';' '\n'
  } | awk -v udns="${primary_udns}" -v uport="${primary_uport}" '
    {
      d = tolower($0)
      gsub(/[[:space:]]/, "", d)
      sub(/^(\^|@|\*\.|\*+|\.+)/, "", d)
      sub(/\.+$/, "", d)
      if (index(d, ".") > 0 && d !~ /[^0-9a-z._-]/ && !seen[d]++) {
        printf "server=/%s/%s#%s\n", d, udns, uport
      }
    }
  ' >> "${DNS_CONF}"
fi
rm -f "${tmp_dns}"

export PUBLIC_ADDR="${addr}"
export FALLBACK="${FALLBACK:-0}"
[ -f "${MAP_FILE}" ] || : > "${MAP_FILE}"

echo "Fallback Mode: ${FALLBACK} (0=strict whitelist, 1=wildcard unlock)"
echo "--- Active Routes (${MAP_FILE}) ---"
grep -vE '^[[:space:]]*(#|$)' "${MAP_FILE}" || echo "(empty)"
echo "------------------------------------------"

"${HAPROXY_BIN}" -v | head -n 1
"${HAPROXY_BIN}" -c -f "${HAPROXY_CONF}"

if [ "${port}" != "0" ] && [ -f "${DNS_CONF}" ]; then
  "${DNSMASQ_BIN}" -v | head -n 1
  "${DNSMASQ_BIN}" --test -C "${DNS_CONF}"
  "${DNSMASQ_BIN}" -C "${DNS_CONF}"
fi

exec "${HAPROXY_BIN}" -W -db -f "${HAPROXY_CONF}"
