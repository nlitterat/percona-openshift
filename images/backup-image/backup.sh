#!/bin/bash

set -o errexit
set -o xtrace

GARBD_OPTS=""
SOCAT_OPTS="TCP-LISTEN:4444,reuseaddr,retry=30"

function get_backup_source() {
    peer-list -on-start=/usr/bin/get-pxc-state -service=$PXC_SERVICE 2>&1 \
        | grep wsrep_ready:ON:wsrep_connected:ON:wsrep_local_state_comment:Synced:wsrep_cluster_status:Primary \
        | sort \
        | tail -1 \
        | cut -d : -f 2 \
        | cut -d . -f 1
}

function check_ssl() {
    local CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    if [ -f /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt ]; then
        CA=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
    fi
    if [ -f /etc/mysql/ssl/ca.crt ]; then
        CA=/etc/mysql/ssl/ca.crt
    fi

    local KEY=/etc/mysql/ssl/tls.key
    local CERT=/etc/mysql/ssl/tls.crt
    if [ -f $CA -a -f $KEY -a -f $CERT ]; then
        GARBD_OPTS="-o socket.ssl_ca=$CA;socket.ssl_cert=$CERT;socket.ssl_key=$KEY;socket.ssl_cipher="
        SOCAT_OPTS="openssl-listen:4444,reuseaddr,cert=$CERT,key=$KEY,cafile=$CA,verify=1,retry=30"
    fi
}

function request_streaming() {
    local LOCAL_IP=$(hostname -i)
    local NODE_NAME=$(get_backup_source)

    if [ -z "$NODE_NAME" ]; then
        peer-list -on-start=/usr/bin/get-pxc-state -service=$PXC_SERVICE
        echo "[ERROR] Cannot find node for backup"
        exit 1
    fi

    timeout -k 25 20 \
        garbd \
            --address "gcomm://$NODE_NAME.$PXC_SERVICE?gmcast.listen_addr=tcp://0.0.0.0:4444" \
            --donor "$NODE_NAME" \
            --group "$PXC_SERVICE" \
            $GARBD_OPTS \
            --sst "xtrabackup-v2:$LOCAL_IP:4444/xtrabackup_sst//1"
}

function backup_volume() {
    BACKUP_DIR=${BACKUP_DIR:-/backup/$PXC_SERVICE-$(date +%F-%H-%M)}
    mkdir -p "$BACKUP_DIR"
    cd "$BACKUP_DIR" || exit

    echo "Backup to $BACKUP_DIR started"
    request_streaming
    timeout -k 110 100 socat -u "$SOCAT_OPTS" stdio \
        > xtrabackup.stream
    echo "Backup finished"

    stat xtrabackup.stream
    if [ $(stat -c%s xtrabackup.stream) = 0 ]; then
        exit 1
    fi
    md5sum xtrabackup.stream | tee md5sum.txt
}

function backup_s3() {
    S3_BUCKET_PATH=${S3_BUCKET_PATH:-$PXC_SERVICE-$(date +%F-%H-%M)-xtrabackup.stream}

    echo "Backup to s3://$S3_BUCKET/$S3_BUCKET_PATH started"
    mc -C /tmp/mc config host add dest "${ENDPOINT_URL:-https://s3.amazonaws.com}" "$ACCESS_KEY_ID" "$SECRET_ACCESS_KEY"
    request_streaming
    timeout -k 110 100 socat -u "$SOCAT_OPTS" stdio \
        | mc -C /tmp/mc pipe "dest/$S3_BUCKET/$S3_BUCKET_PATH"
    echo "Backup finished"

    mc -C /tmp/mc stat "dest/$S3_BUCKET/$S3_BUCKET_PATH"
    s3_size=$(mc -C /tmp/mc stat "dest/$S3_BUCKET/$S3_BUCKET_PATH" | grep "^Size" | awk '{print$3}')
    if [ $s3_size = "0B" ]; then
        exit 1
    fi
}

check_ssl
if [ -n "$S3_BUCKET" ]; then
    backup_s3
else
    backup_volume
fi
