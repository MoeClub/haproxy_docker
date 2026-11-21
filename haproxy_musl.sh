#!/bin/sh

# docker pull alpine:latest
# docker rm -f alpine >/dev/null 2>&1; docker run --name alpine -it -v /mnt:/mnt alpine:latest
# docker exec -it alpine /bin/sh

apk add --no-cache wget xz sed perl openssl gcc coreutils patch file autoconf automake pkgconfig make build-base linux-headers musl-dev libtool


VERSION_HAPROXY="3.4.8"
VERSION_PCRE2="10.49"
VERSION_OPENSSL="3.5.9"


TRAPRM=""
TARPKG=""

function musl_cross(){
  muslHome="/usr/local/musl"
  mkdir -p "${muslHome}"
  for arch in "$@" ; do
    PATH="$PATH" which "${arch}-linux-musl-gcc" >/dev/null 2>&1 || wget --no-check-certificate -qO- "http://musl.cc/${arch}-linux-musl-cross.tgz" |tar -zx --overwrite -C "${muslHome}";
  done

  newPATH=""
  for path in `echo "$PATH" |sed 's/:/\n/g'`; do echo "$path" |grep -q "musl" || newPATH="${newPATH}:${path}"; done
  for path in `find "${muslHome}" -name "*-cc" 2>/dev/null`; do newPATH="${newPATH}:$(dirname ${path})"; done
  newPATH="${newPATH#:}"

  [ -f "$HOME/.bashrc" ] && sed -i "s/^PATH=.*/PATH=${newPATH////\\/}/" "$HOME/.bashrc"
  [ -f "/etc/profile" ] && sed -i "s/^export PATH=.*/export PATH=${newPATH////\\/}/" "/etc/profile"
  echo "export PATH=${newPATH}"
}

# pcre2
function build_pcre2(){
  ARCH="${1:-x86_64}"
  [ -n "$VERSION_PCRE2" ] || return 0
  TMP=`mktemp -d`; TRAPRM="${TRAPRM} ${TMP}"; trap "rm -rf ${TRAPRM# }" EXIT
  wget --no-check-certificate -qO- "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${VERSION_PCRE2}/pcre2-${VERSION_PCRE2}.tar.gz" |tar -xz -C "$TMP" --strip-components=1
  cd "$TMP"
  CC_FOR_BUILD=cc \
  CC="${ARCH}-linux-musl-gcc" \
  CXX="${ARCH}-linux-musl-g++" \
  CFLAGS="-I/usr/local/cross/${ARCH}/include -O2" \
  LDFLAGS="-L/usr/local/cross/${ARCH}/lib -s -w -static -no-pie" \
  ./configure \
    --host="${ARCH}-linux-musl" \
    --prefix="/usr/local/cross/${ARCH}" \
    --disable-shared --enable-static \
    --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 \
    --enable-jit --enable-unicode \
    --disable-pcre2grep-libz --disable-pcre2grep-libbz2 --disable-pcre2test-libreadline
  [ $? -eq 0 ] || return 1
  make -j`nproc`
  [ $? -eq 0 ] || return 1
  make install
  return $?
}

# openssl (with kTLS)
function build_openssl(){
  ARCH="${1:-x86_64}"
  [ -n "$VERSION_OPENSSL" ] || return 0
  TMP=`mktemp -d`; TRAPRM="${TRAPRM} ${TMP}"; trap "rm -rf ${TRAPRM# }" EXIT
  wget --no-check-certificate -qO- "https://github.com/openssl/openssl/releases/download/openssl-${VERSION_OPENSSL}/openssl-${VERSION_OPENSSL}.tar.gz" |tar -xz -C "$TMP" --strip-components=1
  cd "$TMP"
  case "${ARCH}" in
    x86_64)  SSL_TARGET="linux-x86_64" ;;
    aarch64) SSL_TARGET="linux-aarch64" ;;
    arm*)    SSL_TARGET="linux-armv4" ;;
    i?86)    SSL_TARGET="linux-x86" ;;
    *)       SSL_TARGET="linux-generic64" ;;
  esac
  CC="${ARCH}-linux-musl-gcc" \
  CXX="${ARCH}-linux-musl-g++" \
  AR="${ARCH}-linux-musl-ar" \
  RANLIB="${ARCH}-linux-musl-ranlib" \
  NM="${ARCH}-linux-musl-nm" \
  ./Configure "${SSL_TARGET}" \
    --prefix="/usr/local/cross/${ARCH}" \
    --libdir=lib \
    --openssldir="/etc/ssl" \
    enable-ktls \
    no-shared no-async no-dso no-module no-tests no-docs no-comp \
    -O2
  [ $? -eq 0 ] || return 1
  make -j`nproc` build_libs
  [ $? -eq 0 ] || return 1
  make install_dev
  return $?
}

# haproxy
function build_haproxy(){
  ARCH="${1:-x86_64}"
  [ -n "$VERSION_HAPROXY" ] || return 0
  TMP=`mktemp -d`; TRAPRM="${TRAPRM} ${TMP}"; TARGET=`mktemp -d`; TRAPRM="${TRAPRM} ${TARGET}"; trap "rm -rf ${TRAPRM# }" EXIT
  wget --no-check-certificate -qO- "https://www.haproxy.org/download/${VERSION_HAPROXY%.*}/src/haproxy-${VERSION_HAPROXY}.tar.gz" |tar -xz -C "$TMP" --strip-components=1
  cd "$TMP"

  make -j`nproc` \
    CC="${ARCH}-linux-musl-gcc" \
    LD="${ARCH}-linux-musl-gcc" \
    TARGET=linux-musl \
    ARCH_FLAGS="-flto=auto" \
    OPT_CFLAGS="-O3" \
    USE_BACKTRACE=0 \
    USE_PROMEX=1 \
    USE_PCRE2=1 \
    USE_PCRE2_JIT=1 \
    PCRE2_CONFIG="/usr/local/cross/${ARCH}/bin/pcre2-config" \
    PCRE2_INC="/usr/local/cross/${ARCH}/include" \
    PCRE2_LIB="/usr/local/cross/${ARCH}/lib" \
    PCRE2_LDFLAGS="-L/usr/local/cross/${ARCH}/lib -lpcre2-posix -lpcre2-8" \
    USE_OPENSSL=1 \
    USE_KTLS=1 \
    USE_QUIC=1 \
    SSL_INC="/usr/local/cross/${ARCH}/include" \
    SSL_LIB="/usr/local/cross/${ARCH}/lib" \
    LDFLAGS="-L/usr/local/cross/${ARCH}/lib -static -no-pie -s" \
    ADDLIB="-lpthread -ldl -lm" \
    haproxy
  [ $? -eq 0 ] || return 1
  make PREFIX="/usr" SBINDIR="/usr/sbin" DESTDIR="${TARGET}" install-bin
  [ $? -eq 0 ] || return 1

  cd "${TARGET}"
  FILE="/mnt/haproxy_${ARCH}_v${VERSION_HAPROXY}.tar.gz"
  [ -f "${FILE}" ] && rm -rf "${FILE}"
  file ./usr/sbin/haproxy
  tar -czvf "${FILE}" ./
  [ $? -eq 0 ] || return 1
  TARPKG="${TARPKG} ${FILE}"
  return 0
}


function build() {
  ARCH="${1:-x86_64}"
  build_pcre2 "${ARCH}"
  [ $? -eq 0 ] || return 1
  build_openssl "${ARCH}"
  [ $? -eq 0 ] || return 1
  build_haproxy "${ARCH}"
  [ $? -eq 0 ] || return 1
}


for arch in "x86_64" "aarch64"; do
  eval `musl_cross "${arch}"`
  build "${arch}"
  [ "$?" -ne 0 ] && exit 1
done

for tarpkg in `echo "${TARPKG# }"`; do
  echo "--> ${tarpkg}"
done
