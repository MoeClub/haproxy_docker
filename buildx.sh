#!/bin/sh
set -e

oneVer="${1:-3.4.8}"
twoVer="${2:-2.93}"
withLatest="${3:-0}"
dockerProject="haproxy"
dockerBase="alpine:3.20"
dockerName="${dockerProject}_buildx"
mntPath=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
userName="$(docker info 2>/dev/null | grep 'Username:' | cut -d':' -f2 | sed 's/[[:space:]]//g')"

manifest=""
for arch in "amd64" "arm64"; do
  docker run --rm --platform "linux/${arch}" "${dockerBase}" apk --print-arch >/dev/null 2>&1 || docker run --privileged --rm tonistiigi/binfmt --install "${arch}"
  docker rm -f "${dockerName}" >/dev/null 2>&1 || true
  docker run --platform "linux/${arch}" --name "${dockerName}" -id -v "${mntPath}:/mnt" "${dockerBase}"
  docker exec "${dockerName}" /bin/sh /mnt/commit.sh "${oneVer}" "${twoVer}"
  docker commit --change 'CMD ["/bin/sh", "/run.sh"]' "${dockerName}" "${dockerProject}_${arch}:${oneVer}"
  docker rm -f "${dockerName}" >/dev/null 2>&1 || true
  [ -n "${userName}" ] || continue
  [ "${withLatest}" = "1" ] && {
    docker tag "${dockerProject}_${arch}:${oneVer}" "${userName}/${dockerProject}_${arch}:latest"
    docker push "${userName}/${dockerProject}_${arch}:latest"
  }
  docker tag "${dockerProject}_${arch}:${oneVer}" "${userName}/${dockerProject}_${arch}:${oneVer}"
  docker push "${userName}/${dockerProject}_${arch}:${oneVer}"
  manifest=$(printf '%s --amend "%s/%s_%s:%s"' "${manifest}" "${userName}" "${dockerProject}" "${arch}" "${oneVer}")
done

if [ -n "${userName}" ] && [ -n "${manifest}" ]; then
  docker manifest rm "${userName}/${dockerProject}:${oneVer}" >/dev/null 2>&1 || true
  eval "docker manifest create \"${userName}/${dockerProject}:${oneVer}\" ${manifest}"
  docker manifest push -p "${userName}/${dockerProject}:${oneVer}"

  if [ "${withLatest}" = "1" ]; then
    docker manifest rm "${userName}/${dockerProject}:latest" >/dev/null 2>&1 || true
    eval "docker manifest create \"${userName}/${dockerProject}:latest\" ${manifest}"
    docker manifest push -p "${userName}/${dockerProject}:latest"
  fi
fi
