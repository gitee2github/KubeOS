#!/bin/bash
## Copyright (c) Huawei Technologies Co., Ltd. 2021. All rights reserved.
# KubeOS is licensed under the Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#     http://license.coscl.org.cn/MulanPSL2
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR
# PURPOSE.
## See the Mulan PSL v2 for more details.

set -e

NAME=KubeOS
ISO_PATH="/mnt"
ISO=""
VERSION=""
AGENT_PATH=""
PASSWD=""
IMG_SIZE=20
PWD="$(pwd)"
TMP_MOUNT_PATH="${PWD}/mnt"
RPM_ROOT="${PWD}/rootfs"
LOCK=./test.lock
CHECK_REGEX='\||;|&|&&|\|\||>|>>|<|,|#|!|\$'

function show_options() {
	cat << EOF

usage example: sh generate.sh isopath osversion agentpath passwd(encrypted)

options:
    -h,--help       show help information
EOF
}

function file_lock() {
	local lock_file=$1
	exec {lock_fd}>"${lock_file}"
	flock -xn "${lock_fd}"
}

function mount_proc_dev_sys() {
	local tmp_root=$1
	mount -t proc none "${tmp_root}/proc"
	mount --bind /dev "${tmp_root}/dev"
	mount --bind /dev/pts "${tmp_root}/dev/pts"
	mount -t sysfs none "${tmp_root}/sys"
}

function unmount_dir() {
	local dir=$1

	if [ -L "${dir}" ] || [ -f "${dir}" ]; then
		echo "${dir} is not a directory, please check it."
		return 1
	fi

	if [ ! -d "${dir}" ]; then
		return 0
	fi

	local real_dir=$(readlink -e "${dir}")
	local mnts=$(awk '{print $2}' < /proc/mounts | grep "^${real_dir}" | sort -r)
	for m in ${mnts}; do
		echo "Unmount ${m}"
		umount -f "${m}" || true
	done

	return 0
}

function init_part() {
	local offset=$(fdisk -l system.img | grep $1 | awk '{print $2}')
	local sizelimit=$(fdisk -l system.img | grep $1 | awk '{print $3}')
	sizelimit=$(echo "($sizelimit - $offset)*512" | bc)
	offset=$(echo "${offset}*512" | bc)
	local loop=$(losetup -f)
	losetup -o "${offset}" --sizelimit "${sizelimit}" "${loop}" system.img
	mkfs.ext4 -L "$2" "${loop}"
	mount -t ext4 "${loop}" "$3"
	rm -rf "$3/lost+found"
}

function delete_dir() {
	local ret=0
	local dir="$1"
	unmount_dir "${dir}"
	ret=$?
	if [ "${ret}" -eq 0 ]; then
		rm -rf "${dir}"
		return 0
	else
		echo "${dir} is failed to unmount , can not delete $dir."
		return 1
	fi
}

function delete_file() {
	local file="$1"
	if [ ! -e "${file}" ]; then
		return 0
	fi

	if [ ! -f "${file}" ]; then
		echo "${file} is not a file."
		return 1
	fi

	rm -f "${file}"
	return 0
}

function clean_space() {
	delete_dir "${RPM_ROOT}"
	delete_dir "${TMP_MOUNT_PATH}"
	unmount_dir "${ISO_PATH}"
	delete_file os.tar
	rm -rf "${LOCK}"
}

function clean_img() {
	delete_file system.img
	delete_file update.img
}

function test_lock() {
	set +eE
	file_lock "${LOCK}"
	if [ $? -ne 0 ]; then
		echo "There is already an generate  process running."
		exit 203
	fi
	set -eE
}

function check_path() {
	if [ ! -f "${ISO}" ];then
		echo "ISO path is invalid."
		exit 3
	fi

	if [ -d "${RPM_ROOT}" ]; then
		echo "there is a rootfs folder. please confirm if rootfs is being used, if not, please remove ${RPM_ROOT} first."
		exit 5
	fi

	if mount 2>/dev/null | grep -q "${ISO_PATH}"; then
		echo "$ISO_PATH has already been mounted."
		exit 4
	fi
}

function check_disk_space() {
	local disk_ava="$(df ${PWD} -h | awk 'NR==2{print}' | awk '{print $4}')"
	if echo "${disk_ava}" | grep -q G$; then
		disk_ava="$(echo ${disk_ava} | awk -F G '{print $1}' | awk -F . '{print $1}')"
		if [ "${disk_ava}" -lt 25 ]; then
			echo "The available disk space is not enough, at least 25GB."
			exit 6
		fi
	else
		echo "The available disk space is not enough, at least 25G."
		exit 6
	fi
}

function prepare_yum() {
	mount "${ISO}" "${ISO_PATH}"
	if [ ! -d "/mnt/Packages" ]; then
		echo "please use ISO file path as ${ISO}."
		exit 2
	fi

	# init rpmdb
	rpm --root "${RPM_ROOT}" --initdb
	mkdir -p "${RPM_ROOT}"{/etc/yum.repos.d,/persist,/proc,/dev/pts,/sys}
	mount_proc_dev_sys "${RPM_ROOT}"
	# init yum repo
	local iso_repo="${RPM_ROOT}/etc/yum.repos.d/iso.repo"
	echo "[base]" >"${iso_repo}"
	{
		echo "name=ISO base"
		echo "baseurl=file://${ISO_PATH}"
		echo "enabled=1"
	} >>"${iso_repo}"
}

function install_packages() {
	prepare_yum

	echo "install package.."

	local filesize=$(stat -c "%s" ./rpmlist)
	local maxsize=$((1024*1024))
	if [ "${filesize}" -gt "${maxsize}" ]; then
		echo "please check if rpmlist is too big or something wrong"
		exit 7
	fi

	local rpms=$(cat ./rpmlist | tr "\n" " ")
	yum -y --installroot="${RPM_ROOT}" install --nogpgcheck --setopt install_weak_deps=False ${rpms}
	yum -y --installroot="${RPM_ROOT}" clean all
}

function install_misc() {
	cp grub.cfg "${RPM_ROOT}/boot/grub2/"
	cp ../files/*mount ../files/os-agent.service "${RPM_ROOT}/usr/lib/systemd/system/"
	cp ../files/os-release "${RPM_ROOT}/usr/lib/"
	cp "${AGENT_PATH}" "${RPM_ROOT}/usr/bin"
	rm "${RPM_ROOT}/etc/os-release"

	cat <<EOF > "${RPM_ROOT}/usr/lib/os-release"
NAME=${NAME}
ID=${NAME}
EOF
	echo "PRETTY_NAME=\"${NAME} ${VERSION}\"" >> "${RPM_ROOT}/usr/lib/os-release"
	echo "VERSION_ID=${VERSION}" >> "${RPM_ROOT}/usr/lib/os-release"
	mv "${RPM_ROOT}"/boot/vmlinuz* "${RPM_ROOT}/boot/vmlinuz"
	mv "${RPM_ROOT}"/boot/initramfs* "${RPM_ROOT}/boot/initramfs.img"

	cp set_in_chroot.sh "${RPM_ROOT}"
	ROOT_PWD="${PASSWD}" chroot "$RPM_ROOT" bash /set_in_chroot.sh
	rm "${RPM_ROOT}/set_in_chroot.sh"
}

function create_img() {
	rm -f system.img update.img
	qemu-img create system.img ${IMG_SIZE}G
	parted system.img -- mklabel msdos
	parted system.img -- mkpart primary ext4 1MiB 20MiB
	parted system.img -- mkpart primary ext4 20MiB 2120MiB
	parted system.img -- mkpart primary ext4 2120MiB 4220MiB
	parted system.img -- mkpart primary ext4 4220MiB 100%

	local device=$(losetup -f)
	losetup "${device}" system.img

	mkdir -p "${TMP_MOUNT_PATH}"

	init_part system.img2 ROOT-A "${TMP_MOUNT_PATH}"
	local grub2_path="${TMP_MOUNT_PATH}/boot/grub2"
	mkdir -p "${grub2_path}"
	init_part system.img1 GRUB2 "${grub2_path}"

	tar -x -C "${TMP_MOUNT_PATH}" -f os.tar
	sync

	dd if=/dev/disk/by-label/ROOT-A of=update.img bs=8M
	mount_proc_dev_sys "${TMP_MOUNT_PATH}"
	chroot "${TMP_MOUNT_PATH}" grub2-install --modules="biosdisk part_msdos" "${device}"
	sync
	unmount_dir "${TMP_MOUNT_PATH}"

	init_part system.img3 ROOT-B "${TMP_MOUNT_PATH}"
	umount "${TMP_MOUNT_PATH}"

	init_part system.img4 PERSIST "${TMP_MOUNT_PATH}"
	mkdir ${TMP_MOUNT_PATH}/{var,etc,etcwork}
	umount "${TMP_MOUNT_PATH}"

	losetup -D
	qemu-img convert system.img -O qcow2 system.qcow2
}

function create_os_tar() {
	install_packages
	install_misc
	unmount_dir "${RPM_ROOT}"

	tar -C "${RPM_ROOT}" -cf ./os.tar .
}

test_lock

if [ "$#" -eq 1 ]; then
	case $1 in
	-h|--help)
		show_options
		exit 0;;
	*)
		echo "error: params is invalid,please check it."
		show_options
		exit 3;;
	esac
fi

if [ $# != 4 ];then
	echo "error: params is invalid, please check it."
	exit 3
fi

set +eE
for i in $1 $2 $3
do
   echo "$i" | grep -v -E ${CHECK_REGEX}
   filterParam=$(echo "$i" | grep -v -E ${CHECK_REGEX})
   if [[ "${filterParam}" != "$i" ]]; then
      echo "error: params $i is invalid, please check it."
      exit 3
   fi
done
set -eE

ISO=$1
VERSION=$2
AGENT_PATH=$3
PASSWD=$4

check_path
check_disk_space

trap clean_space EXIT
trap clean_img ERR

create_os_tar
create_img
