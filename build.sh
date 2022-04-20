#!/bin/bash
#
# Copyright (C) 2019-2022 ArianK16a
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH="$(pwd)"

if [ "${DEBUG_BUILD}" == 1 ]; then
  SIGNED=0
else
  SIGNED=1
  DEBUG_BUILD=0
fi

telegram () {
  /home/arian/telegram.sh/telegram "$@"
}

# build device gms
build () {
  device=${1}
  project="$(basename ${LOCAL_PATH})"

  cd ${LOCAL_PATH}
  source build/envsetup.sh

  export CCACHE_EXEC=$(command -v ccache)
  export CCACHE_DIR=$(pwd)/.ccache
  export USE_CCACHE=1
  ccache -M 20G

  if [[ -f ${LOCAL_PATH}/.last_build_time ]]; then
    rm ${LOCAL_PATH}/.last_build_time
  fi
  if [[ ${DEBUG_BUILD} == 0 ]]; then
    repo sync -j12 --detach --no-clone-bundle --fail-fast --current-branch --force-sync
    bash "${LOCAL_PATH}"/picks.sh
  fi

  rm -rf vendor/extra
  if [[ ${2} == "gms" ]]; then
    git clone https://github.com/ArianK16a/android_vendor_extra.git -b "${project}"_gms vendor/extra
    export TARGET_UNOFFICIAL_BUILD_ID=GMS
  else
    git clone https://github.com/ArianK16a/android_vendor_extra.git -b "${project}"_vanilla vendor/extra
    export TARGET_UNOFFICIAL_BUILD_ID=
  fi

  breakfast ${device}
  if [[ ${DEBUG_BUILD} == 0 ]]; then
    make clean
  else
    make installclean
  fi
  telegram -N -M "*(i)* \`"$(basename ${LOCAL_PATH})"\` compilation for \`${device}\` *started* on ${HOSTNAME}."
  build_start=$(date +"%s")
  if [[ ${SIGNED} == 1 ]]; then
    mka target-files-package otatools
  else
    brunch ${device}
  fi
  build_result ${device} ${2}

  # post-build
  if [[ -f ${LOCAL_PATH}/.last_build_time ]] && ([[ $(ls ${OUT}/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip) ]] || [[ $(ls "${OUT}"/lineage-*-"${device}".zip) ]]); then
    if [[ ${SIGNED} == 1 ]]; then
      sign_target_files
    fi

    img_version=$(cat "${OUT}"/system/build.prop | grep ro.lineage.version=)
    img_version="${img_version#*=}"
    img_version=lineage-"${img_version}"

    has_ab_partitions=$(cat "${OUT}"/vendor/build.prop | grep ro.build.ab_update=)
    has_ab_partitions="${has_ab_partitions#*=}"
    if [[ ${has_ab_partitions} == "true" ]]; then
      partitions="boot dlkm dtbo vendor_boot"
    else
      partitions="recovery"
    fi
    for partition in ${partitions}; do
      if [[ ${SIGNED} == 1 ]]; then
        if [[ $(unzip -l ${OUT}/SIGNED-target_files-"${filename}" | grep -q IMAGES/"${partition}".img && echo $?) == 0 ]]; then
          unzip -p ${OUT}/SIGNED-target_files-"${filename}" IMAGES/"${partition}".img > ${OUT}/${img_version}-${partition}.img
        fi
      else
        if [[ -f ${OUT}/${partition}.img ]]; then
          cp ${OUT}/${partition}.img ${OUT}/${img_version}-${partition}.img
        fi
      fi
    done
    if [[ ${DEBUG_BUILD} == 0 ]]; then
      upload ${device} ${2}
    fi
  else
    if [[ ${DEBUG_BUILD} == 0 ]]; then
      if [[ ${device} == "davinci" ]]; then
        extra_arguments="-c -1001426238293"
      elif [[ ${device} == "toco" ]]; then
        extra_arguments="-c -1001443889354"
      elif [[ ${device} == "violet" ]]; then
        extra_arguments="-c -1001656828188"
      else
        extra_arguments=""
      fi
      telegram $extra_arguments "Compilation for "$1" failed!"
    fi
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

sign_target_files () {
  filename=$(cat "${OUT}"/system/build.prop | grep ro.lineage.version=)
  filename="${filename#*=}"
  filename=lineage-"${filename}".zip

  ./out/soong/host/linux-x86/bin/sign_target_files_apks -o -d ~/.android-certs \
    ${OUT}/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip \
    ${OUT}/SIGNED-target_files-"${filename}"

  ./out/soong/host/linux-x86/bin/ota_from_target_files -k ~/.android-certs/releasekey \
    --block --backup=true \
    ${OUT}/SIGNED-target_files-"${filename}" \
    ${OUT}/"$filename"

  checksum=$(sha256sum "${OUT}"/"${filename}" | awk '{print $1}')
  echo "$checksum  ${filename}" > ${OUT}/"${filename}".sha256sum
}

# upload device gms
upload () {
  device=${1}
  if [[ ${device} == "" ]]; then
    echo "specify a device"
  fi

  project="$(basename ${LOCAL_PATH})"

  # Make sure the directories exist
  {
    echo 'mkdir /home/frs/project/ephedraceae/'${device}'/'
    echo 'mkdir /home/frs/project/ephedraceae/'${device}'/'${project}'/'
    echo 'mkdir /home/frs/project/ephedraceae/'${device}'/images/'
    echo 'mkdir /home/frs/project/ephedraceae/'${device}'/images/'${project}'/'
  } | sftp ariank16a@frs.sourceforge.net

  rsync -Ph out/target/product/"${device}"/lineage-*-"${device}".zip ariank16a@frs.sourceforge.net:/home/frs/project/ephedraceae/"${device}"/"${project}"/
  rsync -Ph out/target/product/"${device}"/lineage-*-"${device}".zip.sha256sum ariank16a@frs.sourceforge.net:/home/frs/project/ephedraceae/"${device}"/"${project}"/

  img_version=$(cat "${OUT}"/system/build.prop | grep ro.lineage.version=)
  img_version="${img_version#*=}"
  img_version=lineage-"${img_version}"
  for partition in boot dlkm dtbo recovery vendor_boot; do
    if [[ -f out/target/product/"${device}"/${img_version}-${partition}.img ]]; then
      rsync -Ph out/target/product/"${device}"/${img_version}-${partition}.img ariank16a@frs.sourceforge.net:/home/frs/project/ephedraceae/"${device}"/images/"${project}"/
    fi
  done

  if [[ ${DEBUG_BUILD} == 0 ]]; then
    release ${device} ${2}
  fi
}

# release device gms
release () {
  device=${1}
  project="$(basename ${LOCAL_PATH})"

  if [[ ${2} == "gms" ]]; then
    type="GMS"
  else
    type="VANILLA"
  fi

  download_link="https://sourceforge.net/projects/ephedraceae/files/"${device}"/"$project"/$(basename $(ls out/target/product/"$1"/lineage-*-"$1".zip))"
  images_download_link="https://sourceforge.net/projects/ephedraceae/files/"${device}"/images/"$project"/"
  time="$(cat ${LOCAL_PATH}/.last_build_time)"
  checksum="$(cat "${LOCAL_PATH}"/out/target/product/"$1"/lineage-*-"$1".zip.sha256sum | awk '{print $1}')"
  checksum_link="$download_link".sha256sum

  if [ "$2" == "gms" ]; then
    device_variant="$1_gms"
  else
    device_variant="$1"
  fi
  changelog_link=https://raw.githubusercontent.com/arian-ota/changelog/"$project"/"$device_variant".txt

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

  lineage_version=$(cat "${OUT}"/system/build.prop | grep ro.lineage.build.version=)
  lineage_version="${lineage_version#*=}"

  brand=$(cat "${OUT}"/system/build.prop | grep ro.product.system.brand=)
  brand="${brand#*=}"
  model=$(cat "${OUT}"/system/build.prop | grep ro.product.system.model=)
  model="${model#*=}"
  device=$(cat "${OUT}"/system/build.prop | grep ro.product.system.device=)
  device="${device#*=}"

  date=$(cat "${OUT}"/system/build.prop | grep ro.system.build.date.utc=)
  date="${date#*=}"
  date=$(date -d @${date} +%F)
  security_patch=$(cat "${OUT}"/system/build.prop | grep ro.build.version.security_patch=)
  security_patch="${security_patch#*=}"

  telegram ${extra_arguments} -M " \
*LineageOS ${lineage_version} for ${brand} ${model} (${device})*

📅 Build date: \`${date}\`
🛡️ Security patch: \`${security_patch}\`
💬 Variant: \`${type}\`

🗒️ [Changelog](${changelog_link})

*Download*
⬇️ [${project}](${download_link})
☑️ [checksum](${checksum_link})
💽 [lineage recovery](${images_download_link})

*SHA-256 checksum*
\`${checksum}\`

${group}
"
  update_ota ${device} ${2}
  update_changelog ${device} ${2}
  # TODO - Maybe clean out after uploading
  #make clean
}

# update_ota device gms
update_ota () {
  if [[ ${1} == "" ]]; then
    echo "specify a device"
    return -1
  fi

  if [[ ${2} == "gms" ]]; then
    ota_device="${1}_gms"
  else
    ota_device="${1}"
  fi

  project=$(basename ${LOCAL_PATH})

  breakfast ${1}

  datetime=$(cat "${OUT}"/system/build.prop | grep ro.build.date.utc=)
  datetime="${datetime#*=}"

  filename=$(cat "${OUT}"/system/build.prop | grep ro.lineage.version=)
  filename="${filename#*=}"
  filename=lineage-"${filename}".zip

  id=$(cat "${OUT}"/"${filename}".sha256sum | awk '{print $1}')

  romtype=$(cat "${OUT}"/system/build.prop | grep ro.lineage.releasetype=)
  romtype="${romtype#*=}"

  size=$(ls -l "${OUT}"/"${filename}" | awk '{print $5}')

  url="https://sourceforge.net/projects/ephedraceae/files/"$1"/"${project}"/"$filename"/download"

  version=$(cat "${OUT}"/system/build.prop | grep ro.lineage.build.version=)
  version="${version#*=}"

  rm -rf "${LOCAL_PATH}"/ota
  git clone git@github.com:arian-ota/ota.git
  cd "${LOCAL_PATH}"/ota
  if [[ $(git fetch origin "${project}" && echo ${?}) == 0 ]]; then
    git checkout origin/"${project}"
  else
    git checkout --orphan "${project}"
    git rm -rf .
  fi

  ota_entry='{
        datetime: '${datetime}',
        filename: "'${filename}'",
        id: "'${id}'",
        romtype: "'${romtype}'",
        size: '${size}',
        url: "'${url}'",
        version: "'${version}'"
      }'
  if [[ $(jq 'has("response")' "${ota_device}".json 2> /dev/null) ]]; then
    append_ota=1
    for (( i = 0; i < 3; i++ )); do
      if [[ $(jq -r .response[${i}].id "${ota_device}".json) == ${id} ]]; then
        echo "OTA json already contains update with id ${id}"
        append_ota=0
        break
      fi
    done
    if [[ ${append_ota} == 1 ]]; then
      echo "Appending OTA to existing json"
      jq '.response += ['"${ota_entry}"']' "${ota_device}".json | sponge "${ota_device}".json

      # Trim the list of builds in Updater
      while [[ $(jq '.response | length' "${ota_device}".json) > 3 ]]; do
        jq 'del(.response[0])' "${ota_device}".json | sponge "${ota_device}".json
      done
    fi
  else
    echo "Creating new OTA json"
    jq -n '{"response": ['"${ota_entry}"']}' > "${ota_device}".json
  fi

  git add "${ota_device}".json
  git commit -m "${ota_device}: OTA update $(date +%F)"
  git push git@github.com:arian-ota/ota.git HEAD:refs/heads/"${project}"
  cd ${LOCAL_PATH}
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

  rm -rf "${LOCAL_PATH}"/changelog
  git clone git@github.com:arian-ota/changelog.git
  cd "${LOCAL_PATH}"/changelog
  if [[ $(git fetch origin "${project}" && echo ${?}) == 0 ]]; then
    git checkout origin/"${project}"
  else
    git checkout --orphan "${project}"
    git rm -rf .
  fi
  cd ..

  changelog="${LOCAL_PATH}"/changelog/"${changelog_device}".txt

  if [[ -f ${changelog} ]];
  then
      rm ${changelog}
  fi

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
  git push git@github.com:arian-ota/changelog.git HEAD:refs/heads/"${project}"
  cd ${LOCAL_PATH}
}

if [ -f env_overwrite.sh ]; then
  source env_overwrite.sh
fi
