#!/bin/bash
#
# Copyright (C) 2019-2022 ArianK16a
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH="$(pwd)"

telegram () {
  /home/arian/telegram.sh/telegram "$@"
}

# build device gms
build () {
  device=${1}
  project="$(basename ${LOCAL_PATH})"

  cd ${LOCAL_PATH}
  source build/envsetup.sh

  #export CCACHE_EXEC=$(command -v ccache)
  #export CCACHE_DIR=$(pwd)/.ccache
  #export USE_CCACHE=1
  #ccache -M 20G

  if [[ -f ${LOCAL_PATH}/.last_build_time ]]; then
    rm ${LOCAL_PATH}/.last_build_time
  fi

  if [[ ${2} == "gms" ]]; then
    export TARGET_UNOFFICIAL_BUILD_ID=GMS
    # Export variables for GMS inclusion
    # Explicity define gms makefile to throw an error if it does not exist
    export WITH_GMS=true
    export GMS_MAKEFILE=gms.mk
  else
    export TARGET_UNOFFICIAL_BUILD_ID=
    export WITH_GMS=
  fi

  breakfast ${device}
  make installclean

  telegram -N -M "*(i)* \`"${project}"\` compilation for \`${device}\` *started* on ${HOSTNAME}."
  build_start=$(date +"%s")
  brunch ${device}
  build_result ${device} ${2}

  # post-build
  if [[ ! -f ${LOCAL_PATH}/.last_build_time ]] || [[ ! $(ls "${OUT}"/lineage-*-"${device}".zip) ]]; then
    return -1
  fi
}

convertsecs() {
  h=$(bc <<< "${1}/3600")
  m=$(bc <<< "(${1}%3600)/60")
  s=$(bc <<< "${1}%60")
  printf "%02d:%02d:%02d\n" $h $m $s
}

# build_result device gms
build_result () {
  result=$(echo $?)
  build_end=$(date +"%s")
  diff=$((${build_end} - ${build_start}))
  time=$(convertsecs "${diff}")
  if [[ ${2} == "gms" ]]; then
    type="GMS"
  else
    type="VANILLA"
  fi
  if [[ ${result} == "0" ]]; then
    echo ${time} > ${LOCAL_PATH}/.last_build_time
    message="completed successfully"
  else
    message="failed"
  fi
  telegram -M "*(i)* \`$(basename ${LOCAL_PATH})\` compilation for \`${1}\` *${message}* on ${HOSTNAME}. Build variant: \`${type}\`. Build time: \`${time}\`."
}

# release device gms
# release flow:
#   1. Clone OTA repository
#   2. Update OTA json
#   3. Commit, tag and push OTA repo
#   4. Update changelos
#   5. Create github release
#   6. Post telegram release post
release () {
  device=${1}
  project="$(basename ${LOCAL_PATH})"

  if [[ ${2} == "gms" ]]; then
    type="GMS"
    device_variant="${device}_gms"
  else
    type="VANILLA"
    device_variant="${device}"
  fi

  breakfast ${device}

  if [[ -d "${LOCAL_PATH}"/ota ]];
  then
    rm -rf "${LOCAL_PATH}"/ota
  fi
  git clone git@github.com:arian-ota/ota.git -b main
  cd "${LOCAL_PATH}"/ota

  datetime=$(cat "${OUT}"/system/build.prop | grep ro.build.date.utc=)
  datetime="${datetime#*=}"
  filename=$(cat "${OUT}"/system/build.prop "${OUT}"/product/etc/build.prop | grep ro.lineage.version=)
  filename_without_extension=lineage-"${filename#*=}"
  filename="${filename_without_extension#*=}".zip
  id=$(cat "${OUT}"/"${filename}".sha256sum | awk '{print $1}')
  romtype=$(cat "${OUT}"/system/build.prop "${OUT}"/product/etc/build.prop | grep ro.lineage.releasetype=)
  romtype="${romtype#*=}"
  size=$(ls -l "${OUT}"/"${filename}" | awk '{print $5}')
  version=$(cat "${OUT}"/system/build.prop "${OUT}"/product/etc/build.prop | grep ro.lineage.build.version=)
  version="${version#*=}"

  # Add other images which are helpful during installation
  has_ab_partitions=$(cat "${OUT}"/vendor/build.prop | grep ro.build.ab_update=)
  has_ab_partitions="${has_ab_partitions#*=}"
  if [[ ${has_ab_partitions} == "true" ]]; then
    partitions="boot init_boot vendor_boot vbmeta dtbo recovery"
  else
    partitions="recovery"
  fi
  for partition in ${partitions}; do
    if [[ -f ${OUT}/${partition}.img ]]; then
      cp ${OUT}/${partition}.img ${OUT}/${filename_without_extension}-${partition}.img
    fi
  done

  tag="${version}"-"${device_variant}"-"${id:0:8}"
  url="https://github.com/arian-ota/ota/releases/download/"${tag}"/"${filename}
  release_url="https://github.com/arian-ota/ota/releases/tag/"${tag}

  ota_entry='{
        datetime: '${datetime}',
        filename: "'${filename}'",
        id: "'${id}'",
        romtype: "'${romtype}'",
        size: '${size}',
        url: "'${url}'",
        version: "'${version}'"
      }'
  if [[ $(jq 'has("response")' "${device_variant}".json 2> /dev/null) ]]; then
    append_ota=1
    for (( i = 0; i < 3; i++ )); do
      if [[ $(jq -r .response[${i}].id "${device_variant}".json) == ${id} ]]; then
        echo "OTA json already contains update with id ${id}"
        append_ota=0
        break
      fi
    done
    if [[ ${append_ota} == 1 ]]; then
      echo "Appending OTA to existing json"
      jq '.response += ['"${ota_entry}"']' "${device_variant}".json | sponge "${device_variant}".json

      # Trim the list of builds in Updater
      while [[ $(jq '.response | length' "${device_variant}".json) > 3 ]]; do
        jq 'del(.response[0])' "${device_variant}".json | sponge "${device_variant}".json
      done
    fi
  else
    echo "Creating new OTA json"
    jq -n '{"response": ['"${ota_entry}"']}' > "${device_variant}".json
  fi

  git add "${device_variant}".json
  git commit -m "${device_variant}: OTA update $(date +%F)"
  git push

  git tag "${tag}" HEAD
  git push git@github.com:arian-ota/ota.git "${tag}"

  cd ${LOCAL_PATH}

  update_changelog "${device}" "${2}"
  changelog_link=https://raw.githubusercontent.com/arian-ota/changelog/main/"$device_variant".txt

  if [[ ${device} == "davinci" ]]; then
    group="@lineage\_davinci"
    extra_arguments="-c -1001426238293"
  elif [[ ${device} == "toco" ]]; then
    group="@lineage\_toco"
    extra_arguments="-c -1001443889354"
  elif [[ ${device} == "violet" ]]; then
    group="@LineageViolet"
    extra_arguments="-c -1001656828188"
  else
    extra_arguments="-c -1001159030901"
    group="#${device}"
  fi

  brand=$(cat "${OUT}"/system/build.prop | grep ro.product.system.brand=)
  brand="${brand#*=}"
  model=$(cat "${OUT}"/system/build.prop | grep ro.product.system.model=)
  model="${model#*=}"
  device=$(cat "${OUT}"/system/build.prop | grep ro.product.system.device=)
  device="${device#*=}"

  date=$(date -d @${datetime} +%F)
  security_patch=$(cat "${OUT}"/system/build.prop | grep ro.build.version.security_patch=)
  security_patch="${security_patch#*=}"

  title="LineageOS ${version} for ${brand} ${model} (${device})"
  build_info="
📅 Build date: \`${date}\`
🛡️ Security patch: \`${security_patch}\`
💬 Variant: \`${type}\`

🗒️ [Changelog](${changelog_link})"

  cd ota/
  gh repo set-default
  gh release create "${tag}" \
      --title "${title}" \
      --notes "${build_info}

**SHA-256 checksum**
\`${id}\`
" \
      "${OUT}"/"${filename_without_extension}"*

  cd "${LOCAL_PATH}"

  telegram ${extra_arguments} -M " \
*${title}*

${build_info}

*Download*
⬇️ [${project}](${url})
⛭ [GitHub release / additional files](${release_url})

*SHA-256 checksum*
\`${id}\`

${group}
"
}

# update_changelog device gms
update_changelog () {
  if [[ ${1} == "" ]]; then
    echo "specify a device"
    return -1
  fi

  if [[ ${2} == "gms" ]]; then
    changelog_device="${1}_gms"
  else
    changelog_device="${1}"
  fi

  project="$(basename ${LOCAL_PATH})"

  if [[ -d "${LOCAL_PATH}"/changelog ]];
  then
    rm -rf "${LOCAL_PATH}"/changelog
  fi
  git clone git@github.com:arian-ota/changelog.git -b main

  changelog="${LOCAL_PATH}"/changelog/"${changelog_device}".txt
  rm -f ${changelog}
  touch ${changelog}

  # Generate changelog for 7 days
  for i in $(seq 7);
  do
      after_date=`date --date="$i days ago" +%F`
      until_date=`date --date="$(expr ${i} - 1) days ago" +%F`
      echo "====================" >> ${changelog}
      echo "     $until_date    " >> ${changelog}
      echo "====================" >> ${changelog}
      while read path; do
          git_log=`git --git-dir ./${path}/.git log --after=$after_date --until=$until_date --format=tformat:"%h %s [%an]"`
          if [[ ! -z "${git_log}" ]]; then
              echo "* ${path}" >> ${changelog}
              echo "${git_log}" >> ${changelog}
              echo "" >> ${changelog}
          fi
      done < ./.repo/project.list
  done

  cd changelog
  git add "${changelog_device}".txt
  git commit -m "${changelog_device}: Changelog update $(date +%F)"
  git push
  cd ${LOCAL_PATH}
}

if [ -f env_overwrite.sh ]; then
  source env_overwrite.sh
fi
