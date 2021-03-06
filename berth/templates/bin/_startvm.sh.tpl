#!/bin/bash

set -ex

# FIXME; right now this doens't work, need to work out why
#set -o pipefail

# Returns the integer representation of an IP arg, passed in ascii
# dotted-decimal notation (x.x.x.x)
atoi() {
    IP=$1; IPNUM=0
    for (( i=0 ; i<4 ; ++i )); do
        ((IPNUM+=${IP%%.*}*$((256**$((3-${i}))))))
        IP=${IP#*.}
    done
    echo $IPNUM
}

# Returns the dotted-decimal ascii form of an IP arg passed in integer
# format
itoa() {
    echo -n $(($(($(($((${1}/256))/256))/256))%256)).
    echo -n $(($(($((${1}/256))/256))%256)).
    echo -n $(($((${1}/256))%256)).
    echo $((${1}%256))
}

generate_cloud_drive() {
    metadata=/metadata
    if [ ! -f $metadata ]; then
        metadata=""
    fi

    userdata=/userdata
    if [ ! -f $userdata ]; then
        userdata=""
    fi

    if [ "$metadata" == "" -a "$userdata" == "" ]; then
        return
    fi

    TMPDIR=`mktemp -d -t aicvm.XXXXXX`

    if [ $? -ne 0 ]; then
        echo "Fail to create temporaily directory"
        exit 1
    fi

    # create form of config drive
    mkdir -p ${TMPDIR}/openstack/2012-08-10
    OLD_PWD=$PWD
    cd ${TMPDIR}/openstack
    ln -s 2012-08-10 latest
    cd $OLD_PWD

    if [ -f $metadata ]; then
        cp $metadata ${TMPDIR}/openstack/2012-08-10/meta_data.json
    fi
    if [ -f $userdata ]; then
        cp $userdata ${TMPDIR}/openstack/2012-08-10/user_data
    fi

    iso="cloud-drive.iso"
    mkisofs -R -V config-2 -o $iso ${TMPDIR}
    if [ $? -ne 0 ]; then
        echo Fail to create cloud-drive ISO image for cloud-init
        exit 1
    fi
    echo $iso
}

# Generate random new MAC address
hexchars="0123456789ABCDEF"
end=$( for i in {1..8} ; do echo -n ${hexchars:$(( $RANDOM % 16 )):1} ; done | sed -e 's/\(..\)/:\1/g' )
NEWMAC=`echo 06:FE$end`

# These two variables can be overwritten
: ${KVM_BLK_OPTS:="-drive file=\$KVM_IMAGE,if=none,id=drive-disk0,format=qcow2 \
-device virtio-blk-pci,scsi=off,drive=drive-disk0,id=virtio-disk0,bootindex=1"}
: ${KVM_RAW_BLK_OPTS:="-drive file=\$KVM_IMAGE,if=none,id=drive-disk0,format=raw \
-device virtio-blk-pci,scsi=off,drive=drive-disk0,id=virtio-disk0,bootindex=1"}
: ${KVM_NET_OPTS:="-netdev bridge,br=\$BRIDGE_IFACE,id=net0 \
-device virtio-net-pci,netdev=net0,mac=\$NEWMAC"}

# define some valeus for the VM side of the networking but
# allow them to be overriden by the operator
: ${VM_IP:="192.168.254.2"}
: ${VM_GW:="192.168.254.1"}

# the netmask is not definable, as we leverage
# /30 elsewhere
VM_NETMASK="255.255.255.252"

# For debugging
if [ "$1" = "bash" ]; then
  exec bash
fi

# Pass Docker command args to kvm
KVM_ARGS=$@

# Create the qcow disk image on the Docker volume named /image, using
# the compressed qcow image that came with Docker image as the base.
# Docker volumes typically perform better than the file system for
# Docker images (no need for overlay fs etc.)

if [ -e /dev/vm/root ]; then
    KVM_BLK_OPTS="$KVM_RAW_BLK_OPTS"
    KVM_IMAGE=/dev/vm/root
else

    if [ -e "${IMG_TARGET}" ]; then
        BASE=${IMG_TARGET}
    else

        if [ ! -d "/image" ]; then
            echo "/image directory does not exist, failed to mount volume?"
            exit 2
        fi

        if [ ! -e "/image/${IMG_TARGET}" ]; then
            echo "Fetching missing image target"
            curl ${IMG_SOURCE} > /image/${IMG_TARGET}
        fi

        BASE=/image/${IMG_TARGET}
    fi

    if [ ! -d "/image" ]; then
        echo "/image directory does not exist, failed to mount volume /image?"
        exit 2
    fi

    if [ -z "${HOSTNAME}" ]; then
        echo "Could not find HOSTNAME var.  Did you specify a HOSTNAME environment variable?"
    fi

    KVM_IMAGE=/image/${HOSTNAME}.qcow2

    if [ -e "${KVM_IMAGE}" ]; then
        echo "Image ${KVM_IMAGE} already exists.  Not recreating"
    else
        qemu-img create -f qcow2 -b ${BASE} \
                 $KVM_IMAGE > /dev/null
        if [[ $? -ne 0 ]]; then
            echo "Failed to create qcow2 image"
            exit 3
        fi
    fi
fi

VOLUMES_DIR="/volumes/"
VOLUMES_LIST=`find $VOLUMES_DIR -name "*.img" | sort -d`
extra_kvm_blk_opts=""
for volume in $VOLUMES_LIST /dev/vm/disk* ; do
    if [ -e $volume ]; then
        extra_kvm_blk_opts=$extra_kvm_blk_opts" -drive file=$volume,if=virtio,format=raw"
    fi
done
KVM_BLK_OPTS=$KVM_BLK_OPTS$extra_kvm_blk_opts

# Network setup:
#
# 1. Create a bridge named br0
# 2. Remove IP from eth0, save eth0 MAC, give eth0 a random MAC

IFACE=eth0
BRIDGE_IFACE=br0

cidr2mask() {
    local i mask=""
    local full_octets=$(($1/8))
    local partial_octet=$(($1%8))

    for ((i=0;i<4;i+=1)); do
        if [ $i -lt $full_octets ]; then
            mask+=255
        elif [ $i -eq $full_octets ]; then
            mask+=$((256 - 2**(8-$partial_octet)))
        else
            mask+=0
        fi
        test $i -lt 3 && mask+=.
    done

    echo $mask
}

setup_bridge_networking() {

    MAC=`ip addr show $IFACE | grep ether | sed -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*\$//g' | cut -f2 -d ' '`
    HOST_IP=`ip addr show dev $IFACE | grep "inet $IP" | awk '{print $2}' | cut -f1 -d/`
    HOST_CIDR=`ip addr show dev $IFACE | grep "inet $IP" | awk '{print $2}' | cut -f2 -d/`
    HOST_NETMASK=`cidr2mask $HOST_CIDR`
    HOST_GATEWAY=`ip route get 8.8.8.8 | grep via | cut -f3 -d ' '`
    NAMESERVER=( `grep nameserver /etc/resolv.conf | grep -v "#" | cut -f2 -d ' '` )
    NAMESERVERS=`echo ${NAMESERVER[*]} | sed "s/ /,/"`
    SEARCH=( `grep -E ^search /etc/resolv.conf | grep -v "#" | cut -f2- -d ' ' | tr ' ' ','` )
    # MAC=$(ip addr show $IFACE | grep ether | sed -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*\$//g' | cut -f2 -d ' ')
    # HOST_IP=$(ip addr show dev $IFACE | grep "inet $IP" | awk '{print $2}' | cut -f1 -d/)
    # HOST_CIDR=$(ip addr show dev $IFACE | grep "inet $IP" | awk '{print $2}' | cut -f2 -d/)
    # HOST_NETMASK=$(cidr2mask $HOST_CIDR)
    # HOST_GATEWAY=$(ip route get 8.8.8.8 | grep via | cut -f3 -d ' ')
    # NAMESERVER=$(grep nameserver /etc/resolv.conf | grep -v "#" | cut -f2 -d ' ') )
    # NAMESERVERS=$(echo ${NAMESERVER[*]} | sed "s/ /,/")
    # SEARCH=$(grep -E ^search /etc/resolv.conf | grep -v "#" | cut -f2- -d ' ' | tr ' ' ',')

    # fail if any of the above aren't suitable    # here
    [ -n "$MAC" ]
    [ -n "$HOST_IP" ]
    [ -n "$HOST_CIDR" ]
    [ -n "$HOST_NETMASK" ]
    [ -n "$HOST_GATEWAY" ]
    [ -n "$NAMESERVER" ]
    [ -n "$NAMESERVERS" ]
    [ -n "$SEARCH" ]

    # we must enable forwarding inside the container
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # we support exposing port 5900 on the container but leave
    # it up to the operator on whether to expose this - they can
    # specify NO_VNC as an environment variable to disable this
    # functionality
    if [ -z $NO_VNC ]; then
        iptables -t nat -A PREROUTING -p tcp \! --dport 5900 -d $HOST_IP -j DNAT --to-destination $VM_IP
        iptables -t nat -A POSTROUTING -s $VM_IP -j SNAT --to-source $HOST_IP
    else
        iptables -t nat -A PREROUTING -d $HOST_IP -j DNAT --to-destination $VM_IP
        iptables -t nat -A POSTROUTING -s $VM_IP -j SNAT --to-source $HOST_IP
    fi

    # generate VM specifics
    cat > /etc/dnsmasq.conf << EOF
user=root
dhcp-range=$VM_IP,$VM_IP
dhcp-host=$NEWMAC,$HOSTNAME,$VM_IP,infinite
dhcp-option=option:router,$VM_GW
dhcp-option=option:netmask,$VM_NETMASK
dhcp-option=option:dns-server,$NAMESERVERS
dhcp-option=119,$SEARCH
EOF

    if [ -z $NO_DHCP ]; then
        dnsmasq
    fi

    brctl addbr $BRIDGE_IFACE
    ip link set dev $BRIDGE_IFACE up
    ip addr add $VM_GW/30 dev $BRIDGE_IFACE

    # alanmeadows(NOTE) in many implementations with out of
    # subnet gateways the dhcp approach does not work
    # if [ -z $NO_DHCP ]; then
    #     ip addr add $NEWIP/$NEWCIDR dev $BRIDGE_IFACE
    # fi

    if [[ $? -ne 0 ]]; then
        echo "Failed to bring up network bridge"
        exit 4
    fi

    # Exec kvm as PID 1
    mkdir -p /etc/qemu
    echo allow $BRIDGE_IFACE >  /etc/qemu/bridge.conf
}

# need to wait until network is ready
ISO=`generate_cloud_drive`
if [[ $ISO ]]; then
    KVM_BLK_OPTS=$KVM_BLK_OPTS" -cdrom $ISO"
fi

setup_bridge_networking

HOST_IP=`ip addr show dev $IFACE | grep "inet $IP" | awk '{print $2}' | cut -f1 -d/`
VNC="-vnc $HOST_IP:0"

exec $LAUNCHER qemu-system-x86_64 \
     -smp "$IMG_VCPU" \
     -m "$IMG_RAM_MB" \
     -machine q35 \
     -cpu host,+x2apic \
     -vga vmware \
     -enable-kvm \
     $VNC \
     `eval echo $KVM_BLK_OPTS` \
     `eval echo $KVM_NET_OPTS` \
     -usbdevice tablet -nographic $KVM_ARGS
