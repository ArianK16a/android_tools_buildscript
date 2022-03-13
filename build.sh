#!/bin/bash
#
# Copyright (C) 2019-2021 ArianK16a
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH="$(pwd)"

if [ "$DEBUG_BUILD" = 1 ]; then
  signed=0
else
  signed=1
  DEBUG_BUILD=0
fi

telegram () {
  /home/arian/telegram.sh/telegram "$@"
}

prepare () {
  cd ${LOCAL_PATH}
  source build/envsetup.sh
  export CCACHE_EXEC=$(command -v ccache)
  export CCACHE_DIR=$(pwd)/.ccache
  export USE_CCACHE=1
  ccache -M 20G
  if [ -f ${LOCAL_PATH}/.last_build_time ]; then
    rm ${LOCAL_PATH}/.last_build_time
  fi
}

prepare_vanilla () {
  rm -rf vendor/extra
  git clone https://github.com/ArianK16a/android_vendor_extra.git -b lineage-18.1_vanilla vendor/extra
  export TARGET_UNOFFICIAL_BUILD_ID=
}

prepare_gms () {
  rm -rf vendor/extra
  git clone https://github.com/ArianK16a/android_vendor_extra.git -b lineage-18.1_gms vendor/extra
  export TARGET_UNOFFICIAL_BUILD_ID=GMS
}

# build device gms
build () {
  prepare
  if [ "$DEBUG_BUILD" = 0 ]; then
    repo sync --force-sync -q
    bash "${LOCAL_PATH}"/picks.sh
  fi
  if [ "$2" = "gms" ]; then
    prepare_gms
  else
    prepare_vanilla
  fi
  breakfast "$1"
  if [ "$DEBUG_BUILD" = 1 ]; then
    make installclean
  else
    make clean
  fi
  telegram -N -M "*(i)* \`"$(basename ${LOCAL_PATH})"\` compilation for \`"$1"\` *started* on "$HOSTNAME"."
  build_start=$(date +"%s")
  if [ "$signed" = 1 ]; then
    breakfast "$1"
    mka target-files-package otatools
  else
    brunch "$1"
  fi
  build_result "$1" "$2"
  if [ -f ${LOCAL_PATH}/.last_build_time ] && ([[ $(ls $OUT/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip) ]] || [[ $(ls "$OUT"/lineage-*-"$1".zip) ]]); then
    recovery_filename=$(cat "$OUT"/recovery/root/prop.default | grep ro.lineage.version=)
    recovery_filename="${recovery_filename#*=}"
    recovery_filename=lineage_recovery-"$recovery_filename".img
    if [ "$signed" = 1 ]; then
      sign_target_files
      unzip -p $OUT/signed-target_files-"$filename" IMAGES/recovery.img > $OUT/$recovery_filename
    else
      cp ${OUT}/recovery.img ${OUT}/${recovery_filename}
    fi
    upload "$1" "$2" "$3"
  else
    extra_arguments=""
    if [ "$1" = "davinci" ]; then
      extra_arguments="-c -1001426238293"
    elif [ "$1" = "toco" ]; then
      extra_arguments="-c -1001443889354"
    elif [ "$1" = "violet" ]; then
      extra_arguments="-c -1001656828188"
    fi
    telegram $extra_arguments "Compilation for "$1" failed!"
    #exit -1
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
  diff=$(($build_end - $build_start))
  time=$(convertsecs "$diff")
  if [ "$2" = "gms" ]; then
    type="GMS"
  else
    type="VANILLA"
  fi
  if [ "$result" = "0" ]; then
    echo "$time" > ${LOCAL_PATH}/.last_build_time
    message="completed successfully"
  else
    message="failed"
  fi
  telegram -M "*(i)* \`"$(basename ${LOCAL_PATH})"\` compilation for \`"$1"\` *$message* on "$HOSTNAME". Build variant: \`$type\`. Build time: \`$time\`."
}

sign_target_files () {
  filename=$(cat "$OUT"/system/build.prop | grep ro.lineage.version=)
  filename="${filename#*=}"
  filename=lineage-"$filename".zip

  ./out/soong/host/linux-x86/bin/sign_target_files_apks -o -d ~/.android-certs \
    $OUT/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip \
    $OUT/signed-target_files-"$filename"

  ./out/soong/host/linux-x86/bin/ota_from_target_files -k ~/.android-certs/releasekey \
    --block --backup=true \
    $OUT/signed-target_files-"$filename" \
    $OUT/"$filename"

  checksum=$(sha256sum "$OUT"/"$filename" | awk '{print $1}')
  echo ""$checksum"  "$filename"" > $OUT/"$filename".sha256sum
}

# upload device gms
upload () {
  if [ "$1" = "" ]; then
    echo "specify a device"
  fi

  project="$(basename ${LOCAL_PATH})"

  rsync -Ph out/target/product/"$1"/lineage-*-"$1".zip ariank16a@frs.sourceforge.net:/home/frs/project/ephedraceae/"$1"/"$project"/
  rsync -Ph out/target/product/"$1"/lineage-*-"$1".zip.sha256sum ariank16a@frs.sourceforge.net:/home/frs/project/ephedraceae/"$1"/"$project"/

  recovery_filename=$(cat "$OUT"/recovery/root/prop.default | grep ro.lineage.version=)
  recovery_filename="${recovery_filename#*=}"
  recovery_filename=lineage_recovery-"$recovery_filename".img
  rsync -Ph out/target/product/"$1"/"$recovery_filename" ariank16a@frs.sourceforge.net:/home/frs/project/ephedraceae/"$1"/recovery/"$project"/

  if [ "$DEBUG_BUILD" = 0 ]; then
    release "$1" "$project" "$2"
  fi
}

# release device gms
release () {
  device="$1"
  project="$(basename ${LOCAL_PATH})"

  if [ "$2" = "gms" ]; then
    type="GMS"
  else
    type="VANILLA"
  fi

  download_link="https://sourceforge.net/projects/ephedraceae/files/"$1"/"$project"/$(basename $(ls out/target/product/"$1"/lineage-*-"$1".zip))"
  recovery_download_link="https://sourceforge.net/projects/ephedraceae/files/"$1"/recovery/"$project"/$(basename $(ls out/target/product/"$1"/lineage_recovery-*-"$1".img))"
  time="$(cat ${LOCAL_PATH}/.last_build_time)"
  checksum="$(cat "${LOCAL_PATH}"/out/target/product/"$1"/lineage-*-"$1".zip.sha256sum | awk '{print $1}')"
  checksum_link="$download_link".sha256sum

  if [ "$2" = "gms" ]; then
    device_variant="$1_gms"
  else
    device_variant="$1"
  fi
  changelog_link=https://raw.githubusercontent.com/arian-ota/changelog/"$project"/"$device_variant".txt

  if [ "$device" = "davinci" ]; then
    group="@StarWarsFlowers"
    extra_arguments="-c -1001426238293"
  elif [ "$device" = "toco" ]; then
    group="@lineage\_toco"
    extra_arguments="-c -1001443889354"
  elif [ "$device" = "violet" ]; then
    group="@LineageViolet"
    extra_arguments="-c -1001656828188"
  else
    extra_arguments="-c -1001159030901"
    group="#"$device""
  fi

  lineage_version=$(cat "$OUT"/system/build.prop | grep ro.lineage.build.version=)
  lineage_version="${lineage_version#*=}"

  model=$(cat "$OUT"/system/build.prop | grep ro.product.system.model=)
  model="${model#*=}"

  telegram $extra_arguments -M " \
*New LineageOS ${lineage_version} build for ${model} available! *

📅 Build date: \'$(date +\'%Y-%m-%d\')\'
💬 Variant: \`${type}\`

*Download*
⬇️ [${project}](${download_link})
⬇️ [recovery](${recovery_download_link})
✅ [checksum](${checksum_link}): \`${checksum}\`

🚧 [Changelog](${changelog_link})

*Build stats*
⌛ Time: \`${time}\`
🗣️ User: \`${USERNAME}\`
💻 Host: \`${HOSTNAME}\`

${group}
"
  update_ota "$device" "$project" "$3"
  # TMP change this to make clean again
  #make installclean
}

# update_ota device gms
update_ota () {
  if [ "$1" = "" ]; then
    echo "specify a device"
    return -1
  fi

  if [ "$2" = "gms" ]; then
    device="$1_gms"
  else
    device="$1"
  fi

  project="$(basename ${LOCAL_PATH})"

  breakfast "$1"

  datetime=$(cat "$OUT"/system/build.prop | grep ro.build.date.utc=)
  datetime="${datetime#*=}"

  filename=$(cat "$OUT"/system/build.prop | grep ro.lineage.version=)
  filename="${filename#*=}"
  filename=lineage-"$filename".zip

  id=$(cat "$OUT"/"$filename".sha256sum | awk '{print $1}')

  romtype=$(cat "$OUT"/system/build.prop | grep ro.lineage.releasetype=)
  romtype="${romtype#*=}"

  size=$(ls -l "$OUT"/"$filename" | awk '{print $5}')

  url="https://sourceforge.net/projects/ephedraceae/files/"$1"/"${project}"/"$filename"/download"

  version=$(cat "$OUT"/system/build.prop | grep ro.lineage.build.version=)
  version="${version#*=}"

  rm -rf "${LOCAL_PATH}"/ota
  git clone git@github.com:arian-ota/ota.git -b "${project}"
  cd "${LOCAL_PATH}"/ota

  jq '.response += [{
        datetime: '${datetime}',
        filename: "'${filename}'",
        id: "'${id}'",
        romtype: "'${romtype}'",
        size: '${size}',
        url: "'${url}'",
        version: "'${version}'"
      }]' "${device}".json | sponge "${device}".json

  # Only keep the last three builds in Updater
  while [[ $(jq '.response | length' test.json) > 3 ]]; do
    jq 'del(.response[0])' "${device}".json | sponge "${device}".json
  done

  git add "${device}".json
  git commit -m "${device}: OTA update $(date +\'%Y-%m-%d\')"
  git push git@github.com:arian-ota/ota.git HEAD:"$2"
  cd ${LOCAL_PATH}

  update_changelog $1 $2
}

# update_changelog device gms
update_changelog () {
  if [ "$1" = "" ]; then
    echo "specify a device"
    return -1
  fi

  if [ "$2" = "gms" ]; then
    device="$1_gms"
  else
    device="$1"
  fi

  project="$(basename ${LOCAL_PATH})"

  cd "${LOCAL_PATH}"/changelog
  git add -A && git stash && git reset
  git fetch git@github.com:arian-ota/changelog.git "$2"
  git checkout FETCH_HEAD
  cd ${LOCAL_PATH}

  export changelog="${LOCAL_PATH}"/changelog/"$device".txt

  if [ -f $changelog ];
  then
      rm $changelog
  fi

  touch $changelog

  for i in $(seq 7);
  do
      export After_Date=`date --date="$i days ago" +%F`
      k=$(expr $i - 1)
      export Until_Date=`date --date="$k days ago" +%F`
      echo "====================" >> $changelog;
      echo "     $Until_Date    " >> $changelog;
      echo "====================" >> $changelog;
      while read path;
      do
          # https://www.cyberciti.biz/faq/unix-linux-bash-script-check-if-variable-is-empty/
          Git_log=`git --git-dir ./${path}/.git log --after=$After_Date --until=$Until_Date --pretty=tformat:"%h  %s  [%an]" --abbrev-commit --abbrev=7`
          if [ ! -z "${Git_log}" ]; then
              printf "\n* ${path}\n${Git_log}\n" >> $changelog;
          fi
      done < ./.repo/project.list;
  done

  cd changelog
  git add "$device".txt
  git commit -m "$device: Automatic changelog update"
  git push git@github.com:arian-ota/changelog.git HEAD:"$2"
  cd ${LOCAL_PATH}
}

if [ -f env_overwrite.sh ]; then
  source env_overwrite.sh
fi
